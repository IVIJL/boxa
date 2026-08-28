# 04 — Windows idle-sleep prediction with scheduled wake-ups

Status: done

## Parent

None — Windows arm of the power-watch component (issue 03). Windows is
the only platform needing prediction: its suspend notification gives
~2 s, too short to stop containers, while Linux/macOS get a proper
delay window.

## What to build

Idle-sleep prediction inside the Windows power-watch:

- **Inputs**: effective sleep timeout from
  `powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE` for the
  active AC/DC state (`GetSystemPowerStatus`), refreshed roughly every
  5 minutes; user idle time from `GetLastInputInfo`.
- **Scheduled wake-ups, not polling**: compute
  `remaining = timeout − idle`; sleep until `remaining − 2 min`. At
  that check, recompute — if activity reset the clock, reschedule; if
  still on track, schedule the final check at the 1-minute mark. If at
  the final check `remaining ≤ 1 min` and the daemon holds **no awake
  lease**, run the hook (`wsl.exe -d <distro> boxa stop --all
  --reason presleep`) — the stop is parallel (issue 01) so it fits
  the 1-minute budget. The Closeout notification from the stop tells
  the user boxes were stopped even if the machine then never sleeps.
- While any awake lease is held, prediction is suspended entirely
  (the daemon's own `SetThreadExecutionState` blocks idle sleep, so a
  prediction would lie); it resumes when the last lease drops.
- After a fired stop, arm again only after user activity resets the
  idle clock (no repeated stop storms).
- Timeout of 0 / "never sleep" disables prediction cleanly.

## Acceptance criteria

- [ ] With a short test timeout, an idle Windows host gets its boxes
      stopped ~1 min before the sleep deadline and a notification is
      raised. — scheduling/fire logic covered by fake-based tests;
      deferred: live Windows verification (real sleep timing + real
      Closeout notification).
- [x] User activity between checks reschedules without firing —
      covered by fake idle-source test.
- [x] Held lease suspends prediction; releasing it re-arms — covered
      by fake lease-source + awake.Manager notification tests.
- [ ] AC/DC switch and power-plan changes are picked up within one
      settings refresh interval. — refresh-interval logic covered by
      fake settings source; deferred: live Windows verification (real
      `powercfg`/`GetSystemPowerStatus` output).
- [ ] "Never sleep" plans and query failures disable prediction
      without log spam. — disable-on-zero and no-log-spam-on-repeated-
      failure covered by fake tests; deferred: live Windows
      verification (real powercfg failure modes/localized output).
- [x] Unit tests with fake clock/idle/powercfg cover the scheduling
      state machine (reschedule, final check, fire, re-arm).

## Blocked by

.scratch/presleep-stop/issues/03-power-watch-linux.md — needs the
power-watch component and hook runner.

## Comments
