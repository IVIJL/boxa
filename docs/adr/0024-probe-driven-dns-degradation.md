# ADR 0024 — Probe-driven DNS degradation on system-incompatible network modes

- **Status:** accepted
- **Date:** 2026-08-08
- **Builds on:** ADR 0007 (local DNS with external fallback), ADR 0008
  (HTTPS via mkcert)

## Context

On WSL2 with `networkingMode=mirrored`, loopback port 53 is unusable: a
Windows service (ICS) holds `0.0.0.0:53` on the Windows side and the
mirroring layer swallows UDP/TCP to `127.0.0.1:53` even for a plain
listener inside the distro — packets never arrive, while any other port
works. Empirically verified: the boxa dnsmasq published on an alternate
port answers from both WSL and Windows; on 53 it answers from neither.
The same Windows-unreachable outcome occurs under NAT with
`localhostForwarding=false`.

NRPT (the Windows-side `.test` rule) can only target an IP on port 53 —
no port override exists. So on such systems the Windows browser cannot
reach the local resolver at all, and nothing boxa installs can change
that; only user-level system changes (reverting to NAT networking,
disabling the ICS service) can. This is an **Environment prerequisite**
in the CONTEXT.md sense.

The failure was initially misattributed to a Docker Desktop update that
landed the same day. Configuration inspection lied twice; only probing
the real resolution path told the truth.

## Decision

1. **A functional probe is the only signal.** boxa probes the actual
   path — `dig @127.0.0.1` from WSL, `Resolve-DnsName -Server 127.0.0.1`
   via interop from Windows — at `dns-install`, every `boxa up`,
   `dns-status`, `doctor`, and `boxa update`. Network-mode configuration
   (`wslinfo`, `.wslconfig`) is read only to *name the cause* in the
   message, never to decide.
2. **Auto-flip, sticky preference.** A failed probe flips
   `active_domain` to the external provider (ADR 0007 machinery);
   `preferred=local` stays. A later successful probe flips it back.
   Both transitions are automatic; while degraded, every `boxa up`
   prints a loud banner naming the cause, the exact remediation
   steps, and the external URL form. This state is the **DNS
   degradation** of CONTEXT.md.
3. **All-or-nothing.** We do not keep host-side `.test` half-alive on
   an alternate port (dnsmasq on `127.0.0.1:5335` + resolved drop-in
   with port syntax would work for WSL CLI only). Rejected: it
   contradicts the "systemically impossible, use the external domain"
   message, adds a second publish port and drop-in dialect to
   self-heal, and rescues only a minority surface. `.test` inside
   Containers is unaffected anyway: in-box dnsmasq answers `.test` and
   `.127.0.0.1.sslip.io` with Traefik's IP, resolved through Docker embedded
   DNS at `127.0.0.11`; other queries fall through that resolver to the host's
   upstream DNS. Neither path uses host loopback or `boxa_dns`.
4. **Leave installed artifacts in place.** When an existing install
   degrades, NRPT and the resolved drop-in stay — dead but harmless,
   and removal/reinstall would cost a UAC round-trip in each
   direction. Only a *fresh* install on an incompatible system skips
   them; when the system is later fixed, the normal provisioning
   steps install the missing pieces (one UAC prompt, at the moment it
   is useful).
5. **Never mutate the user's system configuration.** boxa does not
   write `.wslconfig` and does not touch Windows services; it prints
   the exact steps, consistent with the Environment-prerequisite
   contract.
6. **Certificates are installed regardless of mode.** The external
   URLs terminate TLS at the local Traefik like `.test` does; the
   mkcert per-project certificate carries SANs for both domains and
   the sslip HTTPS URL works only because of it. Skipping certs in
   degradation would silently downgrade the one URL form the user is
   told to rely on.

## Consequences

- `boxa ports` follows `active_domain`, so a degraded system prints
  working sslip URLs by construction — no dead links.
- The Windows interop probe costs ~1–2 s per `boxa up`; accepted in
  exchange for zero cached state and automatic two-way transitions.
- External-domain risk (ADR 0007: traefik.me died in May 2026) is
  unchanged: degradation is a fallback under an explicit banner, not a
  supported steady state, and recovery instructions are shown until
  the local path works again.
