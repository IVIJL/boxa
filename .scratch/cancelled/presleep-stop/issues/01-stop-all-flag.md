# 01 — Non-interactive `boxa stop --all` with reason-driven closeout notification

Status: done

## Parent

ADR 0023 (host connections / keep-awake trust model) for background;
the pre-sleep stop feature itself has no ADR — grill decisions live in
the issues of this feature.

## What to build

A non-interactive variant of `boxa stop` for machine callers (the
keep-awake daemon's power-watch hook) and scripting:

- `boxa stop --all` stops **every** running boxa container (the same
  set the interactive "* Stop all" picker entry covers) **in
  parallel** (single `docker stop` invocation over all names, not a
  serial loop — the pre-sleep budget is ~1 minute), then stops idle
  Traefik and DNS as the existing stop path does. No picker, no
  prompts, exit non-zero only on real failures.
- No `--clean` semantics: volumes, route YAMLs and HTTPS artifacts are
  left in place so a later `boxa up` restores everything.
- `--reason <token>` (initially `presleep`) tags the run. When a
  reason is present, after the stop completes the command raises a
  **Closeout notification** through the existing host-side deliver
  script (same infrastructure as Allow-for / Agent-browser closeouts):
  "Boxes X, Y stopped before sleep/shutdown" — delivered even if the
  system then does not sleep (that is intentional: the user must learn
  the boxes were stopped).
- Notification logic lives entirely on the boxa/WSL side; the Go
  daemon never raises toasts itself.

## Acceptance criteria

- [x] `boxa stop --all` stops all running boxa containers without any
      interactive prompt, in parallel, then idle Traefik/DNS.
- [x] Volumes / routes / HTTPS artifacts survive (`boxa up` afterwards
      restores the project without re-provisioning).
- [x] `boxa stop --all --reason presleep` raises a Closeout
      notification listing the stopped boxes via the existing deliver
      script; without `--reason` no notification is raised.
- [x] `--all` combined with a project name is rejected with a clear
      error.
- [x] Help text (`boxa stop` section) documents `--all` and
      `--reason`.
- [x] Bats/tests cover the flag parsing, parallel stop and
      notification trigger; shellcheck clean. (repo uses a plain-bash
      test harness, not bats; `tests/stop-all.sh` follows that
      convention.)

## Blocked by

None — can start immediately.

## Comments
