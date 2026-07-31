#!/usr/bin/env bash
# Preserve yad's exit status so a menu Quit remains a clean systemd exit.
set -u

port="${1:-17777}"
icon_dir="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

keep_awake_tray::holders() {
    local json="$1" objects object agent session ttl label labels=""
    objects="$(printf '%s\n' "$json" \
        | sed -nE 's/.*"activeHolders":\[([^]]*)].*/\1/p' \
        | sed 's/},{/}\n{/g')"
    while IFS= read -r object; do
        [ -n "$object" ] || continue
        agent="$(printf '%s\n' "$object" | sed -nE 's/.*"agent":"([^"]*)".*/\1/p')"
        session="$(printf '%s\n' "$object" | sed -nE 's/.*"session":"([^"]*)".*/\1/p')"
        ttl="$(printf '%s\n' "$object" | sed -nE 's/.*"remainingTTLSeconds":([0-9]+).*/\1/p')"
        [ -n "$agent" ] || continue
        label="$agent"
        [ -z "$session" ] || label="$label/$session"
        [ -z "$ttl" ] || label="$label (${ttl}s)"
        if [ -n "$labels" ]; then labels="$labels, $label"; else labels="$label"; fi
    done <<< "$objects"
    printf '%s\n' "$labels"
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

keep_awake_tray::updates | yad --notification --listen \
    --image="$icon_dir/idle.svg" \
    --text='Boxa keep-awake: starting' \
    --menu='Quit!quit'
