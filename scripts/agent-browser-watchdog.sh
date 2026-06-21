#!/bin/bash
# Agent-browser Chrome watchdog (ADR 0010).
#
# Polls Chrome's PID on a fixed interval. When Chrome exits (developer
# closed the window, OOM, crash), invokes broker `stop` for graceful
# cleanup of proxy / relay / firewall slot / state file. Without this
# the broker keeps thinking the session is alive — `boxa agent-browser
# status` reports Chrome PID with `(dead)` but proxy/relay keep running
# and the next `start` would have to wait for the user to notice.
#
# Spawned detached by broker cmd_start; killed by cmd_stop as the first
# teardown step except when stop is itself invoked by this watchdog
# (BOXA_AGENT_BROWSER_FROM_WATCHDOG=1) — that re-entry guard avoids
# self-suicide before the exec lands.
#
# Args:
#   $1  container name (forwarded to `broker stop`)
#   $2  Chrome PID to monitor
#   $3  absolute path to agent-browser-broker.sh
#   $4  absolute path to a writable pidfile this script will self-record
#       its own PID into (cmd_start polls it back to populate the state
#       file, avoiding pgrep races against the spawn wrapper)
#
# Env:
#   BOXA_AGENT_BROWSER_WATCHDOG_INTERVAL  poll interval in seconds
#                                           (default 10; tests set to 1)
#
# Runs as the invoking developer (NOT boxa-agent), so `exec broker stop`
# resolves SESSIONS_DIR / state file paths against the developer's
# XDG_STATE_HOME — the same paths cmd_start wrote into. Process liveness
# checks for Chrome go through ps/proc which work cross-user.

set -u

container="${1:?usage: agent-browser-watchdog.sh <container> <chrome_pid> <broker_path> <pidfile>}"
chrome_pid="${2:?missing chrome_pid arg}"
broker="${3:?missing broker path arg}"
pidfile="${4:?missing pidfile arg}"

# Self-record PID first thing so the broker's spawn caller can pick it
# up without racing pgrep. Best-effort: a write failure leaves cmd_start
# without a watchdog_pid record — manual `stop` still works (just no
# explicit watchdog teardown step in cmd_stop, which is harmless because
# this script exits on its own when Chrome dies).
printf '%s\n' "$$" > "$pidfile" 2>/dev/null || true

interval="${BOXA_AGENT_BROWSER_WATCHDOG_INTERVAL:-10}"
case "$interval" in
    ''|*[!0-9]*) interval=10 ;;
esac
[ "$interval" -ge 1 ] || interval=10

[ -x "$broker" ] || {
    printf '[watchdog] broker not executable: %s\n' "$broker" >&2
    exit 2
}

# Mirror broker's _pid_alive_on_host: existence check that works for
# boxa-agent-owned PIDs from this script's invoker (kill -0 returns
# EPERM cross-user even when the process is alive; ps -p / /proc/<pid>
# bypass that).
_pid_alive() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    if ps -p "$pid" >/dev/null 2>&1; then
        return 0
    fi
    [ -d "/proc/$pid" ]
}

while _pid_alive "$chrome_pid"; do
    sleep "$interval"
done

printf '[watchdog] Chrome PID %s exited; invoking broker stop for %s\n' \
    "$chrome_pid" "$container"

# Re-entry guard: cmd_stop's watchdog-kill step is a no-op when this
# env is set so it doesn't target the script's own PID. exec keeps the
# session-ending log lineage attached to this PID.
exec env BOXA_AGENT_BROWSER_FROM_WATCHDOG=1 \
    "$broker" stop "$container"
