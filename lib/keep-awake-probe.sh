# shellcheck shell=bash
# Shared functional probe for the keep-awake daemon. Callers provide the
# detected host platform; network configuration never selects the target.

KEEP_AWAKE_PROBE_TARGET_KIND=""
KEEP_AWAKE_PROBE_TARGET_ADDRESS=""
KEEP_AWAKE_PROBE_STATUS_JSON=""

keep_awake_probe::gateway() {
    ip route show default 2>/dev/null | awk 'NR == 1 { print $3; exit }'
}

keep_awake_probe::status() {
    local address="$1" port="$2"
    curl -fsS --noproxy '*' --max-time 2 \
        "http://${address}:${port}/v1/status" 2>/dev/null
}

keep_awake_probe::warm_hook() {
    local address="$1" port="$2" armed="$3"
    curl -fsS --noproxy '*' --max-time 2 \
        -H 'Content-Type: application/json' \
        -d "{\"armed\":${armed}}" \
        "http://${address}:${port}/v1/warm-hook" 2>/dev/null
}

keep_awake_probe::select_target() {
    local platform="$1" port="$2" gateway="" kind address status_json
    local -a candidates=("loopback" "127.0.0.1")

    if [ "$platform" = wsl2 ]; then
        gateway="$(keep_awake_probe::gateway)"
        if [ -n "$gateway" ] && [ "$gateway" != 127.0.0.1 ]; then
            candidates+=("gateway" "$gateway")
        fi
    fi

    KEEP_AWAKE_PROBE_TARGET_KIND=""
    KEEP_AWAKE_PROBE_TARGET_ADDRESS=""
    KEEP_AWAKE_PROBE_STATUS_JSON=""
    while [ "${#candidates[@]}" -gt 0 ]; do
        kind="${candidates[0]}"
        address="${candidates[1]}"
        candidates=("${candidates[@]:2}")
        if status_json="$(keep_awake_probe::status "$address" "$port")"; then
            KEEP_AWAKE_PROBE_TARGET_KIND="$kind"
            KEEP_AWAKE_PROBE_TARGET_ADDRESS="$address"
            KEEP_AWAKE_PROBE_STATUS_JSON="$status_json"
            return 0
        fi
    done
    return 1
}

keep_awake_probe::target_description() {
    [ -n "$KEEP_AWAKE_PROBE_TARGET_KIND" ] \
        && [ -n "$KEEP_AWAKE_PROBE_TARGET_ADDRESS" ] || return 1
    printf '%s (%s)\n' \
        "$KEEP_AWAKE_PROBE_TARGET_KIND" "$KEEP_AWAKE_PROBE_TARGET_ADDRESS"
}

keep_awake_probe::status_json() {
    [ -n "$KEEP_AWAKE_PROBE_STATUS_JSON" ] || return 1
    printf '%s\n' "$KEEP_AWAKE_PROBE_STATUS_JSON"
}
