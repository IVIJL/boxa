# 04 — Doc and comment accuracy sweep for the shared config layout

Status: done

## Parent

ADR 0036 (proposed), section 7 of `../NOTES.md`.

## What to build

Bring prose in line with the post-directory-mount reality:

- ADR 0015: amend the "truncated in place (Docker snapshots bind mounts by
  inode)" note — obsolete under the directory mount; point at ADR 0036.
- ADR 0011: its description of `/etc/boxa-shared/` as "bind-mounted shared
  state" is accurate only for the `config/` subtree; fix the wording.
- The two comments claiming `.allow-for.state` is bind-mounted (in the
  allow-for window start script and the restart closeout script) — the file
  is container-local, written inside the Container, and never mounted.
- Flip ADR 0036 from `proposed` to `accepted`.

## Acceptance criteria

- [x] ADR 0015 and ADR 0011 no longer contain statements contradicted by the
      shipped layout, and reference ADR 0036 where relevant. Done in issue 01
      (commit 91027a2): ADR 0015's "truncated in place" note now points to
      ADR 0036 (`git grep -ni truncat docs/adr/0015*` shows only the
      amendment sentence); ADR 0011 now scopes "bind-mounted shared state" to
      `/etc/boxa-shared/config/` (`git grep -ni bind-mounted docs/adr/0011*`).
- [x] No comment in the repo claims `.allow-for.state` is bind-mounted or
      lives on a shared volume. Done in issue 01 for the two named scripts
      (`scripts/start-allow-for-window.sh:44`,
      `scripts/closeout-allow-for-on-restart.sh:12` now say "Container
      rootfs"); repo-wide `grep -rn "allow-for.state"` sweep in issue 04
      found no other bind-mount claims (remaining hits are plain path
      references in `docker-run.sh`, `lib/allow-for.sh`, `CONTEXT.md`,
      `docs/adr/0009`).
- [x] ADR 0036 status is `accepted` (flipped in issue 04, file added to git).

## Blocked by

`01-directory-mount-manifest-transition.md` (docs must describe what actually
shipped).

## Comments
