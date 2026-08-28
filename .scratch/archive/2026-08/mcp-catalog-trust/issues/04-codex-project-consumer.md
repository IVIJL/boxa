# 04 — Project-local Codex MCP consumer rendering

Status: done

## Parent

ADR 0021 — Project-selected MCP catalog and agent-trusted execution.

## What to build

Allow an MCP activation to select Codex as a Project-local consumer. Keep the
host-owned activation as source of truth and render a clearly delimited managed
`boxa-*` MCP section into the trusted Project's `.codex/config.toml`. Preserve
all non-Boxa content byte-for-byte outside the managed region and remove only
Boxa-owned entries on deactivation.

An otherwise untracked generated config is excluded locally through
`.git/info/exclude`, never by modifying shared `.gitignore`. If the Codex config
is already tracked, activation refuses by default; explicit
`--allow-tracked-codex-config` permits the visible working-tree edit. Selecting
Claude, Codex, or both produces only those consumers' entries.

## Acceptance criteria

- [x] `--for codex` and `--for claude,codex` round-trip through activation state
      and render only selected consumers.
- [x] Generated Codex MCP configuration is valid project-scoped TOML and calls
      the same Boxa launcher/activation identity as Claude.
- [x] Managed-region updates are idempotent and preserve comments, formatting,
      manual MCP entries, and all other non-Boxa content outside the region.
- [x] A new/untracked generated file is added only to `.git/info/exclude` using
      worktree-safe Git directory resolution; shared `.gitignore` is untouched.
- [x] A tracked config is unchanged on default refusal and changes only after
      explicit `--allow-tracked-codex-config`.
- [x] Deactivation removes the managed region when empty without deleting a
      user-owned file or unrelated content.
- [x] Tests cover normal repositories, linked worktrees, untracked existing
      configs, tracked configs, and malformed managed regions.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes after shell changes.

## Blocked by

- `02-claude-service-activation.md`

## Comments

2026-07-27: implemented without commit. Added `codex`/combined consumer state,
Project TOML managed region, local worktree-aware exclude, tracked-config opt-in,
rollback, validation, and regression coverage. Full proof: 545 MCP tests,
requested shellcheck, help, py_compile, and diff-check passed. Independent review
reran 130 targeted tests plus help/shellcheck/diff-check with no finding.

2026-07-27: implemented without commit. Added Codex and combined consumer
activation, transactional Project-local managed TOML regions, tracked-config
opt-in, and repository-local exclusion resolved safely for linked worktrees.
Covered normal/untracked/tracked/malformed/worktree paths and consumer/broker
identity. Proof: 545 MCP tests, full requested shellcheck, help suite,
py_compile, and git diff check passed.
