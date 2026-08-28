# PRD — Boxa agent identity

Source: wayfinder map [MAP.md](MAP.md) (all decision tickets closed);
architecture in ADR 0032. This document is the /to-issues input.

## Problem

Agents in boxes either have no forge access (`gh` unauthenticated,
`glab` missing) or, with the SSH gate on, sign with the user's full
authority. Commits carry no trace of agent involvement. Boxa is public;
new users need a painless, best-practice path to a scoped agent
identity.

## Goals

- One per-installation **Agent key** served by a dedicated boxa
  ssh-agent; key material never enters containers.
- Scoped forge access: GitHub machine user (classic PAT `repo`, 1y),
  GitLab service account Developer (`api` PAT, 1y); ceiling enforced
  forge-side.
- Authenticated `gh`/`glab` in boxes, per-project by default, global
  opt-in, surviving restarts and container recreation.
- Commits: author = human, committer = machine identity.
- Onboarding: category-B provisioning step + verified interactive
  checklists; generate / adopt-existing / skip at every decision point.

Non-goals: commit signing; boxa-side push approval; per-project keys;
enforcing any private-repo posture (documented menu instead).

Known limitation (accepted for v1): gate changes take effect at
container creation (`boxa stop && boxa`), not live — tokens travel as
env and the socket mount is decided at creation. Future enhancement:
live off via socket removal in the mounted directory; emergency
revocation is always live forge-side (revoke the PAT / delete the key).

## Functional requirements

### F1 — Agent key + dedicated agent (`lib/ssh.sh` extension)

- `ed25519` keypair generated (only by onboarding or `boxa ssh`
  identity setup) into `~/.config/boxa/` (0600), no passphrase, comment
  `boxa-agent@<hostname>`.
- Dedicated ssh-agent: lazily spawned `ssh-agent -a` at a fixed socket
  path under a boxa-owned directory; env-file + liveness resurrection
  reusing the existing pattern; key loaded on boxa start; no systemd.
- Container mount: the socket's **directory** (inode footgun), socket
  exposed as `SSH_AUTH_SOCK` exactly like the current gate mount.
- The agent's `.pub` may ship into containers; private material never.

### F2 — SSH gate third state

- `ssh.conf` gate values become `off | agent | user` (today's `on`
  parses as `user` for backward compatibility — decide exact migration
  in implementation, byte-preserving writer must survive).
- `boxa ssh` status renders the three states and the identity's
  fingerprint; `boxa ssh on` grows the choice or a new subcommand
  (naming per CONTEXT.md conventions); `boxa ssh add` (key picker)
  remains `user`-mode-only.
- Container-creation wiring picks the socket by state; existing frozen
  container reporting extended to name which agent is forwarded.

### F3 — Forge store + `boxa forge` CLI

- Store `~/.config/boxa/forge/` (0600 files, one per forge: token +
  identity metadata: username, host for GitLab). Values never echoed,
  never in argv (hidden prompt paste, secret-store hygiene).
- `forge.conf` mirrors `ssh.conf`: per-project sections, global opt-in,
  strict parse, fallback off.
- CLI mode `boxa forge`: bare = status for cwd project (gate, which
  forges configured, token age); `on|off [project|path] [--global]`;
  `set github|gitlab` (paste + verification via `gh api user` /
  `glab api user`, rotation = same command); `unset`.
- Warn `boxa stop && boxa` when a running container is affected (same
  UX as the SSH gate).

### F4 — Container delivery

- When the forge gate is on for the project at container creation:
  inject `GH_TOKEN`, `GITLAB_TOKEN`, `GITLAB_HOST` from the store, plus
  `GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` of the machine identity
  (from store metadata).
- Per-project named volumes mounted at `/home/node/.config/gh` and
  `/home/node/.config/glab-cli` (in-container logins persist, project
  scoped). Env wins over config files; document.
- `glab` added to the Dockerfile; gitlab host keys pre-seeded into
  known_hosts alongside github's.
- Reminder surface: non-fatal heads-up at start when a token is expired
  or near expiry (pattern: claude-token heads-up).

### F5 — Onboarding

- New category-B provisioning step `agent-identity`
  (`scripts/ensure-agent-identity.sh`, registered in
  `lib/provisioning.sh`): probe `ok` (key exists or adopted, ≥1 usage
  configured) / `declined` (`agent-identity-seen`) / `missing`; offer =
  one-sentence risk/benefit + default-N prompt; repair re-runs wizard.
- Wizard: three-way key entry (generate / pick existing via key picker /
  skip), then optional per-forge checklists:
  - GitHub: create machine user → add Agent key to it → invite to
    repo(s) → mint classic PAT (`repo`, 1y) → paste → verify
    (`ssh -T git@github.com`, `gh api user`), nudge branch-protection
    ruleset for public repos.
  - GitLab: create instance service account (or plain user fallback) →
    add key → grant Developer on project(s) → mint `api` PAT (1y) →
    paste → verify; nudge protected branches (push=Maintainers) and
    protected tags `v*`.
- Adopt-existing token import from host gh/glab configs: ADR 0031
  consent flow (per-value default-no y/N, rotation prompt, non-TTY
  reports names + `boxa forge set` hint).
- Private-repo posture: documented menu (don't invite / GitHub Pro /
  read-only deploy key), presented as information, never enforced.

### F6 — Docs + glossary

- `docs/forge.md` (feature doc: model, private-repo menu, DIY fallback
  = fine-grained PAT over HTTPS, rotation); `docs/ssh.md` updated for
  the third gate state.
- CONTEXT.md: **Agent key**, **Agent identity**, **Forge store**,
  **Forge gate**, gate states `off/agent/user`; relationships row next
  to Allowlist/SSH gate. UI strings and comments English.

## Acceptance (feature level)

- Fresh machine: `boxa doctor` shows `agent-identity: missing`; running
  the wizard end-to-end yields a box where `git push` (agent key),
  `gh pr create`, `glab mr create` all act as the machine identity,
  commits show "authored by user, committed by agent", and none of the
  user's personal credentials are present in the container.
- Recreating the container and rebooting the host changes nothing.
- Declining everything leaves current behaviour untouched.
- All shell changes shellcheck-clean; tests follow `tests/ssh.sh`
  patterns incl. strict-parse and byte-preserving conf writer coverage;
  interactive flows tested via real pty (no stubbed consent seams).

## Live host verification (post-implementation, user-run)

Wizard on the real host, real machine user + service account creation,
push/PR/MR round-trip on a scratch repo, WSL2 reboot persistence.
