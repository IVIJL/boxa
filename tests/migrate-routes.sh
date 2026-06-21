#!/bin/bash
# Integration assertions for scripts/migrate-routes-to-https.sh — the active
# migration that flips a running boxa's HTTP route YAMLs over to HTTPS as
# part of `boxa dns-install --enable-https` (Phase 6).
#
# Usage: bash tests/migrate-routes.sh
#
# Drives the real script against a per-test TRAEFIK_CONFIG_DIR + BOXA_CERTS_DIR
# sandbox. The --check predicate is exhaustively covered; the --auto
# rewrite path runs end-to-end only when mkcert is available (signing a
# leaf is non-mockable). When mkcert is missing, the rewrite path is
# exercised in its documented "cert generation failed" mode instead, so
# the partial-failure rollback contract still gets touched.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

export TRAEFIK_CONFIG_DIR="$_TMPROOT/dynamic"
export BOXA_CERTS_DIR="$_TMPROOT/certs"
export BOXA_CERT_TLS_DIR="$_TMPROOT/dynamic"
export BOXA_DNS_CONF="$_TMPROOT/dns.conf"
export BOXA_HTTPS_CONF="$_TMPROOT/https.conf"

cat > "$BOXA_DNS_CONF" <<EOF
active_domain=test
external_provider=sslip.io
EOF
: > "$BOXA_HTTPS_CONF"

# shellcheck source-path=SCRIPTDIR source=../lib/naming.sh disable=SC1091
source "$BOXA_DIR/lib/naming.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/mkcert.sh disable=SC1091
source "$BOXA_DIR/lib/mkcert.sh"

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

reset_dynamic() {
    rm -rf "$TRAEFIK_CONFIG_DIR" "$BOXA_CERTS_DIR"
    mkdir -p "$TRAEFIK_CONFIG_DIR" "$BOXA_CERTS_DIR"
}

# Drop a route YAML at the per-container-port filename apply_port_routes
# emits. `entry` is the entrypoint(s) line — `web`, `websecure`, or a list.
write_route() {
    local project="$1" port="$2" entry="$3"
    local container="boxa-${project}"
    local tls_block="" tls_marker=""
    if [ "$entry" = "websecure" ]; then
        tls_block=$'\n      tls: {}'
        tls_marker="      tls: {}"
    fi
    cat > "$TRAEFIK_CONFIG_DIR/${container}-${port}.yml" <<YAML
http:
  routers:
    ${container}-${port}:
      rule: "Host(\`${port}.${project}.test\`)"
      entryPoints:
        - ${entry}${tls_block}
      service: ${container}-${port}
  services:
    ${container}-${port}:
      loadBalancer:
        servers:
          - url: "http://${container}:${port}"
YAML
    : "${tls_marker:=}"
}

# run_check/run_auto are invoked indirectly via `assert_false ... run_check`
# (function name passed as an arg). Silence SC2317's "unreachable" hint —
# the function body IS reached, just not through a direct call site.
# shellcheck disable=SC2317
run_check() {
    bash "$BOXA_DIR/scripts/migrate-routes-to-https.sh" --check
}

run_auto() {
    bash "$BOXA_DIR/scripts/migrate-routes-to-https.sh" --auto 2>&1
}

# --- --check predicate -------------------------------------------------------

reset_dynamic
assert_false "check: empty TRAEFIK_CONFIG_DIR → exit 1" run_check

reset_dynamic
write_route foo 3000 websecure
assert_false "check: HTTPS-only routes → exit 1" run_check

reset_dynamic
write_route foo 3000 web
assert_true "check: at least one HTTP-only route → exit 0" run_check

reset_dynamic
write_route foo 3000 web
write_route bar 5173 websecure
assert_true "check: mixed routes → exit 0" run_check

# <project>-tls.yml fragments must NOT count: the filename does not match
# the boxa-<container>-<port>.yml shape, but a stray `web` token in any
# YAML in the dir would otherwise trip a naïve grep.
reset_dynamic
cat > "$TRAEFIK_CONFIG_DIR/foo-tls.yml" <<EOF
tls:
  certificates:
    - certFile: /etc/traefik/certs/foo.pem
      keyFile: /etc/traefik/certs/foo.key
EOF
assert_false "check: lone <project>-tls.yml is not a migration trigger" run_check

# --- --auto when no HTTP routes exist ----------------------------------------

reset_dynamic
write_route foo 3000 websecure
rc=0
out="$(run_auto)" || rc=$?
assert_eq "auto: no HTTP routes → exit 0" "0" "$rc"
if grep -q "Nothing to migrate" <<< "$out"; then
    printf 'PASS  auto: prints "Nothing to migrate" message\n'
else
    printf 'FAIL  auto: missing "Nothing to migrate" message\n      output: %s\n' "$out"
    fail_count=$((fail_count + 1))
fi

# --- --auto with HTTP routes -------------------------------------------------

if _mkcert::resolve_bin >/dev/null 2>&1 \
    && [ -f "$(_mkcert::caroot 2>/dev/null)/rootCA.pem" ]; then
    reset_dynamic
    write_route foo 3000 web
    write_route foo 5173 web
    out="$(run_auto)"; rc=$?
    assert_eq "auto: rc=0 on full migration with mkcert" "0" "$rc"

    assert_true "auto: backup created for first route" \
        test -f "$TRAEFIK_CONFIG_DIR/boxa-foo-3000.yml.pre-https-backup"
    assert_true "auto: backup created for second route" \
        test -f "$TRAEFIK_CONFIG_DIR/boxa-foo-5173.yml.pre-https-backup"

    if grep -q 'websecure' "$TRAEFIK_CONFIG_DIR/boxa-foo-3000.yml" \
        && grep -q 'tls: {}' "$TRAEFIK_CONFIG_DIR/boxa-foo-3000.yml"; then
        printf 'PASS  auto: route 3000 rewritten with websecure + tls\n'
    else
        printf 'FAIL  auto: route 3000 not rewritten\n      content:\n%s\n' \
            "$(cat "$TRAEFIK_CONFIG_DIR/boxa-foo-3000.yml")"
        fail_count=$((fail_count + 1))
    fi

    assert_true "auto: leaf pem produced" \
        test -s "$BOXA_CERTS_DIR/foo.pem"

    # Idempotency: running it again should be a noop (no HTTP routes left).
    out="$(run_auto)"; rc=$?
    assert_eq "auto: second run on fully-HTTPS dir is exit 0" "0" "$rc"
    if grep -q "Nothing to migrate" <<< "$out"; then
        printf 'PASS  auto: idempotent — second run reports nothing to do\n'
    else
        printf 'FAIL  auto: second run did not report "Nothing to migrate"\n      output: %s\n' \
            "$out"
        fail_count=$((fail_count + 1))
    fi
else
    # mkcert missing — exercise the failure path documented in the script:
    # backup is still created, route file is NOT rewritten, exit is non-zero.
    reset_dynamic
    write_route foo 3000 web
    out="$(run_auto)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'PASS  auto-without-mkcert: non-zero exit when cert generation fails\n'
    else
        printf 'FAIL  auto-without-mkcert: expected non-zero exit, got 0\n      output: %s\n' "$out"
        fail_count=$((fail_count + 1))
    fi
    if grep -q 'entryPoints:' "$TRAEFIK_CONFIG_DIR/boxa-foo-3000.yml" \
        && grep -qE '^[[:space:]]+- web$' "$TRAEFIK_CONFIG_DIR/boxa-foo-3000.yml" \
        && ! grep -q 'websecure' "$TRAEFIK_CONFIG_DIR/boxa-foo-3000.yml"; then
        printf 'PASS  auto-without-mkcert: HTTP route left intact on cert failure\n'
    else
        printf 'FAIL  auto-without-mkcert: HTTP route mangled after cert failure\n      content:\n%s\n' \
            "$(cat "$TRAEFIK_CONFIG_DIR/boxa-foo-3000.yml")"
        fail_count=$((fail_count + 1))
    fi
    note_skip "auto: full HTTPS rewrite verification skipped (no mkcert on PATH)"
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
