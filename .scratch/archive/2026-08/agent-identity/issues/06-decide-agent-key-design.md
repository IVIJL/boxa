# 06 — Decide: agent key + dedicated ssh-agent design

Status: closed
Label: wayfinder:grilling
Assignee: main-session

## Parent

[MAP](../MAP.md) — wayfinder map "Boxa agent identity".

## Question

Given the research facts from
[03](03-research-dedicated-agent-key-patterns.md), design the host-side
mechanics: key generation ceremony (who runs it, where the key lives,
passphrase or not), the dedicated boxa ssh-agent lifecycle (service vs
lazy spawn, socket path), how it composes with the existing SSH gate
(does `boxa ssh` grow an "agent identity" mode? can user-agent forwarding
and agent-key forwarding coexist per project?), revocation/rotation, and
which ADR 0026 invariants extend to it. Also settles the CONTEXT.md
vocabulary for the new concept.

## Acceptance criteria

- [ ] Resolution comment records the design decisions.
- [ ] Map updated; vocabulary fog patch graduated or resolved.

## Blocked by

[03 — Research: dedicated ssh-agent + single-key patterns](03-research-dedicated-agent-key-patterns.md)

## Comments

**2026-08-22 — resolution (user + main session)**

- **One agent key for all forges**: single ed25519 keypair registered on
  the GitHub machine user and the GitLab service account (fingerprint
  uniqueness is per identity/instance, no collision). Revocation =
  delete on both forges + delete local key.
- **Generation**: onboarding runs `ssh-keygen -t ed25519`, key lives
  under `~/.config/boxa/` (0600), **no passphrase** (an unattended agent
  gains nothing from one; protection = key never leaves the host + scoped
  forge rights). Comment `boxa-agent@<hostname>` so it is recognizable on
  forges.
- **Agent lifecycle**: no systemd (WSL2 idle-shutdown makes services
  moot); lazily spawned `ssh-agent -a <fixed socket path>`, resurrected
  via the existing `lib/ssh.sh` env-file + liveness pattern; the socket's
  **directory** is mounted into containers (inode footgun). Key loaded
  into the agent at boxa start.
- **SSH gate grows a third state**: `off` | `agent` (forward the boxa
  agent-key agent; recommended default from onboarding) | `user` (today's
  full personal-agent forwarding, kept as a conscious escalation).
  Per-project, mutually exclusive (one SSH_AUTH_SOCK in the container).
  ADR 0026 invariants extend to the new agent.
- Vocabulary for CONTEXT.md (finalize in the spec): **Agent key**, gate
  states off/agent/user.
