#!/bin/bash
set -euo pipefail

# =============================================================================
# deliver-allow-for-notification — host-side notification dispatcher (ADR 0009)
# =============================================================================
# The in-container teardown daemon writes a small JSON `pending` file when a
# window closes (see scripts/teardown-allow-for-window.sh). This script reads
# those files and fires a notification on the host. Three modes:
#
#   <file.json>                One specific pending file. Used by --sweep
#                              under the hood; rarely called directly.
#   --sweep                    Scan /var/log/boxa/allow-for/ for every
#                              .pending-*.json and deliver each. Invoked at
#                              the start of every `boxa` command (fire-
#                              and-forget) so missed notifications surface
#                              on the user's next interaction.
#   --watch <container> <expires_iso>
#                              Background poller spawned by `boxa
#                              allow-for` start. Polls until either a
#                              pending arrives for this container, or
#                              <expires_iso> + grace passes (safety net for
#                              dead daemons).
#
# Cascade per platform:
#   WSL2 + powershell.exe   → COM toast with protocol activation → click
#                              opens the harvest log in the default editor.
#   Linux + notify-send     → passive notification; log path is in the
#                              body, no click action (depends on daemon).
#   macOS + osascript       → passive `display notification`; no click
#                              action without a third-party helper.
#   anything else           → silent. Harvest log is the canonical record.
#
# Delivery is best-effort. A failed dispatch leaves the pending file in
# place; the next --sweep retries.
# =============================================================================

# --- Constants ---------------------------------------------------------------
# Pending notification files (input to this script) live in a host-user-
# owned subdir so the atomic rename-claim below can succeed; the parent
# log dir stays root:root 0755 for the tamper-proof harvest-log
# guarantee (ADR 0009 §3-4). Harvest log paths come straight out of each
# pending JSON's `log_path` field, so this script never needs to know
# the log dir directly.
ALLOW_FOR_PENDING_DIR="/var/log/boxa/allow-for/pending"
# Agent-browser toast pending dir + archive / profile roots (ADR 0010 +
# slice 08). The pending dir is host-user-owned (XDG state), so no sudo
# is needed for sweep. Archive + profile roots are boxa-agent-owned;
# we only stat through them (`sudo test`) to reconstruct trusted click
# targets — no reads of attacker-controlled content.
AGENT_BROWSER_PENDING_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/boxa/agent-browser/pending"
# Archive + profile roots are env-overridable solely for the
# slice-08 reconstruction test (no production knob). Defaults match
# the broker's hardcoded layout. Overrides MUST be absolute paths;
# the per-event validator still enforces filesystem-trust against the
# resulting trusted_path so a hostile env can only re-anchor reads at
# a different absolute prefix, not bypass the existence check.
AGENT_BROWSER_ARCHIVE_DIR="${BOXA_AGENT_BROWSER_ARCHIVE_DIR:-/var/log/boxa/agent-browser}"
AGENT_BROWSER_PROFILES_DIR="${BOXA_AGENT_BROWSER_PROFILES_DIR:-/var/lib/boxa-agent/profiles}"
WSL_APP_ID="Boxa.AllowFor"
# Files older than this are dropped on --sweep with a stderr warning. Keeps
# a stale pending from a long-past unclean shutdown from firing at every
# `boxa` invocation forever.
STALE_HOURS=24
# Watcher polling: snappy enough that the toast lands within seconds of the
# window closing, slow enough to be free on a laptop.
WATCH_POLL_SECONDS=10
# After expires_at, give the in-container daemon this long to actually
# write the pending file. Covers heartbeat latency, dnsmasq restart, log
# aggregation. Beyond that we conclude the daemon never delivered and exit
# the watcher so it doesn't loop forever.
WATCH_GRACE_SECONDS=120

# --- Diagnostics -------------------------------------------------------------
# Watcher and sweeper both run detached so stderr usually ends up in
# /dev/null. Keep the warnings anyway — direct invocation from a shell or
# from `bash -x` still surfaces them, and they're cheap.
_warn() { printf 'deliver-allow-for: WARN: %s\n' "$*" >&2; }

is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }
is_macos() { [ "$(uname -s 2>/dev/null)" = "Darwin" ]; }

# Parse a timestamp produced by `allow_for::now_iso` /
# `allow_for::iso_plus_minutes` — i.e. `%Y-%m-%dT%H:%M:%S%z` like
# `2026-05-16T07:30:15+0200`. Prints the epoch on stdout; returns
# non-zero on parse failure.
#
# Two implementations: GNU date `-d` (Linux), then BSD date `-j -f`
# (macOS). The format string is fixed by the writer side, so we don't
# need to handle every ISO-8601 variant — just the one shape boxa
# actually emits.
iso_to_epoch() {
    local iso="$1" epoch
    if epoch=$(date -d "$iso" +%s 2>/dev/null); then
        printf '%s\n' "$epoch"
        return 0
    fi
    if epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$iso" +%s 2>/dev/null); then
        printf '%s\n' "$epoch"
        return 0
    fi
    return 1
}

# --- Pending JSON parsing ----------------------------------------------------
# Sets P_CONTAINER, P_LOG_PATH, P_REASON, P_DOMAIN_COUNT, P_TOP_DOMAINS as
# side effects so callers can read them without subshell-stripping arrays.
# Returns non-zero on a structurally broken file so the caller can leave
# the pending in place for human triage. Fields like started_at/ended_at
# live in the JSON for the harvest log's audit trail but aren't surfaced
# in the toast, so we skip parsing them.
#
# We control the writer (teardown-allow-for-window.sh do_teardown), so the
# JSON shape is fixed and flat — no nested objects, no arrays of objects.
# That's why a grep+sed fallback when jq is missing is acceptable; we never
# have to reason about JSON pathologies the writer can't produce.
parse_pending() {
    local file="$1"
    [ -f "$file" ] || return 1

    P_CONTAINER=""; P_LOG_PATH=""; P_REASON=""
    P_DOMAIN_COUNT=0; P_TOP_DOMAINS=""
    # Agent-browser additions (slice 08). Default-empty so the allow-for
    # path keeps working unchanged when the event-class fields are
    # missing from a pending JSON. `event` is parsed for diagnostic
    # purposes only — the actual class dispatch in `deliver_one` runs
    # off the filename prefix, never off this JSON field.
    P_SESSION_TS=""; P_DURATION_SECONDS=""

    if command -v jq >/dev/null 2>&1; then
        local out sentinel='__EMPTY__'
        # One jq invocation, tab-separated. `// ""` keeps missing fields
        # from breaking the read-into-vars below. Numeric fields use `// 0`
        # / `// ""` so absence stays parseable.
        #
        # The literal $sentinel substitutes for empty strings before the
        # @tsv encoding: bash's `read` collapses runs of whitespace IFS
        # characters (tab included) when IFS is non-default-but-still-
        # whitespace, so consecutive empty TSV fields would otherwise
        # vanish. We strip the sentinel back out per-variable below.
        out=$(jq -r --arg s "$sentinel" '
            def nonempty(s): if (s|tostring|length) == 0 then $s else (s|tostring) end;
            [ nonempty(.container // ""),
              nonempty(.log_path  // ""),
              nonempty(.reason    // ""),
              (.domain_count // 0),
              nonempty(.top_domains // ""),
              nonempty(.session_ts // ""),
              nonempty(.duration_seconds // "")
            ] | @tsv
        ' "$file" 2>/dev/null) || return 1
        IFS=$'\t' read -r P_CONTAINER P_LOG_PATH P_REASON \
            P_DOMAIN_COUNT P_TOP_DOMAINS \
            P_SESSION_TS P_DURATION_SECONDS <<< "$out"
        [ "$P_CONTAINER"        = "$sentinel" ] && P_CONTAINER=""
        [ "$P_LOG_PATH"         = "$sentinel" ] && P_LOG_PATH=""
        [ "$P_REASON"           = "$sentinel" ] && P_REASON=""
        [ "$P_TOP_DOMAINS"      = "$sentinel" ] && P_TOP_DOMAINS=""
        [ "$P_SESSION_TS"       = "$sentinel" ] && P_SESSION_TS=""
        [ "$P_DURATION_SECONDS" = "$sentinel" ] && P_DURATION_SECONDS=""
        # jq renders a missing numeric as the literal "null" string after
        # tostring; flatten that back to empty so the downstream check
        # treats it as "unknown".
        [ "$P_DURATION_SECONDS" = "null" ] && P_DURATION_SECONDS=""
    else
        # Fallback parser for hosts without jq. Matches the exact shape
        # teardown-allow-for-window.sh / agent-browser-broker.sh write:
        # one `"key": value` or `"key": "value"` per line. Strings are
        # unquoted, numbers stay literal. The regex tolerates leading
        # whitespace and trailing comma but nothing more exotic — fine
        # because we own the writers.
        local raw key val
        while IFS= read -r raw; do
            key=$(printf '%s' "$raw" | sed -n 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*:.*/\1/p')
            [ -z "$key" ] && continue
            val=$(printf '%s' "$raw" | sed -n 's/^[[:space:]]*"[^"]*"[[:space:]]*:[[:space:]]*\(.*\)[[:space:]]*$/\1/p')
            # Strip a single trailing comma (last field has none).
            val="${val%,}"
            # Strip a single pair of surrounding double-quotes for string
            # values. Numbers stay as-is.
            case "$val" in
                \"*\") val="${val#\"}"; val="${val%\"}" ;;
            esac
            case "$key" in
                container)        P_CONTAINER="$val" ;;
                log_path)         P_LOG_PATH="$val" ;;
                reason)           P_REASON="$val" ;;
                domain_count)     P_DOMAIN_COUNT="$val" ;;
                top_domains)      P_TOP_DOMAINS="$val" ;;
                session_ts)       P_SESSION_TS="$val" ;;
                duration_seconds) [ "$val" = "null" ] || P_DURATION_SECONDS="$val" ;;
            esac
        done < "$file"
    fi

    # Container is mandatory across event classes. Allow-for additionally
    # requires log_path; agent-browser reconstructs log_path from the
    # filename so its mandatory field is `event` instead. The caller's
    # type-specific validator enforces these post-parse.
    [ -n "$P_CONTAINER" ]
}

# --- Toast body composition --------------------------------------------------
# Sets T_TITLE and T_BODY based on the last parse_pending call. Kept pure
# (no fork/exec, no env-lookup) so it's trivial to test in isolation.
#
# Body shape is identical across platforms — the rendering layer
# (PowerShell vs notify-send vs osascript) differs only in how it places
# the strings on screen.
build_toast_body() {
    local title_verb
    case "$P_REASON" in
        stopped)     title_verb="closed manually" ;;
        interrupted) title_verb="interrupted by restart" ;;
        *)           title_verb="closed" ;;  # `expired` and unknown both fall here
    esac
    T_TITLE="boxa allow-for ${title_verb}: ${P_CONTAINER}"

    local count_line
    if [ "${P_DOMAIN_COUNT:-0}" = "0" ]; then
        count_line="No domains outside the allowlist were queried."
    elif [ "${P_DOMAIN_COUNT:-0}" = "1" ]; then
        count_line="1 domain outside the allowlist."
    else
        count_line="${P_DOMAIN_COUNT} domains outside the allowlist."
    fi

    local top_line=""
    if [ -n "$P_TOP_DOMAINS" ]; then
        # Writer joins top domains with `|`. Render as bullets, keep the
        # body compact for Action Center (~200 char target).
        top_line="Top: $(printf '%s' "$P_TOP_DOMAINS" | tr '|' '/' | sed 's:/: · :g')"
    fi

    if [ -n "$top_line" ]; then
        T_BODY="${count_line}"$'\n'"${top_line}"
    else
        T_BODY="${count_line}"
    fi
}

# --- Toast body composition: agent-browser (slice 08) ------------------------
# Two event classes, both produced by scripts/agent-browser-broker.sh:
# session-close (fires when the agent-browser session ends) and
# window-close (fires when the per-window network gate closes).
# Reason / duration / container come from the bounded, post-validation
# globals set by `parse_pending` + the per-class validator.
build_toast_body_agent_browser_session() {
    T_TITLE="Agent-browser session ended: ${P_CONTAINER}"
    if [ -n "$P_DURATION_SECONDS" ]; then
        local mins secs
        mins=$(( P_DURATION_SECONDS / 60 ))
        secs=$(( P_DURATION_SECONDS % 60 ))
        if [ "$mins" -gt 0 ]; then
            T_BODY="Container: ${P_CONTAINER}"$'\n'"Duration: ${mins}m ${secs}s"
        else
            T_BODY="Container: ${P_CONTAINER}"$'\n'"Duration: ${secs}s"
        fi
    else
        T_BODY="Container: ${P_CONTAINER}"
    fi
}

build_toast_body_agent_browser_window() {
    T_TITLE="Agent-browser network window closed: ${P_CONTAINER}"
    local reason_line=""
    case "$P_REASON" in
        timer-expiry)   reason_line="Reason: timer expired" ;;
        explicit-stop)  reason_line="Reason: stopped manually" ;;
        session-stop)   reason_line="Reason: session ended" ;;
        *)              reason_line="" ;;
    esac
    if [ -n "$reason_line" ]; then
        T_BODY="Container: ${P_CONTAINER}"$'\n'"${reason_line}"
    else
        T_BODY="Container: ${P_CONTAINER}"
    fi
}

# --- Filesystem-trust validation: agent-browser (slice 08) -------------------
# Mirrors the allow-for reconstruction discipline: derive the trusted
# click-target path from the pending filename + the canonical archive /
# profile roots, NEVER from a JSON field the writer set. The host-side
# broker that emits agent-browser events runs as the developer, but the
# pending dir lives under XDG state where the in-container `node` UID
# (which is the developer UID at the host kernel layer) can still
# replace files. The same threat model that motivated ADR 0009 applies
# here, so we apply the same defence.
#
# Both functions overwrite P_CONTAINER and P_LOG_PATH with the trusted
# derivatives and bound P_REASON to the small enum the writer emits.
# P_DURATION_SECONDS stays as the writer's value but is bounded to
# digits-only so the body builder never embeds shell metacharacters.
#
# `pending_basename_norm` is the basename minus `.json` (and the
# `.pending-ab-<kind>-` prefix already stripped). Caller guarantees it.
#
# Returns 0 on success, non-zero on validation failure (caller drops the
# pending). Sets P_LOG_PATH to the chosen trusted path; for window-close
# the live profile path is preferred during the session and the archive
# path is preferred after `cmd_stop`.
_validate_agent_browser_common() {
    local pending="$1" body_norm="$2"
    # Strict shape: [A-Za-z0-9._-]+ container charset (matches broker's
    # _require_container_arg) joined by `-` to a compact ISO ts
    # ([0-9]{8}T[0-9]{6}Z) the broker stamps at session start, plus an
    # optional numeric `-<emit_ts>` suffix so repeated events for one
    # session (multiple allow-for windows opened/closed within the same
    # session) get unique pending filenames and survive retry under
    # transient backend failure.
    if ! [[ "$body_norm" =~ ^([A-Za-z0-9._-]+)-([0-9]{8}T[0-9]{6}Z)(-([0-9]+))?$ ]]; then
        _warn "rejecting pending: filename does not match agent-browser writer pattern: $pending"
        return 1
    fi
    P_CONTAINER="${BASH_REMATCH[1]}"
    P_SESSION_TS="${BASH_REMATCH[2]}"
    # Defensive: refuse container basenames the reconstruction would
    # collapse to a traversal anchor under the archive root.
    case "$P_CONTAINER" in
        .|..|*/*) _warn "rejecting pending: container name unsafe: $pending"; return 1 ;;
    esac
    # Reason bounding (window-close uses three known values; session-
    # close accepts a wider set but the body builder ignores unknowns).
    case "$P_REASON" in
        timer-expiry|explicit-stop|session-stop|container-stop) ;;
        *) P_REASON="" ;;
    esac
    # Numeric bounding for duration_seconds.
    case "$P_DURATION_SECONDS" in
        ""|*[!0-9]*) P_DURATION_SECONDS="" ;;
    esac
    return 0
}

_validate_agent_browser_session() {
    local pending="$1" body_norm="$2"
    _validate_agent_browser_common "$pending" "$body_norm" || return 1
    local trusted="${AGENT_BROWSER_ARCHIVE_DIR}/${P_CONTAINER}-${P_SESSION_TS}.summary.md"
    # The archive dir is boxa-agent-owned 0750 — the developer reads
    # via group membership; `sudo test` covers the case where the
    # developer is not yet in that group and the existence check would
    # otherwise false-negative.
    if [ ! -f "$trusted" ] && ! sudo test -f "$trusted" 2>/dev/null; then
        _warn "rejecting pending: summary missing for session-close: $trusted"
        return 1
    fi
    P_LOG_PATH="$trusted"
    return 0
}

_validate_agent_browser_window() {
    local pending="$1" body_norm="$2"
    _validate_agent_browser_common "$pending" "$body_norm" || return 1
    # Two valid reconstruction paths, tried in order: the post-stop
    # archive (preferred — readable to the developer once session ended)
    # and the live per-session proxy log under the boxa-agent profile
    # dir (used when window-close fires mid-session). Either is safe;
    # neither comes from JSON content.
    local archive_path="${AGENT_BROWSER_ARCHIVE_DIR}/${P_CONTAINER}-${P_SESSION_TS}.proxy.log"
    local live_path="${AGENT_BROWSER_PROFILES_DIR}/${P_CONTAINER}-${P_SESSION_TS}/proxy.log"
    if [ -f "$archive_path" ] || sudo test -f "$archive_path" 2>/dev/null; then
        P_LOG_PATH="$archive_path"
        return 0
    fi
    if [ -f "$live_path" ] || sudo test -f "$live_path" 2>/dev/null; then
        P_LOG_PATH="$live_path"
        return 0
    fi
    # Reject when neither the live nor archived per-session proxy log
    # exists. The pending dir is host-user-owned (forgeable by the
    # in-container node UID); without a boxa-agent-owned per-session
    # artifact to anchor the toast we have no proof the session ever
    # ran. Falling back to the archive dir here would let an attacker
    # manufacture window-close toasts for sessions that never existed.
    _warn "rejecting pending: no live or archived proxy log for ${P_CONTAINER}-${P_SESSION_TS}: $pending"
    return 1
}

# --- Path conversion for Windows protocol activation ------------------------
# Turn /var/log/boxa/allow-for/<container>-<ts>.log into a file:// URI
# Windows accepts via the toast's protocol activation. Used as the toast
# launch attribute; click opens the log in the default .log handler
# (usually Notepad).
#
# `wslpath -w` returns a UNC like `\\wsl.localhost\Ubuntu\var\log\...`.
# RFC 8089 file: scheme uses forward slashes and pulls the UNC host into
# the authority component:
#
#   \\wsl.localhost\Ubuntu\var\log\foo.log
#                                              ↓
#   file://wsl.localhost/Ubuntu/var/log/foo.log
#
# Encoding pass keeps the URI-safe characters as-is and percent-encodes
# the rest. Notable triggers in real paths: `+` from timestamp offsets
# (`2026-05-16T07-30-15+0200`), spaces in distro names, `#`/`?` should
# they ever appear in container slugs.
to_file_uri() {
    local linux_path="$1" win_path forward uri
    win_path=$(wslpath -w "$linux_path" 2>/dev/null) || return 1
    [ -n "$win_path" ] || return 1
    # Backslashes → forward slashes. The leading `\\` of the UNC becomes
    # `//`, which combined with the `file:` emit below produces the
    # correct `file://<host>/...` authority form.
    forward="${win_path//\\//}"
    uri=$(printf '%s' "$forward" | awk '
        BEGIN {
            for (i = 0; i < 256; i++) hex[sprintf("%c", i)] = sprintf("%%%02X", i)
        }
        {
            out = ""
            n = length($0)
            for (i = 1; i <= n; i++) {
                ch = substr($0, i, 1)
                if (ch ~ /[A-Za-z0-9._~\/:-]/) out = out ch
                else                            out = out hex[ch]
            }
            print out
        }
    ')
    printf 'file:%s\n' "$uri"
}

# --- Backend availability predicates ----------------------------------------
# Cleanly separate "is this backend applicable on this host" from "did
# delivery succeed". deliver_one uses the predicates to pick which
# backend's deliver_* function to call; transient delivery failures
# (e.g. powershell.exe rc != 0, DBus down) trigger retry-on-next-sweep,
# while a host with no applicable backend at all gets one warning and
# the pending is dropped to avoid looping forever against a dead cascade.
backend_available_windows() {
    is_wsl2 \
        && command -v powershell.exe >/dev/null 2>&1 \
        && command -v wslpath        >/dev/null 2>&1
}
backend_available_macos() {
    is_macos && command -v osascript >/dev/null 2>&1
}
backend_available_linux() {
    command -v notify-send >/dev/null 2>&1 \
        && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]
}

# --- Delivery: Windows COM toast --------------------------------------------
# Inline COM toast under the HKCU AppId provisioned in
# ensure-allow-for-host-state.sh. Click activation goes through protocol
# activation — Windows resolves the `launch` URI through its standard
# protocol handlers, which is why no UWP activator COM server registration
# is needed (`activationType="protocol"`).
#
# The inner PowerShell script reads its inputs from env vars (set on the
# powershell.exe invocation) instead of string-interpolating them, so we
# never have to worry about escaping quotes, ampersands, or newlines in
# the body. Toast XML escaping happens inside PowerShell via
# [System.Security.SecurityElement]::Escape.
#
# Returns 0 on Show() success; non-zero on transient failure (PowerShell
# rc != 0). Caller guarantees the platform is WSL2 and powershell.exe +
# wslpath are present (see backend_available_windows).
deliver_windows() {
    local launch_uri
    launch_uri=$(to_file_uri "$P_LOG_PATH") || launch_uri=""

    local inner
    inner=$(cat <<'PS_INNER'
$ErrorActionPreference = 'Stop'
try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime] | Out-Null

    $title  = [System.Security.SecurityElement]::Escape($env:BOXA_TOAST_TITLE)
    $body   = [System.Security.SecurityElement]::Escape($env:BOXA_TOAST_BODY)
    $launch = [System.Security.SecurityElement]::Escape($env:BOXA_TOAST_LAUNCH)
    $appId  = $env:BOXA_TOAST_APPID

    # Body may legitimately contain a newline (count line + top line).
    # Two <text> elements render as separate lines inside the toast body.
    $bodyParts = $body -split "`n", 2
    $bodyXml = ""
    foreach ($p in $bodyParts) {
        if ($p) { $bodyXml += "<text>$p</text>" }
    }

    $actionsXml = "<actions><action content='Dismiss' arguments='dismiss' activationType='system'/></actions>"
    if ($launch) {
        $toastXml = "<toast activationType='protocol' launch='$launch' scenario='reminder'><visual><binding template='ToastGeneric'><text>$title</text>$bodyXml</binding></visual>$actionsXml</toast>"
    } else {
        $toastXml = "<toast scenario='reminder'><visual><binding template='ToastGeneric'><text>$title</text>$bodyXml</binding></visual>$actionsXml</toast>"
    }

    $xmlDoc = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]::new()
    $xmlDoc.LoadXml($toastXml)

    $toast    = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime]::new($xmlDoc)
    $notifier = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]::CreateToastNotifier($appId)
    $notifier.Show($toast)
    exit 0
} catch {
    # Surface typed exception details on stderr so failures are
    # diagnosable. Our caller redirects to /dev/null in steady state,
    # but a `bash -x` or a temporary patch will see this line.
    [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
    [Console]::Error.WriteLine("TYPE:  $($_.Exception.GetType().FullName)")
    exit 1
}
PS_INNER
)

    local encoded
    encoded=$(printf '%s' "$inner" | iconv -t UTF-16LE 2>/dev/null | base64 -w0 2>/dev/null) || return 1

    # `WSLENV` is required to forward env vars across the WSL/Windows
    # boundary — without it, PowerShell sees `$env:BOXA_TOAST_*` as
    # empty strings, `CreateToastNotifier("")` throws, and our catch
    # block silently exits 1. The colon-separated list names every
    # variable that must cross.
    WSLENV="BOXA_TOAST_APPID:BOXA_TOAST_TITLE:BOXA_TOAST_BODY:BOXA_TOAST_LAUNCH" \
    BOXA_TOAST_APPID="$WSL_APP_ID" \
    BOXA_TOAST_TITLE="$T_TITLE" \
    BOXA_TOAST_BODY="$T_BODY" \
    BOXA_TOAST_LAUNCH="$launch_uri" \
        powershell.exe -NoProfile -EncodedCommand "$encoded" >/dev/null 2>&1
}

# --- Delivery: Linux notify-send --------------------------------------------
# Clickable notification at parity with the WSL2 toast: a single `default`
# action that mako/dunst/GNOME invoke on a body click, opening the log via
# `xdg-open`. See ADR 0009 "Revision — clickable action on native Linux".
#
# `notify-send -A` implies `--wait`, so it blocks until the user clicks or
# the notification closes. Our caller (deliver_one, via --sweep and --watch)
# must not block, so we fire the listener in a detached subshell and return
# the instant the notification is shown — delivered == shown, mirroring the
# WSL2 `Show()`. The log path also stays in the body so a daemon without
# action support still shows where the log is.
#
# `-t 0` (freedesktop "never expire") keeps the notification on screen until
# the user clicks it — they are usually away when a window closes. No
# listener timeout, so the click works for as long as it is on screen.
#
# Returns 0 once the notification is dispatched. Unlike the Windows/macOS
# backends there is no rc-driven retry: the detached subshell returns before
# its notify-send resolves, so a notification lost to a momentarily-dead
# daemon is silently dropped (accepted — the log file is the canonical
# record and is always on disk). Caller guarantees notify-send is in PATH
# and a display env var is set.
deliver_linux() {
    local body="${T_BODY}"$'\n'"Log: ${P_LOG_PATH}"

    # Clickable path requires both xdg-open (to handle the click) and a
    # notify-send new enough to understand `-A` (old libnotify lacks it,
    # and passing -A there would error out and show nothing).
    if command -v xdg-open >/dev/null 2>&1 \
        && notify-send --help 2>&1 | grep -q -- '--action'; then
        # The subshell snapshots T_TITLE/body/P_LOG_PATH at fork time, so a
        # subsequent --sweep iteration overwriting the globals is harmless.
        (
            action=$(notify-send -t 0 -u normal -a "boxa" \
                       -A "default=Open log" \
                       "$T_TITLE" "$body" 2>/dev/null)
            [ "$action" = "default" ] && xdg-open "$P_LOG_PATH" >/dev/null 2>&1
        ) >/dev/null 2>&1 &
        disown
        return 0
    fi

    # Fallback: passive notification (old libnotify or no xdg-open). Path in
    # the body lets the user open it manually.
    notify-send -t 0 -u normal -a "boxa" \
        "$T_TITLE" "$body" 2>/dev/null
}

# --- Delivery: macOS osascript ----------------------------------------------
# `display notification` from osascript has no click activation. We render
# the body and include the path so the user can copy-paste it. Caller
# guarantees the platform is Darwin and osascript is available.
deliver_macos() {
    # AppleScript strings escape `"` as `\"`. Title and body come from
    # parse_pending (controlled input), but escape defensively anyway.
    local title body path
    title=${T_TITLE//\"/\\\"}
    body=${T_BODY//\"/\\\"}
    body="${body//$'\n'/ — }"
    path=${P_LOG_PATH//\"/\\\"}
    osascript -e "display notification \"${body} — Log: ${path}\" with title \"${title}\"" >/dev/null 2>&1
}

# --- Cascade -----------------------------------------------------------------
# Deliver one pending file. Three possible outcomes:
#
#   delivered  Backend was applicable AND succeeded. Drop the claim.
#   failed     Backend was applicable but failed transiently (PowerShell
#              rc != 0, DBus down, osascript error). Restore claim →
#              pending so the next sweep retries.
#   silent     No applicable backend on this host (headless server,
#              non-WSL2 Windows distro, etc.). Drop the claim — retrying
#              against the same dead cascade would spam forever; the
#              harvest log is canonical anyway.
#
# Concurrent deliveries (reset-clock spawns a second watcher; sweep races
# a watcher) are serialised via atomic rename-claim: whichever process
# wins the `mv pending → pending.lock` race owns the delivery; the
# loser's `mv` returns non-zero and it bails out cleanly.
deliver_one() {
    local pending="$1"
    local claim="${pending}.lock"

    # rename(2) is atomic on Linux/macOS: exactly one of N concurrent
    # `mv pending claim` calls succeeds; the rest fail with ENOENT. The
    # `.lock` suffix lands outside both sweep (`.pending-*.json`) and
    # watch (`.pending-<container>-*.json`) globs, so a half-delivered
    # file isn't re-picked-up by a sibling process.
    if ! mv "$pending" "$claim" 2>/dev/null; then
        return 0
    fi

    if ! parse_pending "$claim"; then
        _warn "unparseable pending file: $pending — leaving in place"
        # Restore so a human can inspect and the next sweep doesn't
        # vanish the file. rm -f fallback if restore itself fails
        # (e.g. perms changed mid-flight): a broken pending we can't
        # parse is no use to retry anyway.
        mv "$claim" "$pending" 2>/dev/null || rm -f "$claim"
        return 1
    fi

    # --- Filesystem-trust validation (security boundary) ---
    # The pending hand-off dir is host-user-owned, so the in-container
    # node user (UID 1000 on both sides of the bind mount) can forge,
    # replace, or delete `.pending-*.json` files. Treat every JSON
    # field as untrusted input. Lean on filesystem invariants the
    # attacker cannot subvert: the filename matches a strict writer
    # pattern, and the click target is reconstructed from filename
    # components anchored at a root-owned (allow-for) or
    # boxa-agent-owned (agent-browser) directory.
    #
    # Three dispatchers, picked by the basename's lead segment:
    #   .pending-ab-session-…    agent-browser session-close (slice 08)
    #   .pending-ab-window-…     agent-browser window-close  (slice 08)
    #   .pending-…               allow-for harvest closeout  (ADR 0009)
    local pending_base
    pending_base=$(basename "$pending" .json)
    local event_kind=""
    local body_norm=""
    case "$pending_base" in
        .pending-ab-session-*)
            event_kind="agent-browser-session"
            body_norm="${pending_base#.pending-ab-session-}"
            ;;
        .pending-ab-window-*)
            event_kind="agent-browser-window"
            body_norm="${pending_base#.pending-ab-window-}"
            ;;
        .pending-*)
            event_kind="allow-for"
            body_norm="${pending_base#.pending-}"
            ;;
        *)
            _warn "rejecting pending: unknown filename shape: $pending"
            rm -f "$claim"
            return 1
            ;;
    esac
    case "$event_kind" in
        allow-for)
            # Note: `[-+]` (dash first) — `[+-]` in some bash builds is parsed as
            # the range U+002B..U+002D (`+,-`), which happens to include `+` but
            # tickles a locale-dependent BASH_REMATCH bug where captures come
            # back empty even on a successful match. Dash-first is unambiguous.
            if ! [[ "$body_norm" =~ ^([a-zA-Z0-9-]+)-([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}[-+][0-9]{4})$ ]]; then
                _warn "rejecting pending: filename does not match writer pattern: $pending"
                rm -f "$claim"
                return 1
            fi
            local trusted_container="${BASH_REMATCH[1]}"
            local trusted_log_path="/var/log/boxa/allow-for/${body_norm}.log"
            if [ ! -f "$trusted_log_path" ]; then
                _warn "rejecting pending: corresponding harvest log missing: $trusted_log_path"
                rm -f "$claim"
                return 1
            fi
            P_CONTAINER="$trusted_container"
            P_LOG_PATH="$trusted_log_path"
            case "$P_REASON" in
                expired|stopped|interrupted) ;;
                *) P_REASON="expired" ;;
            esac
            case "$P_DOMAIN_COUNT" in
                *[!0-9]*|"") P_DOMAIN_COUNT=0 ;;
            esac
            # Bound the attacker-controlled top-domains string before it
            # reaches the renderers. Each backend does its own XML / shell
            # escaping, but a kilobyte-long body can wedge Action Center
            # rendering on Windows; cap it here so all paths benefit.
            P_TOP_DOMAINS="${P_TOP_DOMAINS:0:200}"
            build_toast_body
            ;;
        agent-browser-session)
            if ! _validate_agent_browser_session "$pending" "$body_norm"; then
                rm -f "$claim"
                return 1
            fi
            build_toast_body_agent_browser_session
            ;;
        agent-browser-window)
            if ! _validate_agent_browser_window "$pending" "$body_norm"; then
                rm -f "$claim"
                return 1
            fi
            build_toast_body_agent_browser_window
            ;;
    esac

    # Pick a backend by applicability, then run delivery. Outcome
    # depends on both — only "applicable but failed" preserves the
    # pending file for retry.
    local outcome="silent"
    if backend_available_windows; then
        if deliver_windows; then outcome="delivered"; else outcome="failed"; fi
    elif backend_available_macos; then
        if deliver_macos;   then outcome="delivered"; else outcome="failed"; fi
    elif backend_available_linux; then
        if deliver_linux;   then outcome="delivered"; else outcome="failed"; fi
    fi

    case "$outcome" in
        delivered)
            rm -f "$claim"
            ;;
        silent)
            # One quiet log line per pending — the harvest log on disk
            # is the canonical record, the user just won't see a toast.
            _warn "no notification backend available — relying on harvest log: $P_LOG_PATH"
            rm -f "$claim"
            ;;
        failed)
            # Restore for the next sweep to retry. If restore itself
            # fails (e.g. someone deleted the claim out from under us),
            # rm -f the claim — we'd rather lose one notification than
            # leave a stray .lock blocking the slot forever.
            _warn "notification backend failed — preserving pending for retry: $pending"
            mv "$claim" "$pending" 2>/dev/null || rm -f "$claim"
            return 1
            ;;
    esac
}

# --- Stale pruning -----------------------------------------------------------
# Drop pending files older than STALE_HOURS so a long-past unclean shutdown
# doesn't fire toasts on every `boxa` invocation. Stderr-only warning.
# Applied to both pending dirs (allow-for + agent-browser, slice 08) so a
# crashed broker can't accumulate forever in either.
prune_stale() {
    local dir
    for dir in "$ALLOW_FOR_PENDING_DIR" "$AGENT_BROWSER_PENDING_DIR"; do
        [ -d "$dir" ] || continue
        local stale
        # `-mmin +N` is portable across coreutils-find and BSD-find. Convert
        # hours to minutes once.
        # Pattern intentionally matches both `.pending-*.json` (legit hand-off
        # files) and `.pending-*.json.lock` (claim leftovers from a crashed
        # delivery) — both should age out by the same clock. Anything else
        # under this dotfile prefix is unexpected and worth sweeping too.
        stale=$(find "$dir" -maxdepth 1 -name '.pending-*' \
            -mmin "+$((STALE_HOURS * 60))" 2>/dev/null) || continue
        [ -z "$stale" ] && continue
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            _warn "dropping stale pending (>${STALE_HOURS}h): $f"
            rm -f "$f"
        done <<< "$stale"
    done
}

# --- Sweep -------------------------------------------------------------------
# Iterate every .pending-*.json across both supported pending dirs. Each
# delivery is independent; one failure doesn't abort the rest.
sweep() {
    prune_stale
    local dir pending
    for dir in "$ALLOW_FOR_PENDING_DIR" "$AGENT_BROWSER_PENDING_DIR"; do
        [ -d "$dir" ] || continue
        for pending in "$dir"/.pending-*.json; do
            [ -e "$pending" ] || continue
            deliver_one "$pending" || true
        done
    done
    return 0
}

# --- Watch -------------------------------------------------------------------
# Spawned by `boxa allow-for` start branch. Wait for *this container's*
# pending file. Exit as soon as one arrives (and is delivered), or after
# expires_at + grace if the daemon never wrote one.
#
# Multiple watchers may coexist (reset-clock spawns a new one). Whichever
# wins delivers the pending and exits; the others reach grace and exit
# quietly. Safe because deliver_one's rm -f is atomic at the syscall level.
watch_window() {
    local container="$1" expires_iso="$2"
    [ -n "$container" ] || { _warn "watch: missing container"; return 2; }
    [ -n "$expires_iso" ] || { _warn "watch: missing expires_at"; return 2; }

    local expires_epoch deadline_epoch
    expires_epoch=$(iso_to_epoch "$expires_iso") || {
        _warn "watch: unparseable expires_at: $expires_iso"
        return 2
    }
    deadline_epoch=$((expires_epoch + WATCH_GRACE_SECONDS))

    local pending_glob="${ALLOW_FOR_PENDING_DIR}/.pending-${container}-*.json"
    local now pending
    while :; do
        # Match any pending file for this container. Reset-clock changes
        # the expires_at on the sentinel but the container name stays
        # constant, so the glob is stable across the window's lifetime.
        for pending in $pending_glob; do
            [ -e "$pending" ] || continue
            deliver_one "$pending" || true
            return 0
        done
        now=$(date +%s)
        [ "$now" -ge "$deadline_epoch" ] && return 0
        sleep "$WATCH_POLL_SECONDS"
    done
}

# --- Dispatch ----------------------------------------------------------------
case "${1:-}" in
    --sweep)
        sweep
        ;;
    --watch)
        shift
        watch_window "${1:-}" "${2:-}"
        ;;
    --help|-h|"")
        sed -n '4,32p' "$0"
        ;;
    -*)
        _warn "unknown flag: $1"
        exit 2
        ;;
    *)
        deliver_one "$1"
        ;;
esac
