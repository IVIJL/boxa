#!/bin/bash
set -euo pipefail
# Idempotent host-side staging for the agent-browser Python helpers (ADR 0010).
#
# The proxy daemon and summary generator run as the `boxa-agent` OS user
# (ADR 0010 § Actor 1, Actor 3). On hosts where the developer's $HOME is
# 0700/0750, boxa-agent cannot traverse into the repo checkout to exec
# scripts under `$BOXA_DIR/scripts/`. The broker therefore expects these
# helpers at a root-owned, world-traversable location:
#
#   /usr/local/lib/boxa/agent-browser/
#       agent-browser-proxy.py
#       agent-browser-summarize.py
#
# Re-runs are no-ops when both files already match the in-tree sources.
# Called from install.sh during fresh install (sole creator path) and from
# `boxa update` as a self-heal for existing installs that predate this
# staging requirement.

STAGE_DIR="/usr/local/lib/boxa/agent-browser"
# install.sh and docker-run.sh both invoke this script with an absolute
# path, so a plain dirname is reliable. `readlink -f` is GNU-only and
# breaks on macOS/BSD where readlink lacks -f.
BOXA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_PROXY="$BOXA_DIR/scripts/agent-browser-proxy.py"
SRC_SUMMARIZE="$BOXA_DIR/scripts/agent-browser-summarize.py"

QUIET_IF_NOOP=false
for arg in "$@"; do
    case "$arg" in
        --quiet-if-noop) QUIET_IF_NOOP=true ;;
        -h|--help)
            cat <<EOF
Usage: ensure-agent-browser-helpers.sh [--quiet-if-noop]

Stages the agent-browser Python helpers to $STAGE_DIR so the boxa-agent
OS user can exec them regardless of \$HOME perms.

Options:
  --quiet-if-noop   Suppress output when nothing needed to be done.
EOF
            exit 0 ;;
        *)
            echo "ensure-agent-browser-helpers.sh: unknown arg '$arg'" >&2
            exit 2 ;;
    esac
done

log() { $QUIET_IF_NOOP || printf '%s\n' "$*"; }
loud() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

if [ ! -r "$SRC_PROXY" ] || [ ! -r "$SRC_SUMMARIZE" ]; then
    warn "Agent-browser helper sources missing in checkout ($BOXA_DIR/scripts/); cannot stage."
    exit 1
fi

actions=0

# Directory: root:root 0755 so boxa-agent can traverse + read but not write.
if [ ! -d "$STAGE_DIR" ]; then
    sudo install -d -m 0755 -o 0 -g 0 "$STAGE_DIR"
    loud "Created $STAGE_DIR (root:root 0755)"
    actions=$((actions + 1))
fi

# Compare-and-copy. `cmp -s` is a no-op probe; if the staged file already
# matches, skip the sudo install (avoids unnecessary inode churn + sudo
# prompt). Staged files are mode 0755 root:root world-readable, so the
# comparison itself doesn't need sudo — keeping the no-op path
# prompt-free for `boxa update`.
stage_one() {
    local src="$1" name="$2"
    local dst="$STAGE_DIR/$name"
    if [ -r "$dst" ] && cmp -s "$src" "$dst"; then
        return 0
    fi
    sudo install -m 0755 -o 0 -g 0 "$src" "$dst"
    loud "Staged $name -> $dst"
    actions=$((actions + 1))
}

stage_one "$SRC_PROXY" "agent-browser-proxy.py"
stage_one "$SRC_SUMMARIZE" "agent-browser-summarize.py"

if [ "$actions" -eq 0 ]; then
    log "Agent-browser helpers already staged at $STAGE_DIR (no changes)."
fi
