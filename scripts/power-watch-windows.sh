#!/bin/bash
set -euo pipefail

BOXA_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

case "${1:-}" in
    running)
        [ "$#" -eq 1 ] || exit 2
        docker ps --filter "name=^boxa-" --format '{{.Names}}' \
            | sed -n 's/^boxa-//p'
        ;;
    notify)
        shift
        [ "$#" -gt 0 ] || exit 2
        boxes="$1"
        shift
        for box in "$@"; do
            boxes+=", $box"
        done
        exec "$BOXA_DIR/scripts/deliver-allow-for-notification.sh" --notification \
            "Boxa closeout: sleep" \
            "System slept while boxes $boxes were running — check them" \
            "/var/log/boxa"
        ;;
    *)
        exit 2
        ;;
esac
