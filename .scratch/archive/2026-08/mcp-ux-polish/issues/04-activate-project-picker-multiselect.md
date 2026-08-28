# 04 — Fix multi-select UX of the activate project picker (fallback)

Status: done
Priority: P2

## Problem (corrected — earlier draft was wrong)

`boxa mcp activate` DOES have a project picker with multi-select:
`_activation_project_picker` (`scripts/mcp-cli.sh:946-985`) pipes project
rows into `picker::many`, and `cmd_activation` already loops over multiple
selected projects (`mcp-cli.sh:2278-2294`). With fzf, Tab works.

Live-host feedback: Tab/Shift-Tab did nothing, so multi-activation seemed
impossible. Root cause is the no-fzf numbered fallback:

1. **Misleading header.** The caller passes
   `--header "Tab selects multiple Projects; current Project is the
   default (a)"` (`mcp-cli.sh:971`), and `_picker::fallback` prints that
   header verbatim (`lib/picker.sh:93`) even though Tab does nothing
   there — the fallback selects via comma-separated numbers.
2. **Default option can't be combined.** The current project is the `a)`
   letter sentinel; `_picker::select` (`lib/picker.sh:158+`) accepts
   EITHER a single letter OR comma-separated numbers. `a,2` fails with
   "Invalid choice: a". So "current project + one more" is impossible in
   the fallback in a single run.

## Fix

1. `_picker::select` many-mode: accept letter shortcuts mixed with
   numbers (`a,2,3`), preserving order and rejecting duplicates
   gracefully. Update the fallback hint to advertise it, e.g.
   `(comma-separated: numbers and a/q)`.
2. Stop printing fzf-specific instructions in the fallback. Either make
   the picker mode-aware (caller passes a neutral header; the fzf path
   appends its own "Tab selects multiple" hint for `many`), or let the
   fallback print its own multi-select hint instead of the caller header
   when the header mentions Tab. Prefer the first (mode-aware) option;
   keep the API change minimal for other callers (`picker::many` in the
   import wizard shares the benefit).
3. Re-check other `picker::many` call sites (import wizard,
   `mcp-cli.sh:796`) for the same misleading-header pattern and align.

## Acceptance

- No-fzf fallback: header no longer mentions Tab; hint shows how to
  multi-select; `a,2` selects the default project plus item 2.
- fzf path unchanged for users (Tab still works; hint still shown).
- Shellcheck clean. Tests: extend `tests/picker.sh` (uses
  `BOXA_PICKER_TEST_CHOICE`, `BOXA_PICKER_FZF=0`) for mixed letter+number
  selection and the header behavior.
