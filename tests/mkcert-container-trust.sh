#!/bin/bash
# Plain-bash assertions for host-to-Container mkcert root CA trust wiring.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

# shellcheck source-path=SCRIPTDIR source=../lib/mkcert.sh disable=SC1091
source "$BOXA_DIR/lib/mkcert.sh"

readonly BOXA_MKCERT_CA_MOUNT_PATH="/run/boxa/mkcert-rootCA.pem"
readonly BOXA_MKCERT_CA_TRUST_PATH="/usr/local/share/ca-certificates/boxa-mkcert-rootCA.crt"

helpers="$_TMPROOT/helpers.sh"
awk '
    /^_boxa::mkcert_root_ca\(\) \{/ { emit=1 }
    emit { print }
    /^_boxa::append_mkcert_ca_args\(\) \{/ { in_append=1 }
    emit && in_append && /^}/ { exit }
' "$BOXA_DIR/docker-run.sh" > "$helpers"

if [ ! -s "$helpers" ]; then
    printf 'FAIL  could not extract mkcert Container helpers\n'
    exit 1
fi
# shellcheck source=/dev/null
source "$helpers"

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

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      missing: %q\n' "$label" "$needle"
        fail_count=$((fail_count + 1))
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      unexpected: %q\n' "$label" "$needle"
        fail_count=$((fail_count + 1))
    fi
}

# Called indirectly by the extracted docker-run helper.
# shellcheck disable=SC2317
_mkcert::caroot() { return 1; }
DOCKER_ARGS=()
_boxa::append_mkcert_ca_args
assert_eq "missing mkcert is a no-op" "0" "${#DOCKER_ARGS[@]}"

fixture_caroot="$_TMPROOT/caroot"
mkdir -p "$fixture_caroot"
_mkcert::caroot() { printf '%s' "$fixture_caroot"; }
DOCKER_ARGS=()
_boxa::append_mkcert_ca_args
assert_eq "missing rootCA.pem is a no-op" "0" "${#DOCKER_ARGS[@]}"

printf '%s\n' 'public fixture' > "$fixture_caroot/rootCA.pem"
printf '%s\n' 'private fixture' > "$fixture_caroot/rootCA-key.pem"
DOCKER_ARGS=()
_boxa::append_mkcert_ca_args
args_text="$(printf '%s\n' "${DOCKER_ARGS[@]}")"

assert_contains "public root CA is mounted read-only" \
    "$fixture_caroot/rootCA.pem:$BOXA_MKCERT_CA_MOUNT_PATH:ro" "$args_text"
assert_not_contains "private CA key is never mounted" "rootCA-key.pem" "$args_text"
assert_contains "Node inherits the installed CA path" \
    "NODE_EXTRA_CA_CERTS=$BOXA_MKCERT_CA_TRUST_PATH" "$args_text"
assert_contains "Python requests inherits the installed CA path" \
    "REQUESTS_CA_BUNDLE=$BOXA_MKCERT_CA_TRUST_PATH" "$args_text"
assert_contains "Python SSL inherits the installed CA path" \
    "SSL_CERT_FILE=$BOXA_MKCERT_CA_TRUST_PATH" "$args_text"

entrypoint_text="$(cat "$BOXA_DIR/scripts/boxa-entrypoint.sh")"
assert_contains "entrypoint copies the mounted public CA" \
    "install -m 0644 /run/boxa/mkcert-rootCA.pem" "$entrypoint_text"
assert_contains "entrypoint refreshes the system trust store" \
    "update-ca-certificates" "$entrypoint_text"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll mkcert Container trust tests passed.\n'
