# 08 — Decide: onboarding UX (provisioning step + wizard)

Status: closed
Label: wayfinder:grilling
Assignee: main-session

## Parent

[MAP](../MAP.md) — wayfinder map "Boxa agent identity".

## Question

Design the onboarding flow for a stranger installing boxa: a provisioning
category-B step (ADR 0017; probe `ok/declined/missing` + repair, reference
`ensure-ssh-gate.sh` / `ensure-mcp-onboarding.sh`) plus the guided path.
Two entry situations: (a) user already has an agent key / gh / glab set up
— adopt it with consent (ADR 0031 conventions); (b) nothing exists — walk
them through key generation, registering it on the forge(s), creating the
machine user / token with the right scopes. Decide: step granularity (one
step or per-forge), what is skippable, how forge-side manual actions are
guided (checklist? `wizard` skill-style script? links), and the exact
probe semantics.

## Acceptance criteria

- [ ] Resolution comment records the flow (states, prompts, probe/repair
      contract).
- [ ] Map updated.

## Blocked by

[04](04-decide-github-model.md), [05](05-decide-gitlab-model.md),
[06](06-decide-agent-key-design.md), [07](07-decide-token-delivery.md)

## Comments

**2026-08-22 — user input (from ticket 04 session)**: one blessed
recommended path; everything else = documented "do it yourself" pointers,
people adapt to their own workflow. Adopt-existing is a first-class
entry: users typically have several SSH keys (pick which boxa gets) and
existing gh/glab logins (fill them in); rights on the forge side are
their own business then.

**2026-08-22 — resolution (user + main session)**

- **One category-B provisioning step** "agent-identity": offered once,
  generates the key + sets up the boxa agent, then prints how to continue
  per forge. Forge setup itself happens on demand via `boxa forge` /
  `boxa ssh` (it is per-project anyway) — no per-forge provisioning
  steps.
- **Manual forge actions guided by an interactive CLI checklist**: exact
  steps with URLs (create machine user / service account, invite, create
  PAT), pausing at each, and **verifying** each: key via `ssh -T
  git@github.com` through the agent, token via `gh api user` /
  `glab api user` showing who it authenticated as.
- **Three-way entry at both decision points**: agent key = generate new
  (recommended) / pick an existing key (reuse the key picker) / skip;
  forge tokens = paste via blessed path / consent-first import from host
  gh/glab config (ADR 0031) / skip and handle in-container.
- **Probe semantics** (mirrors ensure-ssh-gate.sh): `ok` = agent key
  exists (or an existing key adopted) and at least one usage mode is on;
  `declined` = `agent-identity-seen` marker; `missing` = neither. Repair
  re-runs the wizard.
- **Commit signing is OUT OF SCOPE** (forge "Verified" badge requires the
  signing key to belong to the commit author's account — author is the
  human, key is the machine user's, so no badge is attainable; can be a
  tiny future feature). Instead, per-commit attribution comes from
  **author = human user, committer = machine user** (`GIT_COMMITTER_*`
  env injected when the forge gate is on) — forges render "authored by
  human, committed by agent", which restores the audit trail signing was
  meant to give.
