---
name: postgres-backup-restore
description: >-
  PostgreSQL backup, verification, restore, and cutover — producing a dump you can
  actually trust, restoring it safely, and swapping a restored database into place.
  Use this whenever the user mentions pg_dump, pg_restore, pg_basebackup, database
  backup, restoring or reloading a database, verifying a backup, disaster recovery,
  dump-and-reload migration, or copying a database to another machine. Also use it
  when a task implies those operations without naming them — "make a copy of the
  database", "can we roll this back", "get this data onto the other server", "fix
  the collation version warning", "we need a snapshot before this migration",
  "change shared_preload_libraries", "ALTER SYSTEM", "does this setting need a
  restart". Load
  it BEFORE running any pg_dump or pg_restore command, not after: several of its
  safeguards exist to prevent silent, unrecoverable mistakes, most notably that
  sudo strips PGHOST/PGPORT so a dump can quietly target the wrong database.
---

# PostgreSQL backup, restore, and cutover

Backup and restore work has an unusual risk profile: the commands are short, they
look like they worked, and the failure modes are silent. A dump can name the wrong
database. A checksum file can exist without ever having been checked. An exit code
can belong to a different command than the one you care about. None of these
announce themselves — you discover them when you need the backup and it isn't
there.

So the organizing idea of this skill is **prove each claim separately, from
outside the thing making the claim.** A tool reporting its own success is not
evidence.

## Load the reference you need

Read only what the task requires:

| Task | Reference |
|---|---|
| Taking a dump, verifying it is trustworthy | `references/backup.md` |
| Restoring, post-restore verification, swapping into production | `references/restore.md` |
| Anything expected to run longer than ~20 minutes | `references/long-running.md` |
| Changing a server-level setting (`shared_preload_libraries`, anything needing `ALTER SYSTEM` or a restart) | `references/config-changes.md` |

Two bundled scripts save reinventing fiddly work:

- `scripts/verify_pg_dump.sh` — runs the full backup verification chain and prints
  a pass/fail line per check.
- `scripts/pg_watch_job.sh` — detached watchdog that proves a long job is still
  alive and logs progress, and shouts if the process dies without finishing.

## The four invariants

These apply to every task in this skill. Everything else is detail.

### 1. Prove which database you are connected to — before and after

The highest-consequence mistake in this area is operating on the wrong database
while believing you are on the right one. It is easy because connection targets
come from ambient state (environment variables, defaults, sockets) rather than from
anything visible in the command.

The specific trap worth memorizing: **`sudo` strips the environment by default.**
So this looks correct and is not:

```bash
export PGHOST=/path/to/clone/socket PGPORT=55432
sudo -u postgres pg_dump -d mydb ...   # connects to the DEFAULT socket, not yours
```

The exported variables never reach `pg_dump`. If the default socket is production,
you just dumped production while believing you dumped a clone. Pass connection
target as **explicit flags** (`-h`, `-p`) so it is visible in the command and
survives privilege changes.

Then verify rather than assume, by asking the server what it is:

```bash
psql -h <host> -p <port> -d <db> -Atc \
  "select current_setting('data_directory'), current_setting('port'), pg_is_in_recovery()"
```

Run it against both the intended target *and* the default, and confirm they
differ as expected. Two databases can share a name, a version, and even a system
identifier (a physical clone does), so name alone proves nothing — the data
directory does.

On systems that retain multiple logical environments or data generations, even
the data directory, port, database name, and approximate size may not identify
the intended dataset. Derive the expected environment or generation from the
authorized operation (for example, a reviewed service manifest or run receipt),
pass it as an explicit parameter, and query a project-specific live marker before
starting. Require exactly one matching marker and stop on absence, mismatch, or
ambiguity. Never infer the target by selecting the highest generation number or
the newest-looking schema: retained or partially built generations make that a
guess, not proof.

While a dump or restore is running, you can also confirm the load landed where you
intended:

```sql
SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'pg_dump%';
```

Non-zero on the intended database and zero elsewhere is real evidence.

### 2. A backup is not verified until something has read it back

Each of these proves strictly less than it appears to:

- **`pg_dump` exit 0** — the process didn't crash. Nothing about content.
- **A `SHA256SUMS` file exists** — checksums were *computed while writing*. That
  is not the same as re-reading the bytes and finding them intact. You must run
  `sha256sum -c` to learn anything.
- **`pg_restore --list` succeeds** — the archive's table of contents parses. It
  does not read the data blocks.

The only check that proves the data is usable is **restoring some of it and
comparing row counts against the source.** For a large database, pick a few
mid-sized tables rather than the biggest one; the goal is proof of readability, not
completeness. If a full restore is affordable, that is strictly better and
doubles as a rehearsal.

Also sanity-check the artifact size against a known-good previous backup. A dump
that is much *smaller* than expected is a red flag worth stopping for; larger is
usually just growth.

`references/backup.md` has the full chain.

### 3. Never trust an exit code you did not isolate

Shell mechanics routinely report the wrong command's status:

```bash
some_operation; echo "done"           # $? is echo's, always 0
some_operation && git commit ...      # commit runs, chain reports only the last status
( long_job ) > log 2>&1 &             # backgrounded: wrapper status, not job status
```

When an operation matters, capture its status immediately and separately:

```bash
pg_restore ... ; rc=$?; echo "pg_restore exit: $rc"
```

For anything backgrounded, have the job itself write its real exit code into a log
or status file, and read *that* — not whatever the harness reports about the
wrapper. This is the same reasoning as invariant 2: the outer layer's success is
not the inner operation's success.

### 4. Measure disk from `df`, and know what actually needs to be free

Two independent errors are common here.

**`du` can be wildly wrong.** On copy-on-write filesystems (XFS with reflink, ZFS,
Btrfs), snapshots and reflinked copies share extents, and `du` is not
extent-aware. Real case: `du` reported 2.7 TB for snapshot directories on a 1.9 TB
filesystem — an impossible number whose true cost was ~70 GB. Only a **`df`
before/after delta** tells the truth about reclaimed or consumed space.

Related: space reclaim after a large delete is **asynchronous** on such
filesystems. Free space keeps climbing for minutes after `rm` returns. Don't
record the first reading as final.

**Free space needed is the size of the new copy, not the total of everything.**
When restoring alongside an existing database, the existing one already occupies
its space; it does not need to be freed again. Comparing "total disk used by
everything when finished" against "free space now" double-counts it and invents a
crisis. What must fit in free space is the *new* object plus transient overhead.

On transient overhead: index rebuilds and WAL do consume extra space during a
restore, but empirically far less than intuition suggests — in one measured 439 GB
restore, hourly `df` sampling never rose above the final size, and the index-build
phase added only ~6 GB. Budget a modest margin, but measure rather than assuming a
large multiplier.

## Cross-database verification: two catalogs that will mislead you

When comparing two databases (source vs restored, clone vs production), two
convenient queries give confidently wrong answers:

**`information_schema.tables` hides what the querying role cannot see.** A
restricted read-only role gets a silently shortened list, which reads as "these
tables are missing." Use `to_regclass('schema.table')` instead — it does not
require table-level privileges:

```sql
SELECT to_regclass('public.my_table');   -- NULL only if genuinely absent
```

**`pg_class.reltuples` is a stale planner estimate, not a count.** It produced
apparent 8% row-count "gaps" between two databases that were in fact identical.
For any comparison you intend to act on, use exact `count(*)` — or run `ANALYZE`
first if an estimate is genuinely good enough.

A corollary worth internalizing: **reading source code or migration files is not
verification of live state.** A table count derived by reading `CREATE TABLE`
statements across migrations was wrong twice — it included tables never actually
created and omitted tables created outside those migrations. The live catalog is
the authority.

## Restores are I/O-heavy enough to break unrelated things

A large restore saturates its disk and, less obviously, **evicts the page cache**
— it pushes hundreds of gigabytes through shared memory, displacing the working
set other queries depend on. So other users of the same disk get hit twice: their
fast path is gone and the slow path is congested.

Consequences worth planning around:

- Queries elsewhere on that filesystem can slow by an order of magnitude. Anything
  with a timeout — a web build, a health check, a cron job — may fail while the
  restore runs, and its failure will look unrelated.
- Freezing application *writes* does not stop *reads* or scheduled builds. If
  something must not run during the window, disable it explicitly.
- Check whether the target and source share a device (`df` the paths, and follow
  symlinks — a data directory under `/var/lib/postgresql` is often a symlink
  elsewhere). Reading from one disk and writing to another is much kinder than
  both on one.

## When someone asks to "fix a collation version mismatch"

This comes up often enough to state plainly, because the mechanism explains the fix.

The warning (`database was created using collation version 2.43, but the operating
system provides 2.44`) means the OS string-sorting library changed under an
existing database. Indexes on text are physically ordered by the old rules, so
lookups can miss rows. Nothing is corrupted — heap data is untouched.

Two remedies, and the choice is about downtime versus rollback:

- **`REINDEX` (optionally `CONCURRENTLY`)** rebuilds indexes in place. Fast,
  stays online with `CONCURRENTLY`, but mutates the live database — rollback means
  restoring a backup.
- **Dump and reload** into a fresh database. A logical dump stores no index
  contents, only `CREATE INDEX` statements, so the restore rebuilds every index
  under the current library and a newly created database records the current
  version. Correct by construction. It also reclaims bloat. But it requires a
  write freeze for the whole dump+restore+swap, and the dump is a point-in-time
  snapshot — **writes after the dump starts are lost**, not merely delayed.

Two useful facts: an existing logical dump taken from a mismatched database
restores *clean* (the defect cannot be baked into a `pg_dump`), and `pg_dump`
itself is trustworthy despite suspect indexes because it reads via sequential
scan, never through an index.

**Row counts do not verify a collation repair.** Counting rows never touches a
text index, so identical counts prove the data survived and say nothing about
whether lookups still find it — which is the whole defect. Add a
search-equivalence pass: run identical queries against old and new, and
classify the outcomes three ways, because they mean different things.
*Different rows* is the catastrophic case (and if the NEW database returns
*fewer*, stop — do not swap). *Same rows in a different order* is expected and
benign; the sorting rules genuinely changed. *Identical* is clean. Target
full-text/GIN indexes, trigram and unaccent expression indexes, text
equality/range/`ORDER BY`, prefix `LIKE`, and rows containing accented or
punctuation-heavy text, since that is where library versions disagree.

Finally, **finding no difference is a legitimate result, not a wasted effort.**
One production cutover at this scale ran 111 such comparisons and got 111
identical with zero ordering differences — the drift was real and worth closing,
but had never fired on that corpus's actual character sequences. Report that as
proof obtained, not as a null finding.

See `references/restore.md` for the swap procedure, the mandatory post-restore
`ANALYZE`, and the rollback.

## Log what you did

Operational database work is worth a durable record, because the next person to
touch it — often you, months later — cannot reconstruct intent from the data. If
the project has a log convention, follow it. If not, capture at minimum: who
directed the operation, **which PostgreSQL role executed it**, what changed about
object visibility or permissions, and pointers to the evidence (paths, checksums,
timings). Executing role and visibility are the two fields people omit and later
need most.
