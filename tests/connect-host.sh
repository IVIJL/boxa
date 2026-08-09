#!/bin/bash
# Plain-bash lifecycle assertions for Docker Desktop and native-Docker Host connections.
# Usage: bash tests/connect-host.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOXA="$BOXA_DIR/docker-run.sh"
_TMPROOT="$(mktemp -d)"
# This suite drives the real relay and doctor helpers against mock daemons
# while reading the developer's own keep-awake state. Every unreachable-daemon
# case would otherwise reach the Windows firewall self-heal and raise a UAC
# dialog mid-run, so the opt-out covers the whole file.
export BOXA_KEEP_AWAKE_SKIP_FIREWALL_HEAL=1
cleanup() {
    local pid_file pid
    for pid_file in "$_TMPROOT"/mock-socat-child-*.pid; do
        [ -f "$pid_file" ] || continue
        pid="$(cat "$pid_file")"
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    if [ -n "${BOXA_CONNECT_TEST_CONTAINER_PID_FILE:-}" ]; then
        rm -f "$BOXA_CONNECT_TEST_CONTAINER_PID_FILE"
    fi
    rm -rf "$_TMPROOT"
}
trap cleanup EXIT

mkdir -p "$_TMPROOT/home"
export BOXA_CONNECT_TEST_LOG="$_TMPROOT/docker.log"
export BOXA_CONNECT_TEST_HOST_IP="192.168.65.254"
export BOXA_CONNECT_TEST_BOUND_PORTS=""
export BOXA_CONNECT_TEST_FORWARD_PORTS=""
export BOXA_CONNECT_TEST_HOST_DOWN_PORTS=""
export BOXA_CONNECT_TEST_RULE_MISSING_PORTS=""
export BOXA_CONNECT_TEST_CONTAINERS="boxa-source"
export BOXA_CONNECT_TEST_UFW_ACTIVE=false
export BOXA_CONNECT_TEST_MISSING_SOCAT=false
export BOXA_CONNECT_TEST_HELPERS_MISSING=false
export BOXA_CONNECT_TEST_START_ALLOW_FAIL_PORTS=""
export BOXA_CONNECT_TEST_STOP_ALLOW_FAIL_PORTS=""
export BOXA_CONNECT_TEST_STOP_ALLOW_FAIL_CONTAINERS=""
export BOXA_CONNECT_TEST_MISSING_PYTHON=false
export BOXA_CONNECT_TEST_MISSING_IP=false
export BOXA_CONNECT_TEST_MISSING_SETSID=false
export BOXA_CONNECT_TEST_INTERFACE_IPS="127.0.0.1"
export BOXA_CONNECT_TEST_EXEC_NODE_TEARDOWN=false
export BOXA_CONNECT_TEST_DOCTOR_KEEP_AWAKE=false
: > "$BOXA_CONNECT_TEST_LOG"

# Keep list_listening_ports_in_container's timeout path compatible with the
# exported docker function used by this test harness.
timeout() {
    shift
    "$@"
}
export -f timeout

command() {
    if [ "$BOXA_CONNECT_TEST_MISSING_SOCAT" = true ] \
        && [ "${1:-}" = -v ] && [ "${2:-}" = socat ]; then
        return 1
    fi
    if [ "$BOXA_CONNECT_TEST_MISSING_PYTHON" = true ] \
        && [ "${1:-}" = -v ] && [ "${2:-}" = python3 ]; then
        return 1
    fi
    if [ "$BOXA_CONNECT_TEST_MISSING_IP" = true ] \
        && [ "${1:-}" = -v ] && [ "${2:-}" = ip ]; then
        return 1
    fi
    if [ "$BOXA_CONNECT_TEST_MISSING_SETSID" = true ] \
        && [ "${1:-}" = -v ] && [ "${2:-}" = setsid ]; then
        return 1
    fi
    builtin command "$@"
}
export -f command

ip() {
    local address
    if [ "${1:-}" = route ]; then
        printf 'default via %s dev eth0\n' \
            "${BOXA_CONNECT_TEST_KEEP_AWAKE_GATEWAY:-127.0.0.3}"
        return 0
    fi
    for address in $BOXA_CONNECT_TEST_INTERFACE_IPS; do
        printf '    inet %s/24 scope global eth0\n' "$address"
    done
}
export -f ip

# docker-run.sh is host-side; this stub records the privileged and node execs
# while presenting one running source Container. Resolution deliberately comes
# from the exec made inside that Container.
docker() {
    printf '%s\n' "$*" >> "$BOXA_CONNECT_TEST_LOG"
    case "${1:-}" in
        ps)
            local container filter="" candidate
            for candidate in "$@"; do
                case "$candidate" in
                    name=^boxa-*) filter="${candidate#name=^}"; filter="${filter%\$}" ;;
                esac
            done
            while IFS= read -r container; do
                [ -n "$container" ] || continue
                if [ -z "$filter" ] || { [ "$filter" = "boxa-" ] && [[ "$container" == boxa-* ]]; } \
                    || [ "$container" = "$filter" ]; then
                    case "$*" in
                        *'{{.Names}}'*) printf '%s\n' "$container" ;;
                        *'{{.ID}}'*) printf '%s-id\n' "$container" ;;
                    esac
                fi
            done <<< "${BOXA_CONNECT_TEST_CONTAINERS//,/$'\n'}"
            ;;
        exec)
            local helper_port="${*: -1}"
            if [ "$BOXA_CONNECT_TEST_EXEC_NODE_TEARDOWN" = true ]; then
                local exec_local_port="" exec_pid_file="" argument
                for argument in "$@"; do
                    case "$argument" in
                        LOCAL_PORT=*) exec_local_port="${argument#LOCAL_PORT=}" ;;
                        PID_FILE=*) exec_pid_file="${argument#PID_FILE=}" ;;
                    esac
                done
                if [ -n "$exec_pid_file" ]; then
                    LOCAL_PORT="$exec_local_port" PID_FILE="$exec_pid_file" \
                        bash -lc "${*: -1}"
                    return
                fi
            fi
            case "$*" in
                *'test -x /usr/local/bin/start-host-connection-allow'*)
                    if [ "$BOXA_CONNECT_TEST_HELPERS_MISSING" = true ]; then
                        return 1
                    fi
                    return 0
                    ;;
                *'/usr/local/bin/start-host-connection-allow '*)
                    case ",${BOXA_CONNECT_TEST_START_ALLOW_FAIL_PORTS}," in
                        *",${helper_port},"*) return 1 ;;
                    esac
                    ;;
                *'/usr/local/bin/stop-host-connection-allow '*)
                    case ",${BOXA_CONNECT_TEST_STOP_ALLOW_FAIL_PORTS}," in
                        *",${helper_port},"*) return 1 ;;
                    esac
                    local fail_container
                    for fail_container in ${BOXA_CONNECT_TEST_STOP_ALLOW_FAIL_CONTAINERS//,/ }; do
                        case " $* " in
                            *" ${fail_container} "*) return 1 ;;
                        esac
                    done
                    ;;
            esac
            case "$*" in
                *'getent ahostsv4 host.docker.internal'*)
                    printf '%s\n' "$BOXA_CONNECT_TEST_HOST_IP"
                    ;;
                *'iptables -C OUTPUT -p tcp -d '*)
                    local previous="" rule_port="" argument
                    for argument in "$@"; do
                        if [ "$previous" = --dport ]; then
                            rule_port="$argument"
                            break
                        fi
                        previous="$argument"
                    done
                    case ",${BOXA_CONNECT_TEST_RULE_MISSING_PORTS}," in
                        *",${rule_port},"*) return 1 ;;
                    esac
                    ;;
                *'/dev/tcp/127.0.0.1/'*'LOCAL_PORT'*)
                    local_port=""
                    for argument in "$@"; do
                        case "$argument" in
                            LOCAL_PORT=*) local_port="${argument#LOCAL_PORT=}" ;;
                        esac
                    done
                    case ",${BOXA_CONNECT_TEST_HOST_DOWN_PORTS}," in
                        *",${local_port},"*) return 1 ;;
                    esac
                    ;;
                *'cat /proc/net/tcp /proc/net/tcp6'*)
                    local port
                    for port in ${BOXA_CONNECT_TEST_BOUND_PORTS//,/ }; do
                        printf '  0: 0100007F:%04X 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 0 1 0000000000000000 100 0 0 10 0\n' "$port"
                    done
                    ;;
                *'for pid_file in /tmp/boxa-connect-'*)
                    printf '%s\n' "${BOXA_CONNECT_TEST_FORWARD_PORTS//,/$'\n'}"
                    ;;
            esac
            ;;
        network)
            if [ "${2:-}" = inspect ] && [ "${3:-}" = devproxy ]; then
                printf '%s\n' '172.18.0.0/24 '
            fi
            ;;
    esac
}
export -f docker

sudo() {
    "$@"
}
export -f sudo

ufw() {
    printf 'ufw %s\n' "$*" >> "$BOXA_CONNECT_TEST_LOG"
    case "${1:-}" in
        status)
            if [ "$BOXA_CONNECT_TEST_UFW_ACTIVE" = true ]; then
                printf '%s\n' 'Status: active'
            else
                printf '%s\n' 'Status: inactive'
            fi
            ;;
        allow)
            printf '%s\n' 'Rule added'
            ;;
        delete)
            printf '%s\n' 'Rule deleted'
            ;;
    esac
}
export -f ufw

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

count_log_matches() {
    local needle="$1"
    awk -v needle="$needle" 'index($0, needle) { count++ } END { print count + 0 }' \
        "$BOXA_CONNECT_TEST_LOG"
}

config_file="$_TMPROOT/home/.config/boxa/connect/source.tsv"

# Add: `host` stays literal, --name is the alias, and a free Host port mirrors
# locally. The root firewall call is scoped to the freshly resolved IP
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

# Boxes from a pre-Host-connection image lack the baked-in helpers; connect
# injects both from the repo copy before exec'ing them (issue 15).
export BOXA_CONNECT_TEST_HELPERS_MISSING=true
inject_output="$(run_boxa connect host 17777 --name keep-awake --from source)"
assert_contains "old-image add still reports Host target" \
    "Connected: boxa-source -> host:17777" "$inject_output"
assert_eq "old-image add copies start helper into place" "1" \
    "$(count_log_matches "cp $BOXA_DIR/scripts/start-host-connection-allow.sh boxa-source:/usr/local/bin/start-host-connection-allow")"
assert_eq "old-image add copies stop helper into place" "1" \
    "$(count_log_matches "cp $BOXA_DIR/scripts/stop-host-connection-allow.sh boxa-source:/usr/local/bin/stop-host-connection-allow")"
assert_eq "old-image add fixes helper ownership and mode" "1" \
    "$(count_log_matches 'chown root:root /usr/local/bin/start-host-connection-allow')"
export BOXA_CONNECT_TEST_HELPERS_MISSING=false

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
export HOST_CONNECTION_STATE_DIR="$_TMPROOT/home/.local/state/boxa/host-connections"
# shellcheck source=/dev/null
source "$extracted"
# The extracted docker-run helper block calls the same shared platform and
# keep-awake probe modules that docker-run.sh sources at startup.
# shellcheck source=../lib/host-platform.sh disable=SC1091
source "$BOXA_DIR/lib/host-platform.sh"
# shellcheck source=../lib/keep-awake-probe.sh disable=SC1091
source "$BOXA_DIR/lib/keep-awake-probe.sh"

wait_for_test_daemon() {
    local address="$1" port="$2" attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        : "$attempt"
        keep_awake_probe::status "$address" "$port" >/dev/null && return 0
        sleep 0.02
    done
    return 1
}

# The in-Container teardown executes through docker in production. Run that
# exact embedded shell against a detached socat listener with a live handler.
container_forward_child_file="$_TMPROOT/mock-socat-child-container.pid"
socat TCP-LISTEN:64999,bind=127.0.0.1,reuseaddr,fork EXEC:"sleep 300" \
    >/dev/null 2>&1 &
container_forward_pid=$!
container_forward_client_pid=""
for _attempt in $(seq 1 50); do
    if (exec 3<>/dev/tcp/127.0.0.1/64999) 2>/dev/null; then
        bash -c 'exec 3<>/dev/tcp/127.0.0.1/64999; sleep 300' &
        container_forward_client_pid=$!
        break
    fi
    sleep 0.01
done
for _attempt in $(seq 1 50); do
    container_forward_child_pid="$(pgrep -P "$container_forward_pid" | head -1)"
    [ -n "$container_forward_child_pid" ] && break
    sleep 0.01
done
printf '%s\n' "$container_forward_child_pid" > "$container_forward_child_file"
BOXA_CONNECT_TEST_CONTAINER_PID_FILE="/tmp/boxa-connect-64999.pid"
printf '%s\n' "$container_forward_pid" > "$BOXA_CONNECT_TEST_CONTAINER_PID_FILE"
BOXA_CONNECT_TEST_EXEC_NODE_TEARDOWN=true
stop_container_connection boxa-source 64999
BOXA_CONNECT_TEST_EXEC_NODE_TEARDOWN=false
assert_eq "container forward teardown stops listener" "false" \
    "$(kill -0 "$container_forward_pid" 2>/dev/null && echo true || echo false)"
assert_eq "container forward teardown stops listener child" "false" \
    "$(kill -0 "$container_forward_child_pid" 2>/dev/null && echo true || echo false)"
kill "$container_forward_client_pid" 2>/dev/null || true

# A reused PID must only lose its stale record; the unrelated process survives.
sleep 300 &
stale_container_pid=$!
printf '%s\n' "$stale_container_pid" > "$BOXA_CONNECT_TEST_CONTAINER_PID_FILE"
BOXA_CONNECT_TEST_EXEC_NODE_TEARDOWN=true
stale_container_output="$(stop_container_connection boxa-source 64999 2>&1)"
assert_eq "container teardown preserves mismatched PID" "true" \
    "$(kill -0 "$stale_container_pid" 2>/dev/null && echo true || echo false)"
assert_eq "container teardown removes mismatched PID file" "false" \
    "$([ -f "$BOXA_CONNECT_TEST_CONTAINER_PID_FILE" ] && echo true || echo false)"
assert_contains "container teardown reports mismatched PID" \
    "process identity does not match local port 64999" "$stale_container_output"
kill "$stale_container_pid" 2>/dev/null || true
BOXA_CONNECT_TEST_EXEC_NODE_TEARDOWN=false

# Host-side persisted state has the same PID-reuse protection without relying
# on /proc-only process inspection, so the implementation remains macOS-safe.
sleep 300 &
stale_host_pid=$!
stale_host_port=18985
mkdir -p "$HOST_CONNECTION_STATE_DIR"
printf '127.0.0.2\t%s\t\tfalse\n' "$stale_host_pid" \
    > "$(host_connection_state_file "$stale_host_port")"
stale_host_output="$(stop_host_connection_host_side "$stale_host_port" 2>&1)"
assert_eq "host teardown preserves mismatched PID" "true" \
    "$(kill -0 "$stale_host_pid" 2>/dev/null && echo true || echo false)"
assert_eq "host teardown removes mismatched state" "false" \
    "$([ -f "$(host_connection_state_file "$stale_host_port")" ] && echo true || echo false)"
assert_contains "host teardown reports mismatched PID" \
    "process identity does not match 127.0.0.2:${stale_host_port}" "$stale_host_output"
kill "$stale_host_pid" 2>/dev/null || true

# Behavioral platform detection: a VM-owned address rejects the host bind, so
# no host relay state or ufw INPUT slot is created.
vm_host_port=18990
BOXA_CONNECT_TEST_UFW_ACTIVE=true
vm_ufw_calls_before="$(count_log_matches 'ufw allow proto tcp')"
start_host_connection_host_side 192.168.65.254 "$vm_host_port"
assert_eq "VM-owned Host IP leaves no relay state" "false" \
    "$([ -f "$(host_connection_state_file "$vm_host_port")" ] && echo true || echo false)"
assert_eq "VM-owned Host IP leaves ufw untouched" "$vm_ufw_calls_before" \
    "$(count_log_matches 'ufw allow proto tcp')"

# Python is an optional first-choice bind probe. Without it, Linux interface
# membership still distinguishes host-owned from VM-owned addresses; if no
# supported probe exists, setup fails with an actionable diagnostic.
BOXA_CONNECT_TEST_MISSING_PYTHON=true
BOXA_CONNECT_TEST_INTERFACE_IPS="127.0.0.2"
fallback_native_port=18988
start_host_connection_host_side 127.0.0.2 "$fallback_native_port"
assert_eq "missing python falls back to Linux interface ownership" true \
    "$([ -f "$(host_connection_state_file "$fallback_native_port")" ] && echo true || echo false)"
stop_host_connection_host_side "$fallback_native_port"
BOXA_CONNECT_TEST_INTERFACE_IPS="10.0.0.2"
fallback_desktop_port=18989
start_host_connection_host_side 192.168.65.254 "$fallback_desktop_port"
assert_eq "interface fallback recognizes VM-owned Host IP" false \
    "$([ -f "$(host_connection_state_file "$fallback_desktop_port")" ] && echo true || echo false)"
BOXA_CONNECT_TEST_MISSING_IP=true
if ownership_unknown_output="$(start_host_connection_host_side 192.168.65.254 18987 2>&1)"; then
    ownership_unknown_status=success
else
    ownership_unknown_status=failure
fi
assert_eq "undecidable ownership fails instead of guessing" failure "$ownership_unknown_status"
assert_contains "undecidable ownership suggests optional python" \
    "Install python3" "$ownership_unknown_output"
BOXA_CONNECT_TEST_MISSING_PYTHON=false
BOXA_CONNECT_TEST_MISSING_IP=false
BOXA_CONNECT_TEST_INTERFACE_IPS="127.0.0.1"

# A bindable Host IP selects native Docker: relay only on that IP:port, exact
# bridge-subnet ufw slot, live traffic, changed-IP convergence, and teardown.
native_host_port=18991
relay_mock_bin="$_TMPROOT/relay-mock-bin"
mkdir -p "$relay_mock_bin"
printf '%s\n' \
    '#!/bin/bash' \
    'sleep 300 &' \
    "printf '%s\\n' \"\$!\" > \"\$BOXA_CONNECT_TEST_SOCAT_CHILD_FILE\"" \
    'exec /usr/bin/socat "$@"' \
    > "$relay_mock_bin/socat"
chmod +x "$relay_mock_bin/socat"
socat TCP-LISTEN:"$native_host_port",bind=127.0.0.1,reuseaddr,fork \
    SYSTEM:"printf native-ok" >/dev/null 2>&1 &
native_service_pid=$!
native_service_ready=false
for _attempt in $(seq 1 50); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${native_host_port}") 2>/dev/null; then
        native_service_ready=true
        break
    fi
    sleep 0.02
done
if [ "$native_service_ready" = false ]; then
    printf 'FAIL  native loopback service did not become ready\n'
    exit 1
fi
native_child_file="$_TMPROOT/mock-socat-child-native.pid"
BOXA_CONNECT_TEST_SOCAT_CHILD_FILE="$native_child_file" \
    PATH="$relay_mock_bin:$PATH" \
    start_host_connection_host_side 127.0.0.2 "$native_host_port"
native_state_file="$(host_connection_state_file "$native_host_port")"
IFS=$'\t' read -r native_ip native_relay_pid native_subnet native_ufw_owned \
    _native_target_kind _native_target_address \
    < "$native_state_file"
native_relay_child_pid="$(cat "$native_child_file")"
assert_eq "host relay mock starts a child process" "true" \
    "$(kill -0 "$native_relay_child_pid" 2>/dev/null && echo true || echo false)"
assert_eq "host-owned branch records exact relay IP" "127.0.0.2" "$native_ip"
assert_eq "host-owned branch records exact bridge subnet" "172.18.0.0/24" "$native_subnet"
assert_eq "host-owned branch owns newly added ufw slot" "true" "$native_ufw_owned"
assert_contains "host-owned relay binds only resolved IP and port" \
    "TCP-LISTEN:${native_host_port},bind=127.0.0.2," \
    "$(tr '\0' ' ' < "/proc/${native_relay_pid}/cmdline")"
assert_eq "host-owned relay reaches loopback service" "native-ok" \
    "$(curl --silent --http0.9 --noproxy '*' "http://127.0.0.2:${native_host_port}")"
assert_eq "host-owned branch opens exact ufw INPUT slot" "1" \
    "$(count_log_matches "ufw allow proto tcp from 172.18.0.0/24 to 127.0.0.2 port ${native_host_port}")"

changed_child_file="$_TMPROOT/mock-socat-child-changed.pid"
BOXA_CONNECT_TEST_SOCAT_CHILD_FILE="$changed_child_file" \
    PATH="$relay_mock_bin:$PATH" \
    start_host_connection_host_side 127.0.0.3 "$native_host_port"
IFS=$'\t' read -r changed_ip changed_relay_pid _changed_subnet _changed_ufw_owned \
    _changed_target_kind _changed_target_address \
    < "$native_state_file"
changed_relay_child_pid="$(cat "$changed_child_file")"
assert_eq "changed gateway replaces relay IP" "127.0.0.3" "$changed_ip"
assert_eq "changed gateway stops old relay" "false" \
    "$(kill -0 "$native_relay_pid" 2>/dev/null && echo true || echo false)"
assert_eq "changed gateway stops old relay child" "false" \
    "$(kill -0 "$native_relay_child_pid" 2>/dev/null && echo true || echo false)"
assert_eq "changed gateway removes old ufw slot" "1" \
    "$(count_log_matches "ufw delete allow proto tcp from 172.18.0.0/24 to 127.0.0.2 port ${native_host_port}")"
assert_eq "changed gateway opens new ufw slot" "1" \
    "$(count_log_matches "ufw allow proto tcp from 172.18.0.0/24 to 127.0.0.3 port ${native_host_port}")"
stop_host_connection_host_side "$native_host_port"
assert_eq "host-side teardown removes relay state" "false" \
    "$([ -f "$native_state_file" ] && echo true || echo false)"
assert_eq "host-side teardown stops current relay" "false" \
    "$(kill -0 "$changed_relay_pid" 2>/dev/null && echo true || echo false)"
assert_eq "host-side teardown stops current relay child" "false" \
    "$(kill -0 "$changed_relay_child_pid" 2>/dev/null && echo true || echo false)"

# State produced before setsid support shares the caller process group. The
# compatibility teardown freezes its listener before scanning direct children.
fallback_child_file="$_TMPROOT/mock-socat-child-no-setsid.pid"
BOXA_CONNECT_TEST_MISSING_SETSID=true
BOXA_CONNECT_TEST_SOCAT_CHILD_FILE="$fallback_child_file" \
    PATH="$relay_mock_bin:$PATH" \
    start_host_connection_host_side 127.0.0.4 "$native_host_port"
IFS=$'\t' read -r _fallback_ip fallback_relay_pid _fallback_subnet _fallback_owned \
    _fallback_target_kind _fallback_target_address \
    < "$(host_connection_state_file "$native_host_port")"
fallback_relay_child_pid="$(cat "$fallback_child_file")"
stop_host_connection_host_side "$native_host_port"
BOXA_CONNECT_TEST_MISSING_SETSID=false
assert_eq "pre-setsid teardown stops listener" "false" \
    "$(kill -0 "$fallback_relay_pid" 2>/dev/null && echo true || echo false)"
assert_eq "pre-setsid teardown stops existing child" "false" \
    "$(kill -0 "$fallback_relay_child_pid" 2>/dev/null && echo true || echo false)"
kill "$native_service_pid" 2>/dev/null || true

# The keep-awake relay selects a functional HTTP daemon target, preferring
# WSL loopback and falling back to the default gateway. Its persisted target
# proves the relay command and later convergence use the probed endpoint.
BOXA_KEEP_AWAKE_PLATFORM=wsl2
export BOXA_KEEP_AWAKE_PLATFORM
http_responder="$_TMPROOT/http-status-responder"
printf '%s\n' \
    '#!/bin/bash' \
    "printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\n\\r\\n{}'" \
    > "$http_responder"
chmod +x "$http_responder"
loopback_keep_awake_port=18981
BOXA_KEEP_AWAKE_PORT="$loopback_keep_awake_port"
export BOXA_KEEP_AWAKE_PORT
socat "TCP-LISTEN:${loopback_keep_awake_port},bind=127.0.0.1,reuseaddr,fork" \
    EXEC:"$http_responder" \
    >/dev/null 2>&1 &
loopback_daemon_pid=$!
wait_for_test_daemon 127.0.0.1 "$loopback_keep_awake_port" || exit 1
loopback_target_child="$_TMPROOT/mock-socat-child-loopback-target.pid"
BOXA_CONNECT_TEST_SOCAT_CHILD_FILE="$loopback_target_child" \
    PATH="$relay_mock_bin:$PATH" \
    start_host_connection_host_side 127.0.0.2 "$loopback_keep_awake_port"
IFS=$'\t' read -r _loopback_ip _loopback_pid _loopback_subnet _loopback_owned \
    loopback_target_kind loopback_target_address \
    < "$(host_connection_state_file "$loopback_keep_awake_port")"
assert_eq "WSL keep-awake relay prefers responding loopback" loopback \
    "$loopback_target_kind"
assert_eq "WSL loopback relay records exact target" 127.0.0.1 \
    "$loopback_target_address"
stop_host_connection_host_side "$loopback_keep_awake_port"
kill "$loopback_daemon_pid" 2>/dev/null || true

gateway_keep_awake_port=18982
BOXA_KEEP_AWAKE_PORT="$gateway_keep_awake_port"
socat "TCP-LISTEN:${gateway_keep_awake_port},bind=127.0.0.3,reuseaddr,fork" \
    EXEC:"$http_responder" \
    >/dev/null 2>&1 &
gateway_daemon_pid=$!
wait_for_test_daemon 127.0.0.3 "$gateway_keep_awake_port" || exit 1
gateway_target_child="$_TMPROOT/mock-socat-child-gateway-target.pid"
BOXA_CONNECT_TEST_SOCAT_CHILD_FILE="$gateway_target_child" \
    PATH="$relay_mock_bin:$PATH" \
    start_host_connection_host_side 127.0.0.2 "$gateway_keep_awake_port"
IFS=$'\t' read -r _gateway_ip _gateway_pid _gateway_subnet _gateway_owned \
    gateway_target_kind gateway_target_address \
    < "$(host_connection_state_file "$gateway_keep_awake_port")"
assert_eq "WSL keep-awake relay falls back to responding gateway" gateway \
    "$gateway_target_kind"
assert_eq "WSL gateway relay records exact target" 127.0.0.3 \
    "$gateway_target_address"
stop_host_connection_host_side "$gateway_keep_awake_port"
kill "$gateway_daemon_pid" 2>/dev/null || true

unreachable_keep_awake_port=18983
BOXA_KEEP_AWAKE_PORT="$unreachable_keep_awake_port"
if unreachable_target_output="$(start_host_connection_host_side \
        127.0.0.2 "$unreachable_keep_awake_port" 2>&1)"; then
    unreachable_target_status=success
else
    unreachable_target_status=failure
fi
assert_eq "WSL keep-awake relay rejects unreachable candidates" failure \
    "$unreachable_target_status"
assert_contains "unreachable target failure names selection step and candidates" \
    "relay target selection: daemon unreachable on loopback and gateway" \
    "$unreachable_target_output"
assert_contains "unreachable target failure names daemon and firewall hint" \
    "daemon is running and Windows Firewall allows port ${unreachable_keep_awake_port}" \
    "$unreachable_target_output"
assert_eq "unreachable target failure leaves no relay state" false \
    "$([ -f "$(host_connection_state_file "$unreachable_keep_awake_port")" ] \
        && echo true || echo false)"

# A TCP listener alone is insufficient for keep-awake readiness. This socat
# wrapper accepts on the relay address but deliberately forwards nowhere, so
# the old /dev/tcp check would pass while the HTTP probe must fail.
dishonest_keep_awake_port=18984
BOXA_KEEP_AWAKE_PORT="$dishonest_keep_awake_port"
socat "TCP-LISTEN:${dishonest_keep_awake_port},bind=127.0.0.1,reuseaddr,fork" \
    EXEC:"$http_responder" \
    >/dev/null 2>&1 &
dishonest_daemon_pid=$!
wait_for_test_daemon 127.0.0.1 "$dishonest_keep_awake_port" || exit 1
dishonest_relay_bin="$_TMPROOT/dishonest-relay-bin"
mkdir -p "$dishonest_relay_bin"
printf '%s\n' \
    '#!/bin/bash' \
    "exec /usr/bin/socat \"\$1\" TCP:127.0.0.4:1" \
    > "$dishonest_relay_bin/socat"
chmod +x "$dishonest_relay_bin/socat"
if dishonest_readiness_output="$(PATH="$dishonest_relay_bin:$PATH" \
        start_host_connection_host_side 127.0.0.2 \
        "$dishonest_keep_awake_port" 2>&1)"; then
    dishonest_readiness_status=success
else
    dishonest_readiness_status=failure
fi
assert_eq "keep-awake readiness rejects TCP-only relay" failure \
    "$dishonest_readiness_status"
assert_contains "keep-awake readiness names failed HTTP-through-relay step" \
    "keep-awake readiness failed: daemon did not return an HTTP response through relay" \
    "$dishonest_readiness_output"
assert_eq "dishonest readiness leaves no relay state" false \
    "$([ -f "$(host_connection_state_file "$dishonest_keep_awake_port")" ] \
        && echo true || echo false)"
kill "$dishonest_daemon_pid" 2>/dev/null || true
unset BOXA_KEEP_AWAKE_PLATFORM BOXA_KEEP_AWAKE_PORT

# A relay process that never becomes ready must fail the add path and leave no
# durable host-side state or ufw slot behind.
failed_relay_port=18986
failed_relay_bin="$_TMPROOT/failed-relay-bin"
mkdir -p "$failed_relay_bin"
printf '%s\n' \
    '#!/bin/bash' \
    'sleep 300 &' \
    "printf '%s\\n' \"\$!\" > \"\$BOXA_CONNECT_TEST_SOCAT_CHILD_FILE\"" \
    "trap 'exit 0' TERM" \
    'while true; do sleep 1; done' \
    > "$failed_relay_bin/socat"
chmod +x "$failed_relay_bin/socat"
failed_relay_child_file="$_TMPROOT/mock-socat-child-failed.pid"
failed_relay_ufw_before="$(count_log_matches 'ufw allow proto tcp')"
if failed_relay_output="$(BOXA_CONNECT_TEST_SOCAT_CHILD_FILE="$failed_relay_child_file" \
        PATH="$failed_relay_bin:$PATH" \
        start_host_connection_host_side 127.0.0.2 "$failed_relay_port" 2>&1)"; then
    failed_relay_status=success
else
    failed_relay_status=failure
fi
assert_eq "relay startup death propagates failure" failure "$failed_relay_status"
assert_contains "relay startup death identifies the broken relay" \
    "Host connection relay 127.0.0.2:${failed_relay_port} did not become ready" \
    "$failed_relay_output"
assert_eq "relay startup death leaves no state file" false \
    "$([ -f "$(host_connection_state_file "$failed_relay_port")" ] && echo true || echo false)"
assert_eq "relay startup death leaves ufw untouched" "$failed_relay_ufw_before" \
    "$(count_log_matches 'ufw allow proto tcp')"
failed_relay_child_pid="$(cat "$failed_relay_child_file")"
assert_eq "relay startup failure stops relay child" "false" \
    "$(kill -0 "$failed_relay_child_pid" 2>/dev/null && echo true || echo false)"
BOXA_CONNECT_TEST_HOST_IP="127.0.0.2"
failed_relay_slot_rollbacks_before="$(count_log_matches \
    "/usr/local/bin/stop-host-connection-allow 127.0.0.2 ${failed_relay_port}")"
if failed_relay_add_output="$(PATH="$failed_relay_bin:$PATH" \
        run_boxa connect host "$failed_relay_port" --from source 2>&1)"; then
    failed_relay_add_status=success
else
    failed_relay_add_status=failure
fi
assert_eq "failed relay makes explicit add fail" failure "$failed_relay_add_status"
assert_not_contains "failed relay add never reports connected" \
    "Connected: boxa-source -> host:${failed_relay_port}" "$failed_relay_add_output"
assert_eq "failed relay rolls back the container firewall slot" \
    "$((failed_relay_slot_rollbacks_before + 1))" \
    "$(count_log_matches "/usr/local/bin/stop-host-connection-allow 127.0.0.2 ${failed_relay_port}")"
BOXA_CONNECT_TEST_HOST_IP="192.168.65.254"
run_boxa connect rm host "$failed_relay_port" --from source >/dev/null

BOXA_CONNECT_TEST_MISSING_SOCAT=true
desktop_without_socat_output="$(run_boxa connect host 18992 --from source 2>&1)"
assert_contains "Docker Desktop add does not require host socat" \
    "Connected: boxa-source -> host:18992" "$desktop_without_socat_output"
run_boxa connect rm host 18992 --from source >/dev/null

BOXA_CONNECT_TEST_HOST_IP="127.0.0.2"
missing_socat_output="$(run_boxa connect host 18992 --from source 2>&1 || true)"
assert_contains "missing host socat prints exact install hint" \
    "host socat not found. Install it (Debian/Ubuntu: sudo apt-get install -y socat; Fedora/RHEL: sudo dnf install -y socat; Arch: sudo pacman -S socat; macOS: brew install socat). It is required for the Host connection relay on this platform." \
    "$missing_socat_output"
assert_eq "failed native add remains persisted for repair" \
    $'host-18992\thost\t18992\t18992' \
    "$(awk -F '\t' '$2 == "host" && $3 == 18992 { print }' "$config_file")"
BOXA_CONNECT_TEST_MISSING_SOCAT=false
run_boxa connect rm host 18992 --from source >/dev/null

# Start and replay surface missing durable support artifacts. The persisted
# row remains the repair source of truth, and failed teardown keeps it intact.
BOXA_CONNECT_TEST_HOST_IP="192.168.65.254"
helper_failure_port=18993
BOXA_CONNECT_TEST_START_ALLOW_FAIL_PORTS="$helper_failure_port"
helper_failure_output="$(run_boxa connect host "$helper_failure_port" --from source 2>&1 || true)"
assert_contains "add reports container firewall helper failure" \
    "Could not create the container firewall slot" "$helper_failure_output"
assert_not_contains "failed add does not report success" \
    "Connected: boxa-source -> host:${helper_failure_port}" "$helper_failure_output"
assert_eq "failed add keeps persisted row for repair" "$helper_failure_port" \
    "$(awk -F '\t' -v p="$helper_failure_port" '$3 == p { print $4 }' "$config_file")"
replay_failure_output="$(start_boxa_connections boxa-source 2>&1)"
assert_contains "replay reports helper failure" \
    "WARNING: persisted connection host-${helper_failure_port} for boxa-source failed to start" \
    "$replay_failure_output"
assert_contains "replay prints exact repair command" \
    "boxa connect host ${helper_failure_port} ${helper_failure_port} --name host-${helper_failure_port} --from source" \
    "$replay_failure_output"
if start_boxa_connections boxa-source >/dev/null 2>&1; then
    replay_failure_status=success
else
    replay_failure_status=failure
fi
assert_eq "replay failure does not block box start" success "$replay_failure_status"
BOXA_CONNECT_TEST_START_ALLOW_FAIL_PORTS=""

BOXA_CONNECT_TEST_STOP_ALLOW_FAIL_PORTS="$helper_failure_port"
forward_teardowns_before="$(count_log_matches "PID_FILE=/tmp/boxa-connect-${helper_failure_port}.pid")"
teardown_failure_output="$(run_boxa connect rm host "$helper_failure_port" --from source 2>&1 || true)"
assert_contains "rm reports container firewall teardown failure" \
    "Could not remove the container firewall slot" "$teardown_failure_output"
assert_not_contains "failed rm does not report removal" \
    "Removed Host connection" "$teardown_failure_output"
assert_eq "failed rm retains persisted row" "$helper_failure_port" \
    "$(awk -F '\t' -v p="$helper_failure_port" '$3 == p { print $4 }' "$config_file")"
assert_eq "failed firewall teardown stops before forward teardown" "$forward_teardowns_before" \
    "$(count_log_matches "PID_FILE=/tmp/boxa-connect-${helper_failure_port}.pid")"
BOXA_CONNECT_TEST_STOP_ALLOW_FAIL_PORTS=""
run_boxa connect rm host "$helper_failure_port" --from source >/dev/null

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

# Host status combines forward artifacts with a real TCP touch through the
# managed local listener. The existing up/down vocabulary stays intact while
# naming which side failed.
BOXA_CONNECT_TEST_BOUND_PORTS="17777"
BOXA_CONNECT_TEST_FORWARD_PORTS="17777"
healthy_row="$(run_boxa connections | awk '$2 == "host:17777" { print }')"
assert_contains "live Host probe reports healthy service up" "up" "$healthy_row"

BOXA_CONNECT_TEST_HOST_DOWN_PORTS="17777"
host_down_row="$(run_boxa connections | awk '$2 == "host:17777" { print }')"
assert_contains "live Host probe names non-answering host service" \
    "host down" "$host_down_row"

BOXA_CONNECT_TEST_HOST_DOWN_PORTS=""
BOXA_CONNECT_TEST_RULE_MISSING_PORTS="17777"
forward_down_row="$(run_boxa connections | awk '$2 == "host:17777" { print }')"
assert_contains "live Host probe names broken forward" \
    "forward down" "$forward_down_row"
BOXA_CONNECT_TEST_RULE_MISSING_PORTS=""
BOXA_CONNECT_TEST_BOUND_PORTS=""
BOXA_CONNECT_TEST_FORWARD_PORTS=""

# Removal tears down the exact root slot and pid-backed forward before deleting
# the row. With no persisted row, a later replay performs no Docker calls.
BOXA_CONNECT_TEST_HOST_IP="192.168.65.254"
rm_child_file="$_TMPROOT/mock-socat-child-rm.pid"
# 17777 is the keep-awake port, so starting this relay runs the daemon target
# probe against the stubbed gateway. Without a daemon answering there, target
# selection fails, no relay is ever started, and the teardown assertions below
# silently measure nothing.
socat "TCP-LISTEN:17777,bind=127.0.0.3,reuseaddr,fork" EXEC:"$http_responder" \
    >/dev/null 2>&1 &
rm_daemon_pid=$!
wait_for_test_daemon 127.0.0.3 17777 || exit 1
BOXA_CONNECT_TEST_SOCAT_CHILD_FILE="$rm_child_file" \
    PATH="$relay_mock_bin:$PATH" \
    start_host_connection_host_side 127.0.0.2 17777
rm_host_state_file="$(host_connection_state_file 17777)"
IFS=$'\t' read -r _rm_ip rm_relay_pid _rm_subnet _rm_owned \
    _rm_target_kind _rm_target_address < "$rm_host_state_file"
rm_relay_child_pid="$(cat "$rm_child_file")"
rm_output="$(run_boxa connect rm host 17777 --from source)"
assert_contains "rm reports removed Host target" \
    "Removed Host connection: boxa-source -> host:17777" "$rm_output"
assert_eq "rm invokes exact root firewall teardown" "1" \
    "$(count_log_matches '/usr/local/bin/stop-host-connection-allow 192.168.65.254 17777')"
assert_eq "rm invokes node forward teardown" "1" \
    "$(count_log_matches '-u node -e PID_FILE=/tmp/boxa-connect-17777.pid')"
assert_eq "rm stops native-Docker host relay" "false" \
    "$(kill -0 "$rm_relay_pid" 2>/dev/null && echo true || echo false)"
assert_eq "rm stops native-Docker host relay child" "false" \
    "$(kill -0 "$rm_relay_child_pid" 2>/dev/null && echo true || echo false)"
assert_eq "rm removes native-Docker host state" "false" \
    "$([ -f "$rm_host_state_file" ] && echo true || echo false)"
assert_eq "rm removes exact native-Docker ufw slot" "1" \
    "$(count_log_matches 'ufw delete allow proto tcp from 172.18.0.0/24 to 127.0.0.2 port 17777')"
assert_eq "rm drops persisted row" "0" "$(awk 'END { print NR }' "$config_file")"
kill "$rm_daemon_pid" 2>/dev/null || true

calls_before_empty_replay="$(awk 'END { print NR }' "$BOXA_CONNECT_TEST_LOG")"
start_boxa_connections boxa-source >/dev/null
assert_eq "removed entry is not replayed" "$calls_before_empty_replay" \
    "$(awk 'END { print NR }' "$BOXA_CONNECT_TEST_LOG")"

# A bound mirror falls back to the deterministic ADR 0019 checksum slot.
fallback_host_port=17778
checksum=$(printf '%s' "source:host:${fallback_host_port}" | cksum | awk '{print $1}')
checksum_port=$((15000 + checksum % 1000))
next_port=$((15000 + (checksum_port - 15000 + 1) % 1000))
BOXA_CONNECT_TEST_BOUND_PORTS="$fallback_host_port"
run_boxa connect host "$fallback_host_port" --from source >/dev/null
assert_eq "bound mirror selects checksum fallback" "$checksum_port" \
    "$(awk -F '\t' -v p="$fallback_host_port" '$3 == p { print $4 }' "$config_file")"
run_boxa connect rm host "$fallback_host_port" --from source >/dev/null

# A bound mirror and checksum slot use exactly slot+1 (wrapping in the pool).
BOXA_CONNECT_TEST_BOUND_PORTS="${fallback_host_port},${checksum_port}"
run_boxa connect host "$fallback_host_port" --from source >/dev/null
assert_eq "bound mirror and checksum select slot+1" "$next_port" \
    "$(awk -F '\t' -v p="$fallback_host_port" '$3 == p { print $4 }' "$config_file")"
run_boxa connect rm host "$fallback_host_port" --from source >/dev/null

# With all deterministic candidates bound, invalid and occupied answers are
# rejected until a free interactive answer can be persisted.
prompt_port=18888
BOXA_CONNECT_TEST_BOUND_PORTS="${fallback_host_port},${checksum_port},${next_port}"
prompt_output="$(printf 'invalid\n%s\n%s\n' "$checksum_port" "$prompt_port" \
    | run_boxa connect host "$fallback_host_port" --from source 2>&1)"
assert_contains "prompt validates numeric range" \
    "Local port must be a number from 1 to 65535." "$prompt_output"
assert_contains "prompt rejects an occupied port" \
    "Local port ${checksum_port} is already bound inside boxa-source." "$prompt_output"
assert_eq "prompt persists entered free port" "$prompt_port" \
    "$(awk -F '\t' -v p="$fallback_host_port" '$3 == p { print $4 }' "$config_file")"

# Re-add and replay both use the persisted port, even when every automatic
# candidate and the persisted port are now occupied; neither reads stdin.
BOXA_CONNECT_TEST_BOUND_PORTS="${BOXA_CONNECT_TEST_BOUND_PORTS},${prompt_port}"
readd_output="$(run_boxa connect host "$fallback_host_port" --from source </dev/null)"
assert_contains "re-add keeps persisted local port" \
    "10.0.2.2:${prompt_port}" "$readd_output"
replay_calls_before="$(count_log_matches 'cat /proc/net/tcp /proc/net/tcp6')"
start_boxa_connections boxa-source >/dev/null
assert_eq "replay never rescans occupied persisted port" "$replay_calls_before" \
    "$(count_log_matches 'cat /proc/net/tcp /proc/net/tcp6')"
stolen_output="$(run_boxa connections)"
stolen_row="$(awk -v target="host:${fallback_host_port}" '$2 == target { print }' <<< "$stolen_output")"
assert_contains "stolen persisted port is reported down" "down" "$stolen_row"

# An explicit local port wins without scanning the mirror or fallbacks.
run_boxa connect rm host "$fallback_host_port" --from source >/dev/null
explicit_port=18889
scan_calls_before="$(count_log_matches 'cat /proc/net/tcp /proc/net/tcp6')"
run_boxa connect host "$fallback_host_port" "$explicit_port" --from source >/dev/null
assert_eq "explicit local port skips selection scan" "$scan_calls_before" \
    "$(count_log_matches 'cat /proc/net/tcp /proc/net/tcp6')"
assert_eq "explicit local port is persisted" "$explicit_port" \
    "$(awk -F '\t' -v p="$fallback_host_port" '$3 == p { print $4 }' "$config_file")"
replacement_port=18891
old_forward_teardowns_before="$(count_log_matches "PID_FILE=/tmp/boxa-connect-${explicit_port}.pid")"
run_boxa connect host "$fallback_host_port" "$replacement_port" --from source >/dev/null
assert_eq "changed per-box explicit port tears down old forward" \
    "$((old_forward_teardowns_before + 1))" \
    "$(count_log_matches "PID_FILE=/tmp/boxa-connect-${explicit_port}.pid")"
assert_eq "changed per-box explicit port persists replacement" "$replacement_port" \
    "$(awk -F '\t' -v p="$fallback_host_port" '$3 == p { print $4 }' "$config_file")"
same_port_teardowns_before="$(count_log_matches "-u node -e PID_FILE=/tmp/boxa-connect-${replacement_port}.pid")"
run_boxa connect host "$fallback_host_port" "$replacement_port" --from source >/dev/null
assert_eq "same per-box explicit port remains idempotent" "$same_port_teardowns_before" \
    "$(count_log_matches "-u node -e PID_FILE=/tmp/boxa-connect-${replacement_port}.pid")"
explicit_port="$replacement_port"
per_box_same_scope_collision_output="$(run_boxa connect host 18890 "$explicit_port" --from source 2>&1 || true)"
assert_contains "per-box add rejects same-scope explicit local-port collision" \
    "Local port ${explicit_port} is already used by another persisted connection." \
    "$per_box_same_scope_collision_output"
assert_eq "per-box collision preserves existing row" "$fallback_host_port" \
    "$(awk -F '\t' -v p="$explicit_port" '$4 == p { print $3 }' "$config_file")"

connect_help="$(run_boxa help connect)"
assert_contains "help documents connect host" \
    "boxa connect host <port> [local-port]" "$connect_help"
assert_contains "help documents --name" "--name <label>" "$connect_help"
assert_contains "help documents Host rm" "boxa connect rm host <port>" "$connect_help"
assert_contains "help documents Host selection order" \
    "host port -> 15000-15999 checksum slot -> slot+1" "$connect_help"
assert_contains "help documents explicit local port precedence" \
    "explicit local-port always wins" "$connect_help"
assert_contains "help documents native-Linux standing firewall rule" \
    "standing, narrowly scoped host" "$connect_help"

overview_help="$(run_boxa help)"
assert_contains "overview documents connect host" \
    "boxa connect host <port> [local-port] [--name <label>]" "$overview_help"

# Global scope is persisted once and applied immediately in every running box.
# It coexists with the different-port per-box record above.
global_config_file="$_TMPROOT/home/.config/boxa/connect/_all.tsv"
global_host_port=17779
BOXA_CONNECT_TEST_CONTAINERS=$'boxa-source\nboxa-second'
global_output="$(run_boxa connect host "$global_host_port" --name shared-hook --all)"
assert_contains "global add reports all-box scope" \
    "Connected globally: all boxes -> host:${global_host_port}" "$global_output"
assert_eq "global add persists one dedicated row" \
    $'shared-hook\thost\t17779\t17779' "$(cat "$global_config_file")"
assert_eq "global add starts firewall slot in two running boxes" "2" \
    "$(count_log_matches "/usr/local/bin/start-host-connection-allow 192.168.65.254 ${global_host_port}")"
assert_eq "global add starts forward in two running boxes" "2" \
    "$(count_log_matches "-e TARGET_PORT=${global_host_port} -e LOCAL_PORT=${global_host_port}")"
global_replacement_port=17786
global_old_teardowns_before="$(count_log_matches "PID_FILE=/tmp/boxa-connect-${global_host_port}.pid")"
run_boxa connect host "$global_host_port" "$global_replacement_port" --name shared-hook --all >/dev/null
assert_eq "changed global explicit port tears down old forward in every box" \
    "$((global_old_teardowns_before + 2))" \
    "$(count_log_matches "PID_FILE=/tmp/boxa-connect-${global_host_port}.pid")"
assert_eq "changed global explicit port persists replacement" "$global_replacement_port" \
    "$(awk -F '\t' -v p="$global_host_port" '$3 == p { print $4 }' "$global_config_file")"
global_same_teardowns_before="$(count_log_matches "-u node -e PID_FILE=/tmp/boxa-connect-${global_replacement_port}.pid")"
run_boxa connect host "$global_host_port" "$global_replacement_port" --name shared-hook --all >/dev/null
assert_eq "same global explicit port remains idempotent" "$global_same_teardowns_before" \
    "$(count_log_matches "-u node -e PID_FILE=/tmp/boxa-connect-${global_replacement_port}.pid")"
global_same_scope_collision_output="$(run_boxa connect host 17785 "$global_replacement_port" --all 2>&1 || true)"
assert_contains "global add rejects same-scope explicit local-port collision" \
    "Local port ${global_replacement_port} is already used by another persisted connection." \
    "$global_same_scope_collision_output"
assert_eq "global collision preserves existing row" "$global_host_port" \
    "$(awk -F '\t' -v p="$global_replacement_port" '$4 == p { print $3 }' "$global_config_file")"
assert_eq "global and per-box files coexist" "$explicit_port" \
    "$(awk -F '\t' -v p="$fallback_host_port" '$3 == p { print $4 }' "$config_file")"

# A box started after creation replays the same global row despite having no
# per-box file of its own.
BOXA_CONNECT_TEST_HOST_IP="192.168.65.252"
start_boxa_connections boxa-third >/dev/null
assert_eq "future box replays global firewall slot" "1" \
    "$(count_log_matches "-u root boxa-third /usr/local/bin/start-host-connection-allow 192.168.65.252 ${global_host_port}")"
assert_eq "future box replays global forward" "1" \
    "$(count_log_matches "-u node -e TARGET_CONTAINER=192.168.65.252 -e TARGET_PORT=${global_host_port}")"

BOXA_CONNECT_TEST_CONTAINERS=$'boxa-source\nboxa-second\nboxa-third'
connections_output="$(run_boxa connections)"
assert_contains "connections has explicit scope column" "SCOPE" "$connections_output"
for source in boxa-source boxa-second boxa-third; do
    global_row="$(awk -v source="$source" -v target="host:${global_host_port}" \
        '$1 == source && $2 == target { print }' <<< "$connections_output")"
    assert_contains "connections marks global scope for ${source}" "all" "$global_row"
done

# Cross-scope collisions are rejected instead of silently replacing a forward
# or sharing a firewall slot whose removal would break the other scope.
local_collision_output="$(run_boxa connect host 17781 "$global_replacement_port" --from source 2>&1 || true)"
assert_contains "per-box add rejects global local-port collision" \
    "Local port ${global_replacement_port} is already used by a global persisted connection." \
    "$local_collision_output"
target_collision_output="$(run_boxa connect host "$global_host_port" --from source 2>&1 || true)"
assert_contains "per-box add rejects global Host-port collision" \
    "Host port ${global_host_port} already has a global connection" "$target_collision_output"
global_collision_output="$(run_boxa connect host "$fallback_host_port" --all 2>&1 || true)"
assert_contains "global add rejects existing per-box Host port" \
    "Host port ${fallback_host_port} already has a per-box connection" "$global_collision_output"

# Global removal tears down every running box and deletes the sole global row;
# the unrelated per-box record remains and a future box cannot replay global.
BOXA_CONNECT_TEST_HOST_IP="192.168.65.254"
global_rm_firewall_teardowns_before="$(count_log_matches "/usr/local/bin/stop-host-connection-allow 192.168.65.254 ${global_host_port}")"
global_rm_output="$(run_boxa connect rm host "$global_host_port" --all)"
assert_contains "global rm reports all-box scope" \
    "Removed global Host connection: all boxes -> host:${global_host_port}" "$global_rm_output"
assert_eq "global rm tears down firewall in all running boxes" "3" \
    "$(( $(count_log_matches "/usr/local/bin/stop-host-connection-allow 192.168.65.254 ${global_host_port}") - global_rm_firewall_teardowns_before ))"
assert_eq "global rm tears down forwards in all running boxes" "3" \
    "$(count_log_matches "-u node -e PID_FILE=/tmp/boxa-connect-${global_replacement_port}.pid")"
assert_eq "global rm removes persisted global row" "0" \
    "$(awk 'END { print NR }' "$global_config_file")"
assert_eq "global rm preserves per-box row" "$explicit_port" \
    "$(awk -F '\t' -v p="$fallback_host_port" '$3 == p { print $4 }' "$config_file")"
global_calls_before_removed_replay="$(count_log_matches "TARGET_PORT=${global_host_port}")"
start_boxa_connections boxa-fourth >/dev/null
assert_eq "removed global entry is not replayed by future box" \
    "$global_calls_before_removed_replay" "$(count_log_matches "TARGET_PORT=${global_host_port}")"

# A failing box no longer aborts global removal: healthy boxes are cleaned,
# the record stays for a retry, and a second pass finishes the job (issue 15).
run_boxa connect host "$global_host_port" "$global_replacement_port" --name shared-hook --all >/dev/null
export BOXA_CONNECT_TEST_STOP_ALLOW_FAIL_CONTAINERS=boxa-second
partial_rm_teardowns_before="$(count_log_matches "/usr/local/bin/stop-host-connection-allow 192.168.65.254 ${global_host_port}")"
partial_rm_output="$(run_boxa connect rm host "$global_host_port" --all 2>&1 || true)"
assert_contains "partial global rm names the failing box" \
    "Failed to remove global Host connection in boxa-second." "$partial_rm_output"
assert_contains "partial global rm advises retry" \
    "fix the reported boxes and re-run the removal" "$partial_rm_output"
assert_eq "partial global rm still visits every box" "3" \
    "$(( $(count_log_matches "/usr/local/bin/stop-host-connection-allow 192.168.65.254 ${global_host_port}") - partial_rm_teardowns_before ))"
assert_eq "partial global rm keeps persisted global row" "1" \
    "$(awk 'END { print NR }' "$global_config_file")"
export BOXA_CONNECT_TEST_STOP_ALLOW_FAIL_CONTAINERS=""
run_boxa connect rm host "$global_host_port" --all >/dev/null
assert_eq "retry after partial global rm removes the row" "0" \
    "$(awk 'END { print NR }' "$global_config_file")"

conflict_output="$(run_boxa connect host 17780 --all --from source 2>&1 || true)"
assert_contains "--all rejects per-box --from scope" \
    "--all cannot be combined with --from." "$conflict_output"
assert_contains "connect help documents --all" "--all" "$connect_help"
assert_contains "connect help documents global trust" \
    "deliberately widens trust" "$connect_help"
assert_contains "overview documents --all trust" \
    "--all trusts it in every present/future box" "$overview_help"

# Uninstall enumerates every persisted Host record and routes each one through
# the same removal helper as `connect rm`. A copied CLI with a no-op build.sh
# exercises the real uninstall dispatch without touching host install state.
rm -f "$CONNECT_CONFIG_DIR"/*.tsv
uninstall_per_box_port=17782
uninstall_second_port=17783
uninstall_global_port=17784
printf 'source-host\thost\t%s\t%s\n' \
    "$uninstall_per_box_port" "$uninstall_per_box_port" \
    > "$CONNECT_CONFIG_DIR/source.tsv"
printf 'second-host\thost\t%s\t%s\n' \
    "$uninstall_second_port" "$uninstall_second_port" \
    > "$CONNECT_CONFIG_DIR/second.tsv"
printf 'global-host\thost\t%s\t%s\n' \
    "$uninstall_global_port" "$uninstall_global_port" \
    > "$CONNECT_CONFIG_DIR/_all.tsv"

start_host_connection_host_side 127.0.0.2 "$uninstall_per_box_port"
start_host_connection_host_side 127.0.0.3 "$uninstall_second_port"
start_host_connection_host_side 127.0.0.4 "$uninstall_global_port"
IFS=$'\t' read -r _ip uninstall_per_box_pid _subnet _owned \
    _target_kind _target_address \
    < "$(host_connection_state_file "$uninstall_per_box_port")"
IFS=$'\t' read -r _ip uninstall_second_pid _subnet _owned \
    _target_kind _target_address \
    < "$(host_connection_state_file "$uninstall_second_port")"
IFS=$'\t' read -r _ip uninstall_global_pid _subnet _owned \
    _target_kind _target_address \
    < "$(host_connection_state_file "$uninstall_global_port")"

uninstall_cli_dir="$_TMPROOT/uninstall-cli"
mkdir -p "$uninstall_cli_dir"
cp "$BOXA" "$uninstall_cli_dir/docker-run.sh"
cp -R "$BOXA_DIR/lib" "$uninstall_cli_dir/lib"
ln -s /bin/true "$uninstall_cli_dir/build.sh"
run_uninstall() {
    HOME="$_TMPROOT/home" bash "$uninstall_cli_dir/docker-run.sh" uninstall
}

BOXA_CONNECT_TEST_CONTAINERS=$'boxa-source\nboxa-second'
uninstall_ufw_deletes_before="$(count_log_matches 'ufw delete allow proto tcp')"
uninstall_container_teardowns_before="$(count_log_matches '/usr/local/bin/stop-host-connection-allow 192.168.65.254')"
uninstall_output="$(run_uninstall)"
assert_contains "uninstall uses per-box rm reporting path" \
    "Removed Host connection: boxa-source -> host:${uninstall_per_box_port}" \
    "$uninstall_output"
assert_contains "uninstall removes second per-box Host connection" \
    "Removed Host connection: boxa-second -> host:${uninstall_second_port}" \
    "$uninstall_output"
assert_contains "uninstall uses global rm reporting path" \
    "Removed global Host connection: all boxes -> host:${uninstall_global_port}" \
    "$uninstall_output"
assert_eq "uninstall removes every persisted Host entry" "0" \
    "$(awk -F '\t' '$2 == "host" { count++ } END { print count + 0 }' "$CONNECT_CONFIG_DIR"/*.tsv)"
assert_eq "uninstall stops every host relay" "false false false" \
    "$(kill -0 "$uninstall_per_box_pid" 2>/dev/null && echo true || echo false) $(kill -0 "$uninstall_second_pid" 2>/dev/null && echo true || echo false) $(kill -0 "$uninstall_global_pid" 2>/dev/null && echo true || echo false)"
assert_eq "uninstall removes every host relay state file" "false false false" \
    "$([ -f "$(host_connection_state_file "$uninstall_per_box_port")" ] && echo true || echo false) $([ -f "$(host_connection_state_file "$uninstall_second_port")" ] && echo true || echo false) $([ -f "$(host_connection_state_file "$uninstall_global_port")" ] && echo true || echo false)"
assert_eq "uninstall removes every ufw Host slot" "3" \
    "$(( $(count_log_matches 'ufw delete allow proto tcp') - uninstall_ufw_deletes_before ))"
assert_eq "uninstall tears down per-box plus global container slots" "4" \
    "$(( $(count_log_matches '/usr/local/bin/stop-host-connection-allow 192.168.65.254') - uninstall_container_teardowns_before ))"

empty_uninstall_ufw_deletes_before="$(count_log_matches 'ufw delete allow proto tcp')"
empty_uninstall_container_teardowns_before="$(count_log_matches '/usr/local/bin/stop-host-connection-allow 192.168.65.254')"
empty_uninstall_output="$(run_uninstall)"
assert_eq "uninstall with no Host connections prints nothing extra" "" \
    "$empty_uninstall_output"
assert_eq "uninstall with no Host connections leaves ufw unchanged" \
    "$empty_uninstall_ufw_deletes_before" \
    "$(count_log_matches 'ufw delete allow proto tcp')"
assert_eq "uninstall with no Host connections skips container teardown" \
    "$empty_uninstall_container_teardowns_before" \
    "$(count_log_matches '/usr/local/bin/stop-host-connection-allow 192.168.65.254')"

# Doctor uses the same non-mutating artifact checks, prints an idempotent
# connect command, and adds no bytes at all when no Host records are persisted.
doctor_cli_dir="$_TMPROOT/doctor-cli"
mkdir -p "$doctor_cli_dir"
cp "$BOXA" "$doctor_cli_dir/docker-run.sh"
cp -R "$BOXA_DIR/lib" "$doctor_cli_dir/lib"
cat > "$doctor_cli_dir/lib/provisioning.sh" <<'EOF'
#!/bin/bash
BOXA_PROVISIONING_STEPS=("stub-step|-|A")
boxa::run_provisioning() {
    BOXA_PROVISIONING_REPAIRED=()
    BOXA_PROVISIONING_OK=("stub-step")
    if [ "${BOXA_CONNECT_TEST_DOCTOR_KEEP_AWAKE:-false}" = true ]; then
        BOXA_PROVISIONING_OK+=("keep-awake")
    fi
    BOXA_PROVISIONING_SKIPPED=()
    BOXA_PROVISIONING_PREREQ_MISSING=()
    BOXA_PROVISIONING_MISSING=()
    BOXA_PROVISIONING_DECLINED=()
    BOXA_PROVISIONING_FAILED=()
}
boxa::prereq_remedy() { :; }
EOF
mkdir -p "$doctor_cli_dir/scripts"
printf '%s\n' \
    '#!/bin/bash' \
    'printf "Relay target: gateway (127.0.0.3)\n"' \
    > "$doctor_cli_dir/scripts/ensure-keep-awake.sh"
chmod +x "$doctor_cli_dir/scripts/ensure-keep-awake.sh"
run_doctor() {
    HOME="$_TMPROOT/home" bash "$doctor_cli_dir/docker-run.sh" doctor
}

rm -f "$CONNECT_CONFIG_DIR"/*.tsv
printf 'peer\tboxa-target\t5432\t15432\n' > "$CONNECT_CONFIG_DIR/source.tsv"
doctor_without_connections="$(run_doctor)"
expected_doctor_without_connections=$'Running boxa doctor (repairing unconditional host provisioning)...\n\n\n=== boxa doctor summary ===\nAlready OK:\n  - stub-step\n\nHost provisioning is healthy.'
assert_eq "doctor output with no Host connections is unchanged" \
    "$expected_doctor_without_connections" "$doctor_without_connections"

BOXA_CONNECT_TEST_DOCTOR_KEEP_AWAKE=true
doctor_keep_awake_output="$(run_doctor)"
assert_contains "doctor reports active keep-awake relay target" \
    "Relay target: gateway (127.0.0.3)" "$doctor_keep_awake_output"
BOXA_CONNECT_TEST_DOCTOR_KEEP_AWAKE=false

doctor_port=17790
printf 'doctor-host\thost\t%s\t%s\n' "$doctor_port" "$doctor_port" \
    > "$CONNECT_CONFIG_DIR/source.tsv"
BOXA_CONNECT_TEST_BOUND_PORTS="$doctor_port"
BOXA_CONNECT_TEST_FORWARD_PORTS="$doctor_port"
BOXA_CONNECT_TEST_RULE_MISSING_PORTS="$doctor_port"
doctor_repair_calls_before="$(count_log_matches '/usr/local/bin/start-host-connection-allow')"
doctor_broken_output="$(run_doctor)"
assert_contains "doctor reports broken Host forward" \
    "boxa-source -> host:${doctor_port}: container firewall rule missing" \
    "$doctor_broken_output"
assert_contains "doctor prints exact idempotent Host repair command" \
    "boxa connect host ${doctor_port} ${doctor_port} --name doctor-host --from source" \
    "$doctor_broken_output"
assert_eq "doctor never repairs a broken Host forward" "$doctor_repair_calls_before" \
    "$(count_log_matches '/usr/local/bin/start-host-connection-allow')"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll connect-host tests passed.\n'
