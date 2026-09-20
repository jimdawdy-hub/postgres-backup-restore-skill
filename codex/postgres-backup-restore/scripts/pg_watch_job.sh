#!/usr/bin/env bash
# Watchdog for a long-running detached PostgreSQL job (dump, restore, checksum pass).
#
# Why this exists: the obvious watchdog — "loop until a completion marker appears"
# — waits forever if the job dies, because absence of a completion signal is
# equally consistent with "still working", "finished", and "killed". This script
# checks that the process actually exists on every tick and makes a silent death a
# conspicuous artifact in a file instead of a notification that never arrives.
#
# It also records the OS's own elapsed time each tick, so the log doubles as
# independent duration evidence that survives the observing session dying.
#
# Usage:
#   pg_watch_job.sh <wrapper_pid> <job_log> <progress_log> <done_marker> [database] [interval_secs]
#
# Example:
#   ./pg_watch_job.sh 12345 /backups/job.log /backups/job_progress.log JOB_DONE mydb_new 3600
#
# Launch it detached so it outlives the shell that started it:
#   setsid --fork ./pg_watch_job.sh 12345 /backups/job.log /backups/progress.log JOB_DONE mydb_new 3600
#
# Reading the result later:
#   grep -c 'LIVE:'                       -> how many ticks saw the job alive
#   grep 'logger exiting cleanly'         -> finished normally
#   grep 'ALERT_PROCESS_GONE'             -> died without finishing; tail of job log follows

set -uo pipefail

if [ "$#" -lt 4 ]; then
  echo "usage: $0 <wrapper_pid> <job_log> <progress_log> <done_marker> [database] [interval_secs]" >&2
  exit 2
fi

WRAPPER_PID="$1"
JOB_LOG="$2"
PROGRESS_LOG="$3"
DONE_MARKER="$4"
DATABASE="${5:-}"
INTERVAL="${6:-3600}"

# psql is optional: without a database, this still does liveness + disk, which is
# the part that prevents an indefinite wait.
psql_snapshot() {
  [ -n "$DATABASE" ] || return 0
  command -v sudo >/dev/null 2>&1 || return 0

  echo "-- pg_stat_progress_copy --"
  sudo -n -u postgres psql -d "$DATABASE" -Atc \
    "select relid::regclass, command, pg_size_pretty(bytes_processed), tuples_processed
       from pg_stat_progress_copy;" 2>/dev/null

  echo "-- pg_stat_progress_create_index --"
  sudo -n -u postgres psql -d "$DATABASE" -Atc \
    "select relid::regclass, phase, blocks_done, blocks_total, tuples_done, tuples_total
       from pg_stat_progress_create_index;" 2>/dev/null

  return 0
}

while true; do
  # Check for completion FIRST: if the job finished between ticks, that is a clean
  # exit, not a death, even though the process is now gone.
  if grep -q "$DONE_MARKER" "$JOB_LOG" 2>/dev/null; then
    {
      echo "=== $(date --iso-8601=seconds) === completion marker found, logger exiting cleanly"
    } >> "$PROGRESS_LOG" 2>&1
    exit 0
  fi

  # The process is gone but never wrote its marker. This is the case the naive
  # watchdog cannot distinguish, so make it loud and self-contained: whoever reads
  # this file later should not need the original session's context.
  if ! ps -p "$WRAPPER_PID" > /dev/null 2>&1; then
    {
      echo "=== $(date --iso-8601=seconds) ==="
      echo "ALERT_PROCESS_GONE_NO_COMPLETION_MARKER: pid $WRAPPER_PID is no longer"
      echo "running, but $JOB_LOG contains no '$DONE_MARKER'. The job most likely died"
      echo "(OOM kill, lock conflict, or an error before it could write its marker)."
      echo "Last 30 lines of $JOB_LOG:"
      tail -30 "$JOB_LOG" 2>/dev/null
    } >> "$PROGRESS_LOG" 2>&1
    exit 1
  fi

  {
    echo "=== $(date --iso-8601=seconds) ==="
    echo "LIVE: pid $WRAPPER_PID running, elapsed $(ps -p "$WRAPPER_PID" -o etime= 2>/dev/null | tr -d ' ')"
    psql_snapshot
    echo "-- disk --"
    df -h 2>/dev/null | awk 'NR==1 || /^\/dev\//'
    echo ""
  } >> "$PROGRESS_LOG" 2>&1

  sleep "$INTERVAL"
done
