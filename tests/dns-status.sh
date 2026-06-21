#!/bin/bash
# Integration assertions for the HTTPS section appended to `dns-install.sh
# status` output (HTTPS Phase 8).
#
# Usage: bash tests/dns-status.sh
#
# Drives the real script in a controlled sandbox via BOXA_HTTPS_CONF +
# BOXA_CERTS_DIR overrides, then greps the captured output. We intentionally
# do NOT mock `_dns::detect_platform` or `_dns::resolver_works` — the DNS
# section's contents are platform-dependent and out of scope here; we only
# assert on the new HTTPS lines which are entirely fed by env-isolated state.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

export BOXA_DNS_CONF="$_TMPROOT/dns.conf"
export BOXA_HTTPS_CONF="$_TMPROOT/https.conf"
export BOXA_CERTS_DIR="$_TMPROOT/certs"

fail_count=0

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

# Capture stdout+stderr from a `dns-install.sh status` run. Status itself
# emits the HTTPS section to stdout; the surrounding DNS lines may print
# diagnostics on stderr (resolver verify warning) that don't affect this
# test but we merge streams anyway so the captured string matches what a
# user would see in a terminal.
run_status() {
    bash "$BOXA_DIR/scripts/dns-install.sh" status 2>&1
}

# --- Case 1: no https.conf, no certs dir -------------------------------------

rm -f "$BOXA_HTTPS_CONF"
rm -rf "$BOXA_CERTS_DIR"

out="$(run_status)"
assert_match "no-conf: section header"      "$out" '^HTTPS state:$'
assert_match "no-conf: active=false"        "$out" '^  active: +false$'
assert_match "no-conf: CA not installed"    "$out" '^  CA: +\(not installed\)$'
assert_match "no-conf: trust stores none"   "$out" '^  trust stores: +\(none\)$'
assert_match "no-conf: zero project certs"  "$out" '^  project certs: +0$'
assert_match "no-conf: optout=false"        "$out" '^  optout: +false$'

# --- Case 2: https.conf with CA install + two project meta files ------------

mkdir -p "$BOXA_CERTS_DIR"
cat > "$BOXA_HTTPS_CONF" <<EOF
active=true
optout=false
ca_fingerprint=abc123def456
mkcert_version=1.4.4
ca_installed_at=2026-05-13T10:00:00Z
ca_installed_platforms=linux,windows
EOF

# Two cert meta files. Epoch expiries are stored as integer seconds (see
# lib/cert.sh::_cert::write_meta), matching what openssl emits via
# `notAfter=` after a date conversion. Pick two horizons so the nearer one
# is unambiguously selected as the "nearest expiry" displayed in status.
now_epoch="$(date +%s)"
far_future=$((now_epoch + 86400 * 800))
near_future=$((now_epoch + 86400 * 200))

cat > "$BOXA_CERTS_DIR/foo.meta" <<EOF
project=foo
issued_at=2026-05-13T10:00:00Z
expires_at=$far_future
ca_fingerprint=abc123def456
mkcert_version=1.4.4
external_provider=sslip.io
sans=foo.test,*.foo.test
EOF

cat > "$BOXA_CERTS_DIR/bar.meta" <<EOF
project=bar
issued_at=2026-05-13T10:00:00Z
expires_at=$near_future
ca_fingerprint=abc123def456
mkcert_version=1.4.4
external_provider=sslip.io
sans=bar.test,*.bar.test
EOF

out="$(run_status)"
assert_match "with-certs: active=true"        "$out" '^  active: +true$'
assert_match "with-certs: CA fingerprint"     "$out" '^  CA: +sha256:abc123def456$'
assert_match "with-certs: trust stores"       "$out" '^  trust stores: +linux,windows$'
assert_match "with-certs: count=2 prefix"     "$out" '^  project certs: +2 \(nearest expiry: '
# Derive the expected nearest date from the near_future epoch in the same
# way the renderer does — GNU first, BSD second. Without this we'd be
# hard-coding a date that breaks every time the test runs on a new day.
nearest_date="$(date -u -d "@$near_future" +%Y-%m-%d 2>/dev/null \
               || date -u -r "$near_future" +%Y-%m-%d 2>/dev/null)"
assert_match "with-certs: nearest expiry date" "$out" "nearest expiry: $nearest_date,"
assert_match "with-certs: optout=false"       "$out" '^  optout: +false$'

# --- Case 3: optout=true, certs dir absent -----------------------------------

rm -rf "$BOXA_CERTS_DIR"
cat > "$BOXA_HTTPS_CONF" <<EOF
active=false
optout=true
ca_fingerprint=abc123def456
ca_installed_platforms=linux
EOF

out="$(run_status)"
assert_match "optout: active=false"           "$out" '^  active: +false$'
assert_match "optout: optout=true"            "$out" '^  optout: +true$'
assert_match "optout: CA still shown"         "$out" '^  CA: +sha256:abc123def456$'
assert_match "optout: trust stores linux"     "$out" '^  trust stores: +linux$'
assert_match "optout: zero project certs"     "$out" '^  project certs: +0$'

# --- Case 4: meta file with missing expires_at -------------------------------

mkdir -p "$BOXA_CERTS_DIR"
cat > "$BOXA_HTTPS_CONF" <<EOF
active=true
optout=false
ca_fingerprint=abc123def456
ca_installed_platforms=linux
EOF
# meta with empty expires_at (the openssl read in _cert::write_meta failed)
cat > "$BOXA_CERTS_DIR/baz.meta" <<EOF
project=baz
issued_at=2026-05-13T10:00:00Z
expires_at=
ca_fingerprint=abc123def456
EOF

out="$(run_status)"
# Count still increments; nearest-expiry annotation is suppressed when the
# only meta in the dir has no readable expires_at.
assert_match "no-expiry: count=1, no annotation" "$out" '^  project certs: +1$'

# --- Summary -----------------------------------------------------------------

if [ "$fail_count" -eq 0 ]; then
    printf '\nAll assertions passed.\n'
    exit 0
fi
printf '\n%d assertion(s) failed.\n' "$fail_count"
exit 1
