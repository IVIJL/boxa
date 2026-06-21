#!/bin/bash
set -euo pipefail

# =============================================================================
# boxa-mcp-broker — always-on Container MCP broker launcher (ADR 0014, issue 15)
# =============================================================================
# Started from the entrypoint ROOT phase as the dedicated unprivileged
# `boxa-mcp` account (via `setpriv --reuid boxa-mcp --regid boxa-mcp
# --init-groups`), BEFORE the drop of PID 1 to `node`. The broker listens on a
# unix socket; the `boxa-mcp-run` relay (run as `node`) connects to it, names
# the server it wants, and the broker spawns that MCP server as `boxa-mcp` so
# the agent never sees the server's environment (credential isolation — see
# ADR 0014). The broker ALWAYS runs, even with an empty/missing profile.
#
# This is a thin shell front-end: all socket/stdio/spawn logic lives in the
# unit-tested Python core (`mcp.broker`). The wrapper only locates that core and
# launches it. Mirrors mcp-run.sh's package-resolution so it runs from any CWD.
# =============================================================================

# Preferred in-image location of the Python MCP package's parent dir.
_MCP_SHARE_DIR="/usr/local/share/boxa"

if [ -d "$_MCP_SHARE_DIR/mcp" ]; then
    MCP_PY_DIR="$_MCP_SHARE_DIR"
else
    # Dev/test fallback: run from a repo checkout (scripts/mcp/ alongside us).
    MCP_PY_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
fi

PYTHONPATH="$MCP_PY_DIR${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m mcp.broker "$@"
