# 03 — Show activation scope (which projects) in catalog and status

Status: done
Priority: P2

## Problem

Live-host feedback: neither `boxa mcp catalog` nor `boxa mcp status`
shows WHERE an entry is activated. The user cannot tell whether an entry
is global (everywhere), active in some projects (and which), or inactive
everywhere.

## Facts

- `mcp catalog` table: `_render_catalog_text` `scripts/mcp/cli.py:1604-1633`,
  data from `_catalog_payload` (`cli.py:1593-1602`) which never loads
  activations.
- Activation store: `scripts/mcp/activation.py` —
  `~/.config/boxa/mcp/activations.json`, shape
  `{"projects": {<abs path>: {<entryId>: record}}, "everywhere": {...}}`.
  Helper `_entry_activations(activations, entry_id)` (`activation.py:879-892`)
  already returns `[{"projectKey", "consumers"}, ...]`.
- `mcp status` per-project table: `_cmd_catalog_effective_list`
  (`cli.py:2211`, headers `:2235-2245`), data from
  `catalog_project_status` (`lifecycle.py:868+`) which loads the full
  activations dict but scopes rows to one project.

## Fix

1. `mcp catalog`: add an `ACTIVATIONS` column summarising scope, e.g.
   `everywhere`, `3 projects`, `-`. With a new `--verbose` flag (or in
   `--json` always) list the actual project keys per entry.
2. `mcp status` (single-project view): add a column or per-entry detail
   showing global scope, e.g. `PROJECTS` with the count of projects the
   entry is active in (current project included), so "activated here,
   also in 2 others" is visible. `--json` includes the full project list.
3. Keep table width sane; prefer counts in the table + full lists in
   `--json`/verbose.

## Acceptance

- `boxa mcp catalog` distinguishes at a glance: everywhere / N projects /
  inactive.
- `--json` (catalog and status) carries the explicit project lists.
- Tests: extend `tests/test_mcp_catalog.py` /
  `tests/test_mcp_catalog_lifecycle.py` with activation-scope assertions.
