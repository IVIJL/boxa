#!/bin/bash
# Boxa auto-connect wrapper for the upstream `agent-browser` CLI.
#
# `boxa agent-browser start` (on the host) sets up a socat bridge in
# the container that listens on 127.0.0.1:9222 and forwards CDP to the
# Host agent Chrome. The npm-installed `agent-browser` binary doesn't
# know about that bridge, so without intervention `agent-browser open
# <url>` falls back to auto-launching a local Chrome — which boxa
# containers don't ship — and fails with "Chrome not found".
#
# This wrapper sits in /usr/local/bin/agent-browser (ahead of
# /usr/local/share/npm-global/bin in PATH) and issues a one-shot
# `connect 9222` before delegating to the upstream binary so the next
# command lands on the bridge. The connect call is cached under /tmp
# for this container's lifetime (sentinel wiped on restart), so the WS
# handshake happens at most once per container boot.
#
# Scope: targeted at the common shape `agent-browser <verb> [args]`
# and `agent-browser --session NAME <verb> [args]`. Power-user
# invocations that put global flags AFTER the verb, use uncommon
# value-bearing options (`--state`, `--profile`, `--config`), or rely
# on boolean globals the upstream CLI doesn't document (`--debug`,
# `--ignore-https-errors`, etc.) may bypass auto-connect — in that
# case the user can manually run
#   `agent-browser <global-flags> connect 9222`
# once per session and the upstream CLI takes it from there.
set -euo pipefail

REAL="/usr/local/share/npm-global/bin/agent-browser"
BRIDGE_URL="http://127.0.0.1:9222/json/version"

# Resolve the upstream CLI's `--session NAME` (and AGENT_BROWSER_SESSION
# env equivalent) AND the actual subcommand in a single pass. The
# upstream CLI accepts many value-taking global options before the
# verb (`--session`, `--profile`, `--proxy`, `--config`, `--state`, ...
# — list keeps growing), so a fixed allowlist of value-takers is
# fragile. Invert it: ENUMERATE the booleans (`--auto-connect`,
# `--json`, `--allow-file-access`, ...) and treat every other `--flag`
# as value-taking. That way a future upstream value-flag still skips
# its operand safely; a new boolean would only over-consume one
# positional, which is recoverable.
session_name="${AGENT_BROWSER_SESSION:-default}"
op=""
expect_value=""
peek_bool=""
preargs=()
for arg in "$@"; do
    if [ -n "$peek_bool" ]; then
        peek_bool=""
        case "$arg" in
            true|false)
                preargs+=("$arg")
                continue
                ;;
        esac
        # Not an optional boolean value — fall through to normal
        # processing so this arg is classified on its own merits.
    fi
    if [ -n "$expect_value" ]; then
        if [ "$expect_value" = "--session" ]; then
            session_name="$arg"
        fi
        preargs+=("$arg")
        expect_value=""
        continue
    fi
    case "$arg" in
        --session=*)
            session_name="${arg#--session=}"
            preargs+=("$arg")
            ;;
        # Boolean globals — accept an OPTIONAL following `true`/`false`
        # value (upstream CLI documents this for every boolean flag).
        # Keep this list in sync with the boolean lists in
        # `_extract_open_url` and the argv-rebuild loop at the bottom
        # of this file.
        --auto-connect|--allow-file-access|--ignore-https-errors|--annotate|--content-boundaries|--confirm-interactive|--no-auto-dialog|--debug|--json|--verbose|-v|--quiet|-q|--help|-h|--version|-V|--headed)
            preargs+=("$arg")
            peek_bool=1
            ;;
        # --flag=value form: value already attached, nothing to skip.
        --*=*)
            preargs+=("$arg")
            ;;
        # Every other long or short option takes a value next.
        --*|-[!-]*)
            preargs+=("$arg")
            expect_value="$arg"
            ;;
        *)
            # The first non-flag positional IS the subcommand.
            # Capture it and stop scanning — anything after is an
            # operand (URL, selector, text), not another verb. Without
            # this break the loop would mis-classify operands like
            # `agent-browser click close` or `find text connect` as
            # pass-through subcommands and skip auto-connect.
            op="$arg"
            break
            ;;
    esac
done

# Sanitise session_name into a filesystem-safe sentinel suffix so an
# adversarially crafted name (`../foo`, spaces) cannot redirect rm.
# A safe sentinel charset mirrors the broker's container-name policy.
safe_session="${session_name//[^A-Za-z0-9._-]/_}"
SENTINEL="/tmp/.agent-browser-boxa-connected-${safe_session}"

# Help/version/empty-argv exit early — those upstream modes never
# touch Chrome, so an auto-connect probe is wasted I/O.
if [ "$#" -eq 0 ]; then
    exec "$REAL"
fi
case "${1:-}" in
    -h|--help|--version)
        exec "$REAL" "$@"
        ;;
esac

# Subcommands that don't drive Chrome: pass through untouched.
# `disconnect`, `close`, and the undocumented `quit`/`exit` aliases all
# tear down the upstream session, so they additionally invalidate the
# cache — the next Chrome-bound call must re-issue `connect 9222`
# instead of skipping the preflight and silently falling through to
# auto-launch. `close --all` closes every upstream session, so it
# wipes every per-session sentinel (not just this invocation's).
case "$op" in
    disconnect)
        rm -f "$SENTINEL"
        exec "$REAL" "$@"
        ;;
    close|quit|exit)
        case " $* " in
            *" --all "*) rm -f /tmp/.agent-browser-boxa-connected-* ;;
            *)           rm -f "$SENTINEL" ;;
        esac
        exec "$REAL" "$@"
        ;;
    connect|skills|install|help|version)
        exec "$REAL" "$@"
        ;;
esac

# Idempotent pre-flight with stale-state detection.
#
# Each Chrome process emits a unique `webSocketDebuggerUrl` of the form
# `ws://127.0.0.1:9222/devtools/browser/<uuid>`. The upstream CLI caches
# that exact URL in its own state on `connect`; if the user restarts
# the session (`boxa agent-browser stop` → `start`, or the watchdog
# tears down a closed window and a new session comes up), the cached
# URL targets a dead Chrome process and every subsequent command fails
# even though port 9222 is up again with a different UUID.
#
# The sentinel therefore stores the WS URL we connected to, not just a
# yes/no marker. Before skipping connect we re-probe the bridge and
# compare: matching UUID = same Chrome, skip cheaply; mismatch =
# Chrome restarted under us, drop the sentinel and reconnect.
#
# Pre-verb global flags (`--state`, `--profile`, etc.) are forwarded
# into the connect call so the bridge gets recorded under the SAME
# state the real command will read from.
current_ws=""
if curl_out="$(curl -sf --max-time 1 "$BRIDGE_URL" 2>/dev/null)"; then
    # Extract the `"webSocketDebuggerUrl": "<url>"` snippet without
    # adding a jq dependency to the boxa image. Chrome pretty-prints
    # `/json/version` with whitespace around the colon, so the pattern
    # has to tolerate `:`, `: `, `:\t`, etc. The `|| true` on the
    # pipeline keeps `set -euo pipefail` from killing the wrapper when
    # the field is absent (older Chrome builds, partial responses) —
    # we degrade to "no UUID known", which the caller handles by
    # falling through to the upstream binary unchanged.
    current_ws="$(printf '%s' "$curl_out" \
        | grep -oE '"webSocketDebuggerUrl"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 || true)"
fi

if [ -f "$SENTINEL" ] && [ -n "$current_ws" ]; then
    cached_ws="$(cat "$SENTINEL" 2>/dev/null || true)"
    if [ "$cached_ws" != "$current_ws" ]; then
        rm -f "$SENTINEL"
    fi
fi

if [ ! -f "$SENTINEL" ] && [ -n "$current_ws" ]; then
    # Ensure `--session` is present even when the user relied on
    # AGENT_BROWSER_SESSION or the upstream default — the sentinel
    # is keyed on that resolved name, so the connect must match.
    connect_args=("${preargs[@]+"${preargs[@]}"}")
    case " ${connect_args[*]} " in
        *" --session "*|*" --session="*) ;;
        *) connect_args+=(--session "$session_name") ;;
    esac
    if "$REAL" "${connect_args[@]}" connect 9222 >/dev/null 2>&1; then
        printf '%s\n' "$current_ws" > "$SENTINEL"
    fi
    # Best-effort: if connect failed, fall through to the real
    # binary so its own "Chrome not found" message reaches the
    # user with the canonical install hint — better than masking
    # the failure here.
fi

# -----------------------------------------------------------------------------
# Verb dispatcher — only the navigation verbs (`open`, `goto`, `navigate`)
# need spawn-and-wait so the wrapper can detect Agent-browser proxy CONNECT
# denials and re-invoke Chrome with an inline `data:` URL that renders a
# styled denial page. Every other verb keeps the original `exec` path, so
# the wrapper adds zero overhead on the happy path.
case "$op" in
    open|goto|navigate) ;;     # fall through to spawn-and-wait below
    *) exec "$REAL" "$@" ;;
esac

# Helper: HTML-escape a string for safe substitution into the denial heredoc.
# Order matters: `&` MUST be escaped first so the subsequent rules don't
# re-escape the ampersands they just introduced.
_html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' \
                           -e 's/</\&lt;/g' \
                           -e 's/>/\&gt;/g' \
                           -e 's/"/\&quot;/g'
}

# Helper: percent-encode a string for inclusion in a `data:` URL. jq is
# baked into the boxa image (Dockerfile keyword `jq`), so no runtime
# install is needed. `-R` reads raw input, `-s` slurps the whole stream
# into one string, `-r` emits raw output, `@uri` does the percent-encoding.
_urlencode() {
    printf '%s' "$1" | jq -Rsr @uri
}

# Helper: pull the host out of a URL with pure bash — no curl/python.
# Strip `scheme://`, then drop everything from the first `/`, `?`, or `#`.
_extract_host_from_url() {
    local u="${1#*://}"
    printf '%s' "${u%%[/?#]*}"
}

# Helper: scan an `agent-browser open ...` argv and return the first
# non-flag positional after the `open` verb — that's the URL the user
# tried to navigate to. Mirrors the pre-arg parser above: enumerate
# boolean flags explicitly, treat every other `--flag` / `-flag` as
# value-taking so an as-yet-unknown upstream option still skips its
# operand. The upstream CLI's `--help` documents that boolean flags
# accept an optional `true`/`false` value (e.g. `--headed false`),
# so after a known boolean we also consume the next arg if it's
# literally `true` or `false`. Both pre-verb global flags
# (`--session NAME`) and post-verb `open` options (`--headers JSON`,
# `--init-script PATH`) are handled uniformly. If no URL is found,
# return the empty string — the denial page renders with an empty
# host, which is still strictly better than showing nothing.
_extract_open_url() {
    local seen_verb="" expect="" peek_bool="" arg
    for arg in "$@"; do
        if [ -n "$peek_bool" ]; then
            peek_bool=""
            case "$arg" in
                true|false) continue ;;
            esac
            # Fall through and process `arg` normally — it wasn't the
            # optional boolean value.
        fi
        if [ -n "$expect" ]; then
            expect=""
            continue
        fi
        if [ -z "$seen_verb" ]; then
            case "$arg" in
                --auto-connect|--allow-file-access|--ignore-https-errors|--annotate|--content-boundaries|--confirm-interactive|--no-auto-dialog|--debug|--json|--verbose|-v|--quiet|-q|--help|-h|--version|-V|--headed)
                    peek_bool=1
                    continue
                    ;;
                --*=*)
                    continue
                    ;;
                --*|-[!-]*)
                    expect="$arg"
                    continue
                    ;;
            esac
            if [ "$arg" = "open" ] || [ "$arg" = "goto" ] || [ "$arg" = "navigate" ]; then
                seen_verb=1
            fi
            continue
        fi
        case "$arg" in
            # Boolean flags accepted by `open` and by the global flag set —
            # keep aligned with the pre-arg parser above so behaviour stays
            # symmetric.
            --auto-connect|--allow-file-access|--ignore-https-errors|--annotate|--content-boundaries|--confirm-interactive|--no-auto-dialog|--debug|--json|--verbose|-v|--quiet|-q|--help|-h|--version|-V|--headed)
                peek_bool=1
                ;;
            --*=*)
                ;;
            --*|-[!-]*)
                expect="$arg"
                ;;
            *)
                printf '%s' "$arg"
                return 0
                ;;
        esac
    done
    return 0
}

# Helper: render the denial HTML.
#
# IMPORTANT: keep the body text in lockstep with the proxy 403 plain-text
# response at `scripts/agent-browser-proxy.py:_send_403`. HTTP denials
# show that plain-text body directly in Chrome; HTTPS denials lose the
# body to Chromium's CONNECT-failure handling, so the wrapper synthesises
# a matching page here. Same recovery commands, same allowlist conf
# path, same opening line — divergence between the two would confuse
# anyone debugging deny reasons across HTTP and HTTPS.
_render_denial_html() {
    local host="$1" url="$2"
    cat <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Blocked by boxa agent-browser</title>
<style>
 body { font-family: -apple-system, system-ui, sans-serif; max-width: 640px;
        margin: 3em auto; padding: 1em; color: #222; }
 h1 { color: #b00020; font-size: 1.3em; margin: 0 0 0.5em; }
 code { background: #f4f4f4; padding: 0.15em 0.4em; border-radius: 3px;
        font-size: 0.95em; }
 pre { background: #f4f4f4; padding: 0.9em; border-radius: 4px;
       overflow-x: auto; }
 .url { word-break: break-all; }
</style>
</head>
<body>
<h1>boxa agent-browser blocked: ${host}</h1>
<p>Default mode only allows the configured agent-browser allowlist;
everything else is denied at the host proxy.</p>
<p>To temporarily allow ALL domains for this session, on the host run:</p>
<pre>boxa agent-browser allow-for &lt;minutes&gt; [project]</pre>
<p>Or add this host durably to the agent-browser allowlist:</p>
<pre>~/.config/boxa/agent-browser-allowed-domains.conf</pre>
<p>Original URL: <span class="url"><code>${url}</code></span></p>
</body>
</html>
HTML
}

# Spawn the upstream `open` and capture its stderr to a temp file for
# pattern matching. We redirect 2>"$err_file" instead of teeing via
# process substitution because process substitution runs in an
# asynchronous subshell that bash does not wait for — `grep` on
# `err_file` could fire before `tee` flushed the upstream error and
# the wrapper would intermittently miss `ERR_TUNNEL_CONNECTION_FAILED`
# and skip the denial page. With direct redirection the file is
# closed before we read it. The captured stderr is then echoed
# verbatim to the caller's stderr so existing failure-detection
# (agents grepping for `ERR_TUNNEL_CONNECTION_FAILED`) is unaffected;
# the only behavioural difference is that stderr arrives in one
# burst at the end rather than streaming live, which is fine for
# the short stderr `open` emits.
err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT INT TERM

# `set -e` would kill the wrapper here when the upstream CLI exits
# non-zero — but we explicitly want to inspect that exit code. Disable
# errexit just for this one call, capture the status, restore.
set +e
"$REAL" "$@" 2>"$err_file"
status=$?
set -e
cat "$err_file" >&2

if [ "$status" -eq 0 ]; then
    exit 0
fi

# Only the proxy CONNECT-deny path gets the inline denial page. Every
# other failure (DNS, peer TLS, page-level JS errors, upstream CLI
# crashes) flows through untouched so the agent sees the canonical
# error rather than a confusing "blocked" page.
if ! grep -qE 'ERR_TUNNEL_CONNECTION_FAILED' "$err_file"; then
    exit "$status"
fi

url="$(_extract_open_url "$@")"
host="$(_extract_host_from_url "$url")"
safe_host="$(_html_escape "$host")"
safe_url="$(_html_escape "$url")"

html="$(_render_denial_html "$safe_host" "$safe_url")"
data_url="data:text/html;charset=utf-8,$(_urlencode "$html")"

# Rebuild the argv with the original URL token swapped for the data:
# URL, preserving EVERY other token (pre-verb globals like
# `--session foo`, post-verb options like `--headed`, `--headers '{}'`,
# and the verb itself — open / goto / navigate). This guarantees the
# denial page lands in the same session/state the failing call
# targeted, including the non-default-session case where `--session`
# appears AFTER the verb.
#
# Swap strategy: if `_extract_open_url` returned a URL, replace the
# FIRST occurrence of that exact token in `$@` (it's the URL the user
# typed, so it must appear verbatim in the argv). This is robust even
# when an undocumented boolean upstream flag would have confused a
# strict re-parse — the swap targets the known URL string directly.
# If no URL was extracted (e.g. `agent-browser open` with no positional,
# which doesn't normally hit a tunnel failure), append the data: URL
# at the end so Chrome still gets navigated.
new_args=()
url_swapped=""
for arg in "$@"; do
    if [ -z "$url_swapped" ] && [ -n "$url" ] && [ "$arg" = "$url" ]; then
        new_args+=("$data_url")
        url_swapped=1
    else
        new_args+=("$arg")
    fi
done
if [ -z "$url_swapped" ]; then
    new_args+=("$data_url")
fi

# Re-enter the upstream CLI with the rebuilt argv. The verb stays the
# same (open/goto/navigate), the URL is now `data:`, which Chrome
# renders inline without ever going through the host proxy — so no
# second deny log entry, no second tunnel failure. Best-effort: if
# this secondary call fails we still want the caller to see the
# original error, hence `|| true`.
"$REAL" "${new_args[@]}" >/dev/null 2>&1 || true

# Preserve the original failure semantics so the caller's exit-code
# checks continue to fire on denial.
exit "$status"
