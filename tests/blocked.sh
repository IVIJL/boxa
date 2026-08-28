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

queries=$'api.test\napp.127.0.0.1.sslip.io\nlocalhost\nprinter\ncdn.allowed.example\nblocked.example'
rules=$'ipset=/allowed.example/allowed-domains\naddress=/test/172.30.0.4\naddress=/127.0.0.1.sslip.io/172.30.0.4'
hosts_names=$'localhost\nprinter'
assert_eq "dnsmasq ipset and address rules exclude covered queries" \
    'blocked.example' \
    "$(blocked_domains_from_dnsmasq "$rules" "$queries" "$hosts_names")"

rules_without_test=$'ipset=/allowed.example/allowed-domains\naddress=/127.0.0.1.sslip.io/172.30.0.4'
assert_eq "removing an address rule makes its query blocked again" \
    $'api.test\nblocked.example' \
    "$(blocked_domains_from_dnsmasq "$rules_without_test" "$queries" "$hosts_names")"

assert_eq "a name from the container hosts file is excluded" \
    'blocked.example' \
    "$(blocked_domains_from_dnsmasq '' $'localhost\nblocked.example' 'localhost')"

assert_eq "a single-label name absent from the hosts file remains blocked" \
    'boxa-other' \
    "$(blocked_domains_from_dnsmasq '' 'boxa-other' 'localhost')"

assert_eq "an arbitrary runtime address suffix excludes its subdomains" \
    'blocked.example' \
    "$(blocked_domains_from_dnsmasq \
        'address=/runtime.internal/172.30.0.4' \
        $'service.runtime.internal\nblocked.example' '')"

# Applying the pure filter separately models two Containers with inverse
# runtime allow rules. Both actual per-Container denials survive the union.
divergent_queries=$'blocked-by-a.example\nblocked-by-b.example'
divergent_blocked=$(printf '%s\n%s\n' \
    "$(blocked_domains_from_dnsmasq \
        'ipset=/blocked-by-b.example/allowed-domains' "$divergent_queries" '')" \
    "$(blocked_domains_from_dnsmasq \
        'ipset=/blocked-by-a.example/allowed-domains' "$divergent_queries" '')" \
    | sort -u)
assert_eq "divergent per-container rules preserve both blocked domains" \
    "$divergent_queries" "$divergent_blocked"

# shellcheck disable=SC2016  # Matching literal shell source text below.
assert_eq "the blocked handler filters each container's own queries" 1 \
    "$(grep -c 'blocked_domains_from_dnsmasq "\$dnsmasq_rules" "\$queried" "\$hosts_names"' \
        "$BOXA_DIR/docker-run.sh")"
assert_eq "the blocked handler does not pool queries before filtering" 0 \
    "$(grep -cE 'all_queried|first_container' "$BOXA_DIR/docker-run.sh" || true)"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d blocked test(s) failed.\n' "$fail_count" >&2
    exit 1
fi

printf '\nAll blocked tests passed.\n'
