# ADR 0015 — Firewall DNS pin breaks the embedded resolver's upstream forward on native Docker

- **Status:** accepted
- **Date:** 2026-06-08
- **Builds on:** ADR 0001 (dnsmasq dynamic allowlist), ADR 0009 (allow-for
  harvest window — the reason DNS is pinned to the in-container resolver)

## Context

ADR 0009 hardened the firewall so every name resolution flows through the
in-container dnsmasq. `init-firewall.sh` pins outbound DNS:

```
iptables -A OUTPUT -p udp --dport 53 -d 127.0.0.1 -j ACCEPT   # dnsmasq only
iptables -A OUTPUT -p tcp --dport 53 -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j REJECT                # everything else
iptables -A OUTPUT -p tcp --dport 53 -j REJECT
```

dnsmasq forwards to the upstream captured from the original `/etc/resolv.conf`,
which on a user-defined Docker network is always `127.0.0.11` — Docker's
embedded resolver. The embedded resolver then forwards external queries to the
**Docker daemon's** upstream DNS.

After this hardening shipped, boxa broke on **Omarchy** (Arch): the container
booted "successfully" but nothing resolved inside it. It kept working on
**Ubuntu**, **WSL2 / Docker Desktop**, and had worked on Omarchy *before* the
update.

### What actually differs

The breakage is not Docker-Desktop-vs-native and not Omarchy-specific. It is
**how the Docker embedded resolver forwards its upstream query**, which depends
on whether the daemon's configured DNS is a loopback address:

- **Loopback / unset daemon DNS** (Ubuntu host `resolv.conf` = `127.0.0.53`
  systemd-resolved; Docker Desktop) — the embedded resolver cannot send a
  loopback address out of the container (it would be the container's own
  loopback), so Docker **proxies the upstream forward host-side**. The packet
  never enters the container's network namespace, never hits the OUTPUT chain,
  and the DNS pin does not see it. Resolution works.

- **Non-loopback daemon DNS** (Omarchy ships `daemon.json` with
  `"dns": ["172.17.0.1"]` so containers use the host's systemd-resolved stub
  instead of leaking to public DNS) — the embedded resolver forwards external
  queries **from the querying container's own network namespace** to that IP,
  because the operator declared it as a reachable external server. That packet
  egresses the container, hits the OUTPUT chain, matches the catch-all
  `--dport 53 REJECT`, and dies. Every lookup SERVFAILs.

Empirically confirmed on Omarchy: a plain `docker run --rm --network devproxy
busybox nslookup github.com` resolves (no firewall), while the boxa container
on the same network does not (firewall present). Same host, same network, same
embedded resolver — the only difference is the DNS pin.

### Why the failure was silent

`init-firewall.sh` still reports "configuration complete" with a dead upstream:
the positive reachability assertions are GitHub-gated (skipped when the GitHub
meta fetch — itself a DNS lookup — fails), and the negative assertions ("google
must be unreachable", "external DNS must be unreachable") pass precisely
*because* nothing resolves. A total DNS outage looks like a clean boot.

### Where the upstream IP is visible

Inside the container, `/etc/resolv.conf` shows only `127.0.0.11`; the real
daemon upstream (`172.17.0.1`) is never exposed there. So the container cannot
self-detect the IP it needs to allow — detection must happen host-side.

## Decision

Open a **narrow, single-IP hole** in the DNS pin for the embedded resolver's
own upstream forward, and only when the daemon DNS is non-loopback.

1. **Host-side detection** (`docker-run.sh`, `detect_docker_dns_upstream`)
   finds the non-loopback upstream(s) the embedded resolver forwards to and
   writes them (space-separated — `daemon.json` may declare several servers and
   Docker falls back to later entries, so each must be allowed) to a host file
   bind-mounted read-only into the container at
   `/etc/boxa-shared/dns-upstream.conf`. A **bind-mounted file, not a
   `-e` env var**: env is frozen at container create, but `docker start`
   re-runs the entrypoint firewall, so `write_dns_upstream_file` is called on
   **both** the create and the restart paths and the file is re-read each time
   — a daemon-DNS change is picked up on the next restart without recreating
   the container. The file is truncated in place (memory: Docker Desktop
   snapshots bind mounts by inode). Detection is two tiers, matching Docker's
   own precedence, parsed **without jq** (`install.sh` does not provision jq
   host-side, so requiring it would no-op the fix on the very hosts it
   targets):
   - **Explicit daemon DNS** — `dns` from the **active daemon's**
     `daemon.json` (rootless uses `$XDG_CONFIG_HOME/docker`, rootful uses
     `/etc/docker`; selected via `docker info`, not a fixed order, so a stale
     config for the other daemon kind is never read). Applies on every
     platform; takes precedence.
   - **Inherited host DNS** — when no explicit `dns` is set, a native-Linux
     daemon inherits the host's `/etc/resolv.conf` and forwards its
     non-loopback nameservers from the container netns (same breakage). Read
     those as a fallback. **Skipped on Docker Desktop** (`docker info`
     OperatingSystem), which forwards upstream inside its own VM — never
     through the container firewall — and reads that VM's resolv.conf, not the
     host's.

   Empty when every candidate is loopback (systemd-resolved 127.0.0.53) — the
   common case — so Ubuntu / Docker Desktop are unchanged.

2. **In-container allow** (`init-firewall.sh`): for each valid IPv4 in
   `BOXA_DNS_UPSTREAM`, insert `--dport 53 -d <ip> -j ACCEPT` (udp+tcp)
   **before** the catch-all `--dport 53 REJECT`. A malformed entry is ignored
   with a warning rather than aborting the firewall.

3. **Loud DNS probe**, on both surfaces (memory feedback "no silent
   failures"): `init-firewall.sh` resolves `github.com` through dnsmasq after
   lockdown and `WARNING`s into the container log if it fails — covering
   restarts and visible in `docker logs`. Because the container starts
   detached (`docker run -d`) so that log is not on screen during a normal
   `boxa` start, `docker-run.sh` re-probes via `docker exec` once the
   firewall is up and prints the same `WARNING` where it reaches the user's
   terminal.

### Why this preserves ADR 0009's security model

The allowlist is enforced at the **connection layer**: outbound traffic is
permitted only to IPs in the `allowed-domains` ipset (`init-firewall.sh`'s
`--match-set ... ACCEPT` followed by the catch-all REJECT), and dnsmasq is the
only thing that populates that ipset, for allowlisted domains, at lookup time.

Allowing port 53 to the single daemon-upstream IP lets a process resolve an
arbitrary name directly against that resolver — but the answer is useless: a
connection to a non-allowlisted IP is still rejected because that IP was never
added to the ipset. The DNS pin's job is **audit + harvest-pool completeness**
(ADR 0009), not connection enforcement. The hole narrows audit coverage by one
resolver IP; it does not let the container reach anywhere new.

The hole could be tightened further with `-m owner` matching on the embedded
resolver, but the owning UID is fragile across rootful/rootless/userns-remap
setups; a destination-IP match is deterministic and auditable.

## Consequences

**Positive:**

- boxa resolves on native Linux hosts with a non-loopback Docker daemon DNS
  (Omarchy and any equivalent `daemon.json` `dns` setting), while honouring the
  operator's privacy-respecting resolver choice instead of overriding it.
- Ubuntu, WSL2, and Docker Desktop are byte-for-byte unchanged (empty
  `BOXA_DNS_UPSTREAM`).
- A dead upstream now fails loud at boot instead of masquerading as success.

**Negative / limitations:**

- Detection covers daemon DNS from `daemon.json` and the inherited host
  `/etc/resolv.conf`. A daemon DNS set via the `dockerd --dns` flag or a
  systemd unit override is not parsed; `BOXA_DNS_UPSTREAM` stays empty and
  the host-visible DNS probe's `WARNING` (below) is the safety net that points
  the user at the cause.
- IPv4 only. The firewall is iptables-v4; an IPv6 daemon DNS is out of scope.
- Containers created before this change lack the bind mount. The restart path
  detects the missing mount and recreates the container once (rm + the
  existing recreate contract) so the file is provisioned; subsequent restarts
  are plain `docker start`.
- Audit/harvest coverage excludes direct queries to the one allowed upstream IP
  (see security analysis above) — accepted trade-off.

## References

- `init-firewall.sh` — DNS pin (the `--dport 53` rules), the upstream allow
  block, and the post-lockdown upstream probe.
- `docker-run.sh` — `detect_docker_dns_upstream` and the `BOXA_DNS_UPSTREAM`
  env pass-through.
- ADR 0001 — dnsmasq dynamic allowlist (ipset-at-lookup-time enforcement).
- ADR 0009 — allow-for harvest window (why DNS is pinned to dnsmasq).
