# shellcheck shell=bash
# =============================================================================
# Boxa per-project memory deep-dive
# =============================================================================
# Resolves a Project, gathers live/post-mortem memory evidence, and renders the
# `boxa mem` report. Pure rendering and selection helpers stay separate so the
# report contract is testable without Docker.
# =============================================================================

BOXA_MEM_DOCKER_CMD="${BOXA_MEM_DOCKER_CMD:-docker}"
BOXA_OOM_ARCHIVE_DIR="${BOXA_OOM_ARCHIVE_DIR:-/var/log/boxa/oom}"
BOXA_MEMORY_DOCS_URL="${BOXA_MEMORY_DOCS_URL:-https://github.com/IVIJL/boxa/blob/main/docs/memory.md}"

_BOXA_MEM_PROJECT=
_BOXA_MEM_CONTAINER=
_BOXA_MEM_PROJECT_PATH=

# Resolve an optional name/path exactly like bare `boxa [path]`: an existing
# directory derives the sanitized basename, while any other token is a Project
# name. The explicit cwd argument is a unit-test seam for the no-argument case.
_boxa::mem_resolve_target() {
    local target="${1:-}" cwd="${2:-$PWD}" resolved
    [ -n "$target" ] || target="$cwd"

    if [ -d "$target" ]; then
        resolved="$(realpath "$target")" || return 1
        boxa::names_from_path "$resolved"
        _BOXA_MEM_PROJECT_PATH="$resolved"
    else
        boxa::names_from_token "$target"
        _BOXA_MEM_PROJECT_PATH=
    fi
    _BOXA_MEM_PROJECT="$BOXA_PROJECT_NAME"
    _BOXA_MEM_CONTAINER="$BOXA_CONTAINER_NAME"
}

# Cgroup v2 uses the literal `max` for an unlimited value. Docker inspect uses
# zero for the same condition, so callers can opt into accepting zero too.
_boxa::mem_parse_cgroup_value() {
    local value="${1:-}" zero_is_unlimited="${2:-false}"
    if [ "$value" = "max" ] || { [ "$zero_is_unlimited" = true ] && [ "$value" = 0 ]; }; then
        printf 'unlimited'
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        return 1
    fi
}

_boxa::mem_format_value() {
    local value="${1:-}"
    case "$value" in
        max|unlimited) printf 'unlimited' ;;
        *[!0-9]*|'') printf 'unknown' ;;
        *) _boxa::format_size "$value" ;;
    esac
}

_boxa::mem_format_limit() {
    local value="${1:-}"
    case "$value" in
        max|unlimited|0|-1) printf 'unlimited' ;;
        *) _boxa::mem_format_value "$value" ;;
    esac
}

_boxa::mem_percentage() {
    local usage="${1:-}" limit="${2:-}"
    if [[ ! "$usage" =~ ^[0-9]+$ ]] || [[ ! "$limit" =~ ^[0-9]+$ ]] || [ "$limit" -eq 0 ]; then
        printf 'n/a'
        return 0
    fi
    awk -v usage="$usage" -v limit="$limit" 'BEGIN { printf "%.1f%%", usage * 100 / limit }'
}

_boxa::mem_combined_limit() {
    local memory="${1:-}" swap="${2:-}"
    if [ "$memory" = max ] || [ "$swap" = max ]; then
        printf 'max'
    elif [[ "$memory" =~ ^[0-9]+$ ]] && [[ "$swap" =~ ^[0-9]+$ ]]; then
        printf '%s' "$((memory + swap))"
    else
        return 1
    fi
}

# Always render the complete stable memory.events vocabulary, even if an older
# kernel omitted a key. That keeps comparisons between Projects unambiguous.
_boxa::mem_render_events() {
    local events="${1:-}" key value
    local low=0 high=0 max=0 oom=0 oom_kill=0
    while read -r key value; do
        [[ "$value" =~ ^[0-9]+$ ]] || continue
        case "$key" in
            low) low="$value" ;;
            high) high="$value" ;;
            max) max="$value" ;;
            oom) oom="$value" ;;
            oom_kill) oom_kill="$value" ;;
        esac
    done <<< "$events"
    printf '  low:      %s\n' "$low"
    printf '  high:     %s\n' "$high"
    printf '  max:      %s\n' "$max"
    printf '  oom:      %s\n' "$oom"
    printf '  oom_kill: %s\n' "$oom_kill"
}

# Select newest records by their kernel timestamp embedded in the filename.
# Requiring the complete filename grammar prevents prefix collisions between
# Projects such as `api` and `api-worker`.
_boxa::mem_archive_paths() {
    local container="$1" limit="${2:-5}" dir="${BOXA_OOM_ARCHIVE_DIR}"
    local path base timestamp count=0 rows=""
    [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ] || return 0
    [ -d "$dir" ] || return 0

    for path in "$dir/${container}-"*.log; do
        [ -f "$path" ] || continue
        base="${path##*/}"
        timestamp="${base#"${container}-"}"
        timestamp="${timestamp%.log}"
        [[ "$timestamp" =~ ^[0-9]+\.[0-9]+$ ]] || continue
        rows+="${timestamp}"$'\t'"${path}"$'\n'
    done

    while IFS=$'\t' read -r timestamp path; do
        [ -n "$path" ] || continue
        printf '%s\n' "$path"
        count=$((count + 1))
        [ "$count" -lt "$limit" ] || break
    done < <(printf '%s' "$rows" | sort -t $'\t' -k1,1nr)
}

_boxa::mem_render_archives() {
    local container="$1" path found=false
    printf '\nRecent OOM archive entries:\n'
    while IFS= read -r path; do
        [ -f "$path" ] || continue
        found=true
        printf '\n--- %s ---\n' "${path##*/}"
        sed 's/^/  /' "$path"
    done < <(_boxa::mem_archive_paths "$container" 5)
    [ "$found" = true ] || printf '  none\n'
}

_boxa::mem_render_ps() {
    local rows="${1:-}" pid ppid rss command args count=0
    printf '  %6s %6s %8s %-16s %s\n' PID PPID RSS COMMAND ARGS
    while read -r pid ppid rss command args; do
        [ "$pid" = PID ] && continue
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$ppid" =~ ^[0-9]+$ ]] || continue
        [[ "$rss" =~ ^[0-9]+$ ]] || continue
        printf '  %6s %6s %8s %-16s %s\n' \
            "$pid" "$ppid" "$(_boxa::format_size "$((rss * 1024))")" \
            "$command" "$args"
        count=$((count + 1))
        [ "$count" -lt 10 ] || break
    done <<< "$rows"
    [ "$count" -gt 0 ] || printf '  unavailable\n'
}

_boxa::mem_recommended_size() {
    local limit="${1:-}"
    if [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ]; then
        _boxa::format_size "$((limit * 2))"
    else
        # Removed Containers have no inspect limit to double. Keep the recovery
        # block actionable instead of printing a placeholder.
        printf '12g'
    fi
}

_boxa::mem_render_recommendations() {
    local project="$1" project_path="${2:-}" size="$3" target
    if [ -n "$project_path" ]; then
        printf -v target '%q' "$project_path"
    else
        printf -v target '%q' "$project"
    fi

    printf '\nRecommended next commands:\n'
    printf '  Temporary raise (one shot): boxa --memory %s %s\n' "$size" "$target"
    printf '  Durable raise: edit ~/.config/boxa/resources.conf and add:\n'
    if [ -n "$project_path" ]; then
        printf '    [%s]\n' "$project_path"
    else
        printf '    [/absolute/path/to/%s]\n' "$project"
    fi
    printf '    memory = %s\n' "$size"
    printf '    memory_swap = %s\n' "$size"
    printf '  Diagnose again: boxa mem %s\n' "$target"
    printf '  Docs: %s\n' "$BOXA_MEMORY_DOCS_URL"
}

_boxa::mem_inspect_value() {
    local container="$1" template="$2"
    "$BOXA_MEM_DOCKER_CMD" inspect --format "$template" "$container" 2>/dev/null || true
}

_boxa::mem_inspect_project_path() {
    local container="$1" line
    while IFS= read -r line; do
        case "$line" in
            BOXA_PROJECT_HOST_PATH=*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done < <(_boxa::mem_inspect_value "$container" '{{range .Config.Env}}{{println .}}{{end}}')
}

_boxa::mem_cgroup_value() {
    local container="$1" file="$2" value
    value=$("$BOXA_MEM_DOCKER_CMD" exec "$container" cat "/sys/fs/cgroup/$file" 2>/dev/null || true)
    printf '%s' "$value"
}

_boxa::mem_report_running() {
    local container="$1" usage memory_limit swap_usage swap_limit combined events ps_rows
    usage=$(_boxa::mem_cgroup_value "$container" memory.current)
    memory_limit=$(_boxa::mem_cgroup_value "$container" memory.max)
    swap_usage=$(_boxa::mem_cgroup_value "$container" memory.swap.current)
    swap_limit=$(_boxa::mem_cgroup_value "$container" memory.swap.max)
    events=$(_boxa::mem_cgroup_value "$container" memory.events)
    combined=$(_boxa::mem_combined_limit "$memory_limit" "$swap_limit" 2>/dev/null || printf unknown)

    printf 'Status: running\n'
    printf 'Memory usage: %s / %s (%s)\n' \
        "$(_boxa::mem_format_value "$usage")" \
        "$(_boxa::mem_format_limit "$memory_limit")" \
        "$(_boxa::mem_percentage "$usage" "$memory_limit")"
    printf 'Swap usage: %s\n' "$(_boxa::mem_format_value "$swap_usage")"
    printf 'Memory+swap limit: %s\n' "$(_boxa::mem_format_limit "$combined")"
    printf '\nmemory.events:\n'
    _boxa::mem_render_events "$events"

    printf '\nTop processes by RSS — project aggregate:\n'
    printf '  Nested DinD containers cannot be attributed individually (inner rootless dockerd uses CgroupDriver=none).\n'
    ps_rows=$("$BOXA_MEM_DOCKER_CMD" exec "$container" \
        ps -eo pid,ppid,rss,comm,args --sort=-rss 2>/dev/null || true)
    _boxa::mem_render_ps "$ps_rows"

    _BOXA_MEM_CURRENT_LIMIT="$memory_limit"
}

_boxa::mem_report_exited() {
    local container="$1" status="$2" memory_limit memory_swap oom_killed
    memory_limit=$(_boxa::mem_inspect_value "$container" '{{.HostConfig.Memory}}')
    memory_swap=$(_boxa::mem_inspect_value "$container" '{{.HostConfig.MemorySwap}}')
    oom_killed=$(_boxa::mem_inspect_value "$container" '{{.State.OOMKilled}}')

    printf 'Status: %s\n' "$status"
    printf 'Memory limit: %s\n' "$(_boxa::mem_format_limit "$memory_limit")"
    printf 'Memory+swap limit: %s\n' "$(_boxa::mem_format_limit "$memory_swap")"
    if [ "$oom_killed" = true ]; then
        printf 'OOM history: an OOM kill happened during the container\047s lifetime.\n'
        printf '  .State.OOMKilled is a lifetime flag; it does not mean the container died of OOM.\n'
    fi
    _BOXA_MEM_CURRENT_LIMIT="$memory_limit"
}

_boxa::mem_report() {
    local target="${1:-}" state project_path size
    _boxa::mem_resolve_target "$target" "$PWD" || return 1

    printf 'Project: %s\n' "$_BOXA_MEM_PROJECT"
    printf 'Container: %s\n' "$_BOXA_MEM_CONTAINER"
    _BOXA_MEM_CURRENT_LIMIT=

    if "$BOXA_MEM_DOCKER_CMD" inspect "$_BOXA_MEM_CONTAINER" >/dev/null 2>&1; then
        state=$(_boxa::mem_inspect_value "$_BOXA_MEM_CONTAINER" '{{.State.Status}}')
        project_path=$(_boxa::mem_inspect_project_path "$_BOXA_MEM_CONTAINER")
        [ -n "$_BOXA_MEM_PROJECT_PATH" ] || _BOXA_MEM_PROJECT_PATH="$project_path"
        if [ "$state" = running ]; then
            _boxa::mem_report_running "$_BOXA_MEM_CONTAINER"
        else
            _boxa::mem_report_exited "$_BOXA_MEM_CONTAINER" "${state:-unknown}"
        fi
    else
        printf 'Status: Container exited or removed; Docker inspect data is unavailable.\n'
    fi

    _boxa::mem_render_archives "$_BOXA_MEM_CONTAINER"
    size=$(_boxa::mem_recommended_size "$_BOXA_MEM_CURRENT_LIMIT")
    _boxa::mem_render_recommendations \
        "$_BOXA_MEM_PROJECT" "$_BOXA_MEM_PROJECT_PATH" "$size"
}
