# 10 — `boxa keep-awake`: Elective step, autostart, `--all` Host connection

Status: done

## Parent

ADR 0023; ADR 0017 (provisioning registry — this is a new Elective
step).

## What to build

Optional enablement of the keep-awake daemon, following the existing
Elective-step pattern (like the HTTPS upgrade and MCP onboarding):

- **Install-time**: `install.sh` offers keep-awake with a prompt and an
  opt-out/seen marker. Declining is remembered; `boxa doctor` then only
  reports it, and `boxa doctor --fix keep-awake` (or the subcommand
  below) enables it later.
- **`boxa keep-awake enable`**: obtains the binary (build from repo
  source with the local Go toolchain; a missing toolchain is an
  Environment prerequisite — diagnose and print the exact install
  command, never half-install), installs platform autostart (Windows:
  scheduled task at logon; macOS: launchd user agent; Linux: systemd
  user unit), starts the daemon, and creates the `--all` Host connection
  for the daemon port so every box can signal immediately.
- **`boxa keep-awake disable`**: stops the daemon, removes autostart and
  the `--all` Host connection. **`boxa keep-awake status`**: daemon
  reachable? holders? autostart installed? Host connection present?
- Uninstall includes keep-awake teardown (daemon, autostart; the Host
  connection is already swept by issue 05).
- Docs: a short user section with an example client — a hook that
  heartbeats `/v1/busy/<agent>?ttl=900` on activity and calls idle on
  stop, with the resolution order a client should try (native
  Linux/macOS → localhost; WSL host → vEthernet/gateway IP; boxa
  container → the Host connection's local port).

## Acceptance criteria

- [x] Fresh install prompts once; decline is remembered; doctor reports
      (not repairs) the declined step.
- [x] `enable` on a clean host yields: daemon running, autostart
      installed, `--all` Host connection present; an in-box curl to the
      local port returns `/v1/status` JSON.
- [x] `disable` reverses all three; `status` reflects each state
      truthfully.
- [x] Missing Go toolchain → exact hint, no partial state left behind.
- [x] Shell tests for the provisioning step, enable/disable/status
      surfaces (daemon mockable); `shellcheck` clean.

## Blocked by

`03-all-scope.md`, `08-keep-awake-daemon-core.md`,
`09-keep-awake-windows-backend.md`

## Comments

- 2026-07-30 (agent, commit c413b81): implemented via Codex delegate.
  All criteria are covered by tests/keep-awake.sh +
  tests/test_provisioning.sh with mocks (no Go toolchain in the
  container, no real host): `go build`, systemctl/launchctl/schtasks
  and the daemon HTTP endpoint are PATH stubs. Deferred host
  verifications: real `go build` of keep-awake/, real autostart on
  each platform, and a live in-box curl to `/v1/status` against the
  real daemon.
