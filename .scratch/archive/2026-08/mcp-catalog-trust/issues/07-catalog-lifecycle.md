# 07 — Transactional MCP catalog lifecycle

Status: done

## Parent

ADR 0021 — Project-selected MCP catalog and agent-trusted execution.

## What to build

Complete catalog mutation semantics across every activated Project and consumer.
Cosmetic metadata and rename update independently. A runtime-affecting update is
transactional: every activated Project must be running and ready for the new
definition before catalog data and all Claude/Codex managed configs switch.
Failure leaves catalog, activations, and rendered configs unchanged.

Removing a catalog entry atomically cascades all Project/consumer activations,
destroys stable identity and trust, and re-renders affected configs. Deactivation
and removal prevent new broker connections but never claim to terminate an
already-connected process; output identifies affected consumers and tells the
user to reload/restart them.

## Acceptance criteria

- [x] Rename and cosmetic update preserve stable identity, execution mode,
      activations, and trust without unnecessary readiness checks.
- [x] Runtime update inventories all activations and refuses if any target Boxa
      is stopped or fails new readiness.
- [x] Successful runtime update changes catalog plus all managed Claude/Codex
      configs as one recoverable transaction.
- [x] Injected write/render failures prove rollback leaves no mixed old/new state.
- [x] Execution mode remains immutable while any activation exists.
- [x] Removal cascades all activations/configs, destroys trust identity, and a
      same-name recreate starts service-isolated with a new identity.
- [x] Deactivate/remove output warns about existing connections and names the
      agents requiring reload without killing processes.
- [x] Concurrent mutations are serialized or fail safely without lost updates.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes after shell changes.

## Blocked by

- `04-codex-project-consumer.md`
- `05-agent-trusted-codex.md`
- `06-service-docker-launch.md`

## Comments

- Independent review found an acknowledgement-only removal gap after prior
  deactivation. The transaction now persists activation state independently
  from consumer rendering and rolls it back exactly; two regressions cover
  cleanup and injected failure. Independent post-fix proof: 35 focused tests,
  shellcheck, Python byte-compilation, and diff check passed.

2026-07-27: implemented without commit. Added a reentrant in-process and
cross-process host mutation lock; identity-preserving rename/cosmetic updates;
all-activation running/readiness preflight for runtime changes; and exact
compensating rollback across catalog, activations, broker runtime, Claude,
multi-Project Codex config/local excludes, and affected secret stores. Catalog
removal now cascades activations and acknowledgements, purges identity/name-keyed
credentials, preserves inherited/manual config, and reports affected consumers
without terminating live processes. Added `boxa mcp update` plus multi-Project,
concurrency, second-render, runtime-write, Git-exclude, secret-rename, and remove
failure regressions. Follow-up review separated activation-store persistence
from consumer rendering, so removing a deactivated degraded entry durably clears
its stale acknowledgement without touching Claude/Codex; injected runtime-write
failure restores the exact acknowledgement pre-image. Proof: 581 MCP tests,
full requested shellcheck, Python
byte-compilation, help suite, and `git diff --check` passed.

2026-07-27 final whole-feature review: made the broker runtime snapshot the
last atomic commit point after every catalog, activation, secret-store, Claude,
and Codex write. A synchronized Agent-trusted authorization regression pauses a
late render and proves concurrent launches can observe only the old argv before
a forced rollback. Tracked Codex consent is explicitly per mutation and never
inferred or stored: update/rename, deactivate, and catalog removal preflight all
affected Projects and require `--allow-tracked-codex-config` only when tracked
bytes would change. Updated CLI help and ADR 0021. Final proof: 599 MCP tests,
full requested shellcheck, Python byte-compilation, help suite, and
`git diff --check` passed.
