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

# Function overrides below are invoked indirectly by `_dns::status` after the
# implementation is sourced; shellcheck cannot follow that dynamic dispatch.
# shellcheck disable=SC2317

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

# --- Case 5: WSL2 path probe surfacing --------------------------------------

# Source the real implementation in a subshell, then override only the inputs
# so status rendering is deterministic and cannot contact the real host.
run_mocked_wsl_status() {
    (
        # shellcheck source=../scripts/dns-install.sh disable=SC1091
        source "$BOXA_DIR/scripts/dns-install.sh"
        set +e +u +o pipefail
        _dns::detect_platform() { printf 'wsl2\n'; }
        _dns::resolver_container_state() { printf 'running'; }
        _dns::probe_paths() {
            _DNS_PATH_PROBE_STATE="windows-broken"
            _DNS_WSL_PROBE_RESULT="ok"
            _DNS_WINDOWS_PROBE_RESULT="broken"
            _DNS_PROBE_CAUSE="WSL2 mirrored networking (networkingMode=mirrored) blocks loopback DNS on port 53"
        }
        _dns::status
    ) 2>&1
}

out="$(run_mocked_wsl_status)"
assert_match "wsl-status: probe heading" "$out" '^DNS path probes:$'
assert_match "wsl-status: WSL result" "$out" '^  WSL side: +ok$'
assert_match "wsl-status: Windows result" "$out" '^  Windows side: +broken$'
assert_match "wsl-status: verdict" "$out" '^  Verdict: +windows-broken$'
assert_match "wsl-status: named cause" "$out" '^  Cause: +WSL2 mirrored networking '

# A deterministic non-WSL status keeps the old single Verification surface.
run_mocked_linux_status() {
    (
        # shellcheck source=../scripts/dns-install.sh disable=SC1091
        source "$BOXA_DIR/scripts/dns-install.sh"
        set +e +u +o pipefail
        _dns::detect_platform() { printf 'unsupported\n'; }
        _dns::resolver_container_state() { printf 'running'; }
        _dns::resolver_works() { return 0; }
        _dns::status
    ) 2>&1
}

out="$(run_mocked_linux_status)"
assert_match "non-WSL: existing verification unchanged" "$out" \
    'Verification: \*\.test resolves to 127\.0\.0\.1\.'
if grep -q '^DNS path probes:$' <<< "$out"; then
    printf 'FAIL  non-WSL: no path probe surface\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  non-WSL: no path probe surface\n'
fi

# --- Case 6: doctor reports a broken path as diagnose-only prerequisite -----

doctor_dir="$_TMPROOT/doctor-cli"
mkdir -p "$doctor_dir/lib" "$doctor_dir/scripts" "$doctor_dir/bin" "$doctor_dir/home"
cp "$BOXA_DIR/docker-run.sh" "$doctor_dir/docker-run.sh"
cp -R "$BOXA_DIR/lib/." "$doctor_dir/lib/"
cat > "$doctor_dir/lib/provisioning.sh" <<'EOF'
#!/bin/bash
BOXA_PROVISIONING_STEPS=("stub-step|-|A")
boxa::run_provisioning() {
    BOXA_PROVISIONING_REPAIRED=()
    BOXA_PROVISIONING_OK=("stub-step")
    BOXA_PROVISIONING_FAILED=()
    BOXA_PROVISIONING_SKIPPED=()
    BOXA_PROVISIONING_MISSING=()
    BOXA_PROVISIONING_DECLINED=()
    BOXA_PROVISIONING_PREREQ_MISSING=()
}
boxa::prereq_remedy() { printf 'unused'; }
EOF
cat > "$doctor_dir/scripts/dns-install.sh" <<'EOF'
#!/bin/bash
cat <<'REPORT'
applicable=true
state=windows-broken
wsl=ok
windows=broken
cause=WSL2 mirrored networking (networkingMode=mirrored) blocks loopback DNS on port 53
REPORT
EOF
cat > "$doctor_dir/bin/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$doctor_dir/bin/setsid" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$doctor_dir/docker-run.sh" "$doctor_dir/scripts/dns-install.sh" \
    "$doctor_dir/bin/docker" "$doctor_dir/bin/setsid"

doctor_wslconfig="$doctor_dir/home/.wslconfig"
printf '[wsl2]\nnetworkingMode=mirrored\n' > "$doctor_wslconfig"
doctor_before="$(cksum "$doctor_wslconfig")"
doctor_out="$(HOME="$doctor_dir/home" PATH="$doctor_dir/bin:$PATH" \
    bash "$doctor_dir/docker-run.sh" doctor 2>&1 || true)"
doctor_after="$(cksum "$doctor_wslconfig")"

assert_match "doctor: WSL result" "$doctor_out" '^  WSL side: +ok$'
assert_match "doctor: Windows result" "$doctor_out" '^  Windows side: +broken$'
assert_match "doctor: Environment prerequisite" "$doctor_out" \
    '^      Environment prerequisite: make the WSL2 loopback DNS path reachable\.$'
assert_match "doctor: remove mirrored remediation" "$doctor_out" \
    '^        - remove networkingMode=mirrored$'
assert_match "doctor: forwarding remediation" "$doctor_out" \
    '^        - set localhostForwarding=true$'
assert_match "doctor: shutdown remediation" "$doctor_out" \
    '^      Then run in Windows PowerShell: wsl --shutdown$'
if [ "$doctor_before" = "$doctor_after" ]; then
    printf 'PASS  doctor: .wslconfig remains untouched\n'
else
    printf 'FAIL  doctor: .wslconfig was modified\n'
    fail_count=$((fail_count + 1))
fi

# --- Summary -----------------------------------------------------------------

if [ "$fail_count" -eq 0 ]; then
    printf '\nAll assertions passed.\n'
    exit 0
fi
printf '\n%d assertion(s) failed.\n' "$fail_count"
exit 1
