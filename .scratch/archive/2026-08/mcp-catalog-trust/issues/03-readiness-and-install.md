# 03 — Project readiness and durable MCP installation

Status: done

## Parent

ADR 0021 — Project-selected MCP catalog and agent-trusted execution.

## What to build

Make **MCP readiness** a deterministic local fact for one catalog entry and one
running Project. Check the materialized executable or Docker image plus declared
files, credentials, and sockets without probing external service health.

`boxa mcp install <entry>` prepares the runtime but never activates it. Preserve
the established persistence guarantees: materialized npm/npx runtimes survive
restart and Container recreation through shared storage; Docker images survive
ordinary Project stop/restart through Project Docker storage. Activation refuses
non-ready entries. Interactive activation may explicitly install, re-check, and
activate in one confirmed flow.

## Acceptance criteria

- [x] Readiness is evaluated per catalog-entry × Project and reports each
      missing prerequisite without exposing credential values.
- [x] Readiness supports direct commands, materialized npm/npx tools, and Docker
      images and is independent of live external network health.
- [x] Readiness and installation require a running target Boxa and never start it.
- [x] Install changes readiness only; no Claude or Codex config is rendered.
- [x] Activation of a non-ready entry fails without changing activation state or
      consumer configs.
- [x] Interactive install→re-check→activate is explicit and cancellation leaves
      no activation.
- [x] Installed npm and Docker runtimes use the documented persistent storage and
      readiness remains true after simulated ordinary restart/recreation.
- [x] Credential/readiness probes, including a stubbed Codex login-status probe,
      are deterministic and testable without real credentials or network.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes after shell changes.

## Blocked by

- `02-claude-service-activation.md`

## Comments

2026-07-27: implemented without commit. Added deterministic per-entry × Project
readiness for direct commands, persistent npm materializations, local Docker
images, declared files/sockets/credentials, and a stub-friendly Codex login
probe. Catalog install now requires an already-running target, never activates
or renders, and the interactive activation flow explicitly confirms
install→re-check→activate with cancellation coverage. Legacy scoped profile
installation remains available through migration issue 08. Proof: 540 MCP tests,
full requested shellcheck, help suite,
py_compile, and git diff check passed.

Independent integration review reran 151 targeted readiness/activation/install/
broker/writer tests plus help, shellcheck, and diff-check; all passed with no
additional finding.
