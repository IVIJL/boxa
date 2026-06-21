#!/bin/bash
set -euo pipefail

# =============================================================================
# stage-mcp-secrets — root-side MCP secret staging (ADR 0014, issue 16)
# =============================================================================
# The single, reusable staging step shared by the entrypoint ROOT phase and
# issue 17's `boxa mcp reload` (which re-invokes it via `docker exec -u 0`).
#
# Must run as ROOT: only root can read the host 0600 secret files through the
# gated read-only mount, and only root can chown the staged copies to the
# `boxa-mcp` service account. It copies the IN-SCOPE secret stores (global +
# THIS Container's Project — never another Project's) out of the read-only host
# MCP mount into the `boxa-mcp`-private staged dir, as 0400 files owned by
# `boxa-mcp` that `node` cannot read (wrong UID + 0700 parent dir). The broker
# re-reads them per spawn and injects each server's secrets as environment.
#
# ADR 0003: this runs in the entrypoint's existing root phase BEFORE the drop to
# node (no setuid, no NOPASSWD, no persistent root). SECRET-SAFE: the Python
# core reports scope labels + file basenames + counts only, never a secret value
# or an env-key name.
#
# Thin front-end: all copy/scope/permission logic lives in the unit-tested
# Python core (`mcp.cli stage-secrets` -> `mcp.staging`). The project basename
# (sanitize + hash) is derived in Python so it matches the broker exactly; it is
# never reinvented in shell. This wrapper only resolves paths and the package.
# =============================================================================

# Gated read-only mount of the host MCP store (profile + secret files). The
# entrypoint root phase mounts host ~/.config/boxa/mcp here under a
# boxa-mcp-only parent chain (0700 boxa-mcp); node cannot traverse it.
SOURCE_DIR="${BOXA_MCP_HOST_STORE:-/run/boxa-mcp/host/boxa/mcp}"

# boxa-mcp-private staged store the broker reads secret VALUES from (created
# 0700 boxa-mcp by the entrypoint). Matches DEFAULT_SECRETS_DIR in mcp.broker.
DEST_DIR="${BOXA_MCP_SECRETS_DIR:-/run/boxa-mcp/secrets}"

# Owner of the staged files. boxa-mcp by default; overridable for tests only.
STAGE_OWNER="${BOXA_MCP_STAGE_OWNER:-boxa-mcp}"

# This Container's Project — the FULL host-path key, the same value the
# entrypoint writes into /etc/boxa/identity.json (projectKey) and exports as
# BOXA_PROJECT_HOST_PATH. Empty for a non-project Container: only global
# secrets are then staged. Project scope is least-privilege (ADR 0014): a
# Project A Container never stages Project B's secrets.
PROJECT_KEY="${BOXA_PROJECT_HOST_PATH:-}"

# Allow callers (issue 17 reload) to override the defaults explicitly.
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE_DIR="$2"; shift 2 ;;
        --dest) DEST_DIR="$2"; shift 2 ;;
        --project) PROJECT_KEY="$2"; shift 2 ;;
        --owner) STAGE_OWNER="$2"; shift 2 ;;
        *)
            echo "stage-mcp-secrets: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

# Preferred in-image location of the Python MCP package's parent dir.
_MCP_SHARE_DIR="/usr/local/share/boxa"

if [ -d "$_MCP_SHARE_DIR/mcp" ]; then
    MCP_PY_DIR="$_MCP_SHARE_DIR"
else
    # Dev/test fallback: run from a repo checkout (scripts/mcp/ alongside us).
    MCP_PY_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
fi

cli_args=(stage-secrets --source "$SOURCE_DIR" --dest "$DEST_DIR" --owner "$STAGE_OWNER")
if [ -n "$PROJECT_KEY" ]; then
    cli_args+=(--project "$PROJECT_KEY")
fi

PYTHONPATH="$MCP_PY_DIR${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m mcp.cli "${cli_args[@]}"
