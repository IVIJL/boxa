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
id="${@: -1}"
if [ "${1:-}" = "inspect" ] && [ -n "${BOXA_OOM_TEST_INSPECT_CALLS:-}" ]; then
    printf '%s\n' "$id" >> "$BOXA_OOM_TEST_INSPECT_CALLS"
fi
if [ "${BOXA_OOM_TEST_DOCKER_MODE:-}" = "absent" ] \
    && [ "${1:-}" = "inspect" ]; then
    printf 'Error: No such object: %s\n' "$id" >&2
    exit 1
fi
if [ "${BOXA_OOM_TEST_DOCKER_MODE:-}" = "transient" ]; then
    printf 'Cannot connect to the Docker daemon\n' >&2
    exit 1
fi
if [ "${1:-}" = "ps" ]; then
    printf 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc boxa-gone\n'
    exit 0
fi
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
if [ -n "${BOXA_OOM_TEST_NOTIFY_FAIL_ONCE:-}" ] \
    && [ -f "$BOXA_OOM_TEST_NOTIFY_FAIL_ONCE" ]; then
    rm -f "$BOXA_OOM_TEST_NOTIFY_FAIL_ONCE"
    exit 1
fi
STUB
chmod +x "$DOCKER_STUB" "$NOTIFY_STUB"

export BOXA_OOM_ARCHIVE_DIR="$TEST_TMP/archive"
export BOXA_OOM_STATE_FILE="$TEST_TMP/archive/state"
export BOXA_OOM_DOCKER_CMD="$DOCKER_STUB"
export BOXA_OOM_NOTIFY_CMD="$NOTIFY_STUB"
export BOXA_OOM_NOTIFY_LOCK_STALE_SECONDS=60
export BOXA_OOM_TEST_NOTIFICATIONS="$TEST_TMP/notifications"
export BOXA_OOM_BOOT_ID_FILE="$TEST_TMP/boot_id"

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

pending_notification_count() {
    find "$BOXA_OOM_ARCHIVE_DIR" -maxdepth 1 -type f -name '*.notify-pending' \
        2>/dev/null | wc -l | tr -d ' '
}

set_boot_id() {
    printf '%s\n' "$1" > "$BOXA_OOM_BOOT_ID_FILE"
}

reset_case() {
    rm -rf "$BOXA_OOM_ARCHIVE_DIR"
    rm -f "$BOXA_OOM_TEST_NOTIFICATIONS"
    mkdir -p "$BOXA_OOM_ARCHIVE_DIR"
    set_boot_id boot-a
    unset BOXA_OOM_TEST_DOCKER_MODE BOXA_OOM_TEST_INSPECT_CALLS
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

# A transient backend failure leaves one retry marker. The next sweep retries
# the already-archived event, while a successful retry removes the marker so
# later sweeps stay deduplicated.
reset_case
export BOXA_OOM_TEST_NOTIFY_FAIL_ONCE="$TEST_TMP/notify-fail-once"
: > "$BOXA_OOM_TEST_NOTIFY_FAIL_ONCE"
run_fixture boxa.dmesg
assert_eq "failed notification still archives the event" "1" "$(archive_count)"
assert_eq "failed notification leaves one retry marker" \
    "1" "$(pending_notification_count)"
assert_eq "failed notification dispatches once" \
    "1" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
run_fixture boxa.dmesg
assert_eq "next sweep retries the failed notification" \
    "2" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
assert_eq "successful retry removes the marker" \
    "0" "$(pending_notification_count)"
run_fixture boxa.dmesg
assert_eq "later sweep does not re-notify after retry success" \
    "2" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
unset BOXA_OOM_TEST_NOTIFY_FAIL_ONCE

# A sweep interrupted while it owns a notification leaves the atomic claim
# behind. Stale claims are reclaimed and delivered once; fresh claims may
# still belong to a concurrent sweep and must be left untouched.
reset_case
stale_pending="$BOXA_OOM_ARCHIVE_DIR/stale.log.notify-pending"
printf '%s\n%s\n' 'Stale notification' 'Stale notification body' \
    > "${stale_pending}.lock"
touch -d '2 minutes ago' "${stale_pending}.lock"
run_fixture empty.dmesg
assert_eq "stale notification lock is reclaimed and delivered" \
    "1" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
assert_eq "successful stale-lock delivery removes the claim" \
    "missing" "$([ -e "${stale_pending}.lock" ] && printf present || printf missing)"
run_fixture empty.dmesg
assert_eq "reclaimed notification is not delivered again" \
    "1" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

reset_case
fresh_pending="$BOXA_OOM_ARCHIVE_DIR/fresh.log.notify-pending"
printf '%s\n%s\n' 'Fresh notification' 'Fresh notification body' \
    > "${fresh_pending}.lock"
run_fixture empty.dmesg
assert_eq "fresh notification lock is not delivered concurrently" \
    "0" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
assert_eq "fresh notification lock remains claimed" \
    "present" "$([ -e "${fresh_pending}.lock" ] && printf present || printf missing)"

# The systemd cgroup driver reports Docker IDs in docker-<id>.scope paths.
systemd_parsed=$(_boxa::oom_parse_dmesg < "$FIXTURE_DIR/systemd.dmesg")
assert_contains "systemd cgroup path parses the container ID" \
    $'EVENT\t22345.678950\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\t2345\tsystemd-worker\t3984588' \
    <(printf '%s\n' "$systemd_parsed")
reset_case
run_fixture systemd.dmesg
systemd_record="$BOXA_OOM_ARCHIVE_DIR/boxa-media-22345.678950.log"
assert_eq "systemd cgroup event archived once" "1" "$(archive_count)"
assert_contains "systemd archive keeps kernel-selected victim" \
    "Kernel-selected victim: systemd-worker (PID 2345)" "$systemd_record"
run_fixture systemd.dmesg
assert_eq "systemd cgroup repeat does not duplicate archive" "1" "$(archive_count)"
assert_eq "systemd cgroup repeat does not re-notify" "1" \
    "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

# Default dmesg pads short uptimes after `[`. A boot-time OOM must still be
# parsed, archived, and deduplicated on a repeated snapshot.
reset_case
run_fixture padded-boot.dmesg
padded_record="$BOXA_OOM_ARCHIVE_DIR/boxa-media-0.000050.log"
assert_eq "padded boot-time event archived once" "1" "$(archive_count)"
assert_eq "padded boot-time event notified once" "1" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
assert_contains "padded boot-time archive keeps timestamp" \
    "Event time: kernel timestamp 0.000050 seconds since boot" "$padded_record"
assert_contains "padded boot-time archive keeps victim" \
    "Kernel-selected victim: boot-worker (PID 42)" "$padded_record"
run_fixture padded-boot.dmesg
assert_eq "padded boot-time repeat does not duplicate archive" "1" "$(archive_count)"
assert_eq "padded boot-time repeat does not re-notify" "1" \
    "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

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

# A Container explicitly reported absent by Docker cannot be correlated after
# out-of-band removal. Drop that evidence silently and advance past it.
reset_case
export BOXA_OOM_TEST_DOCKER_MODE=absent
export BOXA_OOM_TEST_INSPECT_CALLS="$TEST_TMP/absent-inspect-calls"
run_fixture boxa.dmesg
assert_eq "absent container event is not archived" "0" "$(archive_count)"
assert_eq "absent container event is not notified" \
    "0" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
IFS= read -r state_line < "$BOXA_OOM_STATE_FILE"
assert_eq "absent container advances the cutoff" "12346.000000" "$state_line"
run_fixture boxa.dmesg
assert_eq "advanced absent event is not retried" \
    "1" "$(line_count "$BOXA_OOM_TEST_INSPECT_CALLS")"

# Daemon/transient inspect failures retain the cutoff and retry later.
reset_case
export BOXA_OOM_TEST_DOCKER_MODE=transient
export BOXA_OOM_TEST_INSPECT_CALLS="$TEST_TMP/transient-inspect-calls"
run_fixture boxa.dmesg
assert_eq "transient inspect failure is not archived" "0" "$(archive_count)"
assert_eq "transient inspect failure is not notified" \
    "0" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
assert_eq "transient inspect failure holds the cutoff" "missing" \
    "$([ -f "$BOXA_OOM_STATE_FILE" ] && printf present || printf missing)"
run_fixture boxa.dmesg
assert_eq "transient inspect failure is retried" \
    "2" "$(line_count "$BOXA_OOM_TEST_INSPECT_CALLS")"

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

# A sweep that races the kernel mid-report must not advance the cutoff past
# the unmatched oom-kill line; the completed pair is archived next sweep.
reset_case
run_fixture truncated-kill.dmesg
assert_eq "truncated event is not archived yet" "0" "$(archive_count)"
assert_eq "truncated event is not notified yet" "0" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
IFS= read -r state_line < "$BOXA_OOM_STATE_FILE"
assert_eq "cutoff capped just below the pending event" "60000.099999999" "$state_line"
run_fixture completed-kill.dmesg
assert_eq "completed pair archived by the next sweep" "1" "$(archive_count)"
assert_eq "completed pair notified by the next sweep" "1" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
run_fixture completed-kill.dmesg
assert_eq "completed pair is not archived twice" "1" "$(archive_count)"
assert_eq "completed pair is not re-notified" "1" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

# A boot id change resets the cutoff even when the new boot's timestamps are
# already past the old cutoff, so no backwards jump exists to detect.
reset_case
run_fixture pre-reset.dmesg
run_fixture late-boot.dmesg
assert_eq "same boot id keeps the cutoff" "1" "$(archive_count)"
set_boot_id boot-b
run_fixture late-boot.dmesg
assert_eq "boot id change admits the pre-cutoff event" "2" "$(archive_count)"
assert_eq "boot id change notifies the admitted event" "2" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
run_fixture late-boot.dmesg
assert_eq "new boot's cutoff dedups the repeat" "2" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

# A pre-boot-id state file (timestamp only) resets instead of skipping events.
reset_case
printf '12345.700000\n' > "$BOXA_OOM_STATE_FILE"
run_fixture boxa.dmesg
assert_eq "old-format state resets and archives the event" "1" "$(archive_count)"
assert_eq "old-format state resets and notifies the event" "1" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"
mapfile -t state_lines < "$BOXA_OOM_STATE_FILE"
assert_eq "state rewritten with the current boot id" "boot-a" "${state_lines[1]:-}"

# Empty/no-OOM logs have no side effects beyond advancing scan state.
reset_case
run_fixture empty.dmesg
assert_eq "empty log creates no archive" "0" "$(archive_count)"
assert_eq "empty log sends no notification" "0" "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

# An unreadable kernel log must leave the old cutoff and all outputs untouched.
reset_case
printf '%s\n' '12000.000000' 'boot-a' > "$BOXA_OOM_STATE_FILE"
cat > "$TEST_TMP/dmesg" <<'STUB'
#!/bin/bash
printf '%s\n' '[12345.678950] oom-kill: oom_memcg=/docker/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
printf '%s\n' 'dmesg: read kernel buffer failed: Operation not permitted' >&2
exit 1
STUB
chmod +x "$TEST_TMP/dmesg"
unset BOXA_OOM_DMESG_FILE
dmesg_failure_output=$(PATH="$TEST_TMP:$PATH" _boxa::oom_sweep)
assert_eq "failed dmesg sweep stays silent" "" "$dmesg_failure_output"
assert_eq "failed dmesg sweep preserves state" \
    $'12000.000000\nboot-a' "$(< "$BOXA_OOM_STATE_FILE")"
assert_eq "failed dmesg sweep creates no archive" "0" "$(archive_count)"
assert_eq "failed dmesg sweep sends no notification" "0" \
    "$(line_count "$BOXA_OOM_TEST_NOTIFICATIONS")"

# docker-run.sh is not source-safe, so extract the destructive-removal helper
# and assert its decision-layer ordering with canned sweep and Docker seams.
remove_helper="$TEST_TMP/remove-container-after-oom-sweep.sh"
awk '
    /^_boxa::remove_container_after_oom_sweep\(\)/ { found=1 }
    found { print }
    found && /^}/ { exit }
' "$SCRIPT_DIR/../docker-run.sh" > "$remove_helper"
if [ -s "$remove_helper" ]; then
    # shellcheck source=/dev/null
    source "$remove_helper"
    removal_order="$TEST_TMP/removal-order"
    removal_boxa_dir="$TEST_TMP/removal-boxa"
    mkdir -p "$removal_boxa_dir/scripts"
    printf '%s\n' \
        '#!/bin/sh' \
        "printf \"sweep\\n\" >> \"\$BOXA_OOM_TEST_REMOVAL_ORDER\"" \
        > "$removal_boxa_dir/scripts/sweep-oom-events.sh"
    chmod +x "$removal_boxa_dir/scripts/sweep-oom-events.sh"
    docker() {
        printf 'rm %s\n' "$2" >> "$BOXA_OOM_TEST_REMOVAL_ORDER"
    }
    export BOXA_OOM_TEST_REMOVAL_ORDER="$removal_order"
    BOXA_DIR="$removal_boxa_dir" _boxa::remove_container_after_oom_sweep boxa-media
    assert_eq "OOM sweep completes before destructive container removal" \
        $'sweep\nrm boxa-media' "$(< "$removal_order")"
else
    printf 'FAIL  could not extract _boxa::remove_container_after_oom_sweep from docker-run.sh\n'
    fail_count=$((fail_count + 1))
fi

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi
printf '\nAll oom-sweep tests passed.\n'
