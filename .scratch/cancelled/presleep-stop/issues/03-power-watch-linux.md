# 03 — Power-watch component in the keep-awake daemon + Linux delay inhibitor

Status: done

## Parent

None — new daemon component. Related: ADR 0023 for the daemon's trust
model.

## What to build

A new per-platform **power-watch** component in the keep-awake daemon
(same structural pattern as the existing per-platform inhibitors),
plus its first real implementation on Linux:

- **Hook runner**: power-watch executes a configured host command when
  the system is about to sleep or shut down. Default hook:
  `boxa stop --all --reason presleep` (on a WSL2-managed daemon the
  Windows wrapper configures `wsl.exe -d <distro> boxa stop --all
  --reason presleep`; the distro comes from the same place the wrapper
  already knows it). Command is overridable via daemon flag/config.
  Hook runs with a bounded timeout; output goes to the daemon log.
- **Linux implementation**: take a logind **delay inhibitor lock**
  (`sleep:shutdown`, mode `delay`) at startup, subscribe to DBus
  `PrepareForSleep` / `PrepareForShutdown`, run the hook inside the
  delay window, then release the lock so the transition proceeds. No
  idle prediction on Linux — the delay window covers idle sleep,
  manual sleep and shutdown alike. Document that a longer stop budget
  needs `InhibitDelayMaxSec` raised in logind.conf, and surface a
  doctor/status hint when the effective delay is shorter than the stop
  budget.
- **Enabled by default**: power-watch is part of plain
  `boxa keep-awake enable` — no separate toggle (an opt-out can be
  added later if ever needed).
- Interaction with leases: power-watch fires regardless of held awake
  leases (if the OS is going down anyway, stopping cleanly beats being
  frozen mid-write).
- Platform stubs for Windows/macOS (no-op) so the daemon builds
  everywhere; Windows behaviour lands in issues 04/05, macOS is
  deferred (see `.scratch/mac/presleep-stop/`).

## Acceptance criteria

- [x] Daemon acquires a logind delay inhibitor on Linux and releases
      it after running the hook on PrepareForSleep/PrepareForShutdown.
- [x] Hook command is configurable; default resolves to the boxa stop
      invocation appropriate for the platform (direct vs `wsl.exe`).
- [x] Hook timeout is enforced; a hanging hook never blocks the
      transition beyond the delay window.
- [x] `keep-awake enable` brings power-watch up with no extra flags;
      `/v1/status` (or daemon log) shows power-watch active.
- [x] Unit tests with a fake DBus/logind cover: sleep signal, shutdown
      signal, hook failure, hook timeout.
- [x] docs/keep-awake.md gains a "Pre-sleep stop" section describing
      behaviour and the InhibitDelayMaxSec note.

## Blocked by

.scratch/presleep-stop/issues/01-stop-all-flag.md — the hook's default
command must exist.

## Comments

2026-08-09: Implemented in 6d6c8be. Unit tests use a fake logind/DBus source; live logind verification (real sleep/shutdown on a Linux host) deferred to the user.
