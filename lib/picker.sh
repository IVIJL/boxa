# shellcheck shell=bash
# =============================================================================
# Boxa interactive picker — single + multi select with consistent UX
# =============================================================================
# Sourced by docker-run.sh (host). Reads items from stdin (one per line),
# prints the selection on stdout. fzf is preferred when available; a numbered
# fallback handles the no-fzf case with `a` (first-option) and `q` (cancel)
# shortcuts and comma-separated multi-select (`1,3,5`).
#
# Public API:
#   picker::one  --prompt "<p>" [--header "<h>"] [--first-option "<s>"]...
#   picker::many --prompt "<p>" [--header "<h>"] [--first-option "<s>"]...
#
# --first-option may be passed multiple times. Each option string is prepended
# to the list in order; the fallback assigns letter shortcuts `a)`, `b)`, ...
# Caller string-compares each returned line against its known sentinels to
# detect "expand all"-style routing.
#
# When --header is set, the text is shown above the choices: fzf renders it
# via its --header option; the numbered fallback prints it to stderr just above
# the option list. Use it for context the user needs to see while picking.
#
# --accept-query makes a free-text entry that matches no item a valid answer:
# the picker prints the raw text on stdout and returns 0 instead of failing.
# Use it only for prompts where a user may paste a value into the picker (a
# token menu, for example) so the paste is not lost; the caller decides what
# the text means. Esc/q/empty input still cancel with return 1. The picker
# never echoes the accepted text to stderr because it may be a secret.
#
# Override fzf detection (for tests): export BOXA_PICKER_FZF=0
# See docs/adr/0006-interactive-picker-conventions.md.
# =============================================================================

# --- Public API --------------------------------------------------------------

# Pick a single item. See header comment for arguments.
picker::one() {
    _picker::run one "$@"
}

# Pick one or more items. See header comment for arguments.
picker::many() {
    _picker::run many "$@"
}

# --- Private -----------------------------------------------------------------

_picker::run() {
    local mode="$1"; shift
    local prompt="" header="" accept_query=0
    local -a first_options=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --prompt)       prompt="$2"; shift 2 ;;
            --header)       header="$2"; shift 2 ;;
            --first-option) first_options+=("$2"); shift 2 ;;
            --accept-query) accept_query=1; shift ;;
            *) echo "picker: unknown arg: $1" >&2; return 1 ;;
        esac
    done

    local raw_items
    raw_items=$(cat)
    [ -z "$raw_items" ] && [ "${#first_options[@]}" -eq 0 ] && return 1

    local -a items=()
    local opt
    # ${arr[@]+...} guards: macOS ships bash 3.2, where expanding an empty
    # array under `set -u` is an unbound-variable error (fixed in bash 4.4).
    for opt in ${first_options[@]+"${first_options[@]}"}; do
        items+=("$opt")
    done
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        items+=("$line")
    done <<< "$raw_items"

    if _picker::fzf_available; then
        _picker::fzf "$mode" "$prompt" "$header" "$accept_query" ${items[@]+"${items[@]}"}
    else
        _picker::fallback "$mode" "$prompt" "$header" "${#first_options[@]}" "$accept_query" ${items[@]+"${items[@]}"}
    fi
}

_picker::fzf_available() {
    [ "${BOXA_PICKER_FZF:-1}" != "0" ] && command -v fzf &>/dev/null
}

_picker::fzf() {
    local mode="$1" prompt="$2" header="$3" accept_query="$4"; shift 4
    local height='40%'
    if fzf --height='~40%' --version >/dev/null 2>&1; then
        height='~40%'
    fi
    local args=(--prompt="$prompt" --height="$height" --min-height=10 --layout=reverse)
    if [ "$mode" = many ]; then
        [ -n "$header" ] && header+=$'\n'
        header+="Tab selects multiple"
    fi
    [ -n "$header" ] && args+=(--header="$header")
    [ "$mode" = many ] && args+=(--multi)
    # --print-query puts the typed filter on the first output line so a
    # no-match Enter (exit 1) can still hand the text back under
    # --accept-query. Esc/Ctrl-C exit 130 and always cancel.
    local output status=0 query selection
    output="$(printf '%s\n' "$@" | fzf "${args[@]}" --print-query)" || status=$?
    query="${output%%$'\n'*}"
    if [ "$status" -ne 0 ]; then
        if [ "$status" -eq 1 ] && [ "$accept_query" = 1 ] && [ -n "$query" ]; then
            _picker::echo_selection "$prompt" '(typed value accepted)'
            printf '%s\n' "$query"
            return 0
        fi
        return 1
    fi
    case "$output" in
        *$'\n'*) selection="${output#*$'\n'}" ;;
        *) return 1 ;;
    esac
    _picker::echo_selection "$prompt" "$selection"
    printf '%s\n' "$selection"
}

_picker::fallback() {
    local mode="$1" prompt="$2" header="$3" first_count="$4" accept_query="$5"; shift 5
    [ -n "$header" ] && printf '%s\n' "$header" >&2
    local -a items=("$@")

    echo "" >&2
    local i
    # Letter shortcuts (a, b, c, ...) cover each first-option in order;
    # real items are 1-based numerals starting after the sentinels.
    local letters="abcdefghijklmnopqrstuvwxyz"
    local letter_hint=""
    for ((i = 0; i < first_count; i++)); do
        printf "  %s) %s\n" "${letters:$i:1}" "${items[$i]}" >&2
        letter_hint+="${letters:$i:1}"
    done
    for ((i = first_count; i < ${#items[@]}; i++)); do
        printf "  %d) %s\n" "$((i - first_count + 1))" "${items[$i]}" >&2
    done
    echo "  q) Cancel" >&2
    echo "" >&2

    local hint letter_part=""
    if [ "$first_count" -gt 0 ]; then
        local j sep=""
        for ((j = 0; j < first_count; j++)); do
            letter_part+="${sep}${letter_hint:$j:1}"
            sep=","
        done
    fi
    if [ "$mode" = many ]; then
        hint="(comma-separated: numbers$([ -n "$letter_part" ] && echo " and $letter_part")/q)"
    else
        hint="(number$([ -n "$letter_part" ] && echo "/$letter_part")/q)"
    fi
    printf "%s %s: " "$prompt" "$hint" >&2

    local choice
    choice=$(_picker::read_choice) || return 1
    if [ "$accept_query" = 1 ] && _picker::is_free_text "$mode" "$choice"; then
        _picker::echo_selection "$prompt" '(typed value accepted)'
        printf '%s\n' "$choice"
        return 0
    fi
    local selection
    selection="$(_picker::select "$mode" "$first_count" "$choice" "${items[@]}")" \
        || return 1
    _picker::echo_selection "$prompt" "$selection"
    printf '%s\n' "$selection"
}

# True when the fallback input cannot be a menu answer (letter, number, q,
# or a comma list in many-mode). Checked before _picker::select so the raw
# text never reaches its "Invalid choice" message on stderr.
_picker::is_free_text() {
    local mode="$1" choice="$2"
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"
    [ -n "$choice" ] || return 1
    if [ "$mode" = many ]; then
        ! [[ "$choice" =~ ^[a-z0-9,[:space:]]+$ ]]
    else
        ! [[ "$choice" =~ ^([a-z]|[0-9]+)$ ]]
    fi
}

_picker::echo_selection() {
    local prompt="$1" selection="$2"
    prompt="${prompt%"${prompt##*[![:space:]]}"}"
    selection="${selection//$'\n'/, }"
    printf '%s %s\n' "$prompt" "$selection" >&2
}

# Read a single line from the controlling terminal.
#
# The caller pipes items into picker via stdin, so by the time the fallback
# prompt runs, the function's stdin is at EOF. We redirect `read` from
# /dev/tty to break that coupling. Tests stub this by exporting
# BOXA_PICKER_TEST_CHOICE (set-but-empty = simulated Enter = cancel).
_picker::read_choice() {
    if [ -n "${BOXA_PICKER_TEST_CHOICE+x}" ]; then
        printf '%s' "$BOXA_PICKER_TEST_CHOICE"
        return 0
    fi
    local choice
    IFS= read -r choice </dev/tty || return 1
    printf '%s' "$choice"
}

# Pure selection logic. Inputs: mode (one|many), first_count (number of
# leading first-option sentinels in `items`), choice string, items (with
# any first-option sentinels at positions [0..first_count-1]). Item indices
# in $choice are 1-based over the **non-sentinel** items (i.e. the user
# types `1` for the first real item). Letter shortcuts `a`, `b`, ... map
# to sentinels 0, 1, ...
#
# Stdout: selected item(s), newline-separated. Returns 1 on cancel/invalid.
_picker::select() {
    local mode="$1" first_count="$2" choice="$3"; shift 3
    local -a items=("$@")

    # Trim whitespace
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"

    case "$choice" in
        q|"") return 1 ;;
    esac

    local letters="abcdefghijklmnopqrstuvwxyz"
    local max=$((${#items[@]} - first_count))

    # Letter shortcuts map to sentinels in declaration order. Many-mode parses
    # letters together with numbered choices below so inputs such as a,2 work.
    if [ "$mode" != many ] && [[ "$choice" =~ ^[a-z]$ ]]; then
        local prefix="${letters%%"$choice"*}"
        local idx=${#prefix}
        if [ "$idx" -lt "$first_count" ]; then
            printf '%s\n' "${items[$idx]}"
            return 0
        fi
        echo "Invalid choice: $choice" >&2
        return 1
    fi

    if [ "$mode" = many ]; then
        local -a raw=()
        IFS=',' read -ra raw <<< "$choice"
        local idx resolved prefix seen_index
        local -a picked=() selected_indices=()
        for idx in ${raw[@]+"${raw[@]}"}; do
            idx="${idx// /}"
            if [[ "$idx" =~ ^[a-z]$ ]]; then
                prefix="${letters%%"$idx"*}"
                resolved=${#prefix}
                if [ "$resolved" -ge "$first_count" ]; then
                    echo "Invalid choice: $idx" >&2
                    return 1
                fi
            elif [[ "$idx" =~ ^[0-9]+$ ]] \
                && [ "$idx" -ge 1 ] && [ "$idx" -le "$max" ]; then
                resolved=$((first_count + idx - 1))
            else
                echo "Invalid choice: $idx" >&2
                return 1
            fi
            for seen_index in ${selected_indices[@]+"${selected_indices[@]}"}; do
                if [ "$seen_index" -eq "$resolved" ]; then
                    echo "Duplicate choice: $idx" >&2
                    return 1
                fi
            done
            selected_indices+=("$resolved")
            picked+=("${items[$resolved]}")
        done
        printf '%s\n' "${picked[@]}"
    else
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$max" ]; then
            echo "Invalid choice." >&2
            return 1
        fi
        printf '%s\n' "${items[$((first_count + choice - 1))]}"
    fi
}
