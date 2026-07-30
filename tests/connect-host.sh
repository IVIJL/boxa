#!/bin/bash
# Plain-bash lifecycle assertions for Docker Desktop and native-Docker Host connections.
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
export BOXA_CONNECT_TEST_BOUND_PORTS=""
export BOXA_CONNECT_TEST_FORWARD_PORTS=""
export BOXA_CONNECT_TEST_CONTAINERS="boxa-source"
export BOXA_CONNECT_TEST_UFW_ACTIVE=false
export BOXA_CONNECT_TEST_MISSING_SOCAT=false
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
    builtin command "$@"
}
export -f command

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
            case "$*" in
                *'getent ahostsv4 host.docker.internal'*)
                    printf '%s\n' "$BOXA_CONNECT_TEST_HOST_IP"
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

# A bindable Host IP selects native Docker: relay only on that IP:port, exact
# bridge-subnet ufw slot, live traffic, changed-IP convergence, and teardown.
native_host_port=18991
socat TCP-LISTEN:"$native_host_port",bind=127.0.0.1,reuseaddr,fork \
    SYSTEM:"printf native-ok" >/dev/null 2>&1 &
native_service_pid=$!
start_host_connection_host_side 127.0.0.2 "$native_host_port"
native_state_file="$(host_connection_state_file "$native_host_port")"
IFS=$'\t' read -r native_ip native_relay_pid native_subnet native_ufw_owned \
    < "$native_state_file"
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

start_host_connection_host_side 127.0.0.3 "$native_host_port"
IFS=$'\t' read -r changed_ip changed_relay_pid _changed_subnet _changed_ufw_owned \
    < "$native_state_file"
assert_eq "changed gateway replaces relay IP" "127.0.0.3" "$changed_ip"
assert_eq "changed gateway stops old relay" "false" \
    "$(kill -0 "$native_relay_pid" 2>/dev/null && echo true || echo false)"
assert_eq "changed gateway removes old ufw slot" "1" \
    "$(count_log_matches "ufw delete allow proto tcp from 172.18.0.0/24 to 127.0.0.2 port ${native_host_port}")"
assert_eq "changed gateway opens new ufw slot" "1" \
    "$(count_log_matches "ufw allow proto tcp from 172.18.0.0/24 to 127.0.0.3 port ${native_host_port}")"
stop_host_connection_host_side "$native_host_port"
assert_eq "host-side teardown removes relay state" "false" \
    "$([ -f "$native_state_file" ] && echo true || echo false)"
assert_eq "host-side teardown stops current relay" "false" \
    "$(kill -0 "$changed_relay_pid" 2>/dev/null && echo true || echo false)"
kill "$native_service_pid" 2>/dev/null || true

BOXA_CONNECT_TEST_MISSING_SOCAT=true
missing_socat_output="$(run_boxa connect host 18992 --from source 2>&1 || true)"
assert_contains "missing host socat prints exact install hint" \
    "host socat not found. Install it (Debian/Ubuntu: sudo apt-get install -y socat; Fedora/RHEL: sudo dnf install -y socat; Arch: sudo pacman -S socat; macOS: brew install socat). It is required for the Host connection relay on this platform." \
    "$missing_socat_output"
assert_eq "missing host socat does not persist failed add" "" \
    "$(awk -F '\t' '$2 == "host" && $3 == 18992 { print }' "$config_file")"
BOXA_CONNECT_TEST_MISSING_SOCAT=false

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
start_host_connection_host_side 127.0.0.2 17777
rm_host_state_file="$(host_connection_state_file 17777)"
IFS=$'\t' read -r _rm_ip rm_relay_pid _rm_subnet _rm_owned < "$rm_host_state_file"
rm_output="$(run_boxa connect rm host 17777 --from source)"
assert_contains "rm reports removed Host target" \
    "Removed Host connection: boxa-source -> host:17777" "$rm_output"
assert_eq "rm invokes exact root firewall teardown" "1" \
    "$(count_log_matches '/usr/local/bin/stop-host-connection-allow 192.168.65.254 17777')"
assert_eq "rm invokes node forward teardown" "1" \
    "$(count_log_matches '-u node -e PID_FILE=/tmp/boxa-connect-17777.pid')"
assert_eq "rm stops native-Docker host relay" "false" \
    "$(kill -0 "$rm_relay_pid" 2>/dev/null && echo true || echo false)"
assert_eq "rm removes native-Docker host state" "false" \
    "$([ -f "$rm_host_state_file" ] && echo true || echo false)"
assert_eq "rm removes exact native-Docker ufw slot" "1" \
    "$(count_log_matches 'ufw delete allow proto tcp from 172.18.0.0/24 to 127.0.0.2 port 17777')"
assert_eq "rm drops persisted row" "0" "$(awk 'END { print NR }' "$config_file")"

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
local_collision_output="$(run_boxa connect host 17781 "$global_host_port" --from source 2>&1 || true)"
assert_contains "per-box add rejects global local-port collision" \
    "Local port ${global_host_port} is already used by a global persisted connection." \
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
global_rm_output="$(run_boxa connect rm host "$global_host_port" --all)"
assert_contains "global rm reports all-box scope" \
    "Removed global Host connection: all boxes -> host:${global_host_port}" "$global_rm_output"
assert_eq "global rm tears down firewall in all running boxes" "3" \
    "$(count_log_matches "/usr/local/bin/stop-host-connection-allow 192.168.65.254 ${global_host_port}")"
assert_eq "global rm tears down forwards in all running boxes" "3" \
    "$(count_log_matches "-u node -e PID_FILE=/tmp/boxa-connect-${global_host_port}.pid")"
assert_eq "global rm removes persisted global row" "0" \
    "$(awk 'END { print NR }' "$global_config_file")"
assert_eq "global rm preserves per-box row" "$explicit_port" \
    "$(awk -F '\t' -v p="$fallback_host_port" '$3 == p { print $4 }' "$config_file")"
global_calls_before_removed_replay="$(count_log_matches "TARGET_PORT=${global_host_port}")"
start_boxa_connections boxa-fourth >/dev/null
assert_eq "removed global entry is not replayed by future box" \
    "$global_calls_before_removed_replay" "$(count_log_matches "TARGET_PORT=${global_host_port}")"

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
    < "$(host_connection_state_file "$uninstall_per_box_port")"
IFS=$'\t' read -r _ip uninstall_second_pid _subnet _owned \
    < "$(host_connection_state_file "$uninstall_second_port")"
IFS=$'\t' read -r _ip uninstall_global_pid _subnet _owned \
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
uninstall_container_teardowns_before="$(count_log_matches '/usr/local/bin/stop-host-connection-allow')"
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
    "$(( $(count_log_matches '/usr/local/bin/stop-host-connection-allow') - uninstall_container_teardowns_before ))"

empty_uninstall_ufw_deletes_before="$(count_log_matches 'ufw delete allow proto tcp')"
empty_uninstall_container_teardowns_before="$(count_log_matches '/usr/local/bin/stop-host-connection-allow')"
empty_uninstall_output="$(run_uninstall)"
assert_eq "uninstall with no Host connections prints nothing extra" "" \
    "$empty_uninstall_output"
assert_eq "uninstall with no Host connections leaves ufw unchanged" \
    "$empty_uninstall_ufw_deletes_before" \
    "$(count_log_matches 'ufw delete allow proto tcp')"
assert_eq "uninstall with no Host connections skips container teardown" \
    "$empty_uninstall_container_teardowns_before" \
    "$(count_log_matches '/usr/local/bin/stop-host-connection-allow')"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll connect-host tests passed.\n'
