# 01 — In-box dev URL DNS resolves to Traefik

Status: done

## Parent

None — box-to-box visibility is not yet covered by an ADR (a new ADR is
written in issue 04). Related context: ADR 0007 (local DNS with external
fallback), ADR 0024 (probe-driven DNS degradation).

## What to build

Today, `<port>.<name>.test` and `<port>.<name>.127.0.0.1.sslip.io` inside a
boxa Container resolve to the Container's **own loopback** (the query falls
through Docker embedded DNS to the host resolver, which answers 127.0.0.1).
An agent curling another box's dev URL silently hits its own services — worse
than an error. Meanwhile all boxes and `boxa_traefik` share the `devproxy`
network, the in-container firewall already ACCEPTs the whole bridge subnet
both ways, and Traefik already routes the dual `Host()` rules to
`http://boxa-<name>:<port>` — so cross-box delivery works; only DNS lies.

Change the in-box dnsmasq configuration so both dev URL suffixes resolve to
the `boxa_traefik` container IP:

- Add `address=/test/<traefik-IP>` and
  `address=/127.0.0.1.sslip.io/<traefik-IP>` to the in-box dnsmasq config
  generated during firewall init.
- Resolve the `boxa_traefik` IP via Docker embedded DNS **before** the DNS
  lockdown closes the 127.0.0.11 bypass (same window the GitHub IP fetch
  uses).
- Graceful degradation: if `boxa_traefik` does not resolve at init time,
  omit the `address=` lines and keep today's behaviour (do not fail the
  firewall init).
- The firewall reload path must refresh the Traefik IP so a recreated
  Traefik (new IP) does not leave running boxes with a stale answer.

Constraints — do not weaken the exfiltration guards:

- No new iptables rules and no ipset changes; traffic to Traefik is already
  covered by the bridge-subnet ACCEPT.
- The `address=` lines answer locally, so `.test` queries stop leaking
  upstream entirely — that direction must be preserved.
- Note (document in code comment): a user-allowlisted `.test` domain would
  be shadowed by the `address=` wildcard; `.test` is a reserved TLD, this
  is acceptable.

Known behaviour change to accept: the loopback-with-explicit-port form
(`<port>.<own>.test:<port>`) stops working inside the box, because Traefik
listens only on 80/443. The canonical `boxa ports` URLs carry no explicit
port; own services remain reachable via `localhost:<port>`.

## Acceptance criteria

- [ ] Inside a box, `getent hosts <port>.<other>.test` returns the
      `boxa_traefik` IP, not 127.0.0.1 (same for the sslip.io form).
      Deferred host verification — needs a live container recreate;
      only unit-tested statically here.
- [ ] `curl http://<port>.<other>.test` from box A reaches the service
      running in live box B (HTTP-mode Traefik; on an HTTPS host the :80
      redirect answer counts — TLS trust is issue 02).
      Deferred host verification — needs two live boxes.
- [ ] A dev URL of a stopped box returns a Traefik 404/502, not a
      connection to the local box.
      Deferred host verification — needs a live container recreate.
- [x] Firewall init succeeds unchanged when `boxa_traefik` is not running,
      falling back to today's resolution (graceful degradation covered by
      `tests/firewall-dev-url-dns.sh`; the Traefik lookup runs before the
      OUTPUT DROP policy and the catch-all REJECT, verified by line-order
      assertions in the same test).
- [x] Firewall reload picks up a changed Traefik IP (covered by
      `tests/firewall-dev-url-dns.sh`, which asserts the address= lines
      are refreshed and stale lines are dropped when Traefik disappears).
- [x] Allowlist/ipset behaviour and the 127.0.0.11 DNS-bypass guard are
      untouched — no new iptables/ipset rules were added; the reload path
      reuses the existing dnsmasq-uid-owner exception for 127.0.0.11
      rather than opening a new one.

## Blocked by

None — can start immediately.

## Comments
