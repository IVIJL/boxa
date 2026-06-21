#!/bin/bash
set -euo pipefail

# =============================================================================
# show-allow-for-status — read-only status of an active Allow-for window
# =============================================================================
# Runs as the node user (no privileged operations). The sentinel is
# mode 0644 so the read works without sudo; everything that writes is
# protected by root ownership.
#
# Output goes to stdout in a fixed, human-oriented format. docker-run.sh
# invokes this when the user runs `boxa allow-for` (no args) and a
# window is already active.
# =============================================================================

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/allow-for.sh
source /usr/local/share/boxa/lib/allow-for.sh

if ! allow_for::sentinel_exists; then
    echo "No allow-for window active."
    exit 1
fi

started_at=$(allow_for::get_field started_at || echo "unknown")
expires_at=$(allow_for::get_field expires_at || echo "unknown")
container=$(allow_for::get_field container || echo "unknown")
log_start_byte=$(allow_for::get_field log_start_byte || echo 0)

remaining=$(allow_for::format_remaining "$expires_at")

# Same aggregation the teardown uses, just on the partial log so far.
# Empty result is normal: the window may have just opened.
captured_count=0
captured=$(allow_for::harvest_domains "$log_start_byte" || true)
[ -n "$captured" ] && captured_count=$(printf '%s\n' "$captured" | wc -l)

cat <<EOF
Allow-for window active for ${container}
  Started:   $(allow_for::human_time "$started_at")
  Expires:   $(allow_for::human_time "$expires_at")   (${remaining} remaining)
  Captured:  ${captured_count} non-allowlist domains so far
EOF
