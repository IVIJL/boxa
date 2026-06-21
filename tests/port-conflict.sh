#!/bin/bash
# Integration assertions for the 443-conflict pre-flight predicate used by
# `_boxa::run_https_upgrade` and `bootstrap_traefik` in docker-run.sh.
#
# Usage: bash tests/port-conflict.sh
#
# docker-run.sh is a CLI dispatcher and not source-safe (top-level
# `set -euo pipefail` + an inline MODE switch that fires immediately on
# load), so the function under test is extracted via awk into a private
# tmp file and sourced in isolation. This keeps the predicate covered by
# tests without spinning up Docker or Traefik.
#
# We exercise the predicate against an unprivileged port (44443) instead
# of literal 443 because binding to 443 requires root. The function's
# regex matches by port suffix, so the behaviour is identical.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v ss >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
    printf 'SKIP  port-conflict suite — neither ss nor lsof present\n'
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    printf 'SKIP  port-conflict suite — python3 needed to bind a listener\n'
    exit 0
fi

_TMPROOT="$(mktemp -d)"
trap '
    [ -n "${LISTENER_PID:-}" ] && kill "$LISTENER_PID" 2>/dev/null || true
    rm -rf "$_TMPROOT"
' EXIT

# Extract just the helper out of docker-run.sh so we can source it on its
# own. Keep the awk window tight (function declaration line through the
# next closing brace at column 0) so we never accidentally drag in the
# top-level dispatcher.
extracted="$_TMPROOT/port_held_by_other.sh"
awk '
    /^_boxa::port_held_by_other\(\) \{$/ { capture=1 }
    capture { print }
    capture && /^\}$/ { exit }
' "$BOXA_DIR/docker-run.sh" > "$extracted"

if [ ! -s "$extracted" ]; then
    printf 'FAIL  could not extract _boxa::port_held_by_other from docker-run.sh\n'
    exit 1
fi

# shellcheck source=/dev/null
source "$extracted"

fail_count=0
TEST_PORT=44443

# assert_false is invoked as `assert_false "label" _boxa::port_held_by_other ...`
# — the body runs the args. Silence SC2317's false "unreachable" report on
# the body lines.
# shellcheck disable=SC2317
assert_false() {
    local label="$1"; shift
    if "$@"; then
        printf 'FAIL  %s\n      expected falsy, got rc=0\n' "$label"
        fail_count=$((fail_count + 1))
    else
        printf 'PASS  %s\n' "$label"
    fi
}

# --- Port free → predicate returns 1 ----------------------------------------

# Probe the chosen port up front — if something on the host already holds
# it, the "free" assertion below is a false positive. Bail loudly rather
# than reporting a spurious failure.
if ss -lntp 2>/dev/null | awk -v port="$TEST_PORT" 'NR>1 && $4 ~ ":"port"$"' | grep -q .; then
    printf 'SKIP  port-conflict suite — chosen test port %s is already in use\n' "$TEST_PORT"
    exit 0
fi

assert_false "port $TEST_PORT free → predicate returns 1" \
    _boxa::port_held_by_other "$TEST_PORT"

# --- Bind a listener → predicate returns 0 + describes the owner ------------

LISTENER_LOG="$_TMPROOT/listener.log"
python3 -c "
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $TEST_PORT))
s.listen(1)
sys.stdout.write('READY\n'); sys.stdout.flush()
time.sleep(10)
" > "$LISTENER_LOG" 2>&1 &
LISTENER_PID=$!

# Wait for the python listener to confirm it's bound. Without this the
# predicate may race past `ss` while the bind is still in flight and
# spuriously report "free".
for _ in $(seq 1 50); do
    if grep -q READY "$LISTENER_LOG" 2>/dev/null; then break; fi
    sleep 0.1
done

if _boxa::port_held_by_other "$TEST_PORT" >/dev/null; then
    printf 'PASS  port %s held → predicate returns 0\n' "$TEST_PORT"
else
    printf 'FAIL  port %s held → predicate returned 1\n' "$TEST_PORT"
    fail_count=$((fail_count + 1))
fi

# The descriptive line is either `pid <N> (python3)` (when ss can see the
# owning process) or the privileged-sudo fallback. Both are acceptable
# contract outputs; failing only when we get an empty line keeps the
# assertion stable across permission contexts.
desc="$(_boxa::port_held_by_other "$TEST_PORT" 2>/dev/null)"
if [ -n "$desc" ]; then
    printf 'PASS  predicate prints a non-empty owner description (%s)\n' "$desc"
else
    printf 'FAIL  predicate returned 0 but printed no owner description\n'
    fail_count=$((fail_count + 1))
fi

kill "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true
LISTENER_PID=

if [ "$fail_count" -eq 0 ]; then
    printf '\nAll assertions passed.\n'
    exit 0
fi
printf '\n%d assertion(s) failed.\n' "$fail_count"
exit 1
