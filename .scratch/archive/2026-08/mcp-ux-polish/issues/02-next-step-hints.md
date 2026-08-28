# 02 — Next-step hints after commands + `mcp import <name>` positional

Status: done
Priority: P1

## Problem

Live-host feedback: `boxa mcp import` (dry-run) ends with "Dry-run only:
no MCP profile or agent config was modified." and never says HOW to apply.
`boxa mcp import dozzle` fails with "Unexpected argument". After
`--apply`, "Catalog definitions updated only. Nothing was installed,
activated, or rendered." again names no next command. The full chain is
documented only in `--help` and in the onboarding hook
(`ensure-mcp-onboarding.sh:159-161`); runtime outputs never echo it.

## Facts (audit)

- import dry tail: `scripts/mcp/cli.py:334-336`; apply tail: `cli.py:685`.
- Positional rejected in `scripts/mcp-cli.sh:427-435`; selectors are only
  `--server <name>` / `--import-id <id>`, and those require
  `--apply`/`--activate` (`mcp-cli.sh:449-457`).
- No next-command line in: `add` (`cli.py:1589`), catalog `install`
  (`cli.py:2173-2176`), `activate` pending (`cli.py:2032-2043`),
  `migrate` (`cli.py:2688-2692`). Partial prose only ("reload/restart the
  named agents", "start a new agent session"): `update`
  (`cli.py:1868-1883`), `activate` (`cli.py:2044-2049`), `deactivate`
  (`cli.py:2199-2206`).

## Fix

1. `mcp import` dry-run tail: append a literal next-step line, e.g.
   `Next: boxa mcp import --apply            (interactive)` and
   `      boxa mcp import --apply --server <name>` when candidates exist.
2. `mcp import --apply` tail: append
   `Next: boxa mcp install <name>` (skip for remote-http entries, which
   have no runtime install) and
   `Then: boxa mcp activate <name> --project <path> --for claude|codex`,
   using the real imported entry name(s) when unambiguous.
3. `mcp install` (catalog) success: append
   `Next: boxa mcp activate <entry> --project <path> --for claude|codex`
   when readiness is ready; when not ready, keep the missing lines and
   point at `boxa mcp readiness <entry>`.
4. `mcp migrate`: append `Next: boxa mcp status` (and align with issue 01
   wording).
5. Positional support: `boxa mcp import <name>` behaves as
   `--server <name>`; without `--apply` print the dry-run filtered to that
   server plus the exact apply command, instead of a hard error.
6. Sweep the remaining commands from the audit and add a literal command
   where a concrete next step exists; leave terminal steps (reload)
   alone. Keep hints to one or two `Next:`/`Then:` lines, no essays.

## Acceptance

- Each amended command prints a copy-pasteable next command on success.
- `boxa mcp import dozzle` works (dry-run filtered view + apply hint);
  `boxa mcp import dozzle --apply` imports that server.
- UI strings English. Shellcheck clean for mcp-cli.sh changes.
- Text assertions added (greenfield — no test currently pins these
  strings): extend `tests/test_mcp_apply.py` / import UX tests.
