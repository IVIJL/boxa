# 18 — Docs and glossary

Status: done

## Parent

[PRD](../PRD.md) F6; ADR 0032.

## What to build

The documentation slice: a new `docs/forge.md` covering the model
(machine identities, capability ceiling, per-project gate, env
delivery, in-container login persistence and env precedence, rotation,
the private-repo posture menu, the DIY fallback = fine-grained PAT over
HTTPS, the v1 known limitation that gate changes apply at container
creation). `docs/ssh.md` finalized for the three gate states (if issue
12 left gaps). CONTEXT.md glossary entries with Avoid-lists: **Agent
key**, **Agent identity**, **Forge store**, **Forge gate**, gate states
`off/agent/user`; a relationships line placing the forge gate in the
default-deny host-owned row next to the Allowlist and SSH gate. Boxa
skill (`skills/boxa/SKILL.md`) updated so in-box agents know how to ask
for the forge gate.

## Acceptance criteria

- [x] `docs/forge.md` complete and consistent with implemented CLI
      output (commands copy-pasteable).
- [x] CONTEXT.md terms added in the established format, no
      implementation detail in the glossary.
- [x] Boxa skill mentions `boxa forge` alongside the other host gates.
- [x] All strings English.

## Blocked by

- [12 — SSH CLI surface and reporting](12-ssh-surface-three-states.md)
- [14 — Container delivery: forge env + committer identity](14-container-delivery-env-committer.md)
- [17 — Forge checklists + adopt-existing](17-forge-checklists-adopt-existing.md)

## Comments
