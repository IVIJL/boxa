#!/bin/bash
# Plain-bash assertions for scripts/hooks/boxa-memory-context.sh.
# Runs without Docker: unit tests source the script's functions
# (BOXA_MEMHOOK_NO_MAIN=1), end-to-end cases execute it with the env
# seams pointing at fixture cgroup files. Usage: bash tests/memory-context.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../scripts/hooks/boxa-memory-context.sh"

BOXA_MEMHOOK_NO_MAIN=1
# shellcheck source-path=SCRIPTDIR source=../scripts/hooks/boxa-memory-context.sh disable=SC1091
source "$HOOK"
unset BOXA_MEMHOOK_NO_MAIN

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
    case "$haystack" in
        *"$needle"*) printf 'PASS  %s\n' "$label" ;;
        *)
            printf 'FAIL  %s\n      missing:  %q\n      in:       %q\n' \
                "$label" "$needle" "$haystack"
            fail_count=$((fail_count + 1))
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Unit: band transitions (the hysteresis table)
# ---------------------------------------------------------------------------

band_case() {
    local label="$1" old="$2" pct="$3" want_new="$4" want_warn="$5"
    memhook_band_transition "$old" "$pct"
    assert_eq "band: $label -> new" "$want_new" "$MEMHOOK_NEW_BAND"
    assert_eq "band: $label -> warn" "$want_warn" "$MEMHOOK_WARN_BAND"
}

band_case "idle at 50%"                 0  50  0  0
band_case "just below 80% stays quiet"  0  79  0  0
band_case "enter 80% band"              0  80 80 80
band_case "hover inside 80% band"      80  85 80  0
band_case "dip to 79% keeps band"      80  79 80  0
band_case "dip to 75% keeps band"      80  75 80  0
band_case "re-arm below 75%"           80  74  0  0
band_case "escalate 80 -> 90"          80  92 90 90
band_case "hover inside 90% band"      90  95 90  0
band_case "90 dips to 85, no repeat"   90  85 90  0
band_case "90 dips to 76, no repeat"   90  76 90  0
band_case "90 re-arms below 75%"       90  74  0  0
band_case "jump straight to 95%"        0  95 90 90
band_case "re-armed re-entry warns"     0  85 80 80
band_case "already 90 stays 90"        90  99 90  0

# ---------------------------------------------------------------------------
# Unit: oom counter dedup
# ---------------------------------------------------------------------------

memhook_oom_action 0 0
assert_eq "oom: no kills -> none" "none" "$MEMHOOK_OOM_ACTION"
memhook_oom_action 3 3
assert_eq "oom: unchanged counter -> none" "none" "$MEMHOOK_OOM_ACTION"
memhook_oom_action 0 2
assert_eq "oom: 0->2 -> report" "report" "$MEMHOOK_OOM_ACTION"
assert_eq "oom: 0->2 delta" "2" "$MEMHOOK_OOM_DELTA"
memhook_oom_action 4 5
assert_eq "oom: 4->5 -> report" "report" "$MEMHOOK_OOM_ACTION"
assert_eq "oom: 4->5 delta" "1" "$MEMHOOK_OOM_DELTA"
memhook_oom_action 5 1
assert_eq "oom: counter regression -> seed" "seed" "$MEMHOOK_OOM_ACTION"

# ---------------------------------------------------------------------------
# Unit: percentage / limit parsing
# ---------------------------------------------------------------------------

memhook_pct 800 1000
assert_eq "pct: 800/1000 = 80" "80" "$MEMHOOK_PCT"
memhook_pct 899 1000
assert_eq "pct: truncates down" "89" "$MEMHOOK_PCT"
memhook_pct 500 max
assert_eq "pct: unlimited -> empty" "" "$MEMHOOK_PCT"
memhook_pct "" 1000
assert_eq "pct: empty usage -> empty" "" "$MEMHOOK_PCT"
memhook_pct 500 0
assert_eq "pct: zero limit -> empty" "" "$MEMHOOK_PCT"
memhook_pct 858993459200 1073741824000
assert_eq "pct: 800GiB/1000GiB no overflow" "80" "$MEMHOOK_PCT"

# ---------------------------------------------------------------------------
# Unit: memory.events reader
# ---------------------------------------------------------------------------

events="$_TMPROOT/memory.events"
printf 'low 0\nhigh 0\nmax 4\noom 2\noom_kill 7\noom_group_kill 0\n' > "$events"
memhook_read_oom_kill "$events"
assert_eq "events: reads oom_kill, not oom/max" "7" "$MEMHOOK_OOM_KILL"
memhook_read_oom_kill "$_TMPROOT/no-such-file"
assert_eq "events: missing file -> 0" "0" "$MEMHOOK_OOM_KILL"

# ---------------------------------------------------------------------------
# Unit: kernel kill-record parsing (real dmesg format)
# ---------------------------------------------------------------------------

kill_line='[ 8123.456789] Memory cgroup out of memory: Killed process 74157 (ugrep) total-vm:9273016kB, anon-rss:8123456kB, file-rss:1024kB, shmem-rss:0kB, UID:1000 pgtables:16108kB oom_score_adj:0'
memhook_parse_kill_line "$kill_line"
assert_eq "kill line: rc" "0" "$?"
assert_eq "kill line: pid" "74157" "$MEMHOOK_VICTIM_PID"
assert_eq "kill line: name" "ugrep" "$MEMHOOK_VICTIM_NAME"
assert_eq "kill line: anon-rss kB" "8123456" "$MEMHOOK_VICTIM_RSS_KB"
assert_eq "kill line: timestamp seconds" "8123" "$MEMHOOK_VICTIM_TS"

memhook_parse_kill_line "[ 12.3] systemd[1]: Started something." \
    && parse_rc=0 || parse_rc=$?
assert_eq "non-kill line rejected" "1" "$parse_rc"

# ---------------------------------------------------------------------------
# Unit: state round-trip and validation
# ---------------------------------------------------------------------------

state="$_TMPROOT/state"
memhook_save_state "$state" 5 80
memhook_load_state "$state"
assert_eq "state: round-trip rc" "0" "$?"
assert_eq "state: oom_kill" "5" "$MEMHOOK_STATE_OOM"
assert_eq "state: band" "80" "$MEMHOOK_STATE_BAND"

memhook_load_state "$_TMPROOT/absent" && load_rc=0 || load_rc=$?
assert_eq "state: missing file rejected" "1" "$load_rc"
printf 'oom_kill=evil\nband=80\n' > "$state"
memhook_load_state "$state" && load_rc=0 || load_rc=$?
assert_eq "state: non-numeric counter rejected" "1" "$load_rc"
printf 'oom_kill=1\nband=55\n' > "$state"
memhook_load_state "$state" && load_rc=0 || load_rc=$?
assert_eq "state: invalid band rejected" "1" "$load_rc"

# ---------------------------------------------------------------------------
# End-to-end: execute the hook against fixture cgroup files
# ---------------------------------------------------------------------------

E2E="$_TMPROOT/e2e"
mkdir -p "$E2E/cgroup"
printf '{"project": "demo", "projectKey": "/home/user/proj/demo"}\n' \
    > "$E2E/identity.json"
printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n' \
    > "$E2E/cgroup/memory.events"
printf '104857600\n' > "$E2E/cgroup/memory.current"   # 100 MiB
printf '1073741824\n' > "$E2E/cgroup/memory.max"      # 1 GiB
printf '9000.00 12345.00\n' > "$E2E/uptime"
: > "$E2E/dmesg"

run_hook() {
    local event=${1:-PostToolUse} session_id=${2:-session-default} input hook_arg=${1:-}
    if [ "$event" = "SessionStart" ]; then
        hook_arg=session-start
        input=$(printf '{"hook_event_name":"SessionStart","session_id":"%s"}\n' \
            "$session_id")
    else
        input=$(printf '{"hook_event_name":"PostToolUse","session_id":"%s"}\n' \
            "$session_id")
    fi
    BOXA_MEMHOOK_IDENTITY_FILE="$E2E/identity.json" \
    BOXA_MEMHOOK_CGROUP_DIR="$E2E/cgroup" \
    BOXA_MEMHOOK_STATE_DIR="$E2E" \
    BOXA_MEMHOOK_DMESG_FILE="$E2E/dmesg" \
    BOXA_MEMHOOK_UPTIME_FILE="$E2E/uptime" \
    USER=tester sh "$HOOK" "$hook_arg" <<< "$input"
}

run_hook_without_session_id() {
    BOXA_MEMHOOK_IDENTITY_FILE="$E2E/identity.json" \
    BOXA_MEMHOOK_CGROUP_DIR="$E2E/cgroup" \
    BOXA_MEMHOOK_STATE_DIR="$E2E" \
    BOXA_MEMHOOK_DMESG_FILE="$E2E/dmesg" \
    BOXA_MEMHOOK_UPTIME_FILE="$E2E/uptime" \
    USER=fallback sh "$HOOK" "$1" <<< "{\"hook_event_name\":\"$2\"}"
}

context_of() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext'
}

out=$(run_hook); rc=$?
assert_eq "e2e: first run seeds silently" "" "$out"
assert_eq "e2e: first run rc 0" "0" "$rc"
out=$(run_hook)
assert_eq "e2e: quiet steady state stays silent" "" "$out"

# Each agent session owns its baseline and warning-band transitions. Starting
# B must not overwrite A, and A reporting a crossing must not silence B.
printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n' \
    > "$E2E/cgroup/memory.events"
printf '104857600\n' > "$E2E/cgroup/memory.current"
out=$(run_hook SessionStart 'session/A'); rc=$?
assert_eq "e2e: session A starts silently" "" "$out"
printf 'low 0\nhigh 0\nmax 1\noom 1\noom_kill 1\noom_group_kill 0\n' \
    > "$E2E/cgroup/memory.events"
out=$(run_hook SessionStart 'session B'); rc=$?
assert_eq "e2e: session B starts silently" "" "$out"
assert_eq "e2e: session A id is sanitized in state path" "yes" \
    "$([ -f "$E2E/boxa-memory-hook.tester.session_A.state" ] && printf yes)"
assert_eq "e2e: session B has a separate state file" "yes" \
    "$([ -f "$E2E/boxa-memory-hook.tester.session_B.state" ] && printf yes)"
out=$(run_hook PostToolUse 'session/A')
assert_contains "e2e: SessionStart B does not reset A baseline" "OOM-killed" \
    "$(context_of "$out")"
printf '891289600\n' > "$E2E/cgroup/memory.current"
out=$(run_hook PostToolUse 'session/A')
assert_contains "e2e: session A reports 80% crossing" \
    "83% of its Memory limit" "$(context_of "$out")"
out=$(run_hook PostToolUse 'session B')
assert_contains "e2e: session B independently reports 80% crossing" \
    "83% of its Memory limit" "$(context_of "$out")"

old_state="$E2E/boxa-memory-hook.tester.expired.state"
: > "$old_state"
touch -d '9 days ago' "$old_state"
run_hook SessionStart cleanup-session > /dev/null
assert_eq "e2e: SessionStart prunes expired session state" "no" \
    "$([ -e "$old_state" ] && printf yes || printf no)"

# Defensive fallback: inputs without session_id remain stable across events
# from the same parent process, rather than using the per-user shared state.
printf '104857600\n' > "$E2E/cgroup/memory.current"
out=$(run_hook_without_session_id session-start SessionStart); rc=$?
assert_eq "e2e: missing session_id fallback starts silently" "" "$out"
fallback_state=
for candidate in "$E2E"/boxa-memory-hook.fallback.ppid-*.state; do
    if [ -f "$candidate" ]; then fallback_state=$candidate; fi
done
assert_contains "e2e: missing session_id uses PPID-scoped path" \
    "boxa-memory-hook.fallback.ppid-" "$fallback_state"
printf 'low 0\nhigh 0\nmax 2\noom 2\noom_kill 2\noom_group_kill 0\n' \
    > "$E2E/cgroup/memory.events"
out=$(run_hook_without_session_id '' PostToolUse)
assert_contains "e2e: missing session_id fallback keeps baseline" "OOM-killed" \
    "$(context_of "$out")"

# SessionStart establishes the baseline before any tool call. An already
# positive counter is historical at session start and stays silent afterward.
rm -f "$E2E"/boxa-memory-hook.tester.*.state
printf 'low 0\nhigh 0\nmax 4\noom 4\noom_kill 4\noom_group_kill 0\n' \
    > "$E2E/cgroup/memory.events"
out=$(run_hook session-start); rc=$?
assert_eq "e2e: SessionStart seeds positive baseline silently" "" "$out"
assert_eq "e2e: SessionStart seed exits 0" "0" "$rc"
out=$(run_hook)
assert_eq "e2e: seeded historical kills stay silent" "" "$out"

# Without a SessionStart state, a positive counter on the first PostToolUse
# means that the first tool call may have been killed: report once, then seed.
rm -f "$E2E"/boxa-memory-hook.tester.*.state
printf 'low 0\nhigh 0\nmax 1\noom 1\noom_kill 1\noom_group_kill 0\n' \
    > "$E2E/cgroup/memory.events"
printf '%s\n' "$kill_line" > "$E2E/dmesg"
out=$(run_hook)
assert_contains "e2e: first-call kill without baseline warns" "OOM-killed" \
    "$(context_of "$out")"
out=$(run_hook)
assert_eq "e2e: first-call kill is reported exactly once" "" "$out"

# Restore a clean baseline for the existing band/dedup scenarios.
printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n' \
    > "$E2E/cgroup/memory.events"
run_hook session-start > /dev/null

printf '891289600\n' > "$E2E/cgroup/memory.current"   # 83%
out=$(run_hook)
ctx=$(context_of "$out")
assert_contains "e2e: entering 80% band warns" "83% of its Memory limit" "$ctx"
assert_contains "e2e: 80% warning names usage/limit" "850 MiB of 1.0 GiB" "$ctx"
# shellcheck disable=SC2088 # literal-text needle: the message intentionally shows an unexpanded ~ path
assert_contains "e2e: warning carries raise guidance" \
    "~/.config/boxa/resources.conf" "$ctx"
assert_contains "e2e: guidance keyed by host path" "[/home/user/proj/demo]" "$ctx"
assert_eq "e2e: hookEventName is PostToolUse" "PostToolUse" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')"

out=$(run_hook)
assert_eq "e2e: hovering at 83% does not repeat" "" "$out"

printf '996147200\n' > "$E2E/cgroup/memory.current"   # 95%
out=$(run_hook)
assert_contains "e2e: entering 90% band warns" "OOM kill is imminent" \
    "$(context_of "$out")"
out=$(run_hook)
assert_eq "e2e: hovering at 95% does not repeat" "" "$out"

printf '838860800\n' > "$E2E/cgroup/memory.current"   # 78% — inside hysteresis
out=$(run_hook)
assert_eq "e2e: dropping to 78% stays silent (no re-arm yet)" "" "$out"
printf '996147200\n' > "$E2E/cgroup/memory.current"   # back to 95%
out=$(run_hook)
assert_eq "e2e: bouncing back to 95% does not re-warn" "" "$out"

printf '536870912\n' > "$E2E/cgroup/memory.current"   # 50% — re-arms
out=$(run_hook)
assert_eq "e2e: re-arm below 75% is silent" "" "$out"
printf '891289600\n' > "$E2E/cgroup/memory.current"   # 83% again
out=$(run_hook)
assert_contains "e2e: re-entry after re-arm warns again" \
    "83% of its Memory limit" "$(context_of "$out")"

# --- OOM kill reporting ---
printf '536870912\n' > "$E2E/cgroup/memory.current"
run_hook > /dev/null                                   # settle band state
printf 'low 0\nhigh 0\nmax 9\noom 1\noom_kill 1\noom_group_kill 0\n' \
    > "$E2E/cgroup/memory.events"
printf '%s\n' "$kill_line" > "$E2E/dmesg"
out=$(run_hook)
ctx=$(context_of "$out")
assert_contains "e2e: oom reports victim name" "'ugrep'" "$ctx"
assert_contains "e2e: oom reports victim RSS" "7.7 GiB" "$ctx"
assert_contains "e2e: oom reports the limit" "Memory limit: 1.0 GiB" "$ctx"
assert_contains "e2e: oom reports when" "~14 min ago" "$ctx"
# shellcheck disable=SC2088 # literal-text needle: the message intentionally shows an unexpanded ~ path
assert_contains "e2e: oom carries raise guidance" \
    "~/.config/boxa/resources.conf" "$ctx"
assert_contains "e2e: wording keeps victim a heuristic" \
    "NOT necessarily the command you just ran" "$ctx"
assert_contains "e2e: advises against blind retry" \
    "Do not retry the killed work as-is" "$ctx"
out=$(run_hook)
assert_eq "e2e: same kill is reported exactly once" "" "$out"

printf 'low 0\nhigh 0\nmax 9\noom 3\noom_kill 3\noom_group_kill 0\n' \
    > "$E2E/cgroup/memory.events"
out=$(run_hook)
assert_contains "e2e: batched kills report the count" \
    "2 processes in this project were OOM-killed" "$(context_of "$out")"

# --- counter regression (cgroup recreated) reseeds silently ---
printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\noom_group_kill 0\n' \
    > "$E2E/cgroup/memory.events"
out=$(run_hook)
assert_eq "e2e: counter regression reseeds silently" "" "$out"

# --- unlimited (memory.max = max) disables bands, keeps oom path ---
rm -f "$E2E"/boxa-memory-hook.tester.*.state
printf 'max\n' > "$E2E/cgroup/memory.max"
printf '996147200\n' > "$E2E/cgroup/memory.current"
run_hook > /dev/null                                   # seed
out=$(run_hook)
assert_eq "e2e: no limit -> no band warnings" "" "$out"
printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill 1\noom_group_kill 0\n' \
    > "$E2E/cgroup/memory.events"
out=$(run_hook)
assert_contains "e2e: no limit -> oom still reported" "OOM-killed" \
    "$(context_of "$out")"

# --- host no-op branch ---
out=$(BOXA_MEMHOOK_IDENTITY_FILE="$E2E/no-identity" \
    BOXA_MEMHOOK_CGROUP_DIR="$E2E/cgroup" \
    BOXA_MEMHOOK_STATE="$E2E/state" \
    sh "$HOOK" < /dev/null); rc=$?
assert_eq "e2e: no identity file -> silent" "" "$out"
assert_eq "e2e: no identity file -> exit 0" "0" "$rc"

# ---------------------------------------------------------------------------

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) FAILED\n' "$fail_count"
    exit 1
fi
printf '\nAll tests passed\n'
