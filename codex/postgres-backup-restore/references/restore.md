# Restoring, verifying, and swapping into production

## Create the target from `template0`

`CREATE DATABASE` copies a template. On a cluster with a collation version
mismatch this is not a style preference — **PostgreSQL hard-refuses to create a
database from a template whose recorded collation version disagrees with the OS**:

```
ERROR:  template database "template1" has a collation version mismatch
```

`template0` is the pristine, connection-barred template and carries no recorded
version, so it works and the new database is stamped with the *current* version:

```sql
CREATE DATABASE mydb_new TEMPLATE template0;
```

Verified behavior on a mismatched cluster: the `template1` attempt errors before
creating anything; the `template0` attempt succeeds and reads `2.44` (current)
rather than inheriting the stale value. Default to `template0` for any restore
target — it costs nothing when there is no mismatch and is the only thing that
works when there is.

Check what your cluster records:

```sql
SELECT datname, datcollate, datcollversion FROM pg_database ORDER BY datname;
```

`template0` normally shows an empty `datcollversion`. If your restore target ends
up with a stale version anyway (possible if you restored into a pre-existing
database), fix it after verifying the indexes were rebuilt:

```sql
ALTER DATABASE mydb_new REFRESH COLLATION VERSION;
```

## Where restores put their bytes

A single database is **not** portable at the filesystem level — it lives as a
numbered directory under `base/` and depends on the cluster's shared catalogs and
WAL. You cannot copy one database's directory to another machine and use it.

To place a database on a different filesystem, use a tablespace:

```sql
CREATE TABLESPACE slow_ts LOCATION '/mnt/other_disk/pg_slow_ts';
ALTER DATABASE mydb_new SET TABLESPACE slow_ts;   -- requires no connections
```

This is also the way to restore onto a different disk than the live database,
which reduces I/O contention (see SKILL.md's section on restores starving other
work). The tradeoff is that the database then runs at that disk's speed.

## Running the restore

```bash
pg_restore -d mydb_new -j 12 /backups/mydb.pgdir ; rc=$?; echo "pg_restore exit: $rc"
```

Choices worth making deliberately:

- **`-j N`** parallelizes across tables and for index builds. It cannot split one
  table's `COPY`, so a database dominated by one huge table will spend a long tail
  single-threaded regardless of `N`. Adding workers will not shorten that.
- **Omit `--no-owner --no-privileges`** when you intend to verify that ownership
  and grants survive — those flags discard exactly what you are testing. Include
  them only for a throwaway scratch restore where you don't care.
- Roles are **cluster-level**, so a single-database dump does not carry them.
  Restoring into the same cluster keeps them; restoring into a *fresh* cluster
  needs `pg_dumpall --globals-only` first, or ownership/grants will fail to apply.

Anything at this scale should run detached with a watchdog — see
`references/long-running.md`.

Expect a rough shape of roughly two-thirds data load and one-third index rebuilds,
though this varies with how index-heavy the schema is. A measured 439 GB restore
took 8h41m: ~6.5h load (bottlenecked on one dominant table) and ~2h index builds.

## Rebuild statistics before the database serves traffic

**PostgreSQL 18's `pg_dump` emits no planner statistics by default**, so a
restored database starts out statistics-blind no matter how cleanly the restore
ran. The planner then picks catastrophic plans — a full-text query that used an
index on the source falls back to a sequential scan of the whole table — and the
resulting timeouts look like an application regression, not a missing `ANALYZE`.
Any deliberately tuned `attstattarget` is likewise inert until it is rebuilt.

```bash
vacuumdb --analyze-in-stages -j 12 -d mydb_new   # usable stats in minutes, then refines
vacuumdb --analyze            -j 12 -d mydb_new   # full quality at the tuned target
```

Budget it as a real phase: on a 439 GB database this took **3h 30m**, with the
largest table's TOAST relation as the long pole. It is easy to omit from a
cutover estimate because neither the dump nor the restore mentions it. It also
drains autovacuum's queue, which helps a subsequent rename win its race.

(`pg_dump --statistics` can carry them instead, but check whether the tooling
you're using actually passes it — a wrapper script usually doesn't.)

## Post-restore verification

Do all of this **before** any swap. Everything to this point is reversible — the
original database is untouched — so a failure here costs only time.

**Budget for a cold cache.** A restore leaves the new database's pages
uncached, so the same verification query can be orders of magnitude slower
there than against warm production — measured 1.7s vs **2m25s** for one
`count(*)` over ~1M full-text matches. Set verification timeouts generously;
a timeout reported as an error reads as a defect in the restore when it is
only an artifact of measuring cold data. Prefer bounded, selective queries
that return identifiers over aggregate counts: they finish in a fraction of
the time *and* say more, because a missing row is visible as a missing id
rather than hidden inside a total.

**1. Collation version landed current.**

```sql
SELECT datname, datcollversion FROM pg_database WHERE datname IN ('mydb','mydb_new');
```

If the point of the exercise was repairing drift, the new database should read the
OS's current version while the old one still reads the stale one.

**2. Exact row counts match, per table.** Use `count(*)`, not `reltuples`. Cover
the largest tables at minimum; all tables if affordable.

**3. Table set matches.** Enumerate from both databases and diff. Sort with the
same collation on both sides, or byte-sort both, before comparing — otherwise
`comm` reports spurious differences:

```bash
psql -d mydb     -Atc "select schemaname||'.'||tablename from pg_tables where schemaname in ('public')" | sort > /tmp/a
psql -d mydb_new -Atc "select schemaname||'.'||tablename from pg_tables where schemaname in ('public')" | sort > /tmp/b
comm -23 /tmp/a /tmp/b   # in old, missing from new  <- must be empty
comm -13 /tmp/a /tmp/b   # in new, not in old
```

For individual existence questions use `to_regclass()`, not
`information_schema.tables` (see SKILL.md).

**4. Ownership and grants survived.**

```sql
SELECT tableowner, count(*) FROM pg_tables
 WHERE schemaname NOT IN ('pg_catalog','information_schema') GROUP BY 1 ORDER BY 2 DESC;

SELECT grantee, count(*) FROM information_schema.role_table_grants
 WHERE table_schema NOT IN ('pg_catalog','information_schema') GROUP BY 1 ORDER BY 2 DESC;
```

Compare shapes between old and new. Investigate differences, but expect some to be
legitimate — grants on extension-provided views, or objects added to one database
after the dump was taken. Distinguish "the restore lost this" from "the source
never had it" before calling anything a defect.

Pay attention to column-level grants and `SECURITY DEFINER` function ownership:
these are the fiddly parts. A broad table-level `REVOKE` applied after a narrow
column grant will clear it, and a `SECURITY DEFINER` function is only safe if its
owner actually holds the underlying table privilege.

**5. Extensions present.**

```sql
SELECT extname FROM pg_extension ORDER BY 1;
```

**6. Application smoke test.** Point a disposable config at the restored database
and exercise real read paths. A schema can verify perfectly and still be wrong in a
way only the application notices.

## The swap

Rename-based cutover, because it is atomic-ish, fast, and trivially reversible:

```sql
ALTER DATABASE mydb     RENAME TO mydb_old;
ALTER DATABASE mydb_new RENAME TO mydb;
```

Both require **no active connections** to the database being renamed. Stop or drain
the application first. `DROP DATABASE ... WITH (FORCE)` exists for terminating
stragglers, but there is no `RENAME ... FORCE` — you must actually clear
connections.

**Retain `mydb_old` until you are confident.** It is the rollback: rename the pair
back and you are exactly where you started, in seconds. This is the main advantage
of dump-and-reload over in-place `REINDEX`, which offers no comparable undo. Drop
it only after the application has run normally for a while:

```sql
DROP DATABASE mydb_old;
```

## The write-freeze arithmetic

If you are swapping in a restored copy, `pg_dump` captured the source as of the
instant it *started*. Every write between that instant and the swap is **lost, not
delayed**:

```
T0        dump starts     <- snapshot frozen here
T0+A      dump ends
T0+A+B    restore ends
T0+A+B+C  verified, swap
```

Writes in the whole `A+B+C` window are gone unless the source was read-only
throughout. So the freeze is not "how long is the outage" but "how long must
writes be refused," and it spans dump *plus* restore *plus* verification *plus*
cutover. Budget all four, and confirm with the owner that a freeze of that length
is acceptable before starting — this is a decision about data loss, not just
downtime.

Also remember that freezing writes does not stop reads, scheduled builds, or
crawlers. If something on a timer must not run during the window, disable it
explicitly.

## Dropping databases

```sql
DROP DATABASE mydb_old WITH (FORCE);
```

`WITH (FORCE)` terminates existing connections. Autovacuum workers frequently hold
one after a large restore, which otherwise blocks the drop for no good reason.
Check what is connected before forcing, so you don't terminate something that
matters:

```sql
SELECT pid, usename, backend_type, state, left(query,60)
  FROM pg_stat_activity WHERE datname = 'mydb_old';
```

Confirm reclaimed space with a `df` delta, and remember it may be asynchronous.
