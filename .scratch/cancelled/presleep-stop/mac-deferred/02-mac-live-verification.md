# 02 — macOS live verification of the presleep-stop feature

Status: ready-for-human

## Parent

.scratch/mac/presleep-stop/01-iokit-power-watch.md

## What to build

Nothing to code up front — a verification pass on the user's Mac once
issue 01 lands:

- `boxa keep-awake enable` brings up daemon + power-watch + tray
  (KeepAwakeTray.swift) with no extra flags.
- Lid close with running boxes → boxes stopped, notification delivered
  (no click action expected on macOS — canonical record is the log).
- Shell-aware Stop hook (`.scratch/presleep-stop/issues/02-…`) works
  with the macOS `ps`/proc-walk variant.
- `boxa stop --all --reason presleep` invoked manually behaves the
  same as on Linux/WSL2.
- Note any macOS-specific gaps found here as new issues in this
  directory.

## Acceptance criteria

- [ ] All checks above pass on the Mac, or gaps are filed as issues.

## Blocked by

.scratch/mac/presleep-stop/01-iokit-power-watch.md; needs a macOS
machine.

## Comments
