#!/bin/bash
# End-to-end integration test for per-project memory limits (ADR 0020).
#
# Usage (on the Docker HOST, never inside a boxa container):
#
#   BOXA_INTEGRATION=1 bash tests/integration-memory.sh
#
# This is the repo's first test that starts real containers and provokes real
# OOM kills, so it is explicit opt-in: without BOXA_INTEGRATION=1 (and a
# reachable host Docker daemon on cgroup v2) it SKIPs loudly and exits 0 —
# the repo has no CI, and a silent skip protects nobody.
#
# What it covers, end to end:
#   A. A 64m-limited container OOM-kills the kernel-selected victim process
#      (observed on this topology: the largest — a heuristic, not a
#      guarantee), PID 1 survives, memory.events oom_kill increments, and a
#      finitely-limited bystander container plus the Docker daemon stay
#      untouched (issue 01's flag contract, ADR 0020 semantics).
#   B. Lowering a limit below current usage via `docker update` — the
#      immediate-OOM risk path issue 02 warns about — converges the limit in
#      place and OOM-kills inside that container only.
#   C. A real boxa Container created through docker-run.sh picks its Memory
#      limit up from resources.conf (BOXA_RESOURCES_CONF seam) with swap off,
#      and survives an in-container OOM kill (issue 01 wiring).
#   D. `boxa ls` shows the MEM cell and the !oom marker for running
#      containers, and the lifetime-flag marker for exited ones: the
#      .State.OOMKilled flag means "an OOM happened during the lifetime",
#      NOT "died of OOM" — it reads true even after a non-OOM exit
#      (issue 03 wiring).
#   E. The host sweep archives exactly one record per OOM event into the
#      archive dir and dedups on a second run (issue 06 wiring), exercised
#      through the BOXA_OOM_* env seams against a temp archive dir.
#
# Host safety:
#   - OOM-tripping plain containers are limited to 64m; every allocation is
#     bounded (head -c | tail -c holds at most the pipe budget) even if the
#     limit were not applied; swap is off (--memory-swap == --memory), so no
#     host swap pressure.
#   - The real boxa Container needs to boot an entrypoint plus rootless
#     dockerd, which cannot live under 64m; it gets a 1g limit instead —
#     still tiny against host RAM, and its allocation is bounded at 1.25g.
#   - All names carry a unique per-run id (memtest09*); traps remove every
#     container/volume on success, failure, and interrupt. The real Container
#     is torn down via `docker-run.sh stop --clean` so its volumes and route
#     files go with it.
#
# Known, accepted side effects on the host:
#   - The synthetic OOM events stay in the shared kernel ring buffer. This
#     test's own sweeps are redirected to a temp archive via the env seams,
#     but the NEXT real `boxa` invocation will archive them once into
#     /var/log/boxa/oom and raise one desktop notification per event. The
#     records are self-labeled (container boxa-memtest09*), harmless, and
#     removable. Avoid running other boxa commands while the test runs.
#   - If no other boxa containers are running, the teardown's idle cleanup
#     may stop the shared traefik/dns infra — boxa's own designed behavior.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Gate: explicit opt-in + a usable host Docker daemon ---------------------

if [ "${BOXA_INTEGRATION:-}" != "1" ]; then
    printf 'SKIP  integration-memory suite — BOXA_INTEGRATION=1 not set.\n'
    printf '      This test starts real containers and provokes real OOM kills.\n'
    printf '      Run it on the Docker host:\n'
    printf '          BOXA_INTEGRATION=1 bash tests/integration-memory.sh\n'
    exit 0
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    printf 'SKIP  integration-memory suite — no reachable Docker daemon.\n'
    printf '      Run this on the host where boxa'\''s Docker daemon lives.\n'
    exit 0
fi

# Inside a boxa Container the reachable daemon is the inner rootless dockerd,
# which runs with CgroupDriver=none — limits are silently not enforced there
# (ADR 0020). This test is only meaningful against the host daemon.
CGROUP_DRIVER="$(docker info --format '{{.CgroupDriver}}' 2>/dev/null)"
if [ "$CGROUP_DRIVER" = "none" ] || [ -z "$CGROUP_DRIVER" ]; then
    printf 'SKIP  integration-memory suite — Docker daemon has CgroupDriver=none\n'
    printf '      (rootless/DinD daemon, e.g. inside a boxa Container). Run it on the host.\n'
    exit 0
fi

if [ "$(docker info --format '{{.CgroupVersion}}' 2>/dev/null)" != "2" ]; then
    printf 'SKIP  integration-memory suite — host Docker is not on cgroup v2.\n'
    printf '      The memory.events/memory.max probes assume the unified hierarchy.\n'
    exit 0
fi

# shellcheck source-path=SCRIPTDIR/.. source=lib/brand.sh disable=SC1091
source "$BOXA_DIR/lib/brand.sh"
# shellcheck source-path=SCRIPTDIR/.. source=lib/naming.sh disable=SC1091
source "$BOXA_DIR/lib/naming.sh"

if ! docker image inspect "$BRAND_IMAGE" >/dev/null 2>&1; then
    printf 'SKIP  integration-memory suite — image %s not present locally.\n' "$BRAND_IMAGE"
    printf '      Build it first: boxa build\n'
    exit 0
fi

# --- Setup --------------------------------------------------------------------

RUN_ID="$(date +%s)"
VICTIM="boxa-memtest09v${RUN_ID}"
BYSTANDER="boxa-memtest09b${RUN_ID}"
LOWER="boxa-memtest09l${RUN_ID}"

REAL_DIR="/tmp/memtest09r${RUN_ID}"
boxa::names_from_path "$REAL_DIR"
REAL_PROJECT="$BOXA_PROJECT_NAME"
REAL_CONTAINER="$BOXA_CONTAINER_NAME"
REAL_VOL_HISTORY="$BOXA_VOL_HISTORY"
REAL_VOL_DOCKER="$BOXA_VOL_DOCKER"
REAL_STARTED=false

LIMIT_64M=67108864
LIMIT_256M=268435456
LIMIT_1G=1073741824
ALLOC_128M=134217728       # 2x the 64m limit, hard upper bound of the holder
ALLOC_1280M=1342177280     # 1.25x the real Container's 1g limit

TMP="$(mktemp -d)"
ASSERT_DIR="$TMP/archive"
ASSERT_STATE="$ASSERT_DIR/.state"
ASSERT_NOTIFY="$TMP/assert-notify.log"
mkdir -p "$ASSERT_DIR"
: > "$ASSERT_NOTIFY"

cleanup() {
    docker rm -f "$VICTIM" "$BYSTANDER" "$LOWER" >/dev/null 2>&1 || true
    if [ "$REAL_STARTED" = true ]; then
        if docker ps -a --filter "name=^${REAL_CONTAINER}$" --format '{{.ID}}' 2>/dev/null | grep -q .; then
            timeout 120 bash "$BOXA_DIR/docker-run.sh" stop "$REAL_PROJECT" --clean \
                </dev/null >/dev/null 2>&1 \
                || docker rm -f "$REAL_CONTAINER" >/dev/null 2>&1 || true
        fi
        # Backstop if stop --clean did not run: per-project volumes by name.
        docker volume rm "$REAL_VOL_HISTORY" "$REAL_VOL_DOCKER" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP" "$REAL_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Notification seam: record calls instead of raising real desktop toasts.
NOTIFY_STUB="$TMP/notify-stub.sh"
cat > "$NOTIFY_STUB" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${MEMTEST_NOTIFY_LOG:?}"
STUB
chmod +x "$NOTIFY_STUB"

# Every docker-run.sh invocation below fires its own detached OOM sweep.
# Redirect those to a side scratch area (separate from the assertion archive,
# so the async workers can never race the synchronous sweep assertions) and
# stub the notifier, keeping /var/log/boxa/oom and the desktop untouched.
export BOXA_OOM_ARCHIVE_DIR="$TMP/side-archive"
export BOXA_OOM_STATE_FILE="$TMP/side-archive/.state"
export BOXA_OOM_NOTIFY_CMD="$NOTIFY_STUB"
export MEMTEST_NOTIFY_LOG="$TMP/side-notify.log"
: > "$MEMTEST_NOTIFY_LOG"

fail_count=0
skip_note=""

pass() { printf 'PASS  %s\n' "$1"; }
fail() {
    printf 'FAIL  %s\n' "$1"
    [ $# -gt 1 ] && printf '      %s\n' "$2"
    fail_count=$((fail_count + 1))
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$label"
    else
        fail "$label" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) pass "$label" ;;
        *) fail "$label" "missing '$needle'" ;;
    esac
}

# wait_until <tries> <cmd...> — polls at 0.5s; bounded, never hangs the host.
wait_until() {
    local tries="$1" i
    shift
    for ((i = 0; i < tries; i++)); do
        if "$@"; then return 0; fi
        sleep 0.5
    done
    return 1
}

oom_kill_count() {
    docker exec -u root "$1" sh -c \
        'awk '\''$1 == "oom_kill" { print $2 }'\'' /sys/fs/cgroup/memory.events' \
        2>/dev/null
}

mem_current() {
    docker exec -u root "$1" cat /sys/fs/cgroup/memory.current 2>/dev/null
}

container_status() {
    docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null
}

# The three predicates below run indirectly as `wait_until N <predicate> ...`
# ("$@" in the loop body), which shellcheck cannot see — silence its false
# "unreachable" report, the same pattern as assert_false in port-conflict.sh.
# shellcheck disable=SC2317
oom_at_least() {
    local count
    count="$(oom_kill_count "$1")"
    [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -ge "$2" ]
}

# shellcheck disable=SC2317
mem_at_least() {
    local current
    current="$(mem_current "$1")"
    [[ "$current" =~ ^[0-9]+$ ]] && [ "$current" -ge "$2" ]
}

# shellcheck disable=SC2317
mem_below() {
    local current
    current="$(mem_current "$1")"
    [[ "$current" =~ ^[0-9]+$ ]] && [ "$current" -lt "$2" ]
}

# Count archive records for one container name in the assertion archive.
archive_count() {
    local count=0 f
    for f in "$ASSERT_DIR/$1-"*.log; do
        [ -e "$f" ] && count=$((count + 1))
    done
    printf '%s' "$count"
}

run_assert_sweep() {
    BOXA_OOM_ARCHIVE_DIR="$ASSERT_DIR" \
    BOXA_OOM_STATE_FILE="$ASSERT_STATE" \
    MEMTEST_NOTIFY_LOG="$ASSERT_NOTIFY" \
        bash "$BOXA_DIR/scripts/sweep-oom-events.sh"
}

printf 'integration-memory suite — run id %s, image %s\n' "$RUN_ID" "$BRAND_IMAGE"

# =============================================================================
# Phase A — OOM isolation in a 64m-limited container, finite bystander
# =============================================================================
printf '\n--- Phase A: OOM stays inside the limited container ---\n'

docker run -d --pull=never --name "$VICTIM" \
    --memory "$LIMIT_64M" --memory-swap "$LIMIT_64M" \
    --entrypoint sleep "$BRAND_IMAGE" 1800 >/dev/null
# The bystander is itself finitely limited — an unlimited bystander would
# prove nothing about isolation and could endanger the host on a regression.
docker run -d --pull=never --name "$BYSTANDER" \
    --memory "$LIMIT_256M" --memory-swap "$LIMIT_256M" \
    --entrypoint sleep "$BRAND_IMAGE" 1800 >/dev/null

assert_eq "victim HostConfig.Memory is 64m" \
    "$LIMIT_64M" "$(docker inspect --format '{{.HostConfig.Memory}}' "$VICTIM")"
assert_eq "victim HostConfig.MemorySwap equals Memory (swap off contract)" \
    "$LIMIT_64M" "$(docker inspect --format '{{.HostConfig.MemorySwap}}' "$VICTIM")"
# The measured Docker footgun: --memory alone would silently grant 2x swap.
# Passing both flags must land as memory.swap.max = 0 (ADR 0020).
assert_eq "victim cgroup memory.swap.max is 0 (no swap escape)" \
    "0" "$(docker exec -u root "$VICTIM" cat /sys/fs/cgroup/memory.swap.max)"
assert_eq "victim oom_kill counter starts at 0" "0" "$(oom_kill_count "$VICTIM")"

# Bounded allocator: tail -c holds at most 128M (2x the limit) even if the
# limit were broken, so the host is safe either way. Under the 64m limit the
# kernel OOM-kills its selected victim mid-pipe (observed: tail, the largest
# process — a heuristic, not a guarantee).
alloc_rc=0
timeout 120 docker exec "$VICTIM" bash -c \
    "head -c $ALLOC_128M /dev/zero | tail -c $ALLOC_128M > /dev/null" \
    >/dev/null 2>&1 || alloc_rc=$?
if [ "$alloc_rc" -ne 0 ]; then
    pass "allocator was killed before completing (rc=$alloc_rc)"
else
    fail "allocator was killed before completing" "128M allocation survived a 64m limit"
fi

if wait_until 20 oom_at_least "$VICTIM" 1; then
    pass "victim oom_kill counter incremented"
else
    fail "victim oom_kill counter incremented" "memory.events oom_kill stayed at $(oom_kill_count "$VICTIM")"
fi
assert_eq "exactly one OOM kill for one allocation" "1" "$(oom_kill_count "$VICTIM")"
assert_eq "victim PID 1 survived (container still running)" \
    "running" "$(container_status "$VICTIM")"
assert_eq "victim still accepts exec" \
    "ok" "$(docker exec "$VICTIM" echo ok 2>/dev/null)"

assert_eq "bystander untouched (still running)" \
    "running" "$(container_status "$BYSTANDER")"
assert_eq "bystander still responsive" \
    "alive" "$(docker exec "$BYSTANDER" echo alive 2>/dev/null)"
assert_eq "bystander saw zero OOM kills" "0" "$(oom_kill_count "$BYSTANDER")"

if docker info >/dev/null 2>&1; then
    pass "Docker daemon alive and responsive after the OOM"
else
    fail "Docker daemon alive and responsive after the OOM"
fi

# =============================================================================
# Phase B — lowering a limit below current usage via docker update
# =============================================================================
# The live-convergence risk path (issue 02): converging a running Container
# DOWN below its current usage cannot reclaim anonymous memory with swap off,
# so the kernel OOM-kills inside that container immediately. Assertions key
# on stable observables (inspect values, memory.events), not message text.
# TODO(issue 02): once the boxa-side convergence sweep lands with its final
# lower-below-usage warning wording, drive this phase through the boxa CLI
# and assert the printed warning as well.
printf '\n--- Phase B: docker update below current usage ---\n'

# PID 1 (bash) stays small; the fifo holder pins ~128M of anonymous memory in
# a background tail until the writer's sleep ends — bounded by construction.
docker run -d --pull=never --name "$LOWER" \
    --memory "$LIMIT_256M" --memory-swap "$LIMIT_256M" \
    --entrypoint bash "$BRAND_IMAGE" -c "
        mkfifo /tmp/holdpipe
        (head -c $ALLOC_128M /dev/zero; sleep 1800) > /tmp/holdpipe &
        tail -c $ALLOC_128M /tmp/holdpipe > /dev/null &
        sleep 1800" >/dev/null

if wait_until 60 mem_at_least "$LOWER" 117440512; then
    pass "holder pinned >112M inside the 256m container"
else
    fail "holder pinned >112M inside the 256m container" "memory.current=$(mem_current "$LOWER")"
fi

update_rc=0
timeout 60 docker update --memory "$LIMIT_64M" --memory-swap "$LIMIT_64M" \
    "$LOWER" >/dev/null 2>&1 || update_rc=$?
assert_eq "docker update to 64m on a running container succeeds" "0" "$update_rc"
assert_eq "lowered HostConfig.Memory converged to 64m" \
    "$LIMIT_64M" "$(docker inspect --format '{{.HostConfig.Memory}}' "$LOWER")"
assert_eq "lowered HostConfig.MemorySwap converged with it" \
    "$LIMIT_64M" "$(docker inspect --format '{{.HostConfig.MemorySwap}}' "$LOWER")"

if wait_until 20 oom_at_least "$LOWER" 1; then
    pass "lowering below usage OOM-killed the kernel-selected victim"
else
    fail "lowering below usage OOM-killed the kernel-selected victim" \
        "oom_kill=$(oom_kill_count "$LOWER")"
fi
if wait_until 20 mem_below "$LOWER" "$LIMIT_64M"; then
    pass "usage dropped under the new 64m limit"
else
    fail "usage dropped under the new 64m limit" "memory.current=$(mem_current "$LOWER")"
fi
assert_eq "lowered container's PID 1 survived" \
    "running" "$(container_status "$LOWER")"

# =============================================================================
# Phase C — real boxa Container: limit applied at creation (issue 01 wiring)
# =============================================================================
printf '\n--- Phase C: real boxa Container via docker-run.sh ---\n'

mkdir -p "$REAL_DIR"
REAL_CONF="$TMP/resources.conf"
printf '[%s]\nmemory = 1g\n' "$REAL_DIR" > "$REAL_CONF"

# 1g, not 64m: the entrypoint plus rootless dockerd cannot boot under 64m.
# Still a tiny, bounded slice of host RAM. The trailing interactive
# `exec docker exec -it ... zsh` fails without a TTY — expected; the
# container itself must be up regardless.
REAL_STARTED=true
BOXA_RESOURCES_CONF="$REAL_CONF" timeout 420 \
    bash "$BOXA_DIR/docker-run.sh" "$REAL_DIR" \
    </dev/null > "$TMP/create.log" 2>&1 || true

assert_contains "startup printed the Memory limit line with its origin" \
    "$(cat "$TMP/create.log")" "Memory limit: 1g (project config"

REAL_OK=false
if [ "$(container_status "$REAL_CONTAINER")" = "running" ]; then
    REAL_OK=true
    pass "real boxa Container is running"
    assert_eq "real Container HostConfig.Memory from resources.conf" \
        "$LIMIT_1G" "$(docker inspect --format '{{.HostConfig.Memory}}' "$REAL_CONTAINER")"
    assert_eq "real Container swap off by default (MemorySwap == Memory)" \
        "$LIMIT_1G" "$(docker inspect --format '{{.HostConfig.MemorySwap}}' "$REAL_CONTAINER")"

    real_alloc_rc=0
    timeout 180 docker exec -u node "$REAL_CONTAINER" bash -c \
        "head -c $ALLOC_1280M /dev/zero | tail -c $ALLOC_1280M > /dev/null" \
        >/dev/null 2>&1 || real_alloc_rc=$?
    if [ "$real_alloc_rc" -ne 0 ]; then
        pass "in-Container allocator was killed (rc=$real_alloc_rc)"
    else
        fail "in-Container allocator was killed" "1.25g allocation survived a 1g limit"
    fi
    if wait_until 20 oom_at_least "$REAL_CONTAINER" 1; then
        pass "real Container oom_kill counter incremented"
    else
        fail "real Container oom_kill counter incremented" \
            "oom_kill=$(oom_kill_count "$REAL_CONTAINER")"
    fi
    assert_eq "real Container PID 1 survived its OOM kill" \
        "running" "$(container_status "$REAL_CONTAINER")"
else
    fail "real boxa Container is running" \
        "creation failed; see docker logs $REAL_CONTAINER and $TMP/create.log tail below"
    tail -n 25 "$TMP/create.log" | sed 's/^/      | /'
fi

# =============================================================================
# Phase D — boxa ls diagnostics: MEM cell, !oom marker, lifetime flag
# =============================================================================
printf '\n--- Phase D: boxa ls MEM column and OOM markers ---\n'

ls_rc=0
ls_output="$(timeout 120 bash "$BOXA_DIR/docker-run.sh" ls </dev/null 2>/dev/null)" || ls_rc=$?
assert_eq "boxa ls exits 0 with test containers present" "0" "$ls_rc"

victim_row="$(grep -F "$VICTIM" <<< "$ls_output" || true)"
assert_contains "ls shows the victim's limit in the MEM cell" "$victim_row" "/64m"
assert_contains "ls shows the victim's OOM marker" "$victim_row" "!oom×1"
if [ "$REAL_OK" = true ]; then
    real_row="$(grep -F "$REAL_CONTAINER" <<< "$ls_output" || true)"
    assert_contains "ls shows the real Container's 1g limit" "$real_row" "/1g"
    assert_contains "ls shows the real Container's OOM marker" "$real_row" "!oom×"
fi

# Lifetime-flag semantics: stop the victim with SIGTERM (a non-OOM exit).
# .State.OOMKilled must STILL read true — it means "an OOM kill happened
# during the lifetime", never "the container died of OOM" (ADR 0020).
docker stop -t 5 "$VICTIM" >/dev/null 2>&1 || true
assert_eq "victim exited" "exited" "$(container_status "$VICTIM")"
assert_eq ".State.OOMKilled is true after a non-OOM exit (lifetime flag)" \
    "true" "$(docker inspect --format '{{.State.OOMKilled}}' "$VICTIM")"

ls_output2="$(timeout 120 bash "$BOXA_DIR/docker-run.sh" ls </dev/null 2>/dev/null)" || true
exited_row="$(grep -F "$VICTIM" <<< "$ls_output2" || true)"
assert_contains "exited section carries the lifetime-flag marker" \
    "$exited_row" "oom seen during run"

# =============================================================================
# Phase E — host sweep: one archive record per event, dedup on rerun
# =============================================================================
printf '\n--- Phase E: OOM archive sweep and dedup ---\n'

if ! dmesg >/dev/null 2>&1; then
    printf 'SKIP  phase E — dmesg is not readable without privileges on this host.\n'
    printf '      The sweep cannot observe kernel OOM events here; on the target\n'
    printf '      WSL2/Docker Desktop host dmesg is readable (measured, ADR 0020).\n'
    skip_note="phase E (sweep) skipped: dmesg unreadable"
else
    sweep_rc=0
    run_assert_sweep || sweep_rc=$?
    assert_eq "sweep run exits 0" "0" "$sweep_rc"

    assert_eq "exactly one archive record for the victim's single event" \
        "1" "$(archive_count "$VICTIM")"
    if [ "$(archive_count "$LOWER")" -ge 1 ]; then
        pass "archive record(s) present for the lowered container's event"
    else
        fail "archive record(s) present for the lowered container's event"
    fi
    if [ "$REAL_OK" = true ]; then
        assert_eq "exactly one archive record for the real Container's event" \
            "1" "$(archive_count "$REAL_CONTAINER")"
    fi

    victim_record="$(cat "$ASSERT_DIR/$VICTIM-"*.log 2>/dev/null || true)"
    assert_contains "record names the container" "$victim_record" "Container: $VICTIM"
    assert_contains "record names the project" "$victim_record" "Project: ${VICTIM#boxa-}"
    assert_contains "record shows the limit" "$victim_record" "Memory limit: 64 MiB"
    assert_contains "record uses kernel-heuristic victim wording" \
        "$victim_record" "Kernel-selected victim:"
    assert_contains "notification was sent for the victim's event" \
        "$(cat "$ASSERT_NOTIFY")" "${VICTIM#boxa-}"

    files_before="$(archive_count "$VICTIM")$(archive_count "$LOWER")$(archive_count "$REAL_CONTAINER")"
    notify_before="$(grep -c "memtest09" "$ASSERT_NOTIFY" || true)"
    sweep_rc=0
    run_assert_sweep || sweep_rc=$?
    assert_eq "second sweep run exits 0" "0" "$sweep_rc"
    files_after="$(archive_count "$VICTIM")$(archive_count "$LOWER")$(archive_count "$REAL_CONTAINER")"
    notify_after="$(grep -c "memtest09" "$ASSERT_NOTIFY" || true)"
    assert_eq "second sweep archives nothing new for the test events (dedup)" \
        "$files_before" "$files_after"
    assert_eq "second sweep re-notifies nothing (dedup)" \
        "$notify_before" "$notify_after"
fi

# =============================================================================
# Cleanup — and prove nothing is left behind
# =============================================================================
printf '\n--- Cleanup: no containers, volumes, or archive litter left ---\n'

cleanup_containers_rc=0
cleanup || cleanup_containers_rc=$?
assert_eq "cleanup completed" "0" "$cleanup_containers_rc"

leftover_containers="$(docker ps -a --format '{{.Names}}' | grep -c "memtest09" || true)"
assert_eq "no test containers remain" "0" "$leftover_containers"
leftover_volumes="$(docker volume ls -q | grep -c "memtest09" || true)"
assert_eq "no test volumes remain" "0" "$leftover_volumes"
real_archive_litter="$(find /var/log/boxa/oom -maxdepth 1 -name '*memtest09*' 2>/dev/null | grep -c . || true)"
assert_eq "no records leaked into the real OOM archive" "0" "$real_archive_litter"

# --- Summary -------------------------------------------------------------------

printf '\n'
if [ -n "$skip_note" ]; then
    printf 'NOTE: %s\n' "$skip_note"
fi
if [ "$fail_count" -eq 0 ]; then
    printf 'All assertions passed.\n'
    exit 0
fi
printf '%d assertion(s) failed.\n' "$fail_count"
exit 1
