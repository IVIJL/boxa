# Wayfinder map — Boxa agent identity

Label: wayfinder:map
Tracker: local markdown, tickets in `./issues/`, research assets in `./research/`.

## Destination

An ADR + implementation-ready spec (feedable to /to-issues) for the "boxa
agent identity" feature: a per-installation agent identity with its own
host-side SSH key served through a dedicated ssh-agent (key material never
enters containers), scoped forge access (personal GitHub, self-hosted
GitLab CE) with authenticated `gh`/`glab` in boxes, commits authored as the
human user, and a product-grade onboarding flow (provisioning category-B
step) that either adopts existing credentials or walks a stranger through
creating them.

## Notes

Standing decisions from charting (2026-08-22, not tickets):

- One agent identity per installation (per machine), not per project or
  container. Fine-grained rights live on the forge side.
- Key stays on host, delivered by agent forwarding only — never copied or
  mounted into a container (extends ADR 0026 invariants).
- Capability ceiling: clone/fetch/push to unprotected branches, open
  PR/MR, read+write issues and comments, read CI logs. Not: protected
  branch push, repo admin, releases, member management. Protection of
  main is enforced forge-side (branch protection), not by trusting the
  agent.
- Commit author = the human user (their name + email); committer = the
  machine identity when the forge gate is on ("authored by human,
  committed by agent"). No Co-Authored-By trailers.
- Boxa is a public project; onboarding must work for a stranger with no
  prior setup, following the existing provisioning registry pattern
  (ADR 0017, category B, probe/repair) and picker/consent conventions
  (ADR 0006, ADR 0031).
- User facts: GitHub = personal free account, mix of public and private
  repos; GitLab = company self-hosted CE, version 19.3.0 (≥ 18.11, so
  Free-tier service accounts are available).
- Forge credentials are per-Project by default (same row as Allowlist /
  SSH gate), with explicit opt-in to enable globally; logins must survive
  container recreation and host restarts. (User, 2026-08-22.)

Skills to consult per session: grilling + domain-modeling for decision
tickets; research for research tickets. Relevant ADRs: 0026 (SSH gate),
0017 (provisioning), 0031 (consent-first credential takeover), 0025
(hook-mount threat model naming ~/.config/gh as a hazard).

## Decisions so far

<!-- one line per closed ticket: [title](issues/NN-....md): gist -->
- [02 — Research: GitLab CE limited-rights options](issues/02-research-gitlab-ce-access-model.md): machine identity as Developer (per-project) + `api` PAT for glab + own SSH key; instance service account if CE ≥ 18.11, else plain admin-created user; main protected via push=Maintainers (CE role buckets only).
- [01 — Research: GitHub limited-rights options](issues/01-research-github-access-model.md): machine account collaborator (ToS-legal; own SSH key + classic PAT for gh — fine-grained PATs can't act on collaborator repos) as primary; fallback = fine-grained PAT on own account over HTTPS; branch protection on Free = public repos only, admin bypass on by default.
- [03 — Research: dedicated ssh-agent + single-key patterns](issues/03-research-dedicated-agent-key-patterns.md): one key ⇒ one forge identity (GitHub per-account/repo, GitLab instance-wide fingerprint); auth keys unscoped+non-expiring on GitHub; one-key agent makes container-side selection trivial (belt: .pub + IdentitiesOnly); WSL2 agent must be lazily resurrectable at a fixed -a socket (directory-mounted), lib/ssh.sh pattern fits; signing+auth dual-register OK (GitHub 2 uploads, GitLab usage-type both).
- [04 — Decide: GitHub access model](issues/04-decide-github-model.md): machine user collaborator per repo; its SSH key in the boxa agent, its classic PAT (`repo`, 1-year expiry) for gh; public repos rely on branch protection, private repos default "don't invite" pending [10 — Decide: private-repo strategy](issues/10-decide-private-repo-strategy.md); onboarding = one blessed path + documented DIY fallback + adopt-existing.
- [05 — Decide: GitLab CE access model](issues/05-decide-gitlab-model.md): instance service account (CE 19.3.0), Developer per project, `api` PAT 1 year, main push=Maintainers, protected tags `v*`; plain machine user documented as fallback for old CE.
- [06 — Decide: agent key + dedicated ssh-agent design](issues/06-decide-agent-key-design.md): one ed25519 key for all forges, no passphrase, `~/.config/boxa/`, comment `boxa-agent@<hostname>`; lazy `ssh-agent -a` with directory-mounted socket (no systemd); SSH gate states become off | agent (default) | user (escalation).
- [10 — Decide: private-repo strategy](issues/10-decide-private-repo-strategy.md): per-user configurable posture, no forge-side enforcement by boxa; documented menu = don't invite (default) / GitHub Pro / read-only deploy key; ssh-add -c push approval rejected as too coarse.
- [07 — Decide: forge token delivery](issues/07-decide-token-delivery.md): host forge store `~/.config/boxa/forge/` + `boxa forge` CLI + env injection (GH_TOKEN/GITLAB_TOKEN/GITLAB_HOST) per project; in-container auth login supported via per-project volumes at ~/.config/gh|glab (env wins when both); adopt-existing via ADR 0031 consent import; git author = keep wholesale gitconfig copy + GIT_COMMITTER_* = machine identity.
- [08 — Decide: onboarding UX](issues/08-decide-onboarding-ux.md): one category-B step "agent-identity" (key + agent, ssh-gate-seen-style marker, probe ok/declined/missing); forge setup on demand via interactive verified checklist (ssh -T / gh api user probes); three-way entries (generate/adopt/skip, paste/import/skip); commit signing ruled out of scope.
- [09 — Task: write the ADR + spec](issues/09-write-adr-and-spec.md): ADR 0032 (accepted) + PRD.md written and user-approved 2026-08-22. **Map complete** — no open tickets, no fog. Continue with /to-issues on PRD.md.

## Not yet specified

(empty — all fog graduated or resolved; vocabulary lands in ticket 09's
spec: Agent key, forge store, gate states off/agent/user.)

## Out of scope

- Commit signing: ruled out in ticket 08 — the forge "Verified" badge
  needs the signing key to belong to the commit author's account, which
  the author=human/key=machine split makes unattainable; per-commit
  attribution is covered by committer = machine identity instead.
  Possible tiny future feature.
- Boxa-side push approval (`ssh-add -c`): rejected in ticket 10 as too
  coarse (fires on every signature, cannot distinguish target branch);
  noted as possible future opt-in hardening.

- Implementation of the feature (destination is the spec; build happens
  via /to-issues afterwards).
- Per-project or per-container identities/keys; rights granularity beyond
  what the forge offers for one identity.
- Per-key filtering of the *user's* forwarded agent (ADR 0026 deferred
  item) — the agent-key design makes it moot for this effort.
