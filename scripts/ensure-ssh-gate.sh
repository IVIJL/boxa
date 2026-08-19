#!/usr/bin/env bash
set -euo pipefail

# One-time SSH gate offer for fresh installs and upgrades (ADR 0026).

BOXA_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SSH_GATE_MARKER="${BOXA_SSH_GATE_MARKER:-${XDG_CONFIG_HOME:-$HOME/.config}/boxa/ssh-gate-seen}"

# shellcheck source=../lib/resources.sh disable=SC1091
source "$BOXA_DIR/lib/resources.sh"
# shellcheck source=../lib/picker.sh disable=SC1091
source "$BOXA_DIR/lib/picker.sh"
# shellcheck source=../lib/ssh.sh disable=SC1091
source "$BOXA_DIR/lib/ssh.sh"

usage() {
    cat <<'EOF'
Usage: ensure-ssh-gate.sh <offer|probe|enable> [options]

One-time offer to enable global SSH agent forwarding.

Options for offer:
  --non-interactive  Print the later-enable command without recording a choice.
  --interactive      Force the prompt (test seam).
EOF
}

ssh_gate::probe() {
    # Only explicit global on is active; global off records a decline decision.
    # An empty project path cannot match a valid section, so the shared parser
    # reports only the global value here without duplicating ssh.conf parsing.
    _boxa::resolve_ssh_gate ""
    if [ "$_BOXA_SSH_SOURCE" = global ] && [ "$_BOXA_SSH_GATE" = on ]; then
        printf 'ok\n'
    elif [ "$_BOXA_SSH_SOURCE" = global ] || [ -f "$SSH_GATE_MARKER" ]; then
        printf 'declined\n'
    else
        printf 'missing\n'
    fi
}

ssh_gate::enable() {
    _boxa::write_ssh_conf global "" on
    printf 'SSH agent forwarding enabled globally.\n'
    _boxa::ssh_add_keys_if_agent_unready
}

ssh_gate::dismiss() {
    mkdir -p "${SSH_GATE_MARKER%/*}"
    printf 'dismissed\n' > "$SSH_GATE_MARKER"
    printf "SSH agent forwarding remains off. Enable it later with 'boxa ssh on --global'.\n"
}

ssh_gate::offer() {
    local force_noninteractive=false force_interactive=false
    local arg answer=""

    for arg in "$@"; do
        case "$arg" in
            --non-interactive) force_noninteractive=true ;;
            --interactive) force_interactive=true ;;
            *) printf 'ssh-gate offer: unknown option %s\n' "$arg" >&2; return 2 ;;
        esac
    done

    [ "$(ssh_gate::probe)" = missing ] || return 0

    if $force_noninteractive || { ! $force_interactive && { [ ! -t 0 ] || [ ! -t 1 ]; }; }; then
        printf "SSH agent forwarding remains off. Enable it with: boxa ssh on --global\n"
        return 0
    fi

    printf '\nBoxa no longer forwards your SSH agent into containers automatically.\n'
    printf 'A forwarded socket grants a container signing authority over every key in the agent.\n'
    printf 'Enable forwarding? [y/N] '
    read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES) ssh_gate::enable ;;
        *) ssh_gate::dismiss ;;
    esac
}

command_name="${1:-}"
if [ -n "$command_name" ]; then
    shift
fi
case "$command_name" in
    offer)  ssh_gate::offer "$@" ;;
    probe)  [ "$#" -eq 0 ] || { printf 'ssh-gate probe: no options expected\n' >&2; exit 2; }; ssh_gate::probe ;;
    enable) [ "$#" -eq 0 ] || { printf 'ssh-gate enable: no options expected\n' >&2; exit 2; }; ssh_gate::enable ;;
    -h|--help|'') usage ;;
    *) printf 'ensure-ssh-gate.sh: unknown command %s\n' "$command_name" >&2; usage >&2; exit 2 ;;
esac
