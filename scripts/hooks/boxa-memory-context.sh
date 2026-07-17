#!/bin/sh
# Boxa in-container Memory warning + OOM detection hook (ADR 0020).
#
# Fires as a SessionStart baseline hook and a PostToolUse observation hook
# (any tool) from BOTH Claude Code and Codex, so the agent learns *at the
# moment it matters* that a process in this project was OOM-killed or that
# memory is running out — before it retries the thing that just got killed.
#
# Registration (delivery per ADR 0011, baked into the image):
#   - Claude Code: /etc/claude-code/managed-settings.d/51-boxa-memory.json
#     (SessionStart plus PostToolUse, matcher "*").
#   - Codex CLI: /etc/codex/managed_config.toml [hooks] SessionStart and
#     PostToolUse.
#     VERIFIED on codex-cli 0.144.5: the managed-config hook schema accepts
#     PostToolUse entries (same HookHandlerConfig shape as the SessionStart
#     identity hook), so the SessionStart "N processes were OOM-killed since
#     your last session" fallback contemplated in the design was NOT needed;
#     both agents receive the same per-tool-call signal. If a future Codex
#     version drops PostToolUse, reintroduce that fallback here and document
#     the asymmetry in this header.
#
# At SessionStart, the hook only snapshots the current counter and usage band
# into state, silently. This establishes the baseline before the first tool
# call without adding any external process to the silent path.
#
# Per tool call:
#   Silent path (budget ~1.4 ms): read this Container's cgroup
#   memory.events / memory.current / memory.max (readable despite the ro
#   cgroupfs mount; verified), compare the oom_kill counter and the usage
#   band against a state file, and exit 0 with empty stdout when nothing
#   changed. Empty stdout means "no additional context" to both agents.
#   This path spawns no external process (no command substitution either —
#   helper functions return via MEMHOOK_* globals to avoid subshell forks).
#
#   Speak-up paths (JSON additionalContext, same schema as the ADR 0011
#   identity hook):
#     1. oom_kill counter delta -> one message per kill batch with the
#        victim's name/RSS pulled from the kernel log. The counter delta is
#        the dedup key: each kill is reported exactly once. dmesg is the
#        WSL-VM-shared ring buffer, so the newest matching record is a
#        best-effort attribution and the wording hedges accordingly; the
#        kernel picks the victim by its oom_score heuristic (observed:
#        largest process), never guaranteed — wording per ADR 0020.
#     2. Memory warning bands (CONTEXT.md `### Memory`): warn once on
#        entering the 80 % band and once on entering the 90 % band; re-arm
#        only after usage falls back below 75 %, so hovering at a threshold
#        does not warn continuously.
#
# State: /tmp/boxa-memory-hook.<user>.state on the container-private rootfs
# (NOT a bind mount), so it survives across tool calls and sessions within
# this Container but cannot leak into another Container. A counter
# regression (cgroup recreated, stale /tmp) reseeds silently. If PostToolUse
# finds no valid state and oom_kill is already positive, it reports that
# count once: the first tool call may itself have been killed. This whole
# layer is best-effort observability; only the cgroup enforces (ADR 0020).
#
# Host no-op: guards on /etc/boxa/identity.json like the identity hook —
# empty stdout + exit 0 on host is the intended branch, not an error.
#
# Test seams (tests/memory-context.sh sources with BOXA_MEMHOOK_NO_MAIN=1):
#   BOXA_MEMHOOK_IDENTITY_FILE  identity guard file (default /etc/boxa/...)
#   BOXA_MEMHOOK_CGROUP_DIR     dir with memory.events/current/max
#   BOXA_MEMHOOK_STATE          state file path
#   BOXA_MEMHOOK_DMESG_FILE     read kernel log from file instead of dmesg
#   BOXA_MEMHOOK_UPTIME_FILE    /proc/uptime override for the "when" field

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested; return via MEMHOOK_* globals — no subshells)
# ---------------------------------------------------------------------------

# memhook_read_oom_kill <memory.events path>
# Sets MEMHOOK_OOM_KILL to the oom_kill counter (0 if unreadable/absent).
memhook_read_oom_kill() {
    MEMHOOK_OOM_KILL=0
    [ -r "$1" ] || return 0
    while IFS=' ' read -r rok_key rok_val; do
        if [ "$rok_key" = "oom_kill" ]; then
            case $rok_val in
                *[!0-9]* | '') ;;
                *) MEMHOOK_OOM_KILL=$rok_val ;;
            esac
        fi
    done < "$1"
}

# memhook_pct <usage_bytes> <limit_bytes>
# Sets MEMHOOK_PCT to the integer usage percentage; empty when the limit is
# unset ("max"), zero, or either value is non-numeric (no band logic then).
memhook_pct() {
    MEMHOOK_PCT=
    case $1 in *[!0-9]* | '') return 0 ;; esac
    case $2 in *[!0-9]* | '' | 0) return 0 ;; esac
    MEMHOOK_PCT=$(( $1 * 100 / $2 ))
}

# memhook_band_transition <old_band> <pct>
# Bands: 0 (disarmed), 80, 90. Sets MEMHOOK_NEW_BAND and MEMHOOK_WARN_BAND
# (0 = stay silent). Entering a higher band warns once; hovering inside or
# just below a band keeps the current band; re-arm only below 75 %.
memhook_band_transition() {
    MEMHOOK_NEW_BAND=$1
    MEMHOOK_WARN_BAND=0
    if [ "$2" -ge 90 ]; then
        if [ "$1" -lt 90 ]; then MEMHOOK_WARN_BAND=90; fi
        MEMHOOK_NEW_BAND=90
    elif [ "$2" -ge 80 ]; then
        if [ "$1" -lt 80 ]; then
            MEMHOOK_WARN_BAND=80
            MEMHOOK_NEW_BAND=80
        fi
    elif [ "$2" -lt 75 ]; then
        MEMHOOK_NEW_BAND=0
    fi
}

# memhook_oom_action <stored_counter> <current_counter>
# Sets MEMHOOK_OOM_ACTION to "report" (MEMHOOK_OOM_DELTA = new kills),
# "seed" (counter regressed — cgroup recreated, reseed silently), or "none".
memhook_oom_action() {
    MEMHOOK_OOM_DELTA=0
    if [ "$2" -gt "$1" ]; then
        MEMHOOK_OOM_ACTION=report
        MEMHOOK_OOM_DELTA=$(( $2 - $1 ))
    elif [ "$2" -lt "$1" ]; then
        MEMHOOK_OOM_ACTION=seed
    else
        MEMHOOK_OOM_ACTION=none
    fi
}

# memhook_parse_kill_line <kernel log line>
# Parses "... Killed process <pid> (<name>) ... anon-rss:<n>kB ..." into
# MEMHOOK_VICTIM_PID / MEMHOOK_VICTIM_NAME / MEMHOOK_VICTIM_RSS_KB and the
# leading "[ 123.456]" timestamp into MEMHOOK_VICTIM_TS (whole seconds,
# empty if absent). Returns 1 when the line is not a kill record.
memhook_parse_kill_line() {
    MEMHOOK_VICTIM_PID=
    MEMHOOK_VICTIM_NAME=
    MEMHOOK_VICTIM_RSS_KB=
    MEMHOOK_VICTIM_TS=
    case $1 in
        *"Killed process "*) ;;
        *) return 1 ;;
    esac
    pkl_rest=${1#*"Killed process "}
    MEMHOOK_VICTIM_PID=${pkl_rest%% *}
    case $pkl_rest in
        *"("*")"*)
            MEMHOOK_VICTIM_NAME=${pkl_rest#*\(}
            MEMHOOK_VICTIM_NAME=${MEMHOOK_VICTIM_NAME%%\)*}
            ;;
    esac
    case $pkl_rest in
        *anon-rss:*kB*)
            MEMHOOK_VICTIM_RSS_KB=${pkl_rest#*anon-rss:}
            MEMHOOK_VICTIM_RSS_KB=${MEMHOOK_VICTIM_RSS_KB%%kB*}
            ;;
    esac
    case $1 in
        \[*.*\]*)
            MEMHOOK_VICTIM_TS=${1#\[}
            MEMHOOK_VICTIM_TS=${MEMHOOK_VICTIM_TS%%.*}
            MEMHOOK_VICTIM_TS=${MEMHOOK_VICTIM_TS# }
            MEMHOOK_VICTIM_TS=${MEMHOOK_VICTIM_TS##* }
            case $MEMHOOK_VICTIM_TS in
                *[!0-9]* | '') MEMHOOK_VICTIM_TS= ;;
            esac
            ;;
    esac
    return 0
}

# memhook_human_bytes <bytes>
# Sets MEMHOOK_HUMAN ("512 MiB" / "7.6 GiB"); echoes the input verbatim into
# MEMHOOK_HUMAN when non-numeric (e.g. the literal "max").
memhook_human_bytes() {
    case $1 in
        *[!0-9]* | '') MEMHOOK_HUMAN=$1; return 0 ;;
    esac
    if [ "$1" -ge 1073741824 ]; then
        MEMHOOK_HUMAN="$(( $1 / 1073741824 )).$(( $1 % 1073741824 * 10 / 1073741824 )) GiB"
    else
        MEMHOOK_HUMAN="$(( $1 / 1048576 )) MiB"
    fi
}

# memhook_format_ago <seconds>
# Sets MEMHOOK_AGO to "~42 s ago" / "~7 min ago" / "~3 h ago".
memhook_format_ago() {
    case $1 in *[!0-9]* | '') MEMHOOK_AGO=; return 0 ;; esac
    if [ "$1" -lt 120 ]; then
        MEMHOOK_AGO="~$1 s ago"
    elif [ "$1" -lt 7200 ]; then
        MEMHOOK_AGO="~$(( $1 / 60 )) min ago"
    else
        MEMHOOK_AGO="~$(( $1 / 3600 )) h ago"
    fi
}

# memhook_load_state <state file>
# Sets MEMHOOK_STATE_OOM / MEMHOOK_STATE_BAND. Returns 1 when the file is
# missing or malformed (caller reseeds). Strict key=value, never sourced.
memhook_load_state() {
    MEMHOOK_STATE_OOM=
    MEMHOOK_STATE_BAND=
    [ -r "$1" ] || return 1
    while IFS='=' read -r ls_key ls_val; do
        case $ls_key in
            oom_kill) MEMHOOK_STATE_OOM=$ls_val ;;
            band) MEMHOOK_STATE_BAND=$ls_val ;;
        esac
    done < "$1"
    case $MEMHOOK_STATE_OOM in *[!0-9]* | '') return 1 ;; esac
    case $MEMHOOK_STATE_BAND in 0 | 80 | 90) ;; *) return 1 ;; esac
    return 0
}

# memhook_save_state <state file> <oom_kill> <band>
# Best-effort atomic write; a failure (perms, full /tmp) must never break
# the tool call — the hook observes, it does not enforce.
memhook_save_state() {
    if printf 'oom_kill=%s\nband=%s\n' "$2" "$3" > "$1.tmp.$$" 2>/dev/null; then
        mv -f "$1.tmp.$$" "$1" 2>/dev/null || rm -f "$1.tmp.$$" 2>/dev/null || :
    fi
}

# ---------------------------------------------------------------------------
# Speak-up message assembly (forks allowed here — rare path)
# ---------------------------------------------------------------------------

# memhook_raise_guidance <identity file>
# Sets MEMHOOK_RAISE — how to raise the Memory limit, keyed to this project.
memhook_raise_guidance() {
    rg_key=$(jq -r '.projectKey // empty' "$1" 2>/dev/null) || rg_key=
    [ -n "$rg_key" ] || rg_key="<absolute host project path>"
    MEMHOOK_RAISE="To raise it, ask the user to edit ~/.config/boxa/resources.conf ON THE HOST — section [${rg_key}], key 'memory = <size>' (e.g. memory = 12g) — any following 'boxa' invocation converges the running Container live (no restart)."
}

# memhook_oom_message <delta> <limit_h> <usage_h>
# Sets MEMHOOK_MSG_OOM. Victim details come from the newest matching kernel
# log record (VM-shared ring buffer — attribution hedged, per header).
memhook_oom_message() {
    om_line=
    if [ -n "${BOXA_MEMHOOK_DMESG_FILE:-}" ]; then
        om_line=$(grep -iE 'out of memory: Killed process' \
            "$BOXA_MEMHOOK_DMESG_FILE" 2>/dev/null | tail -n 1)
    else
        om_line=$(dmesg 2>/dev/null \
            | grep -iE 'out of memory: Killed process' | tail -n 1)
    fi

    om_victim="victim details unavailable (kernel log unreadable or already rotated)"
    if [ -n "$om_line" ] && memhook_parse_kill_line "$om_line"; then
        if [ -n "$MEMHOOK_VICTIM_RSS_KB" ]; then
            memhook_human_bytes "$(( MEMHOOK_VICTIM_RSS_KB * 1024 ))"
        else
            MEMHOOK_HUMAN="unknown"
        fi
        om_when=
        om_now=
        if IFS=' .' read -r om_now _ 2>/dev/null \
            < "${BOXA_MEMHOOK_UPTIME_FILE:-/proc/uptime}" \
            && [ -n "$MEMHOOK_VICTIM_TS" ]; then
            case $om_now in
                *[!0-9]*) ;;
                *)
                    if [ "$om_now" -ge "$MEMHOOK_VICTIM_TS" ]; then
                        memhook_format_ago "$(( om_now - MEMHOOK_VICTIM_TS ))"
                        om_when=", $MEMHOOK_AGO"
                    fi
                    ;;
            esac
        fi
        om_victim="most recent kernel record: process '$MEMHOOK_VICTIM_NAME' (PID $MEMHOOK_VICTIM_PID), anon RSS $MEMHOOK_HUMAN$om_when. The WSL VM shares one kernel log, so if another project OOM-killed at the same moment this record could be its; the counter above is authoritative for THIS project."
    fi

    om_count="A process in this project was OOM-killed"
    if [ "$1" -gt 1 ]; then
        om_count="$1 processes in this project were OOM-killed"
    fi

    MEMHOOK_MSG_OOM="[boxa memory] $om_count by the kernel since the last tool call (Memory limit: $2, usage now: $3); $om_victim
- The kernel selected the victim by its oom_score heuristic (observed to favor the largest process) — it is NOT necessarily the command you just ran; the victim may be a background process or a nested Docker workload.
- The Container keeps running; only the victim died. Do not retry the killed work as-is — at the same Memory limit it will likely be killed again. $MEMHOOK_RAISE"
}

# memhook_band_message <band> <pct> <usage_h> <limit_h>
# Sets MEMHOOK_MSG_BAND.
memhook_band_message() {
    if [ "$1" -eq 90 ]; then
        MEMHOOK_MSG_BAND="[boxa memory] Memory warning: this project is at ${2}% of its Memory limit ($3 of $4). An OOM kill is imminent if usage keeps growing — the kernel will pick a victim by heuristic. Avoid starting new memory-heavy processes and free memory now (the limit covers everything in the Container, nested Docker workloads included). $MEMHOOK_RAISE"
    else
        MEMHOOK_MSG_BAND="[boxa memory] Memory warning: this project is at ${2}% of its Memory limit ($3 of $4). The limit counts everything in the Container — your processes plus nested Docker workloads. Past 90% an OOM kill becomes likely; consider bounding memory-heavy work. $MEMHOOK_RAISE"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

memhook_main() {
    # Host no-op branch (same managed settings are inert without identity).
    mh_identity=${BOXA_MEMHOOK_IDENTITY_FILE:-/etc/boxa/identity.json}
    [ -f "$mh_identity" ] || exit 0

    mh_cgdir=${BOXA_MEMHOOK_CGROUP_DIR:-/sys/fs/cgroup}
    mh_state=${BOXA_MEMHOOK_STATE:-/tmp/boxa-memory-hook.${USER:-agent}.state}

    memhook_read_oom_kill "$mh_cgdir/memory.events"

    mh_usage=
    mh_limit=
    read -r mh_usage 2>/dev/null < "$mh_cgdir/memory.current" || mh_usage=
    read -r mh_limit 2>/dev/null < "$mh_cgdir/memory.max" || mh_limit=
    memhook_pct "$mh_usage" "$mh_limit"

    if [ "${1:-}" = "session-start" ]; then
        # Establish the baseline before the first tool call. SessionStart is
        # deliberately seed-only and silent, even with a positive counter.
        mh_band=0
        if [ -n "$MEMHOOK_PCT" ]; then
            memhook_band_transition 0 "$MEMHOOK_PCT"
            mh_band=$MEMHOOK_NEW_BAND
        fi
        memhook_save_state "$mh_state" "$MEMHOOK_OOM_KILL" "$mh_band"
        exit 0
    fi

    if ! memhook_load_state "$mh_state"; then
        if [ "$MEMHOOK_OOM_KILL" -eq 0 ]; then
            # No baseline and no kills: initialize silently. A positive
            # counter instead remains reportable because the first tool call
            # may have incremented it before this PostToolUse hook ran.
            mh_band=0
            if [ -n "$MEMHOOK_PCT" ]; then
                memhook_band_transition 0 "$MEMHOOK_PCT"
                mh_band=$MEMHOOK_NEW_BAND
            fi
            memhook_save_state "$mh_state" "$MEMHOOK_OOM_KILL" "$mh_band"
            exit 0
        fi
        MEMHOOK_STATE_OOM=0
        MEMHOOK_STATE_BAND=0
    fi

    memhook_oom_action "$MEMHOOK_STATE_OOM" "$MEMHOOK_OOM_KILL"

    MEMHOOK_WARN_BAND=0
    MEMHOOK_NEW_BAND=$MEMHOOK_STATE_BAND
    if [ -n "$MEMHOOK_PCT" ]; then
        memhook_band_transition "$MEMHOOK_STATE_BAND" "$MEMHOOK_PCT"
    else
        # No limit set ("max") — bands are meaningless; disarm.
        MEMHOOK_NEW_BAND=0
    fi

    # Silent path: nothing to say, persist state only if it drifted.
    if [ "$MEMHOOK_OOM_ACTION" = none ] && [ "$MEMHOOK_WARN_BAND" -eq 0 ]; then
        if [ "$MEMHOOK_NEW_BAND" -ne "$MEMHOOK_STATE_BAND" ]; then
            memhook_save_state "$mh_state" "$MEMHOOK_OOM_KILL" "$MEMHOOK_NEW_BAND"
        fi
        exit 0
    fi

    if [ "$MEMHOOK_OOM_ACTION" = seed ] && [ "$MEMHOOK_WARN_BAND" -eq 0 ]; then
        # Counter regressed (cgroup recreated): reseed silently.
        memhook_save_state "$mh_state" "$MEMHOOK_OOM_KILL" "$MEMHOOK_NEW_BAND"
        exit 0
    fi

    # --- speak-up path (forks are fine from here) ---
    memhook_human_bytes "${mh_usage:-?}"
    mh_usage_h=$MEMHOOK_HUMAN
    memhook_human_bytes "${mh_limit:-?}"
    mh_limit_h=$MEMHOOK_HUMAN
    memhook_raise_guidance "$mh_identity"

    mh_context=
    if [ "$MEMHOOK_OOM_ACTION" = report ]; then
        memhook_oom_message "$MEMHOOK_OOM_DELTA" "$mh_limit_h" "$mh_usage_h"
        mh_context=$MEMHOOK_MSG_OOM
    fi
    if [ "$MEMHOOK_WARN_BAND" -ne 0 ]; then
        memhook_band_message "$MEMHOOK_WARN_BAND" "$MEMHOOK_PCT" "$mh_usage_h" "$mh_limit_h"
        if [ -n "$mh_context" ]; then
            mh_context="$mh_context

$MEMHOOK_MSG_BAND"
        else
            mh_context=$MEMHOOK_MSG_BAND
        fi
    fi

    memhook_save_state "$mh_state" "$MEMHOOK_OOM_KILL" "$MEMHOOK_NEW_BAND"

    jq -n \
        --arg context "$mh_context" \
        '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $context}}'
}

if [ -z "${BOXA_MEMHOOK_NO_MAIN:-}" ]; then
    memhook_main "$@"
fi
