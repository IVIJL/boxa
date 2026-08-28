# 03 — Eager migration of legacy credentials

Status: done

## Parent

ADR 0033, Decision 6.

## What to build

On the first forge command of any kind, pre-catalog credential files
(the per-forge files at the forge store root) convert to catalog
identities and become the global defaults in forge.conf. `kind` is not
derivable from stored data, so migration asks one interactive question
per credential (machine user / own account / other) — once per
installation. Migration is atomic per credential (no state where the
legacy file is gone and the identity missing) and idempotent; a store
with no legacy files migrates silently to a no-op.

## Acceptance criteria

- [x] Legacy github/gitlab credential files become identities with the
      answered kind and are set as global defaults
- [x] Re-running any forge command after migration asks nothing and
      changes nothing
- [x] Interrupting migration mid-prompt leaves a working store (legacy
      file intact or identity complete, never neither)
- [x] Interactive path tested through a real pty (no prompt stubs);
      shellcheck clean incl. info-level

## Blocked by

02-conf-v2-resolution-and-injection.md

## Comments

Also fixed a loose end left by issue 02: `_boxa::forge_token_expiry_heads_up`
previously scanned the legacy credential store; it now resolves and loads
the assigned/default catalog identity instead, so expiry heads-up keeps
working after legacy files are migrated away. Commit 7efb81b.
