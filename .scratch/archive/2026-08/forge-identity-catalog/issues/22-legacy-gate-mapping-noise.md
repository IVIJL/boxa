# 22 — Legacy SSH gate mapping: silent `on` everywhere + MISSING spam

Status: done

## Parent

Live verification 2026-08-26; ADR 0034 (binary gate), ADR 0032
supersession.

## What happened (live repro)

The in-memory legacy mapping turned the SSH gate `on` for every known
project, and each project without a persona then printed a
`MISSING: SSH gate is on without an assigned persona or keys.` line —
5 projects, 10 lines of noise, and gates silently held `on` where the
user may no longer want them.

## What to build

Make the legacy state explicit and quiet. On the dashboard, show the
legacy-mapped state distinctly (e.g. `SSH gate: on (legacy)`) and
collapse the per-project MISSING repetition into one summary line
listing affected projects. Offer a one-time migration action from the
dashboard that writes the mapped values (or `off`) explicitly per
project — consent-first, no silent config rewrite (keeps the round-1
consent-safe migration rule). The `NOTE:` line then disappears once
nothing legacy remains.

## Acceptance criteria

- [x] Legacy-mapped gates are visibly marked; no silent write.
- [x] MISSING lines collapse to one summary line.
- [x] Dashboard offers an explicit migration action; after it, the
      NOTE and legacy markers are gone.
- [x] shellcheck clean (incl. info); test coverage.

## Blocked by

(none)

## Comments
