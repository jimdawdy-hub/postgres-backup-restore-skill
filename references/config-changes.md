# Server-level config changes: restart timing and the multi-value GUC trap

This is a different risk shape from backup/restore: no data moves, but a single
malformed statement can leave the server refusing to start, with no data at risk and
no restore to fall back to — the fix is a config edit, but the server has to be down
to make it.

## Find out where a setting actually comes from before editing anything

`ALTER SYSTEM` writes `postgresql.auto.conf`, which PostgreSQL reads **last**, so it
silently overrides `postgresql.conf`. A project's `postgresql.conf` can have a setting
present, commented out, or stale, while the live value comes from `auto.conf` — editing
the file you happen to be looking at, without checking, can be a no-op that still costs
you a restart.

```sql
SELECT name, setting, context, sourcefile, sourceline
FROM pg_settings WHERE name = '<setting>';
```

`sourcefile` is the authority. `context` tells you the second thing you need before
promising anything about downtime:

- `sighup` — `SELECT pg_reload_conf();` applies it with no restart.
- `postmaster` — takes effect only on a full restart. A reload silently does nothing;
  the GUC will still read the old value until the process restarts.

## The multi-value GUC trap

Some GUCs — `shared_preload_libraries` is the one that bites most often — take a
**list** of values, and the natural-looking single-string form is fatal:

```sql
-- Written to disk as shared_preload_libraries = '"a,b"'.
-- PostgreSQL reads the whole quoted string as ONE library literally named "a,b".
-- The server then REFUSES TO START.
ALTER SYSTEM SET shared_preload_libraries = 'a,b';

-- Correct: each element is its OWN value.
ALTER SYSTEM SET shared_preload_libraries = 'a', 'b';
```

The failure is loud and unambiguous once it happens —
`FATAL: could not access file "a,b": No such file or directory` — but it only
surfaces on the next restart, by which point the server is already down and the
statement that caused it can no longer be un-run through SQL, because there is no
running server to send SQL to.

**Recovery is a hand-edit with the server stopped**, not another `ALTER SYSTEM`:

```bash
# server is down; ALTER SYSTEM is unreachable
sudo cp postgresql.auto.conf.pre-change-backup postgresql.auto.conf
sudo systemctl start postgresql.service
```

This is why a dated backup of `postgresql.auto.conf` before the edit (mirroring the
dump-verification discipline elsewhere in this skill) is not optional here — it is the
entire rollback plan.

## Rehearse on a disposable cluster — and it must be a separate SERVER, not a database

Invariant 1 in `SKILL.md` rehearses backup/restore risk with a scratch *database*.
That does not work here. A `postmaster`-context setting like `shared_preload_libraries`
belongs to the whole server process, not to any one database inside it — a second
database in the *same* running server never gets its own startup, so it can never prove
whether a startup-time change is safe. You need a second **server**: its own `initdb`
data directory, its own postmaster, its own port.

```bash
sudo -u postgres initdb -D /tmp/pg-rehearsal --auth=peer
# append to postgresql.conf: port = 55433; listen_addresses = ''
sudo -u postgres pg_ctl -D /tmp/pg-rehearsal -l /tmp/pg-rehearsal/server.log start
```

For a config-only change like this, the scratch cluster does not need any real data —
the entire risk under test is startup behavior, which is independent of what's inside
the database. An empty cluster tests strictly as much as a full data clone would, at a
fraction of the setup cost.

Prove the change on the scratch cluster in this order, and deliberately include the
failure case — don't just prove the happy path:

1. Match the scratch cluster's starting `shared_preload_libraries` to the real target's
   current value, so the "append" step is a real test, not a no-op.
2. Apply the intended `ALTER SYSTEM` statement, restart, confirm it starts and the new
   GUCs appear.
3. **Break it on purpose** with the wrong (single-string) syntax, confirm the server
   actually refuses to start, then recover with the hand-edit above. This is the drill
   that matters — proving the statement is correct is necessary but proving recovery
   works if it *weren't* is what actually de-risks touching production.
4. If a library adds a background worker (e.g. `pg_prewarm`'s `autoprewarm`), don't
   trust a `pg_stat_activity` `backend_type` check alone — some such workers don't
   register a matching type there even while running correctly. Prove function with an
   artifact the worker itself produces (a dump file, a log line) and, ideally, a second
   restart that shows the feature's actual effect end to end.

## Gotchas

- **A `pg_reload_conf()` "success" proves nothing for a `postmaster`-context setting.**
  It will report success and change nothing. Check `context` before believing a reload
  applied anything.
- **Don't assume `postgresql.conf` is authoritative just because it's the file you can
  see change history for.** `postgresql.auto.conf` wins, is often owned by `postgres`
  with no write access for anyone else, and is easy to forget exists.
- **A later, unrelated `ALTER SYSTEM` on a different setting can rewrite the whole
  `postgresql.auto.conf` file** (it's fully regenerated each time) — verify a
  previously-set list-valued GUC survived if you're stacking multiple config changes
  in one session, rather than assuming it's untouched.
