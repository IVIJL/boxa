# 09 — Task: write the ADR + implementation-ready spec

Status: closed
Label: wayfinder:task
Assignee: main-session

## Parent

[MAP](../MAP.md) — wayfinder map "Boxa agent identity".

## Question

Fold all closed decisions into the destination artifacts: an ADR
(docs/adr/) for the agent-identity architecture and a spec/PRD under
`.scratch/agent-identity/` ready for /to-issues. Includes CONTEXT.md
glossary additions decided in [06](06-decide-agent-key-design.md) and the
commit-signing question if it graduated from fog. HITL: user reviews the
draft before the map closes.

## Acceptance criteria

- [ ] ADR drafted, spec/PRD drafted, user has reviewed.
- [ ] Map's Decisions so far complete; no open tickets, no fog left.

## Blocked by

[08 — Decide: onboarding UX](08-decide-onboarding-ux.md),
[10 — Decide: private-repo strategy](10-decide-private-repo-strategy.md)

## Comments

**2026-08-22 — draft ready (main session)**

- ADR drafted: `docs/adr/0032-per-installation-agent-identity.md`
  (status: proposed until user review).
- Spec drafted: [PRD.md](../PRD.md) — F1 agent key+agent, F2 gate third
  state, F3 forge store+CLI, F4 container delivery, F5 onboarding,
  F6 docs/glossary; feature-level acceptance + live-host verification
  list.
- Awaiting user review; ticket closes (and the map with it) once
  approved.

**2026-08-22 — user approved.** ADR 0032 flipped to accepted; map
complete. Next: /to-issues on PRD.md, then /afk-feature-workflow.
