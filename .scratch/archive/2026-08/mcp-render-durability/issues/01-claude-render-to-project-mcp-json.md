# 01 — Claude activations render into the Project's `.mcp.json`

Status: done

## Parent

ADR 0022 — Durable Claude MCP render and approval.

## What to build

Move the Claude Code render target from the Container-visible
`~/.claude/.claude.json` to the Project's `.mcp.json`, so the rendered
definition lives in a file Claude Code reads but never rewrites.

Activation writes the Boxa-owned entries there and deactivation removes them.
Only Boxa's own keys are touched; any other server the user or a repository
already defines in that file is preserved byte-for-byte, as is the rest of the
document. The rendered entry keeps the shape it has today — the wrapper command
plus its arguments, no environment and no secret value.

The Git rules mirror the Codex render from ADR 0021: an otherwise untracked
`.mcp.json` is added to the repository-local `.git/info/exclude` and never to
the shared `.gitignore`; a tracked `.mcp.json` is not written without explicit
per-mutation consent, validated for every affected Project before a multi-Project
lifecycle mutation writes anything.

The same slice retires the old target: entries Boxa previously wrote into
`~/.claude/.claude.json` are removed as part of establishing the new one, so the
two renderers never coexist and there is only ever one rendered source of truth.
Non-Boxa content in that file stays untouched. Drift detection, the `RENDERS`
column of the status view, and the doctor repair all read and fix the new target.

Existing activations must survive the change without the user re-activating
anything.

## Acceptance criteria

- [x] Activating for the `claude` consumer renders the entry into the Project's
      `.mcp.json`, and nothing Boxa owns is written to `~/.claude/.claude.json`.
- [x] Deactivating removes only Boxa's entry; unrelated servers and unrelated
      document content in `.mcp.json` are preserved exactly.
- [x] An untracked `.mcp.json` is added to `.git/info/exclude`; the shared
      `.gitignore` is never modified.
- [x] A tracked `.mcp.json` is refused without explicit consent, and a
      multi-Project mutation refuses as a whole when any affected Project would
      need consent it does not have.
- [x] A render whose result is byte-identical does not rewrite the file and does
      not require consent.
- [x] Boxa-written entries are removed from `~/.claude/.claude.json` when the new
      target is established; non-Boxa entries there are untouched.
      Scope note: the purge covers the per-project `projects[*].mcpServers` /
      `disabledMcpServers` records the activation renderer actually wrote. The
      top-level `mcpServers` block (the legacy ADR 0013 global render) is still
      retired by `scripts/mcp/migration.py`, not duplicated here.
- [ ] Pre-existing activations are re-rendered to the new target with no user
      action, and a fresh in-Container `claude mcp list` shows the server.
      Re-render from an existing activation store with no re-activation is
      covered by a test; the in-Container `claude mcp list` half needs a real
      Container and is deferred verification.
- [x] Status drift reporting and doctor `--fix` operate on `.mcp.json`.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes after any shell changes.

## Blocked by

None — can start immediately.

## Comments
