#!/bin/bash
set -euo pipefail

# =============================================================================
# agent-browser-broker — host-side Agent-browser session lifecycle (ADR 0010)
# =============================================================================
# Single dispatcher for `boxa agent-browser {start,stop,status}`. Holds the
# Chrome process (Host agent Chrome, ADR 0010 § Actor 1) and the in-container
# socat bridge (ADR 0010 § Actor 2) on each side of an Agent-browser session.
#
# Subcommands:
#
#   start <container>   Sweep any stale session file, then launch Chrome as
#                       `boxa-agent` on a free host loopback port, start
#                       socat inside the named container forwarding
#                       127.0.0.1:9222 -> host.docker.internal:<host-port>,
#                       and persist the session-state JSON.
#   stop <container>    Read the state JSON, kill Chrome, kill the
#                       in-container bridge, remove the state file. Safe to
#                       re-run when the state file is missing.
#   status <container>  Print the active session details (PIDs, ports,
#                       profile dir, created_at) in a readable form.
#
# Slice 02 scope:
#   - lifecycle skeleton only — no Chrome hardening flags (slice 03), no
#     forward proxy (slice 04+), no netlog archival, no toast notifications.
#
# Why this file lives in scripts/ and not lib/: per ADR 0010 References,
# `scripts/agent-browser-broker.sh` is the canonical multi-subcommand
# dispatcher; lib/ holds reusable sourced modules, scripts/ holds
# executable host-side entry points.
# =============================================================================

BOXA_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

# shellcheck source-path=SCRIPTDIR source=../lib/host-platform.sh disable=SC1091
source "$BOXA_DIR/lib/host-platform.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/picker.sh disable=SC1091
source "$BOXA_DIR/lib/picker.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/allowlist.sh disable=SC1091
source "$BOXA_DIR/lib/allowlist.sh"

# --- Constants ---------------------------------------------------------------

# Session state JSON lives under XDG state — survives reboots, lets us
# reconcile after a container stop or a host crash on the next `start`.
SESSIONS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/boxa/agent-browser/sessions"

# Ephemeral Chrome profiles + downloads live under a boxa-agent-owned
# parent so the OS-identity boundary covers them too (ADR 0010 § Actor 1).
# /var/lib is the FHS-canonical location for service-owned mutable state;
# the parent dirs are created (with sudo, once) on first `start`.
AGENT_PROFILES_DIR="/var/lib/boxa-agent/profiles"
AGENT_DOWNLOADS_DIR="/var/lib/boxa-agent/downloads"

# Netlog archive dir on the host. Populated at `stop` time when the live
# netlog (under the ephemeral profile dir) is moved here for forensics.
# Owned by boxa-agent; the local developer reads via group membership
# (ADR 0010 § "Tamper-proof property"). The same dir holds the archived
# proxy-decision JSONL (slice 04 onwards).
AGENT_NETLOG_ARCHIVE_DIR="/var/log/boxa/agent-browser"

# Retention cap: how many session triples (.proxy.log + .netlog.json +
# .summary.md sharing a `<container>-<ISO>` prefix) we keep per container
# in the archive. Older ones are pruned at the start of each new session
# so a long-running agent that re-opens sessions does not grow the dir
# unbounded. Per-container so cleanup in one project does not stomp on
# another. Override via env when forensics need more headroom.
AGENT_ARCHIVE_KEEP_PER_CONTAINER="${BOXA_AGENT_ARCHIVE_KEEP_PER_CONTAINER:-10}"

# Per-user agent-browser state root. The proxy daemon's active-mode file
# lives here. The proxy itself runs as boxa-agent and reads files via
# that OS identity, so paths must be reachable for that user (see
# `_stage_allowlist` below for the allowlist-specific handling).
AGENT_USER_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/boxa/agent-browser"
AGENT_PROXY_STATE_DIR="${AGENT_USER_STATE_DIR}/proxy"
AGENT_PROXY_MODE_FILE="${AGENT_PROXY_STATE_DIR}/active-mode"

# Host-user-owned hand-off dir for agent-browser toast events (slice 08).
# Lives under XDG_STATE so no install-time provisioning is needed and the
# broker (running as the developer) can write without sudo. The matching
# deliver-allow-for-notification.sh sweeps this dir alongside the
# allow-for one. Kept separate so the deliver script can apply
# event-type-specific reconstruction rules without disturbing the
# allow-for path.
AGENT_PENDING_DIR="${AGENT_USER_STATE_DIR}/pending"

# Path to the notification deliver script. Best-effort spawn on each
# event emit — failure to dispatch never blocks the broker's stop or
# window-close paths.
AGENT_DELIVER_BIN="${BOXA_DIR}/scripts/deliver-allow-for-notification.sh"

# Upper bound on `allow-for <minutes>`. 1440 = 24h matches the spirit
# of the firewall `allow-for` cap (which has no explicit cap; this is
# defence-in-depth against a typo opening a multi-day window).
AGENT_ALLOW_FOR_MAX_MINUTES=1440

# The user-facing allowlist. The proxy never reads this path directly —
# on hosts where $HOME or ~/.config is 0700, boxa-agent can't traverse
# into it. Instead, `_stage_allowlist` snapshots this file into the
# session-scoped profile dir (boxa-agent-owned) at session start, and
# the proxy is pointed at the snapshot. Hot-reload of the user's edits
# is still possible through `boxa agent-browser allow-for` (slice 05),
# which will re-stage the snapshot and SIGHUP the proxy. For slice 04
# the user edits + restarts the session, which is acceptable because
# the user has no way yet to flip the mode at runtime anyway.
AGENT_ALLOWLIST_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/boxa/agent-browser-allowed-domains.conf"

# Bypass list applied on the Chrome side. Chrome routes these direct and
# the proxy never sees the requests. The set mirrors boxa's dev URL
# scheme (ADR 0007 + the wildcard rules in user CLAUDE.md).
AGENT_PROXY_BYPASS_LIST="127.0.0.1;localhost;*.test;*.127.0.0.1.sslip.io"

# Path to the proxy daemon. install.sh stages a root-owned copy under
# /usr/local/lib/boxa/agent-browser/ so the boxa-agent user can exec
# it regardless of the developer's $HOME perms (0700/0750 homes block
# traversal into the repo checkout). Override via env var for development
# against an unstaged checkout.
AGENT_HELPERS_STAGE_DIR="/usr/local/lib/boxa/agent-browser"
AGENT_PROXY_BIN="${BOXA_AGENT_PROXY_BIN:-${AGENT_HELPERS_STAGE_DIR}/agent-browser-proxy.py}"

# Path to the summary generator. Same staging rationale as AGENT_PROXY_BIN.
AGENT_SUMMARIZE_BIN="${BOXA_AGENT_SUMMARIZE_BIN:-${AGENT_HELPERS_STAGE_DIR}/agent-browser-summarize.py}"

# Chrome-death watchdog (poll Chrome PID; on exit, invoke broker stop).
# Lives next to the broker in the same scripts/ dir; we point at the
# repo copy because the broker itself runs from the same dir (BOXA_DIR
# resolved above via readlink -f on $0). The broker-self path is what
# the watchdog re-invokes with `stop`.
AGENT_WATCHDOG_SCRIPT="${BOXA_DIR}/scripts/agent-browser-watchdog.sh"
AGENT_BROKER_SELF="${BOXA_DIR}/scripts/agent-browser-broker.sh"
AGENT_WATCHDOG_INTERVAL_DEFAULT=10

# Container-side CDP endpoint exposed by the bridge socat. Stable so the
# agent-browser CLI always sees the same URL regardless of which random
# host port Chrome chose this session. ADR 0010 § Actor 2.
BRIDGE_CONTAINER_PORT="9222"

# --- Logging -----------------------------------------------------------------

_log()  { printf '%s\n' "$*"; }
_warn() { printf '%s\n' "$*" >&2; }
_die()  { _warn "agent-browser: $*"; exit 1; }

# --- Argument helpers --------------------------------------------------------

_usage() {
    cat <<'EOF'
Usage:
  agent-browser-broker.sh start      <container>
  agent-browser-broker.sh stop       <container>
  agent-browser-broker.sh status     <container>
  agent-browser-broker.sh open       <container> <url> [<url>...]
  agent-browser-broker.sh allow-for  <minutes> <container>
  agent-browser-broker.sh allow-for  --stop    <container>
  agent-browser-broker.sh allow      [<domain>]
  agent-browser-broker.sh deny       <domain>
  agent-browser-broker.sh blocked    [<container> | --from-cwd <container>]

Allowlist edits write to ~/.config/boxa/agent-browser-allowed-domains.conf
and SIGHUP every live agent-browser proxy. Unlike the firewall allowlist,
an entry matches ONLY the literal host — quote a glob for subdomains
(e.g. '*.example.com').

`allow <domain>` auto-pairs the apex↔www counterpart (qr.cz → also adds
www.qr.cz, and vice versa) to cover the common HSTS / 301-to-www case.
`deny` is symmetric — it removes the counterpart too.
EOF
}

# Require a name that looks like a boxa container; the broker doesn't
# resolve project-name -> container-name (that's `boxa agent-browser`
# dispatch). We just validate the input shape and check Docker.
#
# Charset enforcement mirrors Docker's own `[a-zA-Z0-9][a-zA-Z0-9_.-]*`
# regex. It's defence-in-depth: the container name flows into derived
# paths (profile dir, archive filename) and into the state-file name,
# so even though Docker would reject `../foo` upstream we still refuse
# anything we'd be embarrassed to expand into a filesystem path.
_require_container_arg() {
    local container="${1:-}"
    [ -n "$container" ] || { _usage >&2; exit 2; }
    case "$container" in
        [a-zA-Z0-9]*) ;;
        *) _die "Invalid container name '${container}': must start with [a-zA-Z0-9]." ;;
    esac
    case "$container" in
        *[!a-zA-Z0-9._-]*) _die "Invalid container name '${container}': only [a-zA-Z0-9._-] allowed." ;;
    esac
    printf '%s\n' "$container"
}

_container_running() {
    docker ps --filter "name=^${1}$" --format '{{.Names}}' | grep -q .
}

_container_exists() {
    docker ps -a --filter "name=^${1}$" --format '{{.Names}}' | grep -q .
}

# --- Missing-session picker --------------------------------------------------

# Offer an interactive picker over OTHER live sessions when the caller's
# token does not resolve to a state file (typical cause: history-completion
# or a typo against a co-resident project that does have a session).
#
# Behaviour:
#   - Silent return 1 when stdin or stderr is not a TTY (preserves script
#     and hook semantics — callers see the original error / no-op path).
#   - Silent return 1 when no sibling session exists.
#   - On TTY with at least one sibling: prints a one-line header to stderr,
#     pipes the session list into picker::one (fzf or numbered fallback),
#     prints the chosen container on stdout and returns 0. Esc/q/empty
#     returns 1 so the caller can fall through to its existing error or
#     idempotent-no-op message.
#
# Explicit-token semantics are preserved: this never silently rewrites the
# caller's argument. The user must confirm by selecting an entry.
_offer_session_picker() {
    local missing_token="$1"
    [ -t 0 ] || return 1
    [ -t 2 ] || return 1
    [ -d "$SESSIONS_DIR" ] || return 1
    local -a others=()
    local f base
    shopt -s nullglob
    for f in "$SESSIONS_DIR"/*.json; do
        base="$(basename "$f" .json)"
        [ "$base" = "$missing_token" ] && continue
        others+=("$base")
    done
    shopt -u nullglob
    [ "${#others[@]}" -gt 0 ] || return 1
    local header
    header="agent-browser: no session for ${missing_token}. Pick another (Esc/q cancels)."
    local chosen
    chosen="$(printf '%s\n' "${others[@]}" \
        | picker::one --prompt "switch to> " --header "$header")" \
        || return 1
    [ -n "$chosen" ] || return 1
    printf '%s\n' "$chosen"
}

# --- Session state -----------------------------------------------------------

_state_file() {
    printf '%s/%s.json\n' "$SESSIONS_DIR" "$1"
}

# Read a top-level scalar from the state JSON. Uses jq if available
# (preferred), falls back to a regex-based grep so the broker remains
# functional on minimal hosts where jq is missing — the dependency is
# documented in ADR 0010 but not yet enforced by install.sh.
_state_get() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k] // empty' "$file"
        return 0
    fi
    # Fallback: parse "key": <value> for string, number, boolean, or null.
    # Numbers/booleans/null come without quotes, strings come quoted. The
    # boolean shape (`true`/`false`) is needed for the `ufw_retry_only` marker
    # so the display-consumer predicate reads the same value with or without jq.
    grep -oE "\"$key\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+|true|false|null)" "$file" \
        | head -1 \
        | sed -E "s/^\"$key\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"$//"
}

_iso_utc_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Add N minutes to "now" and emit an ISO-8601 UTC timestamp. Used to
# compute the network window's `expires_at`. `date -u -d "+Nmin"` is
# GNU coreutils; macOS `date` uses `-v +Nm`. Both shapes are tried so
# the broker stays portable to macOS hosts (ADR 0010 cross-platform
# parity).
_iso_plus_minutes_utc() {
    local minutes="$1"
    local out=""
    out="$(date -u -d "+${minutes} minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"
    if [ -z "$out" ]; then
        out="$(date -u -v "+${minutes}M" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"
    fi
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# Render an ISO-8601 UTC timestamp in the user's local timezone in
# `HH:MM:SS` form. Used for the human-facing confirmation lines. Best-
# effort — on a `date` that can't parse the input, falls back to the
# original UTC string so the message still carries useful information.
_local_hms() {
    local iso="$1" out=""
    out="$(date -d "$iso" +"%H:%M:%S" 2>/dev/null || true)"
    if [ -z "$out" ]; then
        out="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +"%H:%M:%S" 2>/dev/null || true)"
    fi
    [ -n "$out" ] || out="$iso"
    printf '%s\n' "$out"
}

# --- Free-port discovery -----------------------------------------------------

# Bind a TCP socket to port 0 and read back the kernel's assignment. Python3
# is in the boxa host install set (mkcert, dns-install both use it), so
# this is safe; the alternative `bash + /dev/tcp` cannot ask the kernel to
# pick a free port, only test specific ones.
_pick_free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

_windows_primary_work_area() {
    # The single-quoted body is a PowerShell script; `$wa`/`$($wa.X)` are
    # PowerShell variables that bash must NOT expand — single quotes are
    # deliberate, so SC2016 is a false positive here.
    # shellcheck disable=SC2016
    powershell.exe -NoProfile -Command '
Add-Type -AssemblyName System.Windows.Forms
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
"$($wa.X) $($wa.Y) $($wa.Width) $($wa.Height)"
' 2>/dev/null | tr -d '\r' | tail -1
}

_fit_chrome_window_to_work_area() {
    local cdp_port="$1" work_area="$2" bottom_margin="${AGENT_BROWSER_WSLG_WORKAREA_MARGIN:-24}"
    [ -n "$cdp_port" ] && [ -n "$work_area" ] || return 1

    python3 - "$cdp_port" "$work_area" "$bottom_margin" <<'PY'
import base64
import http.client
import json
import os
import socket
import struct
import sys


def http_get(port, path):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    conn.request("GET", path)
    resp = conn.getresponse()
    body = resp.read().decode("utf-8")
    conn.close()
    return json.loads(body)


def ws_connect(url):
    rest = url[len("ws://") :]
    host_port, path = rest.split("/", 1)
    host, port_s = host_port.split(":")
    port = int(port_s)
    sock = socket.create_connection((host, port), timeout=3)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    req = (
        f"GET /{path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(req.encode("ascii"))
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("websocket handshake aborted")
        buf += chunk
    if b"101" not in buf.split(b"\r\n", 1)[0]:
        raise RuntimeError("websocket handshake refused")
    return sock


def ws_send(sock, payload):
    data = payload.encode("utf-8")
    header = bytearray([0x81])
    mask = os.urandom(4)
    if len(data) < 126:
        header.append(0x80 | len(data))
    elif len(data) < 65536:
        header.append(0x80 | 126)
        header += struct.pack(">H", len(data))
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", len(data))
    header += mask
    sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def ws_recv(sock):
    def must(n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("websocket closed")
            buf += chunk
        return buf

    while True:
        b0, b1 = must(2)
        opcode = b0 & 0x0F
        plen = b1 & 0x7F
        if plen == 126:
            (plen,) = struct.unpack(">H", must(2))
        elif plen == 127:
            (plen,) = struct.unpack(">Q", must(8))
        mask = must(4) if (b1 & 0x80) else None
        data = must(plen)
        if mask:
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        if opcode == 0x1:
            return data.decode("utf-8")
        if opcode == 0x8:
            raise RuntimeError("websocket closed by remote")


def main():
    port = int(sys.argv[1])
    wa_x, wa_y, wa_w, wa_h = [int(part) for part in sys.argv[2].split()]
    margin = max(0, int(sys.argv[3]))
    work_bottom = wa_y + wa_h

    version = http_get(port, "/json/version")
    targets = http_get(port, "/json")
    page = next((t for t in targets if t.get("type") == "page"), None)
    if page is None:
        print("no page target", file=sys.stderr)
        return 2

    sock = ws_connect(version["webSocketDebuggerUrl"])
    next_id = 0

    def call(method, params=None):
        nonlocal next_id
        next_id += 1
        msg = {"id": next_id, "method": method}
        if params is not None:
            msg["params"] = params
        ws_send(sock, json.dumps(msg))
        while True:
            resp = json.loads(ws_recv(sock))
            if resp.get("id") == next_id:
                if "error" in resp:
                    raise RuntimeError(resp["error"])
                return resp.get("result", {})

    window_id = call("Browser.getWindowForTarget", {"targetId": page["id"]})["windowId"]
    bounds = call("Browser.getWindowBounds", {"windowId": window_id})["bounds"]
    if bounds.get("windowState") not in (None, "normal"):
        print(f"unchanged state={bounds.get('windowState')}")
        return 0

    left = int(bounds.get("left", wa_x))
    top = int(bounds.get("top", wa_y))
    width = int(bounds.get("width", min(1280, wa_w)))
    height = int(bounds.get("height", min(900, wa_h)))

    new_top = max(top, wa_y)
    max_height = work_bottom - new_top - margin
    if max_height < 480:
        print(f"unchanged bounds={bounds} work_area={sys.argv[2]}")
        return 0

    new_height = min(height, max_height)
    if new_top == top and new_height == height and top + height <= work_bottom - margin:
        print(f"unchanged bounds={bounds} work_area={sys.argv[2]}")
        return 0

    new_bounds = {
        "left": left,
        "top": new_top,
        "width": width,
        "height": new_height,
        "windowState": "normal",
    }
    call("Browser.setWindowBounds", {"windowId": window_id, "bounds": new_bounds})
    print(f"adjusted from={bounds} to={new_bounds} work_area={sys.argv[2]} margin={margin}")


if __name__ == "__main__":
    main()
PY
}

# --- Detach helper -----------------------------------------------------------

# Echo the literal command used to detach a child from the broker's session.
# `setsid` is the strongest detach (new session + SIGHUP ignored) but is
# Linux-only; macOS lacks it. `nohup` alone covers the SIGHUP case, which
# is the only signal the broker's shell exit would otherwise raise on the
# child. Used as a prefix in front of the actual command.
_detach_prefix() {
    if command -v setsid >/dev/null 2>&1; then
        printf 'setsid\n'
    else
        printf 'nohup\n'
    fi
}

# --- Process liveness --------------------------------------------------------

_pid_alive_on_host() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 1
    # `kill -0` returns 0 only if the caller may signal that PID — for
    # boxa-agent-owned processes from the user's shell this returns
    # EPERM (rc=1) even though the process is alive. `ps -p` checks
    # existence without permission to signal and is portable across
    # Linux and macOS. /proc/<pid> is the Linux-only third fallback,
    # useful if `ps` is missing in a minimal environment.
    if ps -p "$pid" >/dev/null 2>&1; then
        return 0
    fi
    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    [ -d "/proc/$pid" ]
}

# Read the START TIME of a host PID — field 22 (`starttime`, in clock ticks
# since boot) of `/proc/<pid>/stat` (#12 review P2). Used as a PID-reuse-safe
# IDENTITY for the cmd_start broker process recorded in a starting-claim: a
# reused PID (after a crash/reboot the kernel may hand the same number to an
# unrelated process) has a DIFFERENT start time, so comparing the recorded
# starttime against the live one distinguishes "the original broker is still
# running" from "the PID was recycled". Field 22 is robust to a process name
# containing spaces/parentheses because we split on the LAST ')' — everything
# after the comm field is space-separated and parenthesis-free. Echoes the
# starttime, or empty when /proc is unreadable (caller falls back to bare
# liveness). `$$`/the current process is read as `/proc/$$/stat`.
_pid_starttime_on_host() {
    local pid="${1:-}"
    [ -n "$pid" ] || { printf '%s\n' ""; return 0; }
    [ -r "/proc/$pid/stat" ] || { printf '%s\n' ""; return 0; }
    local stat_line rest
    read -r stat_line < "/proc/$pid/stat" 2>/dev/null || { printf '%s\n' ""; return 0; }
    # Everything after the last ')' (the comm field's close paren) is the
    # space-separated remainder; field 3 there is `state`, so starttime is the
    # 20th token after the paren (fields 3..22 → index 20).
    rest="${stat_line##*) }"
    # shellcheck disable=SC2086
    set -- $rest
    # $1=state(field3) ... starttime is field 22 → the 20th positional here.
    printf '%s\n' "${20:-}"
}

# Decide whether a recorded starting-claim broker PID is STILL the SAME live
# process that wrote the claim (#12 review P2). Shared by the display-consumer
# predicate and `_sweep_if_stale`'s refuse-to-sweep guard so both stay
# consistent. Returns 0 (live + same identity) iff the PID is alive AND, when a
# recorded start time is supplied, the live process's `/proc/<pid>/stat`
# starttime equals it. A PID that is alive but whose starttime DIFFERS is a
# REUSED pid → returns 1 (the claim is abandoned/sweepable, not a live
# consumer). When the recorded starttime is empty (an older claim written before
# this field existed) it falls back to bare liveness — backward compatible.
_starting_pid_is_live() {
    local pid="${1:-}" recorded_starttime="${2:-}"
    [ -n "$pid" ] && [ "$pid" != "null" ] || return 1
    _pid_alive_on_host "$pid" || return 1
    # No recorded identity (old claim) → bare liveness is all we can do.
    [ -n "$recorded_starttime" ] && [ "$recorded_starttime" != "null" ] || return 0
    local live_starttime
    live_starttime="$(_pid_starttime_on_host "$pid")"
    # /proc unreadable for this PID → cannot disprove identity; keep the prior
    # conservative behaviour (treat the live PID as ours) rather than expiring a
    # genuinely in-progress start we cannot evaluate.
    [ -n "$live_starttime" ] || return 0
    [ "$live_starttime" = "$recorded_starttime" ]
}

# `_pid_alive_on_host` only checks existence — but PIDs are reused after
# reboot. For session-state liveness checks we additionally need to know
# the PID still belongs to the same agent-browser process we launched.
# Match against the unique --user-data-dir (Chrome) or the bind-address +
# port pair (relay) embedded in the original cmdline. Returns 0 only when
# the PID is alive AND its cmdline contains the marker.
_pid_matches_marker() {
    local pid="${1:-}" marker="${2:-}"
    [ -n "$pid" ] || return 1
    [ -n "$marker" ] || return 1
    _pid_alive_on_host "$pid" || return 1

    # /proc cmdline is NUL-separated; tr to space for grep. ps fallback
    # covers macOS where /proc doesn't exist; `ps -p` here may be limited
    # to the caller's processes for non-owned PIDs, but for our sweep
    # purposes "we can't read it" is treated as "could be ours, refuse
    # to sweep" — fail-safe.
    if [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null \
            | grep -qF -- "$marker" \
            && return 0
        return 1
    fi
    local cmdline
    cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [ -n "$cmdline" ] || return 0
    printf '%s' "$cmdline" | grep -qF -- "$marker"
}

_pid_alive_in_container() {
    local container="$1" pid="${2:-}"
    [ -n "$pid" ] || return 1
    docker exec "$container" sh -c "[ -d /proc/$pid ]" 2>/dev/null
}

# Like _pid_matches_marker but the PID lives inside the named container.
# Used to discriminate a live bridge socat from a recycled PID across
# container restarts (PIDs reset to small values inside a fresh container).
_pid_matches_marker_in_container() {
    local container="$1" pid="${2:-}" marker="${3:-}"
    [ -n "$pid" ] || return 1
    [ -n "$marker" ] || return 1
    docker exec "$container" sh -c "
        [ -r /proc/$pid/cmdline ] || exit 1
        tr '\0' ' ' < /proc/$pid/cmdline | grep -qF -- \"\$1\"
    " _ "$marker" 2>/dev/null
}

# Kill the in-container bridge socat. The single reuse point for the
# `docker exec <container> kill <pid>` teardown that cmd_stop / the stale-session
# sweep already use — the failed-start cleanup (finding: clean up the bridge on
# a failed/aborted start) MUST call THIS, not invent a second mechanism, so the
# bridge is never orphaned bound to 127.0.0.1:9222 inside the container with no
# state to reclaim it from.
#
# No-ops when the bridge PID is unset/null (the bridge was never started — e.g.
# an abort before the `docker exec -d socat` ran) and when the container has
# already vanished. A `docker exec` failure because the container is gone is
# WARNED, never fatal: the cleanup that calls this must complete the rest of its
# teardown regardless (no silent failure, no aborted cleanup). Best-effort kill:
# `kill` of an already-dead/reused PID inside the container is a harmless no-op.
_kill_bridge_in_container() {
    local container="$1" bridge_pid="${2:-}"
    # The cmdline substring unique to our bridge socat — the same marker the
    # sweep and cmd_stop compute (`socat TCP-LISTEN:<port>`). Optional third arg
    # lets a caller pass it explicitly; default to the standard constant so the
    # pattern lives in one place and every caller of this shared helper gets the
    # identity guard for free.
    local bridge_marker="${3:-socat TCP-LISTEN:${BRIDGE_CONTAINER_PORT}}"
    [ -n "$container" ] || return 0
    [ -n "$bridge_pid" ] && [ "$bridge_pid" != "null" ] || return 0
    # Container already gone — nothing to kill, and `docker exec` would error.
    # That is the expected case when the start aborted because the container
    # died; warn so it is never a silent skip, then return cleanly.
    if ! _container_running "$container"; then
        _warn "agent-browser: container ${container} is no longer running; skipping in-container bridge (PID ${bridge_pid}) kill (nothing to reclaim)."
        return 0
    fi
    # PID-identity guard before signalling (#12/#14 review finding 3): if the
    # container RESTARTED after this bridge PID was recorded, `_container_running`
    # passes against the NEW container and a bare `kill` could terminate an
    # UNRELATED process that reused that small PID inside the fresh container.
    # Confirm the PID still belongs to OUR socat bridge (the `_pid_matches_marker`
    # discipline already applied to host PIDs, here in-container) before killing;
    # on a mismatch the original bridge is already gone with the old container —
    # SKIP the kill and warn rather than signal a stranger.
    if ! _pid_matches_marker_in_container "$container" "$bridge_pid" "$bridge_marker"; then
        _warn "agent-browser: in-container bridge PID ${bridge_pid} in ${container} no longer matches our socat (PID reused or container restarted); skipping kill (the original bridge is already gone)."
        return 0
    fi
    _log "Stopping in-container bridge PID ${bridge_pid} in ${container}..."
    docker exec "$container" kill "$bridge_pid" 2>/dev/null \
        || _warn "agent-browser: could not kill in-container bridge PID ${bridge_pid} in ${container} (already exited, reused, or the container vanished mid-teardown)."
}

# --- UFW / host firewall slot ------------------------------------------------
#
# Mirror of the container-side OUT-side slot (ADR 0010 § "Container-side
# firewall slot"), but on the HOST INPUT side. On a native-Linux host with
# ufw active and default-deny INPUT, the in-container socat bridge's SYN to
# the host-side CDP relay (host.docker.internal:<cdp_port>, served by the
# socat relay bound on the bridge gateway IP) arrives on the custom Docker
# bridge interface (`br-<hash>`, NOT docker0) and is dropped before any
# user rule. The CDP smoke test then times out and the broker rolls back.
#
# The previous behaviour was to only WARN and tell the developer to add a
# broad durable `ufw allow from <subnet>` by hand — which leaves every host
# port open to the whole bridge subnet, permanently, far looser than the
# container-side exception. Issue 14 replaces that with an automatic,
# minimal, EPHEMERAL slot: scoped to the relay's exact destination IP and
# TCP port, from the container's actual bridge subnet, opened on start and
# closed on stop and on every rollback path.

# Whether ufw is installed AND active on this host. Detection uses the ufw
# binary itself (`ufw status`) rather than grepping /etc/ufw/ufw.conf so we
# observe the live enabled/disabled state, not the persisted config flag.
# `ufw status` needs root to read the kernel state, so it goes through sudo;
# the broker already uses sudo elsewhere (profile dirs, kill). Returns 0
# only when both `command -v ufw` succeeds and status reports "Status:
# active". Any other case (not installed, inactive, sudo refused) returns 1
# so the slot path is a clean no-op.
_host_ufw_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    # Force LC_ALL=C: on hosts with a localized ufw, `Status: active` may be
    # translated, so an active default-deny firewall would be misread as
    # inactive and the slot never opened (CDP smoke test then fails with no
    # fallback hint). The C locale pins the English string we grep for.
    LC_ALL=C sudo ufw status 2>/dev/null | grep -qi '^Status: active'
}

# Test whether an IPv4 address falls inside a CIDR (finding 2). Pure-bash
# bit arithmetic — no ipcalc/python dependency. Used to map the container's
# route-source IP to the Docker network whose IPAM subnet actually carries
# the traffic to the relay. Returns 0 when $ip is inside $cidr, 1 otherwise
# (including malformed input).
_ipv4_in_cidr() {
    local ip="$1" cidr="$2"
    [ -n "$ip" ] && [ -n "$cidr" ] || return 1
    local net_addr prefix
    net_addr="${cidr%/*}"
    prefix="${cidr#*/}"
    case "$cidr" in *"/"*) ;; *) return 1 ;; esac
    [ "$prefix" -ge 0 ] 2>/dev/null && [ "$prefix" -le 32 ] 2>/dev/null || return 1
    # Pack a dotted-quad into a 32-bit integer; reject anything non-numeric.
    _ipv4_to_int() {
        local a b c d IFS=.
        read -r a b c d <<<"$1"
        for o in "$a" "$b" "$c" "$d"; do
            [ -n "$o" ] && [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] 2>/dev/null || return 1
        done
        printf '%s\n' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
    }
    local ip_int net_int
    ip_int="$(_ipv4_to_int "$ip")" || return 1
    net_int="$(_ipv4_to_int "$net_addr")" || return 1
    # /0 means "match everything"; left-shifting a 32-bit value by 32 is UB
    # in C but bash gives 0, so special-case it for a correct all-ones mask.
    local mask
    if [ "$prefix" -eq 0 ]; then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    [ "$(( ip_int & mask ))" -eq "$(( net_int & mask ))" ]
}

# --- ufw selector validators (defence-in-depth, ADR 0010) --------------------
#
# Every value that flows into a privileged `sudo ufw allow`/`sudo ufw delete`
# selector — relay IP (`to <ip>`), CDP port (`port <n>`), bridge subnet
# (`from <cidr>`) — is read from the session-state JSON under
# ~/.local/state/boxa/agent-browser/sessions/<container>.json, which is
# developer-writable. The open/close helpers below validate these selectors
# at the single privileged chokepoint per direction BEFORE handing them to
# root's ufw, mirroring the discipline the container-side host-allow helper
# already applies (`start-agent-browser-host-allow.sh` rejects anything that
# is not a dotted IPv4 + a 1..65535 port before touching iptables; ADR 0010
# "the helper validates dotted IPv4").
#
# Residual-threat note (honest, not overclaimed): this is NOT a trust
# boundary against the container. The session JSON is a purely host-side
# artefact with NO bind mount into the container, so no in-container process
# can reach it; a host user who can write it already holds sudo and could
# run `ufw` directly. Validation here is therefore defence-in-depth plus
# injection/typo safety on a root-privileged command path, consistent with
# the container-side IPv4-validation precedent — it does not pretend to fence
# off a privileged host user.

# Strict dotted-IPv4: four decimal octets, each 0-255, no extra characters.
# Mirrors the regex+range check in start-agent-browser-host-allow.sh so the
# host ufw path applies the same rigor as the container-side helper.
_is_ipv4() {
    local ip="${1:-}"
    [[ "$ip" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    local IFS=. o
    local -a octets
    read -ra octets <<<"$ip"
    for o in "${octets[@]}"; do
        # Range 0-255 …
        [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] 2>/dev/null || return 1
        # … AND reject leading-zero / overlong shapes ("08", "010"): a single
        # "0" is fine, but any multi-digit octet beginning with 0 is ambiguous
        # (octal-looking) and must not reach the privileged ufw selector.
        case "$o" in
            0) ;;
            0*) return 1 ;;
        esac
    done
    return 0
}

# Strict TCP port: integer 1..65535, no leading zeros, no surrounding/embedded
# whitespace or extra characters. `^[1-9][0-9]*$` rejects "0", "08", "22; x".
_is_tcp_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[1-9][0-9]*$ ]] || return 1
    [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null
}

# Strict IPv4 CIDR: dotted-IPv4 base + `/` + prefix 0-32, nothing else.
_is_ipv4_cidr() {
    local cidr="${1:-}"
    case "$cidr" in *"/"*) ;; *) return 1 ;; esac
    local base="${cidr%/*}" prefix="${cidr#*/}"
    _is_ipv4 "$base" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    [ "$prefix" -ge 0 ] 2>/dev/null && [ "$prefix" -le 32 ] 2>/dev/null
}

# Derive the container's real bridge subnet (CIDR) for the ufw slot — the
# subnet the container actually uses to REACH the relay IP, not merely the
# first Docker network it happens to report (finding 2). A container on a
# single network (the common devproxy case) resolves exactly as before; a
# multi-homed container would otherwise get a ufw rule scoped to the wrong
# source subnet, so default-deny ufw still drops the real CDP SYN and the
# session rolls back.
#
# Derivation:
#   1. Ask the container, via `ip route get <relay_ip>`, which source IP it
#      uses to reach the relay (the `src <addr>` field).
#   2. Enumerate the container's Docker networks; pick the one whose IPAM
#      subnet CONTAINS that source IP and echo that subnet.
# If the route lookup fails (no `ip` in the image, unexpected output) or no
# network's subnet contains the src, fall back to the previous first-network
# behaviour WITH a visible warning — never a silent change, and the feature
# keeps working (just possibly the wider/old guess). Echoes the CIDR
# (e.g. 172.18.0.0/16) on success, nothing on failure.
#
# Args:
#   $1 container  the target container name/id
#   $2 relay_ip   the relay IP this session resolved (host_allow_ip); the
#                 route is computed toward THIS address. Optional — when
#                 empty we go straight to the first-network fallback.
_container_bridge_subnet() {
    local container="$1" relay_ip="$2"
    [ -n "$container" ] || return 1

    # Enumerate the container's networks once: "<net_name> <subnet>" lines,
    # one per IPAM subnet. Reused by both the route-match path and the
    # first-network fallback below.
    local nets
    nets="$(docker inspect "$container" \
        --format '{{range $n, $c := .NetworkSettings.Networks}}{{$n}}{{"\n"}}{{end}}' \
        2>/dev/null)"
    [ -n "$nets" ] || return 1

    # Resolve a network name to its first IPAM subnet CIDR.
    _net_subnet() {
        docker network inspect "$1" \
            --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9].*\//) {print $i; exit}}'
    }

    # First-network subnet — the legacy behaviour and the fallback target.
    local first_net first_subnet=""
    first_net="$(printf '%s\n' "$nets" | head -n1)"
    [ -n "$first_net" ] && first_subnet="$(_net_subnet "$first_net")"

    # Route-based selection: only attempted when we have a relay IP to route
    # toward. `ip -o route get <ip>` prints a single line containing
    # `... src <container_src_ip> ...`; extract that src.
    if [ -n "$relay_ip" ]; then
        local route_out route_src=""
        route_out="$(docker exec "$container" \
            ip -o route get "$relay_ip" 2>/dev/null || true)"
        if [ -n "$route_out" ]; then
            route_src="$(printf '%s\n' "$route_out" \
                | sed -n 's/.*[[:space:]]src[[:space:]]\+\([0-9.]\+\).*/\1/p' \
                | head -n1)"
        fi
        if [ -n "$route_src" ]; then
            # Pick the network whose IPAM subnet contains the route src.
            local net_name net_subnet
            while IFS= read -r net_name; do
                [ -n "$net_name" ] || continue
                net_subnet="$(_net_subnet "$net_name")"
                [ -n "$net_subnet" ] || continue
                if _ipv4_in_cidr "$route_src" "$net_subnet"; then
                    printf '%s\n' "$net_subnet"
                    return 0
                fi
            done <<EOF
$nets
EOF
            _warn "ufw slot: route to ${relay_ip} uses src ${route_src}, but no Docker network subnet for ${container} contains it; falling back to the first network (${first_subnet:-unknown})."
        else
            _warn "ufw slot: could not determine the container's route source to ${relay_ip} (no 'ip route get' output); falling back to the first network (${first_subnet:-unknown})."
        fi
    fi

    # Fallback: first-network subnet (legacy single-network behaviour).
    [ -n "$first_subnet" ] || return 1
    printf '%s\n' "$first_subnet"
}

# Open a session-scoped ufw/INPUT slot for the CDP relay. The slot is as
# narrow as the container-side exception: a single destination IP + single
# TCP port, scoped to the container's actual bridge subnet:
#
#   sudo ufw allow proto tcp from <subnet> to <relay-ip> port <cdp_port>
#
# This is NOT a blanket `ufw allow from <subnet>` (which would open every
# host port). Arguments:
#   $1 relay_ip   the exact destination the relay binds (= host_allow_ip,
#                 i.e. whatever host.docker.internal resolves to)
#   $2 cdp_port   the per-session CDP host port (cdp_port_host)
#   $3 subnet     the container's real bridge subnet (CIDR)
#
# `ufw allow` is idempotent — re-adding an identical rule is a no-op — so a
# crashed prior session that left the slot open does not accumulate
# duplicates. But idempotence cuts both ways: if an administrator had ALREADY
# configured this exact scoped rule by hand, `ufw allow` succeeds with
# "Skipping adding existing rule" and we must NOT later delete it on stop —
# the session did not create it. We therefore distinguish "newly added" from
# "already existed" via ufw's own output:
#   - "Rule added" / "Rules updated"     -> ufw created the rule  -> rc 0
#   - "Skipping adding existing rule"     -> pre-existing admin rule -> rc 2
# so the caller persists the deletion slot ONLY when WE added it. Returns:
#   0  rule newly added by this session (persist + delete on stop)
#   2  identical rule already existed (leave it alone; do NOT persist)
#   1  the `ufw allow` failed (surfaced by the caller for the manual hint)
_open_host_ufw_slot() {
    local relay_ip="$1" cdp_port="$2" subnet="$3"
    [ -n "$relay_ip" ] && [ -n "$cdp_port" ] && [ -n "$subnet" ] || return 1
    # OPEN chokepoint: refuse to hand a state-derived (developer-writable)
    # selector to root's `ufw allow` unless it strictly validates. A garbage
    # IP/port/subnet must never reach the privileged command. On failure we
    # name the offending field and return 1 ("could not open"), so the caller
    # shows the manual fallback hint instead of silently proceeding.
    if ! _is_ipv4 "$relay_ip"; then
        _warn "ufw slot: refusing to open — malformed relay IP '${relay_ip}' (expected dotted IPv4)."
        return 1
    fi
    if ! _is_tcp_port "$cdp_port"; then
        _warn "ufw slot: refusing to open — malformed CDP port '${cdp_port}' (expected 1..65535)."
        return 1
    fi
    if ! _is_ipv4_cidr "$subnet"; then
        _warn "ufw slot: refusing to open — malformed bridge subnet '${subnet}' (expected IPv4 CIDR)."
        return 1
    fi
    local ufw_out
    # Force LC_ALL=C: the "Rule added" / "Rules updated" / "Skipping adding
    # existing rule" markers parsed below are localized on some hosts, so a
    # translated build would misclassify a newly-added rule as pre-existing
    # (or vice versa). The C locale pins the English strings we grep for.
    ufw_out="$(LC_ALL=C sudo ufw allow proto tcp from "$subnet" to "$relay_ip" port "$cdp_port" 2>&1)" \
        || return 1
    # ufw emits "Skipping adding existing rule" (and no "Rule added"/"Rules
    # updated") when the identical rule was already present. Treat that as
    # "pre-existing" so the caller does not schedule it for deletion.
    if printf '%s' "$ufw_out" | grep -qi 'Skipping adding existing rule'; then
        return 2
    fi
    return 0
}

# Close the session-scoped ufw/INPUT slot opened by _open_host_ufw_slot.
# `ufw delete allow ...` with the exact same selector removes the matching
# rule. Same argument shape as the open helper. The caller persists relay
# IP, port, and subnet in the session-state JSON so the exact rule can be
# deleted later.
#
# Return contract (so cmd_stop can decide whether to RETAIN retryable
# state — finding 1):
#   0  the rule was deleted OR was already absent (nothing left to reclaim)
#   1  the delete genuinely FAILED — typically a no-TTY `sudo` that can no
#      longer authenticate (the detached Chrome watchdog path), so the
#      durable ACCEPT rule survives and must be retried on the next start.
# A "missing rule" (idempotent re-close, or the container/host restarted) is
# NOT a failure: ufw prints "Could not delete non-existent rule" — we map
# that to 0 so a benign re-close never trips the retain-state path. When no
# selector was passed or ufw is absent there is nothing to close (return 0).
_close_host_ufw_slot() {
    local relay_ip="$1" cdp_port="$2" subnet="$3"
    [ -n "$relay_ip" ] && [ -n "$cdp_port" ] && [ -n "$subnet" ] || return 0
    command -v ufw >/dev/null 2>&1 || return 0
    # CLOSE/DELETE chokepoint: a state-derived (developer-writable) selector
    # reaches root's `ufw delete` here. If it does not strictly validate we
    # must NOT delete — a tampered/corrupt selector could otherwise match and
    # remove an arbitrary administrator ufw rule. Treat an invalid selector as
    # "cannot safely release": name the malformed field and return 1 so the
    # caller (per the retain-on-failure design) RETAINS the state file for a
    # human to inspect rather than silently dropping it. We never run the
    # privileged delete with an unvalidated selector.
    if ! _is_ipv4 "$relay_ip"; then
        _warn "ufw slot: refusing to delete — malformed relay IP '${relay_ip}' in session state (expected dotted IPv4); cannot safely release."
        return 1
    fi
    if ! _is_tcp_port "$cdp_port"; then
        _warn "ufw slot: refusing to delete — malformed CDP port '${cdp_port}' in session state (expected 1..65535); cannot safely release."
        return 1
    fi
    if ! _is_ipv4_cidr "$subnet"; then
        _warn "ufw slot: refusing to delete — malformed bridge subnet '${subnet}' in session state (expected IPv4 CIDR); cannot safely release."
        return 1
    fi
    local del_out del_rc=0
    # LC_ALL=C pins the "Could not delete non-existent rule" marker we test
    # for below, mirroring the locale handling in _host_ufw_active / _open.
    del_out="$(LC_ALL=C sudo ufw delete allow proto tcp from "$subnet" to "$relay_ip" port "$cdp_port" 2>&1)" \
        || del_rc=$?
    [ "$del_rc" -eq 0 ] && return 0
    # Treat "rule already gone" as success — an idempotent re-close, not a
    # leaked rule. Any other non-zero rc (no-TTY sudo, ufw error) is a real
    # failure the caller must surface and retry.
    if printf '%s' "$del_out" | grep -qi 'Could not delete non-existent rule'; then
        return 0
    fi
    return 1
}

# Release a broker-OWNED host ufw slot, deciding whether the caller may drop
# the session-state file (finding 2). Shared by the three teardown paths —
# cmd_stop, the stale-session sweep, and cmd_start's bridge-rollback branches —
# so all three handle a failed `sudo ufw delete` identically: keep the state
# file (carrying ufw_slot_subnet + relay IP + port) so a later start can retry,
# never NOPASSWD around the failure (ADR 0003).
#
# Args: relay_ip, cdp_port, subnet (the persisted slot triple).
# Return contract:
#   0  nothing to retain — either no broker-owned slot was recorded (empty /
#      null subnet/ip/port: admin-owned or never added) OR the delete
#      succeeded. The caller may remove the state/marker file.
#   1  a broker-owned slot's delete genuinely FAILED (no-TTY sudo, ufw error).
#      The caller MUST retain the file so the next start's sweep retries; this
#      helper has already printed the standard visible warning.
_release_or_retain_ufw_slot() {
    local relay_ip="$1" cdp_port="$2" subnet="$3"
    # No broker-owned slot recorded → nothing to release, nothing to retain.
    [ -n "$subnet" ] && [ "$subnet" != "null" ] \
        && [ -n "$relay_ip" ] && [ "$relay_ip" != "null" ] \
        && [ -n "$cdp_port" ] && [ "$cdp_port" != "null" ] \
        || return 0
    _log "Releasing host ufw slot for ${relay_ip}:${cdp_port} (from ${subnet})..."
    if _close_host_ufw_slot "$relay_ip" "$cdp_port" "$subnet"; then
        return 0
    fi
    _warn "Could not release the host ufw slot for ${relay_ip}:${cdp_port} (from ${subnet})."
    _warn "  This usually means sudo could not authenticate (e.g. the watchdog or rollback ran after your sudo timestamp expired)."
    _warn "  Retaining the session state so the next 'boxa agent-browser start' sweep can retry the ufw delete."
    _warn "  To release it now: sudo ufw delete allow proto tcp from ${subnet} to ${relay_ip} port ${cdp_port}"
    return 1
}

# Promote the crash-window marker's PENDING ufw slot to OWNED once
# `_open_host_ufw_slot` confirmed ufw actually ADDED the rule (rc 0)
# (finding 1). The marker is written BEFORE `ufw allow` with the subnet in
# `ufw_slot_pending_subnet` and a null `ufw_slot_subnet`, so a crash in the
# narrow window between the marker write and the add can NEVER make the
# sweep delete a rule whose origin is still unknown (it would, at worst, be
# an admin-owned pre-existing rule). Only here — after ufw confirmed WE added
# it — do we move the subnet into the deletable `ufw_slot_subnet` field and
# drop the pending marker, so stop/sweep/rollback will reclaim it. The
# deletion paths key off `ufw_slot_subnet` ONLY; the pending field is never
# deletable. Best-effort: the full state write at the end of cmd_start
# overwrites the marker on the success path.
_promote_ufw_marker_slot() {
    local file="$1" subnet="$2"
    [ -n "$file" ] && [ -f "$file" ] && [ -n "$subnet" ] || return 0
    # Set the owned subnet and null the pending field. The marker is broker-
    # written with exactly one `"ufw_slot_subnet": null` and one
    # `"ufw_slot_pending_subnet": "<subnet>"` line, so scoped seds on those
    # exact keys suffice and avoid a jq dependency.
    # `|` delimiter, not `/`: the subnet replacement contains a slash
    # (e.g. 172.20.0.0/16) which would close a `s/.../.../` expression.
    sed -i -E \
        -e "s|(\"ufw_slot_subnet\"[[:space:]]*:[[:space:]]*)null|\\1\"${subnet}\"|" \
        -e 's|("ufw_slot_pending_subnet"[[:space:]]*:[[:space:]]*)"[^"]*"|\1null|' \
        "$file" 2>/dev/null || true
}

# Drop the crash-window marker's PENDING ufw slot WITHOUT promoting it to
# owned (finding 1). Called when the rule turned out to be admin-owned
# (rc 2) or the add failed (rc 1): in those cases THIS session does not own
# a deletable rule, so the pending claim is cleared and `ufw_slot_subnet`
# stays null — a crash after this point can never make the sweep delete a
# rule we did not create. host_allow_ip and cdp_port_host are left intact so
# the sweep can still release the container-side OUTPUT slot opened earlier.
_clear_ufw_marker_pending() {
    local file="$1"
    [ -n "$file" ] && [ -f "$file" ] || return 0
    sed -i -E 's/("ufw_slot_pending_subnet"[[:space:]]*:[[:space:]]*)"[^"]*"/\1null/' "$file" 2>/dev/null || true
}

# Mark a RETAINED state file as Chrome-torn-down / ufw-retry-only (finding 1).
# A state file kept past cmd_stop ONLY so the next start's sweep can retry a
# failed `sudo ufw delete` no longer has a live Chrome — Chrome was killed and
# its profile removed earlier in cmd_stop. Without this marker, OTHER sessions'
# X-revoke reference count (`_count_other_live_sessions` →
# `_state_file_is_display_consumer`) would still treat the file as a live
# display consumer and never revoke the shared grant, leaving boxa-agent
# authorized on the display indefinitely.
#
# We null chrome_pid + proxy_pid (the processes are dead) and add an explicit
# `ufw_retry_only: true` marker. The retry-only flag is what
# `_state_file_is_display_consumer` keys off, so the file is excluded from the
# display-consumer count yet KEEPS the ufw_slot_subnet / host_allow_ip /
# cdp_port_host fields the sweep needs to finish the delete. Rewritten in place
# (`cat >`, never unlink+recreate) so a bind-mounted file keeps its inode.
# Best-effort: a write failure leaves the file un-marked (it would still be
# swept correctly later — the count would just be conservative, never unsafe in
# the revoke direction since the sweep re-reads PIDs).
_mark_state_file_ufw_retry_only() {
    local file="$1"
    [ -n "$file" ] && [ -f "$file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        local tmp
        tmp="$(jq '.chrome_pid = null | .proxy_pid = null | .ufw_retry_only = true' \
            "$file" 2>/dev/null)" || return 0
        [ -n "$tmp" ] || return 0
        printf '%s\n' "$tmp" > "$file" 2>/dev/null || true
        return 0
    fi
    # jq-less fallback: scoped seds on the exact key shapes the broker writes.
    # Null the two PID fields; append the retry-only marker before the closing
    # brace if it is not already present.
    sed -i -E \
        -e 's/("chrome_pid"[[:space:]]*:[[:space:]]*)[0-9]+/\1null/' \
        -e 's/("proxy_pid"[[:space:]]*:[[:space:]]*)[0-9]+/\1null/' \
        "$file" 2>/dev/null || true
    if ! grep -q '"ufw_retry_only"' "$file" 2>/dev/null; then
        # Insert `"ufw_retry_only": true,` after the opening brace so the JSON
        # stays valid regardless of the trailing field's comma placement.
        sed -i -E '0,/^\{/s/^\{/{\n  "ufw_retry_only": true,/' "$file" 2>/dev/null || true
    fi
}

# Fallback hint shown ONLY when the automatic scoped slot could not be
# created (ufw active but the `ufw allow` failed, e.g. sudo refused or the
# subnet could not be derived). Replaces the previous always-on broad
# durable warning — it is now a last resort, and we still recommend the
# narrow scoped form rather than the blanket `ufw allow from <subnet>`.
_warn_ufw_slot_fallback() {
    local container="$1" relay_ip="$2" cdp_port="$3" subnet="$4"
    _warn ""
    _warn "  Host firewall (ufw) is active and the automatic CDP slot could not be opened."
    _warn "  The container's bridge is NOT docker0, so 'ufw allow in on docker0' is a no-op."
    if [ -n "$relay_ip" ] && [ -n "$cdp_port" ] && [ -n "$subnet" ]; then
        _warn "  Open a scoped, temporary rule by hand (then 'ufw delete ...' the same line to close it):"
        _warn "    sudo ufw allow proto tcp from ${subnet} to ${relay_ip} port ${cdp_port}"
    else
        _warn "  Could not auto-detect the relay IP / bridge subnet. Find the subnet with:"
        _warn "    docker inspect ${container} --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}/{{.IPPrefixLen}} {{end}}'"
        _warn "  Then on host (scoped to the CDP relay IP+port — avoid a blanket subnet allow):"
        _warn "    sudo ufw allow proto tcp from <subnet> to <relay-ip> port <cdp_port>"
    fi
}

# --- Session-dir cleanup -----------------------------------------------------

# Reject any path that doesn't sit directly under one of the agent-owned
# parents we manage. The session-state JSON lives under the developer's
# home dir and so is writable by the developer; without this guard, a
# corrupted or tampered state file could direct the subsequent `sudo rm`
# calls at any path.
#
# Acceptance rules:
#   - must start with the expected parent + exactly one basename
#     (single component, no nested subdirs)
#   - must not equal the parent itself
#   - basename charset restricted to [A-Za-z0-9._-] (matches our
#     `<container>-<ts>` build pattern)
#   - basename must not be `.` or `..` (traversal anchors)
#   - if a third arg `session_prefix` is given, the basename must
#     start with that exact string — used to bind cleanup to the
#     currently-named container, so a tampered state JSON can't
#     redirect rm/mv at a sibling session under the same parent.
#
# The full-path `..` substring check used in earlier drafts was
# overzealous: Docker names like `foo..bar` produce legitimate paths
# such as `/var/lib/boxa-agent/profiles/foo..bar-20260519T120000Z`
# that contain `..` but are not traversal attempts. Doing the check
# on the extracted basename after the single-component constraint
# already rules out real traversal.
_is_managed_path() {
    local path="${1:-}" parent="${2:-}" session_prefix="${3:-}"
    [ -n "$path" ] || return 1
    [ -n "$parent" ] || return 1
    [ "$path" != "$parent" ] || return 1
    local prefix="${parent%/}/"
    case "$path" in
        "$prefix"*) ;;
        *) return 1 ;;
    esac
    local basename="${path#"$prefix"}"
    [ -n "$basename" ] || return 1
    case "$basename" in
        */*) return 1 ;;
    esac
    [ "$basename" != "." ] || return 1
    [ "$basename" != ".." ] || return 1
    case "$basename" in
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    if [ -n "$session_prefix" ]; then
        case "$basename" in
            "$session_prefix"*) ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

# Remove the per-session profile and download dirs. Used by `cmd_start`'s
# early-failure rollback paths (before the state JSON is written, so the
# stale-session sweep on the next `start` has nothing to anchor on) and
# anywhere else that needs to scrub the dirs without going through `stop`.
# `session_prefix` (third arg, typically `${container}-`) binds the rm
# to the currently-named session — a tampered state JSON cannot direct
# the sudo rm at a sibling session's dir under the same parent.
# Existence is checked through `sudo test` because the 0700 parents block
# the developer from stat'ing into the boxa-agent-owned tree.
_cleanup_session_dirs() {
    local profile_dir="${1:-}" download_dir="${2:-}" session_prefix="${3:-}"
    if [ -n "$profile_dir" ] \
        && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "$session_prefix" \
        && sudo test -d "$profile_dir"; then
        sudo rm -rf -- "$profile_dir" || _warn "Failed to remove profile dir ${profile_dir}."
    fi
    if [ -n "$download_dir" ] \
        && _is_managed_path "$download_dir" "$AGENT_DOWNLOADS_DIR" "$session_prefix" \
        && sudo test -d "$download_dir"; then
        sudo rm -rf -- "$download_dir" || _warn "Failed to remove download dir ${download_dir}."
    fi
}

# --- Launch-failure log surfacing --------------------------------------------

# Surface a failed agent process's captured stderr AND stdout to the
# developer's terminal (issue 11 — "no silent failures"). The logs live
# under the 0700 boxa-agent-owned profile dir, so the developer can't
# read them directly; we route through `sudo cat`.
#
# CRITICAL ORDERING: callers MUST invoke this BEFORE `_cleanup_session_dirs`
# (or any other path that removes the profile dir). The original breakage
# was a race where rollback deleted the profile dir before the captured
# error reached the terminal, leaving a bare `stderr:` with nothing after
# it.
#
# Chrome (and the proxy) sometimes write the fatal line to stdout rather
# than stderr, so we surface both streams, each labelled, and only when
# non-empty. When BOTH captured streams are genuinely empty we print an
# actionable hint. Reads happen via `sudo cat` into a variable so the
# emptiness test sees the real content, not a swallowed pipe exit status.
#
# The empty-logs hint differs by process kind ($1 == "Chrome" gets the
# display/X-authorization hint, since the overwhelmingly common cause of a
# silent Chrome exit is the agent user lacking display access — `$DISPLAY`/
# `$WAYLAND_DISPLAY` unset for the launch, or no X authorization for the
# boxa-agent uid; see issue 12). Other processes get a generic pointer to
# raise the verbosity, because a display hint would mislead there.
#
# Args:
#   $1 what          human label for the failed process ("Chrome", "proxy")
#   $2 profile_dir   the 0700 dir holding <prefix>.stderr.log / .stdout.log
#   $3 stderr_log    absolute path to the captured stderr log
#   $4 stdout_log    absolute path to the captured stdout log
#   $5 launch_log    (optional) developer-readable wrapper launch log. The
#                    detached launches redirect the OUTER wrapper's stdout+stderr
#                    here (stdin stays detached via `</dev/null`), so a failure
#                    of `sudo`/`setsid`/`sh` BEFORE the daemon's inner redirects
#                    take effect — expired sudo creds, a policy rejection, a
#                    missing `setsid` — is captured instead of discarded. When
#                    this holds content the process never ran, so we surface it
#                    and SKIP the display hint (which would mislead). The file
#                    lives in the developer-owned SESSIONS_DIR (the redirect is
#                    applied by the broker's own shell, before `sudo`), so it is
#                    read directly, not via `sudo cat`.
_surface_launch_logs() {
    local what="$1" profile_dir="$2" stderr_log="$3" stdout_log="$4" launch_log="${5:-}"
    : "$profile_dir"  # documented for callers; reads go via the explicit paths
    local stderr_body="" stdout_body="" launch_body=""

    stderr_body="$(sudo cat "$stderr_log" 2>/dev/null || true)"
    stdout_body="$(sudo cat "$stdout_log" 2>/dev/null || true)"
    [ -n "$launch_log" ] && launch_body="$(cat "$launch_log" 2>/dev/null || true)"

    if [ -n "$stderr_body" ]; then
        _warn "${what} failed to start. stderr:"
        printf '%s\n' "$stderr_body" | sed 's/^/  /' >&2
    fi
    if [ -n "$stdout_body" ]; then
        _warn "${what} failed to start. stdout:"
        printf '%s\n' "$stdout_body" | sed 's/^/  /' >&2
    fi
    if [ -n "$launch_body" ]; then
        _warn "${what} failed to launch (sudo/setsid/sh error before the process started):"
        printf '%s\n' "$launch_body" | sed 's/^/  /' >&2
    fi

    if [ -n "$stderr_body" ] || [ -n "$stdout_body" ] || [ -n "$launch_body" ]; then
        return 0
    fi

    _warn "${what} failed to start, but captured no stderr/stdout output."
    if [ "$what" = "Chrome" ]; then
        _warn "  Most common cause: the agent user lacks display access."
        _warn "  Check that a display is reachable for the boxa-agent uid:"
        _warn "    - \$DISPLAY / \$WAYLAND_DISPLAY must be set for the launch."
        _warn "    - boxa-agent needs X authorization (its own xauth cookie,"
        _warn "      or 'xhost +SI:localuser:boxa-agent') — see issue 12."
        _warn "  Current developer environment: DISPLAY='${DISPLAY:-}' WAYLAND_DISPLAY='${WAYLAND_DISPLAY:-}'."
    else
        _warn "  Re-run with more verbosity or inspect ${stderr_log} as root to diagnose."
    fi
}

# --- X display grant ---------------------------------------------------------

# Host-side lockfile serializing the X-grant critical sections (#12 review
# finding 1). The shared `xhost +SI:localuser:boxa-agent` grant is per-uid
# AND per-display and is reference-counted across concurrent sessions: writing
# the early starting-claim before granting does NOT by itself close the
# check-to-revoke race, because a teardown can compute `others==0`, THEN a
# concurrent start writes its claim and grants, THEN the teardown revokes — out
# from under the new session. We close that race by running BOTH critical
# sections under one shared exclusive lock:
#   - START side: { write starting-claim + ownership check + `xhost +SI` grant }
#   - TEARDOWN side: { count other consumers + decide + `xhost -SI` revoke +
#                      clear the ownership marker }
# With both mutually exclusive, a teardown either SEES the new claim
# (others>=1 → no revoke) or completes its revoke BEFORE the new start grants
# (the new start then re-grants under the lock — correct).
XHOST_GRANT_LOCKFILE="${SESSIONS_DIR}/.xhost-grant.lock"

# Run a command (function name + args) under the exclusive X-grant lock. The
# critical region MUST stay small — only the claim-write, the xhost ownership
# query, and the single xhost call belong inside it; no Chrome launch and no
# `docker exec`. `flock` lives in util-linux and is virtually always present on
# Linux, but we degrade gracefully if it is missing: warn ONCE and fall back to
# running the section lock-free (the pre-finding-1 behaviour) rather than
# failing — a teardown must never hard-crash because flock is absent.
#
# Lock acquisition + release are scoped to a subshell: fd 9 is opened on the
# lockfile, `flock -x 9` blocks until the lock is held, the section runs, and
# the subshell exit (any path — normal, `_die`, signal) closes fd 9 and so
# RELEASES the lock. We never hold the lock across the subshell boundary, so
# there is no leak on `_die`/trap. The lockfile is created (best-effort) under
# the developer-owned sessions dir; a failure to create it also falls back to
# the lock-free path.
_XHOST_FLOCK_WARNED=0
_with_xhost_grant_lock() {
    # No flock available, or the lockfile cannot be created → run lock-free with
    # a one-time visible warning. flock is in util-linux; this is the rare
    # minimal-host case, not an error worth aborting teardown over.
    if ! command -v flock >/dev/null 2>&1; then
        if [ "$_XHOST_FLOCK_WARNED" = 0 ]; then
            _warn "agent-browser: 'flock' not found; X-grant critical sections run UNSERIALIZED (a concurrent start/stop race on the shared display grant is possible). Install util-linux to close it."
            _XHOST_FLOCK_WARNED=1
        fi
        "$@"
        return $?
    fi
    mkdir -p "$SESSIONS_DIR" 2>/dev/null || true
    if ! { : >> "$XHOST_GRANT_LOCKFILE"; } 2>/dev/null; then
        if [ "$_XHOST_FLOCK_WARNED" = 0 ]; then
            _warn "agent-browser: cannot create X-grant lockfile ${XHOST_GRANT_LOCKFILE}; X-grant critical sections run UNSERIALIZED."
            _XHOST_FLOCK_WARNED=1
        fi
        "$@"
        return $?
    fi
    # Subshell-scoped fd 9: flock holds the lock for the lifetime of fd 9, which
    # the subshell closes on ANY exit path — releasing the lock without an
    # explicit unlock and without leaking it on `_die`/signal. The critical
    # section's own exit status is propagated out of the subshell (a grant
    # failure inside it `_die`s → the subshell exits non-zero → the caller sees
    # it and rolls back). If `flock` itself errors (rare — fd 9 is a valid open
    # file), we DELIBERATELY still run the section rather than silently skipping
    # it, warning that it ran unserialized: skipping the claim+grant or the
    # revoke would be worse than running it without the lock.
    (
        flock -x 9 \
            || _warn "agent-browser: could not acquire the X-grant lock; running this critical section UNSERIALIZED."
        "$@"
    ) 9>>"$XHOST_GRANT_LOCKFILE"
}

# The OWN-HOSTNAME probe (#12 review). A DISPLAY whose host part is THIS
# machine's own name (e.g. `myhost:0`) denotes the SAME local X server as `:0`
# — unlike a genuinely foreign hostname, which is a DIFFERENT machine's server.
# We therefore treat the own hostname as a "local-ish" alias. `hostname` may be
# unavailable (returns non-zero / empty) in a stripped environment; we handle
# that by simply not matching (the value then falls through to the foreign-host
# branch, the conservative no-collapse choice). Compared case-insensitively
# since DNS/hostnames are case-insensitive.
_display_host_is_own_hostname() {
    local host="${1:-}"
    [ -n "$host" ] || return 1
    local own=""
    own="$(hostname 2>/dev/null || true)"
    [ -z "$own" ] && [ -n "${HOSTNAME:-}" ] && own="$HOSTNAME"
    [ -n "$own" ] || return 1
    [ "${host,,}" = "${own,,}" ]
}

# Decide whether a DISPLAY RESOLVES TO THE LOCAL X SERVER on display N — i.e. the
# bare `:N` server reachable via the `/tmp/.X11-unix/X<n>` socket (#12 review).
# This is the single SERVER-IDENTITY probe shared by `_canonical_display` (which
# collapses same-server aliases to the bare `:N` key) and `_x_session_token`
# (which derives an instance identity from that socket), so the two never
# diverge.
#
# The xhost ACL is SERVER-WIDE: `:0` (Unix socket) and `localhost:0` (TCP) that
# reach the SAME X server share ONE authorization, so for refcount + ownership
# they must collapse to one key. The discriminator is the LOCAL X SOCKET
# EXISTENCE:
#   - The host part must be LOCAL-ISH — one of: empty (`:N`), `unix` (`unix:N`),
#     `localhost`, or THIS machine's own hostname. A FOREIGN hostname is a
#     DIFFERENT machine's X server and never resolves here, regardless of any
#     local socket.
#   - AND the local socket `/tmp/.X11-unix/X<n>` must EXIST (a local server is
#     listening on display N). When it exists, all local-ish aliases of N reach
#     that one server → collapse. When it does NOT exist (e.g. SSH-forwarded
#     `localhost:10.0` over an sshd TCP proxy with no `X10` socket), a local-ish
#     TCP form does NOT reach a local server on N → keep its transport-specific
#     form so teardown targets the right transport (round 21).
#   - EXCEPTION — bare `:N` / `unix:N` are ALWAYS local-unix by X convention:
#     they name the local server on N even if the socket is momentarily
#     missing/unreadable (there is no better key than `:N` for them). So they
#     resolve-to-local unconditionally; only the local-ish TCP forms
#     (`localhost`, own hostname) additionally require the socket to exist.
# Returns:
#   0  the display resolves to the local X server on display N (collapse to `:N`)
#   1  it does not (foreign host, SSH-forwarded socket-less localhost:N, or no
#      parseable `[host]:N…`)
_display_resolves_to_local_server() {
    local display="${1:-}"
    [ -n "$display" ] && [ "$display" != "null" ] || return 1
    local host_part="${display%:*}"
    # No colon at all — not a recognizable DISPLAY → not a local server.
    [ "$host_part" != "$display" ] || return 1
    case "$host_part" in
        ''|unix)
            # Bare `:N` / `unix:N` are always the local Unix-socket server.
            return 0 ;;
    esac
    # Remaining host forms collapse to the local server ONLY when the host is
    # local-ish (localhost / own hostname) AND the local X socket exists. A
    # foreign hostname never matches; a local-ish TCP form with no `X<n>` socket
    # (SSH-forwarded localhost:N) keeps its own transport key.
    if [ "${host_part,,}" = localhost ] || _display_host_is_own_hostname "$host_part"; then
        local num_part="${display##*:}"
        local dnum="${num_part%%.*}"
        case "$dnum" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ -S "/tmp/.X11-unix/X${dnum}" ] && return 0
    fi
    return 1
}

# Derive a best-effort token identifying the X-server INSTANCE backing the given
# DISPLAY (#12 review P1). The per-display ownership marker is a disk FILE that
# outlives the X-server-session-scoped grant it records; staleness must therefore
# be decided by whether the marker belongs to the CURRENT X server session — NOT
# by how many live broker sessions currently consume the display. Prior round-15
# logic used the consumer count and so misclassified a LIVE broker-owned grant
# that was retained after a failed `xhost -SI` revoke (round-11) as stale,
# deleting its marker and leaking the grant indefinitely. This token replaces
# that heuristic.
#
# LOCAL-SERVER displays only (#12 review). A reliable X-server-INSTANCE identity
# can only be derived from the local `/tmp/.X11-unix/X<n>` socket. We use the
# SHARED `_display_resolves_to_local_server` server-identity probe (also used by
# `_canonical_display`) so the token and the canonical key never diverge:
#
#   LOCAL-SERVER display — the display resolves to the local X server on N: the
#   host part is local-ish (empty `:N`, `unix:N`, `localhost:N`, or this
#   machine's own `hostname:N`) AND (for the TCP forms) the local `X<n>` socket
#   exists. Token =
#     1. The X server's UNIX socket `/tmp/.X11-unix/X<n>` where `<n>` is the
#        CANONICAL display number (`_canonical_display`: `:0`→`X0`, `:0.0`→`X0`,
#        `:1.2`→`X1`, `localhost:0`→`X0` when `X0` exists). Its inode + mtime
#        (`stat -c '%i:%Y'`) change when the X server (including Xwayland)
#        restarts, so they identify THIS X instance.
#     2. Combined with the kernel boot id (`/proc/sys/kernel/random/boot_id`) so
#        a reboot is always detected even if a fresh socket reuses the same
#        inode/mtime.
#   If the local socket is missing/unreadable for a bare `:N`/`unix:N` we DO NOT
#   fall back to a boot-id-only token: boot id is STABLE across X-server
#   restarts, so a boot-id-only token would FALSE-MATCH itself after an X restart
#   and a stale marker would be kept as "current" → teardown would later revoke a
#   newly-pre-existing USER grant. Instead we return the UNKNOWN sentinel.
#
#   NON-LOCAL display — anything that does NOT resolve to a local server:
#   SSH-forwarded `localhost:10.0` (no `/tmp/.X11-unix/X10` socket), or a real
#   remote `host:0` (a different machine's X server). We must NOT read an
#   unrelated LOCAL `/tmp/.X11-unix/X<n>` socket — it is a DIFFERENT transport /
#   server. No reliable instance identity exists → return the UNKNOWN sentinel.
#
# UNKNOWN sentinel = empty string. The caller treats an unknown current token
# (or an unknown/absent marker token) as CANNOT-DETERMINE → the documented SAFE
# DEFAULT: KEEP the marker (never delete on uncertainty), relying on the
# idempotent `xhost -SI` revoke at teardown. Critically, an unknown token is
# NEVER a confident MATCH — `unknown != unknown` for "proves the marker is
# current" purposes — so it cannot resurrect the boot-id-only false-equality bug.
# Empty/null display → unknown sentinel. Residual limitation (remote/socket-less
# displays lack reliable X-session identity → conservative keep-and-rely-on-
# idempotent-revoke) is documented in ADR 0010; agent-browser's host Chrome is
# fundamentally a LOCAL-display feature.
_x_session_token() {
    local display="${1:-}"
    if [ -z "$display" ] || [ "$display" = "null" ]; then
        # UNKNOWN sentinel (empty) — no display, no derivable identity.
        printf '%s\n' ""
        return 0
    fi

    # Determine whether the DISPLAY resolves to the LOCAL X server, via the
    # shared `_display_resolves_to_local_server` probe (kept in lock-step with
    # `_canonical_display`'s collapse). A NON-LOCAL display — SSH-forwarded
    # socket-less `localhost:N`, a remote `host:N`, or a value with no colon — has
    # no reliable instance identity from here → UNKNOWN sentinel; do NOT read a
    # local X<n> socket (a different transport / a different X server entirely).
    if ! _display_resolves_to_local_server "$display"; then
        printf '%s\n' ""
        return 0
    fi

    # LOCAL-SERVER display: derive the socket identity from the CANONICAL display
    # number
    # (drop any `.screen` suffix — round 18) so `:0` and `:0.0` map to `X0`.
    local canon dnum
    canon="$(_canonical_display "$display")"
    dnum="${canon##*:}"

    local sock_id="" boot_id=""
    if [ -n "$dnum" ] && [ -S "/tmp/.X11-unix/X${dnum}" ]; then
        # inode:mtime of the X socket — changes across an X server restart.
        sock_id="$(stat -c '%i:%Y' "/tmp/.X11-unix/X${dnum}" 2>/dev/null || true)"
    fi

    # The socket IS the X-instance discriminator. Without it, boot id alone is
    # stable across X restarts and would give a false cross-restart match, so a
    # missing/unreadable local socket → UNKNOWN sentinel (caller keeps marker).
    [ -n "$sock_id" ] || { printf '%s\n' ""; return 0; }

    if [ -r /proc/sys/kernel/random/boot_id ]; then
        # Single-line read; trim any stray whitespace.
        read -r boot_id < /proc/sys/kernel/random/boot_id 2>/dev/null || boot_id=""
    fi
    printf 'boot=%s;sock=%s\n' "$boot_id" "$sock_id"
}

# Read the X-session token stored inside an ownership marker file (the line
# `xsession=<token>` written at marker-create time). Echoes the token, or empty
# if the file is unreadable / carries no such line (e.g. a marker created before
# this change — an EMPTY-content marker from the original round-15 code).
_x_session_token_from_marker() {
    local marker="${1:-}"
    if [ -z "$marker" ] || [ ! -r "$marker" ]; then
        printf '%s\n' ""
        return 0
    fi
    local line token=""
    while IFS= read -r line; do
        case "$line" in
            xsession=*) token="${line#xsession=}"; break ;;
        esac
    done < "$marker"
    printf '%s\n' "$token"
}

# Canonicalize an X DISPLAY value to its X-SERVER identity (#12 review). An xhost
# grant authorizes a uid on an X SERVER, not on a particular screen — the
# `.screennumber` suffix of a DISPLAY (`[host]:displaynumber[.screennumber]`) is
# IRRELEVANT to authorization. Beyond the screen suffix, the SERVER IDENTITY is
# keyed on the LOCAL X SOCKET EXISTENCE (the shared
# `_display_resolves_to_local_server` probe), because the xhost ACL is
# SERVER-WIDE: `:0` (Unix socket) and `localhost:0` (TCP) that reach the SAME X
# server share ONE authorization, so for refcount + ownership they must collapse
# to one key. Without canonicalization the per-display reference count, the
# ownership-marker filename, and every display comparison key off the EXACT
# STRING, so two sessions using different aliases for one X server are treated as
# different displays: stopping either sees no peer on "its" display string and
# revokes the grant the surviving Chrome still needs. We therefore reduce the
# value to ONE canonical key per X server:
#   - RESOLVES TO THE LOCAL SERVER on N (`:N`/`unix:N` always; `localhost:N` and
#     `<own-hostname>:N` WHEN `/tmp/.X11-unix/X<n>` EXISTS) → DROP the host part
#     AND `.screennumber`, collapsing every same-server alias to the bare `:N`:
#       :0  →  :0    unix:0  →  :0    localhost:0 (X0 exists)  →  :0    :1.2  →  :1
#   - DOES NOT resolve to a local server (SSH-forwarded `localhost:10.0` with no
#     `X10` socket — round 21; a FOREIGN remote `host:N`) → KEEP
#     `host:displaynumber`, still dropping only the `.screennumber`:
#       localhost:10.0 (no X10)  →  localhost:10    host:0.1  →  host:0
# The local-vs-non-local decision is the shared `_display_resolves_to_local_server`
# probe, so this stays consistent with `_x_session_token`'s socket pick (both
# collapse exactly the displays that reach the local `X<n>` server, and keep
# SSH-forwarded / remote displays transport-specific — round-21 correctness).
# Conservative: a value that
# does NOT match the expected `…:N[.M]` shape (digits after the last colon,
# optional `.digits`) is returned UNCHANGED, so unusual or already-normalized
# values are never mangled. Applying this at every point of use (write of
# granted_display, marker path, refcount comparisons) maps one X server to ONE
# key; applying it at COMPARE time too means a non-canonical value persisted by
# an older broker still normalizes and matches.
_canonical_display() {
    local display="${1:-}"
    if [ -z "$display" ] || [ "$display" = "null" ]; then
        printf '%s\n' "$display"
        return 0
    fi
    # Split on the LAST colon: everything before is the host part (may be
    # empty for the common `:0` form), everything after is `displaynumber`
    # optionally followed by `.screennumber`.
    local host_part num_part
    host_part="${display%:*}"
    num_part="${display##*:}"
    # The value must actually CONTAIN a colon (host_part != whole string) and
    # the number part must be `N` or `N.M` with N,M all digits. Anything else
    # is left untouched (be conservative about unusual values).
    if [ "$host_part" = "$display" ]; then
        printf '%s\n' "$display"
        return 0
    fi
    case "$num_part" in
        ''|*[!0-9.]*)
            printf '%s\n' "$display"; return 0 ;;
    esac
    # Drop the `.screennumber` suffix (everything from the first dot). What
    # remains must be a non-empty run of digits — the display number.
    local display_number="${num_part%%.*}"
    case "$display_number" in
        ''|*[!0-9]*)
            printf '%s\n' "$display"; return 0 ;;
    esac
    # Displays that RESOLVE TO THE LOCAL X SERVER on N (`:N`/`unix:N` always;
    # `localhost:N` / `<own-host>:N` when `/tmp/.X11-unix/X<N>` exists) all reach
    # the SAME server → collapse to the bare `:displaynumber`. A display that does
    # NOT reach a local server (SSH-forwarded socket-less `localhost:N`, a remote
    # host) keeps its own `host:displaynumber` key.
    if _display_resolves_to_local_server "$display"; then
        printf ':%s\n' "$display_number"
        return 0
    fi
    printf '%s:%s\n' "$host_part" "$display_number"
}

# Sanitize an X DISPLAY string into a filesystem-safe token for the per-display
# ownership-marker filename (#12 review finding 3). DISPLAY is `host:display.screen`
# (e.g. `:0`, `:1`, `:1.0`, `somehost:0`). We map every character outside
# `[A-Za-z0-9._-]` to `_` and strip a leading dot, so no path-traversal, slash,
# or shell-special character can reach the filename. `:0` → `0`, `:1` → `1`,
# `:1.0` → `1.0`, `host:0` → `host_0`. Empty/null display → empty (caller skips
# the marker entirely).
_sanitize_display_for_marker() {
    local display="${1:-}"
    if [ -z "$display" ] || [ "$display" = "null" ]; then
        printf '%s\n' ""
        return 0
    fi
    # Drop a leading ':' (the common `:0` form would otherwise become `_0`).
    display="${display#:}"
    # Replace any character not in the safe set with '_'.
    local sanitized
    sanitized="$(printf '%s' "$display" | tr -c 'A-Za-z0-9._-' '_')"
    # Guard against a leading dot (no traversal component can form).
    sanitized="${sanitized#.}"
    [ -n "$sanitized" ] || sanitized="display"
    printf '%s\n' "$sanitized"
}

# Path to the per-display broker-ownership marker (#12 review finding 3). Its
# EXISTENCE means "the broker itself ADDED the xhost grant for this display"
# (boxa-agent was NOT already authorized when the first grant was attempted).
# Teardown revokes ONLY when this marker exists, so a pre-existing non-broker
# authorization is never removed. Empty display → empty path (caller no-ops).
#
# The marker filename derives from the CANONICAL display (#12 review P2) so
# aliases of one X server (`:0` and `:0.0`) resolve to the SAME marker file —
# the grant is per X server, so its ownership record must be too.
_xhost_ownership_marker_path() {
    local display="${1:-}"
    display="$(_canonical_display "$display")"
    local token
    token="$(_sanitize_display_for_marker "$display")"
    [ -n "$token" ] || { printf '%s\n' ""; return 0; }
    printf '%s/xhost-owned-%s\n' "$SESSIONS_DIR" "$token"
}

# Query whether boxa-agent is ALREADY authorized on the given display (#12
# review finding 3). `xhost` with no arguments prints the access control list;
# an `SI:localuser:boxa-agent` ENTRY means the uid is already authorized.
# Returns:
#   0  boxa-agent IS already authorized (an SI:localuser:boxa-agent entry)
#   1  boxa-agent is NOT authorized
#   2  the query itself FAILED (xhost errored / unparseable) — caller MUST take
#      the SAFE path (treat as pre-existing → no marker → no revoke) so the
#      broker never removes authorization it cannot prove it added.
# Match the COMPLETE access-control token, NOT a substring (#12 review): a bare
# `grep boxa-agent` substring-matches an unrelated entry like
# `SI:localuser:boxa-agent2`, so the broker would wrongly conclude the real
# `boxa-agent` is authorized and SKIP both the ownership marker and the
# required `xhost +SI` grant → Chrome startup fails. xhost prints one entry per
# line (often indented); trim each line and compare it for EQUALITY against the
# exact `SI:localuser:boxa-agent` token the broker grants. Case-insensitive on
# the comparison to tolerate output-format differences across xhost builds.
_xhost_agent_already_authorized() {
    local display="${1:-}"
    local out rc=0
    out="$(DISPLAY="$display" xhost 2>/dev/null)" || rc=$?
    [ "$rc" -eq 0 ] || return 2
    local line trimmed
    while IFS= read -r line; do
        # Strip leading/trailing whitespace so an indented entry still matches
        # the exact token (and only the exact token).
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        # Lowercase for a case-insensitive WHOLE-TOKEN equality check — an entry
        # like `SI:localuser:boxa-agent2` differs and is correctly rejected.
        if [ "${trimmed,,}" = 'si:localuser:boxa-agent' ]; then
            return 0
        fi
    done <<EOF
$out
EOF
    return 1
}

# Write the EARLY starting-claim state file — the convergent mechanism for both
# #12 review findings. cmd_start calls this at the very start of a session,
# BEFORE granting the shared X display and long before any PID is known. The
# file it writes is a `status: "starting"` claim carrying:
#   - `granted_display`: the `$DISPLAY` value the grant will run on. Persisting
#     it here (finding 1) lets EVERY later teardown — including the common
#     `stop` paths that run without an ambient `$DISPLAY` (detached watchdog,
#     container-stop closeout, SSH/other-terminal) — revoke against the right
#     display env-independently, instead of leaking the grant. Null/empty when
#     there is no graphical session (a headless start never grants, so its
#     revoke is a no-op).
#   - `status: "starting"` + null PIDs: makes the session visible to a
#     concurrently-starting sibling's revoke-if-last check the instant the claim
#     lands (finding 2). `_state_file_is_display_consumer` counts a starting
#     claim as a consumer, so a sibling that grants then FAILS before this
#     session writes its full state cannot revoke the shared grant out from
#     under this in-progress start.
#   - `starting_pid`: the PID of the cmd_start broker process that owns this
#     start from the early claim through to the full-state write (#12 review
#     P2). The starting claim is counted as a display consumer ONLY WHILE this
#     PID is alive — that is precisely what distinguishes a genuinely
#     in-progress start (PID alive → consumer, the round-8 race fix) from one
#     ABANDONED by a broker killed mid-start (PID dead → not a consumer, and the
#     sweep reclaims it). Without it an orphaned starting file would pin the
#     shared grant indefinitely.
# Progressive update: cmd_start overwrites this same file later (the ufw
# crash-window marker, then the full session state) as resources come up; both
# of those writers carry `granted_display` forward so the persisted display
# survives to teardown. Once the file is overwritten its `status` is no longer
# "starting", so the `starting_pid` liveness gate no longer applies to it (a
# fully-established session is validated by its live chrome_pid instead, never
# mis-expired by a dead starting_pid). Written with `cat >` (never
# unlink+recreate) so a bind-mounted file would keep its inode.
_write_starting_claim() {
    local file="$1" container="$2" granted_display="$3" starting_pid="${4:-}"
    local granted_display_json="null"
    [ -n "$granted_display" ] && granted_display_json="\"${granted_display}\""
    local starting_pid_json="null"
    [ -n "$starting_pid" ] && starting_pid_json="${starting_pid}"
    # Record the broker PID's START TIME alongside it (#12 review P2) so the
    # claim's consumer/sweep guards can verify process IDENTITY, not just PID
    # liveness — a reused PID after a crash/reboot has a different starttime and
    # must NOT be mistaken for a live in-progress start. Empty (→ JSON null) when
    # /proc is unreadable; the guards then fall back to bare liveness.
    local starting_pid_starttime_json="null" starting_pid_starttime=""
    [ -n "$starting_pid" ] && starting_pid_starttime="$(_pid_starttime_on_host "$starting_pid")"
    [ -n "$starting_pid_starttime" ] && starting_pid_starttime_json="${starting_pid_starttime}"
    # PROPAGATE a failed write (#12 review P2): the starting-claim is what protects
    # a concurrent start (the round-8 race) and carries granted_display/starting_pid
    # forward, so cmd_start MUST NOT grant the X display if it could not be written
    # (disk full, unwritable state dir). The `cat > "$file"` redirect returns
    # non-zero when the redirect or the write fails, and it is this function's last
    # command, so its rc is the function's rc — but `set -e` is suppressed at the
    # locked-section call site (it runs under `|| exit 1`), so the caller must check
    # this return value EXPLICITLY (`_write_starting_claim ... || return 1`) rather
    # than rely on errexit. We return the redirect's status verbatim so a failed
    # write is never silently swallowed.
    if ! cat > "$file" <<EOF
{
  "container": "${container}",
  "status": "starting",
  "granted_display": ${granted_display_json},
  "starting_pid": ${starting_pid_json},
  "starting_pid_starttime": ${starting_pid_starttime_json},
  "chrome_pid": null,
  "bridge_pid_in_container": null,
  "relay_pid_host": null,
  "proxy_pid": null,
  "watchdog_pid": null,
  "ufw_slot_subnet": null,
  "ufw_slot_pending_subnet": null,
  "active_network_window": null
}
EOF
    then
        return 1
    fi
    return 0
}

# Grant the unprivileged `boxa-agent` user access to the developer's X
# display before launching Host agent Chrome (issue 12). Host agent Chrome
# runs as `boxa-agent`, a different uid than the session owner; on
# Wayland/Xwayland — and on any X server using per-uid (`SI:localuser`)
# authorization — that uid is rejected ("Authorization required, but no
# authorization protocol specified") because it has no X cookie it can read.
#
# `xhost +SI:localuser:boxa-agent` is the minimal, per-uid, DISPLAY-ONLY
# grant: it authorizes exactly the boxa-agent uid to connect to this one
# X server, nothing more. NEVER blanket `xhost +` (that opens the display to
# every local user). Filesystem isolation from the developer's home and the
# personal Chrome profile is UNCHANGED — only an X connection is granted.
# X11 is a weak boundary between clients on the same server (the granted uid
# can snoop/inject into other X clients on this display); ADR 0010 documents
# this caveat and the headless-Xwayland future-work that would harden it.
#
# Idempotent and re-applied on EVERY start: the grant does not persist across
# logout and we add no autostart entry, so re-running it each launch is what
# keeps it surviving a re-login.
#
# Gating:
#   - Linux native ONLY. macOS uses Quartz (no xhost); WSL2 uses WSLg, whose
#     Wayland/Xwayland sockets are world-readable so boxa-agent already
#     connects without an xhost grant — running xhost there is unnecessary
#     and `xhost` is typically absent. host_platform::detect distinguishes
#     the three; we act only on `linux`.
#   - Only when a graphical session is present (`$DISPLAY` set). Skipped
#     without error when `$DISPLAY` is unset (headless / no X session).
#
# Missing-tool handling: if `$DISPLAY` is set but `xhost` is absent, fail
# with a clear, actionable message rather than launching Chrome into a
# guaranteed display-authorization failure. The actual provisioning of
# `xhost` (package install) is issue 13's job — here we only need a clear
# error, not silent failure.
#
# Ownership-marker revalidation on the already-authorized path (#12 review P1):
# the per-display ownership marker is a FILE that survives on disk across X
# SERVER restarts, but the xhost authorization it records is X-server-session
# scoped (cleared on reset). A marker can therefore OUTLIVE the grant it stood
# for: after an X server reset a stale marker remains while boxa-agent is now
# authorized only by a fresh post-reset state (the user, or nothing the broker
# added). Without revalidation a later start would see boxa-agent already
# authorized, take the already-authorized branch, leave the stale marker intact,
# and teardown would then revoke the USER's pre-existing grant keyed off that
# dead marker.
#
# Staleness is decided by X-SERVER-SESSION IDENTITY, NOT by a live-consumer count
# (the prior round-15 heuristic). Each marker is STAMPED at create time with an
# `_x_session_token` (boot id + X socket inode/mtime) identifying the X instance
# it was created against. On the already-authorized branch we compare the
# marker's stored token to the CURRENT X-session token:
#   - tokens MATCH  → the marker belongs to THIS X server session → it is a LIVE
#     broker-owned grant (possibly retained after a failed `xhost -SI` revoke,
#     round-11) → KEEP it regardless of consumer count. (Replaces the round-15
#     consumer-count logic, which wrongly deleted exactly this retained marker
#     and leaked the grant forever — #12 review P1.)
#   - tokens DIFFER → the marker is from a PRIOR X server (its grant was cleared
#     by the reset/reboot) → genuinely STALE → clear it and log visibly, so
#     teardown treats the authorization as pre-existing and never revokes the
#     user's grant (round-15's real protection).
#   - token MISSING in the marker (created before this change) or the current
#     token UNDERIVABLE (remote / SSH-forwarded / socket-less display) →
#     OWNERSHIP CANNOT BE VERIFIED → DROP the marker (#12 review — supersedes the
#     prior keep-on-uncertainty default). The broker must NEVER revoke an
#     authorization it cannot prove it created: an unverifiable marker is more
#     dangerous (it could make teardown revoke a USER's pre-existing grant whose
#     authorization was added independently while the marker outlived an X reset)
#     than the benign residual it avoids. The accepted, FINAL residual: on exotic
#     TCP/remote/SSH-forwarded displays the broker may then FAIL to revoke its
#     OWN grant — a benign leak for the dedicated, low-privilege `boxa-agent`
#     service account, which exists only for agent-browser. With finding-1's
#     socket-existence probe, local displays now almost always derive a non-empty
#     token, so this unverifiable case shrinks to genuinely exotic displays.
#     Documented as the resolution of the keep-vs-drop-on-uncertainty question in
#     ADR 0010 so it is not re-litigated.
# This runs inside the same X-grant lock as the grant (the caller's locked
# region), so it composes with the round-8 starting-claim, round-10 lock, and
# round-11/12/14 revoke/sweep logic.
#
# $1 (optional): this session's container name, retained for call-site symmetry
# with the locked claim+grant region; the token-based revalidation no longer
# needs it (it does not count peer sessions), but the parameter is kept so
# callers — and the not-yet-authorized marker creation — stay uniform.
_grant_agent_x_display_access() {
    # $1 (this session's container) is accepted for call-site symmetry but no
    # longer used: the already-authorized revalidation is now by X-session token
    # (#12 review P1), not by counting this container's peers.
    : "${1:-}"
    local platform
    platform="$(host_platform::detect 2>/dev/null || true)"
    [ "$platform" = "linux" ] || return 0

    # No graphical session — nothing to grant. Skip cleanly (a headless
    # broker invocation, e.g. over SSH with no X forwarding, is valid).
    [ -n "${DISPLAY:-}" ] || return 0

    command -v xhost >/dev/null 2>&1 \
        || _die "xhost not found, but \$DISPLAY is set (${DISPLAY}). Host agent Chrome runs as 'boxa-agent' and needs an X display grant ('xhost +SI:localuser:boxa-agent'). Install the X11 client tools (Debian/Ubuntu: sudo apt-get install -y x11-xserver-utils; Fedora/RHEL: sudo dnf install -y xorg-x11-server-utils; Arch: sudo pacman -S xorg-xhost), then retry. (Automated provisioning: issue 13.)"

    # Per-display broker-ownership tracking (#12 review finding 3). Before
    # granting, ask the X server whether boxa-agent is ALREADY authorized on
    # this display. We create the per-display ownership marker — which teardown
    # keys its revoke off — ONLY when the broker is the one ADDING the grant
    # (boxa-agent NOT yet authorized). If it was already authorized, or the
    # query itself fails, we DELIBERATELY do not create the marker, so the final
    # teardown never revokes an authorization the broker did not add (safe
    # default on query failure). The query + marker create run inside the START
    # critical section (the caller holds the X-grant lock, finding 1).
    #
    # On the already-authorized path we additionally REVALIDATE any surviving
    # marker (#12 review P1 — see the function header) by X-SERVER-SESSION TOKEN:
    # a marker whose stored token differs from the current X session's token is
    # from a PRIOR X server (its grant was cleared by the reset) → stale → clear
    # it. A matching token is a LIVE broker-owned grant (possibly retained after a
    # failed revoke) → keep it. A missing/underivable token → keep (safe default).
    local marker
    marker="$(_xhost_ownership_marker_path "$DISPLAY")"
    local already_rc=0
    _xhost_agent_already_authorized "$DISPLAY" || already_rc=$?
    case "$already_rc" in
        0)
            # Pre-existing authorization → do NOT claim ownership (no new marker).
            # Revalidate any SURVIVING marker by X-session IDENTITY (#12 review
            # P1). The marker is a disk file that can outlive the
            # X-server-session-scoped grant it recorded (e.g. across an X server
            # reset). Compare the marker's stored token to the CURRENT X-session
            # token:
            #   - DIFFER → marker is from a PRIOR X server (its grant was cleared
            #     by the reset/reboot) → STALE → clear it (visibly) so teardown
            #     treats the authorization as pre-existing and never revokes the
            #     user's grant (round-15's real protection).
            #   - MATCH → the marker belongs to THIS X server session → a LIVE
            #     broker-owned grant (possibly retained after a failed `xhost -SI`
            #     revoke, round-11) → KEEP it. (NOT decided by consumer count: a
            #     retained-after-failed-revoke grant has zero current consumers yet
            #     is still live — the exact case round-15's count logic leaked.)
            #   - marker token MISSING (older marker) or current token UNDERIVABLE
            #     → OWNERSHIP UNVERIFIABLE → DROP the marker (the broker never
            #     claims ownership it cannot prove).
            if [ -n "$marker" ] && [ -e "$marker" ]; then
                local marker_token current_token
                marker_token="$(_x_session_token_from_marker "$marker")"
                current_token="$(_x_session_token "$DISPLAY")"
                # Two outcomes clear/drop the marker; one keeps it (#12 review):
                #   1. BOTH tokens present AND they MATCH → VERIFIED broker
                #      ownership (incl. the round-11 retained-after-failed-revoke
                #      grant) → KEEP.
                #   2. BOTH tokens present AND they DIFFER → STALE (prior X server
                #      / reboot — its grant was cleared by the reset) → CLEAR, so
                #      teardown treats the authorization as pre-existing (round-15's
                #      protection).
                #   3. EITHER token UNAVAILABLE/empty (UNKNOWN sentinel — legacy
                #      tokenless marker, OR a TCP/remote/SSH display where
                #      `_x_session_token` intentionally returns empty) → ownership
                #      CANNOT BE VERIFIED → DROP the marker. This REVERSES the prior
                #      keep-on-uncertainty default (#12 review): the broker must
                #      never revoke an authorization it cannot prove it created — an
                #      unverifiable marker could make teardown revoke a USER's
                #      pre-existing grant (a marker can outlive an X reset while the
                #      current authorization was added independently by the user).
                #      The accepted residual — the broker may then fail to revoke
                #      its OWN grant on exotic TCP/remote/SSH displays (a benign
                #      leak for the dedicated, low-privilege `boxa-agent` service
                #      account) — is documented as FINAL in ADR 0010.
                if [ -z "$marker_token" ] || [ -z "$current_token" ]; then
                    _log "agent-browser: clearing unverifiable X-grant ownership marker for ${DISPLAY}; cannot prove broker ownership (marker or current X-session token unavailable), treating current authorization as pre-existing."
                    rm -f -- "$marker" 2>/dev/null \
                        || _warn "agent-browser: could not remove unverifiable X-grant ownership marker ${marker}; teardown may wrongly revoke a pre-existing authorization on ${DISPLAY}."
                elif [ "$marker_token" != "$current_token" ]; then
                    _log "agent-browser: clearing stale X-grant ownership marker for ${DISPLAY}: it was stamped against a prior X server session (token mismatch — X server reset/reboot), whose grant the reset cleared; existing authorization treated as pre-existing."
                    rm -f -- "$marker" 2>/dev/null \
                        || _warn "agent-browser: could not remove stale X-grant ownership marker ${marker}; teardown may wrongly revoke a pre-existing authorization on ${DISPLAY}."
                fi
            fi
            _log "boxa-agent already authorized on ${DISPLAY} (pre-existing); broker will not revoke this authorization on teardown."
            ;;
        2)
            # Query FAILED → we cannot determine ownership, so we FAIL CLOSED
            # (#12 review P2). The earlier "treat as pre-existing, proceed to
            # grant" path was a LEAK: if the +SI grant then SUCCEEDED, teardown
            # would later find a grant with NO ownership marker, treat it as
            # pre-existing, and NEVER revoke it — boxa-agent stays authorized
            # until the X server resets. Refuse to grant when we cannot track
            # ownership: return non-zero so the locked-section caller's
            # `|| exit 1` fires the EXIT trap → `_cleanup_failed_start`. Since the
            # grant never ran, cleanup no-ops the un-allocated X resource (the
            # starting claim already written is reclaimed by the trap as usual).
            _warn "agent-browser: could not query X access control list on ${DISPLAY} to determine grant ownership; refusing to grant to avoid an untracked authorization that teardown could not revoke. (The X server may be momentarily unreachable — retry the start.)"
            return 1
            ;;
        *)
            # NOT authorized → the broker is the one adding the grant. Claim
            # ownership so teardown is allowed to revoke it later, STAMPING the
            # marker with the current X-session token (#12 review P1) so a later
            # already-authorized start can tell a marker from THIS X session
            # (keep) from one left by a prior X server (stale → clear). The
            # marker's mere EXISTENCE remains the ownership signal for the revoke
            # gate; the token is extra content.
            #
            # FAIL CLOSED on a marker-write failure (#12 review P2), mirroring the
            # rc-2 ownership-query failure above and the round-17 starting-claim
            # write failure. Write the marker BEFORE granting: a successful grant
            # with NO ownership record leaks — every teardown would treat it as
            # pre-existing and never revoke, so boxa-agent stays authorized
            # until the X server resets. We write ATOMICALLY (temp + mv) so a
            # failed write never leaves a half-written marker, then refuse to grant
            # if the marker is not durably in place. The non-zero return propagates
            # through `_start_x_claim_and_grant_locked`'s `|| exit 1` → EXIT trap →
            # `_cleanup_failed_start`, which no-ops since no grant ran.
            if [ -n "$marker" ]; then
                mkdir -p "$SESSIONS_DIR" 2>/dev/null || true
                local current_token marker_tmp
                current_token="$(_x_session_token "$DISPLAY")"
                marker_tmp="${marker}.tmp.$$"
                if ! printf 'xsession=%s\n' "$current_token" > "$marker_tmp" 2>/dev/null \
                    || ! mv -f -- "$marker_tmp" "$marker" 2>/dev/null; then
                    rm -f -- "$marker_tmp" 2>/dev/null || true
                    _warn "agent-browser: could not write X-grant ownership marker for ${DISPLAY}; refusing to grant to avoid an untracked authorization that teardown could not revoke. (Marker path ${marker} — the session dir may be unwritable or full.)"
                    return 1
                fi
                # Marker durably written → grant. If the grant itself FAILS there
                # is NO authorization to own, so REMOVE the just-created marker
                # before failing (else a stale marker is left for a grant that
                # never happened, and a later already-authorized start would treat
                # it as a live broker-owned grant). The rc-0 path below shares the
                # plain grant: it created no marker, so a grant failure there has
                # nothing to undo.
                _log "Granting boxa-agent X display access (xhost +SI:localuser:boxa-agent on ${DISPLAY})..."
                if ! xhost +SI:localuser:boxa-agent >/dev/null; then
                    rm -f -- "$marker" 2>/dev/null || true
                    _die "Failed to grant boxa-agent X display access via 'xhost +SI:localuser:boxa-agent' on ${DISPLAY}."
                fi
                return 0
            fi
            ;;
    esac

    _log "Granting boxa-agent X display access (xhost +SI:localuser:boxa-agent on ${DISPLAY})..."
    xhost +SI:localuser:boxa-agent >/dev/null \
        || _die "Failed to grant boxa-agent X display access via 'xhost +SI:localuser:boxa-agent' on ${DISPLAY}."
}

# The START critical section body (#12 review finding 1): write the early
# starting-claim, then grant the X display (which, finding 3, queries ownership
# and creates the per-display marker only when the broker is adding the grant).
# Run by cmd_start as a single command inside `_with_xhost_grant_lock` so the
# whole claim→grant region is mutually exclusive with a concurrent teardown's
# count→revoke. Kept deliberately small — no Chrome launch / docker exec here.
# A grant failure `_die`s (from `_grant_agent_x_display_access`); inside the lock
# subshell that exits the subshell non-zero, which the caller propagates.
_start_x_claim_and_grant_locked() {
    local start_state_file="$1" container="$2" granted_display="$3" starting_pid="${4:-}"
    # `starting_pid` is the cmd_start broker PID (`$$`), captured by the caller
    # in the MAIN shell and passed in — NOT re-derived here. This function runs
    # inside the X-grant-lock subshell, where `$BASHPID` would be the short-lived
    # subshell rather than the process that owns the start through to the
    # full-state write; `$$` stays the script PID even in a subshell, but we take
    # the caller's value to keep the ownership PID unambiguous (#12 review P2).
    # ABORT BEFORE GRANTING if the starting-claim could not be written (#12 review
    # P2). The X grant must run ONLY after a successful claim write: the claim is
    # the round-8 concurrent-start protection and carries granted_display forward
    # for teardown, so granting without it would leave boxa-agent authorized with
    # no state to revoke against. `set -e` is suppressed here (this helper runs
    # under the caller's `|| exit 1`), so we check the write's rc EXPLICITLY and
    # propagate it; the call site's `|| exit 1` then fires the EXIT trap →
    # `_cleanup_failed_start`, which no-ops since nothing was granted yet.
    if ! _write_starting_claim "$start_state_file" "$container" "$granted_display" "$starting_pid"; then
        _warn "agent-browser: failed to write the starting-claim to ${start_state_file} (state dir $(dirname -- "$start_state_file") unwritable or full); aborting start before granting the X display."
        return 1
    fi
    # Pass the container for call-site symmetry. The grant's already-authorized
    # path now revalidates a surviving ownership marker by X-SESSION TOKEN (#12
    # review P1), not by counting peer sessions, so it no longer needs the
    # container — but it is kept uniform with the other locked-region callers.
    _grant_agent_x_display_access "$container"
}

# A state file is a DISPLAY CONSUMER iff its session is either (a) STARTING —
# an in-progress early claim written before Chrome is up — or (b) already has a
# live Chrome running as boxa-agent. Both depend on the shared per-uid X
# grant: a starting session is mid-launch and will need it the instant Chrome
# spawns; a live session needs it now. A file RETAINED purely so the next
# start's sweep can retry a failed `sudo ufw delete` — Chrome already torn down
# — is NOT a display consumer and must not keep the grant alive. cmd_stop marks
# such a file with `ufw_retry_only: true` (and nulls chrome_pid/proxy_pid)
# before retaining it.
#
# The STARTING case (finding 2 / concurrent-start race): cmd_start writes the
# session state file as a `status: "starting"` claim with a populated
# `granted_display` BEFORE it grants the display and long before Chrome's PID is
# known. Counting that claim as a consumer makes a concurrently-starting sibling
# visible to another start's revoke-if-last check immediately — so a sibling's
# rollback cannot revoke the shared grant out from under an in-progress start.
# We therefore key the predicate on the claim marker (`status: "starting"` or a
# non-null `granted_display`), NOT solely on a populated chrome_pid.
#
# Abandoned-claim expiry (#12 review P2): a starting claim is counted as a
# consumer ONLY WHILE its recorded `starting_pid` — the cmd_start broker process
# that owns the start through to the full-state write — is still ALIVE. A
# genuinely in-progress start (broker alive, mid-launch) still counts, so the
# round-8 race fix is intact. But a broker KILLED after writing the early claim
# yet before writing full session state leaves an orphaned `status: "starting"`
# file; without this gate it would be treated as a live consumer INDEFINITELY,
# so stopping the last REAL session on that display could never revoke the
# broker-owned grant (permanent leak). With the gate, a dead `starting_pid`
# makes the claim ABANDONED → NOT a consumer, and `_sweep_if_stale` reclaims it.
# The gate applies ONLY while `status == "starting"`: once cmd_start overwrites
# the file with full state (status no longer "starting"), the session is
# validated by its live chrome_pid below, never mis-expired by a stale
# starting_pid.
#
# The X grant is per-DISPLAY (xhost authorizes boxa-agent on a SPECIFIC X
# display), so the reference count MUST be scoped to the display being revoked
# (finding: scope X-grant reference counting to the display). The optional
# second argument `target_display` filters the predicate to that display: a file
# is a consumer ON DISPLAY D iff it is a display consumer AND its persisted
# `granted_display` equals D. Sessions on a DIFFERENT display neither block nor
# are affected by a revoke of D; a session with null/absent `granted_display`
# (non-graphical, never granted) is a consumer on NO display. When
# `target_display` is empty the predicate is unscoped (legacy "any display"
# behaviour) — used where no specific display is in play.
#
# Returns 0 when the file represents a display consumer (on the target display,
# if one is given), 1 when it does not (ufw-retry-only marker, an ABANDONED
# starting claim whose broker PID is dead, neither a starting claim nor a live
# chrome_pid, a DEAD/stale chrome_pid, or a granted_display that does not match
# the target display). The ufw_retry_only marker is read as an authoritative
# signal; a LIVE starting claim is validated by its `starting_pid` (#12 review
# P2 — alive broker only), and a file that claims a RUNNING chrome_pid is
# validated for liveness (#12 review finding 2) — the PID must be alive AND match
# the session's profile-dir marker (the same check `_sweep_if_stale` uses) — so
# neither an abandoned start, a crashed Chrome, nor a stale post-reboot file
# pins the shared grant forever.
_state_file_is_display_consumer() {
    local file="$1"
    local target_display="${2:-}"
    [ -f "$file" ] || return 1
    local retry_only chrome_pid status granted_display is_consumer=1
    retry_only="$(_state_get "$file" ufw_retry_only 2>/dev/null || true)"
    # An explicit ufw-retry-only marker means Chrome is already gone — not a
    # display consumer regardless of any stale chrome_pid / starting claim left
    # in the file.
    [ "$retry_only" = "true" ] && return 1
    granted_display="$(_state_get "$file" granted_display 2>/dev/null || true)"
    # In-progress early claim: a session mid-launch that has claimed the display
    # but not yet brought Chrome up. The `status: "starting"` marker (and the
    # paired non-null `granted_display`) is set by cmd_start's early claim before
    # the grant — count it so concurrent siblings don't revoke its grant.
    status="$(_state_get "$file" status 2>/dev/null || true)"
    if [ "$status" = "starting" ]; then
        # Count this in-progress claim as a consumer ONLY while the broker that
        # is driving the start is still alive AND is the SAME process (#12 review
        # P2). A live, identity-matched broker means a real in-progress start
        # whose grant must be protected (round-8 race fix). A DEAD `starting_pid`
        # — or one whose PID is alive but has been REUSED by an unrelated process
        # (different `/proc/<pid>/stat` starttime, e.g. after a crash/reboot) —
        # means the start is ABANDONED: not a consumer, so the last real
        # session's stop can revoke the grant and the sweep can reclaim the file.
        # Missing/null `starting_pid` (older claims pre-dating this field) falls
        # back to counting the claim, preserving the prior conservative
        # behaviour rather than expiring a claim we cannot evaluate. The
        # starttime-identity check is encapsulated in `_starting_pid_is_live`,
        # shared with `_sweep_if_stale` so both stay consistent.
        local starting_pid starting_pid_starttime
        starting_pid="$(_state_get "$file" starting_pid 2>/dev/null || true)"
        starting_pid_starttime="$(_state_get "$file" starting_pid_starttime 2>/dev/null || true)"
        if [ -z "$starting_pid" ] || [ "$starting_pid" = "null" ]; then
            is_consumer=0
        elif _starting_pid_is_live "$starting_pid" "$starting_pid_starttime"; then
            is_consumer=0
        fi
    elif [ -n "$granted_display" ] && [ "$granted_display" != "null" ]; then
        # A populated granted_display with no Chrome yet is the same early-claim
        # window written before chrome_pid is known; still a consumer.
        chrome_pid="$(_state_get "$file" chrome_pid 2>/dev/null || true)"
        if [ -z "$chrome_pid" ] || [ "$chrome_pid" = "null" ]; then
            is_consumer=0
        fi
    fi
    if [ "$is_consumer" != 0 ]; then
        chrome_pid="$(_state_get "$file" chrome_pid 2>/dev/null || true)"
        # A file that claims a RUNNING chrome_pid is a consumer only if that
        # Chrome is actually ALIVE and is OURS (#12 review finding 2). Without
        # this, a crashed Chrome+watchdog or a stale state file surviving a
        # reboot would keep counting as a consumer, so stopping the last REAL
        # session would preserve the shared grant indefinitely. We reuse the
        # broker's own liveness check — `_pid_matches_marker` against the unique
        # `--user-data-dir=<profile_dir>` marker, exactly the predicate
        # `_sweep_if_stale` uses to decide a recorded Chrome PID is still ours —
        # so a dead/recycled PID is NOT counted. The `starting` claim path above
        # already short-circuited (it legitimately has no live chrome yet), so we
        # only reach here for files that assert a running chrome.
        if [ -n "$chrome_pid" ] && [ "$chrome_pid" != "null" ]; then
            local profile_dir chrome_marker
            profile_dir="$(_state_get "$file" profile_dir 2>/dev/null || true)"
            if [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ]; then
                chrome_marker="--user-data-dir=$profile_dir"
                _pid_matches_marker "$chrome_pid" "$chrome_marker" && is_consumer=0
            else
                # No profile_dir to anchor the identity match (older/partial
                # state). Fall back to a bare liveness probe so we never miss a
                # genuinely live session — but a dead PID still drops out.
                _pid_alive_on_host "$chrome_pid" && is_consumer=0
            fi
        fi
    fi
    [ "$is_consumer" = 0 ] || return 1

    # Per-display scoping (finding): when a target display is given, this file is
    # a consumer ON THAT DISPLAY only if its persisted granted_display matches.
    # A null/absent granted_display is a consumer on no display (it never
    # granted); a different display does not count toward this display's revoke.
    if [ -n "$target_display" ]; then
        [ -n "$granted_display" ] && [ "$granted_display" != "null" ] || return 1
        # Compare CANONICAL-to-CANONICAL (#12 review P2): the file's persisted
        # `granted_display` and the caller's `target_display` may be different
        # aliases of the SAME X server (`:0` vs `:0.0`). Canonicalizing both
        # sides at compare time (in addition to writing canonical) means a peer
        # on an alias of this display still counts — so stopping one alias does
        # not revoke the grant the surviving alias's Chrome needs — and an older
        # non-canonical persisted value normalizes and matches too.
        [ "$(_canonical_display "$granted_display")" = "$(_canonical_display "$target_display")" ] || return 1
    fi
    return 0
}

# Count agent-browser sessions OTHER than $1's container that are still
# DISPLAY CONSUMERS — i.e. state files for a DIFFERENT container whose Chrome
# is not torn down. Echoes the integer count on stdout.
#
# The optional second argument `target_display` scopes the count to a SPECIFIC
# X display (finding: scope X-grant reference counting to the display): when
# given, only OTHER sessions whose persisted `granted_display` equals that
# display are counted. The X grant is per-display, so deciding whether to revoke
# the grant on display D must count peers ON D only — a session on a different
# display neither blocks nor is affected by D's revoke. When empty the count is
# unscoped (legacy "any display" behaviour).
#
# Used to reference-count the shared, per-uid X display grant
# (`+SI:localuser:boxa-agent`) on a given display. The grant is keyed on the
# boxa-agent UID AND the display, NOT per session, and the user routinely runs
# several boxa containers (and thus several agent-browser sessions) at once —
# every live session's Chrome on display D depends on that display's shared
# grant. So the grant on D may only be revoked when THIS session is the LAST
# display consumer ON D going away.
#
# Liveness is decided by the presence of a session state file for another
# container — the same primary signal the missing-session picker and the
# stale-session sweep use (`$SESSIONS_DIR/<container>.json`) — EXCEPT that a
# file marked Chrome-torn-down/`ufw_retry_only` is excluded: it is retained
# only so the next start can retry a failed ufw delete, its Chrome is already
# gone, and it must NOT keep the shared display grant alive (the round-6 hole:
# revoke was skipped whenever any file was retained). We still do NOT re-derive
# liveness from process probes for ordinary files: the state file IS the
# session record, and a session whose processes died but whose file survives
# (without the retry-only marker) is exactly the retain-on-failure case we must
# not pull the grant out from under.
_count_other_live_sessions() {
    local this_container="$1"
    local target_display="${2:-}"
    local count=0 f base
    [ -d "$SESSIONS_DIR" ] || { printf '0\n'; return 0; }
    shopt -s nullglob
    for f in "$SESSIONS_DIR"/*.json; do
        base="$(basename "$f" .json)"
        [ "$base" = "$this_container" ] && continue
        # Skip files that are no longer display consumers (Chrome torn down,
        # retained only for a deferred ufw-delete retry) AND, when a target
        # display is given, files whose granted_display is a DIFFERENT display
        # (finding: per-display scoping — only peers on this display count).
        _state_file_is_display_consumer "$f" "$target_display" || continue
        count=$((count + 1))
    done
    shopt -u nullglob
    printf '%s\n' "$count"
}

# Revoke the boxa-agent X display grant — the teardown counterpart of
# `_grant_agent_x_display_access`, mirroring its native-Linux + xhost-present
# gates, BUT targeting a PERSISTED display rather than the ambient `$DISPLAY`
# (finding 1). Runs `DISPLAY=<persisted> xhost -SI:localuser:boxa-agent` and
# logs it visibly so this privileged change is auditable, never silent.
#
# Why a persisted display, not `$DISPLAY` (finding 1): `stop` frequently runs
# WITHOUT `$DISPLAY` in the ambient env — the detached Chrome-death watchdog,
# the container-stop closeout, or an SSH / other-terminal invocation. Gating
# the revoke on the teardown process's own `$DISPLAY` (the round-6/7 behaviour)
# made those common paths return early and LEAK the grant indefinitely. The
# display `start` actually granted on is persisted into the session-state JSON
# as `granted_display`, and teardown revokes against THAT value regardless of
# the ambient env. The single required argument is that persisted display.
#
# Gate: a persisted granted-display must exist for this session (passed in $1).
# If it is absent (empty / "null"), the session never granted — typically a
# non-graphical start that skipped the grant — so the revoke is a clean no-op.
# We DELIBERATELY do not re-check the ambient `$DISPLAY` here: doing so would
# reintroduce the leak. Native-Linux gating still applies (macOS/WSL2 never
# grant via xhost), as does xhost-present.
#
# Unlike the grant, a missing `xhost` here is NOT fatal: this runs on teardown
# / rollback paths where `_die`-ing would abort cleanup of the rest of the
# session. If `xhost` is absent we warn and no-op (there is nothing to revoke
# if the tool that would have granted access was never present). The revoke
# itself is idempotent — `xhost -SI:localuser:...` is harmless if the entry is
# already gone — so a stray double call cannot break anything; the
# reference-count gating at the call sites is what keeps normal multi-session
# operation from logging spurious revokes.
_revoke_agent_x_display_access() {
    local granted_display="${1:-}"
    local platform
    platform="$(host_platform::detect 2>/dev/null || true)"
    [ "$platform" = "linux" ] || return 0

    # No persisted granted-display for this session — nothing was granted (e.g.
    # a headless start with no `$DISPLAY`), so nothing to revoke. Env-independent
    # by design (finding 1): we never consult the ambient `$DISPLAY`.
    [ -n "$granted_display" ] && [ "$granted_display" != "null" ] || return 0

    if ! command -v xhost >/dev/null 2>&1; then
        _warn "agent-browser: xhost not found at teardown; cannot revoke boxa-agent X display access on ${granted_display} (it was never grantable). Skipping."
        return 0
    fi

    # Per-display broker-ownership gate (#12 review finding 3). Revoke ONLY when
    # the broker itself ADDED the grant for this display — i.e. the per-display
    # ownership marker exists (created in `_grant_agent_x_display_access` when
    # the pre-grant query showed boxa-agent NOT yet authorized). If the marker
    # is absent, boxa-agent was already authorized before the broker's first
    # grant (or the query failed and we took the safe path), so the broker must
    # NOT remove a pre-existing non-broker authorization — log and no-op. On a
    # genuine revoke we remove the marker so the next start re-evaluates
    # ownership from scratch.
    local marker
    marker="$(_xhost_ownership_marker_path "$granted_display")"
    if [ -z "$marker" ] || [ ! -e "$marker" ]; then
        _log "Not revoking boxa-agent X display access on ${granted_display}: the broker does not own this grant (pre-existing authorization, or it was never marker-owned). Leaving it intact."
        return 0
    fi

    _log "Revoking boxa-agent X display access (last agent-browser session ended; xhost -SI:localuser:boxa-agent on ${granted_display})..."
    # Retain-on-failure, mirroring the ufw slot's retain pattern (#12 review
    # finding 1): the ownership marker is the ONLY record that the broker added
    # this grant and is still responsible for tearing it down. Removing it when
    # `xhost -SI` FAILED (e.g. a `stop` over SSH with no usable X authorization)
    # would leave the grant active but make every future teardown/sweep treat it
    # as pre-existing (no marker → no revoke) → a PERMANENT leak. So delete the
    # marker ONLY AFTER the revoke succeeds; on failure keep it and warn, so a
    # later cmd_stop or the stale-session sweep retries the revoke.
    if DISPLAY="$granted_display" xhost -SI:localuser:boxa-agent >/dev/null; then
        # Clear the ownership marker now the broker-added grant is gone.
        rm -f -- "$marker" 2>/dev/null || true
        return 0
    fi
    # The actual `xhost -SI` FAILED (e.g. a `stop` over SSH with no usable X
    # authorization). Round-11 already retains the ownership MARKER so a later
    # teardown/sweep can retry; the caller must ALSO retain the session STATE FILE
    # that holds `granted_display`, else a repeated `stop` has no state to read and
    # cannot retry (#12 review P2). SIGNAL this distinct outcome to the caller with
    # rc 2 — distinct from rc 0 returned by every NO-OP path above ("nothing to
    # revoke", "no marker / not broker-owned", "xhost absent", "not linux"), none of
    # which need the state retained. Only this real-revoke failure does.
    _warn "agent-browser: could not revoke boxa-agent X access on ${granted_display}; will retry on next teardown/sweep (ownership marker retained; the grant may persist until then or until the X server resets)."
    return 2
}

# Revoke the shared per-uid X display grant ONLY when $1's container is the
# last agent-browser session going away. Centralises the reference-count check
# so every teardown / rollback path that needs it stays a one-liner and the
# "leave the grant for surviving sessions" rule lives in exactly one place.
#
# Gating with `_count_other_live_sessions` keeps concurrent same-uid sessions
# safe: while any OTHER container still has a session state file that is a
# display consumer, this returns without revoking, so a stop or a failed start
# never yanks display access out from under another live (or starting) session's
# Chrome.
#
# The display to revoke against is read from THIS session's state file
# (`granted_display`), not the ambient `$DISPLAY` (finding 1): teardown paths
# routinely run without `$DISPLAY` set. The optional second argument lets
# callers that already hold the value (cmd_stop captured it before nulling the
# file, the failed-start cleanup tracked it in `_CFS_GRANTED_DISPLAY`) pass it
# directly — avoiding a re-read of a file that may have been removed or
# rewritten. When omitted, it is read from the state file by container name.
#
# Per-display reference counting (finding: scope X-grant reference counting to
# the display): the grant is per-display, so we first determine WHICH display
# this session granted on (its persisted `granted_display`), then count only
# OTHER sessions whose `granted_display` matches THAT display. Display D is
# revoked iff no other live display-consumer session is using D. A session on a
# different display does not block this revoke (it has its own independently
# reference-counted grant), and a session that never granted (null display) is a
# consumer on no display. A session with no granted_display of its own has
# nothing to revoke — the count is then moot and the inner revoke no-ops.
_revoke_x_display_if_last_session() {
    local this_container="$1"
    local granted_display="${2:-}"
    # Resolve the display being torn down FIRST so the count is scoped to it.
    if [ -z "$granted_display" ]; then
        local this_state_file
        this_state_file="$(_state_file "$this_container")"
        granted_display="$(_state_get "$this_state_file" granted_display 2>/dev/null || true)"
    fi
    # The count→decide→revoke→clear-marker sequence is the TEARDOWN critical
    # section (#12 review finding 1): it runs under the shared X-grant lock so it
    # is mutually exclusive with a concurrent START's claim-write→grant. With
    # both serialized, this teardown either SEES a concurrently-starting peer's
    # claim (others>=1 → no revoke) or finishes revoking BEFORE that start grants
    # (the start then re-grants under the lock — correct). The marker read+delete
    # for finding 3 lives inside `_revoke_agent_x_display_access`, which we call
    # from within the locked region, so it too is serialized.
    # Propagate the locked body's rc verbatim (the flock wrapper returns `"$@"`'s
    # status): rc 2 == the actual `xhost -SI` FAILED → the caller retains the
    # session state for a later retry (#12 review P2); rc 0 == revoked or no-op.
    _with_xhost_grant_lock _revoke_x_display_if_last_session_locked \
        "$this_container" "$granted_display"
}

# The locked body of `_revoke_x_display_if_last_session` — see that function for
# the rationale. Kept as a separate function so `_with_xhost_grant_lock` can run
# it as a single command inside the flock subshell.
_revoke_x_display_if_last_session_locked() {
    local this_container="$1"
    local granted_display="${2:-}"
    # Count only OTHER consumers ON THIS DISPLAY. A peer on another display is
    # excluded, so it neither blocks D's revoke nor leaves D authorized forever.
    # "Not last consumer" is a NO-OP (rc 0, no retain): the surviving peer owns the
    # grant and will revoke it when it stops.
    local others
    others="$(_count_other_live_sessions "$this_container" "$granted_display")"
    [ "$others" -eq 0 ] || return 0
    # Propagate the inner rc verbatim: rc 2 == the actual `xhost -SI` FAILED, which
    # the caller (cmd_stop / sweep) reads to RETAIN the session state for a retry
    # (#12 review P2); rc 0 == revoked or a no-op that needs no retain.
    _revoke_agent_x_display_access "$granted_display"
}

# --- Consolidated failed-start cleanup (single teardown chokepoint) -----------
#
# cmd_start grants the shared X display BEFORE a long run of `set -e` steps
# (privileged dir setup, proxy staging, port allocation, Chrome/relay/bridge
# launch). Any of those can exit WITHOUT reaching an explicit rollback branch —
# a `set -e` abort, a `_die`, or a signal — and would otherwise leave
# boxa-agent authorized on the display though no session was ever
# established (finding 2). To make EVERY abort path converge to the same
# correct end state, cmd_start arms an EXIT trap on this one idempotent
# function right at the grant point and disarms it only on a fully-established
# session. The explicit rollback branches funnel through it too, so there is a
# single teardown chokepoint instead of path-by-path patches.
#
# It reads what cmd_start has allocated so far from the `_CFS_*` tracking
# variables (set as each resource comes up), and runs each step GUARDED so it
# no-ops when that resource was never allocated:
#   - close the container-side host-allow slot (if host_allow_ip recorded);
#   - release-or-retain the host ufw slot (only when a broker-owned subnet was
#     recorded), retaining the marker state file on a failed `sudo ufw delete`;
#   - kill the proxy / relay / Chrome (each only if its PID was recorded);
#   - remove the session profile + download dirs (if created);
#   - revoke the shared X grant if this is the last display consumer.
#
# Idempotency: a `_CFS_DONE` guard makes the body run AT MOST ONCE, so when an
# explicit branch calls it and then `exit 1`s (re-triggering the EXIT trap) the
# second invocation is a no-op — no double-revoke, no double-close, no
# double-rm. Every underlying step is itself idempotent too
# (`xhost -SI:...`, `ufw delete` of a missing rule, `rm -f`, `kill` of a dead
# pid), so even a forced re-run would be harmless. On a fully-established
# session cmd_start disarms the trap, so this never runs on success.
_CFS_DONE=0
_CFS_CONTAINER=""
_CFS_PROFILE_DIR=""
_CFS_DOWNLOAD_DIR=""
_CFS_CHROME_PID=""
_CFS_RELAY_PID=""
_CFS_PROXY_PID=""
# The proxy's listen port, tracked alongside `_CFS_PROXY_PID` so the cleanup can
# build the SAME `--listen 127.0.0.1:<port>` identity marker cmd_stop / the sweep
# use to confirm a recorded proxy PID still belongs to OUR proxy before killing
# it (PID may be reused by an unrelated boxa-agent process if the proxy already
# exited). `_CFS_PROFILE_DIR` (Chrome `--user-data-dir`) and `_CFS_CDP_PORT`
# (relay `TCP-LISTEN`) already carry the other two host-PID markers.
_CFS_PROXY_PORT=""
_CFS_HOST_ALLOW_IP=""
_CFS_CDP_PORT=""
_CFS_UFW_SLOT_SUBNET=""
# The in-container bridge socat PID, tracked as soon as cmd_start reads it back
# from the `docker exec -d` launch. Killed by the cleanup below via the SAME
# in-container kill path cmd_stop/sweep use, so a failed/aborted start never
# leaves socat orphaned bound to 127.0.0.1:9222 inside the container with no
# state to reclaim it from (a later start would then fail: port already bound).
_CFS_BRIDGE_PID_IN_CONTAINER=""
# The display `start` granted on, captured at grant time so the X revoke below
# targets it env-independently (finding 1) — the EXIT trap can fire from a
# context that has already lost `$DISPLAY`.
_CFS_GRANTED_DISPLAY=""
_cleanup_failed_start() {
    # Run-once guard: the explicit rollback branches call this directly and then
    # `exit 1`, which re-fires the EXIT trap on this same function — the guard
    # turns that second call into a no-op so nothing is closed/revoked twice.
    [ "$_CFS_DONE" = "1" ] && return 0
    _CFS_DONE=1

    [ -n "$_CFS_CONTAINER" ] || return 0

    # Container-side firewall slot (idempotent; the helper removes all matching
    # ACCEPT rules and no-ops when none exist or the container is gone).
    if [ -n "$_CFS_HOST_ALLOW_IP" ] && [ -n "$_CFS_CDP_PORT" ] \
        && _container_running "$_CFS_CONTAINER"; then
        docker exec -u root "$_CFS_CONTAINER" \
            /usr/local/bin/stop-agent-browser-host-allow \
            "$_CFS_HOST_ALLOW_IP" "$_CFS_CDP_PORT" 2>/dev/null || true
    fi

    # Host-side ufw slot: release the broker-OWNED slot, retaining the marker
    # state file for the next start's sweep when `sudo ufw delete` could not
    # complete (no-TTY sudo). When retained, mark the file Chrome-torn-down so
    # it is not counted as a display consumer by the X-revoke below or by any
    # other session (finding 1's invariant, applied on the start-rollback path
    # too). When released (or when no broker-owned slot was recorded) drop the
    # marker file entirely.
    local cfs_ufw_retain=0
    _release_or_retain_ufw_slot \
        "$_CFS_HOST_ALLOW_IP" "$_CFS_CDP_PORT" "$_CFS_UFW_SLOT_SUBNET" \
        || cfs_ufw_retain=1
    local cfs_state_file
    cfs_state_file="$(_state_file "$_CFS_CONTAINER")"
    # PRE-MARK the file Chrome-torn-down / non-consumer when retaining for the ufw
    # retry, BEFORE the X-revoke below counts other sessions (finding 1). The
    # actual REMOVE-vs-RETAIN decision is deferred to AFTER the X revoke so an
    # X-revoke failure can ALSO retain the file (it holds the granted_display a
    # retry needs), symmetric with cmd_stop / the sweep (#12 review P2).
    if [ "$cfs_ufw_retain" -eq 1 ]; then
        _mark_state_file_ufw_retry_only "$cfs_state_file"
    fi

    # Kill the launched host processes. Each kill is gated on BOTH a recorded
    # non-empty PID AND an identity check (`_pid_matches_marker`) — never bare
    # PID existence. If a tracked process already exited before this cleanup
    # runs, its PID may have been recycled by an UNRELATED boxa-agent process;
    # an unguarded `kill` would then terminate that bystander. This mirrors the
    # marker gate cmd_stop / `_sweep_if_stale` apply on the host side (and the
    # in-container `_pid_matches_marker_in_container` gate on the bridge kill
    # below) — REUSING the exact same per-process markers so the identity check
    # is consistent across every teardown path:
    #   Chrome — `--user-data-dir=<profile_dir>` (the unique session profile)
    #   relay  — `TCP-LISTEN:<cdp_port>`
    #   proxy  — `--listen 127.0.0.1:<proxy_port>`
    # boxa-agent owns the processes; `kill` exit status is ignored. A tracked
    # PID that is unset, or alive-but-reused, or already gone is a normal state
    # at cleanup time — SKIP the kill quietly (a plain `_log` note, never a
    # `_warn`) so there is no warn-spam for the expected dead-process case.
    if [ -n "$_CFS_CHROME_PID" ] \
        && _pid_matches_marker "$_CFS_CHROME_PID" "--user-data-dir=$_CFS_PROFILE_DIR"; then
        sudo -u boxa-agent kill "$_CFS_CHROME_PID" 2>/dev/null || true
    elif [ -n "$_CFS_CHROME_PID" ]; then
        _log "Failed-start cleanup: Chrome PID ${_CFS_CHROME_PID} already gone or reused; skipping kill."
    fi
    if [ -n "$_CFS_RELAY_PID" ] \
        && _pid_matches_marker "$_CFS_RELAY_PID" "TCP-LISTEN:${_CFS_CDP_PORT}"; then
        sudo -u boxa-agent kill "$_CFS_RELAY_PID" 2>/dev/null || true
    elif [ -n "$_CFS_RELAY_PID" ]; then
        _log "Failed-start cleanup: relay PID ${_CFS_RELAY_PID} already gone or reused; skipping kill."
    fi
    if [ -n "$_CFS_PROXY_PID" ] \
        && _pid_matches_marker "$_CFS_PROXY_PID" "--listen 127.0.0.1:${_CFS_PROXY_PORT}"; then
        sudo -u boxa-agent kill "$_CFS_PROXY_PID" 2>/dev/null || true
    elif [ -n "$_CFS_PROXY_PID" ]; then
        _log "Failed-start cleanup: proxy PID ${_CFS_PROXY_PID} already gone or reused; skipping kill."
    fi

    # Kill the in-container bridge socat via the SAME kill path cmd_stop/sweep
    # use (no second mechanism). Guarded: no-op when the bridge was never started
    # (PID unset) and when the container is already gone (the helper warns, does
    # not abort this cleanup). Without this, a `set -e` abort AFTER the bridge
    # launch but BEFORE the full state file is written would orphan socat bound
    # to 127.0.0.1:9222 inside the container — the marker is then removed, so no
    # later sweep can reclaim it and subsequent starts fail (port already bound).
    _kill_bridge_in_container "$_CFS_CONTAINER" "$_CFS_BRIDGE_PID_IN_CONTAINER"

    # Remove the ephemeral profile + download dirs (guarded by _is_managed_path
    # + the session prefix inside the helper; no-op when not yet created).
    _cleanup_session_dirs "$_CFS_PROFILE_DIR" "$_CFS_DOWNLOAD_DIR" "${_CFS_CONTAINER}-"

    # Remove the wrapper launch log too. Its content (if any) was already
    # surfaced by `_surface_launch_logs` before this cleanup ran, so dropping it
    # loses no diagnostics — and a failed start removes the state file below, so
    # without this no later stop/sweep could discover and clean it. Keeps the
    # SESSIONS_DIR free of orphaned per-session artifacts, matching the profile
    # dir removal above.
    rm -f -- "$SESSIONS_DIR/${_CFS_CONTAINER}.launch.log" 2>/dev/null || true

    # Revoke the shared per-uid X grant if no OTHER live display-consuming
    # session remains — DECOUPLED from the ufw-retain decision above: the
    # retain-marked file (this session's own, if retained) is excluded from the
    # display-consumer count, so a deferred ufw delete never keeps the grant
    # alive. The grant ran in cmd_start before any of these resources; on a
    # failed/aborted start it must not linger. Revoke against the captured
    # `_CFS_GRANTED_DISPLAY` (finding 1) — the trap may fire from a context that
    # has already lost the ambient `$DISPLAY`.
    #
    # Capture the rc (#12 review P2): rc 2 == the actual `xhost -SI` FAILED. The
    # state file is the only record of `granted_display`, so a failed revoke must
    # RETAIN it (marked non-consumer) for a later stop/sweep retry — symmetric with
    # cmd_stop and the sweep. Combined with the ufw-retain decision below: keep the
    # file if EITHER the ufw release failed OR the X revoke failed; otherwise remove
    # it as before.
    local cfs_x_revoke_rc=0
    _revoke_x_display_if_last_session "$_CFS_CONTAINER" "$_CFS_GRANTED_DISPLAY" \
        || cfs_x_revoke_rc=$?
    local cfs_x_retain=0
    [ "$cfs_x_revoke_rc" -eq 2 ] && cfs_x_retain=1
    if [ "$cfs_ufw_retain" -eq 1 ] || [ "$cfs_x_retain" -eq 1 ]; then
        # Ensure the retained file is marked non-consumer even when only the X
        # revoke failed (the ufw branch above already marked it in its own case).
        if [ "$cfs_x_retain" -eq 1 ]; then
            _mark_state_file_ufw_retry_only "$cfs_state_file"
        fi
        if [ "$cfs_x_retain" -eq 1 ]; then
            _warn "Failed-start cleanup: retaining state file ${cfs_state_file} (X grant revoke pending; will retry on next stop/sweep)."
        fi
    else
        rm -f -- "$cfs_state_file" 2>/dev/null || true
    fi
}

# --- Proxy provisioning ------------------------------------------------------

# Ensure the per-user proxy state dir exists and the canonical
# active-mode file is seeded with `default`. This is the user-visible
# source of truth that slice 05's `allow-for` will rewrite; it is NOT
# what the proxy reads at runtime (the proxy reads a staged copy under
# the boxa-agent-owned profile dir, see `_stage_proxy_inputs` below).
# Idempotent.
_ensure_proxy_user_state() {
    mkdir -p "$AGENT_PROXY_STATE_DIR"
    chmod 700 "$AGENT_PROXY_STATE_DIR" 2>/dev/null || true
    printf 'default\n' > "$AGENT_PROXY_MODE_FILE"
    chmod 600 "$AGENT_PROXY_MODE_FILE" 2>/dev/null || true
}

# Stage the allowlist and mode file into the session-scoped profile dir
# so the proxy (running as boxa-agent) can read them regardless of the
# developer's home / ~/.config permission bits.
#
# Without this snapshot the proxy fails open on a 0700 home: it cannot
# even traverse to ~/.config and treats the missing file as "empty
# allowlist" — default mode then denies everything, even what the user
# explicitly listed. Snapshotting at session start sidesteps the
# permissions question entirely.
#
# The snapshot is short-lived (session-scoped) and disposed at `stop`
# alongside the profile dir. Slice 05's `allow-for` will re-stage and
# SIGHUP the proxy.
_stage_proxy_inputs() {
    local profile_dir="$1"
    [ -n "$profile_dir" ] || return 1
    local staged_allowlist="${profile_dir}/allowed-domains.conf"
    local staged_mode="${profile_dir}/active-mode"

    # The proxy must always get a readable allowlist + mode file, even
    # when the user's allowlist is missing — an empty allowlist + default
    # mode is the correct default-deny posture.
    #
    # We touch as boxa-agent first (creating the 640 files in the 0700
    # profile dir), then pipe the user-side allowlist contents through
    # `sudo tee` so the source is read as the invoking user (who owns
    # ~/.config/boxa/...) and the destination is written as boxa-
    # agent. This sidesteps SC2024: `sudo -u ... tee dest <src` would
    # do the source-read in the invoking shell anyway, but the linter
    # warns about it because the redirect could mislead the reader.
    sudo -u boxa-agent install -m 640 /dev/null "$staged_allowlist"
    if [ -r "$AGENT_ALLOWLIST_PATH" ]; then
        cat -- "$AGENT_ALLOWLIST_PATH" \
            | sudo -u boxa-agent tee "$staged_allowlist" >/dev/null
        sudo -u boxa-agent chmod 640 "$staged_allowlist" 2>/dev/null || true
    fi

    sudo -u boxa-agent install -m 640 /dev/null "$staged_mode"
    printf 'default\n' \
        | sudo -u boxa-agent tee "$staged_mode" >/dev/null
    sudo -u boxa-agent chmod 640 "$staged_mode" 2>/dev/null || true
}

# Launch the forward proxy as `boxa-agent`. Echoes "<pid>" on success,
# returns non-zero if the proxy fails to come up within ~3s.
_start_proxy() {
    local profile_dir="$1" proxy_port="$2" launch_log="${3:-/dev/null}"
    [ -n "$profile_dir" ] || return 1
    [ -n "$proxy_port" ] || return 1
    [ -x "$AGENT_PROXY_BIN" ] || _die "agent-browser-proxy.py not executable at ${AGENT_PROXY_BIN}."
    local proxy_log_live="${profile_dir}/proxy.log"
    local staged_allowlist="${profile_dir}/allowed-domains.conf"
    local staged_mode="${profile_dir}/active-mode"

    # boxa-agent must own the live log file (the in-container `node`
    # user has no path to it; see ADR 0010 § Tamper-proof property).
    sudo -u boxa-agent touch "$proxy_log_live"
    sudo -u boxa-agent chmod 640 "$proxy_log_live" 2>/dev/null || true

    local detach
    detach="$(_detach_prefix)"
    # OUTER wrapper redirections (after the closing `'`) are NOT redundant with
    # the inner ones. The inner redirects only take effect once `sh -c` runs;
    # the backgrounded `sudo "$detach" sh -c …` inherits the parent's stdin
    # AND stdout/stderr first.
    #   - `</dev/null`: when the broker has a real controlling TTY (interactive
    #     shell), a detached `sudo`/`setsid` reading from that TTY in the
    #     background stalls before it ever execs the daemon — the process never
    #     spawns, pgrep finds nothing, the failure looks like an empty-log crash.
    #     Detaching the outer stdin makes the launch behave identically under a
    #     pipe and under a PTY.
    #   - `>"$launch_log" 2>&1`: a failure of `sudo`/`setsid`/`sh` BEFORE the
    #     inner redirects take hold (expired sudo creds, a policy rejection, a
    #     missing `setsid`) would otherwise be lost to /dev/null, and the empty
    #     inner logs would trip the misleading "display access" hint. Capturing
    #     the outer streams in a developer-readable log lets `_surface_launch_logs`
    #     show the real cause instead. The redirect TRUNCATES (`>`), so the log
    #     holds only THIS launch's wrapper output — never a stale warning from the
    #     earlier (successful) proxy launch. The log lives in the developer-owned
    #     SESSIONS_DIR because this redirect is applied by the broker's own shell,
    #     before `sudo` — the 0700 boxa-agent profile dir is unwritable here.
    # Every detached `sudo … &` launch in this file MUST detach the outer stdin
    # and capture the outer streams (watchdog/deliver/timer already do).
    #
    # SC2024 false positive: the outer `>"$launch_log"` is INTENTIONALLY applied
    # by this (developer) shell, not as root — the log is developer-owned in
    # SESSIONS_DIR. We do not want a privileged redirect here.
    # shellcheck disable=SC2024
    sudo -u boxa-agent "$detach" sh -c '
        exec "$1" \
            --listen "127.0.0.1:$2" \
            --allowlist "$3" \
            --mode-file "$4" \
            --log "$5" \
            </dev/null \
            >"$6/proxy.stdout.log" \
            2>"$6/proxy.stderr.log"
    ' agent-browser-proxy "$AGENT_PROXY_BIN" "$proxy_port" "$staged_allowlist" "$staged_mode" "$proxy_log_live" "$profile_dir" </dev/null >"$launch_log" 2>&1 &
    disown 2>/dev/null || true
    # The proxy is launched in the broker's MAIN shell — exactly like the
    # Chrome and relay launches in cmd_full_start — and its PID is reconciled
    # by the SEPARATE pgrep loop below. It is deliberately NOT wrapped in a
    # command substitution ("$(_start_proxy ...)"). A backgrounded setsid+exec
    # job whose lifetime is tied to a transient $() subshell races that
    # subshell's teardown on the subshell's exit; under an interactive zsh
    # parent on native Linux the proxy lost that race and was torn down before
    # it came up, surfacing as the silent "proxy failed to start" with an empty
    # stderr (it ran fine from a bash parent and on WSL2 — different scheduling
    # won the race). Same scheduling sensitivity is why "real forks before the
    # launch" papered over it. Running in the persistent main shell removes the
    # subshell entirely, so there is no exit to race. See ADR 0010 § Actor 3
    # "Launch in the broker's main shell, not a command substitution". The outer
    # `>"$launch_log" 2>&1` closes the wrapper's inherited terminal stdout/stderr
    # (no fd held open) while still capturing any pre-exec wrapper error; the
    # inner `sh -c` redirects the proxy's own streams to log files.

    # Reconcile PID via the unique listen-port arg in cmdline. The marker
    # mirrors the Chrome/relay reconciliation pattern.
    local proxy_pid="" proxy_retry
    local marker="--listen 127.0.0.1:${proxy_port}"
    for proxy_retry in 1 2 3 4 5 6 7 8 9 10; do
        : "$proxy_retry"
        proxy_pid="$(pgrep -f -- "$marker" 2>/dev/null | head -1 || true)"
        if [ -n "$proxy_pid" ] && _pid_alive_on_host "$proxy_pid"; then
            break
        fi
        proxy_pid=""
        sleep 0.2
    done
    [ -n "$proxy_pid" ] || return 1
    # Hand the PID back via a global rather than stdout: the caller must invoke
    # us as a plain statement (NOT in "$(...)"), so the backgrounded proxy above
    # lives in the broker's main shell instead of a transient subshell that
    # would race its own teardown (see the launch comment above).
    _START_PROXY_PID="$proxy_pid"
}

# --- Sweep stale session -----------------------------------------------------

# Remove a session-state file whose Chrome and bridge are both already
# dead. Called from `start` before refusing — matches ADR 0010 "the broker
# first sweeps for orphan processes from a stale session file". Returns 0
# if a sweep was needed AND completed (state file removed), 1 if either
# process is still alive (caller should refuse).
_sweep_if_stale() {
    local container="$1"
    local file
    file="$(_state_file "$container")"
    [ -f "$file" ] || return 0

    local chrome_pid bridge_pid relay_pid proxy_pid watchdog_pid profile_dir download_dir cdp_port proxy_port host_allow_ip ufw_slot_subnet container_name granted_display status starting_pid starting_pid_starttime
    chrome_pid="$(_state_get "$file" chrome_pid || true)"
    bridge_pid="$(_state_get "$file" bridge_pid_in_container || true)"
    relay_pid="$(_state_get "$file" relay_pid_host || true)"
    proxy_pid="$(_state_get "$file" proxy_pid || true)"
    watchdog_pid="$(_state_get "$file" watchdog_pid || true)"
    profile_dir="$(_state_get "$file" profile_dir || true)"
    download_dir="$(_state_get "$file" download_dir || true)"
    cdp_port="$(_state_get "$file" cdp_port_host || true)"
    proxy_port="$(_state_get "$file" proxy_port_host || true)"
    host_allow_ip="$(_state_get "$file" host_allow_ip || true)"
    ufw_slot_subnet="$(_state_get "$file" ufw_slot_subnet || true)"
    container_name="$(_state_get "$file" container || true)"
    [ -n "$container_name" ] || container_name="$container"
    # The X display this crashed session granted on (#12/#14 review finding 2).
    # The sweep releases its grant below, env-independently, just like every
    # other teardown path — see the revoke call after the processes are killed.
    granted_display="$(_state_get "$file" granted_display || true)"
    # An in-progress early starting-claim (#12 review P2). A `status: "starting"`
    # file has NO resource PIDs yet (Chrome/relay/proxy/bridge all null), so the
    # per-process liveness checks below would judge it stale and reclaim it — but
    # if the broker driving the start is still ALIVE that would race a genuinely
    # in-progress start (the round-8 claim) and yank its file. We therefore gate
    # on the recorded `starting_pid`: a LIVE, identity-matched one means the
    # start is still running (treat as NOT stale, refuse to sweep); a DEAD one —
    # or a PID that is alive but has been REUSED by an unrelated process (its
    # `/proc/<pid>/stat` starttime no longer matches the recorded one, #12 review
    # P2) — means the broker is gone and the claim is ABANDONED (fall through and
    # reclaim it, releasing any ufw slot and revoking the grant if last, exactly
    # like a crashed full session). `_starting_pid_is_live` is the same guard the
    # display-consumer predicate uses, so the two never disagree.
    status="$(_state_get "$file" status || true)"
    starting_pid="$(_state_get "$file" starting_pid || true)"
    starting_pid_starttime="$(_state_get "$file" starting_pid_starttime || true)"
    if [ "$status" = "starting" ] \
        && [ -n "$starting_pid" ] && [ "$starting_pid" != "null" ] \
        && _starting_pid_is_live "$starting_pid" "$starting_pid_starttime"; then
        return 1
    fi

    # Identity markers: cmdline substrings unique to this session. PID
    # reuse after reboot would otherwise make an unrelated process look
    # like our Chrome/relay/proxy. The bridge socat inside the container
    # is matched by cmdline via `_pid_matches_marker_in_container`.
    local chrome_marker="--user-data-dir=$profile_dir"
    local relay_marker="TCP-LISTEN:${cdp_port}"
    local bridge_marker="socat TCP-LISTEN:${BRIDGE_CONTAINER_PORT}"
    local proxy_marker="--listen 127.0.0.1:${proxy_port}"
    local watchdog_marker="agent-browser-watchdog.sh $container_name"

    local chrome_alive=false bridge_alive=false relay_alive=false proxy_alive=false watchdog_alive=false
    if [ -n "$chrome_pid" ] && _pid_matches_marker "$chrome_pid" "$chrome_marker"; then
        chrome_alive=true
    fi
    if _container_running "$container" \
        && [ -n "$bridge_pid" ] \
        && _pid_matches_marker_in_container "$container" "$bridge_pid" "$bridge_marker"; then
        bridge_alive=true
    fi
    if [ -n "$relay_pid" ] && [ "$relay_pid" != "null" ] \
        && _pid_matches_marker "$relay_pid" "$relay_marker"; then
        relay_alive=true
    fi
    if [ -n "$proxy_pid" ] && [ "$proxy_pid" != "null" ] \
        && [ -n "$proxy_port" ] && [ "$proxy_port" != "null" ] \
        && _pid_matches_marker "$proxy_pid" "$proxy_marker"; then
        proxy_alive=true
    fi
    if [ -n "$watchdog_pid" ] && [ "$watchdog_pid" != "null" ] \
        && _pid_matches_marker "$watchdog_pid" "$watchdog_marker"; then
        watchdog_alive=true
    fi

    if [ "$chrome_alive" = true ] || [ "$bridge_alive" = true ] \
        || [ "$relay_alive" = true ] || [ "$proxy_alive" = true ] \
        || [ "$watchdog_alive" = true ]; then
        return 1
    fi

    _warn "Sweeping stale session file for ${container} (Chrome=${chrome_pid:-?}, bridge=${bridge_pid:-?}, relay=${relay_pid:-?}, proxy=${proxy_pid:-?}, watchdog=${watchdog_pid:-?} all gone or reused)."

    # Cleaning up stale session resources from the prior crash: the
    # session-scoped profile/download dirs would otherwise accumulate
    # under /var/lib/boxa-agent/ across host crashes, leaking the
    # netlog and any half-written downloads from the dead session.
    # `_is_managed_path` blocks a corrupted state file from escalating
    # the sudo rm into arbitrary deletion; `sudo test -d` is needed
    # because the 0700 parent dirs block the developer from stat'ing
    # into the boxa-agent-owned tree without elevation.
    if [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] \
        && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-" \
        && sudo test -d "$profile_dir"; then
        _warn "Cleaning up stale session resources from ${profile_dir}..."
        sudo rm -rf -- "$profile_dir" || _warn "Failed to remove stale profile dir ${profile_dir}."
    fi
    if [ -n "$download_dir" ] && [ "$download_dir" != "null" ] \
        && _is_managed_path "$download_dir" "$AGENT_DOWNLOADS_DIR" "${container}-" \
        && sudo test -d "$download_dir"; then
        _warn "Cleaning up stale session resources from ${download_dir}..."
        sudo rm -rf -- "$download_dir" || _warn "Failed to remove stale download dir ${download_dir}."
    fi

    # Close any container-side firewall slot the crashed session left
    # behind. The next start picks a fresh random CDP port, so without
    # this the old ACCEPT for `host_allow_ip:cdp_port` would linger
    # until a container restart (init-firewall flushes iptables on
    # boot). The stop helper is idempotent — a no-op if the rule is
    # already gone, harmless if the container restarted between crash
    # and sweep.
    if [ -n "$host_allow_ip" ] && [ "$host_allow_ip" != "null" ] \
        && [ -n "$cdp_port" ] && [ "$cdp_port" != "null" ] \
        && _container_running "$container"; then
        _warn "Releasing stale container firewall slot for ${host_allow_ip}:${cdp_port}..."
        docker exec -u root "$container" \
            /usr/local/bin/stop-agent-browser-host-allow "$host_allow_ip" "$cdp_port" 2>/dev/null || true
    fi

    # Close any host-side ufw slot the crashed session left behind. Unlike
    # the container-side slot (flushed by init-firewall on container
    # restart), a host ufw rule persists across reboots, so a sweep that
    # didn't release it would accumulate a durable rule per crashed session.
    # Idempotent and guarded on the persisted subnet — no-op when the prior
    # session opened no slot. This is also the RETRY point for a slot whose
    # release failed during a prior cmd_stop (finding 1): cmd_stop retained
    # the state file precisely so this sweep — running interactively under
    # `start`, where sudo can authenticate — can finish the delete.
    local ufw_slot_release_failed=false
    _release_or_retain_ufw_slot "$host_allow_ip" "$cdp_port" "$ufw_slot_subnet" \
        || ufw_slot_release_failed=true

    # Watchdog log + pidfile cleanup. Same SESSIONS_DIR sibling layout
    # cmd_stop uses; harmless if the prior session never wrote them.
    rm -f -- "$SESSIONS_DIR/${container}.watchdog.pid" \
             "$SESSIONS_DIR/${container}.watchdog.log" \
             "$SESSIONS_DIR/${container}.launch.log" 2>/dev/null || true

    # Release the crashed session's persisted X display grant (#12/#14 review
    # finding 2). cmd_stop and the start-rollback paths already revoke-if-last;
    # the sweep was the missing path. Without this, when the replacement session
    # is headless or on a DIFFERENT display, the crashed session's old-display
    # `boxa-agent` authorization + ownership marker leak indefinitely. We reuse
    # the SAME locked last-session revoke the other teardown paths use (NOT a
    # bypass of the flock), so it honours the per-display ownership marker (only
    # revokes a grant the broker owned) and the retain-on-failure from finding 1
    # (a failed revoke KEEPS the marker for a later retry). The just-swept session
    # is NOT counted as a live consumer blocking its own revoke: every consumer of
    # this session is already dead (we only reach here when nothing is alive), and
    # `_count_other_live_sessions` excludes THIS container's own file by name — so
    # the stale session's now-dead Chrome cannot block releasing its own display.
    #
    # The X revoke is DECOUPLED from the ufw-retain decision below, mirroring
    # cmd_stop's round-6/finding-1 fix: every process of this stale session is
    # already dead, so it is no longer a display consumer regardless of whether
    # the host ufw slot could be released. A failed `sudo ufw delete` (sudo could
    # not authenticate during the sweep) must NOT leave the dead session's
    # broker-owned X authorization alive — the ufw-retain decision governs ONLY
    # whether the state file is kept for a ufw retry, never the X revoke.
    if [ "$ufw_slot_release_failed" = true ]; then
        # Mark the retained file Chrome-torn-down / ufw-retry-only BEFORE the
        # X-revoke below counts other sessions (mirrors cmd_stop): every process
        # of this session is already dead, so this file is no longer a display
        # consumer. Without the marker, this very session's retained file (and
        # any other session's revoke check) would still count it as a live
        # consumer and wrongly keep the shared grant alive.
        _mark_state_file_ufw_retry_only "$file"
        # Revoke even though the state file is retained for the ufw retry — the
        # retain decision keeps the file as the record of the durable host rule,
        # not as a display consumer. Same locked last-session helper, env-
        # independent, honouring the ownership marker + retain-on-revoke-failure.
        # The file is retained regardless here (the ufw slot is the reason), so an
        # X-revoke failure needs no separate retain — but surface it so the operator
        # knows the grant was NOT released and will be retried alongside the ufw
        # delete on the next sweep (#12 review P2).
        local ufw_branch_x_rc=0
        _revoke_x_display_if_last_session "$container" "$granted_display" || ufw_branch_x_rc=$?
        # Retain the stale state file (finding 1): removing it would re-orphan
        # the durable host rule. Returning 1 makes `start` refuse rather than
        # launch a new session over an unreclaimed firewall hole, surfacing the
        # problem instead of hiding it. The next start's sweep retries the delete.
        if [ "$ufw_branch_x_rc" -eq 2 ]; then
            _warn "Refusing to sweep ${file}: host ufw slot is still open AND the X grant revoke failed; state file retained for retry of BOTH on next stop/sweep."
        else
            _warn "Refusing to sweep ${file}: host ufw slot is still open and could not be released (X grant released; state file retained for ufw retry)."
        fi
        return 1
    fi

    # Revoke BEFORE discarding the state file (env-independent, like cmd_stop).
    # Capture the rc (#12 review P2): rc 2 == the actual `xhost -SI` FAILED. The
    # state file is the only record of `granted_display`, so a failed revoke must
    # RETAIN it (marked non-consumer) for a later stop/sweep retry rather than
    # remove it — symmetric with cmd_stop's X-retain and with the ufw-retain branch
    # above. Round-16's X-session token on the ownership marker keeps the retry
    # safe: if the X session changed meanwhile, the stale marker is cleared on the
    # next grant rather than wrongly revoked.
    local sweep_x_revoke_rc=0
    _revoke_x_display_if_last_session "$container" "$granted_display" || sweep_x_revoke_rc=$?
    if [ "$sweep_x_revoke_rc" -eq 2 ]; then
        # Mark the retained file Chrome-torn-down / non-consumer so it does not pin
        # the grant for OTHER sessions' revoke decisions while awaiting its own
        # retry (every process of this stale session is already dead anyway).
        _mark_state_file_ufw_retry_only "$file"
        _warn "Refusing to sweep ${file}: X grant revoke failed; state file retained (granted_display preserved) for retry on next stop/sweep."
        return 1
    fi

    rm -f -- "$file"
    return 0
}

# --- subcommand: start -------------------------------------------------------

cmd_start() {
    # `--no-open` suppresses the post-startup auto-open of listening
    # ports. Default is on: most start invocations want the URLs in
    # tabs, and users who don't can opt out per-session or alias the
    # flag in their shell.
    local container="" no_open=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --no-open) no_open=true; shift ;;
            --)        shift; break ;;
            -*)        _die "Unknown flag for start: $1" ;;
            *)         [ -z "$container" ] || _die "Unexpected positional: $1"
                       container="$1"; shift ;;
        esac
    done
    container="$(_require_container_arg "$container")"

    _container_exists "$container" \
        || _die "Container '${container}' does not exist. Start it first: boxa ${container#boxa-}"
    _container_running "$container" \
        || _die "Container '${container}' exists but is not running. Start it first: boxa ${container#boxa-}"

    mkdir -p "$SESSIONS_DIR"

    if ! _sweep_if_stale "$container"; then
        local file
        file="$(_state_file "$container")"
        # The sweep refuses for one of two reasons, both already detailed in
        # its own warnings above: a session is still live, or a stale session
        # left a host ufw slot that could not be released (finding 1). Point
        # at the state file and the sweep output rather than re-guessing here.
        _warn "Cannot start: a previous Agent-browser session for '${container}' could not be cleared."
        _warn "  State file: $file"
        _warn "  See the warning(s) above (live session, or an unreleased host ufw slot to delete by hand)."
        exit 1
    fi

    local chrome_bin
    chrome_bin="$(host_platform::chrome_binary)" \
        || _die "Chrome binary not found on host. See install instructions above."

    # Developer-readable wrapper launch log for the detached proxy/Chrome/relay
    # launches. Their OUTER stdin is detached (`</dev/null`) while their outer
    # stdout/stderr are captured here, so a pre-exec `sudo`/`setsid`/`sh` failure
    # is surfaced instead of discarded. Each launch TRUNCATES the log (`>`, not
    # `>>`), so it only ever holds the most recent launch's wrapper output —
    # never a stale benign warning from an earlier successful launch that a later
    # failure would misattribute. This is race-free because the launches are
    # strictly sequential: each reconcile loop blocks on a live PID before the
    # next launch begins, so the prior wrapper has already exec'd (and redirected
    # its own streams to the inner logs) before the next truncate. Lives in the
    # developer-owned SESSIONS_DIR (the redirect is applied by this shell, before
    # `sudo`) and is swept with the other per-container session files. Mirrors
    # ${container}.watchdog.log.
    local launch_log="$SESSIONS_DIR/${container}.launch.log"
    rm -f -- "$launch_log" 2>/dev/null || true

    id boxa-agent >/dev/null 2>&1 \
        || _die "OS user 'boxa-agent' missing. Run: bash ${BOXA_DIR}/install.sh"

    # Grant the boxa-agent uid access to the developer's X display (issue
    # 12). On Wayland/Xwayland and per-uid-authorized X servers the agent uid
    # is otherwise rejected with no readable X cookie. Per-uid, display-only;
    # Linux-native + $DISPLAY-gated; idempotent each launch. `_die`s if xhost
    # is missing (issue 13 provisions it) — never silent.
    #
    # Done HERE — before the proxy launches and before any session/profile
    # directory is created — so a grant failure (`_die`) leaks nothing: there
    # is no proxy process and no on-disk session state to roll back yet. The
    # grant only needs $DISPLAY + the agent uid (verified just above), so it
    # has no dependency on the proxy or session dirs and is safe to run early.
    #
    # Arm the consolidated failed-start cleanup on EXIT right AT the grant
    # (finding 2). From here until a fully-established session, ANY abnormal
    # exit — a `set -e` abort in the privileged dir setup / proxy staging /
    # port allocation below, a `_die`, or a signal — fires the trap, which runs
    # `_cleanup_failed_start`: it tears down whatever was allocated so far and,
    # crucially, revokes the X grant if this was the last display consumer, so
    # boxa-agent is never left authorized with no session. The explicit
    # rollback branches below funnel through the SAME idempotent function (its
    # run-once guard prevents any double cleanup when both fire). The trap is
    # disarmed on the success path at the end of cmd_start so an established
    # session KEEPS the grant.
    _CFS_DONE=0
    _CFS_CONTAINER="$container"
    _CFS_PROFILE_DIR=""
    _CFS_DOWNLOAD_DIR=""
    _CFS_CHROME_PID=""
    _CFS_RELAY_PID=""
    _CFS_PROXY_PID=""
    _CFS_PROXY_PORT=""
    _CFS_HOST_ALLOW_IP=""
    _CFS_CDP_PORT=""
    _CFS_UFW_SLOT_SUBNET=""
    _CFS_BRIDGE_PID_IN_CONTAINER=""
    _CFS_GRANTED_DISPLAY=""

    # Compute the display the grant will run on, mirroring the grant's gates
    # (native Linux + `$DISPLAY` set). This is the value persisted as
    # `granted_display` and the value every later revoke targets — capturing it
    # ONCE here keeps the persisted display and the actual grant in lockstep, and
    # makes teardown independent of whatever `$DISPLAY` (if any) the stopping
    # process happens to have (finding 1). Empty for a non-graphical / non-Linux
    # start, in which case nothing is granted and every revoke is a no-op.
    local granted_display="" start_platform
    start_platform="$(host_platform::detect 2>/dev/null || true)"
    if [ "$start_platform" = "linux" ] && [ -n "${DISPLAY:-}" ]; then
        # Persist the CANONICAL display (#12 review P2): the screen-number suffix
        # is irrelevant to the per-server xhost grant, so storing `:0` for both
        # `:0` and `:0.0` makes every later reference-count / marker / revoke key
        # off ONE display identity — two sessions on aliases of the same physical
        # display correctly count as peers. The grant itself still runs on the
        # actual `$DISPLAY`, and `xhost` accepts the canonical `:0` form too.
        granted_display="$(_canonical_display "$DISPLAY")"
    fi
    _CFS_GRANTED_DISPLAY="$granted_display"

    # Write the EARLY starting-claim BEFORE the grant (the convergent mechanism
    # for both findings). It (a) persists granted_display so any later teardown
    # revokes against the right display env-independently (finding 1), and (b)
    # makes this session count as a display consumer to a concurrently-starting
    # sibling's revoke-if-last check the instant the file lands — before Chrome's
    # PID is known — so a sibling's rollback cannot revoke the shared grant out
    # from under this in-progress start (finding 2). The ufw crash-window marker
    # and the full state write below overwrite this same file, carrying
    # granted_display forward.
    local start_state_file
    start_state_file="$(_state_file "$container")"

    # Arm the EXIT trap BEFORE the claim/grant so an abort between them still
    # tears the claim down and revokes the grant.
    trap '_cleanup_failed_start' EXIT
    # START critical section (#12 review finding 1): the claim-write + the
    # pre-grant ownership check (finding 3) + the single `xhost +SI` grant run as
    # ONE region under the shared X-grant lock, mutually exclusive with any
    # concurrent teardown's count→revoke. Keeping it small (no Chrome launch /
    # docker exec inside the lock) is what lets the lock stay held only across
    # the claim+grant. A grant failure inside the locked subshell `_die`s there
    # (printing its actionable message) and the subshell returns non-zero; we
    # propagate by exiting, which fires the EXIT trap → `_cleanup_failed_start`.
    # `$$` is the cmd_start broker PID — the process that owns this start from
    # the early claim through to the full-state write below. Captured HERE in the
    # main shell (not inside the lock subshell, where $BASHPID differs) and
    # persisted into the claim as `starting_pid` (#12 review P2): the starting
    # claim counts as a display consumer only while this PID is alive, so a
    # broker killed mid-start leaves an ABANDONED claim that is expired (not
    # counted) and reclaimed by the next sweep, instead of pinning the grant.
    _with_xhost_grant_lock _start_x_claim_and_grant_locked \
        "$start_state_file" "$container" "$granted_display" "$$" \
        || exit 1

    # Profile + downloads dir, owned by boxa-agent. /var/lib/boxa-agent
    # may not exist before the first session — create it once, then chown.
    # `install -d` is the portable atomic equivalent of mkdir+chmod+chown,
    # but requires the target's parent to exist; we layer manually so the
    # first time through still works on a fresh host.
    # Trailing colon on chown = "owner's primary group", portable on Linux
    # (GNU coreutils) and macOS (BSD chown). On Linux the primary group is
    # `boxa-agent` (--user-group in lib/host-platform.sh); on macOS
    # sysadminctl assigns `staff`. Either way no extra group lookup is needed.
    local agent_parent
    for agent_parent in "$AGENT_PROFILES_DIR" "$AGENT_DOWNLOADS_DIR"; do
        if [ ! -d "$agent_parent" ]; then
            sudo mkdir -p "$agent_parent"
            sudo chown boxa-agent: "$agent_parent"
            sudo chmod 700 "$agent_parent"
        fi
    done

    # Netlog archive dir under /var/log so the developer can read past
    # sessions via group membership (parallels allow-for log layout).
    # Group-readable bit on the dir lets future slices add group provisioning
    # without revisiting this code; for slice 03 the local developer must
    # already be in the boxa-agent group to read individual files.
    if [ ! -d "$AGENT_NETLOG_ARCHIVE_DIR" ]; then
        sudo mkdir -p "$AGENT_NETLOG_ARCHIVE_DIR"
        sudo chown boxa-agent: "$AGENT_NETLOG_ARCHIVE_DIR"
        sudo chmod 750 "$AGENT_NETLOG_ARCHIVE_DIR"
    fi

    # Defensive retention sweep. cmd_stop is the canonical enforcement
    # point (runs after the new session's files land in the archive), but
    # we also prune here so an archive that was over-cap before this
    # broker version landed — or that grew via a crash that skipped the
    # stop-time prune — gets trimmed on next start. Best-effort: failure
    # warns but does not block the new session.
    _prune_archive_for "$container" "$AGENT_ARCHIVE_KEEP_PER_CONTAINER"

    local ts profile_dir download_dir netlog_path
    ts="$(date -u +"%Y%m%dT%H%M%SZ")"
    profile_dir="${AGENT_PROFILES_DIR}/${container}-${ts}"
    download_dir="${AGENT_DOWNLOADS_DIR}/${container}-${ts}"
    # Why: `netlog_path` in the state JSON tracks the LIVE location during
    # the session; `cmd_stop` moves the file to the archive dir and the
    # state file is removed in the same step, so there is no post-archive
    # consumer of the field. Keeping it as the live path keeps the field
    # meaningful while the session is running (e.g. `status` could surface it).
    netlog_path="${profile_dir}/netlog.json"
    sudo -u boxa-agent mkdir -p "$profile_dir" "$download_dir"
    # Record the dirs for the consolidated failed-start cleanup (finding 2):
    # from now on an abort removes them via the EXIT trap.
    _CFS_PROFILE_DIR="$profile_dir"
    _CFS_DOWNLOAD_DIR="$download_dir"

    # Seed Default/Preferences with the download dir. ADR 0010 lists
    # `--download-default-directory` as the mechanism, but in practice
    # modern Chrome only consistently honours that path when it is
    # ALSO present in the profile's Preferences JSON — the CLI flag
    # alone is treated as an initial-state hint and can be overridden
    # by the embedded prefs on first run. Writing the prefs eagerly
    # closes the gap so user-initiated downloads land in the ephemeral
    # dir we delete on `stop`, instead of escaping to ~boxa-agent.
    # `prompt_for_download: false` keeps the agent from blocking on a
    # save dialog inside a CDP-driven Chrome.
    sudo -u boxa-agent mkdir -p "$profile_dir/Default"
    sudo -u boxa-agent tee "$profile_dir/Default/Preferences" >/dev/null <<EOF
{
  "download": {
    "default_directory": "${download_dir}",
    "prompt_for_download": false
  },
  "profile": {
    "default_content_setting_values": {
      "automatic_downloads": 1
    }
  }
}
EOF

    local cdp_port
    cdp_port="$(_pick_free_port)"
    [ -n "$cdp_port" ] || _die "Failed to pick a free host port for CDP."
    # Track the CDP port for the consolidated failed-start cleanup (it is the
    # port half of both the container-side host-allow slot and the host ufw
    # slot the cleanup releases).
    _CFS_CDP_PORT="$cdp_port"

    # Provision per-user proxy state + start the forward proxy before
    # Chrome, so the Chrome `--proxy-server=http://127.0.0.1:<proxy_port>`
    # flag points at a listener that already exists. ADR 0010 § Actor 3.
    _ensure_proxy_user_state
    _stage_proxy_inputs "$profile_dir"
    local proxy_port proxy_pid proxy_log_live
    proxy_port="$(_pick_free_port)"
    [ -n "$proxy_port" ] || _die "Failed to pick a free host port for the proxy."
    proxy_log_live="${profile_dir}/proxy.log"

    _log "Starting Agent-browser proxy on 127.0.0.1:${proxy_port}..."
    # Invoked as a plain statement (NOT "$(...)") so the backgrounded proxy runs
    # in this main shell, decoupled from any transient subshell teardown; the
    # reconciled PID comes back via the _START_PROXY_PID global.
    _START_PROXY_PID=""
    if ! _start_proxy "$profile_dir" "$proxy_port" "$launch_log"; then
        # Surface the proxy's captured stderr + stdout BEFORE cleanup wipes
        # the profile dir holding them (same race as the Chrome path), then
        # funnel through the single consolidated teardown (finding 2). It
        # removes the session dirs and revokes the X grant if this was the last
        # display consumer; the EXIT trap re-fires it on `exit 1` but the
        # run-once guard makes that a no-op.
        _surface_launch_logs "proxy" "$profile_dir" \
            "${profile_dir}/proxy.stderr.log" "${profile_dir}/proxy.stdout.log" "$launch_log"
        _cleanup_failed_start
        exit 1
    fi
    # Proxy is up — track its PID + listen port so the cleanup can kill it on any
    # later abort, guarded by the same `--listen 127.0.0.1:<port>` identity marker
    # cmd_stop / the sweep use (the port lets the cleanup rebuild that marker).
    proxy_pid="$_START_PROXY_PID"
    _CFS_PROXY_PID="$proxy_pid"
    _CFS_PROXY_PORT="$proxy_port"

    _log "Starting Host agent Chrome for ${container} on 127.0.0.1:${cdp_port}..."

    # Forward the caller's GUI session credentials so Chrome (running as
    # boxa-agent) can open a window on the user's display. `sudo -u`
    # would otherwise reset the environment and Chrome would fail to
    # connect to the X11/Wayland/WSLg socket.
    #
    # WSL2 + WSLg (the user's primary platform): WAYLAND_DISPLAY +
    # XDG_RUNTIME_DIR point at /mnt/wslg, world-readable by default so
    # boxa-agent can use them as-is. DISPLAY=:0 + WSLg's Xwayland
    # socket are equally accessible. PULSE_SERVER points Chrome at WSLg's
    # audio socket; without preserving it, GUI works but media is silent
    # under sudo-launched boxa-agent Chrome.
    #
    # Native Linux X11: DISPLAY + XAUTHORITY. The user's Xauthority cookie
    # must be readable by boxa-agent — outside the scope of this slice
    # to provision automatically (slice 03 hardening + install.sh sudoers
    # additions). If it isn't readable, Chrome errors out with a clear
    # X11 connection failure in chrome.stderr.log; the CDP smoke test
    # then fails and we roll back below.
    #
    # macOS Quartz: needs `open -na Chrome ... --user` or a logged-in
    # boxa-agent session; that work also lives in slice 03.
    local detach
    detach="$(_detach_prefix)"
    # SC2024 false positive: the outer `>"$launch_log"` is INTENTIONALLY applied
    # by this (developer) shell, not as root — the log is developer-owned in
    # SESSIONS_DIR. We do not want a privileged redirect here.
    # shellcheck disable=SC2024
    sudo --preserve-env=DISPLAY,XAUTHORITY,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,XDG_SESSION_TYPE,PULSE_SERVER \
        -u boxa-agent "$detach" sh -c '
        exec "$1" \
            --remote-debugging-port="$2" \
            --remote-debugging-address=127.0.0.1 \
            --user-data-dir="$3" \
            --no-first-run \
            --no-default-browser-check \
            --disable-extensions \
            --disable-sync \
            --disable-background-networking \
            --disable-component-update \
            --disable-features=NativeMessaging,OptimizationHints,AutofillServerCommunication \
            --download-default-directory="$4" \
            --log-net-log="$5" \
            --proxy-server="http://127.0.0.1:$6" \
            --proxy-bypass-list="$7" \
            --ozone-platform=x11 \
            --test-type \
            </dev/null \
            >"$3/chrome.stdout.log" \
            2>"$3/chrome.stderr.log"
    ' agent-browser-chrome "$chrome_bin" "$cdp_port" "$profile_dir" "$download_dir" "$netlog_path" "$proxy_port" "$AGENT_PROXY_BYPASS_LIST" </dev/null >"$launch_log" 2>&1 &
    disown 2>/dev/null || true

    # Reconcile Chrome's actual PID via pgrep on the unique --user-data-dir
    # path. Necessary because `$!` above is the wrapping sudo/setsid/sh
    # process tree, not Chrome itself. The profile_dir is session-scoped
    # so the match is unambiguous. Loop briefly to cover Chrome's startup
    # latency (cold launch can take a second on a busy host).
    local chrome_pid="" chrome_retry
    for chrome_retry in 1 2 3 4 5 6 7 8 9 10; do
        : "$chrome_retry"
        chrome_pid="$(pgrep -f -- "--user-data-dir=$profile_dir" 2>/dev/null \
            | head -1 || true)"
        [ -n "$chrome_pid" ] && break
        sleep 0.3
    done
    if [ -z "$chrome_pid" ]; then
        # Surface Chrome's real stderr AND stdout BEFORE any cleanup removes
        # the profile dir that holds the logs — otherwise the developer sees
        # a bare "stderr:" with nothing after it (the original silent-crash
        # symptom). The empty-logs case prints a display/X-auth hint. Then
        # funnel through the consolidated teardown (kills the proxy via the
        # tracked PID, removes the dirs, revokes X-if-last).
        _surface_launch_logs "Chrome" "$profile_dir" \
            "$profile_dir/chrome.stderr.log" "$profile_dir/chrome.stdout.log" "$launch_log"
        _cleanup_failed_start
        exit 1
    fi
    # Chrome is up — track its PID so the cleanup kills it on any later abort.
    _CFS_CHROME_PID="$chrome_pid"

    # Host-side relay. On Docker Desktop (most WSL2 setups, macOS),
    # `host.docker.internal` resolves to a magic VM-routed address that
    # Docker Desktop forwards to host loopback directly, so the in-container
    # socat reaches Chrome on 127.0.0.1:${cdp_port} with no host-side help.
    # On native Linux (and on WSL2 with Docker CE, which install.sh also
    # supports), `--add-host=...=host-gateway` resolves to a docker bridge
    # gateway IP — could be the devproxy network's gateway or, in some
    # configurations, the host's default-bridge gateway. Chrome (bound to
    # 127.0.0.1) does not accept either. A small socat relay listening on
    # exactly the IP `host.docker.internal` resolves to, forwarding to
    # 127.0.0.1, closes the gap without exposing Chrome to a routable
    # interface (those docker bridge IPs are host-private).
    #
    # Detection: ask the target container what `host.docker.internal`
    # resolves to. If the resolved IP is host-owned (we can bind to it),
    # we need the relay. On Docker Desktop the resolved IP belongs to
    # the LinuxKit VM, not the host — the socat bind will fail there and
    # we treat that as "no relay needed".
    local relay_pid=""
    local resolved_hdi
    # `getent ahostsv4` (vs `getent hosts`) forces IPv4-only resolution. On
    # Docker Desktop dual-stack setups host.docker.internal carries both an
    # IPv4 (192.168.65.254) and an IPv6 ULA; glibc per RFC 6724 returns the
    # IPv6 first, but Docker Desktop only forwards the IPv4 magic IP, the
    # in-container bridge below uses `TCP4:`, and the firewall slot helper
    # rejects anything that isn't dotted IPv4. Pinning to v4 here keeps all
    # three consumers (relay bind, firewall ACCEPT, socat upstream) on the
    # same address.
    resolved_hdi="$(docker exec "$container" \
        getent ahostsv4 host.docker.internal 2>/dev/null | awk '{print $1}' | head -1 || true)"

    if [ -n "$resolved_hdi" ] && [ "$resolved_hdi" != "127.0.0.1" ]; then
        # Host-side socat is required for the relay. On native Linux /
        # Docker-CE-under-WSL2 it's the only path that makes the in-container
        # bridge reach Chrome on loopback. Surface a clear install hint up
        # front so the user doesn't see the more confusing CDP smoke-test
        # failure later.
        if ! command -v socat >/dev/null 2>&1; then
            # `_die` exits → the EXIT trap fires _cleanup_failed_start, which
            # kills the tracked Chrome/proxy PIDs, removes the session dirs, and
            # revokes the X grant if this was the last display consumer. No
            # inline teardown needed (finding 2 — single chokepoint).
            _die "host socat not found. Install it (Debian/Ubuntu: sudo apt-get install -y socat; Fedora/RHEL: sudo dnf install -y socat; Arch: sudo pacman -S socat; macOS: brew install socat). It is required for the Agent-browser host relay on this platform."
        fi
        _log "Starting host relay on ${resolved_hdi}:${cdp_port} -> 127.0.0.1:${cdp_port}..."

        # Same sudo + detach pattern as Chrome above: the redirects target
        # boxa-agent-owned files, so they must happen inside the sudo'd
        # shell. The bind-address restricts the listener to the docker
        # bridge interface — not LAN-reachable, not loopback-shared with
        # the user's host services.
        #
        # SC2024 false positive: the outer `>"$launch_log"` is INTENTIONALLY
        # applied by this (developer) shell, not as root — the log is
        # developer-owned in SESSIONS_DIR. We do not want a privileged redirect.
        # shellcheck disable=SC2024
        sudo -u boxa-agent "$detach" sh -c '
            exec socat \
                "TCP-LISTEN:$2,bind=$1,fork,reuseaddr" \
                "TCP:127.0.0.1:$2" \
                </dev/null \
                >"$3/relay.stdout.log" \
                2>"$3/relay.stderr.log"
        ' agent-browser-relay "$resolved_hdi" "$cdp_port" "$profile_dir" </dev/null >"$launch_log" 2>&1 &
        disown 2>/dev/null || true

        local relay_retry
        for relay_retry in 1 2 3 4 5 6 7 8 9 10; do
            : "$relay_retry"
            relay_pid="$(pgrep -f -- "TCP-LISTEN:${cdp_port},bind=${resolved_hdi}" 2>/dev/null \
                | head -1 || true)"
            [ -n "$relay_pid" ] && break
            sleep 0.2
        done

        # Empty relay_pid here has two very different causes that the wrapper
        # launch log tells apart:
        #   - launch_log NON-EMPTY: `sudo`/`setsid`/`sh` failed BEFORE socat ran
        #     (expired sudo creds, policy rejection, missing setsid). On this
        #     host the relay is REQUIRED — host.docker.internal resolves to a
        #     host-owned IP, so without the relay the in-container bridge cannot
        #     reach Chrome and the CDP smoke test below fails with only a generic
        #     error. Surface the real cause now so it is not lost (mirrors the
        #     proxy/Chrome wrapper-failure path), then fall through to the same
        #     CDP-driven rollback.
        #   - launch_log EMPTY: socat itself ran but exited within the poll
        #     window — the usual cause is "address not host-owned" (Docker
        #     Desktop case, where the magic IP is not host-bindable). That is
        #     benign: the container reaches Chrome via Docker Desktop's magic
        #     forwarding. socat's own bind error (if any) lives in relay.stderr.log
        #     and is deliberately NOT surfaced here. Log and proceed untracked.
        if [ -z "$relay_pid" ]; then
            local relay_launch_body=""
            relay_launch_body="$(cat "$launch_log" 2>/dev/null || true)"
            if [ -n "$relay_launch_body" ]; then
                _warn "Host relay failed to launch (sudo/setsid/sh error before socat started):"
                printf '%s\n' "$relay_launch_body" | sed 's/^/  /' >&2
                _warn "  The relay is required on this host (host.docker.internal -> ${resolved_hdi}); the CDP smoke test will fail without it."
            else
                _log "Host relay did not bind ${resolved_hdi}:${cdp_port}; proceeding without it (Docker Desktop magic forwarding expected)."
            fi
        fi
        # Track the relay PID (may be empty — the cleanup guards on it) so a
        # later abort tears it down too.
        _CFS_RELAY_PID="$relay_pid"
    fi

    # Container-side firewall slot for the CDP target IP+port. ADR 0001's
    # default-deny OUTPUT chain only accepts traffic to 172.18.0.0/24 (the
    # Docker bridge subnet) and the DNS-driven allowed-domains ipset. On
    # Docker Desktop, host.docker.internal resolves to 192.168.65.254 — a
    # magic IP outside both — so the in-container socat bridge below would
    # hit "No route to host" (ICMP admin-prohibited rendered as
    # EHOSTUNREACH) and the CDP smoke test would time out. Open a
    # session-scoped exception mirroring the allow-for window pattern
    # (start-allow-for-window.sh): insert ACCEPT for tcp/$cdp_port to
    # $resolved_hdi just before the final OUTPUT REJECT, and remove it in
    # cmd_stop / on rollback. Scoping to a single TCP port keeps the hole
    # as narrow as the bridge needs — arbitrary host services on the same
    # magic IP remain firewalled. On native Linux this is a no-op
    # redundancy — resolved_hdi is the bridge gateway, already covered by
    # the 172.18.0.0/24 ACCEPT — but the rule add is idempotent so we
    # don't branch on platform.
    local host_allow_ip=""
    if [ -n "$resolved_hdi" ] && [ "$resolved_hdi" != "127.0.0.1" ]; then
        if ! docker exec -u root "$container" \
                /usr/local/bin/start-agent-browser-host-allow "$resolved_hdi" "$cdp_port"; then
            _warn "Failed to open container firewall slot for ${resolved_hdi}:${cdp_port}; rolling back Chrome, relay, and proxy."
            _warn "  (If you just pulled new boxa code, run 'boxa update' to rebuild the container with the new helper script.)"
            # The container-side slot OPEN failed, so there is nothing to close
            # there (_CFS_HOST_ALLOW_IP is still unset). The consolidated
            # cleanup kills the tracked Chrome/relay/proxy PIDs, removes the
            # dirs, and revokes X-if-last.
            _cleanup_failed_start
            exit 1
        fi
        host_allow_ip="$resolved_hdi"
        # The container-side host-allow slot is now OPEN — record the IP so the
        # cleanup closes it (and reuses it as the ufw slot's relay IP) on abort.
        _CFS_HOST_ALLOW_IP="$host_allow_ip"
    fi

    # Host-side ufw/INPUT slot for the CDP relay. Symmetric to the
    # container-side OUTPUT slot above, but on the host's INPUT side: when
    # ufw is active with default-deny INPUT, the SYN from the in-container
    # socat bridge to the relay (host.docker.internal:<cdp_port>) arrives on
    # the custom Docker bridge (`br-<hash>`, NOT docker0) and is dropped
    # before any user rule. We open a scoped, ephemeral rule for exactly the
    # relay IP + CDP TCP port FROM the container's real bridge subnet — not
    # a whole-host/all-ports allow. Only relevant when a host relay exists
    # (host_allow_ip set, i.e. native Linux / Docker-CE-under-WSL2); on
    # Docker Desktop host.docker.internal is VM-routed and ufw isn't in the
    # container→host path, so the slot is skipped. Persisted as
    # `ufw_slot_subnet` (the relay IP and port reuse host_allow_ip /
    # cdp_port_host) so cmd_stop and every rollback path can delete the
    # exact rule later. Failure is surfaced with a fallback hint, never
    # swallowed, but does NOT roll the session back: on a misconfigured
    # sudo the developer can still open the rule by hand.
    #
    # `ufw_slot_subnet` is persisted ONLY when THIS session actually added
    # the rule. If an administrator had already configured the identical
    # scoped rule by hand, `_open_host_ufw_slot` returns 2 ("already
    # existed") and we leave `ufw_slot_subnet` empty so cmd_stop / rollback
    # never deletes a rule the session did not create.
    local ufw_slot_subnet=""
    if [ -n "$host_allow_ip" ] && _host_ufw_active; then
        local ufw_subnet="" ufw_rc=0
        ufw_subnet="$(_container_bridge_subnet "$container" "$host_allow_ip" || true)"
        if [ -n "$ufw_subnet" ]; then
            # Close the crash window between `ufw allow` and the full state
            # write below. The slot's identifying triple (subnet + relay IP +
            # CDP port) is fully known HERE, before we open the rule. Persist
            # it into the session state file FIRST so that if the broker is
            # interrupted or the host crashes after the rule is added but
            # before the complete state JSON is written, the rule is still
            # reclaimable by the next start's stale-session sweep.
            #
            # BUT (finding 1): at marker-write time we do NOT yet know whether
            # WE will own the rule. `_open_host_ufw_slot` may report rc 2 — an
            # admin had already configured the identical rule — in which case
            # the rule must NOT be deleted on reclaim. Writing the subnet into
            # the deletable `ufw_slot_subnet` here would, on a crash between
            # this write and the `ufw allow` return, let the sweep delete a
            # possibly-admin rule whose origin is unknown. So we record the
            # subnet ONLY in `ufw_slot_pending_subnet` — a field the
            # deletion paths (stop/sweep/rollback) IGNORE — and leave the
            # deletable `ufw_slot_subnet` null. The slot is PROMOTED to owned
            # (subnet moved into `ufw_slot_subnet`) only AFTER ufw confirms it
            # ADDED the rule (rc 0). A crash while pending therefore leaks at
            # most a narrow, correctly-scoped broker rule — never clobbers an
            # admin rule, the deliberate safe trade-off.
            #
            # The marker records the process IDs/ports that are ALREADY LIVE at
            # this point (finding 1): the proxy and Chrome are running, and the
            # host relay too when one was needed. Recording their real PIDs is
            # what makes the sweep safe — _sweep_if_stale only reclaims a
            # session when every recorded PID is dead (it returns 1, refusing
            # to sweep, the moment one is still alive). If we left these null,
            # an interruption between this marker and the full state write would
            # let the next start misclassify the still-live session as stale,
            # tear down its live profile dir + firewall rule, and launch a
            # second session over the orphaned proxy/Chrome. With the real PIDs:
            #   - interrupted but still live → sweep sees them alive, refuses;
            #   - genuinely crashed (PIDs dead) → sweep kills nothing live and
            #     reclaims the rule + dirs, exactly as intended.
            # PIDs NOT yet started at this line (bridge_pid_in_container,
            # watchdog_pid) stay null — they are launched below, and recording
            # fabricated PIDs would let the sweep kill unrelated processes.
            # created_at is the marker's partial/incomplete signal: the full
            # state write at the end of cmd_start adds it and overwrites this
            # marker. The normal rollback paths below still call
            # _close_host_ufw_slot, so there is no double-close: this marker
            # only adds recoverability, it does not itself close the slot.
            local ufw_marker_file ufw_marker_relay_pid="null"
            [ -n "$relay_pid" ] && ufw_marker_relay_pid="$relay_pid"
            ufw_marker_file="$(_state_file "$container")"
            # `granted_display` carried forward from the early starting-claim so
            # this overwrite does not drop the persisted display the teardown
            # paths revoke against (finding 1).
            local ufw_marker_display_json="null"
            [ -n "$granted_display" ] && ufw_marker_display_json="\"${granted_display}\""
            cat > "$ufw_marker_file" <<EOF
{
  "container": "${container}",
  "granted_display": ${ufw_marker_display_json},
  "chrome_pid": ${chrome_pid},
  "bridge_pid_in_container": null,
  "relay_pid_host": ${ufw_marker_relay_pid},
  "proxy_pid": ${proxy_pid},
  "watchdog_pid": null,
  "cdp_port_host": ${cdp_port},
  "proxy_port_host": ${proxy_port},
  "profile_dir": "${profile_dir}",
  "download_dir": "${download_dir}",
  "host_allow_ip": "${host_allow_ip}",
  "ufw_slot_subnet": null,
  "ufw_slot_pending_subnet": "${ufw_subnet}",
  "active_network_window": null
}
EOF
            # Capture the exact rc: 0 = newly added, 2 = pre-existing
            # (skip persist), 1 = failed. Guard against set -e so rc 1/2
            # don't abort cmd_start.
            ufw_rc=0
            _open_host_ufw_slot "$host_allow_ip" "$cdp_port" "$ufw_subnet" || ufw_rc=$?
            case "$ufw_rc" in
                0)
                    # ufw confirmed it ADDED the rule — WE own it. Promote the
                    # marker's pending subnet to the deletable `ufw_slot_subnet`
                    # (clearing the pending field) and record it in the local
                    # var so the final state write and every teardown path
                    # reclaim it (finding 1).
                    ufw_slot_subnet="$ufw_subnet"
                    _promote_ufw_marker_slot "$ufw_marker_file" "$ufw_subnet"
                    # Record the broker-OWNED slot subnet so the consolidated
                    # cleanup releases-or-retains it on a later abort (only the
                    # rc-0 owned case; rc 2/1 leave _CFS_UFW_SLOT_SUBNET empty so
                    # the cleanup never deletes an admin/non-existent rule).
                    _CFS_UFW_SLOT_SUBNET="$ufw_subnet"
                    _log "Opened host ufw slot: tcp from ${ufw_subnet} to ${host_allow_ip} port ${cdp_port}."
                    ;;
                2)
                    # An equivalent admin rule already existed. Leave it
                    # untouched on stop — do NOT record a deletion slot. Drop
                    # the crash-window marker's PENDING claim (the owned
                    # `ufw_slot_subnet` was never set) so a crash after this
                    # point can't make the sweep delete the admin's rule.
                    # Logged so the no-op is auditable, not silent.
                    _clear_ufw_marker_pending "$ufw_marker_file"
                    _log "Host ufw rule already present (admin-managed): tcp from ${ufw_subnet} to ${host_allow_ip} port ${cdp_port}; leaving it in place (will not be removed on stop)."
                    ;;
                *)
                    # The `ufw allow` failed: no rule was added by us, so the
                    # crash-window marker must not claim a deletable slot. Drop
                    # the pending claim; `ufw_slot_subnet` stays empty.
                    _clear_ufw_marker_pending "$ufw_marker_file"
                    _warn "Failed to open the automatic host ufw slot for ${host_allow_ip}:${cdp_port}."
                    _warn_ufw_slot_fallback "$container" "$host_allow_ip" "$cdp_port" "$ufw_subnet"
                    ;;
            esac
        else
            _warn "Failed to open the automatic host ufw slot for ${host_allow_ip}:${cdp_port}."
            _warn_ufw_slot_fallback "$container" "$host_allow_ip" "$cdp_port" "$ufw_subnet"
        fi
    fi

    # In-container bridge: socat inside the container's netns, listening on
    # 127.0.0.1:9222, forwarding to host.docker.internal:<cdp_port>.
    # --add-host=host.docker.internal:host-gateway (added unconditionally
    # in docker-run.sh) makes this work on native Linux via the relay
    # above; on Docker Desktop the hostname is built-in. ADR 0010 § Actor 2.
    #
    # `docker exec -d` failures (container died between gate and exec,
    # image missing socat) must NOT escape set -e before rollback. Wrap
    # in an if/then/exit so the rollback path is reachable on every
    # failure mode below.
    # Force IPv4 (`TCP4:`) for the upstream side. Docker Desktop on WSL2
    # gives `host.docker.internal` a dual-stack response — both an IPv4
    # (192.168.65.254) and an IPv6 ULA (fdc4:...:254). Linux glibc per
    # RFC 6724 prefers IPv6, but Docker Desktop's forwarding to the host
    # loopback Chrome only covers IPv4. Without TCP4 the in-container
    # socat happily connects to the IPv6 address, never reaches host
    # Chrome, and exits — leaving the CDP smoke test below to fail.
    _log "Starting in-container bridge: ${container}:127.0.0.1:${BRIDGE_CONTAINER_PORT} -> host.docker.internal:${cdp_port}"
    if ! docker exec -d "$container" \
        socat \
            "TCP-LISTEN:${BRIDGE_CONTAINER_PORT},bind=127.0.0.1,fork,reuseaddr" \
            "TCP4:host.docker.internal:${cdp_port}"; then
        _warn "docker exec -d socat failed in ${container}; rolling back Chrome, relay, and proxy."
        # Single consolidated teardown (finding 1+2): closes the container-side
        # slot (via _CFS_HOST_ALLOW_IP), releases-or-retains the host ufw slot
        # (marking the state file Chrome-torn-down/ufw-retry-only when retained
        # so it is excluded from the X display-consumer count), kills the
        # tracked PIDs, removes the dirs, and revokes the X grant if this was
        # the last display consumer — DECOUPLED from the ufw-retain decision.
        _cleanup_failed_start
        exit 1
    fi

    # docker exec -d returns immediately and doesn't expose the in-container
    # PID. Re-read it via pgrep once socat has had a moment to register.
    local bridge_pid="" bridge_retry
    for bridge_retry in 1 2 3 4 5; do
        : "$bridge_retry"
        bridge_pid="$(docker exec "$container" \
            pgrep -nf "socat TCP-LISTEN:${BRIDGE_CONTAINER_PORT}" 2>/dev/null || true)"
        [ -n "$bridge_pid" ] && break
        sleep 0.2
    done
    if [ -z "$bridge_pid" ]; then
        _warn "Bridge socat did not register inside ${container}; rolling back Chrome, relay, and proxy."
        # Same single consolidated teardown as the socat-exec rollback above.
        _cleanup_failed_start
        exit 1
    fi
    # Track the in-container bridge PID NOW, so any later `set -e` abort or
    # `_die` before the full state file is written still tears the bridge down
    # via _cleanup_failed_start (it would otherwise orphan socat on 9222 inside
    # the container with no reclaimable state). The full state write below also
    # persists it so cmd_stop / the sweep can reclaim it on the success path.
    _CFS_BRIDGE_PID_IN_CONTAINER="$bridge_pid"

    local created_at
    created_at="$(_iso_utc_now)"

    # Spawn the Chrome-death watchdog. Polls Chrome PID every
    # AGENT_WATCHDOG_INTERVAL_DEFAULT seconds; on Chrome exit (user
    # closed the window, crash, OOM) it invokes `broker stop` for
    # graceful proxy/relay/firewall teardown. Without it the user
    # closing the Chrome window leaves the session in a half-alive
    # state — proxy/relay still running, state file claiming the
    # session is up, and `boxa agent-browser status` reporting
    # Chrome `(dead)` with no automatic remediation. Best-effort:
    # if the watchdog cannot be spawned (script missing, fork failure)
    # we proceed without it — the user can still manually `stop`.
    #
    # Runs as the invoking developer (NOT under sudo -u boxa-agent)
    # so the watchdog's exec-of-broker-stop resolves SESSIONS_DIR /
    # state file paths against the developer's XDG_STATE_HOME — the
    # same paths cmd_start wrote into. Watchdog needs no elevated
    # privileges: ps -p / /proc reads work cross-user, and broker
    # stop will sudo where needed.
    #
    # PID capture is via pidfile written by the watchdog itself
    # (first line in agent-browser-watchdog.sh). pgrep against the
    # script name would race with the spawn wrapper's own cmdline
    # (`setsid`/`nohup`/`sh -c` all carry the watchdog script path as
    # an arg), occasionally returning the wrapper PID instead.
    local watchdog_pid=""
    if [ -x "$AGENT_WATCHDOG_SCRIPT" ]; then
        local watchdog_detach
        watchdog_detach="$(_detach_prefix)"
        local watchdog_log="$SESSIONS_DIR/${container}.watchdog.log"
        local watchdog_pidfile="$SESSIONS_DIR/${container}.watchdog.pid"
        # Stale pidfile cleanup from any prior session that crashed
        # before pidfile removal. The sweep above already covered
        # the prior session's processes; this just removes the file.
        rm -f -- "$watchdog_pidfile" 2>/dev/null || true
        $watchdog_detach "$AGENT_WATCHDOG_SCRIPT" \
            "$container" "$chrome_pid" "$AGENT_BROKER_SELF" "$watchdog_pidfile" \
            </dev/null >>"$watchdog_log" 2>&1 &
        disown 2>/dev/null || true

        # Poll the pidfile for ~1s. Watchdog writes it as its very
        # first action, so missing pidfile after 1s = spawn failure.
        local wd_retry
        for wd_retry in 1 2 3 4 5; do
            : "$wd_retry"
            if [ -s "$watchdog_pidfile" ]; then
                watchdog_pid="$(cat "$watchdog_pidfile" 2>/dev/null || true)"
                [ -n "$watchdog_pid" ] && break
            fi
            sleep 0.2
        done
        if [ -z "$watchdog_pid" ]; then
            _warn "Watchdog spawn failed (Chrome exit will not auto-trigger stop; manual 'boxa agent-browser stop' required if you close the window)."
        fi
    fi

    # Write state JSON. `active_network_window` stays null until slice 05
    # adds the network-window machinery. `relay_pid_host` is an addition
    # over the ADR's listed shape — host-side relay PID for native Linux
    # only; null elsewhere — needed so `stop` can clean it up.
    # `proxy_log_path` records the LIVE log location during the session
    # (under the ephemeral profile dir); `cmd_stop` archives it under
    # /var/log/boxa/agent-browser/ alongside the netlog and removes
    # the state file in the same step, so there is no post-archive
    # consumer of the field — keeping it as the live path matches the
    # `netlog_path` convention.
    local relay_pid_json="null"
    [ -n "$relay_pid" ] && relay_pid_json="$relay_pid"
    local host_allow_ip_json="null"
    [ -n "$host_allow_ip" ] && host_allow_ip_json="\"${host_allow_ip}\""
    # Persist the bridge subnet of the host ufw slot so cmd_stop can delete
    # the exact scoped rule. Null when no slot was opened (ufw inactive/
    # absent, no host relay, or the open failed). Mirrors host_allow_ip.
    local ufw_slot_subnet_json="null"
    [ -n "$ufw_slot_subnet" ] && ufw_slot_subnet_json="\"${ufw_slot_subnet}\""
    local watchdog_pid_json="null"
    [ -n "$watchdog_pid" ] && watchdog_pid_json="$watchdog_pid"
    # Carry the persisted granted_display forward into the final state so a
    # later `stop` (often without an ambient `$DISPLAY`) revokes against the
    # right display (finding 1). The established session is identified by a live
    # `chrome_pid` (the display-consumer predicate), so we drop the transient
    # `status: "starting"` claim here.
    local granted_display_json="null"
    [ -n "$granted_display" ] && granted_display_json="\"${granted_display}\""
    local state_file
    state_file="$(_state_file "$container")"
    cat > "$state_file" <<EOF
{
  "container": "${container}",
  "granted_display": ${granted_display_json},
  "chrome_pid": ${chrome_pid},
  "bridge_pid_in_container": ${bridge_pid},
  "relay_pid_host": ${relay_pid_json},
  "proxy_pid": ${proxy_pid},
  "watchdog_pid": ${watchdog_pid_json},
  "cdp_port_host": ${cdp_port},
  "proxy_port_host": ${proxy_port},
  "profile_dir": "${profile_dir}",
  "download_dir": "${download_dir}",
  "netlog_path": "${netlog_path}",
  "proxy_log_path": "${proxy_log_live}",
  "host_allow_ip": ${host_allow_ip_json},
  "ufw_slot_subnet": ${ufw_slot_subnet_json},
  "created_at": "${created_at}",
  "active_network_window": null
}
EOF

    # End-to-end smoke test of the CDP path from inside the container.
    # Detects both relay misconfig (host.docker.internal pointing to a
    # non-host-owned IP without Docker Desktop magic) and Chrome CDP
    # listener bring-up failures.
    #
    # 15s wallclock budget. Cold-start CDP bringup occasionally needs
    # several seconds even though Chrome is healthy and already pushing
    # HTTP traffic via the proxy. Bail immediately if the Chrome PID is
    # gone — no point waiting on a listener that will never come up.
    local cdp_check="" cdp_deadline cdp_now
    cdp_deadline=$(($(date +%s) + 15))
    while :; do
        if cdp_check="$(docker exec "$container" \
            curl -sf --max-time 1 "http://127.0.0.1:${BRIDGE_CONTAINER_PORT}/json/version" 2>/dev/null)" \
            && [ -n "$cdp_check" ]; then
            break
        fi
        cdp_check=""
        if ! _pid_alive_on_host "$chrome_pid"; then
            _warn "Chrome PID ${chrome_pid} exited before CDP became reachable; aborting smoke-test wait."
            break
        fi
        cdp_now="$(date +%s)"
        [ "$cdp_now" -ge "$cdp_deadline" ] && break
        sleep 0.3
    done

    # CDP unreachable means the session is unusable. Tear down everything
    # we started and surface a clear error rather than leaving the user
    # with a half-broken session whose `status` reports "alive".
    if [ -z "$cdp_check" ]; then
        _warn "CDP NOT reachable from inside ${container}:127.0.0.1:${BRIDGE_CONTAINER_PORT}."
        _warn "  Rolling back the session (Chrome, relay, bridge)."
        _warn "  Diagnose with:"
        _warn "    docker exec ${container} curl -v http://127.0.0.1:${BRIDGE_CONTAINER_PORT}/json/version"
        _warn "    docker exec ${container} getent hosts host.docker.internal"
        # Common failure on native Linux with ufw: the container sits on a
        # custom Docker bridge (devproxy, br-<hash>) rather than docker0,
        # so the SYN from container to host.docker.internal arrives on
        # `br-<hash>` and ufw's default-deny INPUT drops it before it
        # reaches any user rule keyed to `-i docker0`. The broker now opens
        # an automatic scoped slot earlier (issue 14), so this fallback hint
        # only fires when ufw is active AND that auto-slot did NOT get
        # created (open failed, or no host relay was needed) — in which case
        # the developer may need to add the scoped rule by hand. Only fires
        # when Chrome is still alive (Chrome death is a different failure
        # mode whose stderr was already dumped above; a ufw hint would
        # mislead). Skipped on macOS because Docker Desktop's VM forwarding
        # magic bypasses host-side pf for container→host (ufw is inactive
        # there, so _host_ufw_active short-circuits anyway).
        if [ -z "$ufw_slot_subnet" ] \
            && _pid_alive_on_host "$chrome_pid" \
            && _host_ufw_active; then
            local fallback_subnet=""
            fallback_subnet="$(_container_bridge_subnet "$container" "$host_allow_ip" || true)"
            _warn_ufw_slot_fallback "$container" "$host_allow_ip" "$cdp_port" "$fallback_subnet"
        fi
        # Inline rollback: cmd_stop expects the state file to exist; we
        # just wrote it (the full session state JSON above), so delegate to it
        # for the heavy lifting (kill the three processes, archive logs, close
        # both firewall slots, remove the state file). cmd_stop also owns the X
        # display revoke (now decoupled from the ufw-retain decision) — do NOT
        # revoke here too, or a last-session teardown would double-log.
        #
        # DISARM the consolidated-cleanup EXIT trap first (finding 2): from this
        # point the full session state file exists and cmd_stop is the canonical
        # teardown. Without disarming, the `exit 1` below would re-fire the trap
        # AFTER cmd_stop has already removed the state file and revoked the
        # grant — a redundant second teardown. Disarming keeps cmd_stop the
        # single owner of this path.
        trap - EXIT
        _CFS_DONE=1
        cmd_stop "$container"
        exit 1
    fi

    # Session is fully established (CDP reachable, state JSON written). DISARM
    # the consolidated-cleanup EXIT trap so a normal successful return KEEPS the
    # X grant and the running session (finding 2). The trap only ever fires on
    # an abnormal/early exit between the grant and this point; from here the
    # session is real and owned by cmd_stop / the watchdog. `_CFS_DONE=1` is a
    # belt-and-braces guard in case any later code re-arms or the trap survives.
    trap - EXIT
    _CFS_DONE=1

    local platform
    platform="$(host_platform::detect 2>/dev/null || true)"
    if [ "$platform" = "wsl2" ]; then
        local work_area fit_result
        work_area="$(_windows_primary_work_area || true)"
        if [ -n "$work_area" ]; then
            if fit_result="$(_fit_chrome_window_to_work_area "$cdp_port" "$work_area" 2>&1)"; then
                _log "  WSLg window fit:           ${fit_result}"
            else
                _warn "WSLg window fit failed: ${fit_result}"
            fi
        else
            _warn "WSLg window fit skipped: could not read Windows primary screen working area."
        fi
    fi

    _log "Agent-browser session started."
    _log "  Chrome PID (host):         ${chrome_pid}"
    [ -n "$relay_pid" ] && _log "  Relay PID (host):          ${relay_pid}"
    _log "  Proxy PID (host):          ${proxy_pid}"
    [ -n "$watchdog_pid" ] && _log "  Watchdog PID (host):       ${watchdog_pid} (Chrome poll ${AGENT_WATCHDOG_INTERVAL_DEFAULT}s)"
    _log "  Bridge PID (in container): ${bridge_pid}"
    _log "  CDP (host):                127.0.0.1:${cdp_port}"
    _log "  Proxy (host):              127.0.0.1:${proxy_port} (default mode)"
    _log "  CDP (in container):        127.0.0.1:${BRIDGE_CONTAINER_PORT}"
    _log "  Profile dir:               ${profile_dir}"
    _log "  Proxy log (live):          ${proxy_log_live}"
    _log "  State:                     ${state_file}"
    _log "  CDP reachable from container: yes"

    if [ "$no_open" = false ]; then
        _auto_open_listening_ports "$container" "$cdp_port"
    fi
}

# --- Network window helpers --------------------------------------------------

# Re-snapshot the user's allowlist into the session-scoped staged copy
# so the SIGHUP triggered by `allow-for` also picks up any edits the
# user made to `agent-browser-allowed-domains.conf` since session
# start. Mode file is NOT touched — the allow-for caller owns its
# rewrite. Best-effort: a missing user-side allowlist leaves the
# staged file at its prior contents (or empty if no prior contents).
_restage_allowlist_only() {
    local profile_dir="$1"
    [ -n "$profile_dir" ] || return 1
    _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" \
        || _die "Refusing to re-stage allowlist outside the managed profile parent."

    local staged_allowlist="${profile_dir}/allowed-domains.conf"
    if [ ! -r "$AGENT_ALLOWLIST_PATH" ]; then
        return 0
    fi
    # Truncate then refill, matching the staging shape used at session
    # start. `install -m 640 /dev/null` would zero the file but
    # piping the user's contents through `sudo -u boxa-agent tee`
    # both refills and respects the destination's owner.
    cat -- "$AGENT_ALLOWLIST_PATH" \
        | sudo -u boxa-agent tee "$staged_allowlist" >/dev/null \
        || _warn "Failed to re-stage allowlist to ${staged_allowlist}; proxy will keep prior allowlist."
    sudo -u boxa-agent chmod 640 "$staged_allowlist" 2>/dev/null || true
}

# Compose the JSON form of the mode-file. The proxy daemon's _read_mode
# parses either this JSON or the slice-04 legacy plain-text form; we
# write JSON exclusively from slice 05 onward so the proxy can enforce
# expiry directly without waiting on the host-side timer.
_mode_file_json() {
    local mode="$1" expires_at="${2:-}"
    if [ -z "$expires_at" ] || [ "$expires_at" = "null" ]; then
        printf '{"mode":"%s","expires_at":null}\n' "$mode"
    else
        printf '{"mode":"%s","expires_at":"%s"}\n' "$mode" "$expires_at"
    fi
}

# Write the staged mode file (the one the proxy actually reads, under
# the session profile dir, owned by boxa-agent) and the user-state
# copy (the user's record under ~/.local/state). The staged copy is
# canonical for proxy behaviour; the user-state copy is the historical
# `~/.local/state` record slice 04 introduced.
#
# `_is_managed_path` validates the staged path against the profile-dir
# anchor so a tampered session-state JSON cannot redirect the sudo tee
# at an arbitrary location.
_write_mode_file_pair() {
    local profile_dir="$1" mode="$2" expires_at="${3:-}"
    [ -n "$profile_dir" ] || return 1
    _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" \
        || _die "Refusing to write mode file outside the managed profile parent: ${profile_dir}"

    local staged="${profile_dir}/active-mode"
    local payload
    payload="$(_mode_file_json "$mode" "$expires_at")"
    printf '%s' "$payload" \
        | sudo -u boxa-agent tee "$staged" >/dev/null \
        || _die "Failed to write staged mode file ${staged}."
    sudo -u boxa-agent chmod 640 "$staged" 2>/dev/null || true

    mkdir -p "$AGENT_PROXY_STATE_DIR"
    printf '%s' "$payload" > "$AGENT_PROXY_MODE_FILE"
    chmod 600 "$AGENT_PROXY_MODE_FILE" 2>/dev/null || true
}

# Update active_network_window inside the session-state JSON. Uses
# python3 (already a host dependency per mkcert / dns-install) so we
# avoid a jq dependency the broker explicitly tolerates the absence of.
# `state_file` is rewritten atomically via tmp + rename.
_state_set_network_window() {
    local state_file="$1" mode="$2" started_at="${3:-}" expires_at="${4:-}" timer_pid="${5:-}" harvest_log="${6:-}"
    [ -f "$state_file" ] || return 1
    python3 - "$state_file" "$mode" "$started_at" "$expires_at" "$timer_pid" "$harvest_log" <<'PY'
import json
import os
import sys

state_file, mode, started_at, expires_at, timer_pid, harvest_log = sys.argv[1:7]
with open(state_file, "r", encoding="utf-8") as fh:
    state = json.load(fh)

if mode == "null":
    state["active_network_window"] = None
else:
    window = {
        "started_at": started_at,
        "expires_at": expires_at,
    }
    if timer_pid and timer_pid != "null":
        try:
            window["timer_pid"] = int(timer_pid)
        except ValueError:
            window["timer_pid"] = None
    else:
        window["timer_pid"] = None
    if harvest_log and harvest_log != "null":
        window["harvest_log_path"] = harvest_log
    state["active_network_window"] = window

tmp = state_file + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
os.replace(tmp, state_file)
PY
}

# Read the nested timer_pid from active_network_window. Returns empty
# when the window is closed or jq is missing AND the python fallback
# fails (defensive — python3 is a documented host dep). Errors are
# silenced because every call site treats empty as "no timer to kill".
_state_get_window_timer_pid() {
    local state_file="$1"
    [ -f "$state_file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r '.active_network_window.timer_pid // empty' "$state_file" 2>/dev/null
        return 0
    fi
    python3 - "$state_file" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    window = data.get("active_network_window")
    if window:
        pid = window.get("timer_pid")
        if pid is not None:
            print(pid)
except Exception:
    pass
PY
}

# --- Toast emission (slice 08) -----------------------------------------------

# Emit one agent-browser toast event (session-close or window-close) as a
# pending JSON for the host-side deliver script. Best-effort: every
# failure path returns 0 so notification dispatch never blocks the
# broker's stop or window-close flow. The pending dir is host-user-owned
# so no sudo is required; tmp + atomic rename keeps a half-written file
# from being picked up by a concurrent sweep.
#
# The pending JSON carries display fields only. The deliver script
# reconstructs the click-target path from the filename's
# `<container>-<ts_compact>` shape and the canonical archive / profile
# dirs (slice 08 AC #4) — the broker's `click_target_hint` is at most a
# diagnostic aid in the JSON; the deliver script never trusts it.
#
# Args:
#   $1 event           agent-browser-session-close | agent-browser-window-close
#   $2 container       boxa container name (already validated)
#   $3 ts_compact      session timestamp, [0-9]{8}T[0-9]{6}Z
#   $4 reason          for window-close: explicit-stop | timer-expiry | session-stop
#                      for session-close: explicit-stop | container-stop | unknown
#   $5 duration_secs   for session-close: integer seconds, or empty when unknown
#   $6 hint_path       diagnostic click-target hint (not trusted by deliver)
_emit_pending_event() {
    local event="$1" container="$2" ts_compact="$3" reason="${4:-}" duration_secs="${5:-}" hint_path="${6:-}"
    [ -n "$event" ] || return 0
    [ -n "$container" ] || return 0
    [ -n "$ts_compact" ] || return 0

    # Strict shape guard mirrors the deliver script's reconstruction
    # regex. Emitting a JSON the deliver script would later reject is a
    # silent dead-end; refuse early.
    case "$ts_compact" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
        *) _warn "agent-browser: refusing to emit event with malformed ts: ${ts_compact}"; return 0 ;;
    esac

    local kind=""
    case "$event" in
        agent-browser-session-close) kind="session" ;;
        agent-browser-window-close)  kind="window"  ;;
        *) _warn "agent-browser: refusing to emit unknown event: ${event}"; return 0 ;;
    esac

    mkdir -p "$AGENT_PENDING_DIR" 2>/dev/null || return 0
    chmod 700 "$AGENT_PENDING_DIR" 2>/dev/null || true

    # Per-emit suffix so a session that opens multiple network windows
    # (each producing its own window-close event) does not overwrite an
    # earlier pending that is still queued for retry. `date +%s%N`
    # is nanosecond-precision on GNU coreutils; on macOS BSD-date the
    # `%N` is literal — fall back to PID+RANDOM, which is still unique
    # enough at the per-broker-invocation granularity we need.
    local emit_ts
    emit_ts="$(date +%s%N 2>/dev/null || true)"
    case "$emit_ts" in
        *[!0-9]*|"") emit_ts="$(date +%s)$$${RANDOM}" ;;
    esac
    local pending="${AGENT_PENDING_DIR}/.pending-ab-${kind}-${container}-${ts_compact}-${emit_ts}.json"
    local pending_tmp
    pending_tmp="$(mktemp "${AGENT_PENDING_DIR}/.pending-ab-${kind}.XXXXXXXXXX" 2>/dev/null)" || return 0

    local duration_field='null'
    case "$duration_secs" in
        ''|*[!0-9]*) ;;
        *) duration_field="$duration_secs" ;;
    esac

    {
        printf '{\n'
        printf '  "event": "%s",\n' "$event"
        printf '  "container": "%s",\n' "$container"
        printf '  "session_ts": "%s",\n' "$ts_compact"
        printf '  "reason": "%s",\n' "$reason"
        printf '  "duration_seconds": %s,\n' "$duration_field"
        printf '  "click_target_hint": "%s",\n' "$hint_path"
        printf '  "emitted_at": "%s"\n'  "$(_iso_utc_now)"
        printf '}\n'
    } > "$pending_tmp" || { rm -f -- "$pending_tmp"; return 0; }
    chmod 600 "$pending_tmp" 2>/dev/null || true
    mv -- "$pending_tmp" "$pending" 2>/dev/null || { rm -f -- "$pending_tmp"; return 0; }

    if [ -x "$AGENT_DELIVER_BIN" ]; then
        local detach
        detach="$(_detach_prefix)"
        "$detach" "$AGENT_DELIVER_BIN" "$pending" </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi
    return 0
}

# Compute seconds elapsed between two ISO-8601 UTC timestamps of the
# `%Y-%m-%dT%H:%M:%SZ` shape produced by `_iso_utc_now`. Echoes the
# integer count on stdout, empty string on parse failure. Used by
# `cmd_stop` to populate the session-close event's duration field.
_iso_duration_seconds() {
    local start="$1" end="$2"
    [ -n "$start" ] || return 0
    [ -n "$end" ] || return 0
    local start_epoch end_epoch
    start_epoch="$(date -u -d "$start" +%s 2>/dev/null || true)"
    if [ -z "$start_epoch" ]; then
        start_epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$start" +%s 2>/dev/null || true)"
    fi
    end_epoch="$(date -u -d "$end" +%s 2>/dev/null || true)"
    if [ -z "$end_epoch" ]; then
        end_epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$end" +%s 2>/dev/null || true)"
    fi
    [ -n "$start_epoch" ] && [ -n "$end_epoch" ] || return 0
    [ "$end_epoch" -ge "$start_epoch" ] || return 0
    printf '%s\n' $(( end_epoch - start_epoch ))
}

# Extract the session's compact-ISO ts suffix from a managed profile dir
# path, e.g. `/var/lib/boxa-agent/profiles/foo-20260519T123456Z` ->
# `20260519T123456Z`. Echoes empty when the path doesn't follow the
# expected `<container>-<ts>` tail or the ts portion doesn't match the
# strict shape. Used as the canonical event-id timestamp by the toast
# emitters so the deliver script can reconstruct trusted archive paths.
_session_ts_from_profile_dir() {
    local profile_dir="$1" container="$2"
    [ -n "$profile_dir" ] || return 0
    [ -n "$container" ] || return 0
    local basename suffix
    basename="${profile_dir##*/}"
    case "$basename" in
        "${container}-"*) suffix="${basename#"${container}-"}" ;;
        *) return 0 ;;
    esac
    case "$suffix" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) printf '%s\n' "$suffix" ;;
        *) return 0 ;;
    esac
}

# Spawn the host-side window-expiry timer. Sleeps until `expires_at`,
# then rewrites the staged mode file to `default` and SIGHUPs the
# proxy. Detached via setsid + nohup so the calling shell exiting does
# not take the timer with it.
#
# The timer runs as the invoking user (not boxa-agent) because it
# needs `sudo -u boxa-agent` to rewrite the staged mode file; sudo
# from a boxa-agent shell would be a privilege escalation the broker
# avoids.
#
# Echoes "<pid>" on success. PID identifies the bash subshell, which
# in turn holds the sleep child; killing the bash pid kills the sleep
# child as well (the trap below makes that explicit).
_start_window_timer() {
    local proxy_pid="$1" proxy_port="$2" profile_dir="$3" seconds="$4" state_file="$5" container="$6"
    [ -n "$proxy_pid" ] || return 1
    [ -n "$proxy_port" ] || return 1
    [ -n "$profile_dir" ] || return 1
    [ -n "$seconds" ] || return 1
    [ -n "$state_file" ] || return 1
    [ -n "$container" ] || return 1

    local proxy_marker="--listen 127.0.0.1:${proxy_port}"
    _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" \
        || _die "Refusing to spawn timer with profile_dir outside managed parent."

    local detach mode_default_json
    detach="$(_detach_prefix)"
    mode_default_json="$(_mode_file_json default)"

    # The single-quoted body below is intentionally not expanded by the
    # outer shell: every $1..$7 / $sleep_pid is expanded inside the inner
    # `sh -c` once it starts running. Shellcheck would warn on the
    # trap's $sleep_pid otherwise.
    # shellcheck disable=SC2016
    "$detach" sh -c '
        # Trap so any signal received here (most importantly SIGTERM
        # from `cmd_stop` killing the timer pid) propagates to the
        # `sleep` child — otherwise the sleep keeps running detached.
        # Single quotes around the trap body defer $sleep_pid expansion
        # to the moment the trap fires; with double quotes the inner
        # shell would substitute the (still-empty) variable here at
        # install time, so the kill on a real expiry/stop would have
        # no target and would orphan the sleep child.
        sleep "$1" &
        sleep_pid=$!
        trap '"'"'kill -TERM "$sleep_pid" 2>/dev/null; exit 0'"'"' TERM INT HUP
        wait "$sleep_pid" 2>/dev/null
        rc=$?
        # rc=0 means sleep elapsed (window genuinely expired); any
        # other rc means we were signalled (cmd_allow_for reset-clock
        # or cmd_stop teardown), in which case do nothing — the
        # signaller already arranged the next state.
        if [ "$rc" -eq 0 ]; then
            # Rewrite the staged (proxy-canonical) mode file to default.
            # The staged file lives in a 0700 boxa-agent-owned dir, so
            # the write goes through sudo.
            printf "%s" "$2" \
                | sudo -u boxa-agent tee "$3/active-mode" >/dev/null 2>&1 || true
            # Rewrite the user-state copy in $HOME so the historical
            # record matches reality.
            if [ -n "$6" ]; then
                mkdir -p "$(dirname "$6")" 2>/dev/null || true
                printf "%s" "$2" > "$6" 2>/dev/null || true
                chmod 600 "$6" 2>/dev/null || true
            fi
            # Clear active_network_window in the session-state JSON so
            # status no longer reports an active window after expiry
            # and reset-clock paths do not try to kill a dead timer
            # via its stale recorded pid.
            if [ -n "$7" ] && [ -f "$7" ]; then
                python3 - "$7" <<"PYEOF" 2>/dev/null || true
import json, os, sys
state_path = sys.argv[1]
try:
    with open(state_path, "r", encoding="utf-8") as fh:
        state = json.load(fh)
except Exception:
    sys.exit(0)
state["active_network_window"] = None
tmp = state_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
os.replace(tmp, state_path)
PYEOF
            fi
            # Only signal the proxy when its current cmdline still
            # bears the marker we recorded — the listen-port plus the
            # rest of the proxy bin name. Defends against PID reuse.
            if [ -r "/proc/$4/cmdline" ] \
                && tr "\0" " " < "/proc/$4/cmdline" 2>/dev/null \
                    | grep -qF -- "$5"; then
                sudo -u boxa-agent kill -HUP "$4" 2>/dev/null || true
            fi
            # Toast emit (slice 08, timer-expiry path). The full JSON
            # body is composed inline so we do not depend on sourcing
            # broker helpers from a detached subshell. Best-effort: any
            # failure falls through silently — the canonical record is
            # the proxy log on disk. The pending filename pattern must
            # match the deliver script reconstruction regex.
            if [ -n "${8:-}" ] && [ -n "${9:-}" ] && [ -n "${10:-}" ]; then
                pending_dir="$9"
                container_arg="$8"
                deliver_bin="${10}"
                profile_base=$(basename -- "$3")
                ts_compact=${profile_base#"${container_arg}-"}
                case "$ts_compact" in
                    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
                    *) ts_compact="" ;;
                esac
                if [ -n "$ts_compact" ]; then
                    mkdir -p "$pending_dir" 2>/dev/null || true
                    chmod 700 "$pending_dir" 2>/dev/null || true
                    emit_ts=$(date +%s%N 2>/dev/null || echo "")
                    case "$emit_ts" in
                        *[!0-9]*|"") emit_ts="$(date +%s)$$${RANDOM}" ;;
                    esac
                    pending_path="${pending_dir}/.pending-ab-window-${container_arg}-${ts_compact}-${emit_ts}.json"
                    pending_tmp=$(mktemp "${pending_dir}/.pending-ab-window.XXXXXXXXXX" 2>/dev/null || echo "")
                    if [ -n "$pending_tmp" ]; then
                        emitted_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
                        printf "%s\n" \
                            "{" \
                            "  \"event\": \"agent-browser-window-close\"," \
                            "  \"container\": \"${container_arg}\"," \
                            "  \"session_ts\": \"${ts_compact}\"," \
                            "  \"reason\": \"timer-expiry\"," \
                            "  \"duration_seconds\": null," \
                            "  \"click_target_hint\": \"${3}/proxy.log\"," \
                            "  \"emitted_at\": \"${emitted_at}\"" \
                            "}" \
                            > "$pending_tmp" \
                            && chmod 600 "$pending_tmp" 2>/dev/null \
                            && mv -- "$pending_tmp" "$pending_path" 2>/dev/null \
                            || rm -f -- "$pending_tmp"
                        if [ -x "$deliver_bin" ] && [ -e "$pending_path" ]; then
                            (
                                "$deliver_bin" "$pending_path" \
                                    </dev/null \
                                    >/dev/null 2>&1
                            ) &
                        fi
                    fi
                fi
            fi
        fi
    ' agent-browser-window-timer "$seconds" "$mode_default_json" "$profile_dir" "$proxy_pid" "$proxy_marker" "$AGENT_PROXY_MODE_FILE" "$state_file" "$container" "$AGENT_PENDING_DIR" "$AGENT_DELIVER_BIN" \
        </dev/null \
        >/dev/null 2>&1 &
    local timer_pid=$!
    disown "$timer_pid" 2>/dev/null || true

    # Sanity: the wrapper must still be alive an instant later, with
    # the expected cmdline marker — defends against the wrapper dying
    # before its trap installs, or pgrep returning a recycled pid.
    sleep 0.1
    if ! _pid_matches_marker "$timer_pid" "agent-browser-window-timer"; then
        return 1
    fi
    printf '%s\n' "$timer_pid"
}

# Kill a previously-spawned window timer. Best-effort; the wrapper's
# trap propagates the SIGTERM to its `sleep` child.
#
# Gates on the marker `agent-browser-window-timer` (the inner `sh -c`
# argv[0]) so a recorded timer_pid that has been recycled across a
# host crash/reboot does not cause us to signal an unrelated process.
# Mirrors the marker-match pattern used for Chrome / relay / proxy /
# bridge above.
_kill_window_timer() {
    local timer_pid="${1:-}"
    [ -n "$timer_pid" ] || return 0
    [ "$timer_pid" != "null" ] || return 0
    _pid_matches_marker "$timer_pid" "agent-browser-window-timer" || return 0
    kill -TERM "$timer_pid" 2>/dev/null || true
    local wait_ix
    for wait_ix in 1 2 3 4 5; do
        : "$wait_ix"
        _pid_matches_marker "$timer_pid" "agent-browser-window-timer" || return 0
        sleep 0.2
    done
    kill -KILL "$timer_pid" 2>/dev/null || true
}

# Resolve the proxy log archive path (the per-window subset of the
# JSONL stream is the suffix of this file from the moment the window
# opened — the proxy is a single shared stream, slice 06's summary
# generator splits per-window using `started_at`).
_session_proxy_log_live() {
    local state_file="$1"
    _state_get "$state_file" proxy_log_path 2>/dev/null || true
}

# --- subcommand: allow / deny (per-host allowlist round-trip) ----------------
#
# Round-trip CLI for the Agent-browser allowlist file at
# $AGENT_ALLOWLIST_PATH. Mirrors the firewall `boxa allow` / `deny` shape
# but writes to the agent-browser-specific path and SIGHUPs every live
# proxy so edits land without restarting Chrome.
#
# Validation mirrors what the proxy's `_read_allowlist` accepts: bare
# hostnames (`api.openai.com`) and `*` globs (`*.openai.com`). The proxy
# does NOT do implicit subdomain matching, so the user must write the
# `*.` prefix explicitly — this asymmetry vs the firewall side is
# surfaced in --help.

# Reject inputs the proxy would later skip as malformed. Whitespace,
# slashes, scheme prefixes, and control chars are all proxy-side
# rejection rules; catching them at the CLI gives the user immediate
# feedback rather than a silent "added to file, ignored at runtime".
_validate_ab_domain() {
    local domain="$1"
    [ -n "$domain" ] || { _warn "agent-browser: domain must not be empty"; return 1; }
    case "$domain" in
        *[[:space:]]*) _warn "agent-browser: domain must not contain whitespace: '${domain}'"; return 1 ;;
        *://*)         _warn "agent-browser: domain must not include a scheme: '${domain}'"; return 1 ;;
        */*)           _warn "agent-browser: domain must not contain '/': '${domain}'"; return 1 ;;
        \#*)           _warn "agent-browser: domain must not start with '#': '${domain}'"; return 1 ;;
    esac
    # Reject control chars (ASCII < 32) the proxy would also drop.
    case "$domain" in
        *[[:cntrl:]]*) _warn "agent-browser: domain must not contain control characters"; return 1 ;;
    esac
}

# Compute the apex↔www counterpart for an allowlist entry, if one applies.
# This is the deterministic narrow exception to ADR 0012's "no auto-glob on
# write" rule — HSTS / 301-to-www is a common case where the user picks
# `qr.cz` but Chrome immediately retries `www.qr.cz`. Pairing keeps the
# allowlist literal (no wildcards) while saving one round-trip through
# the picker. Globs are skipped — they already cover the pair.
#
# Examples:
#   qr.cz          -> www.qr.cz
#   www.qr.cz      -> qr.cz
#   api.foo.com    -> www.api.foo.com
#   *.foo.com      -> (empty: glob)
#   localhost      -> (empty: no dot, not a real domain)
_ab_www_pair() {
    local d="$1"
    case "$d" in
        *'*'*|*'?'*|*'['*) return 0 ;;       # globs already span pairs
    esac
    case "$d" in
        www.*)
            local apex="${d#www.}"
            case "$apex" in
                *.*) printf '%s\n' "$apex" ;;  # strip only if apex still has a dot
            esac
            ;;
        *.*)
            printf '%s\n' "www.$d"
            ;;
    esac
}

# Fan SIGHUP out to every live agent-browser proxy and re-stage the
# user-side allowlist into each session's profile dir first (the proxy
# reads the staged copy, not $AGENT_ALLOWLIST_PATH directly — see the
# comment on AGENT_ALLOWLIST_PATH for the perms reason).
#
# Sessions whose proxy_pid is dead or recycled are skipped silently —
# cleanup of stale state files is owned by `_sweep_if_stale` on the
# next start/stop, not by this command.
_sighup_all_proxies() {
    [ -d "$SESSIONS_DIR" ] || return 0
    local f proxy_pid profile_dir proxy_port marker
    shopt -s nullglob
    for f in "$SESSIONS_DIR"/*.json; do
        proxy_pid="$(_state_get "$f" proxy_pid 2>/dev/null || true)"
        profile_dir="$(_state_get "$f" profile_dir 2>/dev/null || true)"
        proxy_port="$(_state_get "$f" proxy_port_host 2>/dev/null || true)"
        [ -n "$proxy_pid" ]    || continue
        [ "$proxy_pid" != "null" ]    || continue
        [ -n "$profile_dir" ]         || continue
        [ "$profile_dir" != "null" ]  || continue
        # Guard against PID reuse: only signal a process that still
        # carries the proxy's listen-port marker.
        if [ -n "$proxy_port" ] && [ "$proxy_port" != "null" ]; then
            marker="--listen 127.0.0.1:${proxy_port}"
            _pid_matches_marker "$proxy_pid" "$marker" || continue
        else
            _pid_alive_on_host "$proxy_pid" || continue
        fi
        _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" || continue
        _restage_allowlist_only "$profile_dir"
        sudo -u boxa-agent kill -HUP "$proxy_pid" 2>/dev/null || true
    done
    shopt -u nullglob
}

cmd_agent_allow() {
    # No-arg → list current entries. Mirrors `boxa allow` (no arg)
    # behaviour from docker-run.sh so the two namespaces feel symmetric.
    if [ "$#" -eq 0 ]; then
        _log "Agent-browser allowlist (${AGENT_ALLOWLIST_PATH}):"
        local entries
        entries="$(allowlist::read "$AGENT_ALLOWLIST_PATH" | sort)"
        if [ -n "$entries" ]; then
            printf '%s\n' "$entries" | while IFS= read -r d; do printf '  %s\n' "$d"; done
        else
            _log "  (none)"
        fi
        _log ""
        _log "Usage: boxa agent-browser allow <domain>  |  boxa agent-browser deny <domain>"
        _log "Note: Unlike the firewall allowlist, an entry matches ONLY the literal"
        _log "      host. For subdomains, quote a glob: boxa agent-browser allow '*.example.com'"
        _log "      Apex↔www counterparts are auto-paired on add (e.g. qr.cz pulls in www.qr.cz)."
        return 0
    fi

    [ "$#" -eq 1 ] || _die "Usage: boxa agent-browser allow <domain>"
    local domain="$1"
    _validate_ab_domain "$domain" || exit 2

    local primary_added=0 pair pair_added=0
    if allowlist::add "$AGENT_ALLOWLIST_PATH" "$domain"; then
        _log "Allowed (agent-browser): ${domain}"
        primary_added=1
    else
        _log "Already in agent-browser allowlist: ${domain}"
    fi

    # Auto-add the apex↔www counterpart so HSTS / 301 redirects don't
    # send the user back through `blocked` for the same site.
    pair="$(_ab_www_pair "$domain")"
    if [ -n "$pair" ] && allowlist::add "$AGENT_ALLOWLIST_PATH" "$pair"; then
        _log "Allowed (agent-browser): ${pair} (auto-paired with ${domain})"
        pair_added=1
    fi

    # Skip SIGHUP fan-out when nothing changed — saves a re-stage cycle
    # across every live proxy for a pure no-op.
    if [ "$primary_added" = 1 ] || [ "$pair_added" = 1 ]; then
        _sighup_all_proxies
    fi
}

cmd_agent_deny() {
    [ "$#" -eq 1 ] || _die "Usage: boxa agent-browser deny <domain>"
    local domain="$1"
    _validate_ab_domain "$domain" || exit 2

    local primary_removed=0 pair pair_removed=0
    if allowlist::remove "$AGENT_ALLOWLIST_PATH" "$domain"; then
        _log "Removed (agent-browser): ${domain}"
        primary_removed=1
    else
        _log "Not in agent-browser allowlist: ${domain}"
    fi

    # Symmetric with `allow`: if `allow X` added the counterpart,
    # `deny X` removes it too. Idempotent — silent if the counterpart
    # was already gone.
    pair="$(_ab_www_pair "$domain")"
    if [ -n "$pair" ] && allowlist::remove "$AGENT_ALLOWLIST_PATH" "$pair"; then
        _log "Removed (agent-browser): ${pair} (auto-paired with ${domain})"
        pair_removed=1
    fi

    if [ "$primary_removed" = 0 ] && [ "$pair_removed" = 0 ]; then
        return 0
    fi

    _sighup_all_proxies

    # The proxy enforces the allowlist on CONNECT setup, not on bytes
    # already flowing through an open tunnel. Live HTTPS sessions
    # (HTTP/2 multiplexing, keep-alive) reuse the existing tunnel and
    # bypass the deny until the browser closes the socket. Surface this
    # so users don't think `deny` is broken when a tab keeps loading.
    _log "Note: existing browser tunnels stay open until the tab/window is closed."
    _log "      Restart the browser to enforce deny on live HTTPS sessions."
}

# --- subcommand: blocked (per-container deny viewer) -------------------------
#
# Surfaces the most recent agent-browser session's denied hosts for one
# container in an interactive multi-select picker. Each pick routes back
# through `agent-browser allow <domain>` so SIGHUP fan-out (slice A) runs
# once per pick. ADR 0012 § "Data source — last session, live or archived".

# Enumerate containers that have an archived proxy.log on disk. Used by
# the union picker to surface "agent ran, session timed out, user comes
# back" workflows. The archive filename shape is
# `<container>-<ISO>.proxy.log`; the ISO suffix sorts as text, so we
# strip it to recover the container.
_archived_containers() {
    [ -d "$AGENT_NETLOG_ARCHIVE_DIR" ] || return 0
    local f base container
    shopt -s nullglob
    for f in "$AGENT_NETLOG_ARCHIVE_DIR"/*.proxy.log; do
        base="$(basename "$f" .proxy.log)"
        # Strip trailing -YYYYMMDDTHHMMSSZ. The suffix is fixed-width
        # (15 chars + leading dash), so a sed cut is unambiguous.
        container="$(printf '%s\n' "$base" | sed -E 's/-[0-9]{8}T[0-9]{6}Z$//')"
        [ "$container" = "$base" ] && continue
        printf '%s\n' "$container"
    done
    shopt -u nullglob
}

# Enumerate live session container names from the sessions/ state dir.
_live_session_containers() {
    [ -d "$SESSIONS_DIR" ] || return 0
    local f
    shopt -s nullglob
    for f in "$SESSIONS_DIR"/*.json; do
        basename "$f" .json
    done
    shopt -u nullglob
}

# Trim the per-container archive to the newest $keep session triples.
# A "session triple" is everything sharing a `<container>-<ISO>` prefix:
# `.proxy.log`, `.netlog.json`, `.summary.md`. Proxy log is the anchor —
# always written at stop, ISO ts is unambiguous, sorts as text — so we
# enumerate proxy.log files, keep the newest $keep, and sweep the other
# two extensions for the dropped prefixes too. Idempotent: a parallel
# start for the same container can only add files (different ts), never
# resurrect the ones we just deleted.
_prune_archive_for() {
    local container="$1" keep="$2"
    [ -d "$AGENT_NETLOG_ARCHIVE_DIR" ] || return 0
    [[ "$keep" =~ ^[0-9]+$ ]] || return 0
    [ "$keep" -gt 0 ] || return 0

    # Enumerate as boxa-agent. The archive dir is 0750 boxa-agent
    # (ADR 0010), so a host shell without an active boxa-agent group
    # membership — fresh install before `newgrp` / re-login — cannot list
    # it directly. A bare glob would expand to nothing in that case and
    # retention would silently never fire, letting the archive grow past
    # the cap. Going through sudo makes retention robust to group state;
    # the sudo prompt almost always piggybacks on cmd_start's other sudo
    # calls (cached creds), and a sudo failure here is downgraded to a
    # warning rather than aborting session start.
    local listing
    if ! listing=$(sudo -u boxa-agent \
        find "$AGENT_NETLOG_ARCHIVE_DIR" -maxdepth 1 -type f \
             -name "${container}-*.proxy.log" 2>/dev/null); then
        _warn "agent-browser: could not enumerate archive for prune — retention skipped this session"
        return 0
    fi

    # Walk the listing and require the dash-segment after `<container>-`
    # to be the exact ISO-ts shape `[0-9]{8}T[0-9]{6}Z`, and the pre-ts
    # head to equal `<container>` literally. Without the ts check, a
    # prefix-collision project (`boxa-foo` vs `boxa-foo-bar`) would
    # see its sibling's archives pulled into the keep/drop set and the
    # deletion loop could remove the wrong container's files. Same
    # defence as _boxa::remove_project_agent_browser_archives in
    # docker-run.sh — keep them in sync.
    local -a archives=()
    local f base ts head
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        base="$(basename "$f" .proxy.log)"
        ts="${base##*-}"
        [[ "$ts" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
        head="${base%-"$ts"}"
        [ "$head" = "$container" ] || continue
        archives+=("$f")
    done <<< "$listing"

    [ "${#archives[@]}" -gt "$keep" ] || return 0

    # ISO 8601 sorts lexicographically → ascending gives oldest first.
    local -a sorted=()
    while IFS= read -r line; do
        sorted+=("$line")
    done < <(printf '%s\n' "${archives[@]}" | sort)

    local drop_count=$(( ${#sorted[@]} - keep ))
    local idx ext victim
    for (( idx=0; idx < drop_count; idx++ )); do
        base="$(basename "${sorted[$idx]}" .proxy.log)"
        # Belt-and-braces validation: the glob walk above already
        # confirms `<container>-<ISO>` shape, but _is_managed_path also
        # rejects any path that escapes the archive dir via traversal.
        _is_managed_path "${AGENT_NETLOG_ARCHIVE_DIR}/${base}.proxy.log" \
            "$AGENT_NETLOG_ARCHIVE_DIR" "${container}-" || continue
        # `[ -e ]` would also stat-fail without group membership, so we
        # skip the existence probe and let `rm -f` silently no-op on a
        # missing file. The proxy.log is guaranteed present (we just
        # found it); the other two extensions are best-effort.
        for ext in proxy.log netlog.json summary.md; do
            victim="${AGENT_NETLOG_ARCHIVE_DIR}/${base}.${ext}"
            if ! sudo -u boxa-agent rm -f -- "$victim" 2>/dev/null; then
                _warn "agent-browser: failed to prune ${victim}"
            fi
        done
    done
}

# Pick the most recent archived proxy.log for a container by ISO
# timestamp in filename (sortable as text). Empty stdout if none.
# The shopt+nullglob path is preferred over `ls` so a no-match doesn't
# trip `set -euo pipefail` in the caller's `var="$(_latest...)"` line.
_latest_archived_proxy_log() {
    local container="$1"
    [ -d "$AGENT_NETLOG_ARCHIVE_DIR" ] || return 0
    local -a candidates=()
    local f
    shopt -s nullglob
    for f in "$AGENT_NETLOG_ARCHIVE_DIR"/"${container}"-*.proxy.log; do
        candidates+=("$f")
    done
    shopt -u nullglob
    [ "${#candidates[@]}" -gt 0 ] || return 0
    printf '%s\n' "${candidates[@]}" | sort | tail -1
}

# Locate the live proxy.log for a container (state-file path). Empty
# stdout if no live session, or if the state file points outside the
# managed profile dir — the latter prevents a tampered state JSON from
# steering a downstream `sudo -u boxa-agent cat` at an arbitrary
# boxa-agent-readable path. Same trust property the archive path uses.
_live_proxy_log_for() {
    local container="$1"
    local state_file
    state_file="$(_state_file "$container")"
    [ -f "$state_file" ] || return 0
    local proxy_log_path profile_dir
    proxy_log_path="$(_session_proxy_log_live "$state_file" 2>/dev/null || true)"
    profile_dir="$(_state_get "$state_file" profile_dir 2>/dev/null || true)"
    [ -n "$proxy_log_path" ] && [ "$proxy_log_path" != "null" ] || return 0
    [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] || return 0
    if ! _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-"; then
        return 0
    fi
    if ! _is_managed_path "$proxy_log_path" "$profile_dir"; then
        return 0
    fi
    printf '%s\n' "$proxy_log_path"
}

# Read denied hosts from a JSONL proxy log, dedup by host. Live logs sit
# under boxa-agent-owned profile dirs (0700) that the developer can't
# traverse, so we shell out via sudo when the file isn't directly
# readable. jq is preferred for the JSON parse; python3 is the fallback
# (mirrors `_state_get`'s jq/python3 cascade).
_denied_hosts_from_log() {
    local log_path="$1"
    [ -n "$log_path" ] || return 0
    local reader
    if [ -r "$log_path" ]; then
        reader=(cat -- "$log_path")
    else
        reader=(sudo -u boxa-agent cat -- "$log_path")
    fi
    if command -v jq >/dev/null 2>&1; then
        "${reader[@]}" 2>/dev/null \
            | jq -r 'select(.decision == "deny") | .host // empty' 2>/dev/null \
            | awk 'NF && !seen[$0]++'
    else
        # Heredoc-into-stdin would shadow the pipe, so pass the script
        # via -c and let python3 inherit the piped stdin directly.
        "${reader[@]}" 2>/dev/null \
            | python3 -c '
import json, sys
seen = set()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if rec.get("decision") != "deny":
        continue
    host = rec.get("host")
    if not host or host in seen:
        continue
    seen.add(host)
    print(host)
'
    fi
}

# Drop hosts already covered by the Agent-browser allowlist. Bare
# entries are literal matches; `*`-glob entries use shell fnmatch
# (the same semantic the proxy applies at runtime). `*.example.com`
# additionally matches the bare `example.com` apex, mirroring the
# proxy's `is_allowed` rule. Both sides are lowercased to match the
# proxy's case-insensitive comparison.
_filter_allowlisted_hosts() {
    local -a allow_entries=()
    local entry
    while IFS= read -r entry; do
        [ -n "$entry" ] && allow_entries+=("${entry,,}")
    done < <(allowlist::read "$AGENT_ALLOWLIST_PATH")

    local host host_lc matched apex
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        host_lc="${host,,}"
        matched=false
        for entry in "${allow_entries[@]}"; do
            # shellcheck disable=SC2254 # intentional pattern expansion — fnmatch is the proxy semantic
            case "$host_lc" in
                $entry) matched=true; break ;;
            esac
            case "$entry" in
                \*.*)
                    apex="${entry#*.}"
                    [ "$host_lc" = "$apex" ] && { matched=true; break; }
                    ;;
            esac
        done
        [ "$matched" = true ] || printf '%s\n' "$host"
    done
}

# Collapse apex↔www pairs in a host stream: when both `X` and `www.X`
# appear, drop the `www.X` row so the picker shows the apex only.
# Selecting the apex auto-pairs both via `cmd_agent_allow`, so the
# `www.X` row would be a duplicate prompt. Symmetric with `_ab_www_pair`.
# Input order is preserved for the surviving rows.
_collapse_www_pairs() {
    awk '
    { hosts[NR]=$0; seen[$0]=1 }
    END {
        for (i=1; i<=NR; i++) {
            h = hosts[i]
            if (substr(h, 1, 4) == "www.") {
                apex = substr(h, 5)
                if (apex in seen) continue
            }
            print h
        }
    }'
}

# Resolve the proxy log for one container under the "last session, live or
# archived" rule (ADR 0012 § Data source). Live wins even if empty; otherwise
# the most recent archived log. Empty stdout if neither exists.
#
# Outputs two whitespace-separated tokens on success: `<kind> <path>` where
# kind is `live` or `archived`. Callers may discard the kind.
_resolve_last_session_log() {
    local container="$1"
    local log_path
    log_path="$(_live_proxy_log_for "$container")"
    if [ -n "$log_path" ]; then
        printf 'live %s\n' "$log_path"
        return 0
    fi
    log_path="$(_latest_archived_proxy_log "$container")"
    if [ -n "$log_path" ]; then
        printf 'archived %s\n' "$log_path"
        return 0
    fi
    return 0
}

# Denied + allowlist-filtered hosts for one container. Wraps the live/archived
# resolution + JSONL parse + allowlist filter in one place so both the per-
# container `blocked` viewer and the global unified `boxa blocked` use the
# same path. Emits one host per line on stdout, deduplicated, sorted.
_denied_hosts_for_container() {
    local container="$1"
    local resolved log_path
    resolved="$(_resolve_last_session_log "$container")"
    [ -n "$resolved" ] || return 0
    log_path="${resolved#* }"
    _denied_hosts_from_log "$log_path" | _filter_allowlisted_hosts | sort -u | _collapse_www_pairs
}

# Globally denied hosts across all containers that have ever produced an
# agent-browser session (live ∪ archived), deduplicated and allowlist-
# filtered. Used by the unified `boxa blocked` view.
#
# Silent fallback property (ADR 0012 acceptance #4): if no container has
# any proxy log on disk anywhere, this function emits nothing — no headers,
# no warnings — letting the caller render output indistinguishable from
# today's firewall-only behaviour.
_denied_hosts_global() {
    local container
    { _live_session_containers; _archived_containers; } \
        | awk 'NF && !seen[$0]++' \
        | while IFS= read -r container; do
            [ -n "$container" ] || continue
            _denied_hosts_for_container "$container"
        done \
        | awk 'NF && !seen[$0]++' \
        | sort \
        | _collapse_www_pairs
}

# Interactive union picker over (live sessions ∪ archived containers).
# Returns the picked container on stdout, non-zero on cancel/empty.
_offer_blocked_container_picker() {
    [ -t 0 ] || return 1
    [ -t 2 ] || return 1
    local -a candidates=()
    local name
    while IFS= read -r name; do
        [ -n "$name" ] && candidates+=("$name")
    done < <({ _live_session_containers; _archived_containers; } | awk 'NF && !seen[$0]++' | sort)
    [ "${#candidates[@]}" -gt 0 ] || return 1
    local header="agent-browser: pick a container to view denials (live or archived)"
    local chosen
    chosen="$(printf '%s\n' "${candidates[@]}" \
        | picker::one --prompt "container> " --header "$header")" \
        || return 1
    [ -n "$chosen" ] || return 1
    printf '%s\n' "$chosen"
}

cmd_agent_blocked() {
    # Container resolution: precedence handled by docker-run.sh
    # (explicit -p → CWD basename → picker). The broker accepts three
    # shapes:
    #   blocked                       — no hint, jump straight to picker
    #   blocked <container>           — explicit, error if no data
    #   blocked --from-cwd <container> — CWD-derived, picker on no data
    local container="" from_cwd=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --from-cwd)
                from_cwd=true
                [ -n "${2:-}" ] || _die "Usage: agent-browser-broker.sh blocked [<container> | --from-cwd <container>]"
                container="$2"
                shift 2
                ;;
            -*)
                _die "Unknown flag: $1"
                ;;
            *)
                [ -z "$container" ] || _die "Usage: agent-browser-broker.sh blocked [<container> | --from-cwd <container>]"
                container="$1"
                shift
                ;;
        esac
    done

    if [ -n "$container" ]; then
        container="$(_require_container_arg "$container")"
    fi

    # Pick the data source for this container under the live > archived rule.
    local resolved="" log_kind=""
    if [ -n "$container" ]; then
        resolved="$(_resolve_last_session_log "$container")"
        [ -n "$resolved" ] && log_kind="${resolved%% *}"
    fi

    # No data for the explicit/CWD-derived container? Explicit dies with
    # the informative message; CWD-derived falls back to the picker.
    if [ -z "$resolved" ]; then
        if [ "$from_cwd" = true ] || [ -z "$container" ]; then
            local picked
            if picked="$(_offer_blocked_container_picker)"; then
                container="$picked"
                resolved="$(_resolve_last_session_log "$container")"
                [ -n "$resolved" ] && log_kind="${resolved%% *}"
            else
                if [ -n "$container" ]; then
                    _log "no agent-browser sessions on record for ${container}"
                else
                    _log "no agent-browser sessions on record (no live or archived data)"
                fi
                return 0
            fi
        else
            _log "no agent-browser sessions on record for ${container}"
            return 0
        fi
    fi

    # Resolve denied hosts → unique list → filter against the allowlist.
    local -a hosts=()
    local h
    while IFS= read -r h; do
        [ -n "$h" ] && hosts+=("$h")
    done < <(_denied_hosts_for_container "$container")

    if [ "${#hosts[@]}" -eq 0 ]; then
        _log "No denied hosts to allow for ${container} (source: ${log_kind} log)."
        return 0
    fi

    local selected
    selected="$(printf '%s\n' "${hosts[@]}" \
        | picker::many \
            --prompt "Allow domain (agent-browser):" \
            --header "Tab/Shift-Tab to mark · Enter to confirm   (or \"1,3,5\" without fzf)" \
            --first-option "* Allow all")" \
        || return 1

    local sel d
    while IFS= read -r sel; do
        [ -z "$sel" ] && continue
        if [ "$sel" = "* Allow all" ]; then
            for d in "${hosts[@]}"; do
                "$0" allow "$d"
            done
        else
            "$0" allow "$sel"
        fi
    done <<< "$selected"
}

# --- subcommand: allow-for ---------------------------------------------------

cmd_allow_for() {
    # Parse args: either `<minutes> [<container>]` or `--stop [<container>]`.
    # Mirrors how the firewall allow-for dispatch in docker-run.sh shapes
    # its parsing, just at the broker level — the broker is the canonical
    # single entry point for this slice.
    local stop_mode=false
    local minutes=""
    local container=""
    local arg
    for arg in "$@"; do
        case "$arg" in
            --stop) stop_mode=true ;;
            ''|*[!0-9]*)
                [ -z "$container" ] || _die "Unexpected extra argument: ${arg}"
                container="$arg"
                ;;
            *)
                [ -z "$minutes" ] || _die "Unexpected extra minutes argument: ${arg}"
                minutes="$arg"
                ;;
        esac
    done

    if [ "$stop_mode" = true ]; then
        cmd_allow_for_stop "$container"
        return
    fi

    [ -n "$minutes" ] || _die "Missing minutes. Usage: agent-browser-broker.sh allow-for <minutes> <container>"

    # Validate the integer range; the broker is the trust anchor here
    # because it is invoked directly by tooling, not only through the
    # docker-run.sh dispatcher.
    case "$minutes" in
        ''|*[!0-9]*) _die "Minutes must be a positive integer (got '${minutes}')." ;;
    esac
    if [ "$minutes" -le 0 ] 2>/dev/null; then
        _die "Minutes must be a positive integer (got '${minutes}')."
    fi
    if [ "$minutes" -gt "$AGENT_ALLOW_FOR_MAX_MINUTES" ]; then
        _die "Minutes exceeds cap (${AGENT_ALLOW_FOR_MAX_MINUTES})."
    fi

    container="$(_require_container_arg "$container")"

    local state_file
    state_file="$(_state_file "$container")"
    if [ ! -f "$state_file" ]; then
        local replacement
        if replacement="$(_offer_session_picker "$container")"; then
            container="$replacement"
            state_file="$(_state_file "$container")"
        else
            _die "No Agent-browser session for '${container}'. Start one first: boxa agent-browser start ${container}"
        fi
    fi

    local proxy_pid proxy_port profile_dir
    proxy_pid="$(_state_get "$state_file" proxy_pid || true)"
    proxy_port="$(_state_get "$state_file" proxy_port_host || true)"
    profile_dir="$(_state_get "$state_file" profile_dir || true)"

    if [ -z "$proxy_pid" ] || [ "$proxy_pid" = "null" ]; then
        _die "Session for '${container}' has no proxy_pid — refusing to open a window against a half-started session."
    fi
    if [ -z "$proxy_port" ] || [ "$proxy_port" = "null" ]; then
        _die "Session for '${container}' has no proxy_port_host — state file may be from an older slice."
    fi
    if [ -z "$profile_dir" ] || [ "$profile_dir" = "null" ]; then
        _die "Session for '${container}' has no profile_dir — state file is malformed."
    fi
    if ! _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-"; then
        _die "Session profile_dir '${profile_dir}' is outside the managed parent — refusing to operate."
    fi

    local proxy_marker="--listen 127.0.0.1:${proxy_port}"
    _pid_matches_marker "$proxy_pid" "$proxy_marker" \
        || _die "Proxy PID ${proxy_pid} for '${container}' is no longer alive (or reused). Restart the session."

    # Reset-clock semantics — kill any existing timer before spawning the
    # new one. The mode file still lists `harvest` from the prior call;
    # we'll overwrite it in place.
    local existing_timer
    existing_timer="$(_state_get_window_timer_pid "$state_file" || true)"
    if [ -n "$existing_timer" ] && [ "$existing_timer" != "null" ]; then
        _kill_window_timer "$existing_timer"
    fi
    local existing_started
    if command -v jq >/dev/null 2>&1; then
        existing_started="$(jq -r '.active_network_window.started_at // empty' "$state_file" 2>/dev/null || true)"
    else
        existing_started="$(python3 - "$state_file" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    window = data.get("active_network_window")
    if window:
        s = window.get("started_at")
        if s:
            print(s)
except Exception:
    pass
PY
)"
    fi

    local now_iso new_expires
    now_iso="$(_iso_utc_now)"
    new_expires="$(_iso_plus_minutes_utc "$minutes")" \
        || _die "Failed to compute expiry timestamp (date binary missing required flags?)."

    local started_at="$existing_started"
    [ -n "$started_at" ] || started_at="$now_iso"

    _restage_allowlist_only "$profile_dir"
    _write_mode_file_pair "$profile_dir" "harvest" "$new_expires"

    sudo -u boxa-agent kill -HUP "$proxy_pid" 2>/dev/null \
        || _warn "Failed to send SIGHUP to proxy PID ${proxy_pid}; the proxy will still notice expiry on the next request via the mode-file timestamp."

    local seconds
    seconds=$(( minutes * 60 ))
    local timer_pid=""
    timer_pid="$(_start_window_timer "$proxy_pid" "$proxy_port" "$profile_dir" "$seconds" "$state_file" "$container" || true)"
    if [ -z "$timer_pid" ]; then
        _warn "Window timer failed to start; the proxy will still self-revert at expiry but no SIGHUP will be issued."
        timer_pid=""
    fi

    local harvest_log
    harvest_log="$(_session_proxy_log_live "$state_file")"
    _state_set_network_window "$state_file" "harvest" "$started_at" "$new_expires" "$timer_pid" "$harvest_log"

    local action="opens"
    [ -n "$existing_started" ] && action="extended to"
    _log "Agent-browser network window ${action} ${minutes} min (until $(_local_hms "$new_expires") local) for ${container}."
}

cmd_allow_for_stop() {
    local container
    container="$(_require_container_arg "${1:-}")"

    local state_file
    state_file="$(_state_file "$container")"
    if [ ! -f "$state_file" ]; then
        local replacement
        if replacement="$(_offer_session_picker "$container")"; then
            container="$replacement"
            state_file="$(_state_file "$container")"
        else
            _log "No Agent-browser session for ${container}."
            return 0
        fi
    fi

    local proxy_pid proxy_port profile_dir
    proxy_pid="$(_state_get "$state_file" proxy_pid || true)"
    proxy_port="$(_state_get "$state_file" proxy_port_host || true)"
    profile_dir="$(_state_get "$state_file" profile_dir || true)"

    # Idempotent: if no window is open, this is a no-op success.
    local existing_timer existing_started
    existing_timer="$(_state_get_window_timer_pid "$state_file" || true)"
    if command -v jq >/dev/null 2>&1; then
        existing_started="$(jq -r '.active_network_window.started_at // empty' "$state_file" 2>/dev/null || true)"
    else
        existing_started="$(python3 - "$state_file" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    window = data.get("active_network_window")
    if window:
        s = window.get("started_at")
        if s:
            print(s)
except Exception:
    pass
PY
)"
    fi
    if [ -z "$existing_started" ] && [ -z "$existing_timer" ]; then
        _log "No active network window for ${container} (idempotent no-op)."
        return 0
    fi

    if [ -n "$existing_timer" ] && [ "$existing_timer" != "null" ]; then
        _kill_window_timer "$existing_timer"
    fi

    if [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] \
        && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-"; then
        _write_mode_file_pair "$profile_dir" "default"
    else
        _warn "Session profile_dir '${profile_dir}' is outside the managed parent; not rewriting staged mode file."
    fi

    local proxy_marker="--listen 127.0.0.1:${proxy_port}"
    if [ -n "$proxy_pid" ] && [ "$proxy_pid" != "null" ] \
        && [ -n "$proxy_port" ] && [ "$proxy_port" != "null" ] \
        && _pid_matches_marker "$proxy_pid" "$proxy_marker"; then
        sudo -u boxa-agent kill -HUP "$proxy_pid" 2>/dev/null \
            || _warn "SIGHUP to proxy PID ${proxy_pid} failed; the proxy will pick up the new mode file on its next request anyway."
    fi

    _state_set_network_window "$state_file" "null"
    _log "Agent-browser network window closed for ${container}."

    # Best-effort toast for the explicit-stop branch. Reconstruction in
    # the deliver script uses ${container}-${session_ts} so the live
    # proxy log is the natural pre-archive click target.
    local session_ts hint
    session_ts="$(_session_ts_from_profile_dir "$profile_dir" "$container" || true)"
    if [ -n "$session_ts" ]; then
        hint="${profile_dir}/proxy.log"
        _emit_pending_event "agent-browser-window-close" "$container" "$session_ts" \
            "explicit-stop" "" "$hint"
    fi
}

# --- subcommand: stop --------------------------------------------------------

cmd_stop() {
    local container
    container="$(_require_container_arg "${1:-}")"

    local state_file
    state_file="$(_state_file "$container")"

    if [ ! -f "$state_file" ]; then
        local replacement
        if replacement="$(_offer_session_picker "$container")"; then
            container="$replacement"
            state_file="$(_state_file "$container")"
        else
            _log "No Agent-browser session for ${container} (idempotent no-op)."
            return 0
        fi
    fi

    local chrome_pid bridge_pid relay_pid proxy_pid watchdog_pid profile_dir download_dir
    local netlog_path proxy_log_path cdp_port proxy_port session_created_at
    local host_allow_ip ufw_slot_subnet granted_display
    # Capture the persisted display NOW, before any teardown step rewrites or
    # removes the state file (finding 1). The X revoke at the end targets THIS
    # value, not the ambient `$DISPLAY` — `stop` frequently runs without one
    # (detached watchdog, container-stop closeout, SSH/other-terminal).
    granted_display="$(_state_get "$state_file" granted_display || true)"

    # Refuse to tear down a LIVE in-progress starting claim (#12 review P2).
    # `_sweep_if_stale` already guards a `status:"starting"` claim by its
    # `starting_pid` liveness (round 14/16) so a sweep never reclaims a broker
    # that is mid-start; cmd_stop must mirror that guard. If the target is a
    # `status:"starting"` claim whose `starting_pid` is LIVE and identity-matched
    # (PID alive AND `/proc/<pid>/stat` starttime equal — the round-16 reuse-safe
    # check via the SHARED `_starting_pid_is_live`), a `start` is genuinely still
    # launching Chrome and will later rewrite the full state. Tearing it down here
    # — revoking the X grant / deleting the claim out from under it — would leave
    # that launch failing or orphaned. So REFUSE clearly and return WITHOUT
    # revoking or deleting; the in-progress start owns its own EXIT-trap cleanup
    # (round 7) if it fails, so refusing here orphans nothing. A DEAD/abandoned
    # `starting_pid` (or no status:"starting") falls through to normal teardown,
    # reclaiming the claim exactly as today. This runs AFTER the missing-session
    # picker resolved the real target, so an explicit stop of an established
    # session (no status:"starting") is unaffected.
    local stop_status stop_starting_pid stop_starting_pid_starttime
    stop_status="$(_state_get "$state_file" status || true)"
    if [ "$stop_status" = "starting" ]; then
        stop_starting_pid="$(_state_get "$state_file" starting_pid || true)"
        stop_starting_pid_starttime="$(_state_get "$state_file" starting_pid_starttime || true)"
        if [ -n "$stop_starting_pid" ] && [ "$stop_starting_pid" != "null" ] \
            && _starting_pid_is_live "$stop_starting_pid" "$stop_starting_pid_starttime"; then
            _warn "agent-browser: a start is in progress for ${container} (starting PID ${stop_starting_pid} is live); not stopping a launching session — retry once it has started, or it will be cleaned up automatically if the start fails."
            return 0
        fi
    fi

    chrome_pid="$(_state_get "$state_file" chrome_pid || true)"
    bridge_pid="$(_state_get "$state_file" bridge_pid_in_container || true)"
    relay_pid="$(_state_get "$state_file" relay_pid_host || true)"
    proxy_pid="$(_state_get "$state_file" proxy_pid || true)"
    watchdog_pid="$(_state_get "$state_file" watchdog_pid || true)"
    profile_dir="$(_state_get "$state_file" profile_dir || true)"
    download_dir="$(_state_get "$state_file" download_dir || true)"
    netlog_path="$(_state_get "$state_file" netlog_path || true)"
    proxy_log_path="$(_state_get "$state_file" proxy_log_path || true)"
    cdp_port="$(_state_get "$state_file" cdp_port_host || true)"
    proxy_port="$(_state_get "$state_file" proxy_port_host || true)"
    session_created_at="$(_state_get "$state_file" created_at || true)"
    host_allow_ip="$(_state_get "$state_file" host_allow_ip || true)"
    ufw_slot_subnet="$(_state_get "$state_file" ufw_slot_subnet || true)"

    # Captured-on-success paths threaded into the post-archive summary
    # call below. Empty when the corresponding archive did not happen
    # (missing live file, managed-path check failed, or `sudo mv` errored
    # out). The summarizer accepts a missing path for either input.
    local archived_netlog_path="" archived_proxy_log_path=""

    local chrome_marker="--user-data-dir=$profile_dir"
    local relay_marker="TCP-LISTEN:${cdp_port}"
    local bridge_marker="socat TCP-LISTEN:${BRIDGE_CONTAINER_PORT}"
    local proxy_marker="--listen 127.0.0.1:${proxy_port}"
    local watchdog_marker="agent-browser-watchdog.sh $container"

    # Kill the Chrome-death watchdog first so it can't observe Chrome
    # dying (we're about to SIGTERM it below) and race with us by
    # re-invoking `broker stop` mid-teardown. Re-entry guard: when stop
    # is itself called from the watchdog (BOXA_AGENT_BROWSER_FROM_WATCHDOG=1),
    # skip the kill — the watchdog's PID is this process's parent and
    # signalling it would terminate the cleanup mid-flight.
    # Watchdog runs as the invoking user, so `kill` without sudo is the
    # right signal source.
    if [ "${BOXA_AGENT_BROWSER_FROM_WATCHDOG:-0}" != "1" ] \
        && [ -n "$watchdog_pid" ] && [ "$watchdog_pid" != "null" ] \
        && _pid_matches_marker "$watchdog_pid" "$watchdog_marker"; then
        _log "Stopping watchdog PID ${watchdog_pid}..."
        kill "$watchdog_pid" 2>/dev/null || true
    fi
    # Clean up watchdog log + pidfile alongside the state file removal.
    # Best-effort: a leftover log is not a correctness issue, just a
    # minor sessions-dir clutter that the next start's stale-sweep
    # would also miss (it only sweeps the state file itself).
    rm -f -- "$SESSIONS_DIR/${container}.watchdog.pid" \
             "$SESSIONS_DIR/${container}.watchdog.log" \
             "$SESSIONS_DIR/${container}.launch.log" 2>/dev/null || true

    # Close any active network window first: kill the host-side timer so
    # it can't race with the proxy shutdown below (the proxy is about to
    # die regardless, but a timer firing during cmd_stop would try to
    # SIGHUP a dead PID and write to a soon-removed staged mode file).
    local window_timer_pid was_window_active=false window_started_at=""
    window_timer_pid="$(_state_get_window_timer_pid "$state_file" || true)"
    # Anchor window-active detection on `started_at` (always written
    # when cmd_allow_for opens a window) rather than `timer_pid` alone —
    # `_start_window_timer` may have failed and recorded the window with
    # a null pid, which still requires a session-stop toast at teardown.
    if command -v jq >/dev/null 2>&1; then
        window_started_at="$(jq -r '.active_network_window.started_at // empty' "$state_file" 2>/dev/null || true)"
    else
        window_started_at="$(python3 - "$state_file" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    window = data.get("active_network_window")
    if window:
        s = window.get("started_at")
        if s:
            print(s)
except Exception:
    pass
PY
)"
    fi
    if [ -n "$window_started_at" ] && [ "$window_started_at" != "null" ]; then
        was_window_active=true
    fi
    if [ -n "$window_timer_pid" ] && [ "$window_timer_pid" != "null" ]; then
        _kill_window_timer "$window_timer_pid"
    fi

    # All kill paths gate on the marker match, not bare PID existence —
    # if a saved PID has been reused by an unrelated process across a
    # reboot, we must not signal it.
    if [ -n "$chrome_pid" ] && _pid_matches_marker "$chrome_pid" "$chrome_marker"; then
        _log "Stopping Chrome PID ${chrome_pid}..."
        # boxa-agent owns the process; the invoking user generally can't
        # signal directly. Use sudo to send SIGTERM, then a SIGKILL fallback
        # if Chrome doesn't exit promptly. kill exit-code is ignored — the
        # liveness re-check below is the authoritative answer.
        sudo -u boxa-agent kill "$chrome_pid" 2>/dev/null || true
        local term_wait
        for term_wait in 1 2 3 4 5 6 7 8 9 10; do
            : "$term_wait"
            _pid_matches_marker "$chrome_pid" "$chrome_marker" || break
            sleep 0.3
        done
        if _pid_matches_marker "$chrome_pid" "$chrome_marker"; then
            _warn "Chrome did not exit on SIGTERM, sending SIGKILL."
            sudo -u boxa-agent kill -9 "$chrome_pid" 2>/dev/null || true
        fi
    else
        _log "Chrome PID ${chrome_pid:-?} already gone or reused."
    fi

    if [ -n "$relay_pid" ] && [ "$relay_pid" != "null" ] \
        && _pid_matches_marker "$relay_pid" "$relay_marker"; then
        _log "Stopping host relay PID ${relay_pid}..."
        sudo -u boxa-agent kill "$relay_pid" 2>/dev/null || true
    fi

    if [ -n "$proxy_pid" ] && [ "$proxy_pid" != "null" ] \
        && [ -n "$proxy_port" ] && [ "$proxy_port" != "null" ] \
        && _pid_matches_marker "$proxy_pid" "$proxy_marker"; then
        _log "Stopping Agent-browser proxy PID ${proxy_pid}..."
        sudo -u boxa-agent kill "$proxy_pid" 2>/dev/null || true
    fi

    if _container_running "$container" \
        && [ -n "$bridge_pid" ] \
        && _pid_matches_marker_in_container "$container" "$bridge_pid" "$bridge_marker"; then
        # Reuse the single in-container kill path (also used by the failed-start
        # cleanup). The marker check above already confirmed it is OUR socat.
        _kill_bridge_in_container "$container" "$bridge_pid"
    else
        _log "Bridge PID ${bridge_pid:-?} already gone, reused, or container stopped."
    fi

    # Close the container-side firewall slot that cmd_start opened for the
    # CDP host IP+port. Idempotent — the stop helper removes all matching
    # ACCEPT rules. Skipped if the container is no longer running
    # (init-firewall flushes iptables on the next start anyway) or if the
    # CDP port is unknown (older state file from before port-scoping —
    # init-firewall has flushed the rule across any container restart, so
    # nothing to clean).
    if [ -n "$host_allow_ip" ] && [ "$host_allow_ip" != "null" ] \
        && [ -n "$cdp_port" ] && [ "$cdp_port" != "null" ] \
        && _container_running "$container"; then
        _log "Releasing container firewall slot for ${host_allow_ip}:${cdp_port}..."
        docker exec -u root "$container" \
            /usr/local/bin/stop-agent-browser-host-allow "$host_allow_ip" "$cdp_port" 2>/dev/null || true
    fi

    # Close the host-side ufw/INPUT slot that cmd_start opened for the CDP
    # relay (issue 14). Symmetric to the container-side release above, but
    # on the host. Idempotent — `ufw delete` of a missing rule is swallowed
    # — and a no-op when no slot was opened (ufw inactive/absent or no host
    # relay: ufw_slot_subnet is null). The relay IP and port reuse
    # host_allow_ip / cdp_port_host, the subnet is the persisted field, so
    # the exact scoped rule is deleted, leaving no durable accumulation.
    # `ufw_slot_release_failed` gates the state-file removal at the end of
    # teardown (finding 1). When `stop` is invoked by the detached Chrome
    # watchdog after the developer's sudo credentials have expired, the
    # `sudo ufw delete` has no terminal to authenticate and fails — the
    # durable host ACCEPT rule survives. If we then removed the state file
    # the rule could no longer be identified or reclaimed and would leak a
    # firewall hole indefinitely. So on a failed release of a broker-OWNED
    # slot we RETAIN the state file (carrying ufw_slot_subnet + relay IP +
    # port) and let the next start's stale-session sweep retry the delete.
    local ufw_slot_release_failed=false
    _release_or_retain_ufw_slot "$host_allow_ip" "$cdp_port" "$ufw_slot_subnet" \
        || ufw_slot_release_failed=true

    # Archive netlog before removing the profile dir. Extract the ISO
    # timestamp from the profile dir's basename (suffix after the
    # container name) so the archived filename is anchored to the
    # session that produced it. Fall back to "now" if for any reason
    # the suffix can't be parsed — the moved file is still the same
    # bytes, only the filename suffix differs.
    #
    # The `netlog_path` is sourced from a developer-writable state JSON,
    # so it MUST live under the managed profile dir — otherwise the sudo
    # mv could be redirected. Same parent check is applied to profile_dir
    # itself, plus an inside-parent constraint on netlog_path against the
    # corresponding profile_dir. Existence tests use `sudo test` because
    # the 0700 parent blocks the developer from stat'ing through it.
    local netlog_is_managed=false
    if [ -n "$netlog_path" ] && [ "$netlog_path" != "null" ] \
        && [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] \
        && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-" \
        && _is_managed_path "$netlog_path" "$profile_dir"; then
        netlog_is_managed=true
    fi
    if [ "$netlog_is_managed" = true ] && sudo test -f "$netlog_path"; then
        if [ ! -d "$AGENT_NETLOG_ARCHIVE_DIR" ]; then
            sudo mkdir -p "$AGENT_NETLOG_ARCHIVE_DIR"
            sudo chown boxa-agent: "$AGENT_NETLOG_ARCHIVE_DIR"
            sudo chmod 750 "$AGENT_NETLOG_ARCHIVE_DIR"
        fi
        local ts_suffix archive_path
        ts_suffix="${profile_dir##*/"${container}"-}"
        [ "$ts_suffix" = "$profile_dir" ] && ts_suffix=""
        [ -n "$ts_suffix" ] || ts_suffix="$(date -u +"%Y%m%dT%H%M%SZ")"
        # Final defence: the archive target must itself live under the
        # archive dir and its basename must start with `${container}-`,
        # protecting against a state file with crafted whitespace or path
        # separators in container/ts that survived earlier checks.
        archive_path="${AGENT_NETLOG_ARCHIVE_DIR}/${container}-${ts_suffix}.netlog.json"
        if _is_managed_path "$archive_path" "$AGENT_NETLOG_ARCHIVE_DIR" "${container}-"; then
            if sudo mv -- "$netlog_path" "$archive_path" 2>/dev/null; then
                sudo chown boxa-agent: "$archive_path" 2>/dev/null || true
                sudo chmod 640 "$archive_path" 2>/dev/null || true
                _log "Archived netlog: ${archive_path}"
                archived_netlog_path="$archive_path"
            else
                _warn "Failed to archive netlog from ${netlog_path} to ${archive_path}."
            fi
        else
            _warn "Refusing to archive netlog to suspicious path ${archive_path}."
        fi
    elif [ -n "$netlog_path" ] && [ "$netlog_path" != "null" ] && [ "$netlog_is_managed" != true ]; then
        _warn "State netlog_path '${netlog_path}' is outside the managed profile dir; skipping archive."
    fi

    # Archive proxy log on the same shape and pre-checks as the netlog
    # above. Same trust property: the proxy log path is sourced from a
    # developer-writable state JSON, so it MUST live under the managed
    # profile dir for the sudo mv to be safe.
    local proxy_log_is_managed=false
    if [ -n "$proxy_log_path" ] && [ "$proxy_log_path" != "null" ] \
        && [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] \
        && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-" \
        && _is_managed_path "$proxy_log_path" "$profile_dir"; then
        proxy_log_is_managed=true
    fi
    if [ "$proxy_log_is_managed" = true ] && sudo test -f "$proxy_log_path"; then
        if [ ! -d "$AGENT_NETLOG_ARCHIVE_DIR" ]; then
            sudo mkdir -p "$AGENT_NETLOG_ARCHIVE_DIR"
            sudo chown boxa-agent: "$AGENT_NETLOG_ARCHIVE_DIR"
            sudo chmod 750 "$AGENT_NETLOG_ARCHIVE_DIR"
        fi
        local proxy_ts_suffix proxy_archive_path
        proxy_ts_suffix="${profile_dir##*/"${container}"-}"
        [ "$proxy_ts_suffix" = "$profile_dir" ] && proxy_ts_suffix=""
        [ -n "$proxy_ts_suffix" ] || proxy_ts_suffix="$(date -u +"%Y%m%dT%H%M%SZ")"
        proxy_archive_path="${AGENT_NETLOG_ARCHIVE_DIR}/${container}-${proxy_ts_suffix}.proxy.log"
        if _is_managed_path "$proxy_archive_path" "$AGENT_NETLOG_ARCHIVE_DIR" "${container}-"; then
            if sudo mv -- "$proxy_log_path" "$proxy_archive_path" 2>/dev/null; then
                sudo chown boxa-agent: "$proxy_archive_path" 2>/dev/null || true
                sudo chmod 640 "$proxy_archive_path" 2>/dev/null || true
                _log "Archived proxy log: ${proxy_archive_path}"
                archived_proxy_log_path="$proxy_archive_path"
            else
                _warn "Failed to archive proxy log from ${proxy_log_path} to ${proxy_archive_path}."
            fi
        else
            _warn "Refusing to archive proxy log to suspicious path ${proxy_archive_path}."
        fi
    elif [ -n "$proxy_log_path" ] && [ "$proxy_log_path" != "null" ] && [ "$proxy_log_is_managed" != true ]; then
        _warn "State proxy_log_path '${proxy_log_path}' is outside the managed profile dir; skipping archive."
    fi

    # Generate the session summary alongside the archives. Runs as
    # `boxa-agent` so the output file inherits the same owner as the
    # raw archives — readable to the user via group membership on the
    # archive dir (ADR 0010 § Tamper-proof property). Both inputs are
    # optional: a session that crashed before either log was written
    # still gets a summary noting that no logs were captured. Summary
    # failure is non-fatal; the broker's stop path keeps going so a
    # malformed netlog or a missing python3 cannot block teardown.
    if [ -f "$AGENT_SUMMARIZE_BIN" ]; then
        local summary_ts_suffix summary_path session_ended_at
        summary_ts_suffix=""
        if [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ]; then
            summary_ts_suffix="${profile_dir##*/"${container}"-}"
            [ "$summary_ts_suffix" = "$profile_dir" ] && summary_ts_suffix=""
        fi
        [ -n "$summary_ts_suffix" ] || summary_ts_suffix="$(date -u +"%Y%m%dT%H%M%SZ")"
        summary_path="${AGENT_NETLOG_ARCHIVE_DIR}/${container}-${summary_ts_suffix}.summary.md"
        if _is_managed_path "$summary_path" "$AGENT_NETLOG_ARCHIVE_DIR" "${container}-"; then
            session_ended_at="$(_iso_utc_now)"
            local summary_cmd=(sudo -u boxa-agent python3 "$AGENT_SUMMARIZE_BIN"
                "--output" "$summary_path"
                "--session-start" "${session_created_at:-unknown}"
                "--session-end" "$session_ended_at"
                "--container" "$container")
            [ -n "$archived_netlog_path" ] \
                && summary_cmd+=("--netlog" "$archived_netlog_path")
            [ -n "$archived_proxy_log_path" ] \
                && summary_cmd+=("--proxy-log" "$archived_proxy_log_path")
            # Hand the staged allowlist (boxa-agent-readable copy used
            # by the proxy this session) to the summarizer so harvest-
            # mode requests that already match a rule are classified as
            # in-allowlist rather than out-of-allowlist. The user's
            # original ~/.config copy is 0600 under $HOME — boxa-agent
            # cannot traverse into it. Profile dir is still on disk at
            # this point; rm-rf below happens after this block.
            local staged_allowlist=""
            if [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] \
                && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-"; then
                staged_allowlist="${profile_dir}/allowed-domains.conf"
                if sudo test -f "$staged_allowlist"; then
                    summary_cmd+=("--allowlist" "$staged_allowlist")
                fi
            fi
            if "${summary_cmd[@]}"; then
                sudo chmod 640 "$summary_path" 2>/dev/null || true
                _log "Wrote session summary: ${summary_path}"
            else
                _warn "Summary generator exited non-zero; session teardown continues."
            fi
        else
            _warn "Refusing to write summary to suspicious path ${summary_path}."
        fi
    else
        _warn "Summary generator missing at ${AGENT_SUMMARIZE_BIN}; skipping."
    fi

    # Retention sweep after the new session's triple is fully in place.
    # cmd_start also prunes (defensive against an archive that was already
    # over-cap when the broker first encountered it), but stop is the
    # canonical enforcement point: without this call a container that
    # already had `keep` archived sessions would briefly hold `keep + 1`
    # until the next start. Failure is non-fatal — teardown continues.
    _prune_archive_for "$container" "$AGENT_ARCHIVE_KEEP_PER_CONTAINER"

    # Remove the ephemeral profile and download dirs — they are session-
    # scoped per ADR 0010 § Actor 1, and any forensic value has already
    # been captured by the archived netlog above. Each path is validated
    # against its managed parent AND the `${container}-` session prefix
    # so a tampered state JSON cannot redirect rm at a sibling session.
    if [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] \
        && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-" \
        && sudo test -d "$profile_dir"; then
        sudo rm -rf -- "$profile_dir" || _warn "Failed to remove profile dir ${profile_dir}."
        _log "Removed profile dir ${profile_dir}."
    elif [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ]; then
        _warn "State profile_dir '${profile_dir}' is outside the managed parent or session; skipping rm."
    fi
    if [ -n "$download_dir" ] && [ "$download_dir" != "null" ] \
        && _is_managed_path "$download_dir" "$AGENT_DOWNLOADS_DIR" "${container}-" \
        && sudo test -d "$download_dir"; then
        sudo rm -rf -- "$download_dir" || _warn "Failed to remove download dir ${download_dir}."
        _log "Removed download dir ${download_dir}."
    elif [ -n "$download_dir" ] && [ "$download_dir" != "null" ]; then
        _warn "State download_dir '${download_dir}' is outside the managed parent or session; skipping rm."
    fi

    # Pre-mark the file Chrome-torn-down / non-consumer when a broker-owned ufw
    # slot could not be released, BEFORE the X-revoke below counts other sessions
    # (finding 1): Chrome was killed and its profile removed above, so this file is
    # no longer a display consumer. Without the marker, this very session's
    # retained file (and any other session's revoke check) would still count it as
    # a live consumer and wrongly keep the shared grant alive. (When the X revoke
    # later fails, the same marking is applied below for the X-retain case too.)
    if [ "$ufw_slot_release_failed" = true ]; then
        _mark_state_file_ufw_retry_only "$state_file"
    fi

    # Revoke the shared per-uid X display grant — DECOUPLED from the ufw-retain
    # decision (finding 1). Chrome is ALWAYS torn down by the time we reach
    # here, so whether or not the state file is retained for a deferred ufw
    # delete, this session is no longer a display consumer and must release its
    # claim on the grant. The grant (`+SI:localuser:boxa-agent`) is keyed on
    # the boxa-agent UID, not the session, and the user routinely runs
    # several sessions at once; revoking while ANOTHER session's Chrome is live
    # would break it — so the revoke is gated on
    # `_revoke_x_display_if_last_session`, which counts only OTHER sessions that
    # are still display consumers (the retain-marked file above is excluded, as
    # is this session's own file by name). The ufw-retain decision governs only
    # whether the STATE FILE is kept for retry; it no longer blocks X
    # revocation (the round-6 hole that left boxa-agent authorized whenever a
    # ufw delete was deferred). Revoke against the `granted_display` captured at
    # the top of cmd_stop (finding 1) — env-independent, so the common
    # no-`$DISPLAY` teardown paths still release the grant instead of leaking it.
    #
    # Capture the revoke rc (#12 review P2): rc 2 == the actual `xhost -SI` FAILED
    # (e.g. a `stop` over SSH with no usable X authorization). Round-11 retains the
    # ownership MARKER on that failure, but the session STATE FILE — which holds the
    # `granted_display` a retry needs — must ALSO be retained, else a repeated
    # `stop` has no state to read and can never retry. We therefore retain the file
    # on an X-revoke failure too, symmetric with the ufw-retain branch. rc 0
    # (revoked, or any no-op: "not last consumer" / "no marker" / "nothing to
    # revoke") needs NO retain.
    local x_revoke_failed=false x_revoke_rc=0
    _revoke_x_display_if_last_session "$container" "$granted_display" || x_revoke_rc=$?
    [ "$x_revoke_rc" -eq 2 ] && x_revoke_failed=true

    # State-file retention decision: retain for retry when EITHER the ufw slot
    # release failed (it is the only record of the durable host ACCEPT rule, read
    # back by the next start's sweep) OR the X revoke failed (it is the only record
    # of `granted_display`, read back by the next stop/sweep to retry the revoke).
    # Both retries need the file; either failure keeps it. When the file is retained
    # for the X-revoke retry alone, it must STILL not count as a display consumer
    # (Chrome is torn down) so it does not pin the grant for OTHER sessions' revoke
    # decisions while awaiting its own retry — apply the same non-consumer marking
    # the ufw branch used above (idempotent if already marked). On success of both,
    # the file is removed as before.
    if [ "$ufw_slot_release_failed" = true ] || [ "$x_revoke_failed" = true ]; then
        if [ "$x_revoke_failed" = true ]; then
            _mark_state_file_ufw_retry_only "$state_file"
        fi
        local retain_reason=""
        if [ "$ufw_slot_release_failed" = true ] && [ "$x_revoke_failed" = true ]; then
            retain_reason="host ufw slot pending release AND X grant revoke pending"
        elif [ "$ufw_slot_release_failed" = true ]; then
            retain_reason="host ufw slot pending release"
        else
            retain_reason="X grant revoke pending"
        fi
        _warn "Retaining state file ${state_file} (${retain_reason}; will retry on next stop/sweep)."
    else
        rm -f -- "$state_file"
        _log "Removed state file ${state_file}."
    fi

    # Toast emission (slice 08). Both events depend on a recoverable
    # session-ts; if the profile_dir tail did not parse we silently skip
    # — the canonical record is on disk under the archive dir.
    local session_ts
    session_ts="$(_session_ts_from_profile_dir "$profile_dir" "$container" || true)"
    if [ -n "$session_ts" ]; then
        if [ "$was_window_active" = true ]; then
            local window_hint=""
            [ -n "$archived_proxy_log_path" ] && window_hint="$archived_proxy_log_path"
            _emit_pending_event "agent-browser-window-close" "$container" "$session_ts" \
                "session-stop" "" "$window_hint"
        fi
        local duration_secs="" session_hint=""
        duration_secs="$(_iso_duration_seconds "$session_created_at" "$(_iso_utc_now)" || true)"
        # Prefer the summary archive path; reconstruction in the deliver
        # script targets the same `.summary.md` location anyway. Hint is
        # diagnostic only.
        session_hint="${AGENT_NETLOG_ARCHIVE_DIR}/${container}-${session_ts}.summary.md"
        _emit_pending_event "agent-browser-session-close" "$container" "$session_ts" \
            "explicit-stop" "$duration_secs" "$session_hint"
    fi
}

# --- URL auto-open helpers ---------------------------------------------------

# Pull the listening-port URLs for `$container` from `boxa ports -m`
# and push each into the running session as a new tab. Auto-open is a
# convenience, not an acceptance criterion: any failure (no `boxa`
# wrapper on PATH, machine-readable parser misbehaving, individual CDP
# call timing out) warns but does not roll back the session. Called
# after the CDP smoke-test in cmd_start; safe to no-op when the
# container has no listening ports yet.
_auto_open_listening_ports() {
    local container="$1" cdp_port="$2"
    [ -n "$container" ] || return 0
    [ -n "$cdp_port" ]  || return 0

    local ports_output=""
    if ! ports_output="$("$BOXA_DIR/docker-run.sh" ports -m 2>/dev/null)"; then
        _warn "Auto-open: failed to query 'boxa ports -m'; skipping."
        return 0
    fi
    if [ -z "$ports_output" ]; then
        _log "Auto-open: no listening ports on ${container}; skipping."
        return 0
    fi

    local urls=() row_container row_port row_url
    while IFS=$'\t' read -r row_container row_port row_url; do
        [ "$row_container" = "$container" ] || continue
        [ -n "$row_url" ] || continue
        urls+=("$row_url")
    done <<< "$ports_output"
    : "${row_port:-}"

    if [ "${#urls[@]}" -eq 0 ]; then
        _log "Auto-open: no listening ports on ${container}; skipping."
        return 0
    fi

    # Reuse the blank tab Chrome opened on launch for the FIRST URL: navigate
    # it in place via CDP `Page.navigate` (WebSocket) instead of opening a new
    # tab and leaving the blank behind. Remaining URLs open as new tabs. The
    # reuse attempt is consumed once; if there is no blank tab or the navigate
    # fails, we fall back to a new-tab open so the project still comes up.
    local reuse_id=""
    reuse_id="$(_list_blank_tab_ids "$cdp_port" | head -n1 || true)"

    local opened=0 failed=0 url reuse_consumed=0
    for url in "${urls[@]}"; do
        if [ "$reuse_consumed" -eq 0 ] && [ -n "$reuse_id" ]; then
            reuse_consumed=1
            if _navigate_tab_via_cdp "$cdp_port" "$reuse_id" "$url"; then
                opened=$((opened + 1))
                _log "Auto-opened (reused initial blank tab): ${url}"
                continue
            fi
            # navigate failed → fall through to a fresh new-tab open below
        fi
        if _open_url_via_cdp "$cdp_port" "$url"; then
            opened=$((opened + 1))
            _log "Auto-opened: ${url}"
        else
            failed=$((failed + 1))
            _warn "Auto-open failed: ${url}"
        fi
    done

    if [ "$opened" -eq 0 ]; then
        _warn "Auto-open: 0/${#urls[@]} URLs opened; session is still up — use 'boxa agent-browser open' to retry."
    elif [ "$failed" -gt 0 ]; then
        _warn "Auto-open: ${failed}/${#urls[@]} URL(s) failed; session is still up."
    fi
}

# --- subcommand: open --------------------------------------------------------

# Push one URL into the running session as a new tab via Chrome DevTools
# Protocol's HTTP endpoint `PUT /json/new?<url>`. The endpoint creates a
# top-level target in the default browser context — no WebSocket
# handshake, no extra Python dep. Chrome's anti-DNS-rebinding guard
# requires the Host header to be `localhost` (not `127.0.0.1`), so the
# call sets it explicitly. The 5s cap mirrors the cmd_start smoke-test
# pattern so a hung tab cannot stall the rest of the batch.
_open_url_via_cdp() {
    local cdp_port="$1" url="$2"
    [ -n "$cdp_port" ] || return 2
    [ -n "$url" ]      || return 2
    local encoded
    if command -v jq >/dev/null 2>&1; then
        encoded="$(jq -rn --arg u "$url" '$u|@uri')"
    else
        encoded="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$url")"
    fi
    curl -sS -X PUT \
        -H "Host: localhost" \
        --max-time 5 \
        --fail \
        --output /dev/null \
        "http://127.0.0.1:${cdp_port}/json/new?${encoded}"
}

# Return the target IDs of "blank" page tabs (new-tab page / about:blank) in
# the session, one per line. Auto-open reuses the first of these as the tab to
# navigate to the project URL (via `_navigate_tab_via_cdp`), so Chrome is not
# left with a leftover blank tab beside the project. The list fetch is HTTP +
# python3 only (no jq hard-dep), mirroring `_open_url_via_cdp`.
_list_blank_tab_ids() {
    local cdp_port="$1"
    [ -n "$cdp_port" ] || return 0
    curl -sS -H "Host: localhost" --max-time 5 \
        "http://127.0.0.1:${cdp_port}/json/list" 2>/dev/null \
        | python3 -c '
import sys, json
try:
    targets = json.load(sys.stdin)
except Exception:
    sys.exit(0)
blanks = {"chrome://newtab/", "about:blank", ""}
for t in targets:
    if t.get("type") == "page":
        url = t.get("url", "")
        if url in blanks or url.startswith("chrome://new-tab-page"):
            print(t.get("id", ""))
' 2>/dev/null
}

# Navigate an existing tab (by target ID) to a URL via CDP `Page.navigate`.
# Unlike the HTTP `/json/*` endpoints — which only create/close/activate
# targets — navigation is a Page-domain command that lives on the per-target
# WebSocket, so this opens a short-lived WS to the target's debugger URL,
# issues one JSON-RPC call, and exits. Self-contained (own minimal WS framing,
# same shape as `_fit_chrome_window_to_work_area`); no external Python deps.
# Best-effort: any failure returns non-zero and the caller falls back to a
# new-tab open. Chrome's anti-DNS-rebinding guard does not apply to the WS
# debugger endpoint, so no Host-header juggling is needed here.
_navigate_tab_via_cdp() {
    local cdp_port="$1" target_id="$2" url="$3"
    [ -n "$cdp_port" ]  || return 2
    [ -n "$target_id" ] || return 2
    [ -n "$url" ]       || return 2
    python3 - "$cdp_port" "$target_id" "$url" <<'PY'
import base64
import http.client
import json
import os
import socket
import struct
import sys


def http_get(port, path):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    conn.request("GET", path)
    body = conn.getresponse().read().decode("utf-8")
    conn.close()
    return json.loads(body)


def ws_connect(url):
    rest = url[len("ws://"):]
    host_port, path = rest.split("/", 1)
    host, port_s = host_port.split(":")
    port = int(port_s)
    sock = socket.create_connection((host, port), timeout=3)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    req = (
        f"GET /{path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(req.encode("ascii"))
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("websocket handshake aborted")
        buf += chunk
    if b"101" not in buf.split(b"\r\n", 1)[0]:
        raise RuntimeError("websocket handshake refused")
    return sock


def ws_send(sock, payload):
    data = payload.encode("utf-8")
    header = bytearray([0x81])
    mask = os.urandom(4)
    if len(data) < 126:
        header.append(0x80 | len(data))
    elif len(data) < 65536:
        header.append(0x80 | 126)
        header += struct.pack(">H", len(data))
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", len(data))
    header += mask
    sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def ws_recv(sock):
    def must(n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("websocket closed")
            buf += chunk
        return buf

    while True:
        b0, b1 = must(2)
        opcode = b0 & 0x0F
        plen = b1 & 0x7F
        if plen == 126:
            (plen,) = struct.unpack(">H", must(2))
        elif plen == 127:
            (plen,) = struct.unpack(">Q", must(8))
        mask = must(4) if (b1 & 0x80) else None
        data = must(plen)
        if mask:
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        if opcode == 0x1:
            return data.decode("utf-8")
        if opcode == 0x8:
            raise RuntimeError("websocket closed by remote")


def main():
    port = int(sys.argv[1])
    target_id = sys.argv[2]
    url = sys.argv[3]

    targets = http_get(port, "/json/list")
    page = next((t for t in targets if t.get("id") == target_id), None)
    if page is None or not page.get("webSocketDebuggerUrl"):
        print("target not found or has no debugger URL", file=sys.stderr)
        return 2

    sock = ws_connect(page["webSocketDebuggerUrl"])
    next_id = 0

    def call(method, params=None):
        nonlocal next_id
        next_id += 1
        msg = {"id": next_id, "method": method}
        if params is not None:
            msg["params"] = params
        ws_send(sock, json.dumps(msg))
        while True:
            resp = json.loads(ws_recv(sock))
            if resp.get("id") == next_id:
                if "error" in resp:
                    raise RuntimeError(resp["error"])
                return resp.get("result", {})

    result = call("Page.navigate", {"url": url})
    if result.get("errorText"):
        print(f"navigate error: {result['errorText']}", file=sys.stderr)
        return 1
    return 0


try:
    sys.exit(main())
except Exception as exc:  # best-effort: caller falls back to a new tab
    print(f"navigate failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

cmd_open() {
    local container
    container="$(_require_container_arg "${1:-}")"
    shift
    if [ "$#" -eq 0 ]; then
        _warn "Usage: agent-browser-broker.sh open <container> <url> [<url>...]"
        exit 2
    fi

    local state_file
    state_file="$(_state_file "$container")"
    if [ ! -f "$state_file" ]; then
        local replacement
        if replacement="$(_offer_session_picker "$container")"; then
            container="$replacement"
            state_file="$(_state_file "$container")"
        else
            _die "No active session for ${container}. Run 'boxa agent-browser start ${container}' first."
        fi
    fi

    local cdp_port chrome_pid profile_dir
    cdp_port="$(_state_get "$state_file" cdp_port_host || true)"
    chrome_pid="$(_state_get "$state_file" chrome_pid || true)"
    profile_dir="$(_state_get "$state_file" profile_dir || true)"
    { [ -n "$cdp_port" ]    && [ "$cdp_port" != "null" ];    } \
        || _die "State file ${state_file} is missing cdp_port_host."
    { [ -n "$chrome_pid" ]  && [ "$chrome_pid" != "null" ];  } \
        || _die "State file ${state_file} is missing chrome_pid."
    { [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ]; } \
        || _die "State file ${state_file} is missing profile_dir."

    # Liveness check matches cmd_status: the recorded PID must still
    # carry the --user-data-dir marker. Refuses to push URLs into a
    # stale session whose Chrome was killed externally.
    local chrome_marker="--user-data-dir=$profile_dir"
    if ! _pid_matches_marker "$chrome_pid" "$chrome_marker"; then
        _die "Chrome for ${container} is not alive (pid ${chrome_pid} no longer matches profile marker). Restart the session."
    fi

    local opened=0 failed=0 url
    for url in "$@"; do
        if _open_url_via_cdp "$cdp_port" "$url"; then
            opened=$((opened + 1))
            _log "Opened: ${url}"
        else
            failed=$((failed + 1))
            _warn "Failed to open: ${url}"
        fi
    done

    if [ "$opened" -eq 0 ]; then
        _warn "No URLs opened (${failed} failed)."
        exit 1
    fi
    if [ "$failed" -gt 0 ]; then
        _warn "${failed} URL(s) failed to open; ${opened} succeeded."
    fi
}

# --- subcommand: status ------------------------------------------------------

cmd_status() {
    local container
    container="$(_require_container_arg "${1:-}")"

    local state_file
    state_file="$(_state_file "$container")"

    if [ ! -f "$state_file" ]; then
        local replacement
        if replacement="$(_offer_session_picker "$container")"; then
            container="$replacement"
            state_file="$(_state_file "$container")"
        else
            _log "No Agent-browser session for ${container}."
            return 0
        fi
    fi

    local chrome_pid bridge_pid relay_pid proxy_pid watchdog_pid cdp_port proxy_port profile_dir created_at
    chrome_pid="$(_state_get "$state_file" chrome_pid || true)"
    bridge_pid="$(_state_get "$state_file" bridge_pid_in_container || true)"
    relay_pid="$(_state_get "$state_file" relay_pid_host || true)"
    proxy_pid="$(_state_get "$state_file" proxy_pid || true)"
    watchdog_pid="$(_state_get "$state_file" watchdog_pid || true)"
    cdp_port="$(_state_get "$state_file" cdp_port_host || true)"
    proxy_port="$(_state_get "$state_file" proxy_port_host || true)"
    profile_dir="$(_state_get "$state_file" profile_dir || true)"
    created_at="$(_state_get "$state_file" created_at || true)"

    local chrome_marker="--user-data-dir=$profile_dir"
    local relay_marker="TCP-LISTEN:${cdp_port}"
    local bridge_marker="socat TCP-LISTEN:${BRIDGE_CONTAINER_PORT}"
    local proxy_marker="--listen 127.0.0.1:${proxy_port}"
    local watchdog_marker="agent-browser-watchdog.sh $container"

    local chrome_status="dead"
    if [ -n "$chrome_pid" ] && _pid_matches_marker "$chrome_pid" "$chrome_marker"; then
        chrome_status="alive"
    fi
    local bridge_status="dead"
    if _container_running "$container" \
        && [ -n "$bridge_pid" ] \
        && _pid_matches_marker_in_container "$container" "$bridge_pid" "$bridge_marker"; then
        bridge_status="alive"
    fi
    local relay_line=""
    if [ -n "$relay_pid" ] && [ "$relay_pid" != "null" ]; then
        local relay_status="dead"
        _pid_matches_marker "$relay_pid" "$relay_marker" && relay_status="alive"
        relay_line="  Relay PID (host):          ${relay_pid} (${relay_status})"
    fi
    local proxy_line=""
    if [ -n "$proxy_pid" ] && [ "$proxy_pid" != "null" ]; then
        local proxy_status="dead"
        _pid_matches_marker "$proxy_pid" "$proxy_marker" && proxy_status="alive"
        proxy_line="  Proxy PID (host):          ${proxy_pid} (${proxy_status})"
    fi
    local watchdog_line=""
    if [ -n "$watchdog_pid" ] && [ "$watchdog_pid" != "null" ]; then
        local watchdog_status="dead"
        _pid_matches_marker "$watchdog_pid" "$watchdog_marker" && watchdog_status="alive"
        watchdog_line="  Watchdog PID (host):       ${watchdog_pid} (${watchdog_status})"
    fi

    cat <<EOF
Agent-browser session for ${container}:
  Created at:                ${created_at:-?}
  Chrome PID (host):         ${chrome_pid:-?} (${chrome_status})
EOF
    [ -n "$relay_line" ] && printf '%s\n' "$relay_line"
    [ -n "$proxy_line" ] && printf '%s\n' "$proxy_line"
    [ -n "$watchdog_line" ] && printf '%s\n' "$watchdog_line"
    cat <<EOF
  Bridge PID (in container): ${bridge_pid:-?} (${bridge_status})
  CDP (host):                127.0.0.1:${cdp_port:-?}
  Proxy (host):              127.0.0.1:${proxy_port:-?}
  CDP (in container):        127.0.0.1:${BRIDGE_CONTAINER_PORT}
  Profile dir:               ${profile_dir:-?}
  State file:                ${state_file}
EOF

    # Network window (slice 05). Only printed when the state file
    # records an active window — silent otherwise to keep `status` short
    # for the common no-window case. python3 is the canonical parser
    # for the nested object; the jq path is a faster shortcut when
    # available.
    local window_block=""
    if command -v jq >/dev/null 2>&1; then
        window_block="$(jq -r '
            if .active_network_window == null then
                empty
            else
                "  Network window:            harvest until \(.active_network_window.expires_at) (started \(.active_network_window.started_at))"
            end
        ' "$state_file" 2>/dev/null || true)"
    else
        window_block="$(python3 - "$state_file" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    window = data.get("active_network_window")
    if window:
        print(f"  Network window:            harvest until {window.get('expires_at')} (started {window.get('started_at')})")
except Exception:
    pass
PY
)"
    fi
    if [ -n "$window_block" ]; then
        printf '%s\n' "$window_block"
    fi
}

# --- Dispatch ----------------------------------------------------------------

main() {
    local sub="${1:-}"
    [ -n "$sub" ] || { _usage >&2; exit 2; }
    shift
    case "$sub" in
        start)     cmd_start       "$@" ;;
        stop)      cmd_stop        "$@" ;;
        status)    cmd_status      "$@" ;;
        open)      cmd_open        "$@" ;;
        allow-for) cmd_allow_for   "$@" ;;
        allow)     cmd_agent_allow "$@" ;;
        deny)      cmd_agent_deny  "$@" ;;
        blocked)   cmd_agent_blocked "$@" ;;
        denied-hosts-global)
            # Internal helper used by the unified `boxa blocked` view in
            # docker-run.sh. Emits one denied host per line (live ∪ archived
            # across all containers, deduplicated, allowlist-filtered). Not
            # in the user-facing help: this is a Slice C wire-up surface, not
            # a public sub-command. ADR 0012 § Surface.
            _denied_hosts_global ;;
        -h|--help|help) _usage ;;
        *) _usage >&2; exit 2 ;;
    esac
}

main "$@"
