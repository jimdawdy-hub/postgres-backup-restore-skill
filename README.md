# postgres-backup-restore - "How to take a really good dump"

A skill for Claude Code and OpenAI Codex that covers
PostgreSQL backup, verification, restore, and cutover work — producing a dump you
can actually trust, restoring it safely, and swapping a restored database into
production. Database-agnostic: nothing in here assumes any particular schema,
product, or hosting setup.

## Why this exists

Backup and restore work has an unusual risk profile: the commands are short, they
look like they worked, and the failure modes are silent. A dump can name the wrong
database. A checksum file can exist without ever having been checked. An exit code
can belong to a different command than the one you care about. None of these
announce themselves — you discover them when you need the backup and it isn't
there.

This skill's organizing idea is **prove each claim separately, from outside the
thing making the claim.** A tool reporting its own success is not evidence. It
walks the coding agent through the checks that actually matter, in the order they
matter,
and gives it two small scripts so it isn't reinventing fiddly verification logic
each time.

## What's covered

- **Backup** — choosing a dump format, targeting the right database explicitly
  (the `sudo` strips your environment trap), the full verification chain, and
  retention.
- **Restore & cutover** — `template0` vs `template1` on a collation-mismatched
  cluster, rebuilding planner statistics after restore (PG18's `pg_dump` ships
  none by default), post-restore verification, the rename-based swap, and the
  write-freeze arithmetic (writes after the dump starts are *lost*, not delayed).
- **Long-running jobs** — detaching a job so it outlives its launcher, a watchdog
  that distinguishes "still running" from "died silently" from "finished", and
  reading real progress from `pg_stat_progress_copy` / `pg_stat_progress_create_index`
  instead of guessing from elapsed time.
- **Server-level config changes** — the difference between `sighup` and
  `postmaster` GUC context, why `postgresql.auto.conf` silently overrides
  `postgresql.conf`, and the multi-value `ALTER SYSTEM` trap on list-valued GUCs
  like `shared_preload_libraries` that will make PostgreSQL refuse to start.
- **Fixing a collation-version mismatch** — the actual mechanism, both remedies
  (`REINDEX` vs dump-and-reload), and why row counts alone never verify the fix.

## Install for Claude Code

Drop this directory into your Claude Code skills folder:

```bash
git clone https://github.com/jimdawdy-hub/postgres-backup-restore-skill.git \
  ~/.claude/skills/postgres-backup-restore
```

Claude Code picks up skills automatically from `~/.claude/skills/`. See the
[Claude Code skills documentation](https://docs.claude.com/en/docs/claude-code/skills)
for project-scoped installs and other options.

## Install for Codex

The Codex-ready package is under `codex/postgres-backup-restore/`. Copy that
directory into the Codex skills folder:

```bash
git clone https://github.com/jimdawdy-hub/postgres-backup-restore-skill.git \
  /tmp/postgres-backup-restore-skill
mkdir -p ~/.codex/skills
cp -a /tmp/postgres-backup-restore-skill/codex/postgres-backup-restore \
  ~/.codex/skills/
```

Restart Codex after installation so it discovers the new skill.

## Structure

```
SKILL.md                          entry point — read this first
references/
  backup.md                       taking a dump you can trust
  restore.md                      restoring, verifying, swapping into production
  long-running.md                 detaching, watchdogs, distinguishing stall from slow
  config-changes.md               ALTER SYSTEM, GUC context, the multi-value trap
scripts/
  verify_pg_dump.sh               automated backup-verification checks
  pg_watch_job.sh                 detached watchdog for long jobs
evals/
  evals.json                      behavioral test prompts (works with the
                                   skill-creator eval harness)
codex/postgres-backup-restore/    Codex-ready copy of SKILL.md, references,
                                   and scripts
```

`SKILL.md` stays short and points to the reference file each task actually needs —
the agent loads only what's relevant instead of one long document. The root
package and the Codex package intentionally contain the same operational
guidance so safeguards do not drift between agents.

## A note on the numbers in here

A few reference files cite specific measured figures (e.g. "a measured 439 GB
restore took 8h45m", "1.7s warm vs 2m25s cold for one `count(*)`"). These come from
real production operations and are kept because concrete numbers teach the shape
of the problem better than a vague estimate — but they're illustrative, not a
performance guarantee for your hardware. Measure your own before promising a
duration.

## Contributing

Gotchas are the highest-value content here. If you hit a PostgreSQL backup/restore
failure mode this skill didn't warn you about, a PR adding it — with the concrete
error message and the fix — is the most useful contribution you can make.

## License

MIT — see [LICENSE](LICENSE).
