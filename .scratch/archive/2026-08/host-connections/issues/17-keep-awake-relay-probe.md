# 17 — Probe-driven keep-awake relay target and honest readiness

Status: done

## Parent

ADR 0023 — Host connections; probe philosophy per ADR 0024.
Background: the host-side keep-awake relay on WSL2 forwards to the WSL
loopback, but the keep-awake daemon is a Windows process — that target
only works under mirrored networking. Under NAT the daemon listens on
the `vEthernet (WSL)` adapter IP and is reachable from WSL via the
default gateway; the relay never tries it. The current readiness check
only verifies that the relay's socat is listening, so
`boxa connect host 17777` reports success while every forwarded
connection dies — a false positive.

## What to build

- **Target selection by functional probe:** when starting the
  keep-awake relay on WSL2, probe the candidates — the WSL loopback,
  then the WSL default gateway — with a real HTTP status request
  against the daemon, and relay to the first one that answers. No
  decision based on `wslinfo`/`.wslconfig`; configuration may only
  name the situation in messages.
- **End-to-end readiness:** the Host connection readiness check for
  the keep-awake port verifies an actual daemon HTTP response through
  the relay, not just a successful socat bind.
- **Loud failure:** when no candidate answers, the failing step is
  named (relay target selection: daemon unreachable on loopback and
  gateway) with a hint (daemon not running / Windows firewall).
  Existing semantics stay: keep-awake enable survives a failed
  connect; the connect itself must not report success.
- `boxa keep-awake status` / `doctor` report which target the active
  relay uses, and their own daemon probe uses the same candidate
  logic instead of assuming the gateway.

## Acceptance criteria

- [x] Mirrored-style environment (daemon answering on loopback) →
      relay targets loopback; NAT-style (daemon answering only on
      gateway) → relay targets gateway
- [x] Readiness passes only when a daemon HTTP response comes back
      through the relay
- [x] No responding candidate → connect fails loudly naming the step
      and hint; keep-awake enable continues per existing semantics
- [x] `keep-awake status`/`doctor` show the selected target and use
      the shared candidate logic
- [x] Tests cover candidate selection, honest readiness and the
      no-candidate failure with mocked daemon endpoints
- [x] shellcheck clean including info-level findings

## Blocked by

None — can start immediately (independent of the dns-degradation
issues).

## Comments
