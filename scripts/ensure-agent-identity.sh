#!/usr/bin/env bash
set -euo pipefail

# One-time Agent identity offer (ADR 0032, issue 16).

BOXA_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
AGENT_IDENTITY_MARKER="${BOXA_AGENT_IDENTITY_MARKER:-${XDG_CONFIG_HOME:-$HOME/.config}/boxa/agent-identity-seen}"

# shellcheck source=../lib/resources.sh disable=SC1091
source "$BOXA_DIR/lib/resources.sh"
# shellcheck source=../lib/picker.sh disable=SC1091
source "$BOXA_DIR/lib/picker.sh"
# shellcheck source=../lib/ssh.sh disable=SC1091
source "$BOXA_DIR/lib/ssh.sh"
# The forge dashboard offers the Allowlist entry for a new forge host and
# reads ALLOWLIST_HOST_FILE from lib/allowlist.sh.
# shellcheck source=../lib/allowlist.sh disable=SC1091
source "$BOXA_DIR/lib/allowlist.sh"
# shellcheck source=../lib/forge.sh disable=SC1091
source "$BOXA_DIR/lib/forge.sh"

usage() {
    cat <<'EOF'
Usage: ensure-agent-identity.sh <offer|probe|summary|enable> [options]

One-time offer to provision the scoped Boxa Agent key.

Options for offer and enable:
  --non-interactive  Print the later-setup command without recording a choice.
  --interactive      Force the prompt (test seam).
EOF
}

agent_identity::usage_configured() {
    _boxa::ssh_agent_usage_configured || _boxa::forge_usage_configured
}

agent_identity::probe() {
    if _boxa::ssh_agent_key_exists && agent_identity::usage_configured; then
        printf 'ok\n'
    elif [ -f "$AGENT_IDENTITY_MARKER" ]; then
        printf 'declined\n'
    else
        printf 'missing\n'
    fi
}

agent_identity::summary_one() {
    local forge="$1" display_name="$2" host="$3"
    local ssh_username='' token_username='' details=''

    ssh_username="$(_boxa::forge_ssh_probe_username "$host" 2>/dev/null)" \
        || ssh_username=''
    if _boxa::forge_load_credential "$forge"; then
        token_username="$_BOXA_FORGE_USERNAME"
    fi
    [ -z "$ssh_username" ] || details="SSH as $ssh_username"
    if [ -n "$token_username" ]; then
        [ -z "$details" ] || details="$details; "
        details="${details}token as $token_username"
    fi
    [ -z "$details" ] || printf '%s Agent: %s\n' "$display_name" "$details"
}

agent_identity::summary() {
    local gitlab_host=''

    _boxa::ssh_agent_key_exists || return 0
    agent_identity::summary_one github GitHub github.com || true
    if _boxa::forge_load_credential gitlab; then
        gitlab_host="$_BOXA_FORGE_HOST"
    fi
    [ -z "$gitlab_host" ] \
        || agent_identity::summary_one gitlab GitLab "$gitlab_host" || true
    return 0
}

agent_identity::dismiss() {
    mkdir -p "${AGENT_IDENTITY_MARKER%/*}"
    (umask 077 && printf 'dismissed\n' > "$AGENT_IDENTITY_MARKER")
    printf "Agent identity setup skipped. Run 'boxa doctor --fix agent-identity' later.\n"
}

agent_identity::follow_up() {
    printf 'Agent key ready. The shared forge dashboard follows.\n'
    _boxa::forge_dashboard "$PWD"
}

agent_identity::adopt_existing() {
    local path comment fingerprint label selected found=''
    local i
    local -a key_paths=() key_labels=()

    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -f "$path.pub" ] || continue
        fingerprint="$(ssh-keygen -lf "$path.pub" 2>/dev/null \
            | awk 'NR == 1 { print $2 }')"
        [ -n "$fingerprint" ] || continue
        comment="$(_boxa::ssh_public_comment "$path")"
        label="$path — $fingerprint"
        [ -z "$comment" ] || label="$label — $comment"
        key_paths+=("$path")
        key_labels+=("$label")
    done < <(_boxa::ssh_discover_keys "$HOME/.ssh")

    if [ "${#key_paths[@]}" -eq 0 ]; then
        printf 'No existing key pairs with public-key companions found under ~/.ssh.\n' >&2
        return 1
    fi

    selected="$(printf '%s\n' "${key_labels[@]}" \
        | picker::one --prompt 'Select the Agent key:')" || return 1
    for ((i = 0; i < ${#key_labels[@]}; i++)); do
        if [ "$selected" = "${key_labels[$i]}" ]; then
            _boxa::ssh_adopt_agent_key "${key_paths[$i]}" || return 1
            found=1
            break
        fi
    done
    [ -n "$found" ] || return 1
    printf 'Existing key registered as the Boxa Agent key: %s\n' \
        "$(_boxa::ssh_agent_key_fingerprint)"
}

agent_identity::wizard() {
    local generate='Generate a new Agent key (recommended)'
    local adopt='Adopt an existing key'
    local skip='Skip for now'
    local selected

    selected="$(printf '%s\n' "$generate" "$adopt" "$skip" \
        | picker::one --prompt 'Agent key setup:')" || {
        agent_identity::dismiss
        return 0
    }
    case "$selected" in
        "$generate")
            _boxa::ssh_generate_agent_key
            ;;
        "$adopt")
            agent_identity::adopt_existing
            ;;
        "$skip")
            agent_identity::dismiss
            return 0
            ;;
        *) return 1 ;;
    esac

    _boxa::write_ssh_conf global "" on
    rm -f "$AGENT_IDENTITY_MARKER"
    printf 'Dedicated Agent SSH forwarding enabled globally.\n'
    agent_identity::follow_up
}

agent_identity::parse_interactivity() {
    local arg

    AGENT_IDENTITY_FORCE_NONINTERACTIVE=false
    AGENT_IDENTITY_FORCE_INTERACTIVE=false
    for arg in "$@"; do
        case "$arg" in
            --non-interactive) AGENT_IDENTITY_FORCE_NONINTERACTIVE=true ;;
            --interactive) AGENT_IDENTITY_FORCE_INTERACTIVE=true ;;
            *) printf 'agent-identity: unknown option %s\n' "$arg" >&2; return 2 ;;
        esac
    done
}

agent_identity::interactive() {
    ! $AGENT_IDENTITY_FORCE_NONINTERACTIVE \
        && { $AGENT_IDENTITY_FORCE_INTERACTIVE || { [ -t 0 ] && [ -t 1 ]; }; }
}

agent_identity::noninteractive_follow_up() {
    printf "Agent identity is not configured. Run 'boxa doctor --fix agent-identity' from an interactive terminal.\n"
}

agent_identity::offer() {
    local answer=''

    agent_identity::parse_interactivity "$@" || return $?
    [ "$(agent_identity::probe)" = missing ] || return 0
    if ! agent_identity::interactive; then
        agent_identity::noninteractive_follow_up
        return 0
    fi

    printf '\nCreate a scoped Agent key so containers can access forges without receiving your personal SSH agent, while still granting them signing authority through its dedicated socket? [y/N] '
    IFS= read -r answer || answer=''
    case "$answer" in
        y|Y|yes|YES) agent_identity::wizard ;;
        *) agent_identity::dismiss ;;
    esac
}

agent_identity::enable() {
    agent_identity::parse_interactivity "$@" || return $?
    if ! agent_identity::interactive; then
        agent_identity::noninteractive_follow_up
        return 0
    fi
    agent_identity::wizard
}

command_name="${1:-}"
if [ -n "$command_name" ]; then
    shift
fi
case "$command_name" in
    offer)  agent_identity::offer "$@" ;;
    probe)  [ "$#" -eq 0 ] || { printf 'agent-identity probe: no options expected\n' >&2; exit 2; }; agent_identity::probe ;;
    summary) [ "$#" -eq 0 ] || { printf 'agent-identity summary: no options expected\n' >&2; exit 2; }; agent_identity::summary ;;
    enable) agent_identity::enable "$@" ;;
    -h|--help|'') usage ;;
    *) printf 'ensure-agent-identity.sh: unknown command %s\n' "$command_name" >&2; usage >&2; exit 2 ;;
esac
