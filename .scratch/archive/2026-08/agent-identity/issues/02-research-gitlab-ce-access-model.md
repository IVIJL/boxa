# 02 — Research: GitLab self-hosted CE limited-rights options

Status: closed
Label: wayfinder:research
Assignee: research-agent

## Parent

[MAP](../MAP.md) — wayfinder map "Boxa agent identity".

## Question

On a **self-hosted GitLab CE** instance (admin access available, creating
users is fine), what is the best way to give a coding agent scoped access
matching the ceiling in the map (push unprotected branches, open MRs,
issues read/write, read CI, nothing admin-ish)?

Cover, against primary GitLab docs (verify CE vs Premium/Ultimate gating
for each):

- **Service accounts**: which tier? (believed Premium+ — verify for
  self-managed CE.)
- **Plain machine user** (regular user created by admin): licensing/seat
  impact on CE (none? verify), membership roles — what exactly Developer
  vs Reporter vs Maintainer can do relative to the ceiling; per-project vs
  group membership.
- **Project access tokens** and **group access tokens** on self-managed
  CE: availability, roles, expiry policy, and whether they create bot
  users.
- **Personal access tokens** of the machine user: scopes (`api`,
  `read_repository`, `write_repository`…), expiry maximums.
- **Deploy keys / deploy tokens**: what they cover, write access,
  API limits.
- How **`glab` CLI** authenticates (token env vars, `glab auth login`,
  self-hosted host config) and how git-over-SSH vs git-over-HTTPS pair
  with each option.
- Protected branches in CE: enforcement that keeps the agent out of main.

Recommend one setup (likely machine user + role + PAT + SSH key — verify)
with trade-offs.

## Acceptance criteria

- [x] Findings written to `.scratch/agent-identity/research/gitlab-ce-access-model.md` with source links.
- [x] Resolution comment below + map "Decisions so far" line (decision itself is ticket 05).

## Blocked by

None — can start immediately.

## Comments

**2026-08-22 — research-agent — resolution**

Findings: [research/gitlab-ce-access-model.md](../research/gitlab-ce-access-model.md).
Recommendation: machine identity with **Developer** role (per-project) +
`api`-scoped PAT for `glab` (via `GITLAB_TOKEN`/`GITLAB_HOST` env) + own
SSH key for git; use an **instance service account** if the CE instance is
≥ 18.11 (Free-tier service accounts are new: beta 18.10, GA 18.11 — older
CE must use a plain admin-created user, no seat cost on CE). Protect
`main` with push = Maintainers (CE has role buckets only; per-user allow
lists are Premium+). Project/group access tokens work on CE but create
per-scope bot users with forced ≤365 d expiry and no SSH; deploy keys/
tokens have no API/MR/issue surface. Residual over-grant: Developer can
create releases (CE can't carve it out; mitigate via protected tags).
