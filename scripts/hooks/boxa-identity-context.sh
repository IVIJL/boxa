#!/bin/sh
# Boxa container identity context for agents (ADR 0011 Layer 3).
# Fires from Claude Code and Codex SessionStart hooks.
# Emits a JSON hook response with `additionalContext` so the host agent
# injects our identity block into the conversation. The same managed-
# settings files are bind-mounted shared, so we guard on the identity
# file's presence to keep this a deliberate no-op on host. Exiting 0
# with empty stdout on missing identity is the intended host-vs-
# container branch, not a suppressed error: both Claude Code and Codex
# treat empty stdout as "no additional context", which is exactly the
# desired host behaviour.
#
# Hook output format matches the shared Claude Code / Codex schema:
#   {"hookSpecificOutput": {"hookEventName": "...", "additionalContext": "..."}}
# `hookEventName` is read from the per-hook stdin payload Claude Code
# and Codex both feed us; we echo it back so the same script services
# both Claude Code and Codex SessionStart.
[ -f /etc/boxa/identity.json ] || exit 0

project=$(jq -r .project /etc/boxa/identity.json 2>/dev/null) || exit 0
[ -n "$project" ] && [ "$project" != "null" ] || exit 0

# Read the hook event name from stdin payload. Both Claude Code and
# Codex feed a JSON object on stdin with `hook_event_name`; we echo it
# back in the response so each agent treats the output as belonging to
# the hook it triggered. Fall back to SessionStart if stdin is empty
# or malformed (defensive; should not happen in production paths).
event=$(jq -r '.hook_event_name // empty' 2>/dev/null)
[ -n "$event" ] || event="SessionStart"

context=$(cat <<EOF
You are inside a boxa container for project "$project".

Boundaries:
- The 'boxa' CLI lives on the host, not in this container. To start
  or stop containers, open allow-for windows, manage the allowlist,
  create or remove Host connections, change the SSH gate, or drive the
  host Agent-browser Chrome, ask the user to run the corresponding
  'boxa …' command on host.
- Container network is default-deny. Only ~15 allowlisted domains
  resolve; everything else is REJECTed at the firewall. If
  curl/npm/pip/fetch (container-side traffic) fails with a connection
  error, the most likely cause is that the host is not in the
  Allowlist. Ask the user to run on host:
    boxa allow <domain>          (durable allowlist entry)
    boxa allow-for <minutes>     (time-bounded harvest window)
- Container-to-host service traffic uses a SEPARATE Host connection
  gate, not the domain Allowlist. If traffic from this container or
  inner Docker needs a service listening on the host, ask the user to
  run on host:
    boxa connect host <port> --name <label> [--all]
  Omit --all for this box; include it only to trust every present and
  future box. An Allowlist entry for host.docker.internal is ineffective.
- Agent-browser is a SEPARATE gate. Host Chrome browses through its
  own forward proxy with its own allowlist. Browser failures like
  ERR_TUNNEL_CONNECTION_FAILED or 'proxy denied' do NOT come from the
  container firewall; 'boxa allow' / 'boxa allow-for' will NOT fix
  them. Ask the user to run on host instead:
    boxa agent-browser allow-for <minutes> ${project}
- SSH agent forwarding is a SEPARATE, opt-in SSH gate. It is off by
  default and can be changed only on the host. A forwarded socket grants
  signing authority over every key in the host agent. If SSH signing is
  unavailable, ask the user to run on host:
    boxa ssh
  Then follow its state: 'boxa ssh on' enables the current Project and
  'boxa ssh add' opens the consent-first Key picker. Gate changes take
  effect only when the Container is created; network access to the SSH
  host remains a separate Allowlist or Host connection decision.
- MCP servers are host-gated per Project. If an expected MCP tool
  (e.g. mcp__boxa-codex-delegate for Codex delegation) is missing from
  this session, the server is not exposed here. Ask the user to run on
  host:
    boxa mcp status --project <path>
  and follow what it reports — typically 'boxa mcp readiness <entry>'
  (e.g. a missing 'codex login') or:
    boxa mcp activate <entry> --project <path> --for claude
  (use '--for codex' for a Codex session; the codex-delegate entry is
  Claude-only. A new activation appears only in a NEW agent session.)
- Dev URLs (*.test and *.127.0.0.1.sslip.io) reach this and other live
  boxes through Traefik, bypassing the container and Agent-browser gates.
  Explicit :<port> forms do not work inside containers; use
  localhost:<port> for this box or boxa-<name>:<port> for another box.

For full guidance (SSH, agent-browser, ports, host/container bridging),
invoke the 'boxa' skill.
EOF
)

jq -n \
    --arg event "$event" \
    --arg context "$context" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
