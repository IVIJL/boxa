#!/bin/bash
# Plain-bash lifecycle assertions for per-box Docker Desktop Host connections.
# Usage: bash tests/connect-host.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOXA="$BOXA_DIR/docker-run.sh"
_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

mkdir -p "$_TMPROOT/home"
export BOXA_CONNECT_TEST_LOG="$_TMPROOT/docker.log"
export BOXA_CONNECT_TEST_HOST_IP="192.168.65.254"
: > "$BOXA_CONNECT_TEST_LOG"

# docker-run.sh is host-side; this stub records the privileged and node execs
# while presenting one running source Container. Resolution deliberately comes
# from the exec made inside that Container.
docker() {
    printf '%s\n' "$*" >> "$BOXA_CONNECT_TEST_LOG"
    case "${1:-}" in
        ps)
            case "$*" in
                *'{{.Names}}'*) printf '%s\n' 'boxa-source' ;;
            esac
            ;;
        exec)
            case "$*" in
                *'getent ahostsv4 host.docker.internal'*)
                    printf '%s\n' "$BOXA_CONNECT_TEST_HOST_IP"
                    ;;
            esac
            ;;
    esac
}
export -f docker

# Minimal iptables model for the durable-slot helpers. State contains only the
# accepted destination IP:port pairs; -S renders the final catch-all REJECT the
# start helper must insert before.
iptables() {
    local action="${1:-}" chain="${2:-}" ip="" port="" key="" arg
    shift 2 || true

    if [ "$action" = -S ] && [ "$chain" = OUTPUT ]; then
        printf '%s\n' \
            '-A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT' \
            '-A OUTPUT -j REJECT --reject-with icmp-port-unreachable'
        return 0
    fi

    if [ "$action" = -I ]; then
        shift
    fi
    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
            -d)
                shift
                ip="${1:-}"
                ;;
            --dport)
                shift
                port="${1:-}"
                ;;
        esac
        shift || true
    done
    key="${ip}:${port}"

    case "$action" in
        -D)
            if grep -qxF "$key" "$BOXA_CONNECT_IPTABLES_STATE" 2>/dev/null; then
                grep -vxF "$key" "$BOXA_CONNECT_IPTABLES_STATE" \
                    > "${BOXA_CONNECT_IPTABLES_STATE}.tmp" || true
                mv "${BOXA_CONNECT_IPTABLES_STATE}.tmp" "$BOXA_CONNECT_IPTABLES_STATE"
                return 0
            fi
            return 1
            ;;
        -I)
            printf '%s\n' "$key" >> "$BOXA_CONNECT_IPTABLES_STATE"
            ;;
        *)
            return 1
            ;;
    esac
}
export -f iptables

fail_count=0

run_boxa() {
    HOME="$_TMPROOT/home" bash "$BOXA" "$@"
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

count_log_matches() {
    local needle="$1"
    awk -v needle="$needle" 'index($0, needle) { count++ } END { print count + 0 }' \
        "$BOXA_CONNECT_TEST_LOG"
}

config_file="$_TMPROOT/home/.config/boxa/connect/source.tsv"

# Add: `host` stays literal, --name is the alias, and the naive default mirrors
# the Host port. The root firewall call is scoped to the freshly resolved IP
# and exact TCP port; socat setup remains a separate node-user exec.
add_output="$(run_boxa connect host 17777 --name keep-awake --from source)"
assert_contains "add reports Host target" \
    "Connected: boxa-source -> host:17777" "$add_output"
assert_eq "add persists four-column Host row" \
    $'keep-awake\thost\t17777\t17777' "$(cat "$config_file")"
assert_eq "add resolves inside source Container" "1" \
    "$(count_log_matches 'getent ahostsv4 host.docker.internal')"
assert_eq "add inserts exact root firewall slot" "1" \
    "$(count_log_matches '-u root boxa-source /usr/local/bin/start-host-connection-allow 192.168.65.254 17777')"
assert_eq "add starts one node-user forward" "1" \
    "$(count_log_matches '-u node -e TARGET_CONTAINER=192.168.65.254 -e TARGET_PORT=17777 -e LOCAL_PORT=17777')"

# An identical add repairs runtime state but upserts the same persisted row.
run_boxa connect host 17777 --name keep-awake --from source >/dev/null
assert_eq "repeated add leaves one persisted row" "1" \
    "$(awk 'END { print NR }' "$config_file")"
assert_eq "repeated add re-converges one exact firewall slot" "2" \
    "$(count_log_matches '/usr/local/bin/start-host-connection-allow 192.168.65.254 17777')"

export BOXA_CONNECT_IPTABLES_STATE="$_TMPROOT/iptables.state"
: > "$BOXA_CONNECT_IPTABLES_STATE"
bash "$BOXA_DIR/scripts/start-host-connection-allow.sh" 192.168.65.254 17777
bash "$BOXA_DIR/scripts/start-host-connection-allow.sh" 192.168.65.254 17777
assert_eq "firewall helper deduplicates repeated add" "1" \
    "$(awk 'END { print NR }' "$BOXA_CONNECT_IPTABLES_STATE")"
assert_eq "firewall helper scopes rule to exact IP and port" \
    "192.168.65.254:17777" "$(cat "$BOXA_CONNECT_IPTABLES_STATE")"
bash "$BOXA_DIR/scripts/stop-host-connection-allow.sh" 192.168.65.254 17777
assert_eq "firewall helper removes exact durable slot" "0" \
    "$(awk 'END { print NR }' "$BOXA_CONNECT_IPTABLES_STATE")"

# Extract only the connection helper block to exercise start-time replay
# without starting Docker. This is the function called by every attach/start
# path in docker-run.sh.
extracted="$_TMPROOT/connection-functions.sh"
awk '
    /^connection_config_file\(\) \{$/ { capture=1 }
    /^list_boxa_container_names\(\) \{$/ { exit }
    capture { print }
' "$BOXA" > "$extracted"
if [ ! -s "$extracted" ]; then
    printf 'FAIL  could not extract connection helper block\n'
    exit 1
fi
export CONNECT_CONFIG_DIR="$_TMPROOT/home/.config/boxa/connect"
# shellcheck source=/dev/null
source "$extracted"

BOXA_CONNECT_TEST_HOST_IP="192.168.65.253"
start_boxa_connections boxa-source >/dev/null
assert_eq "replay re-resolves Host IP" "1" \
    "$(count_log_matches '/usr/local/bin/start-host-connection-allow 192.168.65.253 17777')"
assert_eq "replay dials freshly resolved Host IP" "1" \
    "$(count_log_matches '-u node -e TARGET_CONTAINER=192.168.65.253 -e TARGET_PORT=17777 -e LOCAL_PORT=17777')"

connections_output="$(run_boxa connections)"
assert_contains "connections lists Host target" "host:17777" "$connections_output"
assert_contains "connections lists --name label" "keep-awake" "$connections_output"
assert_contains "connections keeps STATUS column" "STATUS" "$connections_output"

# Removal tears down the exact root slot and pid-backed forward before deleting
# the row. With no persisted row, a later replay performs no Docker calls.
BOXA_CONNECT_TEST_HOST_IP="192.168.65.254"
rm_output="$(run_boxa connect rm host 17777 --from source)"
assert_contains "rm reports removed Host target" \
    "Removed Host connection: boxa-source -> host:17777" "$rm_output"
assert_eq "rm invokes exact root firewall teardown" "1" \
    "$(count_log_matches '/usr/local/bin/stop-host-connection-allow 192.168.65.254 17777')"
assert_eq "rm invokes node forward teardown" "1" \
    "$(count_log_matches '-u node -e PID_FILE=/tmp/boxa-connect-17777.pid')"
assert_eq "rm drops persisted row" "0" "$(awk 'END { print NR }' "$config_file")"

calls_before_empty_replay="$(awk 'END { print NR }' "$BOXA_CONNECT_TEST_LOG")"
start_boxa_connections boxa-source >/dev/null
assert_eq "removed entry is not replayed" "$calls_before_empty_replay" \
    "$(awk 'END { print NR }' "$BOXA_CONNECT_TEST_LOG")"

connect_help="$(run_boxa help connect)"
assert_contains "help documents connect host" \
    "boxa connect host <port> [local-port]" "$connect_help"
assert_contains "help documents --name" "--name <label>" "$connect_help"
assert_contains "help documents Host rm" "boxa connect rm host <port>" "$connect_help"

overview_help="$(run_boxa help)"
assert_contains "overview documents connect host" \
    "boxa connect host <port> [local-port] [--name <label>]" "$overview_help"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll connect-host tests passed.\n'
