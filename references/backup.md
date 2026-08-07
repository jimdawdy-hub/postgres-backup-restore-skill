# Taking a PostgreSQL backup you can trust

## Choosing a format

| Format | Command | Use when |
|---|---|---|
| Directory, parallel | `pg_dump -Fd -j N` | Default for anything large. Dumps many tables concurrently. Artifact is a *directory*, not one file. |
| Custom | `pg_dump -Fc` | Single-file logical dump, selective restore, no parallel dump. |
| Plain SQL | `pg_dump -Fp` | Small databases, human-readable diffs, or when the target may be a different major version. |
| Physical | `pg_basebackup` | You need a byte-identical cluster copy (replica, PITR base). Copies index files as-is, so it *preserves* collation drift rather than fixing it. |

A caution on parallel dumps: `-j N` parallelizes **across** tables, never within
one. A single dominant table is one worker's job start to finish, so a database
where one table is most of the volume gets far less than an N× speedup. Measure
before promising a duration.

## Deciding logical vs physical

The distinction matters more than it looks:

- **Logical** (`pg_dump`) stores data plus *instructions* to rebuild indexes.
  Restoring rebuilds indexes under current library versions and current settings.
  This is why a logical round-trip repairs collation drift and reclaims bloat.
- **Physical** (`pg_basebackup`) copies data files, index files, and cluster
  metadata verbatim. Faster and exact, but inherits every physical characteristic
  of the source — including a collation version mismatch and accumulated bloat.

If your goal is "a clean copy," logical. If it's "an identical cluster," physical.

## Target the right database — explicitly

Pass the connection as flags, never via exported environment variables, if any
privilege change (`sudo`, `su`, a systemd unit, a container entrypoint) sits between
your shell and `pg_dump`. See invariant 1 in SKILL.md for the failure mode.

```bash
pg_dump -h /path/to/socket -p 55432 -d mydb -Fd -j 12 --compress=lz4:1 -f /backups/mydb.pgdir
```

If you are wrapping this in a script that escalates privilege, make host and port
first-class parameters of the script rather than relying on inherited environment,
and echo the resolved target into the log so the receipt proves what was dumped:

```bash
echo "server: ${PGDUMP_HOST:-<default socket>}:${PGDUMP_PORT:-<default port>}"
```

Confirm the target before starting (invariant 1's probe), and while it runs:

```sql
SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'pg_dump%';
```

## Naming

Include something that distinguishes *why* this backup exists, not only the date.
`mydb_2026-08-04.pgdir` collides with any other same-day backup and tells a future
reader nothing. `mydb_2026-08-04-pre-migration.pgdir` survives both problems.

## Verification chain

Run `scripts/verify_pg_dump.sh <artifact>` for the mechanical parts, or do it by
hand in this order. Each step proves something the previous one does not — see
invariant 2.

**1. Real exit code.** Captured immediately, not inferred from a wrapper.

```bash
pg_dump ... ; rc=$?; echo "pg_dump exit: $rc"
```

**2. Archive parses.**

```bash
pg_restore --list /backups/mydb.pgdir > /dev/null && echo "TOC OK"
```

Optionally compare the `TABLE DATA` entry count against a table count taken on the
source just before the dump.

**3. Checksums re-read.** This is the step most often skipped, because a
`SHA256SUMS` file already existing feels like completion. Computing hashes while
writing proves nothing about whether the bytes can be read back.

```bash
cd /backups/mydb.pgdir && sha256sum -c ../mydb.SHA256SUMS; rc=$?; echo "checksum exit: $rc"
```

Expect every line to end `: OK`. Count them and compare against the file count —
a truncated manifest passes trivially. On slow media this reads the entire artifact
and can take a while; run it detached (`references/long-running.md`) rather than
skipping it.

**4. Restore-and-count spot check.** The only step that proves the data is usable.
Restore a few tables into a scratch database and compare exact counts against the
source.

```bash
createdb -T template0 verify_scratch
pg_restore -d verify_scratch -j 3 --no-owner --no-privileges \
  -t medium_table_a -t medium_table_b /backups/mydb.pgdir
```

```sql
SELECT 'medium_table_a', count(*) FROM medium_table_a
UNION ALL SELECT 'medium_table_b', count(*) FROM medium_table_b;
```

Choose mid-sized tables — large enough to be meaningful, small enough to finish.
Use `count(*)`, never `reltuples`. Drop the scratch database afterward.

Note `-T template0`: if the cluster has a collation version mismatch, `CREATE
DATABASE` from `template1` **hard-fails**. See `references/restore.md`.

**5. Size sanity.** Compare against a known-good previous backup. Meaningfully
*smaller* warrants investigation; larger is usually growth. Record exact bytes
(`du -sb`, or the size the tooling reports) rather than a rounded figure.

## Permissions for the restoring account

Backups are often written by one account and read by another (`postgres` restoring
an archive owned by a human user with `0700`). Grant narrow read access rather than
loosening the directory:

```bash
sudo setfacl -R -m u:postgres:rX /backups/mydb.pgdir
```

Then confirm it worked as that account, since a permission problem otherwise
surfaces as a confusing mid-restore failure:

```bash
sudo -u postgres ls /backups/mydb.pgdir >/dev/null && echo "readable"
```

## Retention

Keep at least one verified backup older than your newest one; a corrupt-but-recent
backup plus no older copy is a single point of failure. Prune only after the newer
backup has passed the full chain above, and never as an implicit side effect of a
backup script's normal run — make pruning explicitly opt-in.
