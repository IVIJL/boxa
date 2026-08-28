# 08 — MCP catalog migration, import, and onboarding

Status: done

## Parent

ADR 0021 — Project-selected MCP catalog and agent-trusted execution.

## What to build

Migrate the legacy global/Project MCP profile model into the catalog and explicit
Project activations without restoring unwanted global exposure. All legacy
definitions become catalog entries. Former global definitions get no activation.
Project definitions retain activation only in their original Project and only
for consumers where they were actually rendered. Migration never infers trust.

Update import and onboarding to the same model. Import discovers/classifies and
adds catalog definitions only. A wizard may visibly combine import, install,
readiness re-check, and activation, but cancellation at each boundary preserves
the completed earlier facts without silently performing later ones.

## Acceptance criteria

- [x] Migration is versioned, idempotent, resumable after interruption, and keeps
      the original legacy data recoverable until successful completion.
- [x] Every legacy global and Project definition is deduplicated into the catalog
      without leaking secret values into catalog data.
- [x] Legacy global definitions receive zero activations.
- [x] Legacy Project definitions retain only their original Project and actually
      rendered Claude/Codex consumers; disabled/non-rendered choices stay inactive.
- [x] Every migrated entry defaults to service-isolated; no import or classifier
      can infer agent trust.
- [x] Plain import changes catalog only and never installs, activates, or renders.
- [x] Interactive onboarding presents import/install/activate as distinct
      confirmed steps and non-interactive onboarding never prompts.
- [x] Existing inherited/manual agent entries remain untouched throughout.
- [x] Tests cover malformed/partial legacy state, duplicate names with differing
      definitions, interruption/retry, and mixed global/Project profiles.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes after shell changes.

## Blocked by

- `07-catalog-lifecycle.md`

## Comments

- Independent review after stable-ID credential hardening: 140 focused
  migration/import/onboarding/broker/readiness/lifecycle tests passed; targeted
  shellcheck, Python byte-compilation, and diff check were clean. Prepared
  crash recovery and runtime credential resolution were inspected directly.

2026-07-27: implemented without commit. Added a versioned prepared→complete
migration audit manifest, deterministic stable-ID deduplication and auditable
name-conflict resolution, exact issue-07 lock/pre-image rollback, and resumable
reconciliation after a crash that bypasses compensating rollback. Legacy source
profiles and name-keyed credentials remain recoverable; migrated runtime
credential lookup is bound to the stable catalog ID so another same-name
identity cannot inherit them. Former globals get no activation; Project
activations are reconstructed only from exact, enabled Claude/Codex wrapper
renderings in the original Project. Import now changes the secret-free catalog
only, and onboarding names discover/import/install/activate as separate steps
with zero active MCPs in a fresh Project. Manual/inherited agent entries remain
untouched. Proof: 589 MCP tests, full requested shellcheck, Python
byte-compilation, help suite, and `git diff --check` passed.
