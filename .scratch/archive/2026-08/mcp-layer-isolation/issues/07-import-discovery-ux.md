# 07 — Import/discovery UX: dedup, proactive offers, one-shot import

Status: done

## Parent

ADR 0028 (consequences: import is the sole route into the Container) and the
Inherited MCP server glossary entry.

## What to build

Make the inherited→catalog path visible and one-command, without ever
executing candidate code:

- discovery dedups candidates against the catalog: an identical definition
  (same command/args or url) is reported as "already in catalog", not
  proposed; a same-named candidate with a different definition surfaces as a
  conflict with a diff and an explicit choice — update the catalog entry
  (through the existing atomic update flow) or skip,
- `boxa mcp status --project <p>` lists non-imported container-classified
  candidates with a one-line nudge toward import,
- interactive `activate`/`import` offers discovered candidates ("found X in
  your agent config — add it?"); classification stays heuristic-only
  (host-only candidates shown with the reason, importable only via explicit
  force),
- one command takes a candidate through import + readiness + activation for
  the target Project,
- machine mode: `--json` output for discovery/dedup verdicts and `--yes` for
  non-interactive acceptance.

## Acceptance criteria

- [x] A candidate identical to a catalog entry never appears as a proposal;
      status labels it already-cataloged
- [x] A same-named, different-definition candidate shows a diff and both
      resolution paths work
- [x] Status in a Project with unimported container-classified candidates
      shows the nudge; clean Projects show nothing extra
- [x] Single command lands import→readiness→activation; `--json`/`--yes`
      cover the same flow non-interactively
- [x] No candidate process is ever spawned during discovery/classification
      (discovery/status only parse config files via provider.discover(); no
      new execution path added, covered by tests/test_mcp_import_discovery_ux.py)

Note: acceptance criteria are covered by unit tests
(tests/test_mcp_catalog_import.py, tests/test_mcp_cli_render_status.py,
tests/test_mcp_import_discovery_ux.py). No live host verification (real
Claude/Codex config files, real TTY wizard run) was performed in this session.

## Blocked by

None — can start immediately.

## Comments
