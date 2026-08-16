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
cp -R "$SCRIPT_DIR/../config" "$TEST_BOXA_DIR/config"

cat > "$_TMPROOT/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$BOXA_STOP_TEST_DOCKER_LOG"

case "${1:-}" in
    ps)
        if [ "${BOXA_STOP_TEST_RUNNING_ATTACH:-}" = true ]; then
            if [[ " $* " == *" name=^boxa-up-project$ "* ]]; then
                printf '%s\n' running-id
            fi
            exit 0
        fi
        if [ "${BOXA_STOP_TEST_UP:-}" = true ]; then
            exit 0
        fi
        if [[ " $* " == *" -a "* ]]; then
            if [ "${BOXA_STOP_TEST_FAIL_LIST:-}" = true ]; then
                exit 1
            fi
            if [ "${BOXA_STOP_TEST_EMPTY:-}" != true ]; then
                printf '%s\n' boxa-alpha boxa-beta boxa_traefik boxa_dns
            fi
        elif [[ " $* " == *" name=^boxa- "* ]]; then
            if [ ! -f "$BOXA_STOP_TEST_STOPPED" ]; then
                printf '%s\n' boxa-alpha boxa-beta
            elif [ "${BOXA_STOP_TEST_REMAINING:-}" = true ]; then
                printf '%s\n' boxa-beta
            fi
        else
            printf '%s\n' boxa_traefik boxa_dns
        fi
        ;;
    exec)
        if [ "${BOXA_STOP_TEST_RUNNING_ATTACH:-}" = true ]; then
            exit 0
        fi
        if [ "${BOXA_STOP_TEST_UP:-}" = true ] && [[ " $* " == *" stat -c %U /proc/1 "* ]]; then
            printf '%s\n' node
            exit 0
        fi
        if [ "${2:-}" = -u ] && [ "${3:-}" = root ] \
            && [ "${5:-}" = test ] && [ "${6:-}" = -f ]; then
            exit 1
        fi
        ;;
    inspect)
        if [ "${BOXA_STOP_TEST_UP:-}" = true ] && [[ "$*" == *".State.Status"* ]]; then
            printf '%s\n' running
            exit 0
        fi
        exit 1
        ;;
    stop)
        if [[ " $* " == *" boxa-alpha "* ]]; then
            if [ "${BOXA_STOP_TEST_FAIL_BATCH:-}" = true ]; then
                exit 1
            fi
            : > "$BOXA_STOP_TEST_STOPPED"
            # Partial failure: the batch stopped, but one Container vanished
            # mid-run, so docker itself still exits non-zero.
            if [ "${BOXA_STOP_TEST_FAIL_PARTIAL:-}" = true ]; then
                exit 1
            fi
        fi
        ;;
esac
STUB

cat > "$_TMPROOT/bin/curl" <<'STUB'
#!/bin/bash
[ "${BOXA_STOP_TEST_DAEMON_REACHABLE:-true}" = true ] || exit 7
case "${*: -1}" in
    */v1/status)
        printf '%s\n' '{"activeHolders":[],"isInhibited":false}'
        ;;
esac
STUB

cat > "$TEST_BOXA_DIR/scripts/closeout-agent-browser-on-stop.sh" <<'STUB'
#!/bin/bash
if [ "${BOXA_STOP_TEST_PREP_BARRIER:-}" = true ]; then
    printf 'begin:%s\n' "$1" >> "$BOXA_STOP_TEST_PREP_LOG"
    : > "$BOXA_STOP_TEST_PREP_DIR/$1"
    while [ "$(find "$BOXA_STOP_TEST_PREP_DIR" -type f | wc -l)" -lt 2 ]; do
        sleep 0.01
    done
    printf 'end:%s\n' "$1" >> "$BOXA_STOP_TEST_PREP_LOG"
fi
printf '%s\n' "$1" >> "$BOXA_STOP_TEST_CLOSEOUT_LOG"
STUB

cat > "$TEST_BOXA_DIR/scripts/deliver-allow-for-notification.sh" <<'STUB'
#!/bin/bash
printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" \
    >> "$BOXA_STOP_TEST_NOTIFICATION_LOG"
STUB

printf '%s\n' '#!/bin/sh' 'exit 0' > "$_TMPROOT/bin/setsid"
chmod +x "$TEST_BOXA_DIR/docker-run.sh" "$_TMPROOT/bin/docker" "$_TMPROOT/bin/curl" \
    "$_TMPROOT/bin/setsid" \
    "$TEST_BOXA_DIR/scripts/closeout-agent-browser-on-stop.sh" \
    "$TEST_BOXA_DIR/scripts/deliver-allow-for-notification.sh"

export BOXA_STOP_TEST_DOCKER_LOG="$_TMPROOT/docker.log"
export BOXA_STOP_TEST_STOPPED="$_TMPROOT/stopped"
export BOXA_STOP_TEST_CLOSEOUT_LOG="$_TMPROOT/closeout.log"
export BOXA_STOP_TEST_NOTIFICATION_LOG="$_TMPROOT/notification.log"
export BOXA_STOP_TEST_PREP_DIR="$_TMPROOT/prep"
export BOXA_STOP_TEST_PREP_LOG="$_TMPROOT/prep.log"

fail_count=0

run_boxa() {
    HOME="$_TMPROOT/home" PATH="$_TMPROOT/bin:$PATH" \
        bash "$TEST_BOXA_DIR/docker-run.sh" "$@"
}

reset_case() {
    rm -f "$BOXA_STOP_TEST_DOCKER_LOG" "$BOXA_STOP_TEST_STOPPED" \
        "$BOXA_STOP_TEST_CLOSEOUT_LOG" "$BOXA_STOP_TEST_NOTIFICATION_LOG" \
        "$BOXA_STOP_TEST_PREP_LOG"
    rm -rf "$BOXA_STOP_TEST_PREP_DIR"
    mkdir -p "$BOXA_STOP_TEST_PREP_DIR"
    unset BOXA_STOP_TEST_EMPTY BOXA_STOP_TEST_FAIL_BATCH BOXA_STOP_TEST_FAIL_LIST \
        BOXA_STOP_TEST_FAIL_PARTIAL BOXA_STOP_TEST_PREP_BARRIER \
        BOXA_STOP_TEST_REMAINING BOXA_STOP_TEST_UP BOXA_STOP_TEST_DAEMON_REACHABLE \
        BOXA_STOP_TEST_RUNNING_ATTACH
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
export BOXA_STOP_TEST_UP=true
up_project="$_TMPROOT/up-project"
mkdir -p "$up_project"
up_output="$(run_boxa "$up_project" 2>&1)"
up_rc=$?
assert_eq "fresh Container start exits successfully" "0" "$up_rc"
if [ "$up_rc" -ne 0 ]; then
    printf '%s\n' "$up_output"
fi

reset_case
export BOXA_STOP_TEST_RUNNING_ATTACH=true
running_project="$_TMPROOT/up-project"
mkdir -p "$running_project"
running_output="$(run_boxa "$running_project" 2>&1)"
running_rc=$?
assert_eq "attach to a running Container exits successfully" "0" "$running_rc"
if [ "$running_rc" -ne 0 ]; then
    printf '%s\n' "$running_output"
fi

reset_case
export BOXA_STOP_TEST_UP=true
export BOXA_STOP_TEST_DAEMON_REACHABLE=false
unreachable_up_project="$_TMPROOT/unreachable-up-project"
unreachable_up_errors="$_TMPROOT/unreachable-up-errors"
mkdir -p "$unreachable_up_project"
run_boxa "$unreachable_up_project" >/dev/null 2>"$unreachable_up_errors"
unreachable_up_rc=$?
assert_eq "unreachable daemon does not fail Container start" "0" "$unreachable_up_rc"
assert_eq "unreachable daemon is silent during Container start" "" \
    "$(cat "$unreachable_up_errors")"

reset_case
export BOXA_STOP_TEST_PREP_BARRIER=true
run_boxa stop --all >/dev/null 2>&1
parallel_rc=$?
assert_eq "parallel Container prep completes" "0" "$parallel_rc"
assert_eq "both Container preparations start before either finishes" "2" \
    "$(sed -n '/^end:/q; /^begin:/p' "$BOXA_STOP_TEST_PREP_LOG" | wc -l)"

reset_case
export BOXA_STOP_TEST_PREP_BARRIER=true
export BOXA_PICKER_FZF=0
export BOXA_PICKER_TEST_CHOICE=a
run_boxa stop >/dev/null 2>&1
interactive_parallel_rc=$?
assert_eq "interactive Stop all completes" "0" "$interactive_parallel_rc"
assert_eq "interactive Stop all preparations run concurrently" "2" \
    "$(sed -n '/^end:/q; /^begin:/p' "$BOXA_STOP_TEST_PREP_LOG" | wc -l)"
assert_eq "interactive Stop all stops each Container in its own invocation" "2" \
    "$(line_count '^stop -t 15 boxa-\(alpha\|beta\)$' "$BOXA_STOP_TEST_DOCKER_LOG")"
unset BOXA_PICKER_FZF BOXA_PICKER_TEST_CHOICE

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
assert_eq "each outer Container stops in its own docker invocation" "2" \
    "$(line_count '^stop -t 15 boxa-\(alpha\|beta\)$' "$BOXA_STOP_TEST_DOCKER_LOG")"
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
export BOXA_STOP_TEST_REMAINING=true
run_boxa stop alpha >/dev/null 2>&1
remaining_rc=$?
assert_eq "single stop with a remaining Container succeeds" "0" "$remaining_rc"

reset_case
export BOXA_STOP_TEST_DAEMON_REACHABLE=false
unreachable_errors="$_TMPROOT/unreachable-errors"
run_boxa stop --all >/dev/null 2>"$unreachable_errors"
unreachable_rc=$?
assert_eq "unreachable daemon does not fail stop" "0" "$unreachable_rc"
assert_eq "unreachable daemon is silent" "" "$(cat "$unreachable_errors")"

reset_case
reason_output="$(run_boxa stop --reason presleep --all 2>&1)"
reason_rc=$?
assert_eq "--reason parses before --all" "0" "$reason_rc"
assert_contains "reasoned stop still completes" "Stopped:boxa-beta" "$reason_output"
expected_notification=$'--notification\tBoxa closeout: presleep\tBoxes alpha, beta stopped before shutdown\t/var/log/boxa'
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
mkdir -p "$_TMPROOT/home/.config/boxa/traefik/dynamic" \
    "$_TMPROOT/home/.config/boxa/certs"
interactive_route="$_TMPROOT/home/.config/boxa/traefik/dynamic/boxa-alpha-3000.yml"
interactive_tls="$_TMPROOT/home/.config/boxa/traefik/dynamic/alpha-tls.yml"
interactive_cert="$_TMPROOT/home/.config/boxa/certs/alpha.pem"
: > "$interactive_route"
: > "$interactive_tls"
: > "$interactive_cert"
export BOXA_PICKER_FZF=0
export BOXA_PICKER_TEST_CHOICE=a
interactive_clean_output="$(run_boxa stop --clean 2>&1)"
interactive_clean_rc=$?
assert_eq "interactive Stop all keeps --clean semantics" "0" "$interactive_clean_rc"
assert_contains "interactive clean reports removed data" \
    "Stopped + data removed:boxa-alpha" "$interactive_clean_output"
assert_eq "interactive clean removes project volumes" true \
    "$([ "$(line_count '^volume rm ' "$BOXA_STOP_TEST_DOCKER_LOG")" -gt 0 ] && printf true || printf false)"
assert_eq "interactive clean removes route YAMLs" missing \
    "$([ -f "$interactive_route" ] && printf present || printf missing)"
assert_eq "interactive clean removes HTTPS route artifacts" missing \
    "$([ -f "$interactive_tls" ] && printf present || printf missing)"
assert_eq "interactive clean removes HTTPS certificates" missing \
    "$([ -f "$interactive_cert" ] && printf present || printf missing)"
unset BOXA_PICKER_FZF BOXA_PICKER_TEST_CHOICE

reset_case
export BOXA_STOP_TEST_FAIL_BATCH=true
run_boxa stop --all >/dev/null 2>&1
failure_rc=$?
assert_eq "docker stop failure exits non-zero" "1" "$failure_rc"
assert_eq "failed stop does not send a completion notification" "0" \
    "$(line_count '.' "$BOXA_STOP_TEST_NOTIFICATION_LOG")"

reset_case
mkdir -p "$_TMPROOT/home/.config/boxa/traefik/dynamic" \
    "$_TMPROOT/home/.config/boxa/certs"
partial_route="$_TMPROOT/home/.config/boxa/traefik/dynamic/boxa-alpha-3000.yml"
partial_cert="$_TMPROOT/home/.config/boxa/certs/alpha.pem"
: > "$partial_route"
: > "$partial_cert"
export BOXA_STOP_TEST_FAIL_PARTIAL=true
export BOXA_PICKER_FZF=0
export BOXA_PICKER_TEST_CHOICE=a
partial_output="$(run_boxa stop --clean 2>&1)"
partial_rc=$?
assert_eq "interactive Stop all survives a failed docker stop" "0" "$partial_rc"
assert_contains "failed interactive stop still cleans the first Container" \
    "Stopped + data removed:boxa-alpha" "$partial_output"
assert_contains "failed interactive stop still cleans the second Container" \
    "Stopped + data removed:boxa-beta" "$partial_output"
assert_eq "failed interactive stop still removes swept Containers" "2" \
    "$(line_count '^rm boxa-' "$BOXA_STOP_TEST_DOCKER_LOG")"
assert_eq "failed interactive stop still removes project volumes" true \
    "$([ "$(line_count '^volume rm ' "$BOXA_STOP_TEST_DOCKER_LOG")" -gt 0 ] && printf true || printf false)"
assert_eq "failed interactive stop still removes route YAMLs" missing \
    "$([ -f "$partial_route" ] && printf present || printf missing)"
assert_eq "failed interactive stop still removes HTTPS certificates" missing \
    "$([ -f "$partial_cert" ] && printf present || printf missing)"
assert_eq "failed interactive stop still stops idle Traefik" "1" \
    "$(line_count '^stop boxa_traefik$' "$BOXA_STOP_TEST_DOCKER_LOG")"
assert_eq "failed interactive stop still stops idle DNS" "1" \
    "$(line_count '^stop boxa_dns$' "$BOXA_STOP_TEST_DOCKER_LOG")"
unset BOXA_PICKER_FZF BOXA_PICKER_TEST_CHOICE

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
