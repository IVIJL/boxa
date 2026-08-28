# 18 — Dashboard-first `boxa forge` / `forge setup`

Status: done

## Parent

ADR 0034 decision 4.

## What to build

`boxa forge` and `forge setup` open the same dashboard: personas (name,
kind, key fingerprints, forges configured, token ages), the default
persona, per-project assignments and gate states, and what is missing
(no personas yet, assignment without token, gate on without keys…).
Actions are offered from that context — add persona, assign
(multiselect), set default, attach key, rotate token — instead of a
blind linear checklist; the checklist survives only as the "add a
persona" action. The doctor wizard and migration reuse the same flow
components; no third UI appears. Intro/outro narration per issue 09
(what will be configured and why; end summary of what works now).

## Acceptance criteria

- [x] Bare `boxa forge`, `forge status`, and `forge setup` share the
      dashboard; empty state leads into add-persona.
- [x] Dashboard reflects live state (probes/fingerprints) and flags
      the missing-piece cases above.
- [x] Doctor invokes the same components; no duplicate flow code
      paths for setup vs. doctor vs. migration.
- [x] shellcheck clean (incl. info); pty coverage of dashboard →
      action → return.

## Blocked by

- 14-persona-assignment-writethrough.md
- 15-persona-registration-no-posture.md
- 17-persona-multiselect-assignment.md

## Comments
