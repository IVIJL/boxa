#!/bin/bash
# Fast, daemon-free tests for scripts/shutdown-inner-containers.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPROOT="$(mktemp -d)"

cleanup() {
    chmod u+rwx "$TMPROOT/scenarios/unreadable-work" 2>/dev/null || true
    chmod u+rw "$TMPROOT/scenarios/work/unreadable.yml" 2>/dev/null || true
    rm -rf "$TMPROOT"
}
trap cleanup EXIT

mkdir -p "$TMPROOT/bin" "$TMPROOT/app" "$TMPROOT/worker" "$TMPROOT/barrier"
touch "$TMPROOT/app/compose.yml" "$TMPROOT/app/compose.override.yml" \
    "$TMPROOT/worker/compose.yml"
DOCKER_LOG="$TMPROOT/docker.log"
PS_CALLS="$TMPROOT/ps-calls"
printf '0\n' > "$PS_CALLS"

cat > "$TMPROOT/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\t%s\n' "$PWD" "$*" >> "$BOXA_SHUTDOWN_TEST_LOG"

case "${1:-}" in
    ps)
        calls="$(cat "$BOXA_SHUTDOWN_TEST_PS_CALLS")"
        calls=$((calls + 1))
        printf '%s\n' "$calls" > "$BOXA_SHUTDOWN_TEST_PS_CALLS"
        case "$calls" in
            1) printf '%s\n' app-1 app-2 worker-1 loose-1 ;;
            2) printf '%s\n' sweep-1 ;;
        esac
        ;;
    inspect)
        case "${*: -1}" in
            app-1) printf '/app-1\tapp\t%s/app\t%s/app/compose.yml,%s/app/compose.override.yml\n' \
                "$BOXA_SHUTDOWN_TEST_ROOT" "$BOXA_SHUTDOWN_TEST_ROOT" "$BOXA_SHUTDOWN_TEST_ROOT" ;;
            app-2) printf '/app-2\tapp\t%s/app\t%s/app/compose.yml,%s/app/compose.override.yml\n' \
                "$BOXA_SHUTDOWN_TEST_ROOT" "$BOXA_SHUTDOWN_TEST_ROOT" "$BOXA_SHUTDOWN_TEST_ROOT" ;;
            worker-1) printf '/worker-1\tworker\t%s/worker\t%s/worker/compose.yml\n' \
                "$BOXA_SHUTDOWN_TEST_ROOT" "$BOXA_SHUTDOWN_TEST_ROOT" ;;
            loose-1) printf '/loose\t<no value>\t<no value>\t<no value>\n' ;;
        esac
        ;;
    compose)
        project=unknown
        previous=""
        for argument in "$@"; do
            if [ "$previous" = --project-name ]; then project="$argument"; fi
            previous="$argument"
        done
        : > "$BOXA_SHUTDOWN_TEST_BARRIER/compose-$project"
        while [ "$(find "$BOXA_SHUTDOWN_TEST_BARRIER" -type f | wc -l)" -lt 3 ]; do
            sleep 0.01
        done
        printf 'routine compose noise\n'
        ;;
    stop)
        if [ "${2:-}" = loose-1 ]; then
            : > "$BOXA_SHUTDOWN_TEST_BARRIER/unmanaged"
            while [ "$(find "$BOXA_SHUTDOWN_TEST_BARRIER" -type f | wc -l)" -lt 3 ]; do
                sleep 0.01
            done
        fi
        ;;
    rm) ;;
esac
STUB
chmod +x "$TMPROOT/bin/docker"

export BOXA_SHUTDOWN_TEST_ROOT="$TMPROOT"
export BOXA_SHUTDOWN_TEST_LOG="$DOCKER_LOG"
export BOXA_SHUTDOWN_TEST_PS_CALLS="$PS_CALLS"
export BOXA_SHUTDOWN_TEST_BARRIER="$TMPROOT/barrier"

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

line_count() {
    local pattern="$1"
    grep -c -- "$pattern" "$DOCKER_LOG" || true
}

output="$(PATH="$TMPROOT/bin:$PATH" bash "$SCRIPT_DIR/../scripts/shutdown-inner-containers.sh" 2>&1)"
rc=$?

assert_eq "helper succeeds" "0" "$rc"
assert_eq "discovery and verification include stopped containers" "3" \
    "$(line_count $'ps -aq$')"
assert_eq "same Compose identity is grouped once" "1" \
    "$(line_count $'compose --project-name app --project-directory')"
assert_eq "second Compose project launches independently" "1" \
    "$(line_count $'compose --project-name worker --project-directory')"
assert_eq "complete config-file set is replayed" "1" \
    "$(line_count '--file .*app/compose.yml --file .*app/compose.override.yml down --remove-orphans$')"
assert_eq "Compose receives no timeout override" "0" "$(line_count '--timeout\|-t ')"
assert_eq "Compose jobs and unmanaged cleanup launch concurrently" "3" \
    "$(find "$TMPROOT/barrier" -type f | wc -l)"
assert_eq "unmanaged container is gracefully stopped" "1" "$(line_count $'stop loose-1$')"
assert_eq "unmanaged container is removed" "1" "$(line_count $'rm loose-1$')"
assert_eq "final sweep stops a leftover" "1" "$(line_count $'stop sweep-1$')"
assert_eq "final sweep removes a leftover" "1" "$(line_count $'rm sweep-1$')"
assert_eq "logical projects are reported" "2" \
    "$(grep -c '^Stopping Compose project:' <<< "$output" || true)"
assert_eq "unmanaged containers are reported by name" "1" \
    "$(grep -c '^Stopping unmanaged inner containers: loose$' <<< "$output" || true)"
assert_eq "routine Compose output is suppressed" "0" \
    "$(grep -c 'routine compose noise' <<< "$output" || true)"

# Degraded and failure paths use a smaller scenario-driven Docker stub.
SCENARIO_ROOT="$TMPROOT/scenarios"
mkdir -p "$SCENARIO_ROOT/bin" "$SCENARIO_ROOT/work" \
    "$SCENARIO_ROOT/other-work" "$SCENARIO_ROOT/unreadable-work"
touch "$SCENARIO_ROOT/work/compose.yml" \
    "$SCENARIO_ROOT/work/unreadable.yml" \
    "$SCENARIO_ROOT/unreadable-work/compose.yml"
chmod 000 "$SCENARIO_ROOT/work/unreadable.yml"
chmod 600 "$SCENARIO_ROOT/unreadable-work"
cat > "$SCENARIO_ROOT/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$BOXA_SHUTDOWN_SCENARIO_LOG"
case "${1:-}" in
    ps)
        calls="$(cat "$BOXA_SHUTDOWN_SCENARIO_CALLS")"
        calls=$((calls + 1))
        printf '%s\n' "$calls" > "$BOXA_SHUTDOWN_SCENARIO_CALLS"
        if [ "$BOXA_SHUTDOWN_SCENARIO" = daemon-outage ]; then exit 1; fi
        if [ "$calls" -eq 1 ]; then
            printf '%s\n' app-1
            case "$BOXA_SHUTDOWN_SCENARIO" in
                inconsistent-metadata|inconsistent-working-dir|compose-partial) \
                    printf '%s\n' app-2 ;;
            esac
        elif [ "$BOXA_SHUTDOWN_SCENARIO" = remove-failure ]; then
            printf '%s\n' app-1
        fi
        ;;
    inspect)
        [ "$BOXA_SHUTDOWN_SCENARIO" != inspect-failure ] || exit 1
        if [ "$BOXA_SHUTDOWN_SCENARIO" = compose-partial ] \
            && [ "${*: -1}" = app-1 ] \
            && [ -f "$BOXA_SHUTDOWN_SCENARIO_ROOT/compose-partial.removed" ]; then
            exit 1
        fi
        case "$BOXA_SHUTDOWN_SCENARIO:${*: -1}" in
            incomplete-metadata:*)
                printf '/app-1\tapp\t<no value>\t%s/work/compose.yml\n' \
                    "$BOXA_SHUTDOWN_SCENARIO_ROOT"
                ;;
            inconsistent-metadata:app-2)
                printf '/app-2\tapp\t%s/work\t%s/work/other.yml\n' \
                    "$BOXA_SHUTDOWN_SCENARIO_ROOT" "$BOXA_SHUTDOWN_SCENARIO_ROOT"
                ;;
            inconsistent-working-dir:app-2)
                printf '/app-2\tapp\t%s/other-work\t%s/work/compose.yml\n' \
                    "$BOXA_SHUTDOWN_SCENARIO_ROOT" "$BOXA_SHUTDOWN_SCENARIO_ROOT"
                ;;
            unusable-config:*)
                printf '/app-1\tapp\t%s/work\t%s/work/missing.yml\n' \
                    "$BOXA_SHUTDOWN_SCENARIO_ROOT" "$BOXA_SHUTDOWN_SCENARIO_ROOT"
                ;;
            unreadable-config:*)
                printf '/app-1\tapp\t%s/work\t%s/work/unreadable.yml\n' \
                    "$BOXA_SHUTDOWN_SCENARIO_ROOT" "$BOXA_SHUTDOWN_SCENARIO_ROOT"
                ;;
            unusable-working-dir:*)
                printf '/app-1\tapp\t%s/missing-work\t%s/missing-work/compose.yml\n' \
                    "$BOXA_SHUTDOWN_SCENARIO_ROOT" "$BOXA_SHUTDOWN_SCENARIO_ROOT"
                ;;
            unreadable-working-dir:*)
                printf '/app-1\tapp\t%s/unreadable-work\t%s/unreadable-work/compose.yml\n' \
                    "$BOXA_SHUTDOWN_SCENARIO_ROOT" "$BOXA_SHUTDOWN_SCENARIO_ROOT"
                ;;
            *)
                printf '/%s\tapp\t%s/work\t%s/work/compose.yml\n' "${*: -1}" \
                    "$BOXA_SHUTDOWN_SCENARIO_ROOT" "$BOXA_SHUTDOWN_SCENARIO_ROOT"
                ;;
        esac
        ;;
    compose)
        if [ "$BOXA_SHUTDOWN_SCENARIO" = compose-partial ]; then
            : > "$BOXA_SHUTDOWN_SCENARIO_ROOT/compose-partial.removed"
            exit 1
        fi
        [ "$BOXA_SHUTDOWN_SCENARIO" != compose-failure ] \
            && [ "$BOXA_SHUTDOWN_SCENARIO" != remove-failure ]
        ;;
    info) ;;
    stop) ;;
    rm)
        if [ "$BOXA_SHUTDOWN_SCENARIO" = compose-partial ] && [ "${2:-}" = app-1 ]; then
            exit 1
        fi
        [ "$BOXA_SHUTDOWN_SCENARIO" != remove-failure ]
        ;;
esac
STUB
chmod +x "$SCENARIO_ROOT/bin/docker"

run_scenario() {
    local scenario="$1"
    export BOXA_SHUTDOWN_SCENARIO="$scenario"
    export BOXA_SHUTDOWN_SCENARIO_ROOT="$SCENARIO_ROOT"
    export BOXA_SHUTDOWN_SCENARIO_LOG="$SCENARIO_ROOT/$scenario.log"
    export BOXA_SHUTDOWN_SCENARIO_CALLS="$SCENARIO_ROOT/$scenario.calls"
    : > "$BOXA_SHUTDOWN_SCENARIO_LOG"
    printf '0\n' > "$BOXA_SHUTDOWN_SCENARIO_CALLS"
    rm -f "$BOXA_SHUTDOWN_SCENARIO_ROOT/compose-partial.removed"
    scenario_output="$(PATH="$SCENARIO_ROOT/bin:$PATH" \
        bash "$SCRIPT_DIR/../scripts/shutdown-inner-containers.sh" 2>&1)"
    scenario_rc=$?
}

for degraded_scenario in incomplete-metadata unusable-config unreadable-config \
        unusable-working-dir unreadable-working-dir compose-failure inspect-failure; do
    run_scenario "$degraded_scenario"
    assert_eq "$degraded_scenario fallback succeeds" "0" "$scenario_rc"
    assert_eq "$degraded_scenario warns about unordered fallback" "1" \
        "$(grep -c 'without dependency ordering' <<< "$scenario_output" || true)"
    assert_eq "$degraded_scenario gracefully stops the affected container" "1" \
        "$(grep -c '^stop app-1$' "$BOXA_SHUTDOWN_SCENARIO_LOG" || true)"
    assert_eq "$degraded_scenario removes the affected container" "1" \
        "$(grep -c '^rm app-1$' "$BOXA_SHUTDOWN_SCENARIO_LOG" || true)"
done

run_scenario compose-partial
assert_eq "partially completed Compose fallback succeeds" "0" "$scenario_rc"
assert_eq "partially completed Compose fallback warns" "1" \
    "$(grep -c 'Compose teardown failed' <<< "$scenario_output" || true)"
assert_eq "fallback tolerates the record already removed by Compose" "1" \
    "$(grep -c '^rm app-1$' "$BOXA_SHUTDOWN_SCENARIO_LOG" || true)"
assert_eq "fallback removes the remaining original record" "1" \
    "$(grep -c '^rm app-2$' "$BOXA_SHUTDOWN_SCENARIO_LOG" || true)"

run_scenario inconsistent-metadata
assert_eq "inconsistent metadata fallback succeeds" "0" "$scenario_rc"
assert_eq "inconsistent metadata warns for both conflicting groups" "2" \
    "$(grep -c 'inconsistent identity metadata' <<< "$scenario_output" || true)"
assert_eq "inconsistent project does not attempt Compose teardown" "0" \
    "$(grep -c '^compose ' "$BOXA_SHUTDOWN_SCENARIO_LOG" || true)"
assert_eq "inconsistent project removes both containers" "2" \
    "$(grep -c '^rm app-[12]$' "$BOXA_SHUTDOWN_SCENARIO_LOG" || true)"

run_scenario inconsistent-working-dir
assert_eq "working-dir disagreement fallback succeeds" "0" "$scenario_rc"
assert_eq "working-dir disagreement warns for both conflicting groups" "2" \
    "$(grep -c 'inconsistent identity metadata' <<< "$scenario_output" || true)"
assert_eq "working-dir disagreement does not attempt Compose teardown" "0" \
    "$(grep -c '^compose ' "$BOXA_SHUTDOWN_SCENARIO_LOG" || true)"
assert_eq "working-dir disagreement removes both containers" "2" \
    "$(grep -c '^rm app-[12]$' "$BOXA_SHUTDOWN_SCENARIO_LOG" || true)"

run_scenario remove-failure
assert_eq "failed removal returns non-zero" "1" "$scenario_rc"
assert_eq "unresolved leftovers are reported" "1" \
    "$(grep -c 'containers remain after shutdown' <<< "$scenario_output" || true)"

run_scenario daemon-outage
assert_eq "daemon outage returns non-zero" "1" "$scenario_rc"
assert_eq "daemon outage reports unverifiable cleanup" "1" \
    "$(grep -c 'cleanup could not be verified' <<< "$scenario_output" || true)"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll compose-aware shutdown tests passed.\n'
