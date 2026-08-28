# 16 — Tray indicator for terminal-mode keep-awake (follows WezTerm)

Status: done

## Parent

ADR 0023; extends issue 12 (tray) + issue 14 (autostart modes), which
deliberately coupled the tray to `--autostart system`. User decision
2026-08-07: with `--autostart terminal` the tray SHOULD exist, but only
while the terminal session lives — no icon when not working.

## What to build

wsl2 scope (linux/macos terminal-mode tray stays deferred; their status
line keeps explaining the absence):

1. `keep-awake-tray.ps1` accepts an optional second argument
   `FollowProcess` (process name). When set, each poll also checks
   `Get-Process -Name $FollowProcess`; when the process is gone, the
   tray removes its icon and exits. Without the argument the behaviour
   is unchanged (system mode).
2. `start-keep-awake.ps1` (wrapper) accepts `-TrayFollow <name>`; when
   set and the tray script is installed, it spawns the tray hidden with
   the port + follow argument before starting the daemon. The existing
   `Local\BoxaKeepAwakeTray` mutex dedupes double starts.
3. The wezterm.lua terminal snippet passes `-TrayFollow, 'wezterm-gui'`.
4. `enable --autostart terminal` installs the tray SCRIPT (no scheduled
   task) and best-effort starts it immediately (the current WezTerm
   session already missed gui-startup).
5. `tray::remove` (wsl2) also stops a wrapper-spawned tray process
   (match `keep-awake-tray.ps1` in the command line), so disable/mode
   switches leave no orphan icon.
6. `status` in terminal mode on wsl2 reports the real tray state
   (`running` / `not running (starts with WezTerm)`) instead of
   `not installed (autostart: terminal)`.

## Acceptance criteria

- [ ] Terminal-mode enable installs the tray script, no tray scheduled
      task, and logs an immediate tray start.
- [ ] The generated wrapper only spawns the tray when `-TrayFollow` is
      given (system-mode scheduled task path unaffected).
- [ ] Terminal snippet carries `-TrayFollow 'wezterm-gui'`.
- [ ] Tray script exits by itself when the followed process disappears.
- [ ] Disable after terminal mode removes the script and stops a running
      tray process.
- [ ] Terminal-mode status reflects the live tray state on wsl2.
- [ ] System-mode behaviour and tests unchanged; shellcheck clean.

## Blocked by

None — can start immediately.

## Comments

2026-08-07 (agent): Implemented, uncommitted. Tray ps1: optional second
arg `FollowProcess`, poll tick exits the tray when the process is gone.
Wrapper: `param([string]$TrayFollow)`, spawns the tray hidden (port +
follow) only when the parameter is set; snippet passes
`-TrayFollow 'wezterm-gui'`. `tray::enable_terminal` (wsl2) installs the
script without a schtask and best-effort starts it immediately;
`tray::remove` additionally Stop-Processes a wrapper-spawned tray;
`tray::status` (wsl2) also recognises a process-only tray; `status`
maps terminal mode to `running` / `not running (starts with WezTerm)`.
Tests: +11 assertions (mock powershell gained Get-CimInstance /
Start-Process branches, `KEEP_AWAKE_TEST_TRAY_PROCESS` switch). 173
keep-awake + 154 connect-host pass, shellcheck clean. Linux/macos
terminal tray deferred as specified.
