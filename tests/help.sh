#!/bin/bash
# Plain-bash assertions for docker-run.sh command help.
# Usage: bash tests/help.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA="$SCRIPT_DIR/../docker-run.sh"
_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

mkdir -p "$_TMPROOT/bin" "$_TMPROOT/home"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$_TMPROOT/bin/docker"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$_TMPROOT/bin/setsid"
chmod +x "$_TMPROOT/bin/docker" "$_TMPROOT/bin/setsid"

fail_count=0

run_boxa() {
    HOME="$_TMPROOT/home" PATH="$_TMPROOT/bin:$PATH" bash "$BOXA" "$@"
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

for command in agent-browser mcp allow-for mem doctor build ports connect; do
    direct_help="$(run_boxa "$command" --help)"
    help_command="$(run_boxa help "$command")"
    assert_eq "$command help forms match" "$help_command" "$direct_help"
done

agent_help="$(run_boxa help agent-browser)"
assert_contains "agent-browser lists blocked" \
    "blocked [--project|-p NAME]" "$agent_help"
assert_contains "agent-browser keeps ADR pointer" "See ADR 0010." "$agent_help"
assert_eq "agent-browser -h uses unified text" \
    "$agent_help" "$(run_boxa agent-browser -h)"

mcp_help="$(run_boxa help mcp)"
assert_contains "mcp lists reload" "reload      Re-stage changed MCP secrets" "$mcp_help"
assert_contains "mcp keeps ADR pointer" "ADR 0013" "$mcp_help"
assert_eq "mcp -h uses unified text" "$mcp_help" "$(run_boxa mcp -h)"

fallback_help="$(run_boxa help ls)"
assert_contains "fallback prints overview line" \
    "boxa ls                        List running containers" "$fallback_help"
assert_contains "fallback prints standard footer" \
    "Run 'boxa <command> --help' for details." "$fallback_help"

overview_help="$(run_boxa help)"
assert_contains "overview advertises command help" \
    "Run 'boxa <command> --help' for details." "$overview_help"

unknown_output="$(run_boxa help not-a-command 2>&1)"
unknown_rc=$?
assert_eq "unknown command exits 2" "2" "$unknown_rc"
assert_contains "unknown command is named" \
    "Unknown boxa command: not-a-command" "$unknown_output"
assert_contains "unknown command points at boxa help" \
    "Run 'boxa help' for the command overview." "$unknown_output"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll help tests passed.\n'
