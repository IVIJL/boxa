#!/bin/sh
# Signal boxa's host keep-awake daemon; silently no-op when it is unavailable.
# boxa-owned: replaced by boxa on update while this marker is present.
#
# The daemon runs on the host. Inside a Container the Host connection relay
# publishes it on the loopback, but on a WSL2 host under NAT networking the
# daemon is a Windows process reachable only through the default gateway.
# Signal the candidates in that order and stop at the first one that answers —
# the same functional-probe rule the relay itself follows (ADR 0023).
#
# The gateway candidate is confined to a WSL2 host, where it is the Windows
# side. Anywhere else the default gateway is an unrelated machine on the LAN or
# the Container's bridge, so probing it would leak the project name off-box and
# add a timeout to every Claude event for nothing.

action="${1:-busy}"
session="${BOXA_PROJECT_NAME:-default}"
port="${BOXA_KEEP_AWAKE_PORT:-17777}"

# A Stop may arrive while Claude's run_in_background shell is still working.
# Take one process snapshot, find this hook's owning claude ancestor, and keep
# the normal lease while another direct child has the shell-snapshot signature.
# Any missing or malformed process-tree data deliberately leaves Stop as idle.
if [ "$action" = idle ]; then
    ps_command="${BOXA_PS_COMMAND:-ps}"
    processes=$(BOXA_AGENT_AWAKE_HOOK_PID=$$ \
        "$ps_command" -eo pid=,ppid=,comm=,args= 2>/dev/null) || processes=""
    detection=$(printf '%s\n' "$processes" | awk -v hook_pid="$$" '
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
        END {
            if (invalid || !(hook_pid in parent))
                exit 1

            pid = hook_pid
            for (walked = 0; walked <= process_count; walked++) {
                excluded[pid] = 1
                name = command[pid]
                sub(/^.*\//, "", name)
                if (name == "claude") {
                    owner = pid
                    break
                }
                if (!(pid in parent) || parent[pid] == 0 || parent[pid] == pid)
                    exit 1
                pid = parent[pid]
            }
            if (owner == "")
                exit 1

            for (pid in parent) {
                if (parent[pid] == owner && snapshot[pid] && !(pid in excluded)) {
                    print "busy"
                    exit
                }
            }
            print "idle"
        }
    ' 2>/dev/null) || detection=""
    [ "$detection" = busy ] && action=busy
fi

case "$action" in
    idle) path="/v1/idle/claude?session=$session" ;;
    *)    path="/v1/busy/claude?ttl=900&session=$session" ;;
esac

# WSL detection mirrors host_platform::detect: the interop binfmt entry is the
# distro- and kernel-independent signal, with /proc/version only as the fallback
# for older builds. Tests point all three paths at fixtures so both branches stay
# checkable from any machine, matching dns-install.sh's BOXA_WSLCONFIG_FILE.
identity_file="${BOXA_CONTAINER_IDENTITY_FILE:-/etc/boxa/identity.json}"
interop_file="${BOXA_WSL_INTEROP_FILE:-/proc/sys/fs/binfmt_misc/WSLInterop}"
version_file="${BOXA_PROC_VERSION_FILE:-/proc/version}"

gateway=""
if [ ! -f "$identity_file" ] \
    && { [ -e "$interop_file" ] \
        || grep -qiE 'microsoft|wsl' "$version_file" 2>/dev/null; }; then
    gateway=$(ip route show default 2>/dev/null | awk 'NR == 1 { print $3; exit }')
    [ "$gateway" != 127.0.0.1 ] || gateway=""
fi

for address in 127.0.0.1 "$gateway"; do
    [ -n "$address" ] || continue
    if curl -fsS --noproxy '*' -m 1 \
        "http://${address}:${port}${path}" >/dev/null 2>&1; then
        break
    fi
done

exit 0
