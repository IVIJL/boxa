#!/bin/bash
# Plain-bash assertions for lib/cert.sh — the per-project cert lifecycle.
# Companion to tests/https.sh (lib/https.sh) and tests/dns-status.sh
# (HTTPS section of `dns-install.sh status`).
#
# Usage: bash tests/cert.sh
#
# Scope:
#   - SAN computation matches the documented 4-entry layout
#   - meta write/read round-trips byte-for-byte through the parser
#   - _cert::should_regenerate fires on each trigger in the matrix and
#     stays quiet when nothing has drifted
#   - _cert::write_tls_yml is content-compare-then-write (idempotent)
#   - ensure_project_cert end-to-end against a real mkcert when one is on
#     PATH; otherwise the mkcert-dependent block is SKIPPED loudly so a
#     CI runner without mkcert still exercises the rest of the contract.
#
# We override `_mkcert::ca_fingerprint` in the parser-only blocks so the
# trigger matrix is testable without mkcert installed. The end-to-end
# block uses the real binary so we don't paper over an integration bug
# (mkcert flag changes, openssl extraction breakage, etc.).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Sandbox every host-side path the libs touch so the test never reads
# or writes the user's real ~/.config/boxa state.
_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

export BOXA_HTTPS_CONF="$_TMPROOT/https.conf"
export BOXA_DNS_CONF="$_TMPROOT/dns.conf"
export BOXA_CERTS_DIR="$_TMPROOT/certs"
export BOXA_CERT_TLS_DIR="$_TMPROOT/traefik-dynamic"

# Seed dns.conf so boxa::external_provider returns a deterministic value
# instead of inheriting whatever the host has configured.
cat > "$BOXA_DNS_CONF" <<EOF
active_domain=test
external_provider=sslip.io
EOF

# shellcheck source-path=SCRIPTDIR source=../lib/naming.sh disable=SC1091
source "$BOXA_DIR/lib/naming.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/https.sh disable=SC1091
source "$BOXA_DIR/lib/https.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/mkcert.sh disable=SC1091
source "$BOXA_DIR/lib/mkcert.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/cert.sh disable=SC1091
source "$BOXA_DIR/lib/cert.sh"

fail_count=0
skip_count=0

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

assert_true() {
    local label="$1"; shift
    if "$@"; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      expected truthy, got rc=%s\n' "$label" "$?"
        fail_count=$((fail_count + 1))
    fi
}

assert_false() {
    local label="$1"; shift
    if "$@"; then
        printf 'FAIL  %s\n      expected falsy, got rc=0\n' "$label"
        fail_count=$((fail_count + 1))
    else
        printf 'PASS  %s\n' "$label"
    fi
}

note_skip() {
    printf 'SKIP  %s\n' "$1"
    skip_count=$((skip_count + 1))
}

reset_certs_dir() {
    rm -rf "$BOXA_CERTS_DIR" "$BOXA_CERT_TLS_DIR"
    mkdir -p "$BOXA_CERTS_DIR" "$BOXA_CERT_TLS_DIR"
}

# --- SAN computation ---------------------------------------------------------

sans_csv="$(_cert::compute_sans my-app)"
assert_eq "compute_sans 4 entries, .test + sslip.io + wildcards" \
    "my-app.test,*.my-app.test,my-app.127.0.0.1.sslip.io,*.my-app.127.0.0.1.sslip.io" \
    "$sans_csv"

# Provider switch flows into the last two SANs only.
cat > "$BOXA_DNS_CONF" <<EOF
active_domain=test
external_provider=nip.io
EOF
boxa::reset_dns_cache
sans_csv="$(_cert::compute_sans my-app)"
assert_eq "compute_sans honors external_provider override" \
    "my-app.test,*.my-app.test,my-app.127.0.0.1.nip.io,*.my-app.127.0.0.1.nip.io" \
    "$sans_csv"

# Restore the default for the remainder of the suite.
cat > "$BOXA_DNS_CONF" <<EOF
active_domain=test
external_provider=sslip.io
EOF
boxa::reset_dns_cache

# --- Meta round-trip ---------------------------------------------------------

reset_certs_dir
mkdir -p "$BOXA_CERTS_DIR"
# Stub mkcert helpers so _cert::write_meta can complete without a real
# binary. _cert::extract_expires_epoch needs an openssl-readable pem, so
# we hand it back an empty value instead — that path is the documented
# "BSD/GNU date couldn't parse" fallback and is exercised exactly here.
# These overrides are picked up via name lookup from lib/cert.sh; the
# SC2317 disable below tells shellcheck not to flag the lookup as
# "unreachable".
# shellcheck disable=SC2317
_mkcert::ca_fingerprint() { printf '%s' "deadbeef0123"; }
# shellcheck disable=SC2317
_mkcert::version() { printf '%s' "1.4.4"; }
# shellcheck disable=SC2317
_cert::extract_expires_epoch() { return 1; }

# Synthesize a fake pem so _cert::write_meta does not error out on stat.
: > "$BOXA_CERTS_DIR/foo.pem"

_cert::write_meta foo
_cert::read_meta "$BOXA_CERTS_DIR/foo.meta" rt
assert_eq "meta round-trip: ca_fingerprint" "deadbeef0123" "${rt_ca_fingerprint-}"
assert_eq "meta round-trip: mkcert_version" "1.4.4"        "${rt_mkcert_version-}"
assert_eq "meta round-trip: external_provider" "sslip.io"  "${rt_external_provider-}"
assert_eq "meta round-trip: sans" \
    "foo.test,*.foo.test,foo.127.0.0.1.sslip.io,*.foo.127.0.0.1.sslip.io" \
    "${rt_sans-}"

# --- Trigger matrix ----------------------------------------------------------

reset_certs_dir
project=app
pem="$BOXA_CERTS_DIR/${project}.pem"
key="$BOXA_CERTS_DIR/${project}.key"
meta="$BOXA_CERTS_DIR/${project}.meta"

# 1. All missing → regen.
assert_true "should_regenerate: missing artifacts triggers regen" \
    _cert::should_regenerate "$project"
assert_eq "reason: missing" "missing cert/key/meta" "$_BOXA_CERT_LAST_REASON"

# 2. All present + fresh + matching fingerprint + matching SANs → no regen.
now_epoch="$(date +%s)"
far_future=$((now_epoch + 86400 * 800))
: > "$pem"
: > "$key"
current_sans="$(_cert::compute_sans "$project")"
cat > "$meta" <<EOF
project=$project
issued_at=2026-05-13T10:00:00Z
expires_at=$far_future
ca_fingerprint=deadbeef0123
mkcert_version=1.4.4
external_provider=sslip.io
sans=$current_sans
EOF
assert_false "should_regenerate: nothing drifted, no regen" \
    _cert::should_regenerate "$project"

# 3. Stale expiry (within BOXA_CERT_EXPIRY_WARN_DAYS) → regen.
near_expiry=$((now_epoch + 86400 * 3))
sed -i.bak "s/^expires_at=.*/expires_at=$near_expiry/" "$meta"
assert_true "should_regenerate: stale expiry triggers regen" \
    _cert::should_regenerate "$project"
assert_eq "reason: expiry" \
    "expires within ${BOXA_CERT_EXPIRY_WARN_DAYS} days" \
    "$_BOXA_CERT_LAST_REASON"

# Restore fresh expiry for subsequent assertions.
sed -i.bak "s/^expires_at=.*/expires_at=$far_future/" "$meta"

# 4. CA fingerprint drift → regen.
sed -i.bak 's/^ca_fingerprint=.*/ca_fingerprint=different_fp/' "$meta"
assert_true "should_regenerate: CA fingerprint drift triggers regen" \
    _cert::should_regenerate "$project"
assert_eq "reason: CA drift" "root CA fingerprint changed" \
    "$_BOXA_CERT_LAST_REASON"
sed -i.bak 's/^ca_fingerprint=.*/ca_fingerprint=deadbeef0123/' "$meta"

# 5. SAN drift (e.g. provider switched) → regen.
cat > "$BOXA_DNS_CONF" <<EOF
active_domain=test
external_provider=traefik.me
EOF
boxa::reset_dns_cache
assert_true "should_regenerate: SAN drift triggers regen" \
    _cert::should_regenerate "$project"
assert_eq "reason: SAN drift" \
    "SAN set changed (provider/scheme drift)" \
    "$_BOXA_CERT_LAST_REASON"
cat > "$BOXA_DNS_CONF" <<EOF
active_domain=test
external_provider=sslip.io
EOF
boxa::reset_dns_cache

# 6. CAROOT-unreadable (mkcert -uninstall scenario) → regen.
# shellcheck disable=SC2317
_mkcert::ca_fingerprint() { return 1; }
assert_true "should_regenerate: CAROOT unreadable triggers regen" \
    _cert::should_regenerate "$project"
assert_eq "reason: CAROOT unreadable" \
    "rootCA fingerprint unreadable (CAROOT missing?)" \
    "$_BOXA_CERT_LAST_REASON"
# shellcheck disable=SC2317
_mkcert::ca_fingerprint() { printf '%s' "deadbeef0123"; }

rm -f "$meta.bak"

# --- write_tls_yml idempotency ----------------------------------------------

reset_certs_dir
_cert::write_tls_yml "$project"
out="$BOXA_CERT_TLS_DIR/${project}-tls.yml"
mtime_before=""
if [ -f "$out" ]; then
    mtime_before="$(stat -c %Y "$out" 2>/dev/null || stat -f %m "$out" 2>/dev/null || true)"
fi
# Sleep a second so a rewrite would change mtime; lower-resolution stat
# on macOS would otherwise collapse the two calls into the same second.
sleep 1
_cert::write_tls_yml "$project"
mtime_after="$(stat -c %Y "$out" 2>/dev/null || stat -f %m "$out" 2>/dev/null || true)"
assert_eq "write_tls_yml: second call is a content-compare noop" \
    "$mtime_before" "$mtime_after"

# Touch the file to inject drift, then verify the next write rewrites it.
echo "stale content" > "$out"
_cert::write_tls_yml "$project"
if grep -q "${project}.pem" "$out" && grep -q "${project}.key" "$out"; then
    printf 'PASS  %s\n' "write_tls_yml: drifted content gets rewritten"
else
    printf 'FAIL  %s\n      file contents: %s\n' \
        "write_tls_yml: drifted content gets rewritten" \
        "$(cat "$out")"
    fail_count=$((fail_count + 1))
fi

# --- End-to-end with real mkcert (skipped when binary is missing) ------------

# Drop the function stubs so the real binary's CAROOT + fingerprint are
# used. `unset -f` removes the override outright (bash does NOT restore
# the previously-sourced original), so we re-source lib/mkcert.sh and
# lib/cert.sh afterwards to bring the genuine implementations back. The
# cache reset is needed too — _BOXA_MKCERT_BIN may carry over from
# earlier resolve_bin calls in this test that found no usable binary.
unset -f _mkcert::ca_fingerprint _mkcert::version _cert::extract_expires_epoch
# shellcheck source-path=SCRIPTDIR source=../lib/mkcert.sh disable=SC1091
source "$BOXA_DIR/lib/mkcert.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/cert.sh disable=SC1091
source "$BOXA_DIR/lib/cert.sh"
boxa::reset_mkcert_cache

if _mkcert::resolve_bin >/dev/null 2>&1; then
    reset_certs_dir
    project=e2e
    if ensure_project_cert "$project" >/dev/null 2>&1; then
        pem="$BOXA_CERTS_DIR/${project}.pem"
        key="$BOXA_CERTS_DIR/${project}.key"
        meta="$BOXA_CERTS_DIR/${project}.meta"
        tls_yml="$BOXA_CERT_TLS_DIR/${project}-tls.yml"
        assert_true "e2e: leaf pem created"         test -s "$pem"
        assert_true "e2e: leaf key created"         test -s "$key"
        assert_true "e2e: meta file created"        test -s "$meta"
        assert_true "e2e: Traefik TLS yml created"  test -s "$tls_yml"

        if command -v openssl >/dev/null 2>&1; then
            caroot="$(_mkcert::caroot)"
            assert_true "e2e: openssl verifies leaf against CAROOT" \
                openssl verify -CAfile "$caroot/rootCA.pem" "$pem"

            # All four SANs must show up in the leaf's X509 DNS names.
            san_list="$(openssl x509 -in "$pem" -noout -ext subjectAltName \
                2>/dev/null | tr ',' '\n' | grep -oE 'DNS:[^,]+' \
                | sed 's/^DNS://' | sort -u)"
            for expected in \
                "${project}.test" \
                "*.${project}.test" \
                "${project}.127.0.0.1.sslip.io" \
                "*.${project}.127.0.0.1.sslip.io"; do
                if grep -qxF "$expected" <<< "$san_list"; then
                    printf 'PASS  e2e: SAN present — %s\n' "$expected"
                else
                    printf 'FAIL  e2e: SAN missing — %s\n      got:\n%s\n' \
                        "$expected" "$san_list"
                    fail_count=$((fail_count + 1))
                fi
            done
        else
            note_skip "e2e: openssl not available — skipping cert verification"
        fi

        # Second call with no drift must be a noop (no regen).
        mtime_before="$(stat -c %Y "$pem" 2>/dev/null \
                       || stat -f %m "$pem" 2>/dev/null || true)"
        sleep 1
        ensure_project_cert "$project" >/dev/null 2>&1
        mtime_after="$(stat -c %Y "$pem" 2>/dev/null \
                      || stat -f %m "$pem" 2>/dev/null || true)"
        assert_eq "e2e: second ensure_project_cert is a noop" \
            "$mtime_before" "$mtime_after"

        # Stale expiry forces a regen on the next call.
        near_expiry=$(( $(date +%s) + 86400 * 3 ))
        sed -i.bak "s/^expires_at=.*/expires_at=$near_expiry/" "$meta"
        sleep 1
        ensure_project_cert "$project" >/dev/null 2>&1
        mtime_after_regen="$(stat -c %Y "$pem" 2>/dev/null \
                            || stat -f %m "$pem" 2>/dev/null || true)"
        if [ "$mtime_after_regen" != "$mtime_after" ]; then
            printf 'PASS  e2e: stale expires_at triggers regeneration\n'
        else
            printf 'FAIL  e2e: stale expires_at did not trigger regen\n      pem mtime unchanged at %s\n' \
                "$mtime_after"
            fail_count=$((fail_count + 1))
        fi
        rm -f "$meta.bak"
    else
        note_skip "e2e: ensure_project_cert failed (likely CA not yet installed via 'mkcert -install')"
    fi
else
    note_skip "e2e: no usable mkcert >= ${BOXA_MKCERT_MIN_VERSION} on PATH — skipping end-to-end block"
fi

# --- Summary -----------------------------------------------------------------

if [ "$fail_count" -eq 0 ]; then
    if [ "$skip_count" -gt 0 ]; then
        printf '\nAll assertions passed (%d block(s) skipped).\n' "$skip_count"
    else
        printf '\nAll assertions passed.\n'
    fi
    exit 0
fi
printf '\n%d assertion(s) failed.\n' "$fail_count"
exit 1
