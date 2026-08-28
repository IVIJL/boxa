# 20 — Picker: inline fzf (no alternate screen) and echo the choice

Status: done

## Parent

Live verification 2026-08-26; ADR 0006 picker conventions.

## What happened (live repro)

Every fzf picker opens the alternate screen, hiding the dashboard and
narrative printed before it, and after the pick nothing shows what was
chosen. The user loses all context on every selection.

## What to build

In `_picker::fzf` (lib/picker.sh): render inline instead of the
alternate screen (`--height` — e.g. `--height=~40%` with a sane
minimum — plus `--layout=reverse`), so prior terminal output stays
visible. After a successful pick, print the selection to stderr (e.g.
`<prompt> <choice>`, comma-joined for multi), because fzf erases its
inline widget on exit. Fallback picker already echoes context; keep
behavior consistent. Mind older fzf versions: if `--height=~N%` is
unsupported, use a plain `--height` value.

## Acceptance criteria

- [x] fzf pickers no longer use the alternate screen; text printed
      before the picker remains on screen after it closes.
- [x] The chosen item(s) are printed after every pick (fzf and
      fallback paths consistent).
- [x] All picker call sites inherit the fix (single wrapper change).
- [x] shellcheck clean (incl. info); test coverage for the echoed
      choice.

## Blocked by

(none)

## Comments
