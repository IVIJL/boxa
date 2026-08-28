# 01 — macOS power-watch: IOKit sleep/shutdown ack with pre-stop

Status: ready-for-human

## Parent

.scratch/presleep-stop/issues/03-power-watch-linux.md — macOS arm of
the same power-watch component (stubbed as no-op there).

## What to build

Implement the macOS power-watch using IOKit power notifications:
`IORegisterForSystemPower` + `kIOMessageSystemWillSleep` (ack window up
to 30 s) — run the stop hook (`boxa stop --all --reason presleep`),
then `IOAllowPowerChange`. Handle `kIOMessageSystemWillPowerOff` for
shutdown (or a logout hook if IOKit coverage proves insufficient) and
`kIOMessageSystemHasPoweredOn` for parity with the resume path. No
idle prediction — the 30 s ack window covers idle and manual sleep
alike, same reasoning as Linux. Closeout notification comes from the
boxa side as everywhere else (note: the deliver script has no click
action on macOS).

## Acceptance criteria

- [ ] Closing the lid / idle sleep with running boxes stops them
      within the ack window and never exceeds it (ack must always be
      sent, even on hook failure/timeout).
- [ ] Shutdown path stops boxes before the daemon dies.
- [ ] Unit tests with a fake power source; live lid-close and shutdown
      verification on the Mac.

## Blocked by

Issues 01+03 of `.scratch/presleep-stop/` must be merged; needs a
macOS machine.

## Comments
