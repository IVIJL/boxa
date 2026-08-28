# 01 — Purge migrated legacy profile entries + fix stale "issue 08" message

Status: done
Priority: P1

## Problem

After `boxa mcp migrate` completes, the legacy profile store is retained
forever and `boxa mcp status` keeps printing:

```
Legacy MCP profile entries (kept until migration issue 08):
NAME           SCOPE   STATUS    ...
context7       global  disabled  ...
taskmaster-ai  global  disabled  ...
```

Users read this as "migration failed". "issue 08" refers to a long-done
issue of the old mcp-catalog-trust feature. Nothing in the codebase ever
deletes the legacy store files (verified: only shared render targets are
cleaned, never `profile.json` / `projects/*.json` / secrets files).

## Facts

- Message: `scripts/mcp/cli.py:2280-2282`; `legacy = effective_list(...)`
  built in `scripts/mcp/lifecycle.py:244-278` from profile JSON files.
- Legacy store paths: `~/.config/boxa/mcp/profile.json`
  (`profile.py:111`), `~/.config/boxa/mcp/projects/<name>-<hash10>.json`
  (`profile.py:115`), plus `secrets.json` / `projects/*.secrets.json`
  (`secrets.py:41,45`).
- Migration: `scripts/mcp/migration.py` `migrate_legacy`; manifest
  `prepared` → `complete` at `migration.py:887-904`; re-entry with a
  complete manifest short-circuits to cleanup only (`migration.py:791-800`);
  `legacyRetained` is hardcoded `True` (`migration.py:813,890`).
- Update hook runs `migrate-text` on every update:
  `scripts/ensure-mcp-onboarding.sh:98`.

## Fix

1. In the migration cleanup phase (the same re-entry path the update hook
   already triggers), remove from the legacy profile store the entries the
   manifest records as migrated, and their migrated legacy secrets. Delete
   a profile/secrets file when it becomes empty. Entries NOT recorded in
   the manifest (added later, never migrated) must stay untouched.
   Idempotent, like the shared-render cleanup.
2. Reflect it in the manifest (e.g. `legacyRetained: false` / a purge
   marker) so re-runs are no-ops.
3. Replace the stale heading in `cli.py:2280-2282`. If legacy entries
   remain (non-migrated leftovers), print something like
   "Legacy MCP profile entries (superseded by the catalog; run 'boxa mcp
   migrate'):" — no reference to issue 08.
4. `boxa mcp migrate` output: replace "Legacy source retained." with what
   actually happened (e.g. "Migrated legacy entries were purged from the
   legacy profile store.").

## Acceptance

- After migrate completes (or on next update-hook run for already-migrated
  hosts), `boxa mcp status` no longer shows the legacy section for
  migrated entries; the legacy files for fully-migrated stores are gone.
- Non-migrated legacy entries survive and are listed under the new
  heading.
- Tests in `tests/test_mcp_migration.py` cover: purge on complete
  manifest, idempotency, partial store (mixed migrated + later-added
  entry), secrets files handling.
