#!/bin/bash
# Plain-bash tests for non-interactive `boxa stop --all`.
# Usage: bash tests/stop-all.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

TEST_BOXA_DIR="$_TMPROOT/boxa"
mkdir -p "$TEST_BOXA_DIR/scripts" "$_TMPROOT/bin" "$_TMPROOT/home"
cp "$SCRIPT_DIR/../docker-run.sh" "$TEST_BOXA_DIR/docker-run.sh"
cp -R "$SCRIPT_DIR/../lib" "$TEST_BOXA_DIR/lib"

cat > "$_TMPROOT/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$BOXA_STOP_TEST_DOCKER_LOG"

case "${1:-}" in
    ps)
        if [[ " $* " == *" -a "* ]]; then
            if [ "${BOXA_STOP_TEST_FAIL_LIST:-}" = true ]; then
                exit 1
            fi
            if [ "${BOXA_STOP_TEST_EMPTY:-}" != true ]; then
                printf '%s\n' boxa-alpha boxa-beta boxa_traefik boxa_dns
            fi
        elif [[ " $* " == *" name=^boxa- "* ]]; then
            [ ! -f "$BOXA_STOP_TEST_STOPPED" ] \
                && printf '%s\n' boxa-alpha boxa-beta \
                || true
        else
            printf '%s\n' boxa_traefik boxa_dns
        fi
        ;;
    exec)
        if [ "${2:-}" = -u ] && [ "${3:-}" = root ] \
            && [ "${5:-}" = test ] && [ "${6:-}" = -f ]; then
            exit 1
        fi
        ;;
    inspect)
        exit 1
        ;;
    stop)
        if [[ " $* " == *" boxa-alpha "* ]]; then
            if [ "${BOXA_STOP_TEST_FAIL_BATCH:-}" = true ]; then
                exit 1
            fi
            : > "$BOXA_STOP_TEST_STOPPED"
        fi
        ;;
esac
STUB

cat > "$TEST_BOXA_DIR/scripts/closeout-agent-browser-on-stop.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$BOXA_STOP_TEST_CLOSEOUT_LOG"
STUB

cat > "$TEST_BOXA_DIR/scripts/deliver-allow-for-notification.sh" <<'STUB'
#!/bin/bash
printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" \
    >> "$BOXA_STOP_TEST_NOTIFICATION_LOG"
STUB

printf '%s\n' '#!/bin/sh' 'exit 0' > "$_TMPROOT/bin/setsid"
chmod +x "$TEST_BOXA_DIR/docker-run.sh" "$_TMPROOT/bin/docker" \
    "$_TMPROOT/bin/setsid" \
    "$TEST_BOXA_DIR/scripts/closeout-agent-browser-on-stop.sh" \
    "$TEST_BOXA_DIR/scripts/deliver-allow-for-notification.sh"

export BOXA_STOP_TEST_DOCKER_LOG="$_TMPROOT/docker.log"
export BOXA_STOP_TEST_STOPPED="$_TMPROOT/stopped"
export BOXA_STOP_TEST_CLOSEOUT_LOG="$_TMPROOT/closeout.log"
export BOXA_STOP_TEST_NOTIFICATION_LOG="$_TMPROOT/notification.log"

fail_count=0

run_boxa() {
    HOME="$_TMPROOT/home" PATH="$_TMPROOT/bin:$PATH" \
        bash "$TEST_BOXA_DIR/docker-run.sh" "$@"
}

reset_case() {
    rm -f "$BOXA_STOP_TEST_DOCKER_LOG" "$BOXA_STOP_TEST_STOPPED" \
        "$BOXA_STOP_TEST_CLOSEOUT_LOG" "$BOXA_STOP_TEST_NOTIFICATION_LOG"
    unset BOXA_STOP_TEST_EMPTY BOXA_STOP_TEST_FAIL_BATCH BOXA_STOP_TEST_FAIL_LIST
}

line_count() {
    local pattern="$1" file="$2"
    [ -f "$file" ] || { printf '0'; return; }
    grep -c -- "$pattern" "$file" || true
}

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

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      missing: %q\n      actual:  %q\n' \
            "$label" "$needle" "$haystack"
        fail_count=$((fail_count + 1))
    fi
}

reset_case
mkdir -p "$_TMPROOT/home/.config/boxa/traefik/dynamic" \
    "$_TMPROOT/home/.config/boxa/certs"
route_artifact="$_TMPROOT/home/.config/boxa/traefik/dynamic/boxa-alpha-3000.yml"
tls_artifact="$_TMPROOT/home/.config/boxa/traefik/dynamic/alpha-tls.yml"
cert_artifact="$_TMPROOT/home/.config/boxa/certs/alpha.pem"
: > "$route_artifact"
: > "$tls_artifact"
: > "$cert_artifact"
plain_output="$(run_boxa stop --all 2>&1)"
plain_rc=$?
assert_eq "--all exits successfully" "0" "$plain_rc"
assert_eq "outer containers stop in one docker invocation" "1" \
    "$(line_count '^stop -t 15 boxa-alpha boxa-beta$' "$BOXA_STOP_TEST_DOCKER_LOG")"
assert_eq "each Container runs its pre-stop closeout" "2" \
    "$(line_count '^boxa-' "$BOXA_STOP_TEST_CLOSEOUT_LOG")"
assert_contains "--all reports the first stopped Container" \
    "Stopped:boxa-alpha" "$plain_output"
assert_contains "--all reports the second stopped Container" \
    "Stopped:boxa-beta" "$plain_output"
assert_eq "--all stops idle Traefik" "1" \
    "$(line_count '^stop boxa_traefik$' "$BOXA_STOP_TEST_DOCKER_LOG")"
assert_eq "--all stops idle DNS" "1" \
    "$(line_count '^stop boxa_dns$' "$BOXA_STOP_TEST_DOCKER_LOG")"
assert_eq "--all does not remove volumes" "0" \
    "$(line_count '^volume rm ' "$BOXA_STOP_TEST_DOCKER_LOG")"
assert_eq "--all preserves route YAMLs" "present" \
    "$([ -f "$route_artifact" ] && printf present || printf missing)"
assert_eq "--all preserves HTTPS route artifacts" "present" \
    "$([ -f "$tls_artifact" ] && printf present || printf missing)"
assert_eq "--all preserves HTTPS certificates" "present" \
    "$([ -f "$cert_artifact" ] && printf present || printf missing)"
assert_eq "--all without reason sends no notification" "0" \
    "$(line_count '.' "$BOXA_STOP_TEST_NOTIFICATION_LOG")"

reset_case
reason_output="$(run_boxa stop --reason presleep --all 2>&1)"
reason_rc=$?
assert_eq "--reason parses before --all" "0" "$reason_rc"
assert_contains "reasoned stop still completes" "Stopped:boxa-beta" "$reason_output"
expected_notification=$'--notification\tBoxa closeout: presleep\tBoxes alpha, beta stopped before sleep/shutdown\t/var/log/boxa'
actual_notification="$(sed -n '1p' "$BOXA_STOP_TEST_NOTIFICATION_LOG")"
assert_eq "--reason triggers the Closeout notification" \
    "$expected_notification" "$actual_notification"

reset_case
project_output="$(run_boxa stop --all alpha 2>&1)"
project_rc=$?
assert_eq "--all with a project exits non-zero" "1" "$project_rc"
assert_contains "--all with a project has a clear error" \
    "boxa stop --all does not accept a project name." "$project_output"
assert_eq "rejected --all does not stop a Container" "0" \
    "$(line_count '^stop ' "$BOXA_STOP_TEST_DOCKER_LOG")"

reset_case
clean_output="$(run_boxa stop --clean --all 2>&1)"
clean_rc=$?
assert_eq "--all rejects cleanup semantics" "1" "$clean_rc"
assert_contains "--all cleanup rejection is clear" \
    "boxa stop --all does not support --clean." "$clean_output"

reset_case
export BOXA_STOP_TEST_FAIL_BATCH=true
run_boxa stop --all >/dev/null 2>&1
failure_rc=$?
assert_eq "docker stop failure exits non-zero" "1" "$failure_rc"
assert_eq "failed stop does not send a completion notification" "0" \
    "$(line_count '.' "$BOXA_STOP_TEST_NOTIFICATION_LOG")"

reset_case
export BOXA_STOP_TEST_EMPTY=true
run_boxa stop --all --reason presleep >/dev/null 2>&1
empty_rc=$?
assert_eq "--all with no Containers exits successfully" "0" "$empty_rc"
assert_eq "empty --all sends no notification" "0" \
    "$(line_count '.' "$BOXA_STOP_TEST_NOTIFICATION_LOG")"

reset_case
export BOXA_STOP_TEST_FAIL_LIST=true
run_boxa stop --all >/dev/null 2>&1
list_failure_rc=$?
assert_eq "docker container-list failure exits non-zero" "1" "$list_failure_rc"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll stop-all tests passed.\n'
