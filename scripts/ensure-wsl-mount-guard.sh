#!/bin/bash
set -euo pipefail
# Idempotent WSL2 drvfs mount guard for agent-browser isolation.
#
# WSL2's drvfs automounts (/mnt/c, /mnt/d, ...) default to world-readable
# permissions. That defeats the `boxa-agent` OS-user boundary because the
# Host agent Chrome user can read the developer's Windows profile through
# /mnt/c/Users/<user> unless the automount mask is hardened.
#
# This provisioner only mutates /etc/wsl.conf when the live drvfs mounts are
# currently open and the existing automount config has no user-managed masks.
# Existing umask/fmask/dmask choices are never overwritten: a user-managed
# mask that still leaves /mnt open is reported as a FAILURE (exit 1) so
# install / `boxa update` / `boxa doctor` surface the unresolved hole instead
# of counting the step as configured.

QUIET_IF_NOOP=false
WSL_CONF="${BOXA_WSL_CONF:-/etc/wsl.conf}"

for arg in "$@"; do
    case "$arg" in
        --quiet-if-noop) QUIET_IF_NOOP=true ;;
        -h|--help)
            cat <<'USAGE'
Usage: ensure-wsl-mount-guard.sh [--quiet-if-noop]

Hardens WSL2 drvfs automounts for boxa agent-browser isolation by ensuring
/etc/wsl.conf has:

  [automount]
  options = "umask=077"

Options:
  --quiet-if-noop   Stay silent when no change or warning is needed.
USAGE
            exit 0
            ;;
        *)
            printf '\033[1;31m==> ERROR: Unknown argument: %s\033[0m\n' "$arg" >&2
            exit 2
            ;;
    esac
done

CYAN='\033[1;36m'; YELLOW='\033[1;33m'; GREEN='\033[1;32m'; NC='\033[0m'
_info() { printf "${CYAN}==> %s${NC}\n" "$*" >&2; }
_warn() { printf "${YELLOW}==> WARN: %s${NC}\n" "$*" >&2; }
_msg()  { printf '  %s\n' "$*" >&2; }
_noop_msg() {
    $QUIET_IF_NOOP && return 0
    printf '  %s\n' "$*" >&2
}
# Repair report goes to STDOUT: the category-A provisioning runner treats any
# stdout under --quiet-if-noop as "this step repaired something" (see
# _boxa::run_step_a in lib/provisioning.sh), so the hardening notice must not
# hide on stderr or `boxa doctor` would classify a real repair as already-OK.
_report()     { printf "${GREEN}==> %s${NC}\n" "$*"; }
_report_msg() { printf '  %s\n' "$*"; }

is_wsl2() {
    case "${BOXA_WSL_FORCE_PLATFORM:-}" in
        wsl2) return 0 ;;
        other) return 1 ;;
        "") ;;
        *)
            _warn "Ignoring unknown BOXA_WSL_FORCE_PLATFORM=${BOXA_WSL_FORCE_PLATFORM}; expected wsl2 or other."
            ;;
    esac

    [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] \
        || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null
}

# Reduce a raw ini value to its core: unquote a leading quoted segment, or
# cut an unquoted value at an inline comment (# or ;). `"metadata" # keep`
# must yield `metadata`, not leak the comment into token parsing.
strip_value() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    case "$value" in
        \"*) value="${value#\"}"; value="${value%%\"*}" ;;
        \'*) value="${value#\'}"; value="${value%%\'*}" ;;
        *)
            value="${value%%[#;]*}"
            value="${value%"${value##*[![:space:]]}"}"
            ;;
    esac
    printf '%s' "$value"
}

read_automount_key() {
    local key="$1"
    [ -f "$WSL_CONF" ] || return 1
    awk -v want="$key" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        BEGIN { section = "" }
        /^[[:space:]]*[#;]/ { next }
        /^[[:space:]]*\[/ {
            section = tolower($0)
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\][[:space:]]*$/, "", section)
            next
        }
        section == "automount" {
            line = $0
            if (line !~ /^[[:space:]]*[^=]+[[:space:]]*=/) {
                next
            }
            name = tolower(line)
            sub(/=.*/, "", name)
            name = trim(name)
            if (name == want) {
                sub(/^[^=]*=/, "", line)
                print trim(line)
                found = 1
                exit
            }
        }
        END { if (!found) exit 1 }
    ' "$WSL_CONF"
}

automount_root() {
    local root
    root="$(read_automount_key root 2>/dev/null || true)"
    if [ -n "$root" ]; then
        strip_value "$root"
    else
        printf '/mnt'
    fi
}

discover_drvfs_dirs() {
    if [ -n "${BOXA_WSL_DRVFS_DIRS:-}" ]; then
        # shellcheck disable=SC2086 # intentional word splitting: seam is a space-separated dir list.
        printf '%s\n' $BOXA_WSL_DRVFS_DIRS
        return 0
    fi

    local root dir base
    root="$(automount_root)"
    [ -d "$root" ] || return 0
    for dir in "$root"/*; do
        [ -d "$dir" ] || continue
        base="$(basename "$dir")"
        case "$base" in
            [abcdefghijklmnopqrstuvwxyz])
                mountpoint -q "$dir" && printf '%s\n' "$dir"
                ;;
        esac
    done
}

dir_is_open() {
    local dir="$1" mode group_digit other_digit
    mode="$(stat -c '%a' "$dir" 2>/dev/null || true)"
    [ -n "$mode" ] || return 1
    other_digit="${mode: -1}"
    group_digit="${mode: -2:1}"
    [ "$group_digit" != "0" ] || [ "$other_digit" != "0" ]
}

options_contains_token() {
    local options="$1" pattern="$2"
    local token
    IFS=',' read -r -a tokens <<< "$options"
    for token in "${tokens[@]}"; do
        token="${token#"${token%%[![:space:]]*}"}"
        token="${token%"${token##*[![:space:]]}"}"
        [[ "${token,,}" =~ $pattern ]] && return 0
    done
    return 1
}

# True when the automount options guarantee group/other-closed drvfs mounts:
# umask=077 is present AND every explicit fmask=/dmask= (which override the
# umask for files/dirs on drvfs) also clears all group/other bits (octal
# value ending in 77). `umask=077,dmask=000` must NOT pass — the explicit
# dmask would reopen directories after the restart.
options_hardened() {
    local options="$1" token key value has_umask=false
    IFS=',' read -r -a tokens <<< "$options"
    for token in "${tokens[@]}"; do
        token="${token#"${token%%[![:space:]]*}"}"
        token="${token%"${token##*[![:space:]]}"}"
        token="${token,,}"
        case "$token" in
            umask=*|fmask=*|dmask=*)
                key="${token%%=*}"
                value="${token#*=}"
                [[ "$value" =~ ^[0-7]*77$ ]] || return 1
                [ "$key" = "umask" ] && has_umask=true
                ;;
        esac
    done
    $has_umask
}

automount_has_section() {
    [ -f "$WSL_CONF" ] || return 1
    awk '
        /^[[:space:]]*[#;]/ { next }
        /^[[:space:]]*\[/ {
            section = tolower($0)
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\][[:space:]]*$/, "", section)
            if (section == "automount") found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$WSL_CONF"
}

write_new_conf() {
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/boxa-wsl-conf.XXXXXX")"
    trap 'rm -f "$tmp"' RETURN

    if [ ! -f "$WSL_CONF" ]; then
        printf '[automount]\noptions = "umask=077"\n' > "$tmp"
    elif ! automount_has_section; then
        cp "$WSL_CONF" "$tmp"
        printf '\n[automount]\noptions = "umask=077"\n' >> "$tmp"
    else
        awk '
            function trim(s) {
                sub(/^[[:space:]]+/, "", s)
                sub(/[[:space:]]+$/, "", s)
                return s
            }
            # Split a raw value into CORE (the value itself, unquoted) and
            # SUFFIX (a preserved trailing inline comment). A leading quoted
            # segment ends at its closing quote; an unquoted value ends at
            # the first # or ; comment marker.
            function split_value(s,   t, q, rest, h) {
                t = trim(s); CORE = t; SUFFIX = ""
                q = substr(t, 1, 1)
                if (q == "\"" || q == "\047") {
                    rest = substr(t, 2)
                    h = index(rest, q)
                    if (h > 0) {
                        CORE = substr(rest, 1, h - 1)
                        SUFFIX = substr(rest, h + 1)
                    } else {
                        CORE = rest
                    }
                } else {
                    h = match(t, /[#;]/)
                    if (h > 0) {
                        SUFFIX = " " substr(t, h)
                        CORE = trim(substr(t, 1, h - 1))
                    }
                }
            }
            function section_name(line) {
                line = tolower(line)
                sub(/^[[:space:]]*\[/, "", line)
                sub(/\][[:space:]]*$/, "", line)
                return line
            }
            function emit_options() {
                print "options = \"umask=077\""
                inserted = 1
            }
            /^[[:space:]]*\[/ {
                if (section == "automount" && !seen_options && !inserted) {
                    emit_options()
                }
                section = section_name($0)
                print
                next
            }
            section == "automount" && $0 !~ /^[[:space:]]*[#;]/ && $0 ~ /^[[:space:]]*[^=]+[[:space:]]*=/ {
                line = $0
                name = tolower(line)
                sub(/=.*/, "", name)
                name = trim(name)
                if (name == "options") {
                    value = line
                    sub(/^[^=]*=/, "", value)
                    split_value(value)
                    merged = (CORE == "") ? "umask=077" : CORE ",umask=077"
                    print "options = \"" merged "\"" SUFFIX
                    seen_options = 1
                    next
                }
            }
            { print }
            END {
                if (section == "automount" && !seen_options && !inserted) {
                    emit_options()
                }
            }
        ' "$WSL_CONF" > "$tmp"
    fi

    if { [ -f "$WSL_CONF" ] && [ -w "$WSL_CONF" ]; } \
        || { [ ! -e "$WSL_CONF" ] && [ -w "$(dirname "$WSL_CONF")" ]; }; then
        if ! cp "$tmp" "$WSL_CONF"; then
            _warn "Failed to write $WSL_CONF."
            return 1
        fi
    else
        _info "Writing $WSL_CONF — sudo may prompt."
        if ! sudo cp "$tmp" "$WSL_CONF"; then
            _warn "Failed to write $WSL_CONF with sudo."
            return 1
        fi
    fi
}

if ! is_wsl2; then
    _noop_msg "Not WSL2, skipping WSL /mnt umask guard."
    exit 0
fi

mapfile -t drvfs_dirs < <(discover_drvfs_dirs)
open_dirs=()
for dir in "${drvfs_dirs[@]}"; do
    if dir_is_open "$dir"; then
        open_dirs+=("$dir")
    fi
done

if [ "${#open_dirs[@]}" -eq 0 ]; then
    _noop_msg "WSL drvfs automounts already hardened, skipping."
    exit 0
fi

raw_options="$(read_automount_key options 2>/dev/null || true)"
options="$(strip_value "$raw_options")"

if [ -n "$options" ] && options_hardened "$options"; then
    _warn "WSL drvfs mounts are still readable by other Linux users, but $WSL_CONF already contains automount umask=077."
    _msg "Run 'wsl.exe --shutdown' from Windows PowerShell/CMD, then reopen this distro so /mnt drive permissions are remounted."
    exit 0
fi

if [ -n "$options" ] && {
    options_contains_token "$options" '^umask=' \
        || options_contains_token "$options" '^fmask=' \
        || options_contains_token "$options" '^dmask=';
}; then
    _warn "Current WSL automount masks leave /mnt world-readable to other OS users, defeating boxa-agent isolation."
    _msg "Manual fix required: edit $WSL_CONF and set automount options to include umask=077, then run 'wsl.exe --shutdown' from Windows."
    # User-managed masks are never overwritten, but the hole is still open —
    # exit non-zero so install/update/doctor report the step as unresolved
    # instead of silently counting it as configured.
    exit 1
fi

if ! write_new_conf; then
    exit 1
fi

_report "Hardened $WSL_CONF with automount umask=077."
_report_msg "Current /mnt drive mounts remain readable by other users, including boxa-agent, until WSL restarts."
_report_msg "Run 'wsl.exe --shutdown' from Windows PowerShell/CMD, then reopen the distro."
_report_msg "This also restarts Docker Desktop containers."
