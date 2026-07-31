#!/bin/sh
# Signal boxa's host keep-awake daemon; silently no-op when it is unavailable.

action="${1:-busy}"
session="${BOXA_PROJECT_NAME:-default}"

case "$action" in
    idle)
        url="http://127.0.0.1:17777/v1/idle/claude?session=$session"
        ;;
    *)
        url="http://127.0.0.1:17777/v1/busy/claude?ttl=900&session=$session"
        ;;
esac

curl -fsS -m 1 "$url" >/dev/null 2>&1 || true
exit 0
