# 09 — MCP diagnostics, documentation, and integration proof

Status: done

## Parent

ADR 0021 — Project-selected MCP catalog and agent-trusted execution.

## What to build

Finish the user-facing operating path for the catalog model. Doctor and status
must distinguish catalog membership, installation/readiness, Project activation,
consumer render drift, service isolation, agent trust, and degraded Docker
secret isolation. Safe `doctor --fix` actions may restore managed render output
or directories but must not activate entries, grant trust, accept degraded
isolation, start a Boxa, or modify a tracked Codex config without authorization.

Update CLI help and MCP documentation from the legacy global-profile model to
the catalog/install/activation/execution-mode model, including persistence,
migration, restart behavior, Docker limitations, and the exact trusted Codex
delegation workflow. Add a full integration scenario proving migration through
Claude delegation to an agent-trusted Codex stub while unrelated Projects remain
empty.

## Acceptance criteria

- [x] List/status/doctor expose every catalog→readiness→activation→consumer→mode
      state distinctly in human and JSON output with no secret values.
- [x] Doctor detects missing runtime prerequisites, stopped targets, render drift,
      forbidden trusted secrets, stale activation references, and degraded Docker
      isolation with actionable messages.
- [x] `doctor --fix` performs only safe derived-state repair and respects all
      trust, activation, tracked-config, and lifecycle confirmation boundaries.
- [x] Help documents interactive and non-interactive commands/flags and contains
      no legacy `--global` activation semantics.
- [x] MCP docs explain runtime persistence, host-owned state, Project-key move
      behavior, consumer rendering, reload requirements, peer trust domain, and
      the temporary Docker secret exception.
- [x] End-to-end tests cover fresh state, legacy migration, explicit Claude-only
      trusted Codex activation, broker launch, deactivation, and no cross-Project
      exposure.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes.
- [x] The repository's complete existing test suite passes using its native test
      commands.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes.
- [x] `git diff --check` passes.

## Blocked by

- `08-migration-import-onboarding.md`

## Comments

- Independent review found retained MCP-store values were not diagnosed for an
  otherwise secret-free agent-trusted entry. Doctor now checks inactive and
  active identities across display name, stable ID, and `secretStoreKey` with
  presence-only output. Independent post-fix proof: 64 focused tests plus
  shellcheck, byte-compilation, help, and diff checks passed.

- Implemented unified secret-safe Project status across catalog membership,
  readiness checks, activation, consumer renders, execution mode/concrete user,
  runtime snapshot and Docker degradation. Doctor safe fixes are restricted to
  derived Boxa-owned state; tracked Codex config, activation, trust,
  acknowledgement, installation and lifecycle remain explicit boundaries.
- Added `tests/test_mcp_integration.py`: disposable end-to-end proof from empty
  state and legacy migration through Claude+Codex activation, host-authorized
  Claude-only Codex delegation, independent trusted snapshot authorization,
  constrained Docker adapter, doctor repair, no cross-Project exposure,
  deactivation and stable-identity removal. No network/login/image/user config
  is used.
- Proof: MCP suite 591 tests OK; complete Python suite 590 tests OK before the
  final two integration assertions and the final MCP suite 591 tests OK; every
  `tests/*.sh` passed (the explicitly host-only real-container memory test
  skipped behind its `BOXA_INTEGRATION=1` guard); full shellcheck at info level,
  `python3 -m py_compile scripts/mcp/*.py`, MCP help proof and
  `git diff --check` passed.
- Independent-review follow-up: doctor now also rejects retained MCP-store
  values for every `agent-trusted` catalog identity, including inactive entries
  and identity-aware `secretStoreKey` blocks. The finding is presence-only and
  never emits the secret key, value, or store path. Focused integration/trust
  proof: 15 tests OK; final full MCP suite: 592 tests OK; full shellcheck,
  `py_compile`, help, and `git diff --check` passed again.
