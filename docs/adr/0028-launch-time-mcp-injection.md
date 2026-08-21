# ADR 0028 — Launch-time MCP injection instead of shared-file renders

- **Status:** accepted
- **Date:** 2026-08-20
- **Supersedes:** ADR 0022 entirely; the "Consumer rendering" halves of
  ADR 0021 and ADR 0013

## Context

Every consumer render target we have used is a file shared between host and
Container: the project directory is bind-mounted at its host path (ADR 0004),
so `<project>/.mcp.json`, `.claude/settings.local.json`, and
`.codex/config.toml` are the same file on both sides, and `~/.codex` is
mounted RW. The result leaks both ways: host Claude/Codex list boxa servers
they can never start (the `boxa-mcp-run` identity gate fails outside the
Container), and host MCP servers such as a macOS-only `node_repl` leak into
Container Codex sessions. The render machinery also carries real cost: CAS
transactions on project files, `--allow-tracked-*` consent flags,
`.git/info/exclude` management, convergence at Container start, and the
single-file bind-mount inode class of bugs.

## Decision

Stop writing MCP configuration into any shared file. Boxa's host-owned
activation store and the secret-free runtime snapshot (already mounted
read-only at `/run/boxa-mcp-runtime`) remain the only artifacts. A
Container-only Agent launch wrapper occupies each agent CLI's canonical binary
path — `~/.local/bin/claude` (the symlink `setup-claude.sh` already rewrites
becomes a generated script) and `/usr/local/share/npm-global/bin/codex` (the
node-owned npm symlink, regenerated each Container start so npm updates cannot
resurrect it). Occupying the canonical path rather than shadowing via PATH
means absolute-path callers, user skills, hooks, and the codex-delegate's
`AGENT_PATH` resolution all land on the wrapper; only calling package
internals bypasses it, which we accept as deliberate surgery.

On every invocation the wrapper derives the Project's MCP profile from the
runtime snapshot (`projects` × `entries`) and injects it as the session's
complete MCP configuration: Claude via `--strict-mcp-config
--mcp-config=<inline JSON>` (the `=` form; the variadic space form swallows
following arguments), Codex via `-c mcp_servers.*` overrides that also disable
every server found in shared `config.toml` that is not an activation. The
Claude wrapper resolves the highest CLI version per invocation, so a host CLI
update no longer requires a Boxa restart. An unreadable or invalid snapshot
starts the session with no MCP plus a stderr warning; it never blocks the
agent.

Verified on Claude 2.1.234 and Codex 0.145.0: inline `--mcp-config` strings
load servers without any `enabledMcpjsonServers` approval, and `codex -c`
accepts both full server definitions and `enabled=false` overrides.

## Consequences

- Approval seeding dies with the render: explicit `boxa mcp activate` is the
  consent, and strict mode is stronger than the approval prompt it replaces —
  a `.mcp.json` arriving in a cloned repo cannot inject a server into a
  Container session at all. Host-side native approvals are untouched.
- `boxa mcp migrate` grows a cleanup phase that removes previously rendered
  boxa content (`.mcp.json` entries, approval seeds, Codex managed regions,
  `.git/info/exclude` lines, render state), runs on boxa update, and keeps the
  tracked-file consent guard for removal too.
- Convergence (`boxa-mcp-converge`) loses its render-assertion job; activation
  changes still take effect only in new sessions, exactly as today.
- Inherited servers disappear from Container sessions by construction; the
  import path (heuristic classification only — candidate code is never
  executed, it may be malware) is the sole route into the Container, deduped
  against existing catalog entries.
- The wrapper becomes a critical path for every agent start and must stay
  dependency-light and fast.
