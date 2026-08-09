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
