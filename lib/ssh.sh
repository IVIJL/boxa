# shellcheck shell=bash
# =============================================================================
# Boxa SSH gate
# =============================================================================
# Strictly parses ~/.config/boxa/ssh.conf and resolves whether the host SSH
# agent socket is forwarded for one absolute host project path (ADR 0026).
# The config is deliberately never sourced.
# =============================================================================

_BOXA_SSH_GATE=off

# Resolve the SSH gate for one project. A valid project value overrides a
# valid global value; missing or invalid values leave the secure default off.
_boxa::resolve_ssh_gate() {
    local project_path="$1"
    local conf="${BOXA_SSH_CONF:-$HOME/.config/boxa/ssh.conf}"
    local line key value section="" global_value="" project_value=""

    _BOXA_SSH_GATE=off
    [ -f "$conf" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue

        if [[ "$line" == \[*\] ]]; then
            value="${line:1:${#line}-2}"
            if [[ "$value" == /* ]]; then
                section="$value"
            else
                section="INVALID"
            fi
            continue
        fi

        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" = "$line" ] && continue
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        [ "$key" = agent ] || continue
        case "$value" in on|off) ;; *) continue ;; esac

        if [ -z "$section" ]; then
            global_value="$value"
        elif [ "$section" = "$project_path" ]; then
            project_value="$value"
        fi
    done < "$conf"

    if [ -n "$project_value" ]; then
        _BOXA_SSH_GATE="$project_value"
    elif [ -n "$global_value" ]; then
        _BOXA_SSH_GATE="$global_value"
    fi
}
