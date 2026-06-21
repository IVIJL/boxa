#!/bin/bash
set -euo pipefail
# Idempotent host-side state for `boxa agent-browser` group provisioning (ADR 0010).
#
# Called from install.sh during fresh install (alongside user creation)
# and from `boxa update` as a self-heal for existing installs that
# predate group provisioning — notably macOS installs where the previous
# sysadminctl path left the user in primary group `staff` and never
# created a matching `boxa-agent` group.
#
# Linux/WSL2: `useradd --user-group` always co-creates the matching group
# at user-creation time, so this script's only useful action there is
# adding the invoking user to the group.
#
# macOS: pre-existing boxa-agent users from older installs have no
# matching group and primary group `staff`. Without a self-heal,
# `chown boxa-agent:` on archive files resolves to `staff`, which
# everyone on macOS is in — defeating the ADR 0010 tamper-proof
# property that the user-group-membership read path provides.

BOXA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QUIET_IF_NOOP=false

for arg in "$@"; do
    case "$arg" in
        --quiet-if-noop) QUIET_IF_NOOP=true ;;
        -h|--help)
            cat <<EOF
Usage: ensure-agent-browser-host-state.sh [--quiet-if-noop]

Self-heals boxa-agent group provisioning and developer group
membership for the agent-browser feature.

Options:
  --quiet-if-noop   Suppress output when nothing needed to be done.
EOF
            exit 0 ;;
        *)
            echo "ensure-agent-browser-host-state.sh: unknown arg '$arg'" >&2
            exit 2 ;;
    esac
done

log() { $QUIET_IF_NOOP || printf '%s\n' "$*"; }
loud() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# shellcheck source=../lib/host-platform.sh disable=SC1091
. "$BOXA_DIR/lib/host-platform.sh"

# host_platform::ensure_agent_mkcert_trust below uses _mkcert::caroot
# from lib/mkcert.sh to locate the developer's CAROOT before importing
# into the boxa-agent NSS DB. Source it explicitly so the trust seed
# step is self-contained from the caller's perspective.
# shellcheck source=../lib/mkcert.sh disable=SC1091
. "$BOXA_DIR/lib/mkcert.sh"

platform="$(host_platform::detect)" || { warn "unknown platform"; exit 1; }

actions=0

# Active migration for break-fix: when an existing install pulled the
# agent-browser feature but never ran `bash install.sh`, the boxa-agent
# OS user is missing entirely. Without this branch, `boxa update`
# self-heal would silently skip user provisioning and the next
# `boxa agent-browser start` would fail with "user does not exist".
# Per the feedback_active_migration_for_breakfix rule, break-fix lives
# in `boxa update`, not in warn-only output.
if ! id boxa-agent >/dev/null 2>&1; then
    loud "Creating boxa-agent OS user (sudo may prompt)..."
    if ! host_platform::ensure_agent_user; then
        warn "Failed to create boxa-agent user. Run 'bash install.sh' for full setup with diagnostics."
        exit 1
    fi
    loud "Created boxa-agent user"
    actions=$((actions + 1))
fi

# macOS self-heal: group existence + primary group binding on the user.
if [ "$platform" = "macos" ]; then
    if ! dseditgroup -o read boxa-agent >/dev/null 2>&1; then
        if ! sudo dseditgroup -o create boxa-agent; then
            warn "Failed to create boxa-agent group on macOS."
            exit 1
        fi
        loud "Created boxa-agent group"
        actions=$((actions + 1))
    fi

    local_pgid="$(dscl . -read /Users/boxa-agent PrimaryGroupID 2>/dev/null \
        | awk '/PrimaryGroupID:/ {print $2}')"
    target_pgid="$(dscl . -read /Groups/boxa-agent PrimaryGroupID 2>/dev/null \
        | awk '/PrimaryGroupID:/ {print $2}')"
    primary_group_changed=false
    if [ -n "$local_pgid" ] && [ -n "$target_pgid" ] && [ "$local_pgid" != "$target_pgid" ]; then
        if ! sudo dscl . -create /Users/boxa-agent PrimaryGroupID "$target_pgid"; then
            warn "Failed to set boxa-agent primary group to boxa-agent ($target_pgid)."
            exit 1
        fi
        loud "Set boxa-agent primary group to boxa-agent ($target_pgid)"
        actions=$((actions + 1))
        primary_group_changed=true
    fi

    # Re-chown any pre-existing archive dir whose group is still `staff`
    # from before the primary-group migration. `chown boxa-agent:` on a
    # macOS install with the old primary group would have created files
    # in `staff`, leaving them accessible to every macOS user. After the
    # primary group fix above, all NEW files land in `boxa-agent` —
    # but existing ones need a one-shot recursive repair.
    if [ "$primary_group_changed" = true ] && [ -d /var/log/boxa/agent-browser ]; then
        if ! sudo chown -R boxa-agent: /var/log/boxa/agent-browser; then
            warn "Failed to re-chown existing /var/log/boxa/agent-browser to boxa-agent's primary group."
        else
            loud "Re-chowned existing /var/log/boxa/agent-browser to boxa-agent:boxa-agent"
            actions=$((actions + 1))
        fi
    fi
fi

# Universal: invoking user in boxa-agent group.
invoker="${USER:-$(id -un)}"
if ! id -nG "$invoker" 2>/dev/null | tr ' ' '\n' | grep -qx boxa-agent; then
    if host_platform::ensure_agent_user_in_group "$invoker"; then
        loud "Added $invoker to boxa-agent group (re-login or 'newgrp boxa-agent' to apply)"
        actions=$((actions + 1))
    else
        warn "Failed to add $invoker to boxa-agent group."
        exit 1
    fi
fi

# mkcert root-CA trust for boxa-agent. Idempotent: re-imports only
# when fingerprint differs (fresh install or CA rotation). Per
# feedback_active_migration_for_breakfix this lives inside the update
# self-heal path, not warn-only output, because HTTPS-trust drift is
# silent until the user hits an HTTPS URL in the agent Chrome.
#
# Output contract: stdout is non-empty iff a state change happened
# (Imported / Refreshed). Soft-fail diagnostics (missing certutil,
# missing rootCA) print on stderr and fall through to the terminal —
# the developer self-remediates. Hard-fail (return 1) only on broken
# install state (missing user, sudo refused, openssl/sha256 broken).
if trust_msg="$(host_platform::ensure_agent_mkcert_trust)"; then
    if [ -n "$trust_msg" ]; then
        loud "$trust_msg"
        actions=$((actions + 1))
    fi
else
    warn "Agent-browser mkcert trust seed failed (HTTPS dev URLs will show cert warnings in agent Chrome)."
fi

if [ "$actions" -eq 0 ]; then
    log "Agent-browser host state already provisioned (no changes)."
fi
