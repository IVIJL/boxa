# 18 — keep-awake enable provisions the Windows firewall rule for the NAT path

Status: done

## Parent

ADR 0023 — Host connections. Background: under NAT networking, WSL →
Windows traffic to the keep-awake daemon arrives as real inbound on
the `vEthernet (WSL)` interface and is dropped by the Windows firewall
default deny; no rule is currently created anywhere. Under mirrored
networking the loopback path needs no rule.

## What to build

`boxa keep-awake enable` on WSL2 additionally ensures a Windows
firewall inbound rule for the keep-awake TCP port, scoped as narrowly
as the platform allows (the WSL vEthernet interface / WSL subnet, this
port only), created via elevated interop with a UAC prompt — the same
established pattern as the NRPT rule installation.

- Idempotent: an existing rule is detected and never duplicated.
- Declining the UAC prompt is survivable: a vocal warning explains
  that the NAT path stays blocked (mirrored/loopback keeps working),
  and enable continues.
- `boxa keep-awake disable` / uninstall removes the rule (best
  effort, again via elevated interop).
- `boxa keep-awake status` / `doctor` report the rule's presence and
  name it as the likely cause when the gateway target probe from
  issue 17 fails while the daemon runs.

## Acceptance criteria

- [x] Enable creates the scoped rule once; repeated enables do not
      duplicate it
- [x] Declined elevation → vocal warning, enable still succeeds
- [x] Disable/uninstall removes the rule
- [x] Status/doctor show rule presence and reference it in the
      gateway-unreachable diagnosis
- [x] Tests cover create/idempotence/decline/remove with PowerShell
      interop shims
- [x] shellcheck clean including info-level findings

## Blocked by

[17-keep-awake-relay-probe.md](17-keep-awake-relay-probe.md)

## Comments
