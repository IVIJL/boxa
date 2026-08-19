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

        if [[ "$line" == \[* ]]; then
            if [[ "$line" == \[*\] ]]; then
                value="${line:1:${#line}-2}"
            else
                value=
            fi
            if [[ "$line" == \[*\] && "$value" == /* ]]; then
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

        if [[ "$parsed" == \[* ]]; then
            if [[ "$parsed" == \[*\] ]]; then
                value="${parsed:1:${#parsed}-2}"
            else
                value=
            fi
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
            if [[ "$parsed" == \[*\] && "$value" == /* ]]; then
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

# Print private-key candidates without opening them. Shell pathname expansion
# performs the directory read; the basename and file type are the only inputs
# to discovery. Public-key companions are handled separately for labels.
_boxa::ssh_discover_keys() {
    local ssh_dir="${1:-$HOME/.ssh}"
    local path name
    local -a entries=("$ssh_dir"/* "$ssh_dir"/.[!.]* "$ssh_dir"/..?*)

    [ -d "$ssh_dir" ] || return 0
    for path in ${entries[@]+"${entries[@]}"}; do
        [ -f "$path" ] || continue
        name="${path##*/}"
        case "$name" in
            *.pub|config|known_hosts*|authorized_keys*|environment|rc|moduli)
                continue
                ;;
        esac
        printf '%s\n' "$path"
    done
}

# The optional public-key comment is the only key-file content Boxa reads.
_boxa::ssh_public_comment() {
    local public_key="$1.pub"
    local key_type key_data comment

    [ -f "$public_key" ] || return 0
    IFS=' ' read -r key_type key_data comment < "$public_key" || true
    [ -n "${key_type:-}" ] && [ -n "${key_data:-}" ] || return 0
    printf '%s\n' "${comment:-}"
}

_boxa::ssh_agent_state() {
    ssh-add -l >/dev/null 2>&1
    case $? in
        0) printf 'keys\n' ;;
        1) printf 'empty\n' ;;
        *) printf 'dead\n' ;;
    esac
}

_boxa::ssh_agent_available() {
    local status

    [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ] || return 1
    ssh-add -l >/dev/null 2>&1
    status=$?
    [ "$status" -le 1 ]
}

_boxa::ssh_source_agent_env() {
    local env_file="$1"

    [ -r "$env_file" ] || return 1
    unset SSH_AUTH_SOCK SSH_AGENT_PID
    # Both accepted files are generated shell assignments, never user config.
    # shellcheck disable=SC1090
    . "$env_file" >/dev/null 2>&1 || {
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        return 1
    }
    export SSH_AUTH_SOCK SSH_AGENT_PID
    if ! _boxa::ssh_agent_available; then
        unset SSH_AUTH_SOCK SSH_AGENT_PID
        return 1
    fi
}

# Passively resolve an already-running agent: current environment, then the
# plain agent last started by Boxa's picker.
_boxa::ssh_resolve_agent() {
    local boxa_agent_env="${BOXA_SSH_AGENT_ENV:-$HOME/.config/boxa/ssh-agent.env}"

    if _boxa::ssh_agent_available; then
        return 0
    fi
    unset SSH_AUTH_SOCK SSH_AGENT_PID
    _boxa::ssh_source_agent_env "$boxa_agent_env" && return 0
    unset SSH_AUTH_SOCK SSH_AGENT_PID
    return 1
}

_boxa::ssh_persist_agent_env() {
    local agent_output="$1"
    local env_file="${BOXA_SSH_AGENT_ENV:-$HOME/.config/boxa/ssh-agent.env}"
    local env_dir temp

    env_dir="${env_file%/*}"
    [ "$env_dir" != "$env_file" ] || env_dir=.
    mkdir -p "$env_dir" || return 1
    temp="$(mktemp "${env_file}.tmp.XXXXXX")" || return 1
    if ! printf '%s\n' "$agent_output" > "$temp" || ! chmod 600 "$temp" \
            || ! mv "$temp" "$env_file"; then
        rm -f "$temp"
        return 1
    fi
}

# Starting or reviving an agent is deliberately confined to the key picker.
_boxa::ssh_ensure_agent() {
    local agent_output
    local keychain_env="${BOXA_KEYCHAIN_ENV:-$HOME/.keychain/$(hostname)-sh}"

    _boxa::ssh_resolve_agent && return 0
    _boxa::ssh_source_agent_env "$keychain_env" && return 0

    if command -v keychain >/dev/null 2>&1; then
        agent_output="$(keychain --eval --quiet --agents ssh)" || agent_output=
        [ -z "$agent_output" ] || eval "$agent_output"
    fi
    if ! _boxa::ssh_agent_available; then
        printf 'Starting SSH agent...\n' >&2
        agent_output="$(ssh-agent -s)" || return 1
        eval "$agent_output" >/dev/null
        if ! _boxa::ssh_agent_available; then
            printf 'Could not start an SSH agent.\n' >&2
            return 1
        fi
        if ! _boxa::ssh_persist_agent_env "$agent_output"; then
            printf 'Could not persist the SSH agent environment.\n' >&2
            return 1
        fi
    fi

    if ! _boxa::ssh_agent_available; then
        printf 'Could not start an SSH agent.\n' >&2
        return 1
    fi
}

# Report the frozen forwarding reality of an existing Container. The current
# ssh.conf is intentionally irrelevant because mounts change only on recreate.
_boxa::existing_container_ssh_status() {
    local name="$1" key_list key_names

    if ! docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' \
            "$name" 2>/dev/null | grep -qxF /tmp/ssh-agent.sock; then
        printf 'SSH: not forwarded (enable: boxa ssh on)\n'
        return 0
    fi

    if key_list="$(docker exec -u node "$name" ssh-add -l 2>/dev/null)"; then
        key_names="$(printf '%s\n' "$key_list" | awk '
            {
                $1 = ""
                $2 = ""
                sub(/^[[:space:]]+/, "")
                sub(/[[:space:]]+\([^()]*\)$/, "")
                names = names (names == "" ? "" : ", ") $0
            }
            END { print names }
        ')"
        printf 'SSH: forwarded (keys: %s)\n' "$key_names"
    else
        printf "SSH: forwarding on, but agent has no keys — run 'boxa ssh add'\n"
    fi
}

_boxa::print_existing_container_ssh_status() {
    _boxa::existing_container_ssh_status "$1"
}

_boxa::ssh_confirm_discovery() {
    local answer
    printf 'Look into ~/.ssh and offer keys to add? [y/N] ' >&2
    IFS= read -r answer </dev/tty || answer=
    case "$answer" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

_boxa::ssh_read_manual_path() {
    local path
    printf 'Path to private key: ' >&2
    IFS= read -r path </dev/tty || return 1
    [ -n "$path" ] || return 1
    case "$path" in
        \~) path="$HOME" ;;
        \~/*) path="$HOME/${path#\~/}" ;;
    esac
    printf '%s\n' "$path"
}

# Let ssh-add itself determine whether the key needs a passphrase. Boxa never
# opens the private key: a forced failing askpass makes the first attempt
# non-interactive, and only a failed attempt gets one interactive invocation.
_boxa::ssh_add_key() {
    local key_path="$1"

    if SSH_ASKPASS=/bin/false SSH_ASKPASS_REQUIRE=force \
            ssh-add -- "$key_path" </dev/null >/dev/null 2>&1; then
        printf 'WARNING: %s has no passphrase. Any agent in any forwarded box can use it anywhere.\n' \
            "$key_path" >&2
        printf 'Protect it with: ssh-keygen -p -f %q\n' "$key_path" >&2
        return 0
    fi
    ssh-add -- "$key_path"
}

_boxa::ssh_add_keys() {
    local manual_option='Enter a key path manually'
    local path comment label selected manual_path
    local i found
    local -a key_paths=() key_labels=()

    if _boxa::ssh_confirm_discovery; then
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            comment="$(_boxa::ssh_public_comment "$path")"
            label="$path"
            [ -z "$comment" ] || label="$label — $comment"
            key_paths+=("$path")
            key_labels+=("$label")
        done < <(_boxa::ssh_discover_keys "$HOME/.ssh")
    fi

    selected="$(printf '%s\n' ${key_labels[@]+"${key_labels[@]}"} \
        | picker::many --prompt 'Select keys:' \
            --first-option "$manual_option")" || return 1
    _boxa::ssh_ensure_agent || return 1

    while IFS= read -r label; do
        [ -n "$label" ] || continue
        if [ "$label" = "$manual_option" ]; then
            manual_path="$(_boxa::ssh_read_manual_path)" || return 1
            _boxa::ssh_add_key "$manual_path" || return 1
            continue
        fi

        found=
        for ((i = 0; i < ${#key_labels[@]}; i++)); do
            if [ "$label" = "${key_labels[$i]}" ]; then
                _boxa::ssh_add_key "${key_paths[$i]}" || return 1
                found=1
                break
            fi
        done
        [ -n "$found" ] || return 1
    done <<< "$selected"
}

_boxa::ssh_add_keys_if_agent_unready() {
    _boxa::ssh_resolve_agent || true
    [ "$(_boxa::ssh_agent_state)" = keys ] && return 0
    _boxa::ssh_add_keys
}
