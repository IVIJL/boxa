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

# Read host MemTotal in bytes. BOXA_MEMINFO_FILE and BOXA_SYSCTL_CMD are
# unit-test seams for the Linux and macOS sources respectively.
_boxa::host_memtotal_bytes() {
    local meminfo="${BOXA_MEMINFO_FILE:-/proc/meminfo}" sysctl_cmd="${BOXA_SYSCTL_CMD:-sysctl}"
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

    bytes="$("$sysctl_cmd" -n hw.memsize 2>/dev/null || true)"
    if [[ ! "$bytes" =~ ^[0-9]+$ ]] || [ "$bytes" -eq 0 ]; then
        printf 'Unable to determine host RAM from %s or sysctl -n hw.memsize.\n' "$meminfo" >&2
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

# Compare live and desired limits and compose the user-visible result without
# touching Docker. Optional current usage enables the immediate-OOM warning.
# Results are exposed in _BOXA_RESOURCE_UPDATE_* globals for docker-run.sh.
_boxa::plan_resource_convergence() {
    local container="$1" live_memory="$2" live_memory_swap="$3"
    local desired_memory="$4" desired_memory_swap="$5" usage="${6:-}" one_shot="${7:-}"
    local live_memory_display live_swap_display desired_memory_display desired_swap_display usage_display

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
        _BOXA_RESOURCE_UPDATE_NOTICE+=" One-shot override; set ~/.config/boxa/resources.conf for a durable setting."
    fi

    if [[ "$usage" =~ ^[0-9]+$ ]] \
        && { [ "$live_memory" -eq 0 ] || [ "$desired_memory" -lt "$live_memory" ]; } \
        && [ "$desired_memory" -lt "$usage" ]; then
        usage_display="$(_boxa::format_size "$usage")"
        _BOXA_RESOURCE_UPDATE_WARNING="WARNING: ${container} currently uses ${usage_display}, above its new ${desired_memory_display} Memory limit; an immediate OOM kill may follow."
    fi
}

# Render the `boxa ls` MEM cell from a raw in-container cgroup probe: three
# whitespace-separated fields — memory.current in bytes, memory.max in bytes
# or the literal "max" (no limit), and the memory.events oom_kill count. Any
# missing or malformed field degrades to "-" (the Container may have died
# mid-probe); the cell must never break the table. A non-zero oom_kill count
# appends a marker: OOM kills happened during the Container's lifetime — the
# Container itself keeps running (ADR 0020).
_boxa::mem_cell() {
    local probe="${1:-}"
    local -a fields=()
    read -r -d '' -a fields <<< "$probe" || true
    local current="${fields[0]:-}" max="${fields[1]:-}" oom_kill="${fields[2]:-}"
    local cell percent

    if [[ ! "$current" =~ ^[0-9]+$ ]] || [[ ! "$oom_kill" =~ ^[0-9]+$ ]]; then
        printf -- '-'
        return 0
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

# Sum HostConfig.Memory for running user Containers. A newline-delimited file
# of byte values in BOXA_RUNNING_MEMORY_LIMITS_FILE replaces Docker in tests.
_boxa::running_memory_limit_sum() {
    local limits sum=0 limit
    if [ -n "${BOXA_RUNNING_MEMORY_LIMITS_FILE:-}" ]; then
        limits="$(cat "$BOXA_RUNNING_MEMORY_LIMITS_FILE")"
    else
        local -a containers=()
        mapfile -t containers < <(docker ps --filter 'name=^boxa-' --format '{{.Names}}')
        [ "${#containers[@]}" -gt 0 ] || { printf '0'; return 0; }
        limits="$(docker inspect --format '{{.HostConfig.Memory}}' "${containers[@]}")"
    fi

    while IFS= read -r limit; do
        [[ "$limit" =~ ^[0-9]+$ ]] || continue
        sum=$((sum + limit))
    done <<< "$limits"
    printf '%s' "$sum"
}

# True when running limits plus a proposed Container limit exceed host RAM.
_boxa::would_jointly_exhaust_host() {
    local proposed="$1" host_total="${2:-}" running_total
    if [ -z "$host_total" ]; then
        host_total="$(_boxa::host_memtotal_bytes)" || return 1
    fi
    running_total="$(_boxa::running_memory_limit_sum)" || return 1
    [ "$((running_total + proposed))" -gt "$host_total" ]
}
