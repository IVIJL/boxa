#!/bin/bash
# Plain-bash assertions for filtering firewall-blocked DNS queries.
# Usage: bash tests/blocked.sh

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

function_file="$_TMPROOT/blocked-function.sh"
awk '
    /^blocked_domains_from_dnsmasq\(\) \{$/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
' "$BOXA_DIR/docker-run.sh" > "$function_file"
# shellcheck source=/dev/null
source "$function_file"

queries=$'api.test\napp.127.0.0.1.sslip.io\nlocalhost\ncdn.allowed.example\nblocked.example'
rules=$'ipset=/allowed.example/allowed-domains\naddress=/test/172.30.0.4\naddress=/127.0.0.1.sslip.io/172.30.0.4\naddress=/localhost/172.30.0.4'
assert_eq "dnsmasq ipset and address rules exclude covered queries" \
    'blocked.example' \
    "$(blocked_domains_from_dnsmasq "$rules" "$queries")"

rules_without_test=$'ipset=/allowed.example/allowed-domains\naddress=/127.0.0.1.sslip.io/172.30.0.4\naddress=/localhost/172.30.0.4'
assert_eq "removing an address rule makes its query blocked again" \
    $'api.test\nblocked.example' \
    "$(blocked_domains_from_dnsmasq "$rules_without_test" "$queries")"

assert_eq "an arbitrary runtime address suffix excludes its subdomains" \
    'blocked.example' \
    "$(blocked_domains_from_dnsmasq \
        'address=/runtime.internal/172.30.0.4' \
        $'service.runtime.internal\nblocked.example')"

# shellcheck disable=SC2016  # Matching literal shell source text below.
assert_eq "the blocked handler calls the shared filter once" 1 \
    "$(grep -c 'blocked_domains_from_dnsmasq "\$dnsmasq_rules" "\$all_queried"' \
        "$BOXA_DIR/docker-run.sh")"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d blocked test(s) failed.\n' "$fail_count" >&2
    exit 1
fi

printf '\nAll blocked tests passed.\n'
