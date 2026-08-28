# 21 — Dashboard renders twice around an assignment

Status: done

## Parent

Live verification 2026-08-26; ADR 0034 decision 4 (dashboard-first).

## What happened (live repro)

`boxa forge` printed the full dashboard, ran the assignment, then
printed the full dashboard again. Two near-identical screens plus the
closing narrative make the output unreadably long.

## What to build

Render the full dashboard once per invocation. After an action that
changes state, print only a compact delta (the existing
`Persona assignment summary:` line already carries it: `<project>:
none -> vlcak [container recreation needed…]`) instead of a second
full render. If a second full render is genuinely wanted somewhere,
it must replace the first, not follow it.

## Acceptance criteria

- [x] One full dashboard render per `boxa forge` invocation; actions
      report deltas, not a second full dashboard.
- [x] Assignment summary and recreation hint still shown.
- [x] shellcheck clean (incl. info); test asserts single render.

## Blocked by

(none)

## Comments
