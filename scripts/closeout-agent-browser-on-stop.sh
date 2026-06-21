#!/bin/bash
set -euo pipefail

# =============================================================================
# closeout-agent-browser-on-stop — tear down an Agent-browser session on
#                                  `boxa stop` (host side)
# =============================================================================
# Invoked from the `boxa stop` pipeline (graceful_stop_container in
# docker-run.sh) BEFORE the actual `docker stop`, so the in-container socat
# bridge is still reachable when the broker's stop path needs to signal it via
# `docker exec`.
#
# Structurally analogous to closeout-allow-for-on-restart.sh, but triggered on
# a different lifecycle event: that script runs at container boot to harvest a
# leftover allow-for window; this script runs at container stop to terminate
# a live Agent-browser session (host Chrome + in-container bridge), per
# ADR 0010 § Session lifecycle.
#
# Behaviour:
#   - No session-state JSON at
#     ${XDG_STATE_HOME:-$HOME/.local/state}/boxa/agent-browser/sessions/<container>.json
#     → exit 0 silently. `boxa stop` against a container without an active
#     session must be a no-op for the agent-browser side (no extra stdout).
#   - State present → delegate to `agent-browser-broker.sh stop <container>`.
#     The broker owns Chrome kill, host-relay kill, in-container bridge kill,
#     state-file removal, and (when later slices land) netlog archival /
#     profile cleanup / summary emission. This script never duplicates that
#     logic — single source of truth for session teardown.
#
# Best-effort: a failed broker stop must not block `docker stop`. The caller
# treats this script's exit code as advisory; we still propagate it so manual
# invocations get a useful signal.
# =============================================================================

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
    printf 'Usage: %s <container>\n' "$(basename "$0")" >&2
    exit 2
fi

CONTAINER="$1"

BOXA_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

SESSIONS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/boxa/agent-browser/sessions"
STATE_FILE="${SESSIONS_DIR}/${CONTAINER}.json"

if [ ! -f "$STATE_FILE" ]; then
    exit 0
fi

BROKER="${BOXA_DIR}/scripts/agent-browser-broker.sh"
if [ ! -x "$BROKER" ]; then
    printf 'closeout-agent-browser-on-stop: broker not found or not executable: %s\n' \
        "$BROKER" >&2
    exit 1
fi

exec "$BROKER" stop "$CONTAINER"
