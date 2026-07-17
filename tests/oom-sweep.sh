#!/bin/bash
# Plain-bash tests for lib/oom-sweep.sh. All external inputs are canned seams.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/oom-sweep"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

DOCKER_STUB="$TEST_TMP/docker"
NOTIFY_STUB="$TEST_TMP/notify"

cat > "$DOCKER_STUB" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "ps" ]; then
    printf 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc boxa-gone\n'
    exit 0
fi
id="${@: -1}"
case "$id" in
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
        printf '/boxa-media 5368709120\n'
        ;;
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
        printf '/unrelated-worker 2147483648\n'
        ;;
    cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc)
        exit 1
        ;;
    *) exit 1 ;;
esac
STUB
cat > "$NOTIFY_STUB" <<'STUB'
#!/bin/bash
printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$BOXA_OOM_TEST_NOTIFICATIONS"
STUB
chmod +x "$DOCKER_STUB" "$NOTIFY_STUB"

export BOXA_OOM_ARCHIVE_DIR="$TEST_TMP/archive"
export BOXA_OOM_STATE_FILE="$TEST_TMP/archive/state"
export BOXA_OOM_DOCKER_CMD="$DOCKER_STUB"
export BOXA_OOM_NOTIFY_CMD="$NOTIFY_STUB"
export BOXA_OOM_TEST_NOTIFICATIONS="$TEST_TMP/notifications"

# shellcheck source-path=SCRIPTDIR source=../lib/oom-sweep.sh disable=SC1091
source "$SCRIPT_DIR/../lib/oom-sweep.sh"

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
    local label="$1" needle="$2" file="$3"
    if grep -Fq "$needle" "$file"; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      missing: %q\n      file:    %s\n' \
            "$label" "$needle" "$file"
        fail_count=$((fail_count + 1))
    fi
}

line_count() {
    local file="$1"
    [ -f "$file" ] || { printf '0'; return; }
    wc -l < "$file" | tr -d ' '
}

archive_count() {
    find "$BOXA_OOM_ARCHIVE_DIR" -maxdepth 1 -type f -name 'boxa-*.log' \
        2>/dev/null | wc -l | tr -d ' '
}

reset_case() {
    rm -rf "$BOXA_OOM_ARCHIVE_DIR"
    rm -f "$BOXA_OOM_TEST_NOTIFICATIONS"
    mkdir -p "$BOXA_OOM_ARCHIVE_DIR"
}

run_fixture() {
    export BOXA_OOM_DMESG_FILE="$FIXTURE_DIR/$1"
    _boxa::oom_sweep
}

# One boxa event creates a complete record and one backend dispatch.
reset_case
run_fixture boxa.dmesg
record="$BOXA_OOM_ARCHIVE_DIR/boxa-media-12345.678950.log"
assert_eq "boxa event archived once" "1" "$(archive_count)"
assert_eq "boxa event notified once" "1" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
assert_contains "archive project" "Project: media" "$record"
assert_contains "archive event time" "Event time: kernel timestamp 12345.678950 seconds since boot" "$record"
assert_contains "archive limit" "Memory limit: 5 GiB" "$record"
assert_contains "archive kernel-selected victim" "Kernel-selected victim: ugrep (PID 1234)" "$record"
assert_contains "archive victim RSS" "Victim anonymous RSS: 3.8 GiB (3984588 kB)" "$record"
assert_contains "archive next step" "Next step: boxa mem media" "$record"
assert_contains "notification wording" "Killed by the kernel: ugrep, 3.8 GiB RSS. The project keeps running." "$BOXA_OOM_TEST_NOTIFICATIONS"

# State and archive dedup suppress repeats of the identical ring snapshot.
run_fixture boxa.dmesg
assert_eq "repeat does not duplicate archive" "1" "$(archive_count)"
assert_eq "repeat does not re-notify" "1" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

# Docker memcg events not named boxa-* and host OOMs are both ignored.
reset_case
run_fixture non-boxa.dmesg
assert_eq "non-boxa container ignored" "0" "$(archive_count)"
assert_eq "non-boxa container not notified" "0" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
reset_case
run_fixture host.dmesg
assert_eq "host OOM ignored" "0" "$(archive_count)"
assert_eq "host OOM not notified" "0" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

# Fractional timestamps preserve two kills in the same integer second.
reset_case
run_fixture two-kills.dmesg
assert_eq "same-second kills both archived" "2" "$(archive_count)"
assert_eq "same-second kills both notified" "2" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

# If inspect loses the container, ps correlation still records an unknown limit.
reset_case
run_fixture unknown-limit.dmesg
unknown_record="$BOXA_OOM_ARCHIVE_DIR/boxa-gone-30000.300000.log"
assert_eq "vanished inspect result still archived" "1" "$(archive_count)"
assert_contains "vanished container limit is unknown" "Memory limit: unknown" "$unknown_record"
assert_contains "unknown-limit notification stays grammatical" "Project gone hit a memory limit." "$BOXA_OOM_TEST_NOTIFICATIONS"

# A backwards latest timestamp resets the cutoff and admits the new boot.
reset_case
run_fixture pre-reset.dmesg
run_fixture post-reset.dmesg
assert_eq "post-reset event is archived" "2" "$(archive_count)"
assert_eq "post-reset event is notified" "2" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
run_fixture post-reset.dmesg
assert_eq "post-reset repeat stays deduplicated" "2" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

# Corrupt state fails open, while the existing archive remains authoritative.
printf 'not shell and not a timestamp\n' > "$BOXA_OOM_STATE_FILE"
run_fixture post-reset.dmesg
assert_eq "corrupt state does not re-notify archived event" "2" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

# Empty/no-OOM logs have no side effects beyond advancing scan state.
reset_case
run_fixture empty.dmesg
assert_eq "empty log creates no archive" "0" "$(archive_count)"
assert_eq "empty log sends no notification" "0" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi
printf '\nAll oom-sweep tests passed.\n'
