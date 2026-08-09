#!/bin/bash
# Plain-bash tests for the private Windows Power-watch WSL bridge.
# Usage: bash tests/power-watch-windows.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

TEST_BOXA_DIR="$TEST_ROOT/boxa"
mkdir -p "$TEST_BOXA_DIR/scripts" "$TEST_ROOT/bin"
cp "$SCRIPT_DIR/../docker-run.sh" "$TEST_BOXA_DIR/docker-run.sh"
cp "$SCRIPT_DIR/../scripts/power-watch-windows.sh" "$TEST_BOXA_DIR/scripts/"

cat > "$TEST_ROOT/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$POWER_WATCH_TEST_DOCKER_LOG"
printf '%s\n' boxa-beta boxa-alpha boxa_traefik boxa_dns
STUB

cat > "$TEST_BOXA_DIR/scripts/deliver-allow-for-notification.sh" <<'STUB'
#!/bin/bash
printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" \
    >> "$POWER_WATCH_TEST_NOTIFICATION_LOG"
STUB

chmod +x "$TEST_BOXA_DIR/docker-run.sh" \
    "$TEST_BOXA_DIR/scripts/power-watch-windows.sh" \
    "$TEST_BOXA_DIR/scripts/deliver-allow-for-notification.sh" \
    "$TEST_ROOT/bin/docker"

export POWER_WATCH_TEST_DOCKER_LOG="$TEST_ROOT/docker.log"
export POWER_WATCH_TEST_NOTIFICATION_LOG="$TEST_ROOT/notification.log"

fail_count=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      expected: %q\n      actual:   %q\n' \
            "$label" "$expected" "$actual"
        fail_count=$((fail_count + 1))
    fi
}

run_boxa() {
    PATH="$TEST_ROOT/bin:$PATH" bash "$TEST_BOXA_DIR/docker-run.sh" "$@"
}

running_output="$(run_boxa __power-watch-windows running)"
assert_eq "running query emits project names only" $'beta\nalpha' "$running_output"
assert_eq "running query is one read-only Docker call" \
    "ps --filter name=^boxa- --format {{.Names}}" \
    "$(cat "$POWER_WATCH_TEST_DOCKER_LOG")"

run_boxa __power-watch-windows notify alpha beta
assert_eq "resume hook reuses durable notification dispatcher" \
    $'--notification\tBoxa closeout: sleep\tSystem slept while boxes alpha, beta were running — check them\t/var/log/boxa' \
    "$(cat "$POWER_WATCH_TEST_NOTIFICATION_LOG")"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll Windows Power-watch bridge tests passed.\n'
