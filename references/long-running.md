# Running long database jobs safely

Dumps, restores, and full-artifact checksum passes routinely run for hours. Two
things go wrong: the job dies with the session that launched it, or it finishes and
nobody notices because the thing watching it was watching the wrong signal.

## Detach so the job outlives its launcher

A job started with `&` from an interactive tool call can be killed when that call's
shell exits. Use `setsid --fork` to move it into its own session, and have it write
its own log:

```bash
cd /tmp && setsid --fork bash -c '
  echo "started: $(date --iso-8601=seconds)" >> /backups/job.log
  pg_restore -d mydb_new -j 12 /backups/mydb.pgdir >> /backups/job.log 2>&1
  rc=$?
  echo "pg_restore exit: $rc" >> /backups/job.log
  echo "finished: $(date --iso-8601=seconds)" >> /backups/job.log
  echo "JOB_DONE" >> /backups/job.log
'
```

Three properties make this recoverable by a completely fresh session:

1. **Timestamps come from the job**, not from whoever is watching. If the observer
   disconnects for six hours, the recorded duration is still correct.
2. **The real exit code is written into the log** (invariant 3) rather than left to
   whatever the harness reports about the wrapper.
3. **A terminal marker** (`JOB_DONE`) distinguishes "finished" from "still going"
   and from "died." Without it, an empty tail is ambiguous.

Grab the wrapper PID if you want to monitor it: `pgrep -f 'pg_restore -d mydb_new'`.

## Monitor liveness, not silence

The tempting watchdog is wrong:

```bash
until grep -q JOB_DONE /backups/job.log; do sleep 60; done   # waits forever if the job dies
```

If the job is OOM-killed or dies on a lock conflict, the marker never appears and
this waits indefinitely. **Absence of a completion signal is not evidence of
progress** — it is equally consistent with success-pending, death, and a typo in
the marker.

A correct watchdog checks that the process actually exists, and distinguishes the
three outcomes. `scripts/pg_watch_job.sh` does this; run it as:

```bash
scripts/pg_watch_job.sh <wrapper_pid> /backups/job.log /backups/job_progress.log JOB_DONE mydb_new 3600
```

It logs an hourly snapshot with `LIVE:` and the OS-reported elapsed time, exits
cleanly when it sees the marker, and — the important part — writes a loud
`ALERT_PROCESS_GONE_NO_COMPLETION_MARKER` line plus the tail of the job log if the
process vanishes without finishing. Silent death becomes a conspicuous artifact in
a file rather than a notification that never arrives.

Because it records the OS's own elapsed time each hour, the log is also independent
duration evidence. If a monitoring session dies mid-run, the hourly `LIVE:` entries
still prove the job was alive at each of those times.

## Watch real progress, not just liveness

PostgreSQL exposes progress for the phases that dominate these jobs:

```sql
-- bulk load progress (pg_dump and pg_restore both use COPY)
SELECT relid::regclass, command, pg_size_pretty(bytes_processed), tuples_processed
  FROM pg_stat_progress_copy;

-- index rebuild progress (the tail of a restore)
SELECT relid::regclass, phase, blocks_done, blocks_total, tuples_done, tuples_total
  FROM pg_stat_progress_create_index;
```

Sampling these hourly turns "it's been running 8 hours" into a defensible
statement about whether it was *working* for 8 hours. A steady byte rate is proof
of progress; a flat one across several samples, combined with an idle backend and
no filesystem growth, is real stall evidence.

Do not conclude "stalled" from a single idle snapshot — a backend can be
legitimately idle between phases. Require repeated samples showing no movement.

## Distinguishing a stall from slow work

A duration that seems impossibly long is worth decomposing before accepting its
label. Useful discriminators:

- **Compare the same operation across runs.** If one run checked an index in 0.002s
  and another took 1,134s, that inconsistency points at a client-side stall (a
  buffered-pipe deadlock, a hung reader), not at genuinely slow verification.
- **Cross-check the resource trace.** A "671s timeout" that the filesystem trace
  shows as 71s of real growth followed by 600s of flatness is a 71s success plus a
  stall on something trivial afterward — a completely different problem than a slow
  operation.
- **Name the actual cap in every timeout message.** Timeouts are usually
  per-call-site, not uniform. An error saying only "timed out" sends the next
  person looking in the wrong place; "probe-hash timed out after its 3600s cap" does
  not.

## Cold cache after a restart

A restore or a server restart empties the page cache. A read-only suite that took
151s against a warm database can blow a 10-minute timeout on identical data cold.
Budget cold-cache time after any restart or restore rather than reusing a warm
measurement, and before relaunching anything, check for an orphaned runner from the
previous attempt.

## Don't poll tightly

Repeatedly checking every few seconds burns effort and does not make the job
finish sooner. Prefer an hourly snapshot to a file (which a fresh session can read
at any time) over frequent interactive checks. When you do check in, read the
artifacts — log, status sidecar, progress log — rather than re-deriving state.
