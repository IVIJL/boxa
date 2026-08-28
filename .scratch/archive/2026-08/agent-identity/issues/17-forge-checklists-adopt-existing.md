# 17 — Forge checklists in the wizard + adopt-existing token import

Status: done

## Parent

[PRD](../PRD.md) F5 (forge half); ADR 0032 decisions 3, 4, 6.

## What to build

The guided forge setup reachable from the `agent-identity` wizard and
from `boxa forge` directly. Interactive, **verified** checklists for
manual browser steps:

- GitHub: create machine user → add the Agent key to it → invite it to
  chosen repo(s) → mint classic PAT (`repo`, 1-year) → paste → verify
  (`ssh -T git@github.com` through the dedicated agent, `gh api user`
  showing the login); nudge a branch-protection ruleset for public
  repos and present the private-repo posture menu (don't invite —
  default / GitHub Pro / read-only deploy key) as information, never
  enforced.
- GitLab: create instance service account (plain admin-created user as
  documented fallback for CE < 18.11) → add key → grant Developer on
  project(s) → mint `api` PAT (1-year) → paste → verify; nudge
  protected branches (push = Maintainers) and protected tags `v*`.

Each checklist step prints the exact URL, waits, verifies, and lets the
user skip. Adopt-existing: consent-first import of a token found in
host `~/.config/gh` / glab config per ADR 0031 (per-value default-no
y/N, rotation prompt when a stored value differs, never echoed,
non-TTY reports names + `boxa forge set` hint).

## Acceptance criteria

- [x] Both checklists run end-to-end with verification probes and
      per-step skip; failure of a probe loops with guidance, never
      traps the user. (`_boxa::forge_checklist_github/gitlab`,
      `_boxa::forge_verify_ssh_loop`, `_boxa::forge_verify_token_loop`
      in `lib/forge.sh`; covered by `tests/test_forge_checklist_pty.py`.)
- [x] Token paste lands in the forge store; consent import matches
      ADR 0031 semantics exactly (shared behavior, not a re-imagining).
      (`_boxa::forge_adopt_existing`, default-no + rotation prompt,
      non-TTY reports names + `boxa forge set` hint; covered by pty
      tests.)
- [x] Posture menu is informational only; choosing an option prints
      guidance, changes no forge state. (`_boxa::forge_github_posture`;
      covered by
      `test_private_repo_posture_is_informational_only`.)
- [x] Interactive flows tested via real pty
      (`tests/test_forge_checklist_pty.py`, extended
      `tests/test_agent_identity_pty.py`).
- [x] shellcheck clean (including info-level SC####) on all touched
      `.sh` files.

Not live-verified (needs a real box + real GitHub/GitLab accounts):
actual browser walkthrough of the checklist URLs, real `gh`/`glab`
CLIs on a host machine for the adopt-existing YAML-fallback path, and
real `ssh -T` against github.com/a GitLab instance through the
dedicated Agent socket. Tests exercise the logic with faked `gh`/
`glab`/`ssh` stand-ins per the repo's existing pty-test conventions.

## Blocked by

- [13 — Forge store, forge.conf, `boxa forge` CLI](13-forge-store-and-cli.md)
- [16 — Onboarding: `agent-identity` provisioning step](16-onboarding-step-agent-identity.md)

## Comments
