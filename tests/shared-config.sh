#!/bin/bash
# Plain-bash assertions for the shared-config manifest and layout transition.
# Usage: bash tests/shared-config.sh

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

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      missing: %q\n      actual:  %q\n' \
            "$label" "$needle" "$haystack"
        fail_count=$((fail_count + 1))
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      unexpected: %q\n      actual:     %q\n' \
            "$label" "$needle" "$haystack"
        fail_count=$((fail_count + 1))
    fi
}

extract_function() {
    local name="$1" output="$2"
    awk -v signature="${name}() {" '
        $0 == signature { capture=1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$BOXA_DIR/docker-run.sh" > "$output"
}

export HOME="$_TMPROOT/home"
mkdir -p "$HOME"
# shellcheck source-path=SCRIPTDIR source=../lib/allowlist.sh disable=SC1091
source "$BOXA_DIR/lib/allowlist.sh"

prepare_extracted="$_TMPROOT/prepare_shared_config.sh"
unexpected_extracted="$_TMPROOT/shared_config_unexpected_files.sh"
extract_function prepare_shared_config "$prepare_extracted"
extract_function shared_config_unexpected_files "$unexpected_extracted"
# shellcheck source=/dev/null
source "$prepare_extracted"
# shellcheck source=/dev/null
source "$unexpected_extracted"

seed_allowed_domains() {
    allowlist::ensure_seeded "$ALLOWLIST_HOST_FILE" \
        "$BOXA_DIR/config/default-allowlist.conf"
}

filter_user_containers() {
    grep -v '^boxa-infra$' || true
}

docker() {
    case "${1:-}" in
        ps) printf '%s\n' boxa-alpha boxa-beta boxa-current boxa-infra ;;
        inspect)
            if [ "${*: -1}" = boxa-current ]; then
                printf '%s\n' /etc/boxa-shared/config
            else
                printf '%s\n' \
                    /etc/boxa-shared/allowed-domains.conf \
                    /etc/boxa-shared/dns-upstream.conf
            fi
            ;;
    esac
}

# Fresh layout: every and only manifest member exists, with defaults seeded.
prepare_shared_config >/dev/null
assert_eq "fresh shared directory contains exactly the manifest" \
    "$(printf '%s\n' "${SHARED_CONFIG_FILES[@]}" | sort)" \
    "$(find "$SHARED_CONFIG_HOST_DIR" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)"
assert_eq "fresh allowlist is seeded" \
    "$(< "$BOXA_DIR/config/default-allowlist.conf")" \
    "$(< "$ALLOWLIST_HOST_FILE")"

# Upgrade layout: both legacy files move without content loss and warn once.
rm -rf "$SHARED_CONFIG_HOST_DIR"
mkdir -p "$ALLOWLIST_HOST_DIR"
printf '%s\n' legacy.example > "$ALLOWLIST_HOST_DIR/allowed-domains.conf"
printf '%s\n' 172.17.0.1 > "$ALLOWLIST_HOST_DIR/dns-upstream.conf"
migration_output="$(prepare_shared_config)"
assert_eq "legacy allowlist content survives the move" legacy.example \
    "$(allowlist::read "$ALLOWLIST_HOST_FILE" | head -1)"
assert_eq "legacy DNS upstream moved without content loss" 172.17.0.1 \
    "$(< "$DNS_UPSTREAM_HOST_FILE")"
assert_eq "legacy flat files are gone" "" \
    "$(find "$ALLOWLIST_HOST_DIR" -maxdepth 1 -type f -print)"
assert_eq "upgraded shared directory contains exactly the manifest" \
    "$(printf '%s\n' "${SHARED_CONFIG_FILES[@]}" | sort)" \
    "$(find "$SHARED_CONFIG_HOST_DIR" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)"
assert_contains "migration warning names first running Container" boxa-alpha \
    "$migration_output"
assert_contains "migration warning names second running Container" boxa-beta \
    "$migration_output"
assert_not_contains "migration warning excludes current-layout Container" \
    boxa-current "$migration_output"
assert_eq "migration warning is one-time" "" "$(prepare_shared_config)"

# Doctor helper reports only entries outside the manifest, including dotfiles.
touch "$SHARED_CONFIG_HOST_DIR/.editor-backup"
mkdir "$SHARED_CONFIG_HOST_DIR/unexpected-dir"
assert_eq "unexpected shared entries are reported" \
    $'.editor-backup\nunexpected-dir' "$(shared_config_unexpected_files)"
rm -rf "$SHARED_CONFIG_HOST_DIR/.editor-backup" \
    "$SHARED_CONFIG_HOST_DIR/unexpected-dir"
assert_eq "manifest-only shared directory is clean" "" \
    "$(shared_config_unexpected_files)"

# Static guard: literal filenames beneath either shared path must be listed in
# SHARED_CONFIG_FILES. The fixture proves both fail and pass behavior.
scan_unlisted_shared_filenames() {
    local root="$1" match filename manifest_file listed
    while IFS= read -r match; do
        filename="${match##*/}"
        listed=false
        for manifest_file in "${SHARED_CONFIG_FILES[@]}"; do
            if [ "$filename" = "$manifest_file" ]; then
                listed=true
                break
            fi
        done
        $listed || printf '%s\n' "$filename"
    done < <(grep -IRhoE \
        --exclude=shared-config.sh \
        --exclude-dir=.git \
        --exclude-dir=.scratch \
        '(/etc/boxa-shared/config/|[.]config/boxa/shared/|[$][{]?SHARED_CONFIG_(HOST|CONTAINER)_DIR[}]?/)[.]?[[:alnum:]_][[:alnum:]_.-]*' \
        "$root" 2>/dev/null | sort -u || true)
}

fixture="$_TMPROOT/static-fixture"
mkdir -p "$fixture"
printf '%s\n' \
    '/etc/boxa-shared/config/allowed-domains.conf' \
    '/home/test/.config/boxa/shared/unexpected.conf' \
    > "$fixture/references.txt"
assert_eq "static guard rejects an unlisted fixture filename" unexpected.conf \
    "$(scan_unlisted_shared_filenames "$fixture")"
SHARED_CONFIG_FILES+=(unexpected.conf)
assert_eq "manifest addition admits the fixture filename" "" \
    "$(scan_unlisted_shared_filenames "$fixture")"
unset 'SHARED_CONFIG_FILES[2]'
assert_eq "codebase shared filenames match the manifest" "" \
    "$(scan_unlisted_shared_filenames "$BOXA_DIR")"

# The run path has one RO directory mount and no shared-config file mounts.
# shellcheck disable=SC2016  # Matching literal shell source text below.
assert_eq "shared config has exactly one directory mount" 1 \
    "$(grep -cF 'DOCKER_ARGS+=(-v "$SHARED_CONFIG_HOST_DIR:$SHARED_CONFIG_CONTAINER_DIR:ro")' \
        "$BOXA_DIR/docker-run.sh")"
# shellcheck disable=SC2016  # Matching literal shell source text below.
assert_eq "allowlist file is not mounted individually" 0 \
    "$(grep -cF '$ALLOWLIST_HOST_FILE:$ALLOWLIST_CONTAINER_FILE:ro' \
        "$BOXA_DIR/docker-run.sh" || true)"
# shellcheck disable=SC2016  # Matching literal shell source text below.
assert_eq "DNS upstream file is not mounted individually" 0 \
    "$(grep -cF '$DNS_UPSTREAM_HOST_FILE:$DNS_UPSTREAM_CONTAINER_FILE:ro' \
        "$BOXA_DIR/docker-run.sh" || true)"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d shared-config test(s) failed.\n' "$fail_count" >&2
    exit 1
fi

printf '\nAll shared-config tests passed.\n'
