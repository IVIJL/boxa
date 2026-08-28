# 11 — keep-awake enable: build via Docker golang image, local toolchain as fallback

Status: done

## Parent

Follow-up to issue 10 (`boxa keep-awake` elective step). Distribution
decision (Miloš, 2026-07-31): keep-awake will be offered to users as an
easy post-install command, so `enable` must not require a local Go
toolchain — Docker is already a hard prerequisite of boxa, so build the
binary in a throwaway golang container by default.

## What to build

Change `keep_awake::build_binary` in `scripts/ensure-keep-awake.sh` so
the default build path is a throwaway container run by the host Docker
daemon, with the current local-`go` build kept as fallback:

- Default: `docker run --rm` on a **pinned** golang image (match the
  `go.mod` toolchain line, e.g. `golang:1.22`), bind-mounting
  `$BOXA_DIR/keep-awake` read-only as the source and an output dir for
  the artifact. `CGO_ENABLED=0`; for the wsl2 platform add
  `GOOS=windows`. keep-awake is stdlib-only, so the build needs no
  network beyond the image pull.
- Run the container with `--user "$(id -u):$(id -g)"` (plus writable
  `GOCACHE`/`GOMODCACHE`, e.g. under `/tmp` in the container) so the
  produced binary is owned by the invoking user, not root.
- Fallback: when `docker` is missing or the containerised build fails,
  fall back to the existing local `go build` path (message should say
  what happened). `keep_awake::check_enable_prereqs` /
  `keep_awake::go_remedy` update accordingly: the remedy is now
  "have Docker running" first, install-Go instructions only as the
  fallback hint. Prereq passes when docker OR go is available (or the
  binary is already installed).
- `boxa keep-awake status` / help texts mention the Docker build path
  where they currently imply a Go toolchain requirement.

Constraints: shell style of the surrounding script, shellcheck-clean
including info-level findings; do not change the daemon source or the
autostart wiring; do not touch `dotfiles/`.

## Acceptance criteria

- [x] With Docker available and no `go` on PATH, `enable` builds the
      binary via the pinned golang container (native platform build and
      wsl2 `GOOS=windows` cross-build) and the artifact is owned by the
      invoking user. (Covered by mocked unit tests; not verified against
      a live Docker daemon.)
- [x] With Docker unavailable, `enable` falls back to local `go build`
      when a toolchain exists, and fails with the updated remedy text
      when neither is available.
- [x] `tests/keep-awake.sh` covers the build-path selection (docker
      default, fallback ordering, remedy text) with mocks; suite green.
- [x] `shellcheck` clean on changed scripts.

## Blocked by

None — can start immediately.

## Comments

- 2026-07-31: Implemented via Codex delegation. `keep_awake::build_binary`
  now defaults to `docker run --rm` on pinned `golang:1.22`, UID/GID +
  writable Go caches, WSL `GOOS=windows` cross-build, falls back to local
  `go build`; prereq/remedy text and help/docs updated accordingly.
  `tests/keep-awake.sh` (68 cases) and `tests/connect-host.sh` (regression)
  both green; shellcheck clean. Commit: e0c9ffe.
