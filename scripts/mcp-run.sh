#!/bin/bash
set -euo pipefail

# =============================================================================
# boxa-mcp-run — Container MCP launcher wrapper (ADR 0013, issue 07)
# =============================================================================
# Rendered Claude Code / Codex MCP entries do NOT call the raw MCP command. They
# call this wrapper, e.g. `boxa-mcp-run context7` (global) or
# `boxa-mcp-run --project <full-project-key> context7` (Project-scoped). The
# wrapper is the stable control point boxa keeps over MCP startup (ADR 0013
# decision 27): it checks Container identity, resolves the server from boxa's
# canonical MCP profile, validates required env without logging secret values,
# and execs the configured command so the MCP server inherits this process's
# stdio.
#
# This is a thin shell front-end: all logic (identity gate, profile resolution,
# env validation, exec) lives in the unit-tested Python core (`mcp.runner`,
# `mcp.cli run`). The wrapper only locates that core and forwards its args.
#
# The Python package ships into the image at a fixed share dir so this wrapper
# resolves `import mcp` regardless of CWD (the agent launches it from anywhere).
# A repo-checkout fallback keeps it runnable from a source tree during dev/test.
#
# Container-only: if the Container identity file is absent (we are on the host),
# the Python core fails clearly and launches nothing. The agent config trees are
# bind-mounted into the container AND visible on the host, so this host guard is
# load-bearing, not cosmetic.
# =============================================================================

# Preferred in-image location of the Python MCP package's parent dir.
_MCP_SHARE_DIR="/usr/local/share/boxa"

if [ -d "$_MCP_SHARE_DIR/mcp" ]; then
    MCP_PY_DIR="$_MCP_SHARE_DIR"
else
    # Dev/test fallback: run from a repo checkout (scripts/mcp/ alongside us).
    MCP_PY_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
fi

PYTHONPATH="$MCP_PY_DIR${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m mcp.cli run "$@"
