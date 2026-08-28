# 05 — Windows power events: shutdown pre-stop and slept-with-boxes resume notification

Status: done

## Parent

None — Windows arm of the power-watch component (issue 03). Shares one
hidden-window message pump; that is why shutdown and manual-sleep
handling are a single slice.

## What to build

A hidden window + message loop on a dedicated OS thread in the Windows
power-watch handling two event families:

- **Shutdown/restart** (`WM_QUERYENDSESSION`/`WM_ENDSESSION`): call
  `ShutdownBlockReasonCreate` ("Stopping boxa containers…"), run the
  stop hook (`wsl.exe -d <distro> boxa stop --all --reason presleep`),
  then clear the block reason and let the session end. Windows grants
  seconds, not minutes — the hook must already be running in parallel
  and the handler must never hang past its bounded timeout.
- **Manual sleep** (`WM_POWERBROADCAST` / `PBT_APMSUSPEND`): the ~2 s
  window is too short to stop anything and cannot be extended, so do
  **not** race it. Persist a small state file ("suspended at T with
  boxes running / leases held") and return immediately. On
  `PBT_APMRESUMESUSPEND`/`PBT_APMRESUMEAUTOMATIC`, if that state
  exists, invoke a lightweight WSL-side hook that raises a Closeout
  notification: "System slept while boxes X, Y were running — check
  them", then clear the state. No automatic restart or heal of
  containers (interactive processes cannot be replayed; a future
  resume-heal of infra is a separate feature).
- Idle-prediction stops (issue 04) that already emptied the boxes must
  not produce a redundant "slept with boxes" notification — the
  suspend-time state records whether any boxa containers were actually
  running.

## Acceptance criteria

- [x] Start→Shut down with running boxes: boxes are stopped before the
      session ends; the block reason is visible if the stop takes
      more than an instant; a wedged hook cannot block shutdown past
      its timeout. (covered by fake-event-source unit tests only;
      deferred: live Windows verification)
- [x] Manual sleep (lid/menu) with running boxes: after resume, a
      notification names the boxes that were running; no notification
      when nothing was running. (state-machine + WSL bridge covered by
      unit/shell tests; deferred: live Windows verification)
- [x] Idle-predicted stop followed by sleep produces exactly one
      notification (the pre-stop one), not two. (covered by fake-event
      unit test asserting suspend-state records actual running boxes;
      deferred: live Windows verification)
- [x] The message pump runs on its own locked OS thread and shuts down
      cleanly with the daemon (no orphaned window class). (Win32
      wiring only compiles/cross-builds under GOOS=windows, no
      live-thread runtime check possible here; deferred: live Windows
      verification)
- [x] Unit tests with a fake event source cover the state machine;
      live shutdown/sleep verification is documented as a manual test
      checklist in docs/keep-awake.md.

## Blocked by

.scratch/presleep-stop/issues/03-power-watch-linux.md — needs the
power-watch component and hook runner.

## Comments
