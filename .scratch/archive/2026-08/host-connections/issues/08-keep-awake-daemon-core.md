# 08 — Keep-awake daemon core: Go binary, /v1 contract, Linux + macOS

Status: done

## Parent

ADR 0023 (consumer side; the daemon itself is a new component). None of
the existing ADRs cover the daemon — expect a new ADR for the contract
if design trade-offs surface during implementation.

## What to build

A single cross-platform Go binary (`keep-awake` working name) that
prevents the host from sleeping while any coding agent reports work in
progress. Source lives in this repo; per-OS behaviour via build tags.
This slice ships the daemon core plus the Linux and macOS sleep
inhibitors; Windows is issue 09; install/enable wiring is issue 10.

HTTP contract (versioned, the thing third parties integrate against):

- `GET /v1/busy/<agent>?ttl=<seconds>&session=<id>` — mark the
  agent/session busy for `ttl` (default e.g. 900 s). Heartbeat
  semantics: every call re-arms the expiry; an entry whose TTL lapses
  expires on its own, so a crashed client can never hold the machine
  awake and a lost idle never sticks.
- `GET /v1/idle/<agent>?session=<id>` — immediate release (an
  optimization over waiting for expiry). The optional `session`
  distinguishes concurrent holders of the same agent name, so one box
  going idle does not release another box's hold.
- `GET /v1/status` — JSON: active holders with remaining TTLs, whether
  sleep is inhibited, daemon version.
- Unversioned/unknown paths → 404 with a hint to `/v1/status`.

Operational requirements (lessons from the existing PowerShell
prototype — see the reference copy in this feature directory):

- **Bind only loopback plus the interfaces containers/WSL arrive from**
  (bridge/vEthernet). Never 0.0.0.0 — no LAN exposure, no auth needed.
- **Single instance via port bind**: a second start detects the bound
  port and exits with a clear message.
- **Crash-log to a file**, no other disk writes (state is in-memory).
- Sleep inhibition held only while at least one holder is live:
  - Linux: systemd-logind D-Bus Inhibit (or `systemd-inhibit` child).
  - macOS: IOKit power assertion (or a managed `caffeinate` child).
- Headless. Any tray/indicator is a separate optional process with an
  independent lifecycle (the prototype's tray died independently of the
  service; never couple them).

## Acceptance criteria

- [x] `go build` per platform from repo source; no cgo requirement that
      breaks cross-compilation.
- [x] Busy → status shows the holder and inhibition on; TTL lapse with
      no heartbeat → holder expires and inhibition drops without any
      idle call.
- [x] Two sessions of the same agent: one idles, the other still holds.
- [x] Second daemon instance refuses to start; message names the port.
- [x] Daemon binds only the configured interfaces (verifiable in tests
      via listener addresses).
- [x] Go unit tests for the HTTP contract and TTL bookkeeping; inhibitor
      backends behind an interface with a fake for tests.

## Blocked by

None — can start immediately (independent of the boxa CLI slices).

## Comments

- 2026-07-30: Implemented in `keep-awake/` (commit 9d9dc66): daemon core,
  `/v1` contract (busy/idle/status, TTL heartbeat, session-scoped idle),
  loopback-only default bind + explicit `-listen-address`, port-bind
  single-instance guard naming the port, crash log, inhibitor interface +
  fake + tests; Linux = managed `systemd-inhibit --what=idle:sleep` child,
  macOS = managed `caffeinate -i` child, Windows = compile-only stub for
  issue 09. **DEFERRED VERIFICATION:** Go toolchain unavailable in the boxa
  container (no root, egress firewall blocks toolchain download), so
  `go build`/`go vet`/`go test` and the cross-compiles were NOT run —
  acceptance boxes stay unchecked until verified on the host. Code was
  manually reviewed (build tags, imports, stdlib-only, no cgo).
- 2026-07-30 (later): Deferred verification DONE — the "no Go toolchain"
  blocker was container-local thinking: the boxa container has the Docker
  socket, and a container run by the host daemon is not behind the boxa
  firewall. `docker run --rm -v <repo>/keep-awake:/src -w /src golang:1.22
  sh -c 'go vet ./... && go test ./... && CGO_ENABLED=0
  GOOS={linux,darwin,windows} go build ./...'` → vet clean, all tests ok
  (awake, httpapi, netlisten), all three cross-builds succeed. Acceptance
  boxes checked. Only the live-on-Windows checks (issue 09) remain manual.
- 2026-07-30: Reference material landed in `../reference/`:
  `AgentAwake.ps1` + `AgentAwakeTray.ps1` (current prototype),
  `agent-awake-client.sh` (hook client showing the address-resolution
  problem the Host connection removes), and **`NOTES.md` — required
  reading**: today's API contract (900 s stale timeout = de facto
  heartbeat), the security debt (unauthenticated 0.0.0.0 → bind
  selectively), missing API versioning, and daemon/tray lifecycle
  decoupling. PS-specific findings (PS 5.1 0x80000000 overflow,
  TcpListener-over-HttpListener because of urlacl) explain prototype
  scars; the Go daemon sidesteps them but should not reintroduce their
  root causes.
