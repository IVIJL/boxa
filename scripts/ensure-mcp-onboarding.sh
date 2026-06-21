#!/usr/bin/env bash
set -euo pipefail
# One-time MCP onboarding offer (ADR 0013, issue 10).
#
# Fresh installs and the FIRST `boxa update` after MCP support ships should
# make MCP discovery easy without nagging the user on every later update. This
# hook is the single seam both install.sh and the `boxa update` self-heal
# chain call, mirroring the shape of ensure-boxa-skill.sh and the other
# ensure-*.sh provisioners.
#
# Behaviour (issue 10 acceptance criteria):
#   * Offer the import wizard ONLY when eligible: no boxa MCP profile exists
#     yet AND the wizard has not already been seen/dismissed. Eligibility lives
#     in the unit-tested Python core (`mcp.onboarding`), read here as JSON.
#   * Interactive TTY + eligible -> print the offer, ask Y/n. On accept, run a
#     READ-ONLY `boxa mcp import` (dry-run discovery; nothing is applied), then
#     mark the wizard seen so it never re-fires. On decline, mark it dismissed.
#   * Non-interactive (CI/cron/piped) + eligible -> NEVER prompt or open a
#     picker; print a concise follow-up command and DO NOT mark seen, so a later
#     INTERACTIVE update still gets the chance to ask (matches the HTTPS prompt
#     convention in docker-run.sh).
#   * Not eligible (already seen, or a profile already exists) -> print only a
#     short reminder pointing at `boxa mcp import` / `boxa mcp add`, unless
#     --quiet-if-noop is set (steady-state `boxa update` stays silent).
#
# The seen/dismissed marker is stored OUTSIDE the profile at
# ~/.config/boxa/mcp/state.json, so deleting profile files does not re-arm the
# prompt. The marker write is delegated to the Python core.
#
# SECRET-FREE: this hook never reads or prints a credential value; the dry-run
# import it may launch only emits env-variable NAMES.

BOXA_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
MCP_PY_DIR="$BOXA_DIR/scripts"
MCP_CLI="$BOXA_DIR/scripts/mcp-cli.sh"

QUIET_IF_NOOP=false
FORCE_NONINTERACTIVE=false

for arg in "$@"; do
    case "$arg" in
        --quiet-if-noop) QUIET_IF_NOOP=true ;;
        # Test/CI seam: force the non-interactive branch regardless of the TTY
        # state of the harness running the tests.
        --non-interactive) FORCE_NONINTERACTIVE=true ;;
        -h|--help)
            cat <<'EOF'
Usage: ensure-mcp-onboarding.sh [--quiet-if-noop] [--non-interactive]

One-time MCP onboarding offer for fresh installs and the first eligible
`boxa update`. Offers the import wizard only when no boxa MCP profile
exists yet and the wizard has not already been seen. Non-interactive runs
never prompt; they print a concise follow-up command instead.

Options:
  --quiet-if-noop     Suppress the later-update reminder when not eligible.
  --non-interactive   Force the non-interactive branch (testing/CI).
EOF
            exit 0 ;;
        *)
            echo "ensure-mcp-onboarding.sh: unknown arg '$arg'" >&2
            exit 2 ;;
    esac
done

warn() { printf '%s\n' "$*" >&2; }

# Run the MCP Python core with scripts/ on PYTHONPATH (single source of truth
# for the candidate model + onboarding state).
_run_py() {
    PYTHONPATH="$MCP_PY_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 -m mcp.cli "$@"
}

# Pull one field out of the onboarding-status JSON without a JSON parser
# dependency: the Python core emits a stable indented object, so a single field
# is matched with a focused grep. Prints "true"/"false"/the value, or "" when
# absent. The field names are fixed (shouldOffer/profileExists/seen), so this is
# robust enough for the boolean branches we need here.
_status_field() {
    local json="$1" field="$2"
    printf '%s\n' "$json" \
        | grep -E "\"$field\"[[:space:]]*:" \
        | head -n1 \
        | sed -E "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"?([^\",]*)\"?.*/\1/"
}

# python3 is a hard prerequisite of the whole MCP feature; without it the hook
# cannot read eligibility. Fail soft (warn, exit 0) so a missing interpreter
# never breaks `boxa update`.
if ! command -v python3 >/dev/null 2>&1; then
    $QUIET_IF_NOOP || warn "python3 not found; skipping MCP onboarding check."
    exit 0
fi

status_json="$(_run_py onboarding-status 2>/dev/null || true)"
if [ -z "$status_json" ]; then
    $QUIET_IF_NOOP || warn "Could not read MCP onboarding status; skipping."
    exit 0
fi

should_offer="$(_status_field "$status_json" shouldOffer)"

# Not eligible: the wizard was already seen, or a profile already exists. Print
# only the short reminder (suppressed under --quiet-if-noop for steady-state
# updates), then stop. Never prompt.
if [ "$should_offer" != "true" ]; then
    if ! $QUIET_IF_NOOP; then
        echo ""
        _run_py onboarding-text reminder
    fi
    exit 0
fi

# Eligible. Decide interactivity. A non-interactive run (no TTY, or the test
# seam) prints the follow-up command and does NOT mark the wizard seen, so a
# later interactive update can still offer it.
interactive=true
if $FORCE_NONINTERACTIVE || [ ! -t 0 ] || [ ! -t 1 ]; then
    interactive=false
fi

if ! $interactive; then
    echo ""
    echo "==> MCP support is available."
    _run_py onboarding-text followup
    exit 0
fi

# Interactive + eligible: present the offer and ask. On accept run a read-only
# dry-run discovery so the user immediately sees what could be imported; the
# actual apply is left to the user (`boxa mcp import --apply`). Either answer
# marks the wizard seen so it never re-fires on future updates.
echo ""
printf '\033[1;36m==> Set up MCP servers for your boxa Containers?\033[0m\n'
echo ""
_run_py onboarding-text offer
echo ""
ans=""
read -r -p "Scan your existing Claude Code / Codex MCP servers now? [Y/n] " ans || ans=""

case "$ans" in
    ""|y|Y|yes|YES)
        echo ""
        echo "Scanning for Inherited MCP servers (dry-run; nothing is applied)..."
        echo ""
        # Dry-run discovery only. The import dispatcher is read-only without
        # --apply, so this never writes a profile or agent config. A discovery
        # failure (e.g. no agent config present) is informational, not fatal.
        if [ -x "$MCP_CLI" ]; then
            "$MCP_CLI" import || true
        else
            _run_py import-text || true
        fi
        echo ""
        echo "To import Container-safe servers:  boxa mcp import --apply"
        echo "To add a brand-new boxa server:  boxa mcp add ..."
        _run_py onboarding-mark-seen imported || \
            warn "Note: could not record onboarding state; you may be asked again."
        ;;
    *)
        echo "Skipping MCP setup. Run 'boxa mcp import' later if you change your mind."
        _run_py onboarding-mark-seen dismissed || \
            warn "Note: could not record onboarding state; you may be asked again."
        ;;
esac

exit 0
