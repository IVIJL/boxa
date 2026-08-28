# mcp-remote-auth — raw notes for /to-issues

Goal: remote-http MCP catalog entries need authenticated access (HTTP
headers, typically `Authorization: Bearer <token>`) without the token ever
reaching the agent, shared files, or git.

## Motivating case (live, 2026-08-21)

User's colleague added a Bearer token to the dozzle MCP
(`https://dozzle.gaiagroup.cz/api/mcp`). The user already imported dozzle
into the catalog WITHOUT the token (import is definition-only; `headers`
is not modeled, so it was dropped). Once the server enforces auth, every
box session gets 401 with no supported way to fix it.

## Verified current state (commit 374dd25)

- The catalog has NO `headers` support at all (`grep headers scripts/mcp/`
  → only table-rendering hits). ADR 0029 does not address auth.
- Catalog is secret-free by design; URL validation actively REJECTS URLs
  with embedded secrets (`scripts/mcp/catalog.py:176-274`).
- Existing secret machinery: `secretEnvKeys` on entries, values in the
  host secret store, broker stages them per spawn into the isolated
  service container — works for service-isolated (stdio/node) entries
  only. ISOLATION column: those are `isolated`; the agent never sees the
  secret.
- remote-http entries are `ISOLATION: not-applicable`: no boxa-run
  process; the Claude client inside the box opens the HTTPS connection
  itself. Naively putting the header into the launch profile would hand
  the token to the agent.
- Launch wrappers use `--strict-mcp-config --mcp-config=<inline JSON>`
  (ADR 0028), so manual workarounds inside boxes are ignored; host
  `~/.claude.json` is NOT mounted into boxes (only the `~/.claude` DIR is,
  shared RW across all boxes — never park a token in
  `/home/node/.claude/.claude.json`, it propagates everywhere).

## Proposed design (discussed with user, approved direction)

Broker/proxy-side header injection, mirroring the isolation philosophy:

1. Catalog entry (remote-http) declares header NAME(s) + a secret store
   key (e.g. `secretHeaders: {"Authorization": "<secretStoreKey>"}`), no
   values in the catalog. `boxa mcp add`/`update`/`import` accept and
   round-trip this shape; import discovery may DETECT a header on an
   inherited server but must import only the name, prompting for the
   value like other secrets (never copying it silently from
   ~/.claude.json).
2. Secret value lives in the host MCP secret store (same store as
   secretEnvKeys values); `boxa mcp reload` semantics apply.
3. At runtime the agent does NOT get the real URL+token. Instead the
   launch profile points the client at a local endpoint (broker-owned
   forward proxy inside the box or on devproxy, whichever fits the
   existing broker architecture) which injects the header(s) and forwards
   to the real URL over HTTPS. Token stays out of agent reach; ISOLATION
   for such entries becomes meaningful again instead of not-applicable.
4. Entries WITHOUT secretHeaders keep today's direct-URL behavior.
5. `boxa mcp status`/`readiness` should surface "auth header configured /
   secret value missing" so a 401 is diagnosable (Next: hint to set the
   secret).
6. Allowlist note: the real host (e.g. dozzle.gaiagroup.cz) must still be
   reachable per the existing remote-entry Allowlist hint; the proxy does
   not bypass the firewall gate.

Open design points for the issues pass: exact proxy placement (per-box
broker vs devproxy sidecar), TLS handling (client→proxy plaintext on
localhost vs re-encrypt), secret store key naming, migration of existing
remote entries (dozzle) via `boxa mcp update`.

## Constraints (house rules)

- UI strings and comments English. Shellcheck-clean (incl. info-level).
- Catalog stays secret-free; nothing secret in git or shared mounts.
- Tests per slice; suite currently 593 green (`python3 -m unittest
  discover -s tests -q`), `tests/picker.sh` green.
- Related: ADR 0028 (launch-time injection), ADR 0029 (remote entries),
  `.scratch/mcp-ux-polish/` (previous batch, commit 374dd25).
