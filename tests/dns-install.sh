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

# --- WSL2 artifact provisioning follows the functional probe ----------------

wsl_bin="$_TMPROOT/wsl-bin"
wsl_artifacts="$_TMPROOT/wsl-artifacts"
wsl_uninstall_log="$_TMPROOT/wsl-uninstall.log"
mkdir -p "$wsl_bin" "$wsl_artifacts"
cat > "$wsl_bin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$wsl_bin/powershell.exe" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$wsl_bin/systemctl" "$wsl_bin/powershell.exe"
PATH="$wsl_bin:$PATH"
export PATH

TEST_INSTALL_STATE="windows-broken"
TEST_INSTALL_WSL="ok"
TEST_INSTALL_WINDOWS="broken"
TEST_INSTALL_CA_MARKER="$_TMPROOT/ca-installed"
_dns::detect_platform() { printf 'wsl2\n'; }
_dns::probe_paths() {
    _DNS_PATH_PROBE_STATE="$TEST_INSTALL_STATE"
    _DNS_WSL_PROBE_RESULT="$TEST_INSTALL_WSL"
    _DNS_WINDOWS_PROBE_RESULT="$TEST_INSTALL_WINDOWS"
    _DNS_PROBE_CAUSE="WSL2 mirrored networking (networkingMode=mirrored) blocks loopback DNS on port 53"
}
_dns::install_linux_resolved() { touch "$wsl_artifacts/resolved"; }
_dns::install_wsl2_nrpt() { touch "$wsl_artifacts/nrpt"; }
_dns::uninstall_resolved_drop_in() { printf 'resolved\n' >> "$wsl_uninstall_log"; }
_dns::uninstall_wsl2_nrpt() { printf 'nrpt\n' >> "$wsl_uninstall_log"; }
_dns::prime_sudo() { :; }
_dns::install_ca() { touch "$TEST_INSTALL_CA_MARKER"; }

reset_conf
rm -f "$wsl_artifacts/resolved" "$wsl_artifacts/nrpt" \
    "$wsl_uninstall_log" "$TEST_INSTALL_CA_MARKER"
out="$(main install --auto 2>&1)"; rc=$?
assert_eq "WSL broken fresh: rc 0" "0" "$rc"
assert_eq "WSL broken fresh: preferred stays local" \
    "local" "$(conf_val preferred)"
assert_eq "WSL broken fresh: active domain is external" \
    "127.0.0.1.sslip.io" "$(conf_val active_domain)"
assert_match "WSL broken fresh: degradation banner" "$out" \
    '\.test DNS is degraded:.*mirrored networking'
assert_eq "WSL broken fresh: resolved drop-in skipped" \
    "missing" "$([ -e "$wsl_artifacts/resolved" ] && printf present || printf missing)"
assert_eq "WSL broken fresh: NRPT skipped" \
    "missing" "$([ -e "$wsl_artifacts/nrpt" ] && printf present || printf missing)"
assert_eq "WSL broken fresh: CA still provisioned" \
    "present" "$([ -e "$TEST_INSTALL_CA_MARKER" ] && printf present || printf missing)"

# Existing artifacts are deliberately left untouched when a later probe
# fails; none of the uninstall helpers belongs to this transition path.
touch "$wsl_artifacts/resolved" "$wsl_artifacts/nrpt"
_dns::install auto >/dev/null 2>&1
assert_eq "WSL degrade-later: resolved drop-in remains" \
    "present" "$([ -e "$wsl_artifacts/resolved" ] && printf present || printf missing)"
assert_eq "WSL degrade-later: NRPT remains" \
    "present" "$([ -e "$wsl_artifacts/nrpt" ] && printf present || printf missing)"
assert_eq "WSL degrade-later: no uninstall helper called" \
    "missing" "$([ -e "$wsl_uninstall_log" ] && printf present || printf missing)"

# A later passing probe enters both normal installers. Their writes are
# naturally idempotent here just as the real drop-in rewrite and NRPT
# existence guard are; a repeated run leaves the same artifact set.
rm -f "$wsl_artifacts/resolved" "$wsl_artifacts/nrpt"
TEST_INSTALL_STATE="both-ok"
TEST_INSTALL_WSL="ok"
TEST_INSTALL_WINDOWS="ok"
_dns::install auto >/dev/null 2>&1
assert_eq "WSL heal-later: resolved drop-in installed" \
    "present" "$([ -e "$wsl_artifacts/resolved" ] && printf present || printf missing)"
assert_eq "WSL heal-later: NRPT installed" \
    "present" "$([ -e "$wsl_artifacts/nrpt" ] && printf present || printf missing)"
assert_eq "WSL heal-later: active domain returns local" \
    "test" "$(conf_val active_domain)"
wsl_artifacts_before="$(cksum "$wsl_artifacts/resolved" "$wsl_artifacts/nrpt")"
_dns::install auto >/dev/null 2>&1
wsl_artifacts_after="$(cksum "$wsl_artifacts/resolved" "$wsl_artifacts/nrpt")"
assert_eq "WSL heal-later: repeated install is idempotent" \
    "$wsl_artifacts_before" "$wsl_artifacts_after"

# --- Functional WSL2 path probe matrix --------------------------------------

# Restore the real probe functions after the install-specific overrides above.
# shellcheck source=../scripts/dns-install.sh disable=SC1091
source "$BOXA_DIR/scripts/dns-install.sh"
set +e +u +o pipefail

probe_bin="$_TMPROOT/probe-bin"
mkdir -p "$probe_bin"
cat > "$probe_bin/dig" <<'EOF'
#!/bin/sh
[ "${TEST_DIG_RESULT:-broken}" = "ok" ] && printf '127.0.0.1\n'
exit 0
EOF
cat > "$probe_bin/powershell.exe" <<'EOF'
#!/bin/sh
[ -z "${TEST_POWERSHELL_SLEEP:-}" ] || sleep "$TEST_POWERSHELL_SLEEP"
exit "${TEST_POWERSHELL_RC:-2}"
EOF
chmod +x "$probe_bin/dig" "$probe_bin/powershell.exe"
PATH="$probe_bin:$PATH"
export PATH TEST_DIG_RESULT TEST_POWERSHELL_RC
export TEST_POWERSHELL_SLEEP BOXA_DNS_INTEROP_TIMEOUT_SECONDS
export BOXA_DNS_INTEROP_KILL_GRACE_SECONDS

TEST_RESOLVER_STATE=running
_dns::resolver_container_state() { printf '%s' "$TEST_RESOLVER_STATE"; }

assert_probe_case() {
    local label="$1" dig_result="$2" powershell_rc="$3"
    local expected_state="$4" expected_wsl="$5" expected_windows="$6"
    TEST_DIG_RESULT="$dig_result"
    TEST_POWERSHELL_RC="$powershell_rc"
    _dns::probe_paths >/dev/null
    assert_eq "$label: verdict" "$expected_state" "$_DNS_PATH_PROBE_STATE"
    assert_eq "$label: WSL side" "$expected_wsl" "$_DNS_WSL_PROBE_RESULT"
    assert_eq "$label: Windows side" "$expected_windows" "$_DNS_WINDOWS_PROBE_RESULT"
}

assert_probe_case "both paths ok" ok 0 both-ok ok ok
assert_probe_case "Windows path broken" ok 1 windows-broken ok broken
assert_probe_case "WSL path broken" broken 0 wsl-broken broken ok
assert_probe_case "both paths broken" broken 1 wsl-broken broken broken
assert_probe_case "PowerShell tooling error is fail-safe" ok 2 both-ok ok unknown

TEST_POWERSHELL_SLEEP=1
BOXA_DNS_INTEROP_TIMEOUT_SECONDS=0.05
BOXA_DNS_INTEROP_KILL_GRACE_SECONDS=0.05
assert_probe_case "PowerShell hang is timeout-bounded" ok 0 both-ok ok unknown
TEST_POWERSHELL_SLEEP=""
unset BOXA_DNS_INTEROP_TIMEOUT_SECONDS BOXA_DNS_INTEROP_KILL_GRACE_SECONDS

TEST_RESOLVER_STATE=stopped
TEST_DIG_RESULT=broken
TEST_POWERSHELL_RC=1
run_probe_paths() { _dns::probe_paths; }
run_probe_paths >/dev/null
assert_eq "resolver down: verdict" "resolver-not-running" "$_DNS_PATH_PROBE_STATE"
assert_eq "resolver down: WSL not run" "not-run" "$_DNS_WSL_PROBE_RESULT"
assert_eq "resolver down: Windows not run" "not-run" "$_DNS_WINDOWS_PROBE_RESULT"

# Configuration inspection names a cause only; it remains outside the probe
# state matrix above.
wslconfig_fixture="$_TMPROOT/.wslconfig"
cat > "$wslconfig_fixture" <<'EOF'
[wsl2]
networkingMode=nat
localhostForwarding=false
EOF
export BOXA_WSLCONFIG_FILE="$wslconfig_fixture"
assert_eq "cause names disabled forwarding" \
    "WSL2 localhost forwarding is disabled (localhostForwarding=false)" \
    "$(_dns::probe_cause)"

# --- Automatic degradation transitions -------------------------------------

seed_mode() {
    _dns::write_mode "$1" "$2" "${3:-sslip.io}"
}

TEST_AUTO_STATE="both-ok"
TEST_AUTO_WSL="ok"
TEST_AUTO_WINDOWS="ok"
TEST_AUTO_CAUSE="WSL2 mirrored networking (networkingMode=mirrored) blocks loopback DNS on port 53"
_dns::detect_platform() { printf 'wsl2\n'; }
_dns::probe_paths() {
    _DNS_PATH_PROBE_STATE="$TEST_AUTO_STATE"
    _DNS_WSL_PROBE_RESULT="$TEST_AUTO_WSL"
    _DNS_WINDOWS_PROBE_RESULT="$TEST_AUTO_WINDOWS"
    _DNS_PROBE_CAUSE="$TEST_AUTO_CAUSE"
}

reset_conf
seed_mode local test
TEST_AUTO_STATE="windows-broken"
out="$(_dns::auto_transition 2>&1)"
assert_eq "auto-degrade: preferred stays local" "local" "$(conf_val preferred)"
assert_eq "auto-degrade: active domain flips external" \
    "127.0.0.1.sslip.io" "$(conf_val active_domain)"
assert_match "auto-degrade: names cause" "$out" 'mirrored networking'
assert_match "auto-degrade: says system limitation, not bug" "$out" \
    'system limitation, not a boxa bug'
assert_match "auto-degrade: gives external URL form" "$out" \
    'https://<port>\.<project>\.127\.0\.0\.1\.sslip\.io'
assert_match "auto-degrade: keeps Container .test" "$out" \
    '\.test keeps working inside Containers'
assert_match "auto-degrade: promises automatic recovery" "$out" \
    'switch back to \.test automatically'

out_repeat="$(_dns::auto_transition 2>&1)"
assert_match "auto-degrade: banner repeats" "$out_repeat" \
    '^.*\.test DNS is degraded:'

TEST_AUTO_STATE="both-ok"
out="$(_dns::auto_transition 2>&1)"
assert_eq "auto-heal: preferred stays local" "local" "$(conf_val preferred)"
assert_eq "auto-heal: active domain flips local" "test" "$(conf_val active_domain)"
assert_match "auto-heal: restored confirmation" "$out" '\.test DNS restored'

reset_conf
seed_mode external 127.0.0.1.sslip.io
TEST_AUTO_STATE="windows-broken"
_dns::auto_transition >/dev/null 2>&1
assert_eq "user external: preferred untouched" "external" "$(conf_val preferred)"
assert_eq "user external: active domain untouched" \
    "127.0.0.1.sslip.io" "$(conf_val active_domain)"

reset_conf
seed_mode local 127.0.0.1.sslip.io
TEST_AUTO_STATE="resolver-not-running"
_dns::auto_transition >/dev/null 2>&1
assert_eq "resolver down: no transition" \
    "127.0.0.1.sslip.io" "$(conf_val active_domain)"

TEST_AUTO_STATE="both-ok"
TEST_AUTO_WINDOWS="unknown"
_dns::auto_transition >/dev/null 2>&1
assert_eq "tooling failure: no transition" \
    "127.0.0.1.sslip.io" "$(conf_val active_domain)"

reset_conf
seed_mode local test
TEST_AUTO_STATE="wsl-broken"
TEST_AUTO_WSL="broken"
_dns::auto_transition >/dev/null 2>&1
assert_eq "partial tooling failure: no degrade transition" \
    "test" "$(conf_val active_domain)"
TEST_AUTO_WSL="ok"
TEST_AUTO_WINDOWS="ok"

reset_conf
seed_mode local 127.0.0.1.sslip.io
_dns::detect_platform() { printf 'unsupported\n'; }
TEST_AUTO_STATE="both-ok"
_dns::auto_transition >/dev/null 2>&1
assert_eq "non-WSL: no transition" \
    "127.0.0.1.sslip.io" "$(conf_val active_domain)"

echo
if [ "$fail_count" -eq 0 ]; then
    echo "All assertions passed."
else
    echo "$fail_count assertion(s) failed."
    exit 1
fi
