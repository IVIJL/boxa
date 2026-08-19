# shellcheck shell=bash
# =============================================================================
# Boxa SSH gate
# =============================================================================
# Strictly parses ~/.config/boxa/ssh.conf and resolves whether the host SSH
# agent socket is forwarded for one absolute host project path (ADR 0026).
# The config is deliberately never sourced.
# =============================================================================

_BOXA_SSH_GATE=off
_BOXA_SSH_SOURCE=default

# Resolve the SSH gate for one project. A valid project value overrides a
# valid global value; missing or invalid values leave the secure default off.
_boxa::resolve_ssh_gate() {
    local project_path="$1"
    local conf="${BOXA_SSH_CONF:-$HOME/.config/boxa/ssh.conf}"
    local line key value section="" global_value="" project_value=""

    _BOXA_SSH_GATE=off
    _BOXA_SSH_SOURCE=default
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
        _BOXA_SSH_SOURCE=project
    elif [ -n "$global_value" ]; then
        _BOXA_SSH_GATE="$global_value"
        _BOXA_SSH_SOURCE=global
    fi
}

# Replace the SSH agent gate value in one scope without sourcing or
# normalising the config. Existing unrelated bytes pass through unchanged.
# Usage: _boxa::write_ssh_conf <global|project> <path> <on|off>
_boxa::write_ssh_conf() {
    local scope="$1" project_path="$2" agent_value="$3"
    local conf="${BOXA_SSH_CONF:-$HOME/.config/boxa/ssh.conf}"
    local conf_dir temp stripped line parsed value section="" target_seen=''
    local output_started='' file_had_newline=''

    case "$agent_value" in
        on|off) ;;
        *)
            printf 'Invalid SSH gate value: %s (expected on or off)\n' "$agent_value" >&2
            return 1
            ;;
    esac
    case "$scope" in
        global) ;;
        project)
            if [[ "$project_path" != /* ]]; then
                printf 'SSH gate requires an absolute host project path: %s\n' "$project_path" >&2
                return 1
            fi
            if [[ "$project_path" == *'#'* || "$project_path" == *$'\r'* \
                || "$project_path" == *$'\n'* ]]; then
                printf "Cannot update SSH gate for path containing '#', CR, or LF: %q\n" \
                    "$project_path" >&2
                printf 'ssh.conf cannot represent this path.\n' >&2
                return 1
            fi
            ;;
        *)
            printf 'Unknown ssh.conf scope: %s\n' "$scope" >&2
            return 1
            ;;
    esac

    conf_dir="${conf%/*}"
    [ "$conf_dir" != "$conf" ] || conf_dir=.
    mkdir -p "$conf_dir" || return 1
    [ -f "$conf" ] || : > "$conf"
    if [ -s "$conf" ] \
        && [ "$(tail -c 1 "$conf" | wc -l | tr -d ' ')" -gt 0 ]; then
        file_had_newline=1
    fi

    stripped="$(mktemp "${conf}.tmp.XXXXXX")" || return 1
    temp="$(mktemp "${conf}.tmp.XXXXXX")" || {
        rm -f "$stripped"
        return 1
    }
    _boxa::remove_conf_keys "$scope" "$project_path" "$conf" "$stripped" agent

    while IFS= read -r line || [ -n "$line" ]; do
        parsed="${line%%#*}"
        parsed="${parsed#"${parsed%%[![:space:]]*}"}"
        parsed="${parsed%"${parsed##*[![:space:]]}"}"

        if [[ "$parsed" == \[*\] ]]; then
            value="${parsed:1:${#parsed}-2}"
            if [ "$scope" = global ] && [ -z "$target_seen" ]; then
                [ -z "$output_started" ] || printf '\n' >> "$temp"
                printf 'agent = %s' "$agent_value" >> "$temp"
                output_started=1
                target_seen=1
            elif [ "$scope" = project ] && [ "$section" = "$project_path" ] \
                && [ -z "$target_seen" ]; then
                [ -z "$output_started" ] || printf '\n' >> "$temp"
                printf 'agent = %s' "$agent_value" >> "$temp"
                output_started=1
                target_seen=1
            fi
            if [[ "$value" == /* ]]; then
                section="$value"
            else
                section=INVALID
            fi
        fi

        [ -z "$output_started" ] || printf '\n' >> "$temp"
        printf '%s' "$line" >> "$temp"
        output_started=1
    done < "$stripped"

    if [ "$scope" = project ] && [ "$section" = "$project_path" ] \
        && [ -z "$target_seen" ]; then
        [ -z "$output_started" ] || printf '\n' >> "$temp"
        printf 'agent = %s' "$agent_value" >> "$temp"
        output_started=1
        target_seen=1
    fi
    if [ "$scope" = global ] && [ -z "$target_seen" ]; then
        [ -z "$output_started" ] || printf '\n' >> "$temp"
        printf 'agent = %s' "$agent_value" >> "$temp"
        output_started=1
    elif [ "$scope" = project ] && [ -z "$target_seen" ]; then
        [ -z "$output_started" ] || printf '\n' >> "$temp"
        printf '[%s]\nagent = %s' "$project_path" "$agent_value" >> "$temp"
        output_started=1
    fi
    if [ -n "$file_had_newline" ] && [ -n "$output_started" ]; then
        printf '\n' >> "$temp"
    fi

    chmod "$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf")" "$temp" || {
        rm -f "$stripped" "$temp"
        return 1
    }
    mv "$temp" "$conf" || {
        rm -f "$stripped" "$temp"
        return 1
    }
    rm -f "$stripped"
}

_boxa::ssh_status() {
    local project_path="$1"
    local conf="${BOXA_SSH_CONF:-$HOME/.config/boxa/ssh.conf}"

    _boxa::resolve_ssh_gate "$project_path"
    printf 'SSH agent forwarding: %s\n' "$_BOXA_SSH_GATE"
    case "$_BOXA_SSH_SOURCE" in
        default) printf 'Source: default (off)\n' ;;
        global) printf 'Source: global config\n' ;;
        project) printf 'Source: project config [%s]\n' "$project_path" ;;
    esac
    printf 'Config: %s\n' "$conf"
}
