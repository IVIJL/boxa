# Agent Awake reference — field notes (2026-07-30)

Working reference implementation for the keep-awake host service that the
host-connections feature should eventually serve. Three files:

- `AgentAwake.ps1` — Windows daemon. `-Action service` holds state **in
  memory** and serves a minimal hand-rolled HTTP endpoint on `0.0.0.0:17777`
  via `TcpListener` (deliberately not `HttpListener`, which needs urlacl/admin
  for non-localhost prefixes). `-Action busy|idle|status` are thin HTTP
  clients of the running service. Port bind failure = another instance runs →
  silent exit (this doubles as the single-instance guard).
- `AgentAwakeTray.ps1` — optional tray indicator, separate process, polls
  `/status`. Single-instance via named mutex. Keep daemon and tray lifecycle
  decoupled: today the tray died (parent window closed) while the daemon kept
  running fine.
- `agent-awake-client.sh` — the Claude Code hook client. Shows the address
  resolution problem a productized client must solve: WSL host → default
  gateway IP (= Windows vEthernet, changes across reboots); boxa container →
  currently a hardcoded relay IP, which is exactly what `host-service` DNS
  discovery should replace.

## API contract (as implemented)

```
GET /busy/<agent>    agent ∈ claude|codex|pi → 200 "ok"
GET /idle/<agent>    → 200 "ok"
GET /status          → 200 {"activeAgents":[...],"isPreventingSleep":bool,"dryRun":bool}
```

Server-side stale timeout: a busy agent auto-expires after 900 s without a
new `/busy` signal — hooks fire on every tool call, so heartbeats are free.
This is the behaviour the TTL-in-contract proposal formalizes.

## Gotchas learned the hard way

- **PowerShell 5.1:** the literal `0x80000000` (`ES_CONTINUOUS`) overflows to
  a negative Int32 and the cast to the P/Invoke `uint` parameter throws. Use
  `[uint32]2147483648`. The original state-file version crashed on this.
- **Hidden-window processes crash invisibly.** Both scripts now log to
  `agent-awake.log` next to the script; the tray uses a script-level `trap`
  so even startup crashes land in the log. A Go daemon should keep an
  equivalent crash log.
- **Container → Windows host paths that do NOT work under Docker Desktop +
  boxa:** direct WSL gateway IP (shadowed by the docker bridge subnet),
  `host.docker.internal` (boxa default-deny REJECTs it), Windows LAN IP
  (same). `boxa allow host.docker.internal` writes the dnsmasq
  `ipset=/…/allowed-domains` line but the IP never lands in the ipset —
  allowlist domains appear to be pre-resolved host-side, where that name
  does not resolve. The bridge-subnet relay works because `-d 172.18.0.0/24
  -j ACCEPT` is already in the egress chain by design.
- **Security debt:** the daemon listens unauthenticated on `0.0.0.0`; anyone
  on the LAN can toggle keep-awake. Fine for a personal box, not for a
  published project — productized version should bind selectively
  (localhost + WSL/bridge interfaces) or require a token.
- **No `/v1` prefix yet.** If the API becomes a public contract, version it.

## Host-side lifecycle (current, Windows)

Autostart lives in WezTerm `gui-startup`
(`~/.config/wezterm/wezterm.lua` on the Windows side): spawns daemon + tray
hidden at GUI start; duplicate spawns are no-ops thanks to the port/mutex
guards. A productized daemon should own this per platform (scheduled task /
launchd / systemd user unit) instead of piggybacking on the terminal.
