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
  or stop containers, open allow-for windows, manage the allowlist, or
  drive the host Agent-browser Chrome, ask the user to run the
  corresponding 'boxa …' command on host.
- Container network is default-deny. Only ~15 allowlisted domains
  resolve; everything else is REJECTed at the firewall. If
  curl/npm/pip/fetch (container-side traffic) fails with a connection
  error, the most likely cause is that the host is not in the
  Allowlist. Ask the user to run on host:
    boxa allow <domain>          (durable allowlist entry)
    boxa allow-for <minutes>     (time-bounded harvest window)
- Agent-browser is a SEPARATE gate. Host Chrome browses through its
  own forward proxy with its own allowlist. Browser failures like
  ERR_TUNNEL_CONNECTION_FAILED or 'proxy denied' do NOT come from the
  container firewall; 'boxa allow' / 'boxa allow-for' will NOT fix
  them. Ask the user to run on host instead:
    boxa agent-browser allow-for <minutes> ${project}
- Dev URLs bypass both gates via built-in routes. Both forms resolve
  locally: http(s)://<port>.${project}.test and
  http(s)://<port>.${project}.127.0.0.1.sslip.io

For full guidance (agent-browser, ports, host/container bridging),
invoke the 'boxa' skill.
EOF
)

jq -n \
    --arg event "$event" \
    --arg context "$context" \
    '{hookSpecificOutput: {hookEventName: $event, additionalContext: $context}}'
