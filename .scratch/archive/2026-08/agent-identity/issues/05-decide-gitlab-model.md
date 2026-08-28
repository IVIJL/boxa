# 05 — Decide: GitLab CE access model for the agent identity

Status: closed
Label: wayfinder:grilling
Assignee: main-session

## Parent

[MAP](../MAP.md) — wayfinder map "Boxa agent identity".

## Question

Given the research facts from
[02](02-research-gitlab-ce-access-model.md), pick the self-hosted GitLab
CE setup: machine user + role + PAT/SSH key, or project/group access
tokens, or deploy keys/tokens. Must satisfy the capability ceiling,
work with `glab` against a self-hosted host, and generalize for other
boxa users (who may be on gitlab.com or CE without admin rights —
decide how much the spec accommodates that).

## Acceptance criteria

- [ ] Resolution comment records the chosen model and why.
- [ ] Map updated.

## Blocked by

[02 — Research: GitLab CE limited-rights options](02-research-gitlab-ce-access-model.md)

## Comments

**2026-08-22 — user input**: company CE instance just upgraded to
19.3.0, so instance service accounts (Free-tier GA in 18.11) are
available — the "plain machine user" fallback branch is likely moot.

**2026-08-22 — resolution (user + main session)**

- **Instance service account** (admin-created, no UI login, no seat
  cost); plain machine user stays documented as the fallback for older
  CE instances (< 18.11) or users without admin.
- Role **Developer**, membership granted **per project** (invite
  philosophy mirrors the GitHub collaborator model).
- **PAT scope `api`, 1-year expiry** for `glab` auth.
- `main` protected with push = Maintainers (humans = Maintainer, agent =
  Developer); **protected tags `v*`** close the Developer→tag-push→
  release over-grant.
