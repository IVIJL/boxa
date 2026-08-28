# 07 — Decide: forge token delivery into containers (gh/glab auth)

Status: closed
Label: wayfinder:grilling
Assignee: main-session

## Parent

[MAP](../MAP.md) — wayfinder map "Boxa agent identity".

## Question

Once the GitHub ([04](04-decide-github-model.md)) and GitLab
([05](05-decide-gitlab-model.md)) models are chosen: how do the resulting
tokens reach `gh`/`glab` inside containers safely? Candidates: reuse/extend
the MCP secret store machinery (ADRs 0014/0021/0030), env injection at
container creation, a mounted config, or a broker like the SSH agent
socket. Constraints: tokens must not be silently readable by arbitrary
host processes, consent-first per ADR 0031, and exfiltration by a rogue
in-container agent is assumed possible — so scope of the token is the real
defence. Also decides how git author name/email get set (narrowing the
current wholesale `~/.gitconfig` copy or keeping it).

User requirements added 2026-08-22:

- **Persistence**: a `gh`/`glab` login made for a project must survive
  container recreation and host restarts (volume-backed or re-injected at
  container creation) — no re-login after every reboot.
- **Per-project by default**: forge credentials are granted per Project
  (same row as Allowlist / SSH gate / Host connections), with an explicit
  opt-in to enable globally for all boxes. Default is per-project.

## Acceptance criteria

- [ ] Resolution comment records delivery mechanism + git author plumbing.
- [ ] Map updated; git-author fog patch resolved.

## Blocked by

[04 — Decide: GitHub access model](04-decide-github-model.md),
[05 — Decide: GitLab CE access model](05-decide-gitlab-model.md)

## Comments

**2026-08-22 — resolution (user + main session)**

- **Host-side forge store**: `~/.config/boxa/forge/` (0600, values never
  echoed, never in argv — secret-store hygiene). Host `gh`/`glab` logins
  are untouched; the machine-user/service-account PAT is just a string
  the user generates in the browser and pastes into `boxa forge set
  github|gitlab`. No host CLI login as the machine identity ever happens.
- **Delivery**: env injection at container creation (`GH_TOKEN`,
  `GITLAB_TOKEN`, `GITLAB_HOST`) — gh/glab honor these natively, no login
  inside, survives restarts because the host store is the source of truth
  re-read at every container creation.
- **Per-project gate**: `~/.config/boxa/forge.conf` mirroring `ssh.conf`
  (project sections, global opt-in); CLI mode **`boxa forge`** (status /
  `on|off [project] [--global]` / `set github|gitlab` incl. rotation).
- **In-container `gh auth login` / `glab auth login` IS supported**
  (user decision: people will do it the way they would on their own
  machine). Mechanics: per-project named volumes mounted at
  `~/.config/gh` and `~/.config/glab` in the container, so an in-box
  login persists across recreation and stays project-scoped.
  Precedence: boxa injects env only when the forge store has a token for
  the project; env wins over config files (gh semantics) — documented.
  Docs warn that logging in with a full personal account hands the agent
  full rights; the blessed path remains the scoped machine-identity
  token.
- **Adopt-existing**: consent-first import of a token from host
  `~/.config/gh` / glab config per ADR 0031 (per-value default-no y/N,
  never silent, never echoed).
- **Git author**: keep today's wholesale `~/.gitconfig` copy — commits
  carry the human's name/email, which is exactly the decided authorship
  model. Fog patch resolved, no change.

**2026-08-22 — amendment (from ticket 08 session)**: additionally inject
`GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` = the machine identity when
the forge gate is on, so author = human, committer = agent ("authored
by human, committed by agent" on forges). Author plumbing unchanged.
