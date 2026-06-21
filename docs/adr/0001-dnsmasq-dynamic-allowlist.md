# ADR 0001 — dnsmasq dynamic resolution for the firewall allowlist

- **Status:** accepted
- **Date:** 2026-05-03

## Context

Boxa runs every container behind a default-deny iptables firewall. Outbound
traffic is allowed only to IPs in the `allowed-domains` ipset. The ipset is
populated from two sources:

1. **GitHub IP ranges** — fetched once at container startup from
   `api.github.com/meta` and inserted into the ipset as static CIDRs.
2. **Domain-based rules** — for every domain in
   `~/.config/boxa/allowed-domains.conf`, a dnsmasq `ipset=/<domain>/allowed-domains`
   directive is generated. dnsmasq then adds the resolved IP to the ipset
   **at DNS lookup time**, every time, automatically.

The alternative we did **not** take is `dig <domain>` at startup and
`ipset add allowed-domains <ip>` for each result.

## Decision

The allowlist uses dnsmasq's `--ipset=` directive for dynamic resolution.
Static `dig + ipset add` is reserved for sources that publish stable IP
ranges (currently only GitHub).

Both `foo.com` and `*.foo.com` are accepted in `allowed-domains.conf` and
mean the same thing: **the domain and all its subdomains**. The `*.` prefix
is purely cosmetic — dnsmasq's `ipset=/foo.com/...` directive matches
`foo.com` and every subdomain by design. There is no "exact-only" form,
because dnsmasq does not expose one.

Wildcard normalization (stripping `*.`) happens at render time, inside
`allowlist::render_dnsmasq` in `lib/allowlist.sh`. The user-facing file
preserves whatever the user wrote.

## Consequences

**Positive:**

- CDN-backed domains (Cloudflare, Fastly, R2, …) work without manual IP
  refresh as backends rotate. The ipset stays correct as long as the app
  resolves through dnsmasq, which it does (`/etc/resolv.conf` points at
  127.0.0.1).
- Single source of truth: one entry in `allowed-domains.conf` per domain,
  no parallel CIDR list to keep in sync.
- New defaults can be added by editing `config/default-allowlist.conf`
  without touching shell code.

**Negative:**

- Cannot allow a single domain without also allowing its subdomains. If
  this becomes a real need later, **add a third syntactic form** (e.g.
  `=foo.com` for exact-only) rather than overloading the existing entries.
- Long-lived TCP connections that outlive the dnsmasq cache TTL **and**
  the upstream IP rotation may break. We have not seen this in practice;
  if it happens, the fix is per-app (reconnect on failure) not per-firewall.
- An app that bypasses the system resolver (rare; some Go binaries with
  CGO disabled) will not trigger dnsmasq, so its destination IP will not
  be added to the ipset. The connection will be dropped by iptables. We
  accept this.

## References

- `init-firewall.sh:64–68` — the inline comment that originally captured
  this decision.
- `lib/allowlist.sh` — the implementation.
- dnsmasq `--ipset` directive — matches the named domain *and all its
  subdomains*. No mode for exact-only.
