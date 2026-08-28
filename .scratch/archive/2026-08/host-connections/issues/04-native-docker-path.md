# 04 — Native Docker path: host relay + durable scoped ufw slot

Status: done

## Parent

ADR 0023 — Host connections via a durable scoped firewall slot.

## What to build

Host connections on native Docker (Linux with Docker CE, and Docker CE
under WSL2), where `host.docker.internal` maps to a host-owned bridge
gateway IP instead of a VM-routed magic address.

- **Detection is behavioral, not platform-guessing** (same approach as
  the agent-browser broker): resolve `host.docker.internal` (IPv4)
  inside the container, then test whether the host can bind the resolved
  IP. Bind succeeds → host-owned → this path. Bind fails → VM-owned
  (Docker Desktop, including Docker Desktop on Linux) → the issue-01
  branch, no host-side work.
- On the host-owned branch, Container start additionally brings up a
  host-side socat relay bound to exactly the resolved IP and port,
  forwarding to the service on the host loopback (host services bind
  loopback; containers cannot reach it directly), and — when ufw is
  installed and active — a durable ufw INPUT slot scoped to the exact
  destination IP, TCP port, and the container's bridge subnet (the
  agent-browser ephemeral slot, made durable).
- The resolved IP is re-checked on every start; relay and slot follow
  it. `rm` tears down relay and ufw slot along with the container-side
  pieces.
- Missing host `socat` fails the add with the exact install hint (same
  message discipline the broker uses).
- Help/docs name the native-Linux consequence explicitly: a standing,
  narrowly scoped host firewall rule that exists exactly as long as the
  entry does.

## Acceptance criteria

- [x] On a host-owned resolved IP, add + start bring up relay (bound to
      that IP:port only, not LAN-reachable) and, with ufw active, the
      scoped INPUT slot; the in-box curl reaches the host service.
- [x] On a VM-owned IP the branch is a no-op (Docker Desktop on Linux
      lands here automatically).
- [x] `rm` removes relay and ufw slot; restart does not resurrect them.
- [x] Replay after a changed bridge-gateway IP converges (old relay/slot
      gone, new ones up).
- [x] Shell tests cover detection branching and teardown (ufw and socat
      interactions mockable, as in existing broker tests); `shellcheck`
      clean.

## Blocked by

`01-connect-host-docker-desktop.md`

## Comments

- 2026-07-30: Implemented in 2f6027e (Codex-delegated). All criteria
  covered by tests in tests/connect-host.sh (mocked ufw/socat plus a
  real relay curl); shellcheck -S info clean. Note: criteria are proven
  by mocked shell tests, not a live native-Docker host integration run.
