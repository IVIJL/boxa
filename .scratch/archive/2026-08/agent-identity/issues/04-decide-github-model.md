# 04 — Decide: GitHub access model for the agent identity

Status: closed
Label: wayfinder:grilling
Assignee: main-session

## Parent

[MAP](../MAP.md) — wayfinder map "Boxa agent identity".

## Question

Given the research facts from
[01](01-research-github-access-model.md), pick the GitHub setup for a
personal account: fine-grained PAT vs machine user vs GitHub App vs
deploy keys (or a combo, e.g. machine-user SSH key for git + fine-grained
PAT for `gh`). Must satisfy the capability ceiling in the map and stay
painless for a stranger onboarding into boxa. Includes: what `gh auth`
uses, how git-over-SSH vs HTTPS is chosen, expiry/rotation policy.

## Acceptance criteria

- [ ] Resolution comment records the chosen model and why.
- [ ] Map updated (Decisions so far; fog graduated if the answer sharpens
      commit signing or git author plumbing).

## Blocked by

[01 — Research: GitHub limited-rights options](01-research-github-access-model.md)

## Comments

**2026-08-22 — resolution (user + main session)**

- **Model: machine user account** (second free personal account, ToS
  §B.3 legal), invited per repo as collaborator. Its SSH key goes into
  the dedicated boxa agent; git remotes stay `git@github.com`.
- **`gh` auth: classic PAT of the machine user**, scope `repo` only,
  **1-year expiry** with rotation reminder (fine-grained PATs rejected:
  they cannot act on collaborator repos). No `workflow` scope; workflow
  file edits travel via SSH push.
- **Public repos**: capability ceiling enforced by branch protection /
  ruleset (available on Free for public repos; must be configured —
  onboarding should nudge this).
- **Private repos (Free plan has no protection there)**: default stance
  is *do not invite* the machine user (personal-repo collaborators are
  always read+write; read-only invite impossible). Push-approval ideas
  for private repos spun off into
  [10 — Decide: private-repo strategy](10-decide-private-repo-strategy.md).
- **Onboarding shape**: one blessed path (machine user), a documented
  do-it-yourself fallback (e.g. fine-grained PAT on the user's own
  account, HTTPS remotes), and adopt-existing supported — users pick
  which of their SSH keys / gh logins boxa gets and manage rights
  themselves.
