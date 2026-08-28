# 01 — Research: GitHub limited-rights options for a personal account

Status: closed
Label: wayfinder:research
Assignee: research-agent

## Parent

[MAP](../MAP.md) — wayfinder map "Boxa agent identity".

## Question

For a **personal GitHub account** (no org), what are the viable ways to
give a coding agent scoped access matching this ceiling: clone/fetch/push
to unprotected branches, open PRs, read+write issues/comments, read CI
logs — and explicitly NOT protected-branch push, repo admin, releases,
member management?

Cover, against primary GitHub docs:

- **Fine-grained PATs**: available scopes/permissions, per-repo selection,
  expiry/rotation rules, whether `gh` CLI and git-over-HTTPS work with
  them, limitations on personal accounts.
- **Machine user account** (second account owned by the user): ToS
  legality, free-plan viability, collaborator invites and what permission
  levels a collaborator on a personal repo can have (personal repos have
  no granular roles — verify), SSH key on the machine account.
- **GitHub App**: is it practical for a single person's own repos? How git
  auth and `gh` work with installation tokens; token lifetime (1h)
  implications for an always-on dev container.
- **Deploy keys**: per-repo read/write SSH keys — what they can and cannot
  do (no API/PR/issue access — verify), the one-key-one-repo restriction.
- Interplay with **branch protection** on personal accounts (free plan:
  protected branches on public repos only? verify current state).
- What do established agent products (Copilot coding agent, others) do —
  only if documented in primary sources.

Recommend 1–2 combos as best practice, with trade-offs.

## Acceptance criteria

- [x] Findings written to `.scratch/agent-identity/research/github-access-model.md` with source links.
- [x] Resolution comment below + map "Decisions so far" line (the recorded answer is the fact set, decision itself is ticket 04).

## Blocked by

None — can start immediately.

## Comments

**2026-08-22 — research-agent — resolved.** Findings in
[research/github-access-model.md](../research/github-access-model.md).
Summary: personal-repo collaborators have exactly two levels (owner /
read+write collaborator, no granular roles — confirmed). A second
machine account is explicitly ToS-legal (one free personal + one machine
account). Fine-grained PATs (GA 2026) cover the ceiling well on one's own
repos but **cannot act on collaborator repos**, killing "machine account +
fine-grained PAT"; the machine account needs SSH + classic PAT instead.
Deploy keys are git-only (no PR/issue/API) and one-per-repo — rejected.
GitHub Apps install fine on personal accounts but 1-hour installation
tokens need a minting daemon — disproportionate. Branch protection on
GitHub Free exists on **public repos only**; admin bypass is on by
default, so the owner's own PAT bypasses protection unless no-bypass is
set. Copilot coding agent's documented model (distinct identity, pushes
confined to `copilot/*`, protection as backstop) supports the same shape.
Recommendation: machine account collaborator (host SSH key via dedicated
agent + its classic PAT for `gh`); fallback for low-friction onboarding:
fine-grained PAT on the user's own account over HTTPS.
