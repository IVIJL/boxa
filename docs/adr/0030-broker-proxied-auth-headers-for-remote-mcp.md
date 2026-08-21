# ADR 0030 — Broker-proxied auth headers for remote MCP entries

- **Status:** accepted
- **Date:** 2026-08-21
- **Extends:** ADR 0029 (remote catalog entries), ADR 0014 (broker
  credential isolation), ADR 0028 (launch-time injection)

## Context

Remote (http) catalog entries carry only a URL. Real hosted connectors
(the Dozzle server from ADR 0029's motivating case) are moving behind
bearer-token auth, and the catalog has no way to express an
`Authorization` header. Naively adding headers to the launch profile
would hand the token to the agent: for remote entries the agent's own
client opens the HTTPS connection, so anything in its config is
agent-readable. That breaks the secret-isolation line the broker
established for service-isolated servers (agent never sees another
process's secrets), and a token parked in any shared file (`~/.claude`
mount, project `.mcp.json`) leaks across Projects or into git.

## Decision

1. **Catalog shape mirrors the env split.** A remote entry may declare
   `headers` (non-secret name→value map, stored in the catalog) and
   `secretHeaderKeys` (a list of header NAMES whose values live in the
   host MCP secret store, keyed by entry + header name — no separate
   store-key field). Validation rejects overlap between the two, and
   rejects non-secret `headers` whose name or value trips the existing
   secret heuristics (the same guard the entry URL already has). The
   catalog stays secret-free.
2. **Per-box broker proxy, only when secrets are involved.** An entry
   with a non-empty `secretHeaderKeys` is routed through the in-box
   broker (the ADR 0014 `boxa-mcp` process): the launch profile gives the
   agent a loopback HTTP endpoint instead of the real URL; the broker
   reads the staged secret per request, adds the header(s), and forwards
   upstream. Entries without secret headers keep today's direct URL
   (non-secret `headers` ride along in the launch profile config).
3. **TLS model.** Client→broker is plaintext HTTP bound exclusively to
   the container loopback (never `0.0.0.0`); no token flows on that leg.
   Broker→upstream is HTTPS with normal certificate verification against
   the combined system CA bundle. No re-encryption on loopback.
4. **Pinned upstream — the proxy is not a forwarder.** The proxy forwards
   only to the scheme+host+port+path of the entry's catalog URL. The
   agent cannot redirect the token to another destination; changing the
   destination means changing the catalog entry, which is host-gated.
5. **Firewall semantics unchanged.** The broker shares the box's network
   namespace, so its egress passes the same default-deny Allowlist and
   DNS filter as agent traffic. The upstream host must be allowlisted
   exactly as for a direct remote entry. (This is also why a devproxy
   sidecar was rejected: it would concentrate every Project's tokens in
   one shared container AND let remote-MCP traffic bypass the box's own
   firewall by egressing from devproxy.)

## Security boundary

Consumer scoping between agents that run as the same `node` UID in one
Container is not an OS-enforceable security boundary. Claude and Codex launch
profiles are rendered inside the Container by same-UID wrappers; any malicious
`node` process can request either consumer's route, invoke either renderer, or
read another same-UID process's rendered configuration. `SO_PEERCRED` can
authenticate the UID but cannot identify which agent program or session owns
the connection.

Route capabilities therefore prevent accidental or guessed cross-consumer
access; they do not protect against a malicious process running under the
shared `node` UID. The broker checks peer credentials so only `node` can mint a
route, excluding its `boxa-mcp`-owned service processes, but all `node`
processes remain equivalently trusted. The Container itself is the security
boundary for agent-visible route capabilities; consumer selection within that
boundary is policy scoping, not process isolation.

## Consequences

- The broker gains an HTTP listener capability (today it only relays
  stdio); loopback-only, one pinned upstream per proxied entry.
- Readiness/status can report "auth header declared / secret value
  missing" for proxied entries, and ISOLATION becomes meaningful for
  them (proxied) instead of `not-applicable`.
- Import discovery may detect headers on inherited servers but imports
  names only and prompts for values — never silently copying a token out
  of `~/.claude.json`. (Refined by ADR 0031: the prompt may offer to
  move the value into the secret store, per-value and consent-first.)
- A stopped broker means a proxied entry is unavailable; direct-URL
  entries are unaffected.
