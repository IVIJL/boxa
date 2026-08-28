# 14 — Container delivery: forge env + committer identity

Status: done

## Parent

[PRD](../PRD.md) F4; ADR 0032 decisions 4–5.

## What to build

When the forge gate is on for a project at container creation, inject
`GH_TOKEN`, `GITLAB_TOKEN`, `GITLAB_HOST` from the forge store, plus
`GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` set to the machine identity
(from store metadata), so commits made in the box render "authored by
the human, committed by the agent" on forges while the author plumbing
(the `~/.gitconfig` copy) stays untouched. A non-fatal heads-up at boxa
start when a stored token is expired or near expiry (pattern: the
claude-token heads-up). Documented precedence: injected env wins over
any in-container gh/glab config files.

## Acceptance criteria

- [x] With gate on and tokens stored: DOCKER_ARGS wiring injects
      `GH_TOKEN`/`GITLAB_TOKEN`/`GITLAB_HOST`; a real-git test asserts a
      commit shows the human as author and the machine identity as
      committer. NOT live-verified in an actual booted box (`gh api
      user`/`glab api user` inside a fresh container) — deferred to
      live host verification.
- [x] With gate off: none of the five variables are set in the box
      (tested).
- [x] Container recreation and host restart change nothing (env
      re-derived from the host store each creation; tested).
- [x] Expiry heads-up fires only in the warning window, never blocks
      (tested; 365-day lifetime + 30-day warning window, non-fatal).
- [x] Known limitation documented: changes apply at container creation
      (`boxa stop && boxa`), not live.
- [x] shellcheck clean; tests for the wiring decision matrix (91 forge
      + 118 ssh regression, all pass).

## Blocked by

- [13 — Forge store, forge.conf, `boxa forge` CLI](13-forge-store-and-cli.md)

## Comments
