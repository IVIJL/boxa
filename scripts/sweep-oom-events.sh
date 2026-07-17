#!/bin/bash
set -euo pipefail

# Detached host entry point. All behavior lives in lib/oom-sweep.sh so canned
# dmesg, Docker, filesystem, state, and notification seams remain unit-testable.
BOXA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export BOXA_OOM_NOTIFY_CMD="${BOXA_OOM_NOTIFY_CMD:-$BOXA_DIR/scripts/deliver-allow-for-notification.sh}"
# shellcheck source-path=SCRIPTDIR/.. source=lib/oom-sweep.sh disable=SC1091
source "$BOXA_DIR/lib/oom-sweep.sh"

_boxa::oom_sweep
