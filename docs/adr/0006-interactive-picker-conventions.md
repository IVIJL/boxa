# ADR 0006 — Interactive picker conventions

- **Status:** accepted
- **Date:** 2026-05-04

## Context

`docker-run.sh` had four interactive selection sites with copy-pasted logic
and divergent UX:

| Site             | Mode  | "Expand all" sentinel    | Fallback shortcuts        |
|------------------|-------|--------------------------|---------------------------|
| `pick_container` | one   | optional `with_all`      | numbered only             |
| `remove`         | one   | always "* Remove all"    | numbered only             |
| `blocked`        | many (fzf) | "* Allow all"       | numbered + `a`/`q`        |
| `deny`           | many (fzf) | none                | numbered + `q`, **single-only fallback** |

Each site re-implemented `command -v fzf` detection, the numbered fallback
loop, and the cancel/expand keys — with subtle drift. `deny` was the
clearest bug: fzf path was `--multi`, fallback was single-select. No module
owned "interactive selection" as a concept; adding a new shortcut, changing
the cancel key, or extending the no-fzf UX required edits in three or four
places.

## Decision

Introduce `lib/picker.sh` as the single owner of interactive selection.

**Two functions, not one with a flag.** Bash flag-parsing for a boolean
switch is verbose and error-prone; a separate name is cheap.

```bash
picker::one  --prompt "<p>" [--header "<h>"] [--first-option "<s>"]   # single
picker::many --prompt "<p>" [--header "<h>"] [--first-option "<s>"]   # multi
```

**Stdin = items, stdout = selection.** Items arrive as one-per-line on
stdin. Selection is printed on stdout (newline-separated for `picker::many`
when multiple are picked). Returns 1 on cancel or empty input.

**`--first-option` as a sentinel.** When set, the option string is
prepended to the menu (rendered as `a)` in the fallback) and returned
verbatim if the user picks it. Caller string-compares the return value to
its own sentinel to detect "expand all". This keeps the picker neutral
about what "all" means — `pick_container` interprets it as "stop all
running", `remove` as "wipe all volumes", `blocked` as "allow every blocked
domain".

**Unified fallback UX:** numbered list, `a` shortcut for first-option,
`q` to cancel. `picker::many` accepts comma-separated indices (`1,3,5`,
spaces tolerated). fzf, when present, gets `--multi` for `picker::many`.

**`--header` for caller context.** fzf takes over the full screen and
clears everything that was on it, so any error or status line the caller
wrote to stderr just before launching the picker is invisible by the time
the user is choosing. `--header` threads that context inside the picker:
fzf renders it via its own `--header` option (sticky above the prompt);
the numbered fallback prints it to stderr just above the option list.
Added 2026-05-21 for `agent-browser-broker.sh`'s missing-session fallback
(ADR 0010), but generally applicable to any picker site that needs the
user to see *why* they're picking.

**Pure-logic core (`_picker::select`).** The selection parser is split out
from the I/O-rendering wrapper so it can be exercised by `tests/picker.sh`
without a tty or fzf. The wrapper renders the menu to stderr, reads from
stdin, then delegates parsing to the pure function.

## Behavior changes for callers

- `pick_container` and `remove` gain `q` (cancel) and `a` (expand-all
  shortcut where applicable). Numbered input still works.
- `blocked` fallback gains comma-multi (`1,3,5`), matching its fzf
  `--multi` path. Previously single-only.
- `deny` fallback gains comma-multi, matching its fzf `--multi` path.
  Previously single-only — closes the inconsistency that was effectively a
  bug.

## Out of scope

- **bats harness.** `tests/picker.sh` follows the same plain-bash pattern as
  `tests/naming.sh`. Test harness adoption is its own decision.
- **fzf I/O testing.** Tests focus on `_picker::select`. Mocking fzf would
  require either a fake binary on `PATH` or a more elaborate harness, and
  fzf's own behavior is not the surface under test.
- **`picker::confirm` / yes-no.** Useful future addition but not present
  in any current call site — adding it speculatively would be premature.

## Consequences

- The four selection sites in `docker-run.sh` shrank by ~70 lines net.
- A future fifth site (or an extension to multi-select with a default
  set, fuzzy-filter in fallback, etc.) is a single-edit change in
  `lib/picker.sh`.
- A pre-existing `deny` fallback bug (single-only when fzf was multi) is
  fixed as a side effect of unifying the UX.
- `tests/picker.sh` can be run directly (`bash tests/picker.sh`) to verify
  the parser; the I/O path remains exercised by manual use of the
  surrounding subcommands.
