#!/bin/bash
set -euo pipefail
# Idempotent host-side state for `boxa allow-for` (ADR 0009).
#
# Provisions five pieces of state that live outside Docker and therefore
# survive container teardown:
#   1. /var/log/boxa/allow-for/ as root:root 0755 — the harvest log
#      directory. Mounted read-write into every container so the in-container
#      root daemon can write reports; the node user (host UID 1000) can read
#      but cannot delete or overwrite, which is the tamper-proof guarantee
#      ADR 0009 §3-4 hangs the security argument on.
#   2. /var/log/boxa/allow-for/pending/ as <host-uid>:<host-gid> 0755 —
#      the pending notification subdir (ADR 0009 Phase 3). Files inside
#      are still written by container root as root:root 0644, but the
#      directory's write bit is delegated so the host-side deliver script
#      can `mv pending pending.lock` for atomic claim semantics. Tamper-
#      proof guarantee on log FILES is unchanged (root-owned 0644 — no
#      content tampering); only the pending-signal subdirectory becomes
#      host-user-writable.
#   3. /var/log/boxa/allow-for/.tmp/ as root:root 0700 — scratch dir
#      for the teardown daemon's atomic pending publish (mktemp here,
#      atomic-rename into pending/). Must live inside the same bind
#      mount as pending/ so rename(2) doesn't return EXDEV, but the
#      mode 0700 + root parent denies the in-container node user any
#      visibility — closing the TOCTOU race a user-writable tempdir
#      would otherwise allow.
#   4. /var/log/boxa/oom/ as <host-uid>:<host-gid> 0755 — durable OOM
#      archive + last-seen kernel timestamp. The host-side detached sweep
#      writes here without sudo on ordinary boxa invocations.
#   5. (WSL2 only) HKCU\Software\Classes\AppUserModelId\Boxa.AllowFor —
#      the toast notification AppId so the inline-COM PowerShell toast at
#      window close can launch File Explorer at the harvest log via WSL
#      UNC path. Missing AppId would degrade to a generic toast without
#      click-to-open; the log file is still written either way.
#
# Called from install.sh during fresh install (sole creator path) and from
# `boxa update` as a self-heal for existing installs that predate ADR 0009.
# Each step is independent: a missing powershell.exe on a non-Windows
# distro under WSL2 (rare but possible) degrades to a warning, not an
# overall failure — the log file remains the canonical record.
#
# Exits 0 when all required directories end in their desired state ("created" or "already
# present"). Exits non-zero only when a directory step actually failed,
# since that breaks the feature; HKCU failure is informational.

ALLOW_FOR_LOG_DIR="/var/log/boxa/allow-for"
# Pending notification subdir (ADR 0009 Phase 3). Host-user-owned so the
# host-side deliver script can rename-claim files; the parent stays
# root:root 0755 for the tamper-proof harvest-log guarantee. Capture
# UID/GID before any sudo invocation so `install -o`/`-g` get the real
# user's numbers, not 0:0.
ALLOW_FOR_PENDING_DIR="$ALLOW_FOR_LOG_DIR/pending"
# Root-only scratch dir for the teardown daemon's atomic pending publish
# (sibling of pending/, but in the root-owned parent so the in-container
# node user can't relocate or peek into it). See lib/allow-for.sh for
# the full threat-model reasoning.
ALLOW_FOR_TMP_DIR="$ALLOW_FOR_LOG_DIR/.tmp"
OOM_ARCHIVE_DIR="/var/log/boxa/oom"
HOST_UID=$(id -u)
HOST_GID=$(id -g)
WSL_APP_ID="Boxa.AllowFor"

# --- Argument parsing --------------------------------------------------------
# `--quiet-if-noop` suppresses the per-step "already correct, skipping"
# stderr lines. install.sh calls without it (user expects a status report
# during a fresh install); the `boxa update` self-heal passes it so the
# common steady-state run is silent and only a real fix-up makes noise.
QUIET_IF_NOOP=false
for arg in "$@"; do
    case "$arg" in
        --quiet-if-noop) QUIET_IF_NOOP=true ;;
        --help|-h)
            cat <<'USAGE'
Usage: ensure-allow-for-host-state.sh [--quiet-if-noop]

Idempotently provision the host-side state `boxa allow-for` needs:
  - /var/log/boxa/allow-for/         owned root:root 0755
  - /var/log/boxa/allow-for/pending/ owned <host-uid>:<host-gid> 0755
  - /var/log/boxa/allow-for/.tmp/    owned root:root 0700
  - /var/log/boxa/oom/               owned <host-uid>:<host-gid> 0755
  - (WSL2 only) HKCU\...\AppUserModelId\Boxa.AllowFor toast AppId

Options:
  --quiet-if-noop   Stay silent when every piece of state is already in
                    the desired shape. Created / repaired / failed steps
                    still print. Intended for the `boxa update` self-heal.
USAGE
            exit 0
            ;;
        *)
            printf '\033[1;31m==> ERROR: Unknown argument: %s\033[0m\n' "$arg" >&2
            exit 2
            ;;
    esac
done

# Diagnostics on stderr, free for callers (install.sh, docker-run.sh) to
# either suppress or forward. Stdout is unused so callers parsing rc alone
# never see noise.
CYAN='\033[1;36m'; YELLOW='\033[1;33m'; GREEN='\033[1;32m'; NC='\033[0m'
_info() { printf "${CYAN}==> %s${NC}\n" "$*" >&2; }
_ok()   { printf "${GREEN}==> %s${NC}\n" "$*" >&2; }
_warn() { printf "${YELLOW}==> WARN: %s${NC}\n" "$*" >&2; }
_msg()  { printf '  %s\n' "$*" >&2; }
_noop_msg() {
    $QUIET_IF_NOOP && return 0
    printf '  %s\n' "$*" >&2
}

is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }

# Portable `stat` probe — emits `uid:gid:octal-mode` on stdout. GNU
# coreutils (Linux) uses `-c '%u:%g:%a'`; BSD `stat` on macOS uses
# `-f '%u:%g:%Lp'`. Try GNU first because it's the common host; fall
# back to BSD silently. Numeric uid/gid sidesteps the Linux-vs-macOS
# root-group name split (root vs wheel) — we compare against the
# numeric `0:0:755` invariant directly.
_stat_owner_mode() {
    local path="$1"
    stat -c '%u:%g:%a' "$path" 2>/dev/null \
        || stat -f '%u:%g:%Lp' "$path" 2>/dev/null
}

# --- Step 1: harvest log directory ------------------------------------------
# `sudo install -d` is naturally idempotent: creates if missing, resets
# perms when present. We probe with stat first to avoid an unnecessary sudo
# prompt — the `boxa update` self-heal calls into this script on every
# run, so the fast-path matters.
#
# Numeric `-o 0 -g 0` instead of `-o root -g root` because BSD `install`
# on macOS rejects the latter: root's primary group on macOS is `wheel`,
# not `root`, and the group lookup fails before any work happens. UID/GID 0
# is universal across both platforms.
ensure_log_dir() {
    if [ -d "$ALLOW_FOR_LOG_DIR" ]; then
        local stat_out
        stat_out="$(_stat_owner_mode "$ALLOW_FOR_LOG_DIR" || true)"
        if [ "$stat_out" = "0:0:755" ]; then
            _noop_msg "$ALLOW_FOR_LOG_DIR already root:root 0755 — skipping."
            return 0
        fi
    fi

    _info "Creating $ALLOW_FOR_LOG_DIR (root:root 0755) — sudo may prompt."
    if ! sudo install -d -o 0 -g 0 -m 0755 "$ALLOW_FOR_LOG_DIR"; then
        _warn "Failed to create $ALLOW_FOR_LOG_DIR — 'boxa allow-for' will not work until this is fixed."
        return 1
    fi
    _ok "$ALLOW_FOR_LOG_DIR ready."
}

# --- Step 1b: pending notification subdir ------------------------------------
# Sibling of the harvest log dir, but owned by the host user so the deliver
# script's atomic rename-claim (`mv pending pending.lock`) can succeed —
# rename(2) needs write on the parent directory, which a normal user lacks
# on the root-owned ALLOW_FOR_LOG_DIR. Files INSIDE this dir are still
# written as root:root by the in-container teardown daemon; only the
# directory's write bit is delegated.
ensure_pending_dir() {
    local want="${HOST_UID}:${HOST_GID}:755"
    if [ -d "$ALLOW_FOR_PENDING_DIR" ]; then
        local stat_out
        stat_out="$(_stat_owner_mode "$ALLOW_FOR_PENDING_DIR" || true)"
        if [ "$stat_out" = "$want" ]; then
            _noop_msg "$ALLOW_FOR_PENDING_DIR already ${HOST_UID}:${HOST_GID} 0755 — skipping."
            return 0
        fi
    fi

    _info "Creating $ALLOW_FOR_PENDING_DIR (${HOST_UID}:${HOST_GID} 0755) — sudo may prompt."
    if ! sudo install -d -o "$HOST_UID" -g "$HOST_GID" -m 0755 "$ALLOW_FOR_PENDING_DIR"; then
        _warn "Failed to create $ALLOW_FOR_PENDING_DIR — 'boxa allow-for' notifications will not deliver until this is fixed."
        return 1
    fi
    _ok "$ALLOW_FOR_PENDING_DIR ready."
}

# --- Step 1c: root-only tmp subdir for atomic pending publish ---------------
# Used by the in-container teardown daemon (root) to mktemp + write pending
# JSON, then atomic-rename into the user-writable pending dir. Sibling of
# pending/ on the same filesystem (same bind mount) so rename(2) works
# without EXDEV. Mode 0700 root:root denies the in-container node user
# both write (no symlink planting) and read (no enumeration of in-flight
# tempfile names).
ensure_tmp_dir() {
    local want="0:0:700"
    if [ -d "$ALLOW_FOR_TMP_DIR" ]; then
        local stat_out
        stat_out="$(_stat_owner_mode "$ALLOW_FOR_TMP_DIR" || true)"
        if [ "$stat_out" = "$want" ]; then
            _noop_msg "$ALLOW_FOR_TMP_DIR already root:root 0700 — skipping."
            return 0
        fi
    fi

    _info "Creating $ALLOW_FOR_TMP_DIR (root:root 0700) — sudo may prompt."
    if ! sudo install -d -o 0 -g 0 -m 0700 "$ALLOW_FOR_TMP_DIR"; then
        _warn "Failed to create $ALLOW_FOR_TMP_DIR — 'boxa allow-for' notifications will not deliver until this is fixed (TOCTOU-safe publish requires this dir)."
        return 1
    fi
    _ok "$ALLOW_FOR_TMP_DIR ready."
}

# --- Step 1d: host-user-owned OOM archive -----------------------------------
# The OOM sweep is launched detached on ordinary, non-sudo boxa invocations.
# Delegate only this archive directory; /var/log/boxa and the allow-for
# forensics remain under their existing ownership boundaries.
ensure_oom_archive_dir() {
    local want="${HOST_UID}:${HOST_GID}:755"
    if [ -d "$OOM_ARCHIVE_DIR" ]; then
        local stat_out
        stat_out="$(_stat_owner_mode "$OOM_ARCHIVE_DIR" || true)"
        if [ "$stat_out" = "$want" ]; then
            _noop_msg "$OOM_ARCHIVE_DIR already ${HOST_UID}:${HOST_GID} 0755 — skipping."
            return 0
        fi
    fi

    _info "Creating $OOM_ARCHIVE_DIR (${HOST_UID}:${HOST_GID} 0755) — sudo may prompt."
    if ! sudo install -d -o "$HOST_UID" -g "$HOST_GID" -m 0755 "$OOM_ARCHIVE_DIR"; then
        _warn "Failed to create $OOM_ARCHIVE_DIR — boxa OOM events cannot be archived until this is fixed."
        return 1
    fi
    _ok "$OOM_ARCHIVE_DIR ready."
}

# --- Step 2: WSL2 HKCU toast AppId ------------------------------------------
# HKCU writes never elevate, so this is a plain powershell.exe call (no
# Start-Process -Verb RunAs). The script is doubly idempotent: outer
# Test-Path skips the New-Item / Set-ItemProperty when the key already
# exists, and the final Test-Path returns the rc so a partial write
# (e.g. registry permission glitch) surfaces as a non-zero exit.
ensure_wsl_app_id() {
    is_wsl2 || return 0
    if ! command -v powershell.exe >/dev/null 2>&1; then
        _warn "powershell.exe not in PATH — cannot register $WSL_APP_ID toast AppId. Click-to-open notifications will fall back to silent close (log file is still written)."
        return 0
    fi

    # Distinct exit codes let bash differentiate no-op (key already
    # present) from a fresh create — only the create gets a visible "==>"
    # banner, so the steady-state self-heal stays silent under
    # --quiet-if-noop. Exit 1 covers a write that succeeded partially but
    # left Test-Path returning false; bash treats it as a soft failure.
    local ps_cmd
    ps_cmd="\$RegPath = 'HKCU:\\Software\\Classes\\AppUserModelId\\${WSL_APP_ID}'; if (Test-Path \$RegPath) { exit 0 }; New-Item -Path \$RegPath -Force | Out-Null; Set-ItemProperty -Path \$RegPath -Name DisplayName -Value 'Boxa'; if (Test-Path \$RegPath) { exit 10 } else { exit 1 }"
    local rc=0
    powershell.exe -NoProfile -Command "$ps_cmd" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0)
            _noop_msg "Windows toast AppId $WSL_APP_ID already registered — skipping."
            ;;
        10)
            _ok "Registered Windows toast AppId $WSL_APP_ID."
            ;;
        *)
            _warn "Failed to register Windows toast AppId $WSL_APP_ID (powershell rc=$rc) — 'boxa allow-for' will fall back to silent close (log file is still written)."
            ;;
    esac
}

ensure_log_dir
ensure_pending_dir
ensure_tmp_dir
ensure_oom_archive_dir
ensure_wsl_app_id
