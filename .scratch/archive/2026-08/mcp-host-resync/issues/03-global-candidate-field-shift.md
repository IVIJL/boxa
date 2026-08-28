# 03 — Interactive apply misclassifies global candidates (lossy TSV parse)

Status: done

## Parent

Live-test regression of issue 01 (#mcp-host-resync, shipped as beca814).
Root cause confirmed 2026-08-21.

## Root cause (confirmed)

`applicable-candidates` rows are TAB-separated with `source_project`
empty for global-scoped candidates (`scripts/mcp/cli.py:1055-1074`).
The consumer `while IFS=$'\t' read -r id name scope pkey catalog_status
placement reason` at `scripts/mcp-cli.sh:852` collapses the two
adjacent TABs into ONE delimiter (TAB is IFS whitespace in bash even
when IFS contains only TAB), shifting every field right of the empty
one. For a global changed candidate `catalog_status` reads as
`container`, so:

- the row lands in the New section ("New: 1; Changed (reimport): 0"),
- the reimport consent question is never asked and `--reimport` is
  never emitted (`scripts/mcp-cli.sh:1094-1101`),
- python then aborts with "import id ... is already cataloged; pass
  --reimport to select it" (`scripts/mcp/cli.py:679-684`),
- the credential-takeover consent prompt is never reached.

Global in-sync candidates hit the same shift: the `in-sync` filter at
`scripts/mcp-cli.sh:854` never matches, so they are offered as "New"
and the "N entries in sync" summary line is wrong.

Dry-run output is unaffected (sections computed in python,
`_render_text`).

## What to build

- Make the candidate stream parse lossless for empty middle fields.
  Preferred: switch the row delimiter to a non-IFS-whitespace
  character (e.g. ASCII unit separator `\x1f`) on BOTH sides
  (python emit + bash `IFS=$'\x1f' read`), since non-whitespace IFS
  chars do not collapse. An explicit placeholder token for the empty
  project key is an acceptable alternative. Do NOT duplicate the
  sectioning logic — whichever mechanism, the shell must see the same
  `catalog_status` the python dry-run sections use.
- Audit ALL `IFS=$'\t' read` sites in `scripts/mcp-cli.sh` for the
  same failure mode (any potentially-empty NON-final field) and fix
  those the same way. Trailing-field-empty or two-column reads with a
  guaranteed non-empty final key are fine.
- No behavior change for project-scoped candidates.

## Acceptance criteria

- [x] A GLOBAL changed candidate goes through the interactive
      `--apply` wizard end to end: tally prints "New: 0; Changed
      (reimport): 1", the reimport consent question fires, `--reimport`
      is emitted, and the import proceeds into the normal apply path
      (regression test drives the real wizard/picker path, not a
      hand-built arg vector).
- [x] A GLOBAL in-sync candidate is excluded from the menu and counted
      in the "N entries in sync with host configs" line (test).
- [x] Project-scoped candidates behave exactly as before (existing
      tests stay green).
- [x] Audit result: no remaining `IFS=$'\t' read` in mcp-cli.sh with a
      potentially-empty non-final field (state the audited sites in
      the report).
- [x] Tests green (`python3 -m unittest discover -s tests -q`),
      `tests/picker.sh` green, shellcheck clean incl. info-level.

## Blocked by

None. Do this first — it blocks the user's live host verification of
issue 01.

## Comments

- 2026-08-21: Found in live host test: dry-run showed dozzle under
  Changed, `--apply` showed "New: 1; Changed: 0" then died on
  "already cataloged; pass --reimport".
