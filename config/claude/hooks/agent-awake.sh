#!/bin/sh
# Signal boxa's host keep-awake daemon; silently no-op when it is unavailable.
# boxa-owned: replaced by boxa on update while this marker is present.
#
# The daemon runs on the host. Inside a Container the Host connection relay
# publishes it on the loopback, but on a WSL2 host under NAT networking the
# daemon is a Windows process reachable only through the default gateway.
# Signal the candidates in that order and stop at the first one that answers.

action="${1:-busy}"
session="${BOXA_PROJECT_NAME:-default}"
port="${BOXA_KEEP_AWAKE_PORT:-17777}"
ttl="${BOXA_AWAKE_TTL:-900}"
state_root="${BOXA_AWAKE_STATE_DIR:-${TMPDIR:-/tmp}/boxa-agent-awake}"
ps_command="${BOXA_PS_COMMAND:-ps}"

process_snapshot() {
    BOXA_AGENT_AWAKE_HOOK_PID=$$ \
        "$ps_command" -eo pid=,ppid=,comm=,args= 2>/dev/null
}

# Inspect one process snapshot. "owner" walks from start_pid to its claude
# ancestor. "snapshot" checks direct snapshot children of owner_pid, excluding
# the chain from start_pid to the owner when one is supplied.
inspect_processes() {
    inspect_mode=$1
    inspect_start=$2
    inspect_owner=$3
    awk -v mode="$inspect_mode" -v start_pid="$inspect_start" \
        -v owner_pid="$inspect_owner" '
        NF {
            if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $1 in parent) {
                invalid = 1
                next
            }
            parent[$1] = $2
            command[$1] = $3
            snapshot[$1] = index($0, "shell-snapshots/snapshot-") != 0
            process_count++
        }
        function command_name(pid, name) {
            name = command[pid]
            sub(/^.*\//, "", name)
            return name
        }
        function find_owner(pid, walked) {
            for (walked = 0; walked <= process_count; walked++) {
                if (!(pid in parent))
                    return ""
                if (command_name(pid) == "claude")
                    return pid
                if (parent[pid] == 0 || parent[pid] == pid)
                    return ""
                pid = parent[pid]
            }
            return ""
        }
        END {
            if (invalid)
                exit 1
            if (mode == "owner") {
                owner = find_owner(start_pid)
                if (owner == "")
                    exit 1
                print owner
                exit
            }
            if (mode != "snapshot" || owner_pid !~ /^[0-9]+$/ \
                    || !(owner_pid in parent))
                exit 1
            if (start_pid != "") {
                pid = start_pid
                for (walked = 0; walked <= process_count; walked++) {
                    if (!(pid in parent))
                        exit 1
                    excluded[pid] = 1
                    if (pid == owner_pid)
                        break
                    if (parent[pid] == 0 || parent[pid] == pid)
                        exit 1
                    pid = parent[pid]
                }
                if (pid != owner_pid)
                    exit 1
            }
            for (pid in parent) {
                if (parent[pid] == owner_pid && snapshot[pid] \
                        && !(pid in excluded)) {
                    print "busy"
                    exit
                }
            }
            print "idle"
        }
    '
}

find_claude_owner() {
    if [ "$#" -gt 0 ]; then
        owner_processes=$1
    else
        owner_processes=$(process_snapshot) || owner_processes=""
    fi
    [ -n "$owner_processes" ] || return 1
    printf '%s\n' "$owner_processes" | inspect_processes owner "$$" ""
}

snapshot_child_state() {
    snapshot_owner=$1
    snapshot_start=${2:-}
    if [ "$#" -gt 2 ]; then
        snapshot_processes=$3
    else
        snapshot_processes=$(process_snapshot) || snapshot_processes=""
    fi
    [ -n "$snapshot_processes" ] || return 1
    printf '%s\n' "$snapshot_processes" \
        | inspect_processes snapshot "$snapshot_start" "$snapshot_owner"
}

append_refresher_log() {
    log_owner=$1
    shift
    log_dir=$(state_directory "$log_owner") || return 0
    mkdir -p "$log_dir" 2>/dev/null || return 0
    log_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || log_time=unknown-time
    printf '%s %s\n' "$log_time" "$*" >> "$log_dir/refresher.log" \
        2>/dev/null || true
}

record_send_transition() {
    transition_owner=$1
    transition_source=$2
    transition_result=$3
    transition_addresses=$4
    [ -n "$transition_owner" ] || return 0
    transition_dir=$(state_directory "$transition_owner") || return 0
    mkdir -p "$transition_dir" 2>/dev/null || return 0
    transition_file="$transition_dir/send-$transition_source.status"
    transition_previous=""
    if [ -r "$transition_file" ]; then
        IFS= read -r transition_previous < "$transition_file" \
            || transition_previous=""
    fi
    if [ "$transition_result" = failure ]; then
        if [ "$transition_previous" = success ]; then
            append_refresher_log "$transition_owner" \
                "send failure after previous success: daemon unreachable src=$transition_source addresses=$transition_addresses"
        elif [ -z "$transition_previous" ]; then
            append_refresher_log "$transition_owner" \
                "initial send failure: daemon unreachable src=$transition_source addresses=$transition_addresses"
        fi
    elif [ "$transition_result" = success ] \
        && [ "$transition_previous" = failure ]; then
        append_refresher_log "$transition_owner" \
            "send recovery after failure src=$transition_source"
    fi
    printf '%s\n' "$transition_result" > "$transition_file" 2>/dev/null || true
}

send_action() {
    send_kind=$1
    send_source=${2:-hook}
    send_owner=${3:-}
    case "$send_kind" in
        idle) send_path="/v1/idle/claude?session=$session" ;;
        *)    send_path="/v1/busy/claude?ttl=$ttl&session=$session&src=$send_source" ;;
    esac

    identity_file="${BOXA_CONTAINER_IDENTITY_FILE:-/etc/boxa/identity.json}"
    interop_file="${BOXA_WSL_INTEROP_FILE:-/proc/sys/fs/binfmt_misc/WSLInterop}"
    version_file="${BOXA_PROC_VERSION_FILE:-/proc/version}"
    gateway=""
    if [ ! -f "$identity_file" ] \
        && { [ -e "$interop_file" ] \
            || grep -qiE 'microsoft|wsl' "$version_file" 2>/dev/null; }; then
        gateway=$(ip route show default 2>/dev/null \
            | awk 'NR == 1 { print $3; exit }')
        [ "$gateway" != 127.0.0.1 ] || gateway=""
    fi

    send_addresses=""
    send_result=failure
    for address in 127.0.0.1 "$gateway"; do
        [ -n "$address" ] || continue
        if [ -n "$send_addresses" ]; then
            send_addresses="$send_addresses,$address"
        else
            send_addresses=$address
        fi
        if curl -fsS --noproxy '*' -m 1 \
            "http://${address}:${port}${send_path}" >/dev/null 2>&1; then
            send_result=success
            break
        fi
    done
    record_send_transition "$send_owner" "$send_source" \
        "$send_result" "$send_addresses"
    [ "$send_result" = success ]
}

state_directory() {
    state_owner=$1
    case "$state_owner" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s/%s\n' "$state_root" "$state_owner"
}

is_our_refresher() {
    refresh_pid=$1
    refresh_owner=$2
    case "$refresh_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$refresh_pid" 2>/dev/null || return 1
    if [ -r "/proc/$refresh_pid/cmdline" ]; then
        refresh_command=$(tr '\000' ' ' \
            < "/proc/$refresh_pid/cmdline" 2>/dev/null) || return 1
    else
        refresh_command=$("$ps_command" -p "$refresh_pid" \
            -o comm= -o args= 2>/dev/null) || return 1
    fi
    case "$refresh_command" in
        *agent-awake.sh*" __refresher $refresh_owner"*) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_refresher() {
    ensure_owner=$1
    kill -0 "$ensure_owner" 2>/dev/null || return 0
    ensure_dir=$(state_directory "$ensure_owner") || return 0
    mkdir -p "$ensure_dir" 2>/dev/null || return 0
    ensure_lock="$ensure_dir/spawn.lock"
    if ! mkdir "$ensure_lock" 2>/dev/null; then
        ensure_lock_owner=""
        if [ -r "$ensure_lock/owner.pid" ]; then
            IFS= read -r ensure_lock_owner < "$ensure_lock/owner.pid" \
                || ensure_lock_owner=""
        fi
        case "$ensure_lock_owner" in
            ''|*[!0-9]*)
                ensure_lock_age=$(find "$ensure_lock" -maxdepth 0 \
                    -mmin +1 -print 2>/dev/null) || return 0
                [ -n "$ensure_lock_age" ] || return 0
                ;;
            *)
                kill -0 "$ensure_lock_owner" 2>/dev/null && return 0
                ;;
        esac
        rm -f "$ensure_lock/owner.pid" 2>/dev/null || return 0
        rmdir "$ensure_lock" 2>/dev/null || return 0
        mkdir "$ensure_lock" 2>/dev/null || return 0
    fi
    printf '%s\n' "$$" > "$ensure_lock/owner.pid" 2>/dev/null || {
        rm -f "$ensure_lock/owner.pid" 2>/dev/null || true
        rmdir "$ensure_lock" 2>/dev/null || true
        return 0
    }

    ensure_pid=""
    if [ -r "$ensure_dir/refresher.pid" ]; then
        IFS= read -r ensure_pid < "$ensure_dir/refresher.pid" || ensure_pid=""
    fi
    if is_our_refresher "$ensure_pid" "$ensure_owner"; then
        rm -f "$ensure_lock/owner.pid"
        rmdir "$ensure_lock" 2>/dev/null || true
        return 0
    fi
    rm -f "$ensure_dir/refresher.pid"
    if command -v setsid >/dev/null 2>&1; then
        setsid "$0" __refresher "$ensure_owner" </dev/null >/dev/null 2>&1 &
    else
        "$0" __refresher "$ensure_owner" </dev/null >/dev/null 2>&1 &
    fi
    printf '%s\n' "$!" > "$ensure_dir/refresher.pid"
    rm -f "$ensure_lock/owner.pid"
    rmdir "$ensure_lock" 2>/dev/null || true
}

stop_refresher() {
    stop_owner=$1
    stop_dir=$(state_directory "$stop_owner") || return 0
    stop_pid=""
    if [ -r "$stop_dir/refresher.pid" ]; then
        IFS= read -r stop_pid < "$stop_dir/refresher.pid" || stop_pid=""
    fi
    if is_our_refresher "$stop_pid" "$stop_owner"; then
        kill -- "-$stop_pid" 2>/dev/null \
            || kill "$stop_pid" 2>/dev/null \
            || true
    fi
    rm -f "$stop_dir/refresher.pid"
}

write_state() {
    write_owner=$1
    write_value=$2
    write_dir=$(state_directory "$write_owner") || return 0
    mkdir -p "$write_dir" 2>/dev/null || return 0
    printf '%s\n' "$write_value" > "$write_dir/state" 2>/dev/null || true
}

run_refresher() {
    refresher_owner=$1
    refresher_dir=$(state_directory "$refresher_owner") || return 0
    # Must stay below the daemon's default idle grace so another Claude
    # process cannot let a shared project holder expire between refreshes.
    refresh_interval="${BOXA_AWAKE_REFRESH_INTERVAL:-90}"
    refresher_source="refresher-$refresher_owner"
    refresher_exit_reason=state-idle
    append_refresher_log "$refresher_owner" \
        "refresher start owner=$refresher_owner pid=$$ interval=$refresh_interval"

    # ShellCheck parses traps out of runtime order and misses this assignment.
    # shellcheck disable=SC2154
    trap 'cleanup_pid=""; if [ -r "$refresher_dir/refresher.pid" ]; then
        IFS= read -r cleanup_pid < "$refresher_dir/refresher.pid" \
            || cleanup_pid=""; fi
        if [ "$cleanup_pid" = "$$" ]; then
            rm -f "$refresher_dir/refresher.pid"; fi
        append_refresher_log "$refresher_owner" \
            "refresher exit owner=$refresher_owner pid=$$ reason=$refresher_exit_reason"' EXIT
    trap 'exit 0' HUP INT TERM

    while :; do
        sleep "$refresh_interval" || return 0
        if ! kill -0 "$refresher_owner" 2>/dev/null; then
            refresher_exit_reason="owner-dead"
            return 0
        fi
        refresher_state=""
        if [ -r "$refresher_dir/state" ]; then
            IFS= read -r refresher_state < "$refresher_dir/state" \
                || refresher_state=""
        fi
        case "$refresher_state" in
            busy)
                # Re-read immediately before sending to narrow the Stop race.
                IFS= read -r refresher_state < "$refresher_dir/state" \
                    2>/dev/null || refresher_state=""
                [ "$refresher_state" = busy ] || continue
                send_action busy "$refresher_source" "$refresher_owner" || true
                ;;
            shell)
                shell_state=$(snapshot_child_state "$refresher_owner") \
                    || shell_state=""
                case "$shell_state" in
                    busy)
                        IFS= read -r refresher_state < "$refresher_dir/state" \
                            2>/dev/null || refresher_state=""
                        [ "$refresher_state" = shell ] || continue
                        send_action busy "$refresher_source" \
                            "$refresher_owner" || true
                        ;;
                    idle)
                        IFS= read -r refresher_state < "$refresher_dir/state" \
                            2>/dev/null || refresher_state=""
                        [ "$refresher_state" = shell ] || continue
                        write_state "$refresher_owner" idle
                        send_action idle "$refresher_source" \
                            "$refresher_owner" || true
                        refresher_exit_reason="shell-gone"
                        return 0
                        ;;
                    *) continue ;;
                esac
                ;;
            *)
                refresher_exit_reason=state-idle
                return 0
                ;;
        esac
    done
}

if [ "$action" = __refresher ]; then
    run_refresher "${2:-}"
    exit 0
fi

hook_processes=$(process_snapshot) || hook_processes=""
owner=$(find_claude_owner "$hook_processes") || owner=""
case "$action" in
    idle)
        detection=""
        if [ -n "$owner" ]; then
            detection=$(snapshot_child_state "$owner" "$$" "$hook_processes") \
                || detection=""
        fi
        if [ "$detection" = busy ]; then
            write_state "$owner" shell
            ensure_refresher "$owner"
            send_action busy hook "$owner" || true
        else
            if [ -n "$owner" ]; then
                write_state "$owner" idle
                stop_refresher "$owner"
            fi
            send_action idle hook "$owner" || true
        fi
        ;;
    *)
        send_action busy hook "$owner" || true
        if [ -n "$owner" ]; then
            write_state "$owner" busy
            ensure_refresher "$owner"
        fi
        ;;
esac

exit 0
