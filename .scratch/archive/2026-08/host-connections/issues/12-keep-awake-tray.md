# 12 — keep-awake tray indicators (Windows / macOS / Linux), optional and decoupled

Status: done

## Parent

Follow-up to issues 08–10. The daemon is headless by design; per the
prototype lessons in `../reference/NOTES.md`, any tray/indicator is a
**separate optional process with an independent lifecycle** — never
coupled to the daemon. This slice ships those indicators.

## What to build

Per-platform tray indicators that poll the daemon's `GET /v1/status`
(default `http://localhost:17777`) every ~5 s and show busy/idle state
(distinct icon + tooltip listing active holders). Installed, started,
reported, and removed by the existing `boxa keep-awake
enable|status|disable` flows in `scripts/ensure-keep-awake.sh`.
**Best-effort everywhere: a missing tray prerequisite prints a notice
and skips the tray — it must never fail or block enable, and a tray
crash must never affect the daemon.**

Sources live under `keep-awake/tray/` in the repo; `enable` installs
them next to the daemon binary.

- **Windows (wsl2 platform):** PowerShell WinForms `NotifyIcon` script,
  modernised from the prototype `../reference/AgentAwakeTray.ps1`
  (keep: single-instance mutex, crash-trap to log file, generated
  circle icons, context-menu quit — label in English). Change: poll
  `/v1/status` (v1 JSON: holders with remaining TTLs, `inhibited`
  flag, version) instead of the legacy `/status`; tooltip shows holder
  names, icon green when inhibited, gray when idle. Autostart via a
  second logon scheduled task (e.g. `BoxaKeepAwakeTray`) created and
  deleted alongside the daemon task; mind PS 5.1 compatibility (see
  NOTES.md scars).
- **macOS:** small AppKit `NSStatusItem` app (single Swift file in the
  repo, ~100 lines) compiled at enable time with `swiftc` (Xcode CLT);
  menu-bar dot green/gray + holders in the menu, Quit item. Autostart
  via a second launchd user agent. If `swiftc` is missing, skip with a
  notice naming the remedy (`xcode-select --install`).
- **Linux (non-WSL):** shell script driving `yad --notification
  --listen` (icon + tooltip updates via stdin, quit menu item),
  autostart via a second systemd user unit. If `yad` is missing, skip
  with a notice naming the package.

`status` reports the tray as its own line (running / not installed /
skipped-missing-prereq); `disable` and the uninstall teardown remove
tray autostart entries and stop the tray on every platform.

Constraints: match surrounding shell style; shellcheck-clean including
info-level; daemon source untouched except adding `tray/` alongside it
(no Go changes); tray talks only to the local daemon, no other network;
do not touch `dotfiles/`.

## Acceptance criteria

- [x] Windows tray script polls `/v1/status`, distinguishes busy/idle
      via `inhibited`, lists holders in the tooltip, keeps the mutex +
      crash-log behaviour; scheduled task created on enable, removed on
      disable (verified via mocks in `tests/keep-awake.sh`).
- [x] macOS and Linux indicators exist in `keep-awake/tray/` with their
      autostart wiring in enable/disable; missing `swiftc`/`yad` skips
      with a notice and enable still succeeds (mock-tested).
- [x] Tray failure paths never fail enable; disable/uninstall remove
      all tray artifacts (mock-tested).
- [x] `status` shows the tray line per platform (mock-tested).
- [x] `shellcheck` clean on changed/added scripts; PowerShell script
      has no PS 5.1-incompatible constructs (verified by grep; no pwsh
      available in container to run it directly).

## Blocked by

None — independent of issue 11 (touches different functions of
`ensure-keep-awake.sh`; if both land, integrate on latest main).

## Comments

- Live visual verification (icon actually visible in the Windows tray /
  macOS menu bar) is a host-side manual check, out of container scope.

- 2026-07-31: Implemented via Codex delegation, commit `8420f13`. Tray
  sources added under `keep-awake/tray/` (PS1 WinForms, Swift AppKit,
  yad shell script + icons); `scripts/ensure-keep-awake.sh` wires
  install/autostart/status/teardown for all three platforms,
  best-effort with missing-prereq notices. `bash tests/keep-awake.sh`
  103/103 pass, `bash tests/connect-host.sh` regression 140/140 pass,
  shellcheck clean (incl. info-level) on all changed/added scripts.
  PowerShell script checked by grep for PS7-only constructs (no pwsh
  in container to run it directly) — clean. Live visual check on
  Windows/macOS tray remains a manual host-side step.
