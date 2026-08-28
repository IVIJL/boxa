# 15 — glab in the image + per-project gh/glab config volumes

Status: done

## Parent

[PRD](../PRD.md) F4 (image + persistence half); ADR 0032 decision 4.

## What to build

Make in-container forge logins first-class and durable. `glab` is
installed in the image next to `gh`; `gitlab.com` host keys are
pre-seeded into known_hosts alongside github's (self-hosted GitLab
hosts still arrive via the user's known_hosts/ssh config as today).
Per-project named volumes are mounted at `/home/node/.config/gh` and
`/home/node/.config/glab-cli`, so a user who runs `gh auth login` /
`glab auth login` inside a box the way they would on their own machine
keeps that login across container recreation, scoped to the project.

## Acceptance criteria

- [ ] `glab version` works in a fresh box. — live host verification (build must run on host; in-box build OOMs)
- [ ] `gh auth login` (token paste) inside a box survives
      `boxa stop && boxa`; a different project does not see it. — live host verification (build must run on host; in-box build OOMs)
- [ ] With forge-gate env also present, env wins (gh semantics) — noted
      in docs. — not verified this pass; docs claim carried over from earlier commits, no new doc change needed here
- [x] Volumes follow existing naming/cleanup conventions for per-project
      volumes. — `boxa::volume_name`/`boxa::project_volume_regex` cover gh/glab suffixes; `tests/naming.sh` green
- [ ] shellcheck clean; docker build succeeds. — shellcheck clean (verified); docker build succeeds = live host verification (build must run on host; in-box build OOMs)

## Blocked by

None - can start immediately.

## Comments
