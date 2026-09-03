#!/bin/bash
set -euo pipefail

readonly config_dir="${GLAB_CONFIG_DIR:-$HOME/.config/glab-cli}"
readonly config_file="$config_dir/config.yml"

[ -n "${GITLAB_HOST:-}" ] || exit 0

# User-managed config wins. Reconciliation belongs to a later migration slice.
[ ! -e "$config_file" ] || exit 0

mkdir -p "$config_dir"
umask 077
printf 'host: %s\nhosts:\n  %s:\n' "$GITLAB_HOST" "$GITLAB_HOST" \
    > "$config_file"
chmod 0600 "$config_file"
