#!/bin/bash
set -euo pipefail

# Re-assert Container-visible Claude state before an agent starts.
_MCP_SHARE_DIR="/usr/local/share/boxa"

if [ -d "$_MCP_SHARE_DIR/mcp" ]; then
    MCP_PY_DIR="$_MCP_SHARE_DIR"
else
    # Dev/test fallback: run from a repo checkout (scripts/mcp/ alongside us).
    MCP_PY_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
fi

PYTHONPATH="$MCP_PY_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    exec python3 -m mcp.cli converge "$@"
