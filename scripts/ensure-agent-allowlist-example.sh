#!/bin/bash
set -euo pipefail
# Idempotent host-side write of the agent-browser allowlist EXAMPLE file
# (ADR 0010, ADR 0017 § 2 category A).
#
# Ships a documented `.example` template of the agent-browser default-mode
# allowlist under ~/.config/boxa so the user has something to copy when
# they enable the feature. We NEVER touch the real
# `agent-browser-allowed-domains.conf` — the user's edits are sacred; only
# the `.example` sibling is managed here.
#
# Called from install.sh during fresh install and, via lib/provisioning.sh,
# from `boxa doctor` / the `boxa update` self-heal chain for existing
# installs. Mirrors the shape of ensure-boxa-skill.sh /
# ensure-allow-for-host-state.sh.
#
# Exits 0 when the example file is present with the expected content
# (whether it was already there or freshly written). Exits non-zero only on
# a real write failure.

QUIET_IF_NOOP=false
for arg in "$@"; do
    case "$arg" in
        --quiet-if-noop) QUIET_IF_NOOP=true ;;
        -h|--help)
            cat <<'EOF'
Usage: ensure-agent-allowlist-example.sh [--quiet-if-noop]

Writes the agent-browser allowlist example file to
~/.config/boxa/agent-browser-allowed-domains.conf.example. Idempotent:
re-runs are no-ops when the file already matches. Never touches the real
allowlist file.

Options:
  --quiet-if-noop   Suppress output when nothing needed to be done.
EOF
            exit 0 ;;
        *)
            echo "ensure-agent-allowlist-example.sh: unknown arg '$arg'" >&2
            exit 2 ;;
    esac
done

log() { $QUIET_IF_NOOP || printf '%s\n' "$*"; }
loud() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/boxa"
EXAMPLE="$CFG_DIR/agent-browser-allowed-domains.conf.example"

# Canonical example content. Kept in lockstep with install.sh's prior inline
# heredoc so install-time and registry-driven paths write byte-identical
# files.
read -r -d '' EXAMPLE_CONTENT <<'EOF' || true
# boxa agent-browser default-mode allowlist
# One domain pattern per line. `#` lines are comments.
# Glob `*.example.com` matches all subdomains.
#
# Examples:
# *.github.com
# api.openai.com
# registry.npmjs.org
EOF

# Idempotent: skip the write when the file already matches byte-for-byte.
# Rewrite in place (no unlink-then-recreate) to keep the destination inode
# stable, consistent with feedback_bindmount_inode.
if [ -f "$EXAMPLE" ] && [ "$(cat "$EXAMPLE")" = "$EXAMPLE_CONTENT" ]; then
    log "Agent-browser allowlist example already present at $EXAMPLE (no changes)."
    exit 0
fi

if ! mkdir -p "$CFG_DIR"; then
    warn "Failed to create $CFG_DIR — cannot write agent-browser allowlist example."
    exit 1
fi

if ! printf '%s\n' "$EXAMPLE_CONTENT" > "$EXAMPLE"; then
    warn "Failed to write $EXAMPLE."
    exit 1
fi

loud "Wrote agent-browser allowlist example to $EXAMPLE"
