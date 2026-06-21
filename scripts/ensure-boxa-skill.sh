#!/usr/bin/env bash
set -euo pipefail
# Idempotent host-side seed/refresh of the `boxa` agent skill (ADR 0011 § Layer 2).
#
# Source of truth lives at <boxa-repo>/skills/boxa/SKILL.md. This
# script copies it to ~/.agents/skills/boxa/SKILL.md on the host and
# creates per-agent symlinks at ~/.claude/skills/boxa and
# ~/.codex/skills/boxa so Claude Code, Codex, and any other
# agentskills.io-compatible agent see the same content. All three trees
# are bind-mounted into boxa Containers (ADR 0002), so the skill
# reaches Containers automatically without per-Container provisioning.
#
# Called from install.sh during fresh install and from the
# `boxa update` self-heal chain in docker-run.sh for existing installs.
# Mirrors the shape of ensure-agent-browser-host-state.sh and
# ensure-agent-browser-helpers.sh.

BOXA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QUIET_IF_NOOP=false

for arg in "$@"; do
    case "$arg" in
        --quiet-if-noop) QUIET_IF_NOOP=true ;;
        -h|--help)
            cat <<EOF
Usage: ensure-boxa-skill.sh [--quiet-if-noop]

Seeds the user-level 'boxa' agent skill from the boxa repo into
~/.agents/skills/boxa/ and creates per-agent symlinks for Claude Code
and Codex. Idempotent: re-runs are no-ops when content already matches.

Options:
  --quiet-if-noop   Suppress output when nothing needed to be done.
EOF
            exit 0 ;;
        *)
            echo "ensure-boxa-skill.sh: unknown arg '$arg'" >&2
            exit 2 ;;
    esac
done

log() { $QUIET_IF_NOOP || printf '%s\n' "$*"; }
loud() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

SRC="$BOXA_DIR/skills/boxa/SKILL.md"
DEST_DIR="$HOME/.agents/skills/boxa"
DEST="$DEST_DIR/SKILL.md"
LINK_TARGET="../../.agents/skills/boxa"

if [ ! -r "$SRC" ]; then
    warn "Boxa skill source missing in checkout ($SRC); cannot stage."
    exit 1
fi

WARNINGS=()
actions=0

mkdir -p "$DEST_DIR"

# Content-aware sync. cmp -s returns non-zero when files differ OR when
# $DEST is absent; either case means we copy. cp overwrites in place
# rather than unlink-then-recreate so the destination inode is stable
# (consistent with feedback_bindmount_inode, even though $HOME is not
# itself bind-mounted — keeping the habit avoids future regressions if
# the layout ever changes).
if ! cmp -s "$SRC" "$DEST" 2>/dev/null; then
    cp "$SRC" "$DEST"
    loud "Updated $DEST"
    actions=$((actions + 1))
fi

# Per-agent symlinks. Relative target so the link survives a $HOME
# rename or a different mount point for the home directory.
for agent_dir in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
    mkdir -p "$agent_dir"
    link="$agent_dir/boxa"

    if [ -L "$link" ]; then
        current="$(readlink "$link")"
        if [ "$current" = "$LINK_TARGET" ]; then
            continue
        fi
        # Existing symlink points elsewhere — could be a user's own
        # boxa skill or a stale link to a previous layout. Do not
        # clobber. Surface via the WARNINGS collector so the install
        # summary highlights it.
        WARNINGS+=("$link is a symlink to '$current' (not our target); leaving it alone")
        continue
    fi

    if [ -e "$link" ]; then
        # Regular file or directory at that path — almost certainly the
        # user's own custom 'boxa' skill. Never overwrite user content.
        WARNINGS+=("$link exists and is not a symlink; leaving it alone (user's own 'boxa' skill?)")
        continue
    fi

    ln -s "$LINK_TARGET" "$link"
    loud "Linked $link -> $LINK_TARGET"
    actions=$((actions + 1))
done

if [ "$actions" -eq 0 ] && [ "${#WARNINGS[@]}" -eq 0 ]; then
    log "Boxa skill already seeded at $DEST_DIR (no changes)."
fi

if [ "${#WARNINGS[@]}" -gt 0 ]; then
    warn "Boxa skill install completed with warnings:"
    for w in "${WARNINGS[@]}"; do
        warn "  - $w"
    done
fi
