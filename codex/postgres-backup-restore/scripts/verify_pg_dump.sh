#!/usr/bin/env bash
# Verify a pg_dump artifact, printing one PASS/FAIL line per check.
#
# Why this exists: the checks that feel like verification mostly aren't. A dump
# exiting 0 says the process didn't crash. A SHA256SUMS file existing says hashes
# were computed *while writing* — not that the bytes can be read back. Only
# re-reading the checksums and restoring some data proves anything, and those are
# exactly the steps people skip because the earlier ones already felt conclusive.
#
# This automates the mechanical checks (1-3, 5). Check 4 — restore-and-count — needs
# a live database and a judgment call about which tables to sample, so it stays
# manual; see references/backup.md.
#
# Usage:
#   verify_pg_dump.sh <artifact> [expected_min_bytes]
#
#   <artifact>            path to the .pgdir directory or .dump/.sql file
#   [expected_min_bytes]  optional floor; a dump much smaller than a known-good
#                         previous one is the red flag worth stopping for
#
# Example:
#   ./verify_pg_dump.sh /mnt/backup_db/mydb_2026-08-04.pgdir 200000000000
#
# Exit codes: 0 = all attempted checks passed, 1 = at least one failed.
# On slow media the checksum pass reads the entire artifact and can take a long
# while; run this detached rather than skipping it.

set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <artifact> [expected_min_bytes]" >&2
  exit 2
fi

ARTIFACT="$1"
EXPECTED_MIN="${2:-0}"
FAILED=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILED=1; }
skip() { printf 'SKIP  %s\n' "$1"; }

if [ ! -e "$ARTIFACT" ]; then
  fail "artifact exists: $ARTIFACT not found"
  exit 1
fi
pass "artifact exists: $ARTIFACT"

BASE="${ARTIFACT%.pgdir}"
STATUS_FILE="${BASE}.status"
VERIFY_FILE="${BASE}.verify"
SUMS_FILE="${BASE}.SHA256SUMS"

# --- 1. status/verify sidecars (only meaningful if the tooling writes them) ---
if [ -f "$STATUS_FILE" ]; then
  if [ "$(tr -d '[:space:]' < "$STATUS_FILE")" = "OK" ]; then
    pass "status sidecar reads OK"
  else
    fail "status sidecar reads '$(tr -d '[:space:]' < "$STATUS_FILE")' (expected OK)"
  fi
else
  skip "status sidecar absent (not all tooling writes one)"
fi

if [ -f "$VERIFY_FILE" ]; then
  if head -1 "$VERIFY_FILE" | grep -q "VERIFY_OK"; then
    pass "verify sidecar reads VERIFY_OK"
  else
    fail "verify sidecar does not start with VERIFY_OK"
  fi
else
  skip "verify sidecar absent"
fi

# --- 2. archive table of contents parses ---
# Proves the TOC is readable. Does NOT read data blocks — that's check 4.
if command -v pg_restore >/dev/null 2>&1; then
  if pg_restore --list "$ARTIFACT" > /dev/null 2>&1; then
    TOC_COUNT=$(pg_restore --list "$ARTIFACT" 2>/dev/null | grep -c 'TABLE DATA' || true)
    pass "pg_restore --list parses ($TOC_COUNT TABLE DATA entries)"
  else
    fail "pg_restore --list could not parse the archive"
  fi
else
  skip "pg_restore not on PATH"
fi

# --- 3. checksums RE-READ (the step that actually proves readability) ---
if [ -f "$SUMS_FILE" ]; then
  MANIFEST_LINES=$(wc -l < "$SUMS_FILE" | tr -d ' ')
  if [ -d "$ARTIFACT" ]; then
    CHECK_OUT=$( cd "$ARTIFACT" && sha256sum -c "$SUMS_FILE" 2>&1 )
    CHECK_RC=$?
  else
    CHECK_OUT=$( cd "$(dirname "$ARTIFACT")" && sha256sum -c "$SUMS_FILE" 2>&1 )
    CHECK_RC=$?
  fi
  OK_COUNT=$(printf '%s\n' "$CHECK_OUT" | grep -c ': OK$' || true)
  BAD_COUNT=$(printf '%s\n' "$CHECK_OUT" | grep -cvE ': OK$' || true)

  if [ "$CHECK_RC" -eq 0 ] && [ "$OK_COUNT" -eq "$MANIFEST_LINES" ] && [ "$MANIFEST_LINES" -gt 0 ]; then
    pass "checksums re-read: $OK_COUNT/$MANIFEST_LINES files OK"
  else
    fail "checksums re-read: $OK_COUNT OK of $MANIFEST_LINES in manifest, $BAD_COUNT not-OK, exit $CHECK_RC"
    printf '%s\n' "$CHECK_OUT" | grep -vE ': OK$' | head -5 | sed 's/^/        /'
  fi

  # A manifest listing far fewer files than the artifact contains would pass
  # trivially, so compare the counts.
  if [ -d "$ARTIFACT" ]; then
    FILE_COUNT=$(find "$ARTIFACT" -type f | wc -l | tr -d ' ')
    if [ "$FILE_COUNT" -eq "$MANIFEST_LINES" ]; then
      pass "manifest covers every file ($FILE_COUNT)"
    else
      fail "manifest covers $MANIFEST_LINES files but artifact contains $FILE_COUNT"
    fi
  fi
else
  skip "no SHA256SUMS manifest found — cannot verify byte integrity"
fi

# --- 5. size sanity ---
ACTUAL_BYTES=$(du -sb "$ARTIFACT" 2>/dev/null | cut -f1)
if [ -n "${ACTUAL_BYTES:-}" ]; then
  HUMAN=$(numfmt --to=iec-i --suffix=B "$ACTUAL_BYTES" 2>/dev/null || echo "${ACTUAL_BYTES} bytes")
  if [ "$EXPECTED_MIN" -gt 0 ]; then
    if [ "$ACTUAL_BYTES" -ge "$EXPECTED_MIN" ]; then
      pass "size $HUMAN meets floor"
    else
      fail "size $HUMAN is BELOW the $EXPECTED_MIN-byte floor — investigate before trusting this backup"
    fi
  else
    skip "size is $HUMAN (no floor given; compare against a known-good backup)"
  fi
fi

echo ""
echo "NOT CHECKED HERE: restore-and-count. Nothing above reads the data blocks, so"
echo "restore a few mid-sized tables into a scratch database (createdb -T template0)"
echo "and compare exact count(*) against the source. See references/backup.md step 4."

exit "$FAILED"
