# 13 — Key registry with lazy silent re-add

Status: done

## Parent

ADR 0034 decision 9; supersedes the ADR 0026 memory-only key loading.

## What to build

A durable host-side **Key registry** recording the paths (never private
material) of every key that passed the Key picker. When a project's
container starts and its gate is on, the project agent is silently
re-populated from the registry: passphrase-less keys load without
interaction, a passphrase-protected key lets `ssh-add` prompt once —
lazy per project, never a batch sweep after host restart, and boxa
never touches the passphrase (no askpass, no keyring).

Enabling the gate on a project with no assigned keys offers the
add/assignment flow inline instead of failing to a manual
`boxa ssh add`. Removing a key from the registry stops future re-adds.

## Acceptance criteria

- [x] Keys added via the Key picker land in the registry as paths;
      registry file never contains key material.
- [x] After the project agent dies (simulated restart), the next
      container start restores its keys without user action for
      passphrase-less keys.
- [x] A passphrase key triggers exactly one `ssh-add` prompt for that
      project, none for untouched projects (pty test).
- [x] Enable-with-no-keys leads into the add flow inline.
- [x] shellcheck clean (incl. info).

## Verification (2026-08-25)

Implemented via Codex (MCP session, threadId
01a039ce-c159-7513-b04b-112232d99bc6), verified directly by the
orchestrator:
- `shellcheck -S style` clean on `lib/ssh.sh`, `docker-run.sh`,
  `tests/ssh.sh`.
- `bash tests/ssh.sh` (170 passed), `tests/test_ensure_ssh_gate.sh`
  (22 passed), `tests/forge.sh` (8 passed) all green.
- `python3 -m unittest tests.test_ssh_gate_pty` green (2 tests,
  including the new
  `test_container_start_lazily_prompts_for_only_its_registered_key`
  real-pty case proving exactly one passphrase prompt for the
  registered Project and none for an untouched one).
- Reviewed the `lib/ssh.sh`/`docker-run.sh` diff directly: registry is
  a fail-closed `[project]`/`key =` grammar (never sourced) at
  `~/.config/boxa/ssh-key-registry`, 0600/0700, atomic mktemp+mv
  writes; reapply reuses the existing `_boxa::ssh_add_key` primitive
  (same passphrase-less warning, same
  `SSH_ASKPASS=/bin/false`-then-real-attempt trick, no askpass helper,
  no keyring); `_boxa::ssh_add_project_keys_if_agent_unready` tries
  silent reapply first and only falls to the interactive picker when
  the registry is empty for that project (satisfies
  enable-with-no-keys → inline add flow via the existing `boxa ssh on`
  path); docker-run.sh's container-start block calls the same reapply
  only when the freshly (re)ensured Project agent currently holds zero
  keys — lazy, per-project, never a sweep across projects.
- Out of scope, deliberately deferred to issue 14: wiring persona
  assignment itself into the registry/project agent.

## Blocked by

- 11-binary-ssh-gate-project-agents.md

## Comments
