# ADR 0032 — Per-installation agent identity (agent key, forge access, onboarding)

- **Status:** accepted (setup/credential flow superseded by ADR 0033
  forge identity catalog; decision 2 three-state gate and the posture
  checklists superseded by ADR 0034)
- **Date:** 2026-08-22
- **Extends:** ADR 0026 (SSH gate), ADR 0017 (provisioning registry),
  ADR 0031 (consent-first credential takeover), ADR 0006 (pickers)

## Context

Historically the user's own SSH key sat inside the container; the SSH
gate (ADR 0026) replaced that with opt-in forwarding of the user's host
agent — but that is all-or-nothing: a forwarded socket signs with the
user's full authority, and per-key filtering was deferred. Meanwhile
agents increasingly need forge access beyond git: `gh` ships in the
image but is unauthenticated (`~/.config/gh` is even named a threat in
ADR 0025), `glab` is absent, and commits made in boxes carry the user's
full identity with nothing marking agent involvement.

Boxa is a public project. Whatever shape this takes must onboard a
stranger: some users bring existing keys and logins, some need to be
walked through creating scoped credentials, and postures differ (some
pay for GitHub Pro, some don't care).

Research (see `.scratch/agent-identity/research/`) pinned the forge
facts this design leans on: GitHub auth SSH keys are unscoped and
non-expiring and bind to exactly one account; fine-grained PATs cannot
act on repos where the account is a mere collaborator; personal-repo
collaborators are always read+write; branch protection on GitHub Free
exists only on public repos. GitLab CE ≥ 18.11 has Free-tier instance
service accounts; CE protected branches know only role buckets. A
systemd service does not keep a WSL2 VM alive.

## Decision

1. **One agent identity per installation.** Boxa owns a generated
   ed25519 keypair — the **Agent key** — stored under `~/.config/boxa/`
   (0600), passphrase-less (an unattended agent gains nothing from a
   passphrase; the protections are that the key never leaves the host
   and holds only scoped forge rights), comment `boxa-agent@<hostname>`.
   The key is held by a dedicated, boxa-owned ssh-agent: lazily spawned
   `ssh-agent -a <fixed socket path>` resurrected via the existing
   `lib/ssh.sh` env-file + liveness pattern (no systemd — WSL2
   idle-shutdown), with the socket's **directory** bind-mounted into
   containers (socket re-creation changes the inode). Both ADR 0026
   invariants extend to this agent: boxa never reads private key
   material beyond generating it, and only explicit user action loads
   other keys anywhere.

2. **The SSH gate grows a third state.** `off` | `agent` (forward the
   boxa agent's socket; the recommended default onboarding suggests) |
   `user` (today's full personal-agent forwarding, kept as a conscious
   escalation). Per-project as before, mutually exclusive — one
   `SSH_AUTH_SOCK` inside the container.

3. **Forge access runs through scoped machine identities, enforced
   forge-side.** The capability ceiling (push to unprotected branches,
   open PR/MR, read+write issues, read CI; nothing admin-ish) is not
   enforced by trusting the agent but by what the identity can do:
   - **GitHub (personal accounts):** a **machine user** account
     (ToS-legal second free account) invited per repo as collaborator;
     its SSH key is the Agent key; `gh` authenticates with the machine
     user's **classic PAT**, scope `repo`, 1-year expiry (fine-grained
     PATs cannot act on collaborator repos). Public repos get a branch
     protection ruleset; private repos on Free have none, so the
     private-repo posture is a **per-user documented choice** — don't
     invite (default) / GitHub Pro / read-only deploy key — never
     boxa-enforced.
   - **GitLab (self-managed):** an **instance service account**
     (CE ≥ 18.11; plain admin-created user documented as fallback) with
     **Developer** role granted per project; `glab` uses its PAT, scope
     `api`, 1-year expiry. `main` protected with push = Maintainers;
     protected tags `v*` close the Developer tag-push→release gap.

4. **Forge tokens live in a host-side forge store, delivered as env.**
   `~/.config/boxa/forge/` (0600; values never echoed, never in argv),
   managed by a new `boxa forge` CLI mode (status, `on|off [project]
   [--global]`, `set github|gitlab` incl. rotation), gated per project
   by `~/.config/boxa/forge.conf` mirroring `ssh.conf` (per-project
   sections, explicit global opt-in; default per-project). Containers
   get `GH_TOKEN` / `GITLAB_TOKEN` / `GITLAB_HOST` injected at creation
   — no login inside, and persistence across restarts is free because
   the host store is re-read at every container creation. Host `gh`/
   `glab` logins are never touched: the machine identity's PAT is a
   string pasted once into `boxa forge set`. Adopt-existing imports a
   token from host gh/glab configs only via the ADR 0031 consent flow.
   In-container `gh auth login`/`glab auth login` **is supported** for
   users who work that way: per-project named volumes back
   `~/.config/gh` and `~/.config/glab-cli`, so an in-box login survives
   recreation and stays project-scoped; injected env wins over config
   files (gh semantics), documented.

5. **Authorship: author = human, committer = machine identity.** The
   wholesale `~/.gitconfig` copy stays (commits carry the user's name
   and email; responsibility is theirs). When the forge gate is on, the
   container additionally gets `GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL`
   of the machine identity, so forges render "authored by human,
   committed by agent" — a permanent per-commit audit trail. Commit
   signing is **out of scope**: the "Verified" badge requires the
   signing key to belong to the author's account, unattainable under
   this split.

6. **Onboarding is one category-B provisioning step plus verified
   checklists.** A single `agent-identity` step (ADR 0017: probe
   `ok`/`declined`/`missing` with an `agent-identity-seen` marker,
   repair re-runs the wizard) generates the Agent key and sets up the
   agent. Forge-side manual actions (create machine user / service
   account, invite, mint PAT) are guided by an interactive CLI checklist
   with exact URLs that **verifies** each step (`ssh -T` through the
   agent; `gh api user` / `glab api user` showing who authenticated).
   Every decision point is three-way: generate new (recommended) /
   adopt existing (key picker; consent-first token import) / skip.

## Considered options

- **Fine-grained PAT on the user's own account** — rejected as primary:
  acts with the user's (admin) authority, requires HTTPS remotes, and
  cannot be combined with a machine user (collaborator-repo gap). Kept
  as the documented DIY fallback.
- **GitHub App** — 1-hour installation tokens would need a host-side
  minting daemon; overkill for a personal setup.
- **Deploy keys / deploy tokens as primary** — git-transport only, no
  PR/issue/API surface, one key per repo. Read-only deploy keys remain
  one item on the private-repo menu.
- **GitLab project/group access tokens** — per-scope bot users, no SSH,
  forced ≤365-day expiry; a service account is strictly cleaner on CE.
- **Per-forge agent keys** — more ceremony, no isolation gain; one key
  per installation, revocable by deleting it on both forges.
- **Key file mounted into the container** — exfiltratable by the very
  agent it serves; the agent-socket design keeps material on host.
- **systemd-managed agent** — does not keep the WSL2 VM alive; lazy
  resurrection matches how boxa already treats agents.
- **Boxa-side push approval (`ssh-add -c`)** — fires on every signature
  (fetch included) and cannot distinguish the target branch; too coarse
  to be the private-repo safety story. Noted as possible future opt-in
  hardening.
- **Commit signing with the Agent key** — no attainable badge (see
  Decision 5); committer attribution delivers the audit value for free.

## Consequences

- The deferred per-key filtering of ADR 0026 becomes moot for the common
  case: the recommended gate state forwards an agent holding exactly one
  scoped key, while `user` mode survives as the explicit escalation.
- Compromise of a box yields at most: signatures with a key limited to
  invited repos/projects (revocable by deleting two forge entries), and
  a PAT scoped to the same repos with a 1-year horizon.
- The user's own credentials (`~/.ssh`, `~/.config/gh`, host logins)
  never enter the fleet by default, closing the threat ADR 0025 names.
- New moving parts to maintain: a second long-lived agent, a forge
  store + conf, per-project gh/glab volumes, and forge-side setup docs
  that must track GitHub/GitLab UI changes.
- Users who skip everything lose nothing they have today; the feature is
  strictly opt-in via provisioning category B.

## Forge identity postures

Guided setup now offers three postures per forge. The machine/service account
remains the recommended default.

- **My own account — quick.** The agent pushes as you, with everything you can
  access; forge-side repository restrictions cannot narrow that identity.
- **Machine/service account — safest.** Invite or grant it only where needed;
  the trade-off is another account to manage.
- **GitHub fine-grained PAT only — narrow, HTTPS-only.** Choose repositories
  and token permissions, but SSH remotes cannot authenticate as the agent.
- **GitLab personal PAT only — account-wide, HTTPS-only.** A personal PAT has
  full account reach for its granted scopes. Use a project or group access
  token for genuinely project-scoped access. SSH remotes cannot authenticate
  as the agent.
