# 06 — Import wizard: multi-select projects (destination + activations)

Status: done

## Parent

Live-test UX gap in the import wizard (#mcp-host-resync). User-approved
2026-08-21: when switching an imported server to project scope, the
project picker must allow selecting MULTIPLE projects, like the
activation picker does.

## Current state

`_wizard_project_picker` (`scripts/mcp-cli.sh:958-1021`) uses
`picker::one`, so fzf runs without `--multi` and TAB does nothing.
The multi-select project picker already exists as
`_activation_project_picker` (`scripts/mcp-cli.sh:1025+`,
`picker::many`) but is wired only into the activation flow.

## Design constraints (do not relitigate)

The catalog model has ONE destination scope per entry (global or one
project; the destination drives the secret-store resolution) and MANY
activations. Multi-select therefore means: one destination project +
activation in every selected project. Do not invent multi-destination
entries.

## What to build

- In the import wizard's project step, replace the single-select with
  a multi-select over initialized Projects (reuse the
  `_activation_project_picker` mechanics / shared `picker::many`,
  keeping the source project as the first/default option as today).
- Destination: the FIRST selected project (the source-project default
  keeps its one-keystroke position, so the common case is unchanged).
  Emit the same `--override <id> project <key>` as today for it.
- Activations: after a successful import apply, activate the entry in
  EVERY selected project. Ask the consumer set (claude/codex/both)
  ONCE per entry, reusing the existing activation path/UX (`boxa mcp
  activate` semantics — same records, same `Next: reload` hints).
  Selecting exactly one project must behave exactly like today plus
  the activation it implies; if the existing single-select flow did
  NOT activate, keep a plain-enter/skip way to end up with today's
  no-activation result, so the change is additive.
- Cancel semantics: `q`/empty in the picker cancels that entry's
  import exactly as today.
- Non-interactive paths unchanged.

## Acceptance criteria

- [x] Interactive import of a project-scoped server offers a
      multi-select project picker (fzf `--multi`; numbered fallback
      accepts comma-separated choices) — covered in `tests/picker.sh`.
- [x] Selecting projects A+B: destination override goes to the first
      selection; after apply the entry is activated in both A and B
      for the chosen consumers (test asserts activation records).
- [x] Single selection reproduces today's destination behavior;
      declining activation leaves today's exact state.
- [x] `q` cancels cleanly, nothing applied.
- [x] Tests green (`python3 -m unittest discover -s tests -q`),
      `tests/picker.sh` green, shellcheck clean incl. info-level.

## Blocked by

03 (same wizard code region; land 03 first to avoid conflicts).

## Comments

- 2026-08-21: Filed from live host test: "dalo mi to vybrat jaký
  projekt, ale nemohl jsem jich vybrat více, TAB nefungoval" — fzf was
  fine, the picker was single-select by construction.
