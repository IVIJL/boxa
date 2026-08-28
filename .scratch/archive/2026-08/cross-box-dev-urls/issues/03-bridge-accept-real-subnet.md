# 03 — Firewall bridge ACCEPT uses the real devproxy subnet

Status: done

## Parent

None — pre-existing firewall bug, not covered by an ADR.

## What to build

The in-container firewall derives the bridge network by rewriting the last
octet of the default-gateway IP to `.0/24`. The `devproxy` network is a
`/16` (Docker default IPAM), so with more than ~254 containers, peers with
IPs outside the first `/24` (e.g. `172.18.1.x`) would silently fall outside
the ACCEPT rules — breaking Traefik reachability, cross-box traffic, and
host connections for those containers.

Derive the actual subnet from the container's routing table (the scope-link
route on the primary interface carries the true prefix, e.g.
`172.18.0.0/16`) instead of the sed octet hack, and use it for both the
INPUT and OUTPUT ACCEPT rules. Keep the failure mode: abort init if no
subnet can be determined.

## Acceptance criteria

- [x] The INPUT/OUTPUT ACCEPT rules carry the real subnet prefix of the
      devproxy network (verify `iptables -S` inside a box shows
      `172.18.0.0/16` on a default setup). Partially verified: this
      container's own `ip route` shows `172.18.0.0/16 dev eth0 proto kernel
      scope link src 172.18.0.5`, and the new `_detect_host_network` parsing
      logic (unit-tested against stubbed `ip` output) yields `172.18.0.0/16`
      for that shape of route table. Live `iptables -S` check inside a
      freshly recreated box is deferred host verification.
- [x] Firewall init still aborts loudly when the route table yields no
      usable subnet — covered by two new test cases (missing default route,
      missing scope-link route), both exit 1 with
      `ERROR: Failed to detect host network`.
- [x] No other rule ordering changes (allowlist ipset, catch-all REJECT,
      DNS-bypass guard untouched) — confirmed via diff review.

## Blocked by

None — can start immediately.

## Comments
