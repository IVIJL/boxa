# shellcheck shell=bash
# =============================================================================
# Boxa per-project resource limits
# =============================================================================
# Strictly parses ~/.config/boxa/resources.conf, resolves the effective Memory
# and Memory+swap limits, and provides host-capacity checks for docker-run.sh.
# Config is host-owned and keyed by absolute host project path (ADR 0020).
# =============================================================================

_BOXA_RESOURCES_CONF_LOADED=
_BOXA_RESOURCES_GLOBAL_MEMORY=
_BOXA_RESOURCES_GLOBAL_MEMORY_SWAP=
_BOXA_RESOURCES_GLOBAL_MEMORY_SET=
_BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET=
declare -gA _BOXA_RESOURCES_PROJECT_MEMORY=()
declare -gA _BOXA_RESOURCES_PROJECT_MEMORY_SWAP=()

_BOXA_MEMORY_BYTES=
_BOXA_MEMORY_SWAP_BYTES=
_BOXA_MEMORY_SOURCE=
_BOXA_MEMORY_SWAP_SOURCE=
_BOXA_HOST_MEMTOTAL_BYTES=

_BOXA_RESOURCE_UPDATE_NEEDED=
_BOXA_RESOURCE_UPDATE_NOTICE=
_BOXA_RESOURCE_UPDATE_WARNING=
_BOXA_RESOURCES_CONF_CHANGED=
_BOXA_OOM_PRE_UPDATE_SWEEP_DONE=

# Run at the first convergence update only. Ordering invariant: archive events
# under the pre-update limit before converging.
_boxa::sweep_oom_before_resource_update() {
    [ -z "$_BOXA_OOM_PRE_UPDATE_SWEEP_DONE" ] || return 0
    _BOXA_OOM_PRE_UPDATE_SWEEP_DONE=1
    if [ -n "${BOXA_DIR:-}" ] \
        && [ -x "$BOXA_DIR/scripts/sweep-oom-events.sh" ]; then
        "$BOXA_DIR/scripts/sweep-oom-events.sh" || true
    fi
}

_boxa::reset_resources_cache() {
    _BOXA_RESOURCES_CONF_LOADED=
    _BOXA_RESOURCES_GLOBAL_MEMORY=
    _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP=
    _BOXA_RESOURCES_GLOBAL_MEMORY_SET=
    _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET=
    _BOXA_RESOURCES_PROJECT_MEMORY=()
    _BOXA_RESOURCES_PROJECT_MEMORY_SWAP=()
    _BOXA_MEMORY_BYTES=
    _BOXA_MEMORY_SWAP_BYTES=
    _BOXA_MEMORY_SOURCE=
    _BOXA_MEMORY_SWAP_SOURCE=
    _BOXA_HOST_MEMTOTAL_BYTES=
}

# Parse ~/.config/boxa/resources.conf (or $BOXA_RESOURCES_CONF) into the
# cache. The file is deliberately never sourced: only memory and memory_swap
# key=value pairs are accepted, globally or below an [/absolute/path] header.
_boxa::load_resources_conf() {
    [ -n "$_BOXA_RESOURCES_CONF_LOADED" ] && return 0
    _BOXA_RESOURCES_CONF_LOADED=1
    _BOXA_RESOURCES_GLOBAL_MEMORY=
    _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP=
    _BOXA_RESOURCES_GLOBAL_MEMORY_SET=
    _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET=
    _BOXA_RESOURCES_PROJECT_MEMORY=()
    _BOXA_RESOURCES_PROJECT_MEMORY_SWAP=()

    local conf="${BOXA_RESOURCES_CONF:-$HOME/.config/boxa/resources.conf}"
    [ -f "$conf" ] || return 0

    local line key value section=""
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

        case "$key" in
            memory)
                if [ "$section" = "INVALID" ]; then
                    continue
                elif [ -n "$section" ]; then
                    _BOXA_RESOURCES_PROJECT_MEMORY["$section"]="$value"
                else
                    _BOXA_RESOURCES_GLOBAL_MEMORY="$value"
                    _BOXA_RESOURCES_GLOBAL_MEMORY_SET=1
                fi
                ;;
            memory_swap)
                if [ "$section" = "INVALID" ]; then
                    continue
                elif [ -n "$section" ]; then
                    _BOXA_RESOURCES_PROJECT_MEMORY_SWAP["$section"]="$value"
                else
                    _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP="$value"
                    _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET=1
                fi
                ;;
        esac
    done < "$conf"
}

# Remove both Memory keys from one scope. A project section containing no
# other content is removed with the keys; unrelated bytes pass through.
_boxa::remove_resources_conf_keys() {
    local scope="$1" target_section="$2" conf="$3" temp="$4"
    local line parsed key value section="" output_started='' in_target=''
    local target_has_content=''
    local -a target_lines=()

    _boxa::emit_resources_line() {
        [ -z "$output_started" ] || printf '\n' >> "$temp"
        printf '%s' "$1" >> "$temp"
        output_started=1
    }

    _boxa::flush_resources_target() {
        local buffered
        if [ -n "$target_has_content" ]; then
            for buffered in "${target_lines[@]}"; do
                _boxa::emit_resources_line "$buffered"
            done
        fi
        target_lines=()
        target_has_content=
        in_target=
    }

    while IFS= read -r line || [ -n "$line" ]; do
        parsed="${line%%#*}"
        parsed="${parsed#"${parsed%%[![:space:]]*}"}"
        parsed="${parsed%"${parsed##*[![:space:]]}"}"

        if [[ "$parsed" == \[*\] ]]; then
            [ -z "$in_target" ] || _boxa::flush_resources_target
            value="${parsed:1:${#parsed}-2}"
            if [[ "$value" == /* ]]; then
                section="$value"
            else
                section="INVALID"
            fi
            if [ "$scope" = project ] && [ "$section" = "$target_section" ]; then
                in_target=1
                target_lines+=("$line")
                continue
            fi
        fi

        key="${parsed%%=*}"
        if [ "$key" = "$parsed" ]; then
            key=
        else
            key="${key%"${key##*[![:space:]]}"}"
        fi
        if { [ "$scope" = global ] && [ -z "$section" ]; } \
            || [ -n "$in_target" ]; then
            case "$key" in
                memory|memory_swap)
                    _BOXA_RESOURCES_CONF_CHANGED=1
                    continue
                    ;;
            esac
        fi

        if [ -n "$in_target" ]; then
            target_lines+=("$line")
            [ -z "${line//[[:space:]]/}" ] || target_has_content=1
        else
            _boxa::emit_resources_line "$line"
        fi
    done < "$conf"
    [ -z "$in_target" ] || _boxa::flush_resources_target

    unset -f _boxa::emit_resources_line _boxa::flush_resources_target
}

# Reject a global change if any project that inherits a changed key would
# resolve to an invalid Memory and Memory+swap pair.
_boxa::validate_global_project_pairs() {
    local memory_value="$1" memory_swap_value="$2"
    local old_memory="$_BOXA_RESOURCES_GLOBAL_MEMORY"
    local old_swap="$_BOXA_RESOURCES_GLOBAL_MEMORY_SWAP"
    local old_memory_set="$_BOXA_RESOURCES_GLOBAL_MEMORY_SET"
    local old_swap_set="$_BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET"
    local memory_changed='' swap_changed='' section affected validation_error
    local -A project_sections=()

    if [ -n "$memory_value" ]; then
        _BOXA_RESOURCES_GLOBAL_MEMORY="$memory_value"
        _BOXA_RESOURCES_GLOBAL_MEMORY_SET=1
        memory_changed=1
        if [ -n "$memory_swap_value" ]; then
            _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP="$memory_swap_value"
            _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET=1
            swap_changed=1
        fi
    else
        memory_changed="$_BOXA_RESOURCES_GLOBAL_MEMORY_SET"
        swap_changed="$_BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET"
        _BOXA_RESOURCES_GLOBAL_MEMORY=
        _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP=
        _BOXA_RESOURCES_GLOBAL_MEMORY_SET=
        _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET=
    fi

    for section in "${!_BOXA_RESOURCES_PROJECT_MEMORY[@]}"; do
        project_sections["$section"]=1
    done
    for section in "${!_BOXA_RESOURCES_PROJECT_MEMORY_SWAP[@]}"; do
        project_sections["$section"]=1
    done

    for section in "${!project_sections[@]}"; do
        affected=
        if [ -z "${_BOXA_RESOURCES_PROJECT_MEMORY[$section]+set}" ] \
            && [ -n "$memory_changed" ]; then
            affected=1
        fi
        if [ -z "${_BOXA_RESOURCES_PROJECT_MEMORY_SWAP[$section]+set}" ] \
            && [ -n "$swap_changed" ]; then
            affected=1
        fi
        [ -n "$affected" ] || continue

        if ! validation_error="$(_boxa::resolve_resources "$section" 2>&1)"; then
            _BOXA_RESOURCES_GLOBAL_MEMORY="$old_memory"
            _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP="$old_swap"
            _BOXA_RESOURCES_GLOBAL_MEMORY_SET="$old_memory_set"
            _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET="$old_swap_set"
            printf 'Invalid resulting resource limits for project section [%s]: %s\n' \
                "$section" "$validation_error" >&2
            return 1
        fi
    done

    _BOXA_RESOURCES_GLOBAL_MEMORY="$old_memory"
    _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP="$old_swap"
    _BOXA_RESOURCES_GLOBAL_MEMORY_SET="$old_memory_set"
    _BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET="$old_swap_set"
}

# Reject a project unset if removing its overrides would resolve to an invalid
# Memory and Memory+swap pair.
_boxa::validate_project_unset_pair() {
    local project_path="$1" validation_error
    local old_memory="${_BOXA_RESOURCES_PROJECT_MEMORY[$project_path]-}"
    local old_swap="${_BOXA_RESOURCES_PROJECT_MEMORY_SWAP[$project_path]-}"
    local old_memory_set="${_BOXA_RESOURCES_PROJECT_MEMORY[$project_path]+set}"
    local old_swap_set="${_BOXA_RESOURCES_PROJECT_MEMORY_SWAP[$project_path]+set}"

    unset '_BOXA_RESOURCES_PROJECT_MEMORY[$project_path]'
    unset '_BOXA_RESOURCES_PROJECT_MEMORY_SWAP[$project_path]'

    if ! validation_error="$(_boxa::resolve_resources "$project_path" 2>&1)"; then
        [ -z "$old_memory_set" ] \
            || _BOXA_RESOURCES_PROJECT_MEMORY["$project_path"]="$old_memory"
        [ -z "$old_swap_set" ] \
            || _BOXA_RESOURCES_PROJECT_MEMORY_SWAP["$project_path"]="$old_swap"
        printf 'Invalid resulting resource limits for project section [%s]: %s\n' \
            "$project_path" "$validation_error" >&2
        return 1
    fi

    [ -z "$old_memory_set" ] \
        || _BOXA_RESOURCES_PROJECT_MEMORY["$project_path"]="$old_memory"
    [ -z "$old_swap_set" ] \
        || _BOXA_RESOURCES_PROJECT_MEMORY_SWAP["$project_path"]="$old_swap"
}

# Replace or remove the targeted Memory keys without sourcing or normalising the config.
# Existing lines retain their formatting and comments; unrelated bytes pass
# through unchanged. Validation completes before the config directory or file
# is touched. An empty Memory value removes both keys from the scope.
# Usage: _boxa::write_resources_conf <global|project> <path> <memory> [memory_swap]
_boxa::write_resources_conf() {
    local scope="$1" project_path="$2" memory_value="$3" memory_swap_value="${4:-}"
    local conf="${BOXA_RESOURCES_CONF:-$HOME/.config/boxa/resources.conf}"
    local memory_bytes memory_swap_bytes effective_swap conf_dir temp
    local line parsed key value section="" target_section="" comment body lhs rhs
    local leading trailing output_started='' file_had_newline='' target_seen=''
    local memory_seen='' swap_seen=''

    _BOXA_RESOURCES_CONF_CHANGED=

    case "$scope" in
        global) ;;
        project)
            if [[ "$project_path" != /* ]]; then
                printf 'Resource limits require an absolute host project path: %s\n' "$project_path" >&2
                return 1
            fi
            if [[ "$project_path" == *'#'* || "$project_path" == *$'\r'* \
                || "$project_path" == *$'\n'* ]]; then
                printf "Cannot update project Memory limits for path containing '#', CR, or LF: %q\n" \
                    "$project_path" >&2
                printf 'resources.conf cannot represent this path; use boxa --memory SIZE <path> for a one-shot override.\n' >&2
                return 1
            fi
            target_section="$project_path"
            ;;
        *)
            printf 'Unknown resources.conf scope: %s\n' "$scope" >&2
            return 1
            ;;
    esac

    _boxa::reset_resources_cache
    _boxa::load_resources_conf

    if [ -z "$memory_value" ]; then
        if [ "$scope" = global ]; then
            if [ -z "$_BOXA_RESOURCES_GLOBAL_MEMORY_SET" ] \
                && [ -z "$_BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET" ]; then
                return 0
            fi
        elif [ -z "${_BOXA_RESOURCES_PROJECT_MEMORY[$project_path]+set}" ] \
            && [ -z "${_BOXA_RESOURCES_PROJECT_MEMORY_SWAP[$project_path]+set}" ]; then
            return 0
        fi

        if [ "$scope" = global ]; then
            _boxa::validate_global_project_pairs '' '' || return 1
        else
            _boxa::validate_project_unset_pair "$project_path" || return 1
        fi

        temp="$(mktemp "${conf}.tmp.XXXXXX")" || return 1
        if [ -s "$conf" ] \
            && [ "$(tail -c 1 "$conf" | wc -l | tr -d ' ')" -gt 0 ]; then
            file_had_newline=1
        fi
        _boxa::remove_resources_conf_keys "$scope" "$target_section" "$conf" "$temp"
        if [ -n "$file_had_newline" ] && [ -s "$temp" ]; then
            printf '\n' >> "$temp"
        fi
        chmod "$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf")" "$temp" || {
            rm -f "$temp"
            return 1
        }
        mv "$temp" "$conf" || {
            rm -f "$temp"
            return 1
        }
        _boxa::reset_resources_cache
        return 0
    fi

    memory_bytes="$(_boxa::parse_size "$memory_value")" || return 1

    if [ -n "$memory_swap_value" ]; then
        effective_swap="$memory_swap_value"
    elif [ "$scope" = global ] && [ -n "$_BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET" ]; then
        effective_swap="$_BOXA_RESOURCES_GLOBAL_MEMORY_SWAP"
    elif [ "$scope" = project ] \
        && [ -n "${_BOXA_RESOURCES_PROJECT_MEMORY_SWAP[$project_path]+set}" ]; then
        effective_swap="${_BOXA_RESOURCES_PROJECT_MEMORY_SWAP[$project_path]}"
    elif [ "$scope" = project ] && [ -n "$_BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET" ]; then
        effective_swap="$_BOXA_RESOURCES_GLOBAL_MEMORY_SWAP"
    else
        effective_swap="$memory_value"
    fi
    memory_swap_bytes="$(_boxa::parse_size "$effective_swap")" || return 1
    if [ "$memory_swap_bytes" -lt "$memory_bytes" ]; then
        printf 'Invalid resource limits: memory_swap (%s bytes) must be greater than or equal to memory (%s bytes).\n' \
            "$memory_swap_bytes" "$memory_bytes" >&2
        return 1
    fi
    if [ "$scope" = global ]; then
        _boxa::validate_global_project_pairs "$memory_value" "$memory_swap_value" || return 1
    fi

    conf_dir="${conf%/*}"
    [ "$conf_dir" != "$conf" ] || conf_dir=.
    mkdir -p "$conf_dir" || return 1
    temp="$(mktemp "${conf}.tmp.XXXXXX")" || return 1
    if [ -f "$conf" ] && [ -s "$conf" ]; then
        [ "$(tail -c 1 "$conf" | wc -l | tr -d ' ')" -gt 0 ] && file_had_newline=1
    fi

    # Emit one logical line, inserting exactly one separator before every
    # line after the first. The original final-newline state is restored below.
    if [ -f "$conf" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            parsed="${line%%#*}"
            parsed="${parsed#"${parsed%%[![:space:]]*}"}"
            parsed="${parsed%"${parsed##*[![:space:]]}"}"

            if [[ "$parsed" == \[*\] ]]; then
                if [ "$scope" = global ]; then
                    if [ -z "$memory_seen" ]; then
                        [ -n "$output_started" ] && printf '\n' >> "$temp"
                        printf 'memory = %s' "$memory_value" >> "$temp"
                        output_started=1
                        memory_seen=1
                    fi
                    if [ -n "$memory_swap_value" ] && [ -z "$swap_seen" ]; then
                        printf '\nmemory_swap = %s' "$memory_swap_value" >> "$temp"
                        swap_seen=1
                    fi
                    target_seen=1
                elif [ "$scope" = project ] && [ "$section" = "$target_section" ]; then
                    if [ -z "$memory_seen" ]; then
                        [ -n "$output_started" ] && printf '\n' >> "$temp"
                        printf 'memory = %s' "$memory_value" >> "$temp"
                        output_started=1
                    fi
                    if [ -n "$memory_swap_value" ] && [ -z "$swap_seen" ]; then
                        [ -n "$output_started" ] && printf '\n' >> "$temp"
                        printf 'memory_swap = %s' "$memory_swap_value" >> "$temp"
                        output_started=1
                    fi
                    memory_seen=1
                    [ -z "$memory_swap_value" ] || swap_seen=1
                fi

                value="${parsed:1:${#parsed}-2}"
                if [[ "$value" == /* ]]; then
                    section="$value"
                else
                    section="INVALID"
                fi
                [ "$section" != "$target_section" ] || target_seen=1
            fi

            body="${line%%#*}"
            comment="${line:${#body}}"
            key="${parsed%%=*}"
            if [ "$key" = "$parsed" ]; then
                key=
            else
                key="${key%"${key##*[![:space:]]}"}"
            fi
            if { [ "$scope" = global ] && [ -z "$section" ]; } \
                || { [ "$scope" = project ] && [ "$section" = "$target_section" ]; }; then
                case "$key" in
                    memory)
                        value="$memory_value"
                        memory_seen=1
                        target_seen=1
                        ;;
                    memory_swap)
                        if [ -n "$memory_swap_value" ]; then
                            value="$memory_swap_value"
                            swap_seen=1
                            target_seen=1
                        else
                            value=
                        fi
                        ;;
                    *) value= ;;
                esac
                if [ -n "$value" ]; then
                    lhs="${body%%=*}"
                    rhs="${body#*=}"
                    if [ -z "${rhs//[[:space:]]/}" ]; then
                        leading="$rhs"
                        trailing=
                    else
                        leading="${rhs%%[![:space:]]*}"
                        trailing="${rhs##*[![:space:]]}"
                    fi
                    line="${lhs}=${leading}${value}${trailing}${comment}"
                fi
            fi

            [ -z "$output_started" ] || printf '\n' >> "$temp"
            printf '%s' "$line" >> "$temp"
            output_started=1
        done < "$conf"
    fi

    if [ "$scope" = global ]; then
        if [ -z "$memory_seen" ]; then
            [ -z "$output_started" ] || printf '\n' >> "$temp"
            printf 'memory = %s' "$memory_value" >> "$temp"
            output_started=1
        fi
        if [ -n "$memory_swap_value" ] && [ -z "$swap_seen" ]; then
            [ -z "$output_started" ] || printf '\n' >> "$temp"
            printf 'memory_swap = %s' "$memory_swap_value" >> "$temp"
            output_started=1
        fi
    elif [ "$scope" = project ]; then
        if [ -z "$target_seen" ]; then
            [ -z "$output_started" ] || printf '\n\n' >> "$temp"
            printf '[%s]\nmemory = %s' "$target_section" "$memory_value" >> "$temp"
            output_started=1
            if [ -n "$memory_swap_value" ]; then
                printf '\nmemory_swap = %s' "$memory_swap_value" >> "$temp"
            fi
        else
            if [ -z "$memory_seen" ]; then
                [ -z "$output_started" ] || printf '\n' >> "$temp"
                printf 'memory = %s' "$memory_value" >> "$temp"
                output_started=1
            fi
            if [ -n "$memory_swap_value" ] && [ -z "$swap_seen" ]; then
                [ -z "$output_started" ] || printf '\n' >> "$temp"
                printf 'memory_swap = %s' "$memory_swap_value" >> "$temp"
                output_started=1
            fi
        fi
    fi
    [ -z "$file_had_newline" ] || printf '\n' >> "$temp"

    if [ -f "$conf" ]; then
        chmod "$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf")" "$temp" || {
            rm -f "$temp"
            return 1
        }
    fi
    mv "$temp" "$conf" || {
        rm -f "$temp"
        return 1
    }
    _BOXA_RESOURCES_CONF_CHANGED=1
    _boxa::reset_resources_cache
}

# Convert a Docker-style size to bytes. Units use binary multiples, matching
# Docker: k/m/g with optional B or iB suffix, case-insensitive. Docker refuses
# memory limits below 6 MiB, so every parsed resource limit enforces that floor.
_boxa::parse_size() {
    local raw="${1:-}" normalized number unit multiplier bytes
    normalized="${raw,,}"
    if [[ ! "$normalized" =~ ^([0-9]+)(k|m|g)(i?b)?$ ]]; then
        printf "Invalid memory size '%s': expected a positive size such as 512m, 5g, or 6GiB.\n" "$raw" >&2
        return 1
    fi

    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
        k) multiplier=1024 ;;
        m) multiplier=1048576 ;;
        g) multiplier=1073741824 ;;
    esac

    bytes=$((10#$number * multiplier))
    if [ "$bytes" -eq 0 ]; then
        printf "Invalid memory size '%s': size must be greater than zero.\n" "$raw" >&2
        return 1
    fi
    if [ "$bytes" -lt 6291456 ]; then
        printf "Invalid memory size '%s': Docker requires at least 6 MiB.\n" "$raw" >&2
        return 1
    fi
    printf '%s' "$bytes"
}

# Read the Docker host's MemTotal in bytes. BOXA_MEMINFO_FILE,
# BOXA_DOCKER_INFO_CMD, and BOXA_SYSCTL_CMD are unit-test seams for the Linux,
# Docker Desktop, and physical-macOS fallback sources respectively.
_boxa::host_memtotal_bytes() {
    local meminfo="${BOXA_MEMINFO_FILE:-/proc/meminfo}"
    local docker_info_cmd="${BOXA_DOCKER_INFO_CMD:-docker}" sysctl_cmd="${BOXA_SYSCTL_CMD:-sysctl}"
    local kib bytes
    if [ -f "$meminfo" ]; then
        kib="$(awk '$1 == "MemTotal:" { print $2; exit }' "$meminfo" 2>/dev/null)"
        if [[ ! "$kib" =~ ^[0-9]+$ ]] || [ "$kib" -eq 0 ]; then
            printf 'Unable to determine host RAM from %s.\n' "$meminfo" >&2
            return 1
        fi
        printf '%s' "$((kib * 1024))"
        return 0
    fi

    bytes="$("$docker_info_cmd" info --format '{{.MemTotal}}' 2>/dev/null || true)"
    if [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 0 ]; then
        printf '%s' "$bytes"
        return 0
    fi

    bytes="$("$sysctl_cmd" -n hw.memsize 2>/dev/null || true)"
    if [[ ! "$bytes" =~ ^[0-9]+$ ]] || [ "$bytes" -eq 0 ]; then
        printf 'Unable to determine host RAM from %s, docker info, or sysctl -n hw.memsize.\n' "$meminfo" >&2
        return 1
    fi
    printf '%s' "$bytes"
}

# Resolve limits for an absolute host project path. Optional arguments are the
# CLI seams consumed by issue 02: <memory override> [memory_swap override].
# Results are exposed in _BOXA_MEMORY_* globals for the sourcing host script.
_boxa::resolve_resources() {
    local project_path="$1" cli_memory="${2:-}" cli_memory_swap="${3:-}"
    local memory_value memory_swap_value memory_source memory_swap_source

    if [[ "$project_path" != /* ]]; then
        printf 'Resource limits require an absolute host project path: %s\n' "$project_path" >&2
        return 1
    fi

    _boxa::load_resources_conf
    _BOXA_HOST_MEMTOTAL_BYTES=

    if [ -n "$cli_memory" ]; then
        memory_value="$cli_memory"
        memory_source="CLI flag"
    elif [ -n "${_BOXA_RESOURCES_PROJECT_MEMORY[$project_path]+set}" ]; then
        memory_value="${_BOXA_RESOURCES_PROJECT_MEMORY[$project_path]}"
        memory_source="project config"
    elif [ -n "$_BOXA_RESOURCES_GLOBAL_MEMORY_SET" ]; then
        memory_value="$_BOXA_RESOURCES_GLOBAL_MEMORY"
        memory_source="global config"
    else
        memory_value=""
        memory_source="derived"
    fi

    if [ "$memory_source" != "derived" ]; then
        if ! _BOXA_MEMORY_BYTES="$(_boxa::parse_size "$memory_value")"; then
            return 1
        fi
        _BOXA_HOST_MEMTOTAL_BYTES="$(_boxa::host_memtotal_bytes 2>/dev/null || true)"
    else
        if ! _BOXA_HOST_MEMTOTAL_BYTES="$(_boxa::host_memtotal_bytes)"; then
            return 1
        fi
        _BOXA_MEMORY_BYTES=$((_BOXA_HOST_MEMTOTAL_BYTES * 65 / 100))
        if [ "$_BOXA_MEMORY_BYTES" -lt 6291456 ]; then
            printf 'Derived Memory limit is below Docker minimum of 6 MiB.\n' >&2
            return 1
        fi
    fi

    if [ -n "$cli_memory_swap" ]; then
        memory_swap_value="$cli_memory_swap"
        memory_swap_source="CLI flag"
    elif [ -n "${_BOXA_RESOURCES_PROJECT_MEMORY_SWAP[$project_path]+set}" ]; then
        memory_swap_value="${_BOXA_RESOURCES_PROJECT_MEMORY_SWAP[$project_path]}"
        memory_swap_source="project config"
    elif [ -n "$_BOXA_RESOURCES_GLOBAL_MEMORY_SWAP_SET" ]; then
        memory_swap_value="$_BOXA_RESOURCES_GLOBAL_MEMORY_SWAP"
        memory_swap_source="global config"
    else
        memory_swap_value=""
        memory_swap_source="Memory limit (swap off)"
    fi

    if [ "$memory_swap_source" != "Memory limit (swap off)" ]; then
        if ! _BOXA_MEMORY_SWAP_BYTES="$(_boxa::parse_size "$memory_swap_value")"; then
            return 1
        fi
    else
        _BOXA_MEMORY_SWAP_BYTES="$_BOXA_MEMORY_BYTES"
    fi

    if [ "$_BOXA_MEMORY_SWAP_BYTES" -lt "$_BOXA_MEMORY_BYTES" ]; then
        printf 'Invalid resource limits: memory_swap (%s bytes) must be greater than or equal to memory (%s bytes).\n' \
            "$_BOXA_MEMORY_SWAP_BYTES" "$_BOXA_MEMORY_BYTES" >&2
        return 1
    fi

    _BOXA_MEMORY_SOURCE="$memory_source"
    _BOXA_MEMORY_SWAP_SOURCE="$memory_swap_source"
}

# Render bytes compactly for startup diagnostics (for example 6.5g or 512m).
_boxa::format_size() {
    local bytes="$1" divisor suffix
    if [ "$bytes" -ge 1073741824 ]; then
        divisor=1073741824
        suffix=g
    elif [ "$bytes" -ge 1048576 ]; then
        divisor=1048576
        suffix=m
    else
        divisor=1024
        suffix=k
    fi
    awk -v bytes="$bytes" -v divisor="$divisor" -v suffix="$suffix" \
        'BEGIN { value = bytes / divisor; if (value == int(value)) printf "%d%s", value, suffix; else printf "%.1f%s", value, suffix }'
}

# Render a live Docker limit for convergence notices. Docker reports zero
# Memory and zero/-1 MemorySwap for unconstrained legacy Containers.
_boxa::format_live_limit() {
    local bytes="$1"
    if [ "$bytes" -le 0 ]; then
        printf 'unlimited'
    else
        _boxa::format_size "$bytes"
    fi
}

# Print the unsafe-limit warning when host RAM is known and the proposed
# Memory limit exceeds it. An unavailable host total intentionally stays silent.
_boxa::memory_limit_host_warning() {
    local proposed="$1" host_total="${2:-}"
    if [ -n "$host_total" ] && [ "$proposed" -gt "$host_total" ]; then
        printf 'WARNING: Memory limit exceeds host RAM; protection is void.\n'
    fi
}

# Compare live and desired limits and compose the user-visible result without
# touching Docker. Optional current usage enables the immediate-OOM warning.
# Results are exposed in _BOXA_RESOURCE_UPDATE_* globals for docker-run.sh.
_boxa::plan_resource_convergence() {
    local container="$1" live_memory="$2" live_memory_swap="$3"
    local desired_memory="$4" desired_memory_swap="$5" usage="${6:-}" one_shot="${7:-}"
    local host_total="${8:-}"
    local live_memory_display live_swap_display desired_memory_display desired_swap_display usage_display host_warning

    _BOXA_RESOURCE_UPDATE_NEEDED=
    _BOXA_RESOURCE_UPDATE_NOTICE=
    _BOXA_RESOURCE_UPDATE_WARNING=

    if [ "$live_memory" -eq "$desired_memory" ] \
        && [ "$live_memory_swap" -eq "$desired_memory_swap" ]; then
        return 0
    fi

    _BOXA_RESOURCE_UPDATE_NEEDED=1
    live_memory_display="$(_boxa::format_live_limit "$live_memory")"
    live_swap_display="$(_boxa::format_live_limit "$live_memory_swap")"
    desired_memory_display="$(_boxa::format_size "$desired_memory")"
    desired_swap_display="$(_boxa::format_size "$desired_memory_swap")"
    _BOXA_RESOURCE_UPDATE_NOTICE="Memory limits updated for ${container}: memory ${live_memory_display} -> ${desired_memory_display}; memory+swap ${live_swap_display} -> ${desired_swap_display}."
    if [ -n "$one_shot" ]; then
        _BOXA_RESOURCE_UPDATE_NOTICE+=" One-shot override; use boxa mem set for a durable setting."
    fi

    host_warning="$(_boxa::memory_limit_host_warning "$desired_memory" "$host_total")"
    if [ -n "$host_warning" ]; then
        _BOXA_RESOURCE_UPDATE_WARNING="$host_warning"
    fi

    if [[ "$usage" =~ ^[0-9]+$ ]] \
        && { [ "$live_memory" -eq 0 ] || [ "$desired_memory" -lt "$live_memory" ]; } \
        && [ "$desired_memory" -lt "$usage" ]; then
        usage_display="$(_boxa::format_size "$usage")"
        if [ -n "$_BOXA_RESOURCE_UPDATE_WARNING" ]; then
            _BOXA_RESOURCE_UPDATE_WARNING+=$'\n'
        fi
        _BOXA_RESOURCE_UPDATE_WARNING+="WARNING: ${container} currently uses ${usage_display}, above its new ${desired_memory_display} Memory limit; an immediate OOM kill may follow."
    fi
}

# Effective memory usage: memory.current minus the reclaimable portion the
# kernel evicts before an OOM kill — inactive_file + active_file (page cache)
# + slab_reclaimable, per memory.stat — clamped at zero. Raw memory.current
# counts a warm page cache as usage, so a cache-heavy but healthy Project
# would read as nearly full; every boxa usage surface reports this effective
# value instead (ADR 0020 amendment). Missing memory.stat keys contribute
# zero, so an empty stat text degrades to raw memory.current.
_boxa::effective_usage_bytes() {
    local current="$1" stat="${2:-}" key value reclaimable=0
    [[ "$current" =~ ^[0-9]+$ ]] || return 1
    while read -r key value; do
        [[ "$value" =~ ^[0-9]+$ ]] || continue
        case "$key" in
            inactive_file|active_file|slab_reclaimable)
                reclaimable=$((reclaimable + value)) ;;
        esac
    done <<< "$stat"
    if [ "$reclaimable" -ge "$current" ]; then
        printf '0'
    else
        printf '%s' "$((current - reclaimable))"
    fi
}

# Render the `boxa ls` MEM cell from a raw in-container cgroup probe: three
# whitespace-separated fields — memory.current in bytes, memory.max in bytes
# or the literal "max" (no limit), and the memory.events oom_kill count —
# plus an optional fourth, the reclaimable byte sum from memory.stat (see
# _boxa::effective_usage_bytes), subtracted so the cell shows effective
# usage. An absent fourth field means zero (raw usage); any missing or
# malformed field degrades to "-" (the Container may have died mid-probe);
# the cell must never break the table. A non-zero oom_kill count appends a
# marker: OOM kills happened during the Container's lifetime — the
# Container itself keeps running (ADR 0020).
_boxa::mem_cell() {
    local probe="${1:-}"
    local -a fields=()
    read -r -d '' -a fields <<< "$probe" || true
    local current="${fields[0]:-}" max="${fields[1]:-}" oom_kill="${fields[2]:-}"
    local reclaimable="${fields[3]:-0}"
    local cell percent

    if [[ ! "$current" =~ ^[0-9]+$ ]] || [[ ! "$oom_kill" =~ ^[0-9]+$ ]] \
        || [[ ! "$reclaimable" =~ ^[0-9]+$ ]]; then
        printf -- '-'
        return 0
    fi
    if [ "$reclaimable" -ge "$current" ]; then
        current=0
    else
        current=$((current - reclaimable))
    fi
    if [ "$max" = "max" ]; then
        cell="no limit"
    elif [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ]; then
        percent=$(((current * 100 + max / 2) / max))
        cell="$(_boxa::format_size "$current")/$(_boxa::format_size "$max") ${percent}%"
    else
        printf -- '-'
        return 0
    fi
    if [ "$oom_kill" -gt 0 ]; then
        cell="$cell !oom×${oom_kill}"
    fi
    printf '%s' "$cell"
}

# Marker for an exited Container whose `docker inspect .State.OOMKilled` is
# true. That flag is a lifetime flag: "at least one OOM kill happened while
# the container ran", NOT "the container died of OOM" — it reads true even
# after a clean exit (ADR 0020). The wording must not claim the exit was
# OOM-caused. Prints nothing for any other flag value.
_boxa::exited_oom_marker() {
    local oomkilled="${1:-}" project="${2:-}"
    if [ "$oomkilled" = "true" ]; then
        printf "oom seen during run — see 'boxa mem %s'" "$project"
    fi
}

# Sum Memory limits for running user Containers. By default these are the live
# HostConfig values. In effective mode, resolve each Container's Project path
# against the current resources.conf; this projects a just-written config
# change before the convergence sweep applies it. BOXA_RUNNING_MEMORY_LIMITS_FILE
# replaces Docker in tests. Its original one-byte-value-per-line format remains
# valid; effective-mode records add a tab and the absolute Project path.
_boxa::running_memory_limit_sum() {
    local mode="${1:-live}" limits sum=0 limit project_path
    if [ -n "${BOXA_RUNNING_MEMORY_LIMITS_FILE:-}" ]; then
        limits="$(cat "$BOXA_RUNNING_MEMORY_LIMITS_FILE")"
    else
        local -a containers=()
        local name
        mapfile -t containers < <(docker ps --filter 'name=^boxa-' --format '{{.Names}}')
        [ "${#containers[@]}" -gt 0 ] || { printf '0'; return 0; }
        if [ "$mode" = effective ]; then
            limits=
            for name in "${containers[@]}"; do
                limit="$(docker inspect --format '{{.HostConfig.Memory}}' "$name" 2>/dev/null)" \
                    || return 1
                project_path="$(_boxa::container_project_path "$name" 2>/dev/null || true)"
                limits+="${limits:+$'\n'}${limit}"$'\t'"${project_path}"
            done
        else
            limits="$(docker inspect --format '{{.HostConfig.Memory}}' "${containers[@]}")"
        fi
    fi

    [ "$mode" != effective ] || _boxa::reset_resources_cache
    while IFS=$'\t' read -r limit project_path; do
        if [ "$mode" = effective ] && [[ "$project_path" == /* ]]; then
            _boxa::resolve_resources "$project_path" || return 1
            limit="$_BOXA_MEMORY_BYTES"
        fi
        [[ "$limit" =~ ^[0-9]+$ ]] || continue
        sum=$((sum + limit))
    done <<< "$limits"
    printf '%s' "$sum"
}

# True when the absolute Project path belongs to a running Container.
# BOXA_RUNNING_MEMORY_LIMITS_FILE uses the same effective-mode path records as
# _boxa::running_memory_limit_sum so tests need no Docker daemon.
_boxa::project_is_in_running_memory_limits() {
    local target_path="$1" limits project_path name
    if [ -n "${BOXA_RUNNING_MEMORY_LIMITS_FILE:-}" ]; then
        limits="$(cat "$BOXA_RUNNING_MEMORY_LIMITS_FILE")"
        while IFS=$'\t' read -r _ project_path; do
            [ "$project_path" = "$target_path" ] && return 0
        done <<< "$limits"
        return 1
    fi

    local -a containers=()
    mapfile -t containers < <(docker ps --filter 'name=^boxa-' --format '{{.Names}}')
    for name in "${containers[@]}"; do
        project_path="$(_boxa::container_project_path "$name" 2>/dev/null || true)"
        [ "$project_path" = "$target_path" ] && return 0
    done
    return 1
}

# True when running limits plus a proposed Container limit exceed host RAM.
_boxa::would_jointly_exhaust_host() {
    local proposed="$1" host_total="${2:-}" sum_mode="${3:-live}" running_total
    if [ -z "$host_total" ]; then
        host_total="$(_boxa::host_memtotal_bytes)" || return 1
    fi
    running_total="$(_boxa::running_memory_limit_sum "$sum_mode")" || return 1
    [ "$((running_total + proposed))" -gt "$host_total" ]
}

# Print the canonical shared-capacity warning when the proposed limit plus
# running Containers' current limits exceeds host RAM.
_boxa::joint_exhaustion_warning() {
    local proposed="$1" host_total="${2:-}" sum_mode="${3:-live}"
    if [ -n "$host_total" ] \
        && _boxa::would_jointly_exhaust_host "$proposed" "$host_total" "$sum_mode"; then
        printf 'WARNING: Running boxa Containers can jointly exhaust host RAM; use the .wslconfig VM backstop.\n'
    fi
}

# A running target is already represented by its newly effective limit in the
# projected sum. A stopped or not-yet-created target must be added separately.
_boxa::project_joint_exhaustion_warning() {
    local proposed="$1" project_path="$2" host_total="${3:-}"
    if _boxa::project_is_in_running_memory_limits "$project_path"; then
        proposed=0
    fi
    _boxa::joint_exhaustion_warning "$proposed" "$host_total" effective
}

# Warn from the effective limits after a scope change. Global changes are
# already represented by every running Container in effective mode; a stopped
# Project target must still be added separately.
_boxa::effective_scope_joint_exhaustion_warning() {
    local scope="$1" project_path="${2:-}" host_total="${3:-}"
    if [ "$scope" = global ]; then
        _boxa::joint_exhaustion_warning 0 "$host_total" effective
        return
    fi

    _boxa::resolve_resources "$project_path" || return 1
    _boxa::project_joint_exhaustion_warning \
        "$_BOXA_MEMORY_BYTES" "$project_path" "$host_total"
}
