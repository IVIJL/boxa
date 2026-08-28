# 04 — `forge use` + `forge default`

Status: done

## Parent

ADR 0033, Decision 3, 5.

## What to build

Assignment UX. `boxa forge use [<id>]`: with no args, an identity
picker over the catalog followed by an MCP-style multi-project picker
(current Project first and default, candidates unioned from the project
registry and existing boxa containers, same UX as MCP activation);
with an ID, still offers the project picker. Writes the per-project
assignment keys and turns the project's forge gate on (assignment is
intent); `forge off` remains a kill switch and does not touch
assignments. `boxa forge default <id>` sets the global default for that
identity's forge. Both commands validate the ID against the catalog.

## Acceptance criteria

- [x] `forge use` with no args walks identity picker → project picker
      and writes assignment + gate on for every selected project
- [x] `forge use <id>` validates the ID and errors helpfully on unknown
- [x] `forge off <project>` after `use` leaves the assignment in place;
      turning back on restores the same identity
- [x] `forge default <id>` sets the per-forge default; bare `forge`
      status output shows defaults and per-project assignments
- [x] Interactive paths tested through a real pty; shellcheck clean
      incl. info-level

## Blocked by

02-conf-v2-resolution-and-injection.md

## Comments
