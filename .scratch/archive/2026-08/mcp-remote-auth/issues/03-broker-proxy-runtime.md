# 03 — Broker proxy runtime + launch profile rewiring

Status: done
Priority: P1
Type: AFK

## Parent

.scratch/mcp-remote-auth/KICKOFF-NOTES.md + docs/adr/0030.

## What to build

The in-box broker (ADR 0014 `boxa-mcp` process) gains a loopback-only
HTTP listener. For each activated remote entry with non-empty
`secretHeaderKeys`, the launch profile hands the agent a
`http://127.0.0.1:<port>/...` endpoint instead of the real URL; the
broker reads the staged secret value per request, adds the secret
header(s) plus any non-secret `headers`, and forwards to the upstream
pinned to the entry's catalog URL (scheme+host+port+path — the proxy is
NOT a general forwarder, ADR 0030 decision 4). Upstream connections are
HTTPS with normal verification against the combined system CA bundle.
Entries without secret headers keep the direct URL, with non-secret
`headers` passed inline in the launch config. Broker unavailability makes
only proxied entries fail, with a diagnosable error.

## Acceptance criteria

- [x] End-to-end: an activated remote entry with a secret header works
      against an auth-requiring upstream, covered via a local HTTPS stub
      server in `tests/test_mcp_http_proxy.py`. Live verification in a
      real fresh agent session (real box, real Claude/Codex client)
      NOT done — deferred to the user.
- [x] The token never appears in the agent-visible launch config,
      process env, argv, or any file the agent user can read (proxy
      reads staged secrets per request; launch profile only emits the
      loopback URL).
- [x] The listener binds 127.0.0.1 only; requests cannot reach any
      upstream other than the pinned catalog URL (test: attempted
      host/path override is refused) — covered in
      `tests/test_mcp_http_proxy.py`.
- [x] Direct-URL behavior of non-secret remote entries is unchanged
      (regression test), including inline non-secret headers — covered
      in `tests/test_mcp_launch_profile.py`.
- [x] Egress goes through the box firewall as normal (no new allowlist
      machinery); the unchanged Allowlist requirement is documented in
      the entry's readiness hint (`scripts/mcp/readiness.py`).
- [x] English UI strings; unittest suite green (608 passed); shellcheck
      clean for the touched shell script (`scripts/mcp-broker.sh`).

## Implementation notes

- Implemented by Codex delegation, commit ed05e52.
- New module `scripts/mcp/http_proxy.py`: loopback-only proxy started
  alongside the Unix broker in `scripts/mcp/broker.py`; listens on
  `127.0.0.1:8765`, route `/mcp/<catalog-entry-UUID>`, re-reads staged
  secrets and activation state per request.
- `scripts/mcp/launch_profile.py` rewires secret-header entries to the
  proxy URL (both Claude and Codex launch profiles); non-secret
  `headers` on direct entries are passed inline as before.
- Deferred / not done in this session: live end-to-end check from a
  real box against a real auth-requiring remote MCP server (e.g.
  dozzle with the colleague's Bearer token) — to be done by the user
  when convenient.

## Blocked by

- 01-catalog-headers-model.md (done, 8553423)
- 02-secret-header-values-store.md (done, bdf306a)
