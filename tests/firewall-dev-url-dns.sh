#!/bin/bash
# Plain-bash assertions for in-container dev URL dnsmasq rendering.
# Usage: bash tests/firewall-dev-url-dns.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

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

assert_lt() {
    local label="$1" first="$2" second="$3"
    if [ "$first" -lt "$second" ]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      expected: %s < %s\n' \
            "$label" "$first" "$second"
        fail_count=$((fail_count + 1))
    fi
}

assert_status() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" -eq "$actual" ]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      expected status: %s\n      actual status:   %s\n' \
            "$label" "$expected" "$actual"
        fail_count=$((fail_count + 1))
    fi
}

mkdir -p "$_TMPROOT/bin"
cat > "$_TMPROOT/bin/runuser" <<'STUB'
#!/bin/bash
if [ "$1" != "-u" ] || [ "$2" != "dnsmasq" ] || [ "$3" != "--" ]; then
    exit 2
fi
shift 3
exec "$@"
STUB
cat > "$_TMPROOT/bin/dig" <<'STUB'
#!/bin/bash
if [ "$*" != "+short +time=2 +tries=1 @127.0.0.11 boxa_traefik A" ]; then
    exit 2
fi
if [ -n "${TEST_TRAEFIK_IP:-}" ]; then
    printf '%s\n' "$TEST_TRAEFIK_IP"
fi
STUB
chmod +x "$_TMPROOT/bin/runuser" "$_TMPROOT/bin/dig"
PATH="$_TMPROOT/bin:$PATH"
export PATH TEST_TRAEFIK_IP

init_script="$BOXA_DIR/init-firewall.sh"
lookup_line=$(awk '/^TRAEFIK_IP=\$\(dig / { print NR; exit }' "$init_script")
drop_line=$(awk '/^iptables -P OUTPUT DROP$/ { print NR; exit }' "$init_script")
reject_line=$(awk '/^iptables -A OUTPUT -j REJECT / { print NR; exit }' "$init_script")
assert_lt "init resolves Traefik before OUTPUT DROP" "$lookup_line" "$drop_line"
assert_lt "init resolves Traefik before catch-all REJECT" "$lookup_line" "$reject_line"

cat > "$_TMPROOT/bin/ip" <<'STUB'
#!/bin/bash
if [ "$*" = "-4 route show default" ]; then
    if [ "${TEST_ROUTE_MODE:-}" != "no-default" ]; then
        printf 'default via 172.18.0.1 dev eth0\n'
    fi
elif [ "$*" = "-4 route show dev eth0 scope link" ]; then
    if [ "${TEST_ROUTE_MODE:-}" != "no-link" ]; then
        printf '172.18.0.0/16 proto kernel scope link src 172.18.1.9\n'
    fi
else
    exit 2
fi
STUB
chmod +x "$_TMPROOT/bin/ip"
export TEST_ROUTE_MODE

network_block="$_TMPROOT/init-firewall.network"
awk '
    /^_detect_host_network\(\) \{$/ { capture=1 }
    capture { print }
    capture && /^echo "Host network detected as:/ { exit }
' "$init_script" > "$network_block"

TEST_ROUTE_MODE=
network_output=$(bash "$network_block" 2>&1)
network_status=$?
assert_status "init accepts a scope-link subnet" 0 "$network_status"
assert_eq "init uses the real scope-link prefix" \
    'Host network detected as: 172.18.0.0/16' "$network_output"

TEST_ROUTE_MODE=no-default
network_output=$(bash "$network_block" 2>&1)
network_status=$?
assert_status "init aborts without a primary interface" 1 "$network_status"
assert_eq "init reports a missing primary interface loudly" \
    'ERROR: Failed to detect host network' "$network_output"

TEST_ROUTE_MODE=no-link
network_output=$(bash "$network_block" 2>&1)
network_status=$?
assert_status "init aborts without a scope-link subnet" 1 "$network_status"
assert_eq "init reports a missing scope-link subnet loudly" \
    'ERROR: Failed to detect host network' "$network_output"

init_function="$_TMPROOT/init-firewall.function"
awk '
    /^_append_dev_url_dns\(\) \{$/ { capture=1 }
    capture { print }
    capture && /^\}$/ { exit }
' "$init_script" > "$init_function"
# shellcheck source=/dev/null
source "$init_function"
config="$_TMPROOT/init-firewall.conf"
printf 'server=127.0.0.11\n' > "$config"
_append_dev_url_dns "$config" 172.30.0.4
assert_eq "init renders both dev URL suffixes from the early lookup" \
    $'server=127.0.0.11\naddress=/test/172.30.0.4\naddress=/127.0.0.1.sslip.io/172.30.0.4' \
    "$(< "$config")"
printf 'server=127.0.0.11\n' > "$config"
_append_dev_url_dns "$config" ""
assert_eq "init degrades when the early lookup is empty" \
    'server=127.0.0.11' "$(< "$config")"

reload_script="$BOXA_DIR/scripts/boxa-firewall-reload.sh"
reload_function="$_TMPROOT/boxa-firewall-reload.function"
awk '
    /^_render_dev_url_dns\(\) \{$/ { capture=1 }
    capture { print }
    capture && /^\}$/ { exit }
' "$reload_script" > "$reload_function"
# shellcheck source=/dev/null
source "$reload_function"
config="$_TMPROOT/boxa-firewall-reload.conf"
printf 'server=127.0.0.11\n' > "$config"

TEST_TRAEFIK_IP=172.30.0.4
_render_dev_url_dns "$config"
assert_eq "reload renders both dev URL suffixes" \
    $'server=127.0.0.11\naddress=/test/172.30.0.4\naddress=/127.0.0.1.sslip.io/172.30.0.4' \
    "$(< "$config")"

TEST_TRAEFIK_IP=172.30.0.9
_render_dev_url_dns "$config"
assert_eq "reload refreshes a changed Traefik IP" \
    $'server=127.0.0.11\naddress=/test/172.30.0.9\naddress=/127.0.0.1.sslip.io/172.30.0.9' \
    "$(< "$config")"

TEST_TRAEFIK_IP=
_render_dev_url_dns "$config"
assert_eq "reload degrades without stale address rules" \
    'server=127.0.0.11' "$(< "$config")"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed\n' "$fail_count"
    exit 1
fi

printf '\nAll tests passed\n'
