# 06 — `forge remove` with in-use protection

Status: done

## Parent

ADR 0033, Decision 5.

## What to build

`boxa forge remove <id>` deletes an identity from the catalog. When the
identity is assigned to any project or is a global default, the command
refuses and lists every place it is used; `--force` removes it anyway
and cleans the assignments (affected projects fall back to the default,
or to none when the removed identity was the default). Removing an
unused identity just works.

## Acceptance criteria

- [x] Remove of an assigned/default identity refuses with a list of
      projects and the default role; exit code non-zero
- [x] `--force` removes the file and scrubs every reference from
      forge.conf in one locked write
- [x] Boxes created afterwards reflect the fallback (default or nothing)
- [x] shellcheck clean incl. info-level; forge-suite tests cover refuse,
      force, and unused paths

## Blocked by

04-forge-use-and-default.md

## Comments
