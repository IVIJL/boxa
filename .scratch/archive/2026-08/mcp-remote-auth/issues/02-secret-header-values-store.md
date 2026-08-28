# 02 — Secret header values: store, prompt, reload, staging

Status: done
Priority: P1
Type: AFK

## Parent

.scratch/mcp-remote-auth/KICKOFF-NOTES.md + docs/adr/0030.

## What to build

Values for `secretHeaderKeys` live in the host MCP secret store, keyed by
entry + header name (no separate store-key field — ADR 0030 decision 1).
Setting a value follows the existing secret UX: interactive prompt (no
value on the command line), same machinery the env-secret path uses,
including the reload prompt when a running Container is affected and
`boxa mcp reload` re-staging semantics. Staged secrets reach the in-box
broker the same way env secrets do (per-spawn/per-request read; the agent
UID must not be able to read them — same boundary as ADR 0014).

## Acceptance criteria

- [x] A secret header value can be set (and updated) via the existing
      secret-writing flow; never appears in argv, catalog, or any shared
      file.
- [x] readiness flips to ready once the value exists; status hint from
      issue 01 disappears.
- [x] `boxa mcp reload` re-stages a changed header value into running
      Containers; next session/request uses it.
- [x] Staged value unreadable by the agent user (test at the
      staging-permission level, consistent with env-secret tests).
- [x] English UI strings; unittest suite green.

## Blocked by

- 01-catalog-headers-model.md
