# 05 — Agent-trusted Codex delegation

Status: done

## Parent

ADR 0021 — Project-selected MCP catalog and agent-trusted execution.

## What to build

Deliver the complete `agent-trusted` execution path using `codex mcp-server` as
the acceptance example. A host-side mode command displays stable catalog ID,
resolved command/image, and the exact node-private access boundary before
confirmation. In-container callers may use the authorization but cannot grant
it. Discovery/import never infer trust.

The existing `boxa-mcp-run` launcher asks the broker to validate catalog identity
and Project activation. For an agent-trusted entry the broker returns only a
secret-free authorization/launch plan; the launcher starts the process as
`node`. It receives deterministic HOME/XDG/PATH and known Docker/SSH socket
locations plus declared non-secret environment, but no arbitrary ambient bearer
tokens. It can reuse the mounted Codex ChatGPT login and control Project Docker.

## Acceptance criteria

- [x] New entries default to `service-isolated`; only the host-side mode command
      can grant `agent-trusted`, interactively or with explicit `--yes`.
- [x] Mode cannot change while any activation exists.
- [x] Mode change to agent-trusted refuses entries declaring secret env keys or
      retaining values in the MCP secret store and lists names, never values.
- [x] Broker authorization binds stable catalog identity, active Project, and
      selected consumer and contains no secret credential values.
- [x] Agent-trusted launch runs as `node` with deterministic baseline and fixed
      Docker/SSH pointers while test-only ambient tokens are absent.
- [x] Codex readiness uses `codex login status`; the MCP server reuses mounted
      node Codex state without copying auth or requiring an API key.
- [x] `codex-delegate` can activate only for Claude, operate on Project source,
      and invoke Project Docker; no self-activation for Codex is implicit.
- [x] Rename/update preserves trust identity; removal/recreation does not.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes without requiring a real Codex login or network.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes after shell changes.

## Blocked by

- `02-claude-service-activation.md`
- `03-readiness-and-install.md`

## Comments

- Implemented host-only trust grant, immutable active modes, secret refusal,
  deterministic node launch, Codex login readiness, and Claude-only Codex
  delegation. Full MCP suite: 560 tests passed.
- Security review found that a service-isolated process sharing the broker UID
  could forge a broker launch plan. Fixed by mounting a secret-free host runtime
  snapshot separately and making the node relay independently reconstruct and
  exactly validate identity, activation, consumer, argv, env, cwd, and sockets.
- Independent post-fix review: 140 targeted tests passed; shellcheck and
  `git diff --check` clean.
