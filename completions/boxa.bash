# Bash completion for boxa
#
# Install: source this file from ~/.bashrc, or copy to a system completion
# directory such as /usr/local/etc/bash_completion.d/ or
# /etc/bash_completion.d/. install.sh wires this up automatically when the
# user's shell is bash.
#
# Scope: completes top-level subcommands plus the `agent-browser` sub-tree
# in enough depth to satisfy the spec from ADR 0012 (Slice C). Mirrors the
# zsh completion in completions/_boxa.

_boxa_containers_bash() {
    docker ps --filter 'name=^boxa-' \
        --format '{{.Names}}' 2>/dev/null \
        | grep -vE '^boxa-(traefik|dns)$' \
        | sed 's/^boxa-//'
}

# Strip comments + blank lines from the agent-browser allowlist file.
# Output: one bare domain per line.
_boxa_agent_allowed_bash() {
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/boxa/agent-browser-allowed-domains.conf"
    [ -f "$cfg" ] || return 0
    sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$cfg" 2>/dev/null \
        | grep -v '^$' || true
}

_boxa() {
    # `prev` is read+written by `_init_completion` from the bash-completion
    # package; localised here so it doesn't leak to the global env even
    # though our routing logic only consults `cword` and `words`.
    local cur prev words cword
    if declare -F _init_completion >/dev/null 2>&1; then
        _init_completion || return
    else
        # Minimal fallback when bash-completion's helper isn't sourced.
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]:-}"
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    fi
    # `prev` reserved for future use; reference it once to satisfy shellcheck.
    : "${prev:-}"

    local top_commands="help ls mem stop remove port ports connect connections build update uninstall prune claude-token allow deny blocked allow-for agent-browser cursor code clip ssh-config sync-skills dns-install dns-status dns-uninstall"

    # Top-level subcommand
    if [ "$cword" -eq 1 ]; then
        # shellcheck disable=SC2207  # mapfile not always available in older bash
        COMPREPLY=( $(compgen -W "$top_commands" -- "$cur") )
        return 0
    fi

    local sub="${words[1]}"
    case "$sub" in
        mem)
            if [ "$cword" -eq 2 ]; then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "set $(_boxa_containers_bash)" -- "$cur") )
            elif [ "${words[2]:-}" = set ]; then
                if [ "${words[cword-1]:-}" = --swap ]; then
                    return 0
                fi
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "--global --swap $(_boxa_containers_bash)" -- "$cur") )
            fi
            ;;
        stop|remove|cursor|code)
            # These offer a project name as their positional completion. No
            # top-level `status` exists — that lives under `agent-browser`
            # and is handled by the agent-browser branch below.
            if [ "$cword" -eq 2 ]; then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "$(_boxa_containers_bash)" -- "$cur") )
            fi
            ;;
        agent-browser)
            local ab_subs="start stop status open allow-for allow deny blocked help"
            if [ "$cword" -eq 2 ]; then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "$ab_subs" -- "$cur") )
                return 0
            fi
            local ab_sub="${words[2]}"
            case "$ab_sub" in
                start)
                    if [ "$cword" -eq 3 ]; then
                        # shellcheck disable=SC2207
                        COMPREPLY=( $(compgen -W "--no-open $(_boxa_containers_bash)" -- "$cur") )
                    elif [ "$cword" -eq 4 ] && [ "${words[3]}" = "--no-open" ]; then
                        # shellcheck disable=SC2207
                        COMPREPLY=( $(compgen -W "$(_boxa_containers_bash)" -- "$cur") )
                    fi
                    ;;
                stop|status)
                    if [ "$cword" -eq 3 ]; then
                        # shellcheck disable=SC2207
                        COMPREPLY=( $(compgen -W "$(_boxa_containers_bash)" -- "$cur") )
                    fi
                    ;;
                open|blocked)
                    if [ "$cword" -eq 3 ]; then
                        # shellcheck disable=SC2207
                        COMPREPLY=( $(compgen -W "--project -p" -- "$cur") )
                    elif [ "$cword" -eq 4 ] \
                        && { [ "${words[3]}" = "--project" ] || [ "${words[3]}" = "-p" ]; }; then
                        # shellcheck disable=SC2207
                        COMPREPLY=( $(compgen -W "$(_boxa_containers_bash)" -- "$cur") )
                    fi
                    ;;
                allow-for)
                    if [ "$cword" -eq 3 ]; then
                        # shellcheck disable=SC2207
                        COMPREPLY=( $(compgen -W "--stop $(_boxa_containers_bash)" -- "$cur") )
                    elif [ "$cword" -eq 4 ]; then
                        # shellcheck disable=SC2207
                        COMPREPLY=( $(compgen -W "$(_boxa_containers_bash)" -- "$cur") )
                    fi
                    ;;
                allow)
                    # No useful source for "things you might want to add"
                    # (ADR 0012 § Shell completion).
                    ;;
                deny)
                    if [ "$cword" -eq 3 ]; then
                        # shellcheck disable=SC2207
                        COMPREPLY=( $(compgen -W "$(_boxa_agent_allowed_bash)" -- "$cur") )
                    fi
                    ;;
            esac
            ;;
    esac
}

complete -F _boxa boxa
