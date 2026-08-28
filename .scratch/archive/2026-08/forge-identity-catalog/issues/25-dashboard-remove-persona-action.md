# 25 — Dashboard lacks a "Remove a persona" action

Status: done
Type: AFK

## Parent

Live verification round 2, 2026-08-26; ADR 0034 decision 4 (actions
offered from the dashboard context).

## What happened (live repro)

The user needed to delete the mis-created persona `vlcak`. The
dashboard action menu offers Add / Assign / Set default / Attach an
SSH key / Rotate a token / Migrate legacy SSH gates / Done — no remove.
The guarded CLI remove exists (`_boxa::forge_remove`, lib/forge.sh
~3666, with the in-use guard in `_boxa::forge_remove_locked`), but the
user has no way to discover it from the dashboard, which is the primary
UX per ADR 0034.

## What to build

Add a "Remove a persona" action to the dashboard action menu. It picks
a persona (picker over existing personas), runs the existing guarded
remove path (same in-use guard: refuse while assigned, listing the
Projects using it), and reports the outcome. When the persona is the
default, the existing default-handling semantics of `forge remove`
apply unchanged. Reuse `_boxa::forge_remove`/`_boxa::forge_remove_locked`
— do not duplicate the guard logic. UI strings EN.

## Acceptance criteria

- [x] Dashboard action menu offers "Remove a persona".
- [x] The action reuses the guarded remove; an in-use persona is
      refused with the same message listing the Projects.
- [x] After a successful remove the dashboard state reflects it
      (persona gone from the header on the next render).
- [x] shellcheck clean (incl. info); test coverage for the new action
      (real pty where the flow is interactive).

## Blocked by

(none)

## Comments
