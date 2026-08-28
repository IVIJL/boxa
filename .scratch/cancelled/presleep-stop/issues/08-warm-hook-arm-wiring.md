# 08 — Warm hook arming: HTTP endpoint + boxa up/stop wiring

Status: done

## Parent

None — second slice of the warm-hook design (see issue 07 for the
root-cause context). Rule agreed with the user: **the warm child lives
exactly while boxa containers run** — `boxa up` (first box) arms it,
`boxa stop` (last box) disarms it. No polling, no idle timers.

## What to build

**Daemon HTTP API** (`keep-awake/internal/httpapi/`):

- `POST /v1/warm-hook` with a JSON body like `{"armed": true|false}`
  calling the issue-07 manager's `Arm()`/`Disarm()`. Follow the existing
  handler/auth conventions of `/v1/busy`/`/v1/idle`.
- Surface warm-hook state (armed, child alive) in the existing
  `powerWatch` section of `/v1/status`, and show it in
  `boxa keep-awake status` output.

**CLI wiring** (`docker-run.sh`):

- After a successful container start (all paths that bring a boxa box up),
  best-effort POST `{"armed":true}` to the daemon — reuse the same
  reachability/curl pattern the keep-awake client signal already uses
  (`lib/keep-awake-probe.sh` knows how to find the daemon), `|| true`
  throughout: a missing/disabled daemon must never break `boxa up`.
- After `boxa stop` (interactive, `--all`, and single-box), when no
  `boxa-*` container remains running, best-effort POST `{"armed":false}`.
  When some still run, do nothing.
- The pre-shutdown stop executed *through the warm hook* must not
  re-trigger arming or disarming loops (`--reason presleep` path runs
  `boxa stop --all`; its final "none left running" disarm is correct and
  harmless — the child is exiting anyway).

## Acceptance criteria

- [x] Go proof green (same docker golang:1.22 command as issue 07);
      httpapi unit tests cover arm, disarm, and status exposure.
- [x] `tests/stop-all.sh` extended: stubbed daemon endpoint asserts
      `boxa up`-path arms, last stop disarms, stop with boxes remaining
      does not disarm, and daemon-unreachable is silent and non-fatal.
- [x] `tests/keep-awake.sh` + `tests/help.sh` still pass.
- [x] shellcheck clean (including info-level) on changed shell files.

## Blocked by

`.scratch/presleep-stop/issues/07-warm-hook-child.md` — needs the manager
and its `Arm()`/`Disarm()` API.

## Comments

Done in commit 834cac5. No deviations from spec. Implemented via Codex
(threadId 01a003b2-60db-76b2-a944-68437c0ce9ac), proof independently
re-verified by orchestrator before commit.
