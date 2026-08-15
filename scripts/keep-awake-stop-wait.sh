#!/usr/bin/env bash
set -euo pipefail

if [ -z "$(docker ps --filter 'name=^boxa-' --format '{{.ID}}')" ]; then
    printf 'no-boxes\n'
    exit 0
fi

printf 'ready\n'
if ! IFS= read -r command; then
    exit 0
fi

if [ "$command" = stop ]; then
    boxa stop --all --reason presleep >&2
    printf 'done\n'
fi
