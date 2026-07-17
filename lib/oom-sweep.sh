# shellcheck shell=bash
# =============================================================================
# Boxa host-side memcg OOM sweep
# =============================================================================
# The kernel ring buffer is the source, but it is memory-only. Every completed
# boxa memcg OOM event is therefore copied into a durable archive record on the
# first boxa invocation that sees it. There is intentionally no daemon: the
# caller launches one detached sweep alongside each CLI invocation.
#
# This is best-effort/eventual diagnostics. If the VM dies before any boxa
# invocation runs the sweep, the kernel ring buffer and the unseen event are
# both lost. The archive cannot reconstruct evidence it never observed.
# =============================================================================

BOXA_OOM_ARCHIVE_DIR="${BOXA_OOM_ARCHIVE_DIR:-/var/log/boxa/oom}"
BOXA_OOM_STATE_FILE="${BOXA_OOM_STATE_FILE:-$BOXA_OOM_ARCHIVE_DIR/.last-seen-kernel-timestamp}"
BOXA_OOM_DOCKER_CMD="${BOXA_OOM_DOCKER_CMD:-docker}"
BOXA_OOM_NOTIFY_CMD="${BOXA_OOM_NOTIFY_CMD:-deliver-allow-for-notification.sh}"

# Read dmesg through a fixture seam in tests. Production deliberately uses the
# default timestamp format: `[seconds.frac]` is stable, sortable kernel truth.
_boxa::oom_read_dmesg() {
    if [ -n "${BOXA_OOM_DMESG_FILE:-}" ]; then
        cat "$BOXA_OOM_DMESG_FILE"
    else
        dmesg 2>/dev/null
    fi
}

# Emit tab-separated records:
#   EVENT <oom timestamp> <container id> <pid> <victim> <anon RSS kB>
#   LATEST <latest timestamp present anywhere in the ring-buffer snapshot>
#
# An oom-kill line identifies the memcg and the following Killed-process line
# supplies the actual kernel-selected victim and RSS. Incomplete pairs are not
# archived; a later sweep can retry while the evidence remains in dmesg.
_boxa::oom_parse_dmesg() {
    local line timestamp latest=""
    local event_timestamp="" container_id=""
    local victim_pid="" victim_name="" victim_rss_kb=""
    local killed_re='Killed[[:space:]]process[[:space:]]([0-9]+)[[:space:]]\(([^)]*)\).*anon-rss:([0-9]+)kB'

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^\[([0-9]+\.[0-9]+)\] ]]; then
            timestamp="${BASH_REMATCH[1]}"
            latest="$timestamp"
        else
            continue
        fi

        if [[ "$line" == *"oom-kill:"* ]]; then
            if [[ "$line" =~ oom_memcg=/docker/([[:xdigit:]]{64})(,|[[:space:]]) ]]; then
                event_timestamp="$timestamp"
                container_id="${BASH_REMATCH[1]}"
                victim_pid=""
                victim_name=""
                victim_rss_kb=""
            else
                # A host/non-Docker OOM begins a different event. Clear any
                # incomplete Docker pair rather than associating its victim.
                event_timestamp=""
                container_id=""
            fi
            continue
        fi

        [ -n "$event_timestamp" ] || continue
        if [[ "$line" =~ $killed_re ]]; then
            victim_pid="${BASH_REMATCH[1]}"
            victim_name="${BASH_REMATCH[2]}"
            victim_rss_kb="${BASH_REMATCH[3]}"
            printf 'EVENT\t%s\t%s\t%s\t%s\t%s\n' \
                "$event_timestamp" "$container_id" "$victim_pid" \
                "$victim_name" "$victim_rss_kb"
            event_timestamp=""
            container_id=""
        fi
    done

    [ -z "$latest" ] || printf 'LATEST\t%s\n' "$latest"
}

# Convert a kernel timestamp to integer nanoseconds for arithmetic comparison.
# dmesg commonly prints six fractional digits, but padding to nine makes the
# comparison correct for any precision up to nanoseconds.
_boxa::oom_timestamp_key() {
    local timestamp="$1" whole fraction
    whole="${timestamp%%.*}"
    fraction="${timestamp#*.}000000000"
    fraction="${fraction:0:9}"
    printf '%s\n' "$((10#$whole * 1000000000 + 10#$fraction))"
}

_boxa::oom_timestamp_gt() {
    local left right
    left=$(_boxa::oom_timestamp_key "$1")
    right=$(_boxa::oom_timestamp_key "$2")
    [ "$left" -gt "$right" ]
}

# State is data, never shell. Accept exactly one kernel timestamp and treat a
# missing or corrupt file as an empty state (fail open); existing archive files
# remain the second dedup layer and prevent re-notification.
_boxa::oom_read_state() {
    local state=""
    [ -f "$BOXA_OOM_STATE_FILE" ] || return 0
    IFS= read -r state < "$BOXA_OOM_STATE_FILE" || true
    if [[ "$state" =~ ^[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "$state"
    fi
}

_boxa::oom_write_state() {
    local timestamp="$1" tmp="${BOXA_OOM_STATE_FILE}.tmp.$$"
    if printf '%s\n' "$timestamp" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$BOXA_OOM_STATE_FILE" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
}

# Print `<container> <limit-bytes>` for a Docker id. Inspect normally provides
# both values. A `docker ps -a --no-trunc` fallback preserves correlation if
# the container disappears between listing and inspection; its limit then
# degrades to unknown instead of aborting the sweep.
_boxa::oom_inspect_container() {
    local container_id="$1" output name="" limit="" listed_id listed_name
    if output=$("$BOXA_OOM_DOCKER_CMD" inspect \
        --format '{{.Name}} {{.HostConfig.Memory}}' "$container_id" 2>/dev/null); then
        read -r name limit <<< "$output"
    else
        output=$("$BOXA_OOM_DOCKER_CMD" ps -a --no-trunc \
            --format '{{.ID}} {{.Names}}' 2>/dev/null) || return 1
        while read -r listed_id listed_name; do
            if [ "$listed_id" = "$container_id" ]; then
                name="$listed_name"
                limit=0
                break
            fi
        done <<< "$output"
        [ -n "$name" ] || return 1
    fi
    name="${name#/}"
    [[ "$name" =~ ^boxa-[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || return 2
    case "${limit:-}" in
        *[!0-9]*|"") limit=0 ;;
    esac
    printf '%s\t%s\n' "$name" "$limit"
}

_boxa::oom_format_bytes() {
    local bytes="$1" unit value tenths
    if [ "$bytes" -le 0 ]; then
        printf 'unknown'
        return
    fi
    if [ "$bytes" -ge 1073741824 ]; then
        unit="GiB"; value=1073741824
    else
        unit="MiB"; value=1048576
    fi
    if [ $((bytes % value)) -eq 0 ]; then
        printf '%d %s' "$((bytes / value))" "$unit"
    else
        tenths=$(((bytes * 10 + value / 2) / value))
        printf '%d.%d %s' "$((tenths / 10))" "$((tenths % 10))" "$unit"
    fi
}

_boxa::oom_format_rss() {
    _boxa::oom_format_bytes "$(( $1 * 1024 ))"
}

# Create the final archive path with noclobber semantics. That makes the
# archive itself the concurrency-safe dedup record when two detached sweeps
# overlap: exactly one writer wins and only that writer sends a notification.
_boxa::oom_archive_event() {
    local timestamp="$1" container="$2" project="$3" limit="$4"
    local victim_pid="$5" victim_name="$6" victim_rss_kb="$7"
    local path="$BOXA_OOM_ARCHIVE_DIR/${container}-${timestamp}.log"
    local limit_text rss_text
    limit_text=$(_boxa::oom_format_bytes "$limit")
    rss_text=$(_boxa::oom_format_rss "$victim_rss_kb")

    if ! (
        set -o noclobber
        printf '%s\n' \
            'Boxa OOM archive' \
            "Project: $project" \
            "Container: $container" \
            "Event time: kernel timestamp $timestamp seconds since boot" \
            "Memory limit: $limit_text" \
            "Kernel-selected victim: $victim_name (PID $victim_pid)" \
            "Victim anonymous RSS: $rss_text (${victim_rss_kb} kB)" \
            "Next step: boxa mem $project" > "$path"
    ) 2>/dev/null; then
        # Existing final path means another/earlier sweep already archived and
        # notified it. Any other write failure is retried because state will
        # not advance for this scan.
        [ -f "$path" ] && return 2
        return 1
    fi

    OOM_ARCHIVE_PATH="$path"
    OOM_LIMIT_TEXT="$limit_text"
    OOM_RSS_TEXT="$rss_text"
    return 0
}

_boxa::oom_notify_event() {
    local project="$1" victim_name="$2"
    local title="Boxa memory limit: $project"
    local limit_sentence
    if [ "$OOM_LIMIT_TEXT" = "unknown" ]; then
        limit_sentence="Project $project hit a memory limit."
    else
        limit_sentence="Project $project hit its $OOM_LIMIT_TEXT memory limit."
    fi
    local body="$limit_sentence Killed by the kernel: $victim_name, $OOM_RSS_TEXT RSS. The project keeps running."
    "$BOXA_OOM_NOTIFY_CMD" --notification "$title" "$body" \
        "$OOM_ARCHIVE_PATH" >/dev/null 2>&1
}

_boxa::oom_process_event() {
    local timestamp="$1" container_id="$2" victim_pid="$3"
    local victim_name="$4" victim_rss_kb="$5"
    local inspected container limit project archive_rc

    if inspected=$(_boxa::oom_inspect_container "$container_id"); then
        :
    else
        local inspect_rc=$?
        [ "$inspect_rc" -eq 2 ] && return 0
        return 1
    fi
    IFS=$'\t' read -r container limit <<< "$inspected"
    project="${container#boxa-}"

    if _boxa::oom_archive_event "$timestamp" "$container" "$project" \
        "$limit" "$victim_pid" "$victim_name" "$victim_rss_kb"; then
        _boxa::oom_notify_event "$project" "$victim_name" || true
        return 0
    else
        archive_rc=$?
    fi
    [ "$archive_rc" -eq 2 ] && return 0
    return 1
}

# Sweep one snapshot. A backwards latest timestamp means the VM/ring buffer
# restarted: discard the old cutoff and process everything currently visible.
# Old events are gone; archive-file dedup prevents any surviving fixture or
# corrupt-state rescan from notifying twice.
_boxa::oom_sweep() {
    mkdir -p "$BOXA_OOM_ARCHIVE_DIR" 2>/dev/null || return 0

    local previous latest="" cutoff failed=false
    local row kind timestamp container_id victim_pid victim_name victim_rss_kb
    local -a parsed=()
    previous=$(_boxa::oom_read_state)
    mapfile -t parsed < <(_boxa::oom_read_dmesg | _boxa::oom_parse_dmesg)

    for row in "${parsed[@]}"; do
        IFS=$'\t' read -r kind timestamp _ <<< "$row"
        [ "$kind" = "LATEST" ] && latest="$timestamp"
    done
    [ -n "$latest" ] || return 0

    cutoff="$previous"
    if [ -n "$previous" ] && _boxa::oom_timestamp_gt "$previous" "$latest"; then
        cutoff=""
    fi

    for row in "${parsed[@]}"; do
        IFS=$'\t' read -r kind timestamp container_id victim_pid \
            victim_name victim_rss_kb <<< "$row"
        [ "$kind" = "EVENT" ] || continue
        if [ -n "$cutoff" ] && ! _boxa::oom_timestamp_gt "$timestamp" "$cutoff"; then
            continue
        fi
        _boxa::oom_process_event "$timestamp" "$container_id" "$victim_pid" \
            "$victim_name" "$victim_rss_kb" || failed=true
    done

    $failed || _boxa::oom_write_state "$latest"
    return 0
}
