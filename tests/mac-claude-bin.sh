#!/bin/bash
# Assertions for the sync script that advances the shared macOS Claude binary
# volume (boxa-mac-claude-bin) to the image-baked version — the payload
# `refresh_mac_claude_bin_volume` in docker-run.sh runs inside a helper
# Container.
#
# Usage: bash tests/mac-claude-bin.sh
#
# docker-run.sh is a CLI dispatcher and not source-safe, so the heredoc body is
# extracted with awk. Its two directory paths are container-absolute; the test
# rewrites those two assignments to point at fixture directories, which keeps
# the production script free of test-only seams while covering the version
# comparison, the additive copy, and the failure modes.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! printf '2.1.9\n2.1.10\n' | sort -V >/dev/null 2>&1; then
    printf 'SKIP  mac-claude-bin suite — sort(1) lacks -V\n'
    exit 0
fi

_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

raw="$_TMPROOT/sync-raw.sh"
awk '
    /^read -r -d .. _BOXA_MAC_CLAUDE_BIN_SYNC <</ { capture=1; next }
    /^SYNC$/ { if (capture) exit }
    capture { print }
' "$BOXA_DIR/docker-run.sh" > "$raw"

if [ ! -s "$raw" ]; then
    printf 'FAIL  could not extract _BOXA_MAC_CLAUDE_BIN_SYNC from docker-run.sh\n'
    exit 1
fi

fail_count=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'ok    %s\n' "$label"
    else
        printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' \
            "$label" "$expected" "$actual"
        fail_count=$((fail_count + 1))
    fi
}

# Run the extracted script against a fresh fixture pair.
# run_sync <case-name> <image-versions...> -- <volume-versions...>
run_sync() {
    local name="$1"
    shift
    IMG_DIR="$_TMPROOT/$name/image"
    VOL_DIR="$_TMPROOT/$name/volume"
    mkdir -p "$IMG_DIR" "$VOL_DIR"

    local seeding_volume=0 v
    for v in "$@"; do
        if [ "$v" = "--" ]; then
            seeding_volume=1
            continue
        fi
        if [ "$seeding_volume" -eq 1 ]; then
            printf 'volume-%s\n' "$v" > "$VOL_DIR/$v"
        else
            printf 'image-%s\n' "$v" > "$IMG_DIR/$v"
        fi
    done

    local script="$_TMPROOT/$name/sync.sh"
    sed -e "s#^img=.*#img=$IMG_DIR#" \
        -e "s#^vol=.*#vol=$VOL_DIR#" "$raw" > "$script"
    # Callers capture stdout with $(...), which runs run_sync in a subshell —
    # an exit status kept in a variable would never reach them. Record it in
    # the fixture dir instead, where sync_status reads it back.
    bash "$script" 2>&1
    printf '%s\n' "$?" > "$_TMPROOT/$name/status"
    return 0
}

sync_status() {
    cat "$_TMPROOT/$1/status" 2>/dev/null || printf 'missing\n'
}

# The rewrite must have taken — otherwise every case below would silently test
# the container paths (absent here) instead of the fixtures.
run_sync path-rewrite 2.1.5 -- >/dev/null
assert_eq "fixture paths replaced the container-absolute ones" "0" \
    "$(grep -c '^\(img\|vol\)=/home/node' "$_TMPROOT/path-rewrite/sync.sh")"

out="$(run_sync empty-volume 2.1.223 --)"
assert_eq "empty volume: reports the copy" "UPDATED 2.1.223" "$out"
assert_eq "empty volume: exits 0" "0" "$(sync_status empty-volume)"
assert_eq "empty volume: binary landed" "image-2.1.223" \
    "$(cat "$_TMPROOT/empty-volume/volume/2.1.223" 2>/dev/null)"

out="$(run_sync older-volume 2.1.223 -- 2.1.191)"
assert_eq "older volume: reports the copy" "UPDATED 2.1.223" "$out"
assert_eq "older volume: new version landed" "image-2.1.223" \
    "$(cat "$_TMPROOT/older-volume/volume/2.1.223" 2>/dev/null)"
# A Container may be executing from the version already in the volume, so the
# copy is additive — never a replacement of the directory's contents.
assert_eq "older volume: previous version kept" "volume-2.1.191" \
    "$(cat "$_TMPROOT/older-volume/volume/2.1.191" 2>/dev/null)"

out="$(run_sync same-version 2.1.223 -- 2.1.223)"
assert_eq "same version: reports no work" "CURRENT 2.1.223" "$out"
assert_eq "same version: volume copy untouched" "volume-2.1.223" \
    "$(cat "$_TMPROOT/same-version/volume/2.1.223" 2>/dev/null)"

# `claude update` inside a Container leaves the volume ahead of the image; the
# sync must not drag it back down.
out="$(run_sync newer-volume 2.1.223 -- 2.1.300)"
assert_eq "newer volume: reports no work" "CURRENT 2.1.300" "$out"
assert_eq "newer volume: image version not copied in" "absent" \
    "$([ -e "$_TMPROOT/newer-volume/volume/2.1.223" ] && echo present || echo absent)"

# Numeric ordering, not lexicographic: 2.1.99 must not beat 2.1.223.
out="$(run_sync numeric-order 2.1.223 -- 2.1.99)"
assert_eq "numeric order: 2.1.223 beats 2.1.99" "UPDATED 2.1.223" "$out"

# No Claude in the image is a broken build, not a reason to abort the start.
out="$(run_sync no-image-version --)"
assert_eq "empty image dir: reports the skip" "SKIP image has no Claude version" "$out"
assert_eq "empty image dir: exits 0" "0" "$(sync_status no-image-version)"

# The staging file the copy renames from must never be mistaken for a version.
out="$(run_sync staging-leftover 2.1.223 --)"
mkdir -p "$_TMPROOT/staging-leftover/volume"
printf 'partial\n' > "$_TMPROOT/staging-leftover/volume/.sync.abc123"
out="$(bash "$_TMPROOT/staging-leftover/sync.sh" 2>&1)"
assert_eq "leftover staging file ignored by the version scan" "CURRENT 2.1.223" "$out"

if [ "$fail_count" -eq 0 ]; then
    printf '\nmac-claude-bin: all assertions passed\n'
    exit 0
fi
printf '\nmac-claude-bin: %d assertion(s) failed\n' "$fail_count"
exit 1
