#!/usr/bin/env bash
# Preserve yad's exit status so a menu Quit remains a clean systemd exit.
set -u

port="${1:-17777}"
icon_dir="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

keep_awake_tray::holders() {
    local json="$1"
    if ! command -v jq >/dev/null 2>&1; then
        printf 'holder details unavailable\n'
        return 0
    fi
    printf '%s\n' "$json" | jq -r '
        [
            .activeHolders[]?
            | select((.agent | type) == "string")
            | .agent
                + (if (.session? | type) == "string" and (.session | length) > 0
                    then "/" + .session else "" end)
                + (if (.remainingTTLSeconds? | type) == "number"
                    then " (" + (.remainingTTLSeconds | tostring) + "s)" else "" end)
        ]
        | join(", ")
    ' 2>/dev/null || printf 'holder details unavailable\n'
}

keep_awake_tray::updates() {
    local json holders
    printf 'menu:Quit!quit\n'
    while true; do
        if json="$(curl -fsS --max-time 2 "http://localhost:${port}/v1/status" 2>/dev/null)"; then
            if [[ "$json" == *'"isInhibited":true'* ]]; then
                holders="$(keep_awake_tray::holders "$json")"
                printf 'icon:%s/busy.svg\n' "$icon_dir"
                printf 'tooltip:Boxa keep-awake: busy - %s\n' "${holders:-active holder}"
            else
                printf 'icon:%s/idle.svg\n' "$icon_dir"
                printf 'tooltip:Boxa keep-awake: idle\n'
            fi
        else
            printf 'icon:%s/idle.svg\n' "$icon_dir"
            printf 'tooltip:Boxa keep-awake: daemon unavailable\n'
        fi
        sleep 5
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    keep_awake_tray::updates | yad --notification --listen \
        --image="$icon_dir/idle.svg" \
        --text='Boxa keep-awake: starting' \
        --menu='Quit!quit'
fi
