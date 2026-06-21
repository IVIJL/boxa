#!/bin/bash
# Plain-bash assertions for lib/https.sh. Runs in any bash, no harness needed.
#
# Usage: bash tests/https.sh
#
# Each assertion prints PASS/FAIL with a short label; non-zero exit on any FAIL.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/https.sh disable=SC1091
source "$SCRIPT_DIR/../lib/https.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/mkcert.sh disable=SC1091
source "$SCRIPT_DIR/../lib/mkcert.sh"

# Isolate the test surface from the user's real ~/.config/boxa/https.conf
# by pointing every load + write at a per-test tmp file.
_TMP_HTTPS_CONF="$(mktemp)"
export BOXA_HTTPS_CONF="$_TMP_HTTPS_CONF"
trap 'rm -f "$_TMP_HTTPS_CONF"' EXIT

# Reset the cache and on-disk content. Pass key=value pairs to seed.
seed_https_conf() {
    boxa::reset_https_cache
    : > "$_TMP_HTTPS_CONF"
    local line
    for line in "$@"; do
        printf '%s\n' "$line" >> "$_TMP_HTTPS_CONF"
    done
}

# Force "no https.conf" by pointing at a non-existent file.
clear_https_conf() {
    boxa::reset_https_cache
    rm -f "$_TMP_HTTPS_CONF"
}

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

# --- Defaults when https.conf absent -----------------------------------------

clear_https_conf
assert_false "https_active default false"           boxa::https_active
assert_false "https_optout default false"           boxa::https_optout
assert_eq    "ca_fingerprint default empty"            ""  "$(boxa::ca_fingerprint)"
assert_eq    "mkcert_version default empty"            ""  "$(boxa::mkcert_version)"
assert_eq    "ca_installed_at default empty"           ""  "$(boxa::ca_installed_at)"
assert_eq    "ca_installed_platforms default empty"    ""  "$(boxa::ca_installed_platforms)"

# --- Parsing -----------------------------------------------------------------

seed_https_conf "active=true" "optout=false" "ca_fingerprint=abc123" \
                "mkcert_version=1.4.4" "ca_installed_at=2026-05-13T10:00:00Z" \
                "ca_installed_platforms=linux,windows"
assert_true  "https_active reads true"        boxa::https_active
assert_false "https_optout reads false"       boxa::https_optout
assert_eq    "ca_fingerprint parsed"          "abc123"                  "$(boxa::ca_fingerprint)"
assert_eq    "mkcert_version parsed"          "1.4.4"                   "$(boxa::mkcert_version)"
assert_eq    "ca_installed_at parsed"         "2026-05-13T10:00:00Z"    "$(boxa::ca_installed_at)"
assert_eq    "ca_installed_platforms parsed"  "linux,windows"           "$(boxa::ca_installed_platforms)"

# Bogus boolean values fall back to the default (false), not the literal.
seed_https_conf "active=yes" "optout=garbage"
assert_false "active=yes rejected, default false" boxa::https_active
assert_false "optout=garbage rejected, default false" boxa::https_optout

# Whitespace and comments tolerated; unknown keys ignored.
seed_https_conf \
    "# leading comment" \
    "" \
    "  active = true   # trailing comment" \
    " ca_fingerprint = deadbeef " \
    "bogus_key=ignored"
assert_true "whitespace tolerant active"  boxa::https_active
assert_eq   "whitespace tolerant fingerprint" "deadbeef"  "$(boxa::ca_fingerprint)"

# --- Writer round-trips ------------------------------------------------------

clear_https_conf
boxa::write_https_field active true
assert_true "write_https_field active=true round-trips" boxa::https_active

boxa::write_https_field active false
assert_false "write_https_field active=false round-trips" boxa::https_active

boxa::write_https_field ca_fingerprint "abc-new"
assert_eq "write_https_field fingerprint round-trips" "abc-new" "$(boxa::ca_fingerprint)"

# Writing the same key twice must not duplicate the line.
boxa::write_https_field ca_fingerprint "abc-second"
matches=$(grep -c '^ca_fingerprint=' "$_TMP_HTTPS_CONF")
assert_eq "ca_fingerprint line appears once after two writes" "1" "$matches"
assert_eq "second fingerprint write wins" "abc-second" "$(boxa::ca_fingerprint)"

# Unknown key is refused (rc != 0) and the file is not mutated. Hash via the
# lib's own portable helper so the assertion stays meaningful on macOS hosts
# without GNU coreutils — `sha256sum` directly would silently return empty
# on both sides and trivially pass.
before_hash="$(_mkcert::_sha256_file "$_TMP_HTTPS_CONF")"
assert_false "unknown key refused" boxa::write_https_field totally_unknown_key value
after_hash="$(_mkcert::_sha256_file "$_TMP_HTTPS_CONF")"
assert_eq "unknown key did not mutate file" "$before_hash" "$after_hash"

# Comments preserved by the writer.
clear_https_conf
printf '%s\n' '# my own comment' 'active=false' >> "$_TMP_HTTPS_CONF"
boxa::reset_https_cache
boxa::write_https_field active true
if grep -q '^# my own comment$' "$_TMP_HTTPS_CONF"; then
    printf 'PASS  %s\n' "writer preserves user comment"
else
    printf 'FAIL  %s\n      comment line lost\n' "writer preserves user comment"
    fail_count=$((fail_count + 1))
fi

# --- add_ca_installed_platform -----------------------------------------------

clear_https_conf
boxa::add_ca_installed_platform linux
assert_eq "first platform writes linux" "linux" "$(boxa::ca_installed_platforms)"

boxa::add_ca_installed_platform linux
assert_eq "duplicate platform is a noop"  "linux" "$(boxa::ca_installed_platforms)"

boxa::add_ca_installed_platform windows
assert_eq "second platform appended"      "linux,windows" "$(boxa::ca_installed_platforms)"

boxa::add_ca_installed_platform linux
assert_eq "duplicate after appended noop"  "linux,windows" "$(boxa::ca_installed_platforms)"

# Empty argument is a noop, not an error.
assert_true "empty platform arg is noop"  boxa::add_ca_installed_platform ""
assert_eq   "empty platform left list unchanged" "linux,windows" "$(boxa::ca_installed_platforms)"

# --- Writer surfaces failure to caller ---------------------------------------

# Point at a path whose parent is a regular file: `mkdir -p` cannot create
# a directory under a non-directory, so the write must fail and surface a
# non-zero rc to the caller. Anchors the contract that
# `boxa::write_https_field ... || _warn` actually warns on a real failure
# rather than silently succeeding because reset_https_cache returns 0.
_BLOCKER_FILE="$(mktemp)"
BOXA_HTTPS_CONF="$_BLOCKER_FILE/blocked.conf"
boxa::reset_https_cache
assert_false "writer returns rc!=0 when target unwritable" \
    boxa::write_https_field active true 2>/dev/null

# Restore the normal isolated config for the remaining assertions.
BOXA_HTTPS_CONF="$_TMP_HTTPS_CONF"
rm -f "$_BLOCKER_FILE"
boxa::reset_https_cache

# --- Portable sha256 helper (Codex fix #1) -----------------------------------

# `_mkcert::_sha256_file` must work without GNU coreutils on macOS. Sanity
# check on whatever host runs the tests: feed a known-content file and
# verify the result matches the expected sha256.
_FIXTURE="$(mktemp)"
printf 'boxa-https-fixture' > "$_FIXTURE"
expected_hash="$(
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$_FIXTURE" | awk '{print $1}'
    else
        shasum -a 256 "$_FIXTURE" | awk '{print $1}'
    fi
)"
actual_hash="$(_mkcert::_sha256_file "$_FIXTURE")"
assert_eq "sha256_file matches host hasher" "$expected_hash" "$actual_hash"
assert_false "sha256_file rc!=0 on missing path" _mkcert::_sha256_file /no/such/path
rm -f "$_FIXTURE"

# --- Summary -----------------------------------------------------------------

if [ "$fail_count" -eq 0 ]; then
    printf '\nAll assertions passed.\n'
    exit 0
fi
printf '\n%d assertion(s) failed.\n' "$fail_count"
exit 1
