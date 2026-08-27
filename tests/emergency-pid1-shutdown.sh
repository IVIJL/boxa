#!/bin/bash
# Fast, daemon-free tests for the boxa-entrypoint PID 1 shutdown fallback.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPROOT="$(mktemp -d)"
ENTRYPOINT_PID=""
SOCKET_PID=""

cleanup() {
    if [ -n "$ENTRYPOINT_PID" ]; then
        kill -KILL "$ENTRYPOINT_PID" >/dev/null 2>&1 || true
        wait "$ENTRYPOINT_PID" 2>/dev/null || true
    fi
    if [ -n "$SOCKET_PID" ]; then
        kill "$SOCKET_PID" >/dev/null 2>&1 || true
        wait "$SOCKET_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPROOT"
}
trap cleanup EXIT

mkdir -p "$TMPROOT/bin" "$TMPROOT/runtime" "$TMPROOT/barrier"
DOCKER_LOG="$TMPROOT/docker.log"
EVENT_LOG="$TMPROOT/events.log"

socat "UNIX-LISTEN:$TMPROOT/runtime/docker.sock,fork" /dev/null &
SOCKET_PID=$!
for _ in $(seq 1 100); do
    [ -S "$TMPROOT/runtime/docker.sock" ] && break
    sleep 0.01
done
if [ ! -S "$TMPROOT/runtime/docker.sock" ]; then
    printf 'FAIL  isolated fake Docker socket was not created.\n' >&2
    exit 1
fi

cat > "$TMPROOT/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$BOXA_PID1_TEST_DOCKER_LOG"
case "${1:-}" in
    info) ;;
    ps)
        printf '%s\n' 'first-id first' 'second-id second'
        ;;
    stop)
        cid="${4:-}"
        printf 'begin:%s\n' "$cid" >> "$BOXA_PID1_TEST_EVENT_LOG"
        : > "$BOXA_PID1_TEST_BARRIER/$cid"
        while [ "$(find "$BOXA_PID1_TEST_BARRIER" -type f | wc -l)" -lt 2 ]; do
            sleep 0.01
        done
        sleep 0.05
        printf 'end:%s\n' "$cid" >> "$BOXA_PID1_TEST_EVENT_LOG"
        [ "$cid" != first-id ]
        ;;
esac
STUB
chmod +x "$TMPROOT/bin/docker"

export BOXA_PID1_TEST_DOCKER_LOG="$DOCKER_LOG"
export BOXA_PID1_TEST_EVENT_LOG="$EVENT_LOG"
export BOXA_PID1_TEST_BARRIER="$TMPROOT/barrier"

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

XDG_RUNTIME_DIR="$TMPROOT/runtime" PATH="$TMPROOT/bin:$PATH" \
    bash "$SCRIPT_DIR/../scripts/boxa-entrypoint.sh" > "$TMPROOT/output" 2>&1 &
ENTRYPOINT_PID=$!
sleep 0.05
kill -TERM "$ENTRYPOINT_PID"

finished=false
for _ in $(seq 1 200); do
    if ! kill -0 "$ENTRYPOINT_PID" 2>/dev/null; then
        finished=true
        break
    fi
    sleep 0.01
done
if [ "$finished" = true ]; then
    wait "$ENTRYPOINT_PID"
    entrypoint_rc=$?
    ENTRYPOINT_PID=""
else
    entrypoint_rc=124
fi

assert_eq "fallback exits promptly after completed Inner container stops" "0" "$entrypoint_rc"
assert_eq "fallback discovers running containers only" "1" \
    "$(grep -c '^ps --format {{.ID}} {{.Names}}$' "$DOCKER_LOG" || true)"
assert_eq "fallback launches every graceful stop" "2" \
    "$(grep -c '^stop -t 30 \(first-id\|second-id\)$' "$DOCKER_LOG" || true)"
assert_eq "both stops begin before either finishes" "2" \
    "$(sed -n '/^end:/q; /^begin:/p' "$EVENT_LOG" | wc -l)"
assert_eq "fallback waits for every launched stop despite one failure" "2" \
    "$(grep -c '^end:' "$EVENT_LOG" || true)"
assert_eq "fallback performs no Compose discovery or removal" "0" \
    "$(grep -c '^\(compose\|inspect\|rm\|volume\) ' "$DOCKER_LOG" || true)"
assert_eq "outer Container is configured with a 45-second stop deadline" "1" \
    "$(grep -c -- '--stop-timeout 45' "$SCRIPT_DIR/../docker-run.sh" || true)"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll emergency PID 1 shutdown tests passed.\n'
