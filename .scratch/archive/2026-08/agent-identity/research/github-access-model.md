# GitHub limited-rights options for a personal account

Research for ticket [01](../issues/01-research-github-access-model.md).
Date: 2026-08-22. Sources: docs.github.com and github.blog changelog
(primary). Facts verified via WebFetch/WebSearch against docs.github.com;
items marked *(unverified)* rest on search snippets only.

Target ceiling: clone/fetch/push to unprotected branches, open PRs,
read+write issues/comments, read CI logs. NOT: protected-branch push,
repo admin, releases, member management.

## 1. Fine-grained PATs

- GA since 2025-03-18; previously public preview
  ([changelog](https://github.blog/changelog/2025-03-18-fine-grained-pats-are-now-generally-available/)).
- Work fully on personal accounts: resource owner = the user's own
  account, token limited to resources of that single owner; repo access
  is "all repositories" or an explicit per-repo list
  ([Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)).
- Permission model maps cleanly onto the ceiling:
  - `Contents: read/write` → clone/fetch/push (git over HTTPS).
  - `Pull requests: read/write` → open/comment PRs.
  - `Issues: read/write` → issues + comments.
  - `Actions: read` → read CI runs/logs.
  - `Metadata: read` (mandatory baseline).
  - Simply omit `Administration`, `Releases` (Contents covers releases —
    see caveat below), member management is N/A on a personal account.
  - Caveat: releases live under the **Contents** permission in the REST
    API, so a Contents:write token *can* create releases. The ceiling's
    "no releases" cannot be expressed exactly with a fine-grained PAT;
    accept it or gate releases socially. *(API mapping well known;
    unverified against a fetched page in this session.)*
- Expiry: custom expiration; **infinite lifetime is allowed** for
  personal accounts (org/enterprise policies can cap it, irrelevant here)
  ([Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)).
  Default suggestion in the UI is 30 days, but that is only a default.
- git over HTTPS: token is used as the password (username ignored)
  ([same doc](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)).
  **No SSH**: PATs are HTTPS-only; a PAT-based model means the agent's
  git remotes must be HTTPS, not `git@github.com:` — SSH keys on the
  account are all-or-nothing and can't be scoped.
- `gh` CLI: works; recommended path is `GH_TOKEN` env var rather than
  `gh auth login --with-token` (the CLI's classic-scope checks
  `repo`/`read:org`/`gist` don't map onto fine-grained permissions and
  produce confusing warnings)
  ([gh manual](https://cli.github.com/manual/gh_auth_login),
  [cli/cli#6680](https://github.com/cli/cli/issues/6680)). Some `gh`
  commands touching org/gist APIs may fail — acceptable for
  PR/issue/CI-log use.
- Key limitation: fine-grained PATs **cannot contribute to repos where
  the user is an outside/repository collaborator** (still listed as a gap
  at GA); token targets only repos owned by the resource owner
  ([changelog](https://github.blog/changelog/2025-03-18-fine-grained-pats-are-now-generally-available/)).
  Consequence: a fine-grained PAT **on a machine account** is useless for
  repos it merely collaborates on — this kills the "machine account +
  fine-grained PAT" combo and matters for combo choice below.
- The token acts *as the user*. On the user's own account that means it
  acts as the repo **owner/admin identity** — permission selection limits
  the API surface, but see branch-protection interplay in §5.

## 2. Machine user account (second personal account)

- ToS-legal: "One person or legal entity may maintain no more than one
  free Account (if you choose to control a machine account as well,
  that's fine, but it can only be used for running a machine)." Machine
  account must be registered by a human, have its own valid email, and be
  used only for automation
  ([GitHub ToS §B.3](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service)).
  So: one free personal account + one free machine account is explicitly
  allowed.
- Free plan is viable (machine account needs no paid features; it doesn't
  own the repos).
- Collaborator permission levels on a personal-account repo: **only two
  levels exist — owner and collaborator**. A collaborator gets read AND
  write; "Collaborators can't have read-only access to repositories owned
  by a personal account" and no granular roles exist (granular roles
  require moving the repo to an organization)
  ([Permission levels for a personal account repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/repository-access-and-collaboration/permission-levels-for-a-personal-account-repository)).
  Confirmed: the ticket's "no granular roles on personal repos" holds.
- What a collaborator *cannot* do maps well onto the ceiling: no repo
  settings/admin, no deleting the repo, no managing collaborators, no
  editing branch protection. What it *can* do includes pushing, PRs,
  issues, and (write access implies) creating releases — same releases
  caveat as PATs.
- SSH key: the machine account is a normal account, so it gets its own
  SSH key → clean fit with the boxa design (host-side key + dedicated
  ssh-agent, `git@github.com:` remotes work). Deploy-key doc explicitly
  names "machine users" as the pattern for multi-repo automation access
  ([Managing deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)).
- For `gh` on the machine account: a **classic PAT** of the machine
  account works everywhere (including collaborator repos); a fine-grained
  PAT of the machine account does NOT reach collaborator repos (§1).
  Classic PAT `repo` scope is coarse but bounded by the collaborator
  role's ceiling — the blast radius is "whatever a collaborator can do on
  the invited repos", plus anything on the machine account's own (empty)
  namespace.
- Branch protection applies to a collaborator with no admin bypass — the
  machine account genuinely cannot push to a protected branch (§5).

## 3. GitHub App (self-owned)

- A person can create/own a GitHub App and install it on their **personal
  account**, selecting specific repos and permissions at install time
  ([Installing a GitHub App from a third party](https://docs.github.com/en/apps/using-github-apps/installing-a-github-app-from-a-third-party)).
- Same fine-grained permission model as fine-grained PATs; the app
  identity is separate from the user (commits/comments show as the app
  bot).
- Auth flow: app private key → signed JWT → POST
  `/app/installations/{id}/access_tokens` → installation token,
  **expires after 1 hour**
  ([Generating an installation access token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)).
- git over HTTPS works:
  `git clone https://x-access-token:TOKEN@github.com/owner/repo.git`
  (requires Contents permission)
  ([Authenticating as a GitHub App installation](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)).
  `gh` accepts the installation token via `GH_TOKEN`.
- Practicality for one person's always-on dev container: poor. The 1-hour
  lifetime demands a token-minting daemon or git credential helper on the
  host, the app's private key becomes a new secret to protect (strictly
  more powerful than one token), and stale-token failures mid-session are
  a real UX hazard. Rulesets *can* name an app as a bypass actor, which
  is the one capability PATs lack. This is the right architecture for
  products (it is what CI vendors use), overkill for a personal setup.

## 4. Deploy keys

- SSH key bound to **a single repository**; a key cannot be reused across
  repos on the same host. Read-only by default, optionally read/write
  ([Managing deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)).
- Git-transport only: no REST/GraphQL identity, so **no PRs, no issues,
  no CI-log reads** — confirmed they cannot meet the ceiling alone. A
  write deploy key "can perform the same actions as … a collaborator on a
  personal repository" *for git operations* (same doc).
- One-key-one-repo also fights the "one identity per installation"
  decision (would need N keys + N ssh config aliases). At most a
  supplement for git while a PAT covers API — but that doubles the
  credential surface for no gain over a single account credential.

## 5. Branch protection on personal accounts (free plan)

- **Branch protection rules and rulesets are available on public repos
  under GitHub Free, but NOT on private repos** (private needs Pro+)
  ([About protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches),
  [About rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)).
  Boxa itself is public, so it's fine; the user's *private* personal
  repos get **no forge-side main protection at all** on the free plan —
  the map's "protection of main is enforced forge-side" premise fails
  there unless the plan is upgraded or the repo is public.
- Admin bypass: by default branch-protection restrictions "do not apply
  to people with admin permissions"; must tick "Do not allow bypassing
  the above settings" to bind admins
  ([About protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)).
  Interplay per option:
  - **User's own fine-grained PAT**: acts as the owner/admin → bypasses
    protection unless no-bypass is enabled; and since the human uses the
    same account, binding admins also binds the human. Protection here is
    honor-system-adjacent.
  - **Machine account collaborator**: non-admin → protection binds it
    unconditionally; the owner (human) keeps their bypass. Cleanest
    separation.
  - **GitHub App**: not covered by admin bypass; can be added as an
    explicit ruleset bypass actor if desired.

## 6. What established agent products do (primary sources only)

- **Copilot coding agent** (GitHub's own): runs in GitHub Actions;
  tokens are deliberately limited so pushes are **only allowed to
  branches beginning `copilot/`** and never to main/master; it opens
  draft PRs; commits are signed and co-authored with the requesting
  developer; each commit links to session logs; internet access is
  firewalled
  ([Risks and mitigations for Copilot coding agent](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/risks-and-mitigations),
  [About Copilot coding agent](https://docs.github.com/en/copilot/concepts/coding-agent/about-copilot-coding-agent)).
  It can't satisfy rules like "specific commit authors"; the documented
  workaround is adding Copilot as a **ruleset bypass actor**
  ([responsible use](https://docs.github.com/en/copilot/responsible-use/copilot-coding-agent)).
  Takeaway mirrored in this design: distinct identity + forge-enforced
  branch confinement + protection as the backstop, not agent trust.

## Recommendation

**Primary: machine user account as collaborator (SSH key) + classic PAT
of that account for `gh`.**
Fits boxa's architecture exactly: real SSH key on the host behind the
dedicated ssh-agent (ADR 0026 pattern), `git@github.com:` remotes
unchanged, one identity across all repos (just invite it), and — the
decisive property — it is a **non-admin principal**, so branch
protection binds it unconditionally while the human keeps admin. ToS
explicitly permits it. Trade-offs: second account to onboard (email
address, key upload, per-repo invites — onboarding wizard material);
`gh` needs the machine account's classic PAT because fine-grained PATs
don't work on collaborator repos, and classic `repo` scope is coarse
(bounded, though, by the collaborator ceiling of invited repos);
"author = human user" must be forced via git config since the pusher is
the machine account; private repos on Free still have no branch
protection at all.

**Fallback (no second account wanted): fine-grained PAT on the user's own
account**, permissions Contents+PRs+Issues:write, Actions:read,
per-repo list, delivered as `GH_TOKEN`; remotes must switch to HTTPS.
Simplest onboarding (one token page, no invites), but the token acts as
the repo admin — protected-main is only safe if "do not allow bypassing"
is enabled (which then also binds the human), and SSH/agent-forwarding
design is unused for GitHub. Weaker fit for the ceiling; acceptable as a
low-friction stranger-onboarding tier.

GitHub App: architecturally cleanest permissions but the 1-hour token
churn plus private-key custody make it disproportionate for a personal
installation — not recommended. Deploy keys: cannot meet the ceiling
(no API surface, one repo per key) — rejected.
