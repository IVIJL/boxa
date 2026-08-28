# 04 — Migrate never purges legacy entries from pre-fingerprint manifests

Status: done

## Parent

Live-test finding against the migrate proof model introduced in
374dd25 (#mcp-ux-polish legacy store purge). Confirmed on host:
`grep -c legacyFingerprint ~/.config/boxa/mcp/migration-v1.json` → 0.

## Root cause (confirmed)

`_purge_migrated_legacy` (`scripts/mcp/migration.py:788-921`) purges a
legacy server only when its manifest row carries a `legacyFingerprint`
matching the recomputed fingerprint of the current legacy entry. Rows
written before 374dd25 have no `legacyFingerprint`, so every entry is
retained (`migration.py:834-837`). Because `migrate_legacy`
short-circuits for a `status: complete` manifest (`migration.py:
934-946`) and only re-runs the purge, the fingerprints are never
backfilled — retention is terminal, re-running `boxa mcp migrate`
prints "Legacy entries without matching migration proof were retained"
forever and `boxa mcp status` keeps listing the legacy block.

## What to build

- On `boxa mcp migrate` with a `complete` manifest, handle rows
  missing `legacyFingerprint`: recompute the proof NOW instead of
  giving up. A row is provably migrated when the CURRENT legacy entry,
  passed through the same `_catalog_entry` + `_legacy_fingerprint`
  normalization, corresponds to the definition the manifest recorded
  for it (i.e. the legacy entry still matches what was migrated into
  the catalog). In that case backfill the fingerprint into the
  manifest row (persist it) and let the existing purge logic delete
  the legacy server. Genuine mismatches (legacy entry edited since
  migration) stay retained.
- Improve the retained-path message: name the retained entries and say
  why each was kept and what to do next (today's message names
  nothing). Keep it one short block.
- Fix the hardcoded "global activations: 0" literal in the
  already-complete message (`scripts/mcp/cli.py` around line 3470) to
  report the real count recorded in the manifest.
- No changes to the fingerprint scheme itself; new manifests keep
  today's prepare-time recording.

## Acceptance criteria

- [x] A `complete` manifest whose rows lack `legacyFingerprint`, with
      legacy entries unchanged since migration → `boxa mcp migrate`
      purges the legacy servers, backfills the fingerprints, and
      `boxa mcp status` no longer shows the legacy block (test builds
      such a manifest, mirroring the user's host state with context7 +
      taskmaster-ai).
- [x] Same manifest but one legacy entry edited after migration → that
      entry is retained and the message names it with a reason; the
      unedited one is purged.
- [x] Rows WITH a matching fingerprint keep today's behavior; rows
      with a mismatching fingerprint stay retained (existing tests
      green).
- [x] The already-complete message reports the real global-activation
      count from the manifest.
- [x] Tests green (`python3 -m unittest discover -s tests -q`),
      shellcheck clean on touched shell scripts (no shell scripts
      touched — N/A).

## Blocked by

None. Independent of 03.

## Comments

- 2026-08-21: User ran migrate repeatedly on host; context7 +
  taskmaster-ai (both already catalog members) never left the legacy
  list.
