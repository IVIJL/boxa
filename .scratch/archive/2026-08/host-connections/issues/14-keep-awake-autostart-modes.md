# 14 — keep-awake autostart modes: system (default) / terminal / none

Status: done

## Parent

Follow-up to issues 10–13. Miloš's prototype was launched from WezTerm's
`gui-startup` hook instead of a system autostart; keep this as a
first-class option. The daemon's port-bind single-instance guard already
makes duplicate launches safe, so modes may even coexist.

## What to build

`boxa keep-awake enable` gains `--autostart <system|terminal|none>`
(default `system`, today's behaviour) in `scripts/ensure-keep-awake.sh`:

- **system** — unchanged: scheduled task (Windows) / launchd user agent
  (macOS) / systemd user unit (Linux).
- **terminal** — do NOT install the system autostart. Instead print a
  ready-to-paste WezTerm `gui-startup` snippet with the REAL resolved
  paths (no placeholders), launching the daemon detached via
  `wezterm.background_child_process`:
  - wsl2: launch the existing PowerShell wrapper
    (`powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle
    Hidden -File <windows path to the generated start wrapper>`) — the
    wrapper owns WSL-gateway resolution and MUST stay the entry point;
    never the raw exe.
  - linux/macos: launch the installed binary with the same arguments
    the autostart unit would use.
  Also start the daemon immediately (as enable already does via the
  wrapper/binary) so the current session works without a restart. Docs
  note for non-WezTerm terminals: run the wrapper/binary from any
  startup hook; the port-bind guard makes duplicates safe.
- **none** — install binary + Host connection + hook wiring, start the
  daemon now, but no autostart of any kind; user owns startup.
- Windows binary build adds `-ldflags -H=windowsgui` (both docker and
  local-go build paths) so a direct/terminal launch never flashes a
  console window; daemon logging already goes to the log file, but
  verify nothing in the daemon writes to stdout/stderr in normal
  operation on Windows (crash output still lands in the crash log).
- Persist the chosen mode in the keep-awake state file; `boxa
  keep-awake status` reports it (`autostart: system|terminal|none`);
  `disable`/teardown keeps working for every mode (removing a system
  autostart that does not exist must stay a no-op; for terminal mode
  remind the user to drop the WezTerm block).
- `docs/keep-awake.md`: short "Start with your terminal instead of the
  system" section with the snippet story and the trade-off (daemon dies
  with the terminal session's lifetime on close vs. always-on system
  autostart; idle daemon costs nothing).

Constraints: match surrounding shell style; shellcheck clean incl.
info-level; no daemon Go source changes (ldflags is a build-command
change only); do not touch `dotfiles/`; tray autostart wiring (issue
12) follows the same mode — terminal/none installs no tray autostart
either, tray line in status says why.

## Acceptance criteria

- [x] `enable --autostart terminal` installs no system autostart,
      starts the daemon, prints a WezTerm snippet with real paths
      (wsl2 → wrapper via powershell, unix → binary); mock-tested.
- [x] `enable --autostart none` starts the daemon with no autostart;
      `enable` with no flag still installs system autostart;
      mock-tested.
- [x] Mode persisted in state; `status` reports it; `disable` cleans
      up correctly in all three modes (no-op removal safe);
      mock-tested.
- [x] Windows build (docker and local paths) uses
      `-ldflags -H=windowsgui`; covered by build-command assertions in
      `tests/keep-awake.sh`.
- [x] Tray autostart follows the mode; status explains; mock-tested.
- [x] `shellcheck` clean on changed scripts; existing suites green.

## Blocked by

None — builds on landed issues 10–13.

## Comments

- Live check (WezTerm actually launching the daemon on GUI start, no
  console flash) is a host-side manual step.
- 2026-07-31 (e7a02ec): implemented via Codex delegation — added
  `--autostart system|terminal|none` to `ensure-keep-awake.sh`
  (persisted mode, WezTerm snippet, tray follows mode, windowsgui
  build flags), wired CLI help in `docker-run.sh`, docs in
  `docs/keep-awake.md`; `tests/keep-awake.sh` (158 assertions) and
  `tests/connect-host.sh` green, shellcheck -S info clean. Live
  WezTerm GUI-start check remains a manual host step.
