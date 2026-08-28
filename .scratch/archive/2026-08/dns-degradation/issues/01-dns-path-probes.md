# 01 — Functional DNS path probes surfaced in dns-status and doctor

Status: done

## Parent

ADR 0024 — Probe-driven DNS degradation on system-incompatible network
modes. Background: on WSL2 `networkingMode=mirrored`, loopback port 53
is unusable (Windows ICS holds `0.0.0.0:53`, the mirroring layer
swallows the traffic even for a plain in-distro listener), and under
NAT with `localhostForwarding=false` the Windows side cannot reach the
resolver either. NRPT cannot target a non-53 port, so nothing boxa
installs can fix it — it is an **Environment prerequisite**.

## What to build

Two reusable probes of the *actual* `.test` resolution path on WSL2,
plus their surfacing:

- **WSL-side probe** — a DNS query for a unique throwaway name under
  `.test` against `127.0.0.1`, in the spirit of the existing
  resolver-works verification.
- **Windows-side probe** — the same query issued from Windows via
  interop PowerShell with the resolver forced to `127.0.0.1`, i.e. the
  exact path NRPT uses. Timeout-bounded (a few seconds).

The probes must distinguish these states so later slices can act on
them: `both-ok`, `windows-broken`, `wsl-broken` (implies both), and
`resolver-not-running` (boxa_dns container down — *not* a degradation
signal). Tooling failures of the interop probe itself (PowerShell
unavailable/erroring) must fail safe: report unknown, never treat as
broken.

Cause naming is separate from the decision: best-effort read of
`wslinfo --networking-mode` and the user's `.wslconfig`
(`networkingMode`, `localhostForwarding`) produces the human
explanation only — it never influences the probe verdict.

`boxa dns-status` and `boxa doctor` show the per-side probe results
and the named cause; doctor treats a broken path as an Environment
prerequisite: it prints the exact remediation steps (remove
`networkingMode=mirrored` / set `localhostForwarding=true`, then
`wsl --shutdown`) and never mutates `.wslconfig` or Windows services.

Non-WSL2 platforms are untouched: probes and output changes activate
on WSL2 only; existing behaviour elsewhere stays as is.

## Acceptance criteria

- [x] Probe helpers exist, are reusable by other commands, and return
      the four distinct states above
- [x] `boxa dns-status` on WSL2 shows WSL-side and Windows-side probe
      results plus the named cause when a side is broken
- [x] `boxa doctor` reports a broken path as an Environment
      prerequisite with exact remediation text; no system config is
      ever written
- [x] Interop probe is timeout-bounded and fails safe (tooling error ≠
      broken path)
- [x] `resolver-not-running` is reported as such, not as degradation
- [x] Tests cover the probe state matrix with mocked `dig`/PowerShell
      shims; non-WSL2 behaviour unchanged
- [x] shellcheck clean including info-level findings

## Blocked by

None — can start immediately.

## Comments
