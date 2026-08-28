# 07 — Warm hook: pre-spawned WSL child executes the pre-shutdown stop

Status: done

## Parent

None — follow-up to issues 03/05 (power-watch shutdown-only trim, commit
c3527e4). Live test on 2026-08-14 proved the current design dead: when
`WM_QUERYENDSESSION` arrives, spawning `wsl.exe … boxa stop --all` fails
instantly with `0xC0000142` (STATUS_DLL_INIT_FAILED) — Windows refuses to
create new processes in a session that is shutting down. The stop must be
executed by a process that already exists before the shutdown starts.

## What to build

A "warm hook": a long-lived `wsl.exe` child pre-spawned by the keep-awake
daemon, sitting inside WSL blocked on stdin. At shutdown the daemon only
writes a line into the already-open pipe — no process creation.

**WSL-side wait script** (`scripts/keep-awake-stop-wait.sh`, dispatched as a
hidden `boxa __keep-awake-stop-wait` subcommand in `docker-run.sh`, mirroring
how other internal helpers are dispatched):

- On start, check once whether any `boxa-*` container is running
  (`docker ps`). If none, print `no-boxes` on stdout and exit 0 — this keeps
  a stale spawn from pinning the WSL VM when there is nothing to stop.
- Otherwise print `ready` and block on `read` from stdin.
- On a `stop` line: run `boxa stop --all --reason presleep` (output to
  stderr so it lands in the keep-awake log), then print `done` and exit 0.
- On stdin EOF (daemon gone / disarm): exit 0 quietly.

**Daemon side** (`keep-awake/internal/powerwatch/`):

- A warm-hook manager with `Arm()` / `Disarm()`. Armed → keep a child
  running: spawn `wsl.exe -d $BOXA_WSL_DISTRO -- boxa __keep-awake-stop-wait`
  (same invocation convention and `BOXA_WSL_DISTRO` requirement as the
  existing `DefaultCommand` in `powerwatch_windows.go`), hold its stdin
  pipe open, capture stdout/stderr into the daemon log.
- Child exits with `no-boxes` → self-disarm (do not respawn). Child dies
  any other way while armed → respawn with backoff (e.g. 1 s doubling to
  30 s cap). Disarm → close stdin and reap the child.
- Non-Windows builds: the manager compiles but arming is a no-op (shutdown
  path on Linux keeps the logind inhibitor from issue 03 unchanged).
- Shutdown path (`session.go` `handleShutdown`): when a warm child is
  alive, write `stop\n` and wait for `done`/child exit within the existing
  45 s budget instead of running `commandRunner`. When no child is alive,
  log that the warm hook was down and fall back to the current direct
  `wsl.exe` attempt (best-effort — it will almost certainly fail during a
  real shutdown, but it is free and correct in synthetic tests).

Arming is wired to the HTTP API in issue 08; this slice must expose the
manager so that issue can call it, and may add a temporary manual arming
hook only if needed for its own tests.

## Acceptance criteria

- [x] `go vet` + `go test ./...` green (run via
      `docker run --rm -e GOPROXY=direct -v "$PWD/keep-awake:/src" -w /src
      golang:1.22 sh -c 'gofmt -l . && go vet ./... && go test ./...'` —
      proxy.golang.org is not allowlisted).
- [x] Unit tests cover: armed spawn + respawn-with-backoff, `no-boxes`
      self-disarm, disarm closes the pipe, shutdown writes `stop` and
      waits for `done` within budget, fallback path logs when no child.
      Use a stub executable so tests run on Linux.
- [x] `tests/stop-all.sh`, `tests/keep-awake.sh`, `tests/help.sh` still
      pass; the hidden subcommand does not appear in `boxa help`.
- [x] shellcheck clean (including info-level) on changed shell files.

## Blocked by

None — can start immediately.

## Comments
