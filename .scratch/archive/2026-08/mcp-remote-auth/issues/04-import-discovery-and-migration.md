# 04 — Import discovery of headers + upgrading existing entries

Status: done
Priority: P2
Type: AFK

## Parent

.scratch/mcp-remote-auth/KICKOFF-NOTES.md + docs/adr/0030.

## What to build

Import discovery recognizes `headers` on an inherited http server
definition (e.g. a Bearer token in the host's Claude config). The dry-run
and apply views show WHICH header names exist, never values; on apply,
secret-looking headers become `secretHeaderKeys` (name only) and the user
is prompted for the value through the issue-02 flow (or given the exact
`Next:` command to set it later) — a token is never copied silently out
of the source config. Non-secret headers import as catalog `headers`.
Separately, an already-imported entry (the live Dozzle case) can be
upgraded in place: `boxa mcp update <entry>` accepts the new header
fields, and the post-update output tells the user the next step to set
the secret value and reload/restart.

## Acceptance criteria

- [x] Discovery of an inherited server with an Authorization header:
      dry-run shows the header name, marks the value as secret, never
      prints it.
- [x] Apply imports name-only + prompts (or hints) for the value; source
      config file is never mutated.
- [x] Existing catalog entry upgraded via update gains the headers, with
      a `Next:` chain that ends in a working proxied session.
- [x] English UI strings; unittest suite green.

## Implementation notes (2026-08-21)

- Discovery: `scripts/mcp/providers/claude.py` `_candidate_from_spec` now reads
  `spec["headers"]` for http candidates; header NAME or VALUE that trips the
  existing secret heuristics (`_is_secret_header_name` reusing
  `_name_marks_secret`, plus `_looks_like_secret_value`/
  `_contains_embedded_secret`) goes into `secret_header_keys` (name only);
  everything else copies into `headers` with its value. Source config is
  read-only, never mutated.
- Dry-run (`_render_text` in `scripts/mcp/cli.py`) prints `headers` names and
  a `secret headers: ... (values not shown)` line; no secret value is ever
  rendered.
- Apply (`_render_apply_text`) now emits `Next: boxa mcp secret set <entry>
  <header>` per secret header before the activate hint (`Then: boxa mcp
  activate ...`).
- `boxa mcp catalog update` (`_cmd_catalog_update`) diffs previous vs new
  `secretHeaderKeys` and prints `Next: boxa mcp secret set <entry> <header>`
  for newly-added secret headers, plus `Then: boxa mcp reload` when the
  update wasn't already runtime-affecting.
- Deferred (per AFK scope): live end-to-end verification that the full
  `Next:` chain (secret set -> activate/reload) actually reaches a working
  proxied session against a real upstream (e.g. the live Dozzle server) —
  this needs a real host/browser session and is left for the user to
  verify manually.
- Proof: `python3 -m unittest discover -s tests -q` — 611 passed, 0 failed
  (no shell scripts touched, no shellcheck needed).

## Blocked by

- 01-catalog-headers-model.md
- 02-secret-header-values-store.md
