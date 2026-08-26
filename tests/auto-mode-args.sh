#!/bin/bash
# Plain-bash assertions for auto-mode positional argument validation.
# Usage: bash tests/auto-mode-args.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

mkdir -p "$_TMPROOT/bin" "$_TMPROOT/home"
export AUTO_MODE_TEST_DOCKER_LOG="$_TMPROOT/docker.log"
# shellcheck disable=SC2016  # Variables expand when the generated stub runs.
printf '%s\n' \
    '#!/bin/sh' \
    'printf '\''%s\n'\'' "$*" >> "$AUTO_MODE_TEST_DOCKER_LOG"' \
    'exit 0' > "$_TMPROOT/bin/docker"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$_TMPROOT/bin/setsid"
chmod +x "$_TMPROOT/bin/docker" "$_TMPROOT/bin/setsid"

validator_extracted="$_TMPROOT/validate_auto_mode_args.sh"
awk '
    /^_boxa::validate_auto_mode_args\(\) \{$/ { capture=1 }
    capture { print }
    capture && /^\}$/ { exit }
' "$BOXA_DIR/docker-run.sh" > "$validator_extracted"

fail_count=0
expected_reorder=$'Unexpected arguments after \'demo\': ssh off\nDid you mean: boxa ssh off demo'

run_boxa() {
    HOME="$_TMPROOT/home" PATH="$_TMPROOT/bin:$PATH" \
        bash "$BOXA_DIR/docker-run.sh" "$@"
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

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      unexpected: %q\n      actual:     %q\n' \
            "$label" "$needle" "$haystack"
        fail_count=$((fail_count + 1))
    fi
}

if [ ! -s "$validator_extracted" ]; then
    printf 'FAIL  could not extract _boxa::validate_auto_mode_args from docker-run.sh\n'
    fail_count=$((fail_count + 1))
else
    # shellcheck source=/dev/null
    source "$validator_extracted"

    for label_and_target in "bare boxa|" "single project|demo" "single path|/tmp/demo project"; do
        label="${label_and_target%%|*}"
        target="${label_and_target#*|}"
        if [ -n "$target" ]; then
            output="$(_boxa::validate_auto_mode_args "$target" 2>&1)"
        else
            output="$(_boxa::validate_auto_mode_args 2>&1)"
        fi
        rc=$?
        assert_eq "$label succeeds" 0 "$rc"
        assert_eq "$label stays silent" "" "$output"
    done

    output="$(_boxa::validate_auto_mode_args demo ssh off 2>&1)"
    rc=$?
    assert_eq "known subcommand rejects trailing args" 1 "$rc"
    assert_eq "known subcommand names args and suggests reorder" \
        "$expected_reorder" "$output"

    output="$(_boxa::validate_auto_mode_args demo blah 2>&1)"
    rc=$?
    assert_eq "unknown trailing arg rejects" 1 "$rc"
    assert_eq "unknown trailing arg is named" \
        "Unexpected arguments after 'demo': blah" "$output"
    assert_not_contains "unknown trailing arg has no hint" "Did you mean:" "$output"

    known_subcommands=(
        ls mem ssh forge stop remove port ports connect connections allow deny
        blocked allow-for agent-browser mcp cursor code ssh-config clip
        claude-token build update doctor keep-awake dns-install dns-status
        dns-uninstall uninstall prune sync-skills help
    )
    for subcommand in "${known_subcommands[@]}"; do
        output="$(_boxa::validate_auto_mode_args demo "$subcommand" argument 2>&1)"
        assert_eq "$subcommand gets reorder hint" \
            "Did you mean: boxa $subcommand argument demo" "${output##*$'\n'}"
    done
fi

: > "$AUTO_MODE_TEST_DOCKER_LOG"
output="$(run_boxa demo ssh off 2>&1)"
rc=$?
assert_eq "full CLI rejects known trailing args" 1 "$rc"
assert_eq "full CLI prints usage error and reorder hint" \
    "$expected_reorder" "$output"
docker_calls="$(< "$AUTO_MODE_TEST_DOCKER_LOG")"
assert_not_contains "rejected args do not attach" "exec " "$docker_calls"
assert_not_contains "rejected args do not create" "run " "$docker_calls"
assert_not_contains "rejected args do not restart" "start " "$docker_calls"

output="$(run_boxa demo blah 2>&1)"
rc=$?
assert_eq "full CLI rejects unknown trailing arg" 1 "$rc"
assert_eq "full CLI omits hint for unknown trailing arg" \
    "Unexpected arguments after 'demo': blah" "$output"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count" >&2
    exit 1
fi

printf '\nAll auto-mode argument tests passed.\n'
