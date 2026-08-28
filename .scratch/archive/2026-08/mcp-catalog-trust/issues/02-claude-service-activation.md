# 02 — Service-isolated Project activation for Claude Code

Status: done

## Parent

ADR 0021 — Project-selected MCP catalog and agent-trusted execution.

## What to build

Deliver the first complete **MCP activation** tracer bullet for an already
available direct-process catalog entry. From a running Boxa, the user can
activate the entry for Claude Code in one Project, see it in the Project's
effective MCP list, connect through `boxa-mcp-run`, and execute it as
**boxa-mcp** through the broker. Deactivation removes the managed Claude entry
and prevents new launches without terminating an already-connected process.

Activations are host-owned, keyed by the canonical absolute Project path, and
carry an explicit consumer set. No activation follows a moved directory or new
clone. Non-interactive activation requires `--for claude`; interactive use may
select the catalog entry and consumer. The target Boxa must be running and is
never started implicitly.

## Acceptance criteria

- [x] Activation records catalog identity, Project key, and explicit `claude`
      consumer without copying the server definition.
- [x] A ready direct-process entry renders only its managed Claude Project entry
      and preserves all inherited/manual configuration.
- [x] The broker rejects absent, wrong-Project, disabled, deleted, and
      wrong-consumer activation requests.
- [x] A valid request launches as `boxa-mcp`, relays stdio end to end, and has
      Project read/write access under the existing namespace boundary.
- [x] Fresh Projects remain empty; activation never leaks to another Project.
- [x] Deactivation re-renders immediately, blocks new connections, and prints a
      reload/restart notice rather than killing a live process.
- [x] `boxa mcp list` distinguishes catalog availability from current-Project
      activation.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes after shell changes.

## Blocked by

- `01-mcp-catalog.md`

## Comments

2026-07-27: implemented without commit. Added host-owned activation state,
Project/consumer-aware Claude render and broker protocol authorization, catalog
remove guard, deactivate/list UX, and real broker stdio tracer proof. Full proof:
531 MCP tests and requested shellcheck passed. Independent review found and
returned one partial-write defect; activate/deactivate now rollback activation,
runtime, Claude config, and render-state to exact pre-images, covered by failure
regressions. Reviewer reran 151 targeted tests plus shellcheck/diff-check.
