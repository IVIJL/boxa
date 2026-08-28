# 12 — SSH CLI surface and reporting for three gate states

Status: done

## Parent

[PRD](../PRD.md) F2; ADR 0032 decision 2.

## What to build

Finish the user-facing surface around the three-state gate. `boxa ssh`
subcommands let the user switch a project (and `--global`) between
`off`, `agent`, and `user` with the same consent-first, default-safe
prompts the gate has today; switching warns `boxa stop && boxa` when a
running container is affected. The existing frozen-reality report for a
running container states **which** agent is forwarded (dedicated agent
vs user agent vs none), not just whether one is. `boxa ssh add` (key
picker into the user agent) stays `user`-mode-only and says so if
invoked in `agent` state. `docs/ssh.md` updated for the three states
and the Agent key.

## Acceptance criteria

- [x] Project and global switching across all three states works and is
      covered by tests (real pty for interactive prompts, no stubbed
      consent seams).
- [x] Running-container status names the forwarded identity correctly
      in all three states.
- [x] `boxa ssh add` in `agent` state explains itself instead of
      touching the dedicated agent.
- [x] `docs/ssh.md` documents the three states; UI strings English.
- [x] shellcheck clean.

## Implementation

Delegated to Codex (thread `01a02867-ff00-7ff0-b719-9de50cf4c6b7`), commit
`814f4dd` on `feat/agent-identity`. Proof: shellcheck clean on
`docker-run.sh`, `lib/ssh.sh`, `tests/ssh.sh`; `tests/ssh.sh` 118/118
passed; `tests/test_ensure_ssh_gate.sh` 22/22 passed. No deviations from
spec reported.

## Blocked by

- [11 — Agent key, dedicated agent, gate state `agent`](11-agent-key-dedicated-agent-gate-state.md)

## Comments
