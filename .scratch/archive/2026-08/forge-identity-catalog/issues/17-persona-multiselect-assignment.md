# 17 — Persona multiselect assignment across projects

Status: done

## Parent

ADR 0034 decision 10.

## What to build

`forge use` with no args becomes: persona picker → multi-select of
projects (current project preselected). Confirming assigns the persona
to every selected project in one run — full write-through per issue 14,
overwriting previous assignments — and reports a summary (which
projects switched from what, which containers need recreation for the
mounts/env to change). Ten projects = one invocation, not ten.

Every picker screen carries its question and step context in the fzf
`--header` (issue 09 convention).

## Acceptance criteria

- [x] One run assigns a persona to N projects including overwrites;
      summary lists old → new per project and recreation hints.
- [x] Deselecting a project in the picker does NOT unassign it (no
      surprise removals); explicit `none` remains the removal path.
- [x] Headers present on both pickers (pty asserts).
- [x] shellcheck clean (incl. info).

## Blocked by

- 14-persona-assignment-writethrough.md

## Comments
