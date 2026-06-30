#!/bin/bash
# Unit assertions for `_dns::install`'s mode/fallback decision tree in
# scripts/dns-install.sh — specifically the distinction between a FIXABLE
# resolver-setup failure (degraded: loud, non-zero, preferred=local +
# active_domain=sslip so URLs still resolve and self-heal retries) and a
# DURABLE fallback (port 53 conflict / unsupported platform → calm external).
#
# Usage: bash tests/dns-install.sh
#
# Sources the script (guarded `main` does not fire) and overrides the
# platform-specific writers + probes so the decision tree runs deterministically
# on any host, with no real sudo / resolver mutation.
#
# The function overrides below are invoked indirectly (through `_dns::install`),
# which shellcheck cannot see — disable the unreachable-command warning file-wide.
# shellcheck disable=SC2317

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

export BOXA_DNS_CONF="$_TMPROOT/dns.conf"
# Keep the CA-install side effects out of these resolver-only assertions.
export BOXA_HTTPS_CONF="$_TMPROOT/https.conf"

# shellcheck source=../scripts/dns-install.sh disable=SC1091
source "$BOXA_DIR/scripts/dns-install.sh"
# dns-install.sh sets `set -euo pipefail`; relax it so a non-zero return from
# the function under test does not abort the harness.
set +e +u +o pipefail

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

assert_match() {
    local label="$1" haystack="$2" pattern="$3"
    if grep -qE "$pattern" <<< "$haystack"; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      pattern: %q\n      output:\n%s\n' \
            "$label" "$pattern" "$haystack"
        fail_count=$((fail_count + 1))
    fi
}

conf_val() {
    # Echo the value of key $1 from the dns.conf under test (empty if absent).
    [ -f "$BOXA_DNS_CONF" ] || return 0
    grep -E "^$1=" "$BOXA_DNS_CONF" | tail -1 | cut -d= -f2-
}

reset_conf() { rm -f "$BOXA_DNS_CONF"; boxa::reset_dns_cache; }

# Neutralise real side effects shared across cases.
_dns::port_53_held_by_other() { return 1; }   # port free unless a case overrides
_dns::resolver_works()        { return 1; }   # post-write verify deferred
_dns::sudo_available()        { return 0; }
boxa::reset_dns_cache()       { :; }            # no live container cache to poke

# --- Case 1: fixable resolver-write failure under auto → DEGRADED ------------

reset_conf
_dns::detect_platform()        { echo "linux-resolved"; }
_dns::install_linux_resolved() { _warn "simulated write failure"; return 1; }

out="$(_dns::install auto 2>&1)"; rc=$?
assert_eq    "degraded: non-zero rc"          "1"                    "$rc"
assert_match "degraded: loud banner"          "$out" 'was NOT set up'
assert_eq    "degraded: preferred=local"      "local"                "$(conf_val preferred)"
assert_eq    "degraded: active_domain=sslip"  "127.0.0.1.sslip.io"   "$(conf_val active_domain)"

# --- Case 2: same failure under --local → fail loud, NO degraded write -------

reset_conf
out="$(_dns::install local 2>&1)"; rc=$?
assert_eq    "local-fail: non-zero rc"        "1"   "$rc"
assert_eq    "local-fail: no dns.conf written" ""   "$(conf_val preferred)"

# --- Case 3: port 53 conflict under auto → DURABLE external (calm) -----------

reset_conf
_dns::port_53_held_by_other() { return 0; }
out="$(_dns::install auto 2>&1)"; rc=$?
assert_eq    "conflict: rc 0"                 "0"          "$(printf '%s' "$rc")"
assert_eq    "conflict: preferred=external"   "external"   "$(conf_val preferred)"
assert_match "conflict: no degraded banner"   "$out" 'External mode active'
_dns::port_53_held_by_other() { return 1; }

# --- Case 4: unsupported platform under auto → DURABLE external (calm) -------

reset_conf
_dns::detect_platform() { echo "unsupported"; }
out="$(_dns::install auto 2>&1)"; rc=$?
assert_eq    "unsupported: rc 0"              "0"          "$rc"
assert_eq    "unsupported: preferred=external" "external"  "$(conf_val preferred)"

# --- Case 5: successful resolver setup under auto → local/.test -------------

reset_conf
_dns::detect_platform()        { echo "linux-resolved"; }
_dns::install_linux_resolved() { return 0; }
out="$(_dns::install auto 2>&1)"; rc=$?
assert_eq    "success: rc 0"                  "0"       "$rc"
assert_eq    "success: preferred=local"       "local"   "$(conf_val preferred)"
assert_eq    "success: active_domain=test"    "test"    "$(conf_val active_domain)"

echo
if [ "$fail_count" -eq 0 ]; then
    echo "All assertions passed."
else
    echo "$fail_count assertion(s) failed."
    exit 1
fi
