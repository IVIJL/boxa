# GitLab self-hosted CE: limited-rights access for a coding agent

Research for ticket [02](../issues/02-research-gitlab-ce-access-model.md).
Date: 2026-08-22. Source of truth: docs.gitlab.com (current version, 18.x)
and gitlab-org/cli docs. Note: "CE" corresponds to the **Free tier of
GitLab Self-Managed** in the docs' availability badges; anything marked
"Premium/Ultimate only" is unavailable on CE.

Target ceiling (from the [map](../MAP.md)): push unprotected branches, open
MRs, issues read/write, read CI; **not** protected-branch push, repo admin,
releases, member management.

## Service accounts

- Availability: **Free, Premium, Ultimate — including self-managed** per
  current docs (<https://docs.gitlab.com/user/profile/service_accounts/>).
  **Caveat: Free-tier availability is new** — introduced in 16.3 as
  Premium+, became Free-tier **beta in GitLab 18.10, GA in 18.11** (per the
  page's history notes). An older self-hosted CE instance will NOT have
  them; verify the instance version before relying on this.
- Free-tier limit: up to 100 service accounts per self-managed instance.
- Non-billable: do not use a seat (moot on CE, which has no seat limits
  anyway).
- Instance-level service accounts are created by an admin; they cannot
  sign in through the UI and authenticate **only via personal access
  tokens** (their PATs can optionally be non-expiring via an instance
  setting).
- Get memberships like normal users: any role per group/subgroup/project.
- Effectively "machine user done right" — same membership/role model, no
  UI login surface, admin-owned lifecycle.

## Plain machine user (regular user created by admin)

- Licensing/seat impact on CE: **none** — CE has no license seat limits;
  users are free. (Billable-user accounting applies to Premium/Ultimate
  licenses only.)
- Role fit vs the ceiling
  (<https://docs.gitlab.com/user/permissions/>):
  - **Reporter**: issues read/write, comments, view pipelines/job logs —
    but **cannot create branches, push, or open MRs**. Below the ceiling.
  - **Developer**: everything Reporter has **plus** push to unprotected
    branches, create branches, open MRs. Cannot manage members, project
    settings, or deploy keys/tokens. **Closest match to the ceiling.**
  - **Maintainer**: adds member management, project settings, deploy
    keys/tokens — exceeds the ceiling. Avoid.
- One over-grant at Developer: Developers **can create releases** (via tag
  push / releases API), which the ceiling excludes. CE cannot subtract
  this from the Developer role (custom roles are Ultimate-only). Mitigate
  with **protected tags** (Free tier) restricting tag creation to
  Maintainers if it matters; otherwise accept as residual.
- Membership: per-project membership gives the narrowest blast radius;
  group membership grants the role on all projects in the group. For an
  agent identity, prefer explicit per-project (or per-subgroup) Developer
  membership over top-level group membership.

## Project access tokens / group access tokens

(<https://docs.gitlab.com/user/project/settings/project_access_tokens/>,
<https://docs.gitlab.com/user/group/settings/group_access_tokens/>)

- Availability on self-managed: **any license, including CE** (the
  Premium+ restriction applies to GitLab.com only).
- Each token **creates a bot user** (`project_{id}_bot_...` /
  `group_{id}_bot_...`), non-billable, one bot per token.
- Token gets a role (Guest..Owner) + scopes (`api`, `read_repository`,
  `write_repository`, ...).
- Expiry: default 365 days, max 365 (400 with a 17.6+ feature flag);
  admins can adjust the instance max. **Cannot be non-expiring.**
- Drawbacks for an agent identity: bot user is per-project/per-group (not
  one identity across the forge), MRs/comments appear authored by an
  auto-named bot, **no SSH** (bot has no SSH keys usable in practice —
  auth is token-over-HTTPS), and forced expiry means rotation churn.

## Personal access tokens (of the machine user / service account)

(<https://docs.gitlab.com/user/profile/personal_access_tokens/>)

- Available on all tiers.
- Scopes: `api` (full read/write API + git-over-HTTPS + registries),
  `read_api`, `read_user`, `read_repository`, `write_repository`, `sudo`
  (admin only), `admin_mode`, `create_runner`, `k8s_proxy`, `ai_features`.
- For the agent's needs (`glab`: MRs, issues, CI read) the practical
  minimum is **`api`** — `read_api` cannot create MRs/issues, and there is
  no finer classic-PAT scope for "issues+MRs but not settings" (the API
  enforces the user's **role** as the second gate, which is where the real
  limiting happens: PAT scope ∩ Developer role = the ceiling).
- Expiry: default 365 days if none given; max 365 (400 via 17.6+ flag);
  self-managed admins can set instance max lifetime. **Service-account
  PATs may be non-expiring** if the instance setting allows.

## Deploy keys / deploy tokens

- **Deploy keys** (<https://docs.gitlab.com/user/project/deploy_keys/>):
  SSH git access only, read-only or read-write per project. **No API, no
  issues, no MRs.** Write pushes to protected branches only if the key is
  explicitly allowed (and "allow deploy key to push to protected branch"
  is Premium+). Not sufficient alone; could pair with a PAT but then the
  identity is split across two credentials for no gain over an SSH key on
  the machine user.
- **Deploy tokens** (<https://docs.gitlab.com/user/project/deploy_tokens/>):
  HTTP auth with scopes `read_repository`, `read/write_registry`,
  `read/write_package_registry`, etc. **Repository scope is read-only
  (clone/pull); no git push, no general API.** Not usable for the ceiling.

Verdict: both are below the ceiling on the API/MR/issue axis; irrelevant
for this feature except as non-options.

## glab CLI authentication

(<https://gitlab.com/gitlab-org/cli/-/blob/main/docs/source/auth/login.md>,
README)

- `glab auth login --hostname gitlab.example.com --stdin` (token piped),
  or `--token`; OAuth `--web` / `--device` (device flow needs GitLab
  17.9+). Env vars `GITLAB_TOKEN` / `GITLAB_ACCESS_TOKEN` take precedence
  over stored config; `GITLAB_HOST` (alias `GITLAB_URI`) selects the
  self-hosted instance; `GITLAB_API_HOST` if API and git hosts differ.
- Config: OS keyring if available, else plaintext
  `~/.config/glab-cli/config.yml` (`--insecure-storage` forces file). In a
  boxa container, env-var injection (`GITLAB_TOKEN` + `GITLAB_HOST`)
  avoids persisting the token in the container filesystem — mirrors the
  ADR 0025 concern about `~/.config/gh`.
- `--git-protocol ssh|https`: with `ssh`, git push/pull rides the
  **forwarded agent key** (matches the map: key never enters container)
  while glab uses the PAT for API. With `https`, glab configures the token
  as git credential — workable fallback, but the token then covers git too.
- Token scope: glab needs `api` for MR/issue/CI operations.

## Protected branches on CE

(<https://docs.gitlab.com/user/project/repository/branches/protected/>)

- Available on **Free/CE**. Default branch is protected by default.
- CE can set "Allowed to push and merge" / "Allowed to merge" to role
  buckets: **No one / Developers + Maintainers / Maintainers**. Per-user
  and per-group allow lists are Premium+ — so on CE you cannot say "all
  Developers except the agent"; the agent must simply hold Developer while
  push is restricted to **Maintainers** (or No one, merge-only via MR).
- Force-push is off unless toggled; protected branches cannot be deleted
  by git push.
- Consequence: keeping the agent out of `main` on CE = protect `main` with
  push allowed to Maintainers (humans hold Maintainer, agent holds
  Developer). This is forge-side enforcement, exactly as the map requires.

## Recommendation

**Machine identity with Developer role + `api`-scoped PAT + its own SSH
key** — realized as an **instance service account if the CE instance is ≥
18.11**, else a plain admin-created machine user (functionally identical
on CE; migrate to a service account after upgrade).

- Membership: per-project (or per-subgroup) **Developer** — meets the
  ceiling except the releases over-grant (accept, or protect tags).
- `main` (and other protected branches): "Allowed to push and merge" =
  Maintainers → agent structurally cannot touch them.
- Git over **SSH** with the identity's own key served by the host-side
  ssh-agent (ADR 0026 pattern); `glab` over HTTPS API with the PAT via
  `GITLAB_TOKEN` + `GITLAB_HOST` env, not a config file in the container.
- PAT: `api` scope, max-lifetime expiry (365 d) with rotation; if service
  account + instance setting, optionally non-expiring.
- Rejected: project/group access tokens (per-scope bot identities, no SSH,
  forced expiry, bot-named authorship), deploy keys/tokens (no API/MR/
  issue surface), Maintainer role (exceeds ceiling), Reporter (can't push).

Trade-offs: a plain machine user is indistinguishable from a human account
(UI login possible — set an unusable password / no email access);
Developer's release ability slightly exceeds the ceiling and CE cannot
carve it out (custom roles are Ultimate-only); per-user branch allow lists
being Premium+ means branch policy must be expressed in role buckets.
