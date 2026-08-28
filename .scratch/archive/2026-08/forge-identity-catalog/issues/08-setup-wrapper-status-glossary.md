# 08 — `forge setup` wrapper, status, glossary

Status: done

## Parent

ADR 0033, Decision 5; ADR 0032 Decision 6 (doctor onboarding).

## What to build

Onboarding and visibility glue. `boxa forge setup` becomes the wrapper:
`forge add` → offer to set the new identity as the per-forge default →
offer `forge use` for the current project; doctor keeps invoking it.
`forge status` becomes a real subcommand (alias of bare `forge`) and its
output grows the per-project assignment view on top of the existing
authenticates-as lines. CLI help and usage strings cover the new verbs.
CONTEXT.md gains the glossary terms: Forge identity, Identity kind,
Identity assignment, Default identity (glossary-only, no implementation
detail).

## Acceptance criteria

- [x] `forge setup` end-to-end: fresh install reaches a project with an
      assigned, verified identity in one guided run
- [x] `boxa forge status` works and equals bare `boxa forge`; shows
      defaults, per-project assignments, and divergence warnings
- [x] Usage/help lines list add/list/use/default/remove/status
- [x] CONTEXT.md terms added in glossary format
- [x] pty-tested where interactive; shellcheck clean incl. info-level

## Blocked by

04-forge-use-and-default.md, 07-forge-add-registration.md

## Comments
