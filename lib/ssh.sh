# shellcheck shell=bash
# =============================================================================
# Boxa SSH gate
# =============================================================================
# Strictly parses ~/.config/boxa/ssh.conf and resolves whether one absolute
# host project path receives its dedicated per-project ssh-agent (ADR 0034).
# The config is deliberately never sourced.
# =============================================================================

_BOXA_SSH_GATE=off
_BOXA_SSH_SOURCE=default
_BOXA_SSH_HAS_LEGACY=
_BOXA_SSH_GLOBAL_HAS_LEGACY=
_BOXA_SSH_PROJECT_HAS_LEGACY=
_BOXA_SSH_LEGACY=
_BOXA_SSH_LEGACY_MODE=
_BOXA_SSH_LEGACY_NOTE_SHOWN=
_BOXA_SSH_REGISTRY_KEYS=()
_BOXA_SSH_PROJECT_AGENT_STARTED=

_boxa::ssh_key_registry_path() {
    printf '%s\n' "${BOXA_SSH_KEY_REGISTRY:-$HOME/.config/boxa/ssh-key-registry}"
}

# The Key registry keeps permanent consent history separately from each
# Project's effective key set. Each key path is also the stable identity for a
# private-only key whose public-key fingerprint is unavailable. The absolute
# sentinel preserves the strict section grammar while ensuring it can never
# name a real Project target.
_boxa::ssh_key_registry_history_section() {
    printf '/.boxa-key-history\n'
}

_boxa::ssh_registry_record_history_key() {
    local section

    section="$(_boxa::ssh_key_registry_history_section)" || return 1
    _boxa::ssh_registry_record_key "$section" "$1"
}

_boxa::ssh_registry_validate_path() {
    local label="$1" path="$2"

    if [[ "$path" != /* ]]; then
        printf '%s requires an absolute path: %s\n' "$label" "$path" >&2
        return 1
    fi
    if [[ "$path" == *'#'* || "$path" == *$'\r'* || "$path" == *$'\n'* ]]; then
        printf "%s cannot contain '#', CR, or LF: %q\n" "$label" "$path" >&2
        return 1
    fi
}

# Load one Project's registered key paths while validating the complete file.
# The registry is user-controlled data and is deliberately never sourced.
_boxa::ssh_registry_load_project() {
    local project_path="$1"
    local registry line parsed key value section=''

    _BOXA_SSH_REGISTRY_KEYS=()
    _boxa::ssh_registry_validate_path 'SSH key registry Project path' \
        "$project_path" || return 1
    registry="$(_boxa::ssh_key_registry_path)"
    [ -f "$registry" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        parsed="$line"
        parsed="${parsed#"${parsed%%[![:space:]]*}"}"
        parsed="${parsed%"${parsed##*[![:space:]]}"}"
        [ -z "$parsed" ] && continue
        [[ "$parsed" == \#* ]] && continue

        if [[ "$parsed" == \[* ]]; then
            if [[ "$parsed" != \[*\] ]]; then
                printf 'Invalid SSH key registry section: %s\n' "$line" >&2
                _BOXA_SSH_REGISTRY_KEYS=()
                return 1
            fi
            value="${parsed:1:${#parsed}-2}"
            if ! _boxa::ssh_registry_validate_path \
                    'SSH key registry section' "$value"; then
                _BOXA_SSH_REGISTRY_KEYS=()
                return 1
            fi
            section="$value"
            continue
        fi

        key="${parsed%%=*}"
        value="${parsed#*=}"
        if [ "$key" = "$parsed" ]; then
            printf 'Invalid SSH key registry entry: %s\n' "$line" >&2
            _BOXA_SSH_REGISTRY_KEYS=()
            return 1
        fi
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [ "$key" != key ] || [ -z "$section" ] \
                || ! _boxa::ssh_registry_validate_path \
                    'SSH key registry key path' "$value"; then
            printf 'Invalid SSH key registry entry: %s\n' "$line" >&2
            _BOXA_SSH_REGISTRY_KEYS=()
            return 1
        fi
        if [ "$section" = "$project_path" ]; then
            _BOXA_SSH_REGISTRY_KEYS+=("$value")
        fi
    done < "$registry"
}

_boxa::ssh_registry_prepare_write() {
    local registry="$1" registry_dir

    registry_dir="${registry%/*}"
    [ "$registry_dir" != "$registry" ] || registry_dir=.
    mkdir -p "$registry_dir" || return 1
    chmod 700 "$registry_dir" || return 1
}

_boxa::ssh_registry_record_key_locked() {
    local project_path="$1" key_path="$2"
    local registry input=/dev/null temp line parsed value section=''
    local target_seen='' written=''
    local existing

    _boxa::ssh_registry_validate_path 'SSH key registry key path' "$key_path" \
        || return 1
    _boxa::ssh_registry_load_project "$project_path" || return 1
    for existing in "${_BOXA_SSH_REGISTRY_KEYS[@]}"; do
        [ "$existing" != "$key_path" ] || return 0
    done

    registry="$(_boxa::ssh_key_registry_path)"
    _boxa::ssh_registry_prepare_write "$registry" || return 1
    [ ! -f "$registry" ] || input="$registry"
    temp="$(mktemp "${registry}.tmp.XXXXXX")" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        parsed="${line%%#*}"
        parsed="${parsed#"${parsed%%[![:space:]]*}"}"
        parsed="${parsed%"${parsed##*[![:space:]]}"}"
        if [[ "$parsed" == \[*\] ]]; then
            value="${parsed:1:${#parsed}-2}"
            if [ "$section" = "$project_path" ] && [ -z "$written" ]; then
                printf 'key = %s\n' "$key_path" >> "$temp"
                written=1
            fi
            section="$value"
            [ "$section" != "$project_path" ] || target_seen=1
        fi
        printf '%s\n' "$line" >> "$temp"
    done < "$input"
    if [ "$section" = "$project_path" ] && [ -z "$written" ]; then
        printf 'key = %s\n' "$key_path" >> "$temp"
        written=1
    fi
    if [ -z "$target_seen" ]; then
        [ ! -s "$temp" ] || printf '\n' >> "$temp"
        printf '[%s]\nkey = %s\n' "$project_path" "$key_path" >> "$temp"
    fi
    if ! chmod 600 "$temp" || ! mv "$temp" "$registry"; then
        rm -f "$temp"
        return 1
    fi
}

_boxa::ssh_registry_remove_key_locked() {
    local project_path="$1" key_path="$2"
    local registry temp line parsed key value section=''

    _boxa::ssh_registry_validate_path 'SSH key registry key path' "$key_path" \
        || return 1
    _boxa::ssh_registry_load_project "$project_path" || return 1
    registry="$(_boxa::ssh_key_registry_path)"
    [ -f "$registry" ] || return 0
    _boxa::ssh_registry_prepare_write "$registry" || return 1
    temp="$(mktemp "${registry}.tmp.XXXXXX")" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        parsed="${line%%#*}"
        parsed="${parsed#"${parsed%%[![:space:]]*}"}"
        parsed="${parsed%"${parsed##*[![:space:]]}"}"
        if [[ "$parsed" == \[*\] ]]; then
            section="${parsed:1:${#parsed}-2}"
        else
            key="${parsed%%=*}"
            value="${parsed#*=}"
            key="${key%"${key##*[![:space:]]}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            if [ "$section" = "$project_path" ] && [ "$key" = key ] \
                    && [ "$value" = "$key_path" ]; then
                continue
            fi
        fi
        printf '%s\n' "$line" >> "$temp"
    done < "$registry"
    if ! chmod 600 "$temp" || ! mv "$temp" "$registry"; then
        rm -f "$temp"
        return 1
    fi
}

# Atomically replace one Project's complete key-path set while preserving
# every unrelated registry section byte-for-byte. An empty set deliberately
# leaves the Project with no registered keys.
_boxa::ssh_registry_replace_project_locked() {
    local project_path="$1" keys="$2"
    local registry input=/dev/null temp line parsed key value section=''
    local target_seen='' inserted='' key_path

    _boxa::ssh_registry_validate_path 'SSH key registry Project path' \
        "$project_path" || return 1
    while IFS= read -r key_path; do
        [ -z "$key_path" ] && continue
        _boxa::ssh_registry_validate_path 'SSH key registry key path' \
            "$key_path" || return 1
    done <<< "$keys"

    registry="$(_boxa::ssh_key_registry_path)"
    _boxa::ssh_registry_load_project "$project_path" || return 1
    _boxa::ssh_registry_prepare_write "$registry" || return 1
    [ ! -f "$registry" ] || input="$registry"
    temp="$(mktemp "${registry}.tmp.XXXXXX")" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        parsed="${line%%#*}"
        parsed="${parsed#"${parsed%%[![:space:]]*}"}"
        parsed="${parsed%"${parsed##*[![:space:]]}"}"
        if [[ "$parsed" == \[*\] ]]; then
            if [ "$section" = "$project_path" ] && [ -z "$inserted" ]; then
                while IFS= read -r key_path; do
                    [ -z "$key_path" ] \
                        || printf 'key = %s\n' "$key_path" >> "$temp"
                done <<< "$keys"
                inserted=1
            fi
            section="${parsed:1:${#parsed}-2}"
            [ "$section" != "$project_path" ] || target_seen=1
            printf '%s\n' "$line" >> "$temp"
            continue
        fi
        key="${parsed%%=*}"
        value="${parsed#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [ "$section" = "$project_path" ] && [ "$key" = key ]; then
            continue
        fi
        printf '%s\n' "$line" >> "$temp"
    done < "$input"
    if [ "$section" = "$project_path" ] && [ -z "$inserted" ]; then
        while IFS= read -r key_path; do
            [ -z "$key_path" ] || printf 'key = %s\n' "$key_path" >> "$temp"
        done <<< "$keys"
    elif [ -z "$target_seen" ] && [ -n "$keys" ]; then
        [ ! -s "$temp" ] || printf '\n' >> "$temp"
        printf '[%s]\n' "$project_path" >> "$temp"
        while IFS= read -r key_path; do
            [ -z "$key_path" ] || printf 'key = %s\n' "$key_path" >> "$temp"
        done <<< "$keys"
    fi
    if ! chmod 600 "$temp" || ! mv "$temp" "$registry"; then
        rm -f "$temp"
        return 1
    fi
}

_boxa::ssh_run_registry_locked() {
    local callback="$1"
    shift

    _BOXA_SSH_REGISTRY_LOCK_HELD=1 "$callback" "$@"
}

_boxa::ssh_with_registry_lock() {
    local callback="$1" registry registry_dir lock status
    shift

    if [ -n "${_BOXA_SSH_REGISTRY_LOCK_HELD:-}" ]; then
        "$callback" "$@"
        return
    fi
    registry="$(_boxa::ssh_key_registry_path)"
    registry_dir="${registry%/*}"
    [ "$registry_dir" != "$registry" ] || registry_dir=.
    mkdir -p "$registry_dir" || return 1
    chmod 700 "$registry_dir" || return 1
    lock="${registry}.lock"
    if _boxa::with_pid_lock "$lock" _boxa::ssh_run_registry_locked \
            "$callback" "$@"; then
        return 0
    else
        status=$?
    fi
    if [ "$status" -eq 75 ]; then
        printf 'Timed out waiting for SSH Key registry lock: %s\n' "$lock" >&2
    fi
    return "$status"
}

_boxa::ssh_registry_record_key() {
    _boxa::ssh_with_registry_lock _boxa::ssh_registry_record_key_locked "$@"
}

_boxa::ssh_registry_remove_key() {
    _boxa::ssh_with_registry_lock _boxa::ssh_registry_remove_key_locked "$@"
}

_boxa::ssh_registry_replace_project() {
    _boxa::ssh_with_registry_lock _boxa::ssh_registry_replace_project_locked "$@"
}

# Resolve the SSH gate for one project. A valid project value overrides a
# valid global value; missing or invalid values leave the secure default off.
_boxa::resolve_ssh_gate() {
    local project_path="$1"
    local conf="${BOXA_SSH_CONF:-$HOME/.config/boxa/ssh.conf}"
    local line key value section="" global_value="" project_value=""
    local global_legacy="" project_legacy="" migration_needed=''
    local global_legacy_value='' project_legacy_value='' global_has_legacy=''
    local project_has_legacy=''

    _BOXA_SSH_GATE=off
    _BOXA_SSH_SOURCE=default
    _BOXA_SSH_HAS_LEGACY=
    _BOXA_SSH_GLOBAL_HAS_LEGACY=
    _BOXA_SSH_PROJECT_HAS_LEGACY=
    _BOXA_SSH_LEGACY=
    _BOXA_SSH_LEGACY_MODE=
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

        case "$key" in
            gate)
                case "$value" in
                    off|on) ;;
                    *)
                        _BOXA_SSH_GATE=off
                        _BOXA_SSH_SOURCE=invalid
                        return 0
                        ;;
                esac
                if [ -z "$section" ]; then
                    global_legacy_value=
                    global_legacy=
                elif [ "$section" = "$project_path" ]; then
                    project_legacy_value=
                    project_legacy=
                fi
                ;;
            agent)
                migration_needed=1
                if [ -z "$section" ]; then
                    global_has_legacy=1
                    global_legacy_value=1
                elif [ "$section" = "$project_path" ]; then
                    project_has_legacy=1
                    project_legacy_value=1
                fi
                case "$value" in
                    off) value=off ;;
                    on|user)
                        value=on
                        if [ -z "$section" ]; then
                            global_legacy=user
                        elif [ "$section" = "$project_path" ]; then
                            project_legacy=user
                        fi
                        ;;
                    agent)
                        value=on
                        if [ -z "$section" ]; then
                            global_legacy=agent
                        elif [ "$section" = "$project_path" ]; then
                            project_legacy=agent
                        fi
                        ;;
                    *)
                        _BOXA_SSH_GATE=off
                        _BOXA_SSH_SOURCE=invalid
                        return 0
                        ;;
                esac
                ;;
            *)
                continue
                ;;
        esac

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
    if [ "$_BOXA_SSH_SOURCE" = project ]; then
        _BOXA_SSH_LEGACY="$project_legacy_value"
        _BOXA_SSH_LEGACY_MODE="$project_legacy"
    elif [ "$_BOXA_SSH_SOURCE" = global ]; then
        _BOXA_SSH_LEGACY="$global_legacy_value"
        _BOXA_SSH_LEGACY_MODE="$global_legacy"
    fi
    _BOXA_SSH_HAS_LEGACY="$migration_needed"
    _BOXA_SSH_GLOBAL_HAS_LEGACY="$global_has_legacy"
    _BOXA_SSH_PROJECT_HAS_LEGACY="$project_has_legacy"
    if [ -n "$migration_needed" ] && [ -z "$_BOXA_SSH_LEGACY_NOTE_SHOWN" ]; then
        printf 'NOTE: Legacy SSH gate values are mapped in memory to off|on; the config remains unchanged until an explicit write.\n' >&2
        _BOXA_SSH_LEGACY_NOTE_SHOWN=1
    fi
}

# Replace the SSH agent gate value in one scope without sourcing or
# normalising the config. Existing unrelated bytes pass through unchanged.
# Usage: _boxa::write_ssh_conf <global|project> <path> <off|on>
_boxa::write_ssh_conf_locked() {
    local scope="$1" project_path="$2" agent_value="$3"
    local conf="${BOXA_SSH_CONF:-$HOME/.config/boxa/ssh.conf}"
    local conf_dir temp stripped line parsed value section="" target_seen=''
    local output_started='' file_had_newline=''

    case "$agent_value" in
        off|on) ;;
        *)
            printf 'Invalid SSH gate value: %s (expected off or on)\n' \
                "$agent_value" >&2
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
    _boxa::remove_conf_keys "$scope" "$project_path" "$conf" "$stripped" \
        agent gate

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
                printf 'gate = %s' "$agent_value" >> "$temp"
                output_started=1
                target_seen=1
            elif [ "$scope" = project ] && [ "$section" = "$project_path" ] \
                && [ -z "$target_seen" ]; then
                [ -z "$output_started" ] || printf '\n' >> "$temp"
                printf 'gate = %s' "$agent_value" >> "$temp"
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
        printf 'gate = %s' "$agent_value" >> "$temp"
        output_started=1
        target_seen=1
    fi
    if [ "$scope" = global ] && [ -z "$target_seen" ]; then
        [ -z "$output_started" ] || printf '\n' >> "$temp"
        printf 'gate = %s' "$agent_value" >> "$temp"
        output_started=1
    elif [ "$scope" = project ] && [ -z "$target_seen" ]; then
        [ -z "$output_started" ] || printf '\n' >> "$temp"
        printf '[%s]\ngate = %s' "$project_path" "$agent_value" >> "$temp"
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

_boxa::write_ssh_conf() {
    _boxa::ssh_with_registry_lock _boxa::write_ssh_conf_locked "$@"
}

_boxa::ssh_status() {
    local project_path="$1"
    local conf="${BOXA_SSH_CONF:-$HOME/.config/boxa/ssh.conf}"
    local fingerprints persona

    _boxa::resolve_ssh_gate "$project_path"
    if [ "$_BOXA_SSH_GATE" = on ] && [ -n "$_BOXA_SSH_LEGACY_MODE" ]; then
        _boxa::ssh_apply_legacy_keys "$project_path" "$_BOXA_SSH_LEGACY_MODE" \
            || true
    fi
    printf 'SSH agent forwarding: %s\n' "$_BOXA_SSH_GATE"
    case "$_BOXA_SSH_SOURCE" in
        default) printf 'Source: default (off)\n' ;;
        global) printf 'Source: global config\n' ;;
        project) printf 'Source: project config [%s]\n' "$project_path" ;;
        invalid) printf 'Source: invalid config (off)\n' ;;
    esac
    printf 'Config: %s\n' "$conf"
    persona="$(_boxa::ssh_project_persona "$project_path")"
    if _boxa::ssh_resolve_project_agent "$project_path"; then
        fingerprints="$(ssh-add -l 2>/dev/null \
            | awk 'NF { fingerprints = fingerprints (fingerprints == "" ? "" : ", ") $2 } END { print fingerprints }' \
            || true)"
        if [ -n "$fingerprints" ]; then
            printf "Per-project ssh-agent: running (persona '%s' keys: %s)\n" \
                "$persona" "$fingerprints"
        else
            printf "Per-project ssh-agent: running (persona '%s', no keys)\n" \
                "$persona"
        fi
    else
        printf 'Per-project ssh-agent: stopped\n'
    fi
    if declare -F _boxa::forge_ssh_gate_divergence_warnings >/dev/null; then
        _boxa::forge_ssh_gate_divergence_warnings "$project_path"
    fi
}

_boxa::ssh_project_persona() {
    local project_path="$1"

    if declare -F _boxa::resolve_forge_identity >/dev/null \
            && _boxa::resolve_forge_identity "$project_path" \
            && [ -n "${_BOXA_FORGE_RESOLVED_IDENTITY_ID:-}" ]; then
        printf '%s\n' "$_BOXA_FORGE_RESOLVED_IDENTITY_ID"
    else
        printf 'unassigned\n'
    fi
}

_boxa::ssh_agent_identity_dir() {
    printf '%s\n' "${BOXA_AGENT_IDENTITY_DIR:-$HOME/.config/boxa/agent-identity}"
}

_boxa::ssh_agent_key_pointer_path() {
    printf '%s\n' \
        "${BOXA_AGENT_KEY_POINTER:-$(_boxa::ssh_agent_identity_dir)/key-path}"
}

_boxa::ssh_agent_key_path() {
    local pointer path='' line line_count=0

    if [ -n "${BOXA_AGENT_KEY:-}" ]; then
        printf '%s\n' "$BOXA_AGENT_KEY"
        return 0
    fi

    # Adoption records only an absolute path. The private key remains in its
    # original location and is opened only by ssh-add, never by Boxa itself.
    pointer="$(_boxa::ssh_agent_key_pointer_path)"
    if [ -f "$pointer" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line_count=$((line_count + 1))
            path="$line"
        done < "$pointer"
        if [ "$line_count" -eq 1 ] && [[ "$path" == /* ]] \
                && [[ "$path" != *$'\r'* && "$path" != *$'\n'* ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    fi
    printf '%s/id_ed25519\n' "$(_boxa::ssh_agent_identity_dir)"
}

_boxa::ssh_agent_key_exists() {
    local key_path

    key_path="$(_boxa::ssh_agent_key_path)"
    [ -f "$key_path" ] || return 1
    [ ! -f "$key_path.pub" ] \
        || ssh-keygen -lf "$key_path.pub" >/dev/null 2>&1
}

_boxa::ssh_restore_agent_key() {
    _boxa::ssh_load_agent_key >/dev/null 2>&1 \
        || ssh-add -D >/dev/null 2>&1 || true
}

_boxa::ssh_adopt_agent_key() {
    local key_path="$1" identity_dir pointer pointer_dir temp
    local expected_fingerprint key_list

    if [ -n "${BOXA_AGENT_KEY:-}" ]; then
        printf 'Cannot adopt an Agent key while BOXA_AGENT_KEY overrides its path.\n' >&2
        return 1
    fi
    if [[ "$key_path" != /* || "$key_path" == *$'\r'* \
            || "$key_path" == *$'\n'* ]]; then
        printf 'Agent key adoption requires an absolute single-line path.\n' >&2
        return 1
    fi
    if [ ! -f "$key_path" ]; then
        printf 'Agent key adoption requires an existing private key: %s\n' \
            "$key_path" >&2
        return 1
    fi
    if [ -f "$key_path.pub" ] \
            && ! ssh-keygen -lf "$key_path.pub" >/dev/null 2>&1; then
        printf 'Agent key public key is invalid: %s.pub\n' "$key_path" >&2
        return 1
    fi
    expected_fingerprint=''
    if [ -f "$key_path.pub" ]; then
        expected_fingerprint="$(ssh-keygen -lf "$key_path.pub" 2>/dev/null \
            | awk 'NR == 1 { print $2 }')"
    fi
    _boxa::ssh_ensure_agent_identity_socket || return 1
    ssh-add -D >/dev/null 2>&1 || return 1
    if ! ssh-add -- "$key_path" >/dev/null 2>&1; then
        _boxa::ssh_restore_agent_key
        printf 'Could not load the selected Agent key: %s\n' "$key_path" >&2
        return 1
    fi
    key_list="$(ssh-add -l 2>/dev/null || true)"
    if [ "$(printf '%s\n' "$key_list" | awk 'NF { count++ } END { print count + 0 }')" -ne 1 ] \
            || { [ -n "$expected_fingerprint" ] \
                && [ "$(printf '%s\n' "$key_list" | awk 'NF { print $2 }')" \
                    != "$expected_fingerprint" ]; }; then
        _boxa::ssh_restore_agent_key
        printf 'Agent key private and public halves do not match: %s\n' \
            "$key_path" >&2
        return 1
    fi

    identity_dir="$(_boxa::ssh_agent_identity_dir)"
    pointer="$(_boxa::ssh_agent_key_pointer_path)"
    pointer_dir="${pointer%/*}"
    [ "$pointer_dir" != "$pointer" ] || pointer_dir=.
    if ! mkdir -p "$identity_dir" "$pointer_dir"; then
        _boxa::ssh_restore_agent_key
        return 1
    fi
    if ! chmod 700 "$identity_dir"; then
        _boxa::ssh_restore_agent_key
        return 1
    fi
    if ! temp="$(mktemp "${pointer}.tmp.XXXXXX")"; then
        _boxa::ssh_restore_agent_key
        return 1
    fi
    if ! (umask 077 && printf '%s\n' "$key_path" > "$temp") \
            || ! chmod 600 "$temp" || ! mv "$temp" "$pointer"; then
        rm -f "$temp"
        _boxa::ssh_restore_agent_key
        return 1
    fi
}

_boxa::ssh_agent_socket_dir() {
    printf '%s\n' \
        "${BOXA_AGENT_SOCKET_DIR:-$(_boxa::ssh_agent_identity_dir)/ssh-agent}"
}

_boxa::ssh_agent_socket_path() {
    printf '%s\n' "${BOXA_AGENT_SOCKET:-$(_boxa::ssh_agent_socket_dir)/agent.sock}"
}

_boxa::ssh_agent_env_path() {
    printf '%s\n' \
        "${BOXA_AGENT_SSH_ENV:-$(_boxa::ssh_agent_identity_dir)/ssh-agent.env}"
}

_boxa::ssh_generate_agent_key_locked() {
    local identity_dir key_path

    identity_dir="$(_boxa::ssh_agent_identity_dir)"
    key_path="$(_boxa::ssh_agent_key_path)"
    if [ -e "$key_path" ] || [ -e "$key_path.pub" ]; then
        if [ -f "$key_path" ] && [ -f "$key_path.pub" ]; then
            chmod 600 "$key_path"
            return 0
        fi
        printf 'Agent key pair is incomplete; refusing to overwrite it: %s\n' \
            "$key_path" >&2
        return 1
    fi

    mkdir -p "$identity_dir" || return 1
    chmod 700 "$identity_dir" || return 1
    if ! (umask 077 && ssh-keygen -q -t ed25519 -N '' \
            -C "boxa-agent@$(hostname)" -f "$key_path"); then
        return 1
    fi
    chmod 600 "$key_path"
}

_boxa::ssh_generate_agent_key() {
    local identity_dir lock status

    identity_dir="$(_boxa::ssh_agent_identity_dir)"
    mkdir -p "$identity_dir" || return 1
    chmod 700 "$identity_dir" || return 1
    lock="$identity_dir/.agent-key.lock"
    if _boxa::with_pid_lock "$lock" _boxa::ssh_generate_agent_key_locked; then
        return 0
    else
        status=$?
    fi
    if [ "$status" -eq 75 ]; then
        printf 'Timed out waiting for Agent key generation lock: %s\n' "$lock" >&2
    fi
    return "$status"
}

_boxa::ssh_agent_key_fingerprint() {
    local key_path

    key_path="$(_boxa::ssh_agent_key_path)"
    if [ ! -f "$key_path.pub" ]; then
        printf '%s\n' "$key_path"
        return 0
    fi
    ssh-keygen -lf "$key_path.pub" 2>/dev/null | awk 'NR == 1 { print $2 }'
}

# True when any global or per-Project SSH gate is on.
_boxa::ssh_agent_usage_configured() {
    local conf="${BOXA_SSH_CONF:-$HOME/.config/boxa/ssh.conf}"
    local line parsed section

    _boxa::resolve_ssh_gate ""
    if [ "$_BOXA_SSH_SOURCE" = global ] && [ "$_BOXA_SSH_GATE" = on ]; then
        return 0
    fi
    [ -f "$conf" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        parsed="${line%%#*}"
        parsed="${parsed#"${parsed%%[![:space:]]*}"}"
        parsed="${parsed%"${parsed##*[![:space:]]}"}"
        [[ "$parsed" == \[*\] ]] || continue
        section="${parsed:1:${#parsed}-2}"
        [[ "$section" == /* ]] || continue
        _boxa::resolve_ssh_gate "$section"
        if [ "$_BOXA_SSH_SOURCE" = project ] \
                && [ "$_BOXA_SSH_GATE" = on ]; then
            return 0
        fi
    done < "$conf"
    return 1
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
    local env_file="${2:-${BOXA_SSH_AGENT_ENV:-$HOME/.config/boxa/ssh-agent.env}}"
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

_boxa::ssh_project_agent_id() {
    local project_path="$1" digest

    if command -v sha256sum >/dev/null 2>&1; then
        digest="$(printf '%s' "$project_path" | sha256sum | awk '{ print $1 }')"
    elif command -v shasum >/dev/null 2>&1; then
        digest="$(printf '%s' "$project_path" | shasum -a 256 | awk '{ print $1 }')"
    else
        printf 'Cannot derive a per-project ssh-agent ID: sha256sum or shasum is required.\n' >&2
        return 1
    fi
    # Keep the Unix socket below the common 108-byte sockaddr_un ceiling.
    # The owner file checked by the resolver makes even a truncated-hash
    # collision fail instead of sharing another Project's agent.
    printf '%.24s\n' "$digest"
}

_boxa::ssh_project_agents_dir() {
    printf '%s\n' "${BOXA_SSH_AGENTS_DIR:-$HOME/.config/boxa/ssh-agents}"
}

_boxa::ssh_project_agent_dir() {
    local project_id

    project_id="$(_boxa::ssh_project_agent_id "$1")" || return 1
    printf '%s/%s\n' "$(_boxa::ssh_project_agents_dir)" "$project_id"
}

_boxa::ssh_project_agent_socket_dir() {
    # These legacy overrides are a single-Project test seam. Never set them
    # while testing or operating multi-Project isolation.
    if [ -n "${BOXA_AGENT_SOCKET_DIR:-}" ]; then
        printf '%s\n' "$BOXA_AGENT_SOCKET_DIR"
        return 0
    fi
    printf '%s/socket\n' "$(_boxa::ssh_project_agent_dir "$1")"
}

_boxa::ssh_project_agent_socket_path() {
    if [ -n "${BOXA_AGENT_SOCKET:-}" ]; then
        printf '%s\n' "$BOXA_AGENT_SOCKET"
        return 0
    fi
    printf '%s/agent.sock\n' "$(_boxa::ssh_project_agent_socket_dir "$1")"
}

_boxa::ssh_project_agent_env_path() {
    if [ -n "${BOXA_AGENT_SSH_ENV:-}" ]; then
        printf '%s\n' "$BOXA_AGENT_SSH_ENV"
        return 0
    fi
    printf '%s/agent.env\n' "$(_boxa::ssh_project_agent_dir "$1")"
}

_boxa::ssh_resolve_project_agent() {
    local project_path="$1" expected_socket env_file agent_dir owner

    agent_dir="$(_boxa::ssh_project_agent_dir "$project_path")" || return 1
    owner="$agent_dir/project-path"
    [ -f "$owner" ] && [ "$(cat "$owner")" = "$project_path" ] || return 1
    expected_socket="$(_boxa::ssh_project_agent_socket_path "$project_path")" \
        || return 1
    env_file="$(_boxa::ssh_project_agent_env_path "$project_path")" || return 1
    if _boxa::ssh_source_agent_env "$env_file" \
            && [ "$SSH_AUTH_SOCK" = "$expected_socket" ]; then
        return 0
    fi
    unset SSH_AUTH_SOCK SSH_AGENT_PID
    return 1
}

_boxa::ssh_ensure_project_agent() {
    local project_path="$1" agents_dir agent_dir socket_dir socket_path
    local env_file agent_output owner temp

    _BOXA_SSH_PROJECT_AGENT_STARTED=
    if _boxa::ssh_resolve_project_agent "$project_path"; then
        return 0
    fi
    agents_dir="$(_boxa::ssh_project_agents_dir)"
    agent_dir="$(_boxa::ssh_project_agent_dir "$project_path")" || return 1
    socket_dir="$(_boxa::ssh_project_agent_socket_dir "$project_path")" \
        || return 1
    socket_path="$(_boxa::ssh_project_agent_socket_path "$project_path")" \
        || return 1
    env_file="$(_boxa::ssh_project_agent_env_path "$project_path")" || return 1
    mkdir -p "$agents_dir" "$agent_dir" "$socket_dir" || return 1
    chmod 700 "$agents_dir" "$agent_dir" "$socket_dir" || return 1
    owner="$agent_dir/project-path"
    if [ -e "$owner" ]; then
        if [ ! -f "$owner" ] || [ "$(cat "$owner")" != "$project_path" ]; then
            printf 'Per-project ssh-agent ID collision for %s; refusing to share an ssh-agent.\n' \
                "$project_path" >&2
            return 1
        fi
    else
        temp="$(mktemp "${owner}.tmp.XXXXXX")" || return 1
        if ! (umask 077 && printf '%s\n' "$project_path" > "$temp") \
                || ! chmod 600 "$temp" || ! mv "$temp" "$owner"; then
            rm -f "$temp"
            return 1
        fi
    fi
    [ ! -S "$socket_path" ] || rm -f "$socket_path"
    agent_output="$(ssh-agent -a "$socket_path" -s)" || return 1
    eval "$agent_output" >/dev/null
    if ! _boxa::ssh_agent_available || [ "$SSH_AUTH_SOCK" != "$socket_path" ]; then
        printf 'Could not start the per-project ssh-agent for %s.\n' \
            "$project_path" >&2
        return 1
    fi
    _boxa::ssh_persist_agent_env "$agent_output" "$env_file" || {
        printf 'Could not persist the per-project ssh-agent environment for %s.\n' \
            "$project_path" >&2
        return 1
    }
    _BOXA_SSH_PROJECT_AGENT_STARTED=1
}

_boxa::ssh_stop_project_agent() {
    local project_path="$1" agent_pid

    _boxa::ssh_resolve_project_agent "$project_path" || return 0
    agent_pid="${SSH_AGENT_PID:-}"
    [[ "$agent_pid" =~ ^[0-9]+$ ]] || return 1
    kill "$agent_pid" 2>/dev/null || return 1
    for _ in {1..100}; do
        _boxa::ssh_agent_available || return 0
        sleep 0.01
    done
    kill -KILL "$agent_pid" 2>/dev/null || true
    for _ in {1..100}; do
        _boxa::ssh_agent_available || return 0
        sleep 0.01
    done
    return 1
}

_boxa::ssh_load_agent_key_into_project() {
    local project_path="$1"

    _boxa::ssh_ensure_project_agent "$project_path" || return 1
    _boxa::ssh_load_agent_key
}

_boxa::ssh_apply_legacy_keys() {
    local project_path="$1" legacy_mode="$2"

    case "$legacy_mode" in
        agent)
            printf 'NOTE: Seeding this per-project ssh-agent with the legacy Agent key.\n' >&2
            _boxa::ssh_load_agent_key_into_project "$project_path"
            ;;
        user)
            printf 'NOTE: Legacy user mode now uses a per-project ssh-agent; reselect the previously picked keys.\n' >&2
            if [ -t 0 ] && [ -t 1 ]; then
                _boxa::ssh_add_keys "$project_path"
            else
                _boxa::ssh_ensure_project_agent "$project_path"
                printf "NOTE: Run 'boxa ssh add' interactively to restore the Project's keys.\n" >&2
            fi
            ;;
    esac
}

_boxa::ssh_resolve_agent_identity_agent() {
    local expected_socket env_file

    expected_socket="$(_boxa::ssh_agent_socket_path)"
    env_file="$(_boxa::ssh_agent_env_path)"
    if _boxa::ssh_source_agent_env "$env_file" \
            && [ "$SSH_AUTH_SOCK" = "$expected_socket" ]; then
        return 0
    fi
    unset SSH_AUTH_SOCK SSH_AGENT_PID
    return 1
}

_boxa::ssh_load_agent_key() {
    local key_path expected_identity key_list

    key_path="$(_boxa::ssh_agent_key_path)"
    [ -f "$key_path" ] || return 1
    expected_identity="$(_boxa::ssh_agent_key_fingerprint)" || return 1
    key_list="$(ssh-add -l 2>/dev/null || true)"
    if [ "$expected_identity" != "$key_path" ] \
            && [ "$(printf '%s\n' "$key_list" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] \
            && [ "$(printf '%s\n' "$key_list" | awk 'NF { print $2 }')" \
                = "$expected_identity" ]; then
        return 0
    fi

    ssh-add -D >/dev/null 2>&1 || return 1
    ssh-add -- "$key_path" >/dev/null 2>&1
}

_boxa::ssh_ensure_agent_identity_socket() {
    local identity_dir socket_dir socket_path env_file agent_output

    identity_dir="$(_boxa::ssh_agent_identity_dir)"
    socket_dir="$(_boxa::ssh_agent_socket_dir)"
    socket_path="$(_boxa::ssh_agent_socket_path)"
    env_file="$(_boxa::ssh_agent_env_path)"
    if ! _boxa::ssh_resolve_agent_identity_agent; then
        mkdir -p "$identity_dir" "$socket_dir" || return 1
        chmod 700 "$identity_dir" "$socket_dir" || return 1
        [ ! -S "$socket_path" ] || rm -f "$socket_path"
        agent_output="$(ssh-agent -a "$socket_path" -s)" || return 1
        eval "$agent_output" >/dev/null
        if ! _boxa::ssh_agent_available \
                || [ "$SSH_AUTH_SOCK" != "$socket_path" ]; then
            printf 'Could not start the Boxa agent identity SSH agent.\n' >&2
            return 1
        fi
        if ! _boxa::ssh_persist_agent_env "$agent_output" "$env_file"; then
            printf 'Could not persist the Boxa agent identity SSH agent environment.\n' >&2
            return 1
        fi
    fi
}

# Lazily resurrect the dedicated one-key agent at its fixed socket path. The
# socket directory is stable and can remain mounted while the socket is remade.
_boxa::ssh_ensure_agent_identity_agent() {
    _boxa::ssh_ensure_agent_identity_socket || return 1

    if ! _boxa::ssh_load_agent_key; then
        printf 'Could not load the Agent key into its SSH agent.\n' >&2
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
    local name="$1" mounts key_list fingerprints persona
    local project_path="${PROJECT_PATH:-}"

    mounts="$(docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' \
        "$name" 2>/dev/null || true)"
    if ! grep -qxF /tmp/boxa-agent <<< "$mounts"; then
        printf 'SSH: gate off (enable: boxa ssh on)\n'
        return 0
    fi

    if [ -z "$project_path" ] \
            && declare -F _boxa::container_project_path >/dev/null; then
        project_path="$(_boxa::container_project_path "$name" 2>/dev/null \
            || true)"
    fi
    persona="$(_boxa::ssh_project_persona "$project_path")"
    if key_list="$(docker exec -u node "$name" ssh-add -l 2>/dev/null)"; then
        fingerprints="$(printf '%s\n' "$key_list" \
            | awk 'NF { values = values (values == "" ? "" : ", ") $2 } END { print values }')"
        printf "SSH: gate on; per-project ssh-agent running (persona '%s' keys: %s)\n" \
            "$persona" "$fingerprints"
    else
        printf "SSH: gate on; per-project ssh-agent running (persona '%s', no keys) — run 'boxa ssh add'\n" \
            "$persona"
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
        printf 'WARNING: %s has no passphrase. Any process in a box with this ssh-agent forwarded can use it anywhere.\n' \
            "$key_path" >&2
        printf 'Protect it with: ssh-keygen -p -f %q\n' "$key_path" >&2
        return 0
    fi
    ssh-add -- "$key_path"
}

_boxa::ssh_add_keys() {
    local project_path="${1:-}"
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
    if [ -n "$project_path" ]; then
        _boxa::ssh_ensure_project_agent "$project_path" || return 1
    else
        _boxa::ssh_ensure_agent || return 1
    fi

    while IFS= read -r label; do
        [ -n "$label" ] || continue
        if [ "$label" = "$manual_option" ]; then
            manual_path="$(_boxa::ssh_read_manual_path)" || return 1
            _boxa::ssh_add_key "$manual_path" || return 1
            [ -z "$project_path" ] \
                || _boxa::ssh_registry_record_key "$project_path" "$manual_path" \
                || return 1
            continue
        fi

        found=
        for ((i = 0; i < ${#key_labels[@]}; i++)); do
            if [ "$label" = "${key_labels[$i]}" ]; then
                _boxa::ssh_add_key "${key_paths[$i]}" || return 1
                [ -z "$project_path" ] \
                    || _boxa::ssh_registry_record_key "$project_path" \
                        "${key_paths[$i]}" || return 1
                found=1
                break
            fi
        done
        [ -n "$found" ] || return 1
    done <<< "$selected"
}

_boxa::ssh_reapply_registry_keys() {
    local project_path="$1" key_path

    _boxa::ssh_ensure_project_agent "$project_path" || return 1
    _boxa::ssh_registry_load_project "$project_path" || return 1
    [ "${#_BOXA_SSH_REGISTRY_KEYS[@]}" -gt 0 ] || return 2
    ssh-add -D >/dev/null 2>&1 || return 1
    (
        trap 'ssh-add -D >/dev/null 2>&1 || true; exit 130' HUP INT TERM
        for key_path in "${_BOXA_SSH_REGISTRY_KEYS[@]}"; do
            if ! _boxa::ssh_add_key "$key_path"; then
                ssh-add -D >/dev/null 2>&1 || true
                exit 1
            fi
        done
    )
}

# Keep an already-running per-project ssh-agent in sync after an assignment
# change. A stopped ssh-agent stays lazy and is populated at the next Container
# start.
_boxa::ssh_reconcile_running_project_agent() {
    local project_path="$1" key_path

    _boxa::ssh_registry_load_project "$project_path" || return 1
    _boxa::ssh_resolve_project_agent "$project_path" || return 0
    ssh-add -D >/dev/null 2>&1 || return 1
    for key_path in "${_BOXA_SSH_REGISTRY_KEYS[@]}"; do
        _boxa::ssh_add_key "$key_path" || return 1
    done
}

_boxa::ssh_add_project_keys_if_agent_unready() {
    local project_path="$1" reapply_status=0

    _boxa::ssh_ensure_project_agent "$project_path" || return 1
    [ "$(_boxa::ssh_agent_state)" = keys ] && return 0
    _boxa::ssh_reapply_registry_keys "$project_path" || reapply_status=$?
    if [ "$reapply_status" -eq 0 ]; then
        [ "$(_boxa::ssh_agent_state)" = keys ] && return 0
        return 1
    fi
    [ "$reapply_status" -eq 2 ] || return "$reapply_status"
    return 2
}
