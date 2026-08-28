# 03 — `boxa blocked` stops listing dev URLs

Status: done

## Parent

ADR 0036 (proposed), section 6 of `../NOTES.md`. None of the mount work
blocks this — the bug predates it.

## What to build

`boxa blocked` currently treats every logged dnsmasq query without an
`ipset=` line as blocked. Dev URLs (`localhost`, `*.test`,
`*.127.0.0.1.sslip.io`) are routed by `address=` lines in the same dnsmasq
config, so they show up as "blocked" and get offered for `boxa allow` even
though they are routing, not firewall denials.

Extend the blocked-set definition to also exclude queries covered by the
`address=` lines read from the same dnsmasq config the handler already opens.
No hardcoded suffix list: whatever the firewall routes as a dev URL is
automatically excluded, and anything it stops routing reappears.

## Acceptance criteria

- [x] Queries for `*.test`, `*.127.0.0.1.sslip.io` and `localhost` no longer
      appear in `boxa blocked` output on a Container that has made such
      queries. Proven via `tests/blocked.sh` ("dnsmasq ipset and address rules
      exclude covered queries") against synthetic dnsmasq config + query
      fixtures, since `blocked_domains_from_dnsmasq()` was extracted into a
      pure, Docker-free function. Live verification on a real running
      Container is deferred (host-only step, not available in this session).
- [x] A genuinely blocked domain (no `ipset=`, no `address=` coverage) still
      appears and is still offered for `boxa allow`. Proven by the same test
      plus `tests/blocked.sh` ("an arbitrary runtime address suffix excludes
      its subdomains" / "removing an address rule makes its query blocked
      again", which also cover unrelated non-covered domains staying
      blocked).
- [x] The exclusion is derived from `address=` config at query time, not from
      a literal suffix list in the handler. Proven by
      `tests/blocked.sh` ("removing an address rule makes its query blocked
      again"): removing an `address=` line from the fixture config makes the
      corresponding domain reappear as blocked, and the handler
      (`blocked_domains_from_dnsmasq` in `docker-run.sh`) contains no
      hardcoded suffix list — confirmed by inspection of the diff.
- [x] Existing test suites pass; shellcheck clean on touched scripts. All 34
      `tests/*.sh` suites pass (exit 0 each, including the new
      `tests/blocked.sh`); `shellcheck -S style` clean on `docker-run.sh` and
      `tests/blocked.sh`. Python `pytest` suite was not independently
      re-verified in this session (pytest not installed in this container);
      unaffected by this change (no Python files touched).

## Blocked by

None — can start immediately.

## Comments

Round-1 review found two gaps, fixed in a follow-up commit:
- `localhost` has no `address=` rule in production (`init-firewall.sh` only
  emits `address=/test/…` and `address=/127.0.0.1.sslip.io/…`); it is
  answered locally via dnsmasq's built-in/`/etc/hosts` single-label
  handling. `blocked_domains_from_dnsmasq()` now excludes any domain with no
  `.` in it structurally, instead of relying on a fabricated
  `address=/localhost/…` test fixture.
- The `boxa blocked` handler previously pooled queried domains from all
  running Containers and filtered them against only the first Container's
  dnsmasq runtime rules. It now fetches and filters each Container's
  queries against that same Container's own rules, then unions the
  per-Container blocked sets.

Round-2 review found the dot-less exclusion above was itself wrong: the
dnsmasq config has no `domain-needed` (and can't get one — it would break
`boxa-<name>` resolution via Docker's embedded DNS), so single-label queries
are genuinely forwarded upstream and can be real denials (e.g. an
unallowlisted `boxa-<name>`). The true reason `localhost` never appears is
that the config also has no `no-hosts`, so dnsmasq answers any name present
in `/etc/hosts` locally without forwarding. `blocked_domains_from_dnsmasq()`
now takes the querying Container's own `/etc/hosts` names as a third
argument (fetched per-Container, like the dnsmasq rules) and excludes only
those, so other single-label denials reappear in `boxa blocked`.

Round-3 review flagged aliases on IPv6-only `/etc/hosts` lines (e.g.
`ip6-allnodes`): the claim was that dnsmasq forwards A queries for names that
have no IPv4 hosts entry, making them possible real denials. Initially
rejected as a false positive, but a deeper experiment confirmed it: the
original `aa`-flag "authoritative, no forwarding" evidence came from an
environment where the query could also be answered by an upstream chain, so
it didn't isolate dnsmasq's own hosts-file behaviour. Re-run with the
upstream forced unreachable, `dig A ip6-allnodes @127.0.0.1` REFUSED (dnsmasq
attempted to forward it — no IPv4 hosts entry to answer locally), while
`dig AAAA ip6-allnodes @127.0.0.1` and `dig A localhost @127.0.0.1` both
still answered authoritatively from `/etc/hosts`. dnsmasq's hosts-file
answers are per address family, so an `A` query for an IPv6-only hosts name
(or an `AAAA` query for an IPv4-only name) is not answered locally and must
not be blanket-excluded. `blocked_domains_from_dnsmasq()` now takes the
query's type (`A`/`AAAA`, parsed from the query log) and each `/etc/hosts`
entry's own address family, and excludes a query only when they match.
