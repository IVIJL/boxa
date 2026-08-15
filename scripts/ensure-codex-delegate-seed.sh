#!/usr/bin/env bash
set -euo pipefail
# One-time codex-delegate catalog seed offer (ADR 0021).
#
# The Container image bakes the Codex CLI, so trusted Codex delegation
# ('codex mcp-server' as an MCP server for Claude) needs no install — only a
# user-wide catalog definition plus the host-confirmed agent-trusted grant.
# This hook is the single seam install.sh and the `boxa update` self-heal
# chain call, mirroring ensure-mcp-onboarding.sh.
#
# Behaviour:
#   * Offer ONLY when eligible: no catalog entry running `codex mcp-server`
#     exists yet AND the offer has not already been applied/dismissed.
#     Eligibility lives in the unit-tested Python core (`mcp.seed`).
#   * Interactive TTY + eligible -> print the offer INCLUDING the exact
#     agent-trusted access boundary (the same wording `boxa mcp mode`
#     previews), ask y/N. Explicit yes applies the seed (definition + grant;
#     the grant path itself refuses inside a Container) and marks the offer
#     seen. Explicit no marks it dismissed. Anything else, or unreadable
#     input, skips without marking. Nothing is activated: Projects still opt
#     in via `boxa mcp activate`.
#   * Non-interactive (CI/cron/piped) + eligible -> NEVER prompt or apply;
#     print the manual commands and DO NOT mark seen, so a later INTERACTIVE
#     update still gets the chance to ask.
#   * Not eligible -> when the entry already exists, stay silent (steady
#     state); when previously dismissed, print a short reminder unless
#     --quiet-if-noop is set.
#
# The seen/dismissed marker shares ~/.config/boxa/mcp/state.json with the
# onboarding wizard (own key), so deleting catalog files does not re-arm it.
#
# SECRET-FREE: the seeded definition has no env or secrets; this hook never
# reads or prints a credential value.

BOXA_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
MCP_PY_DIR="$BOXA_DIR/scripts"

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
Usage: ensure-codex-delegate-seed.sh [--quiet-if-noop] [--non-interactive]

One-time offer to seed the default 'codex-delegate' MCP catalog entry
(trusted Codex delegation) on fresh installs and the first eligible
`boxa update`. Offered only when no codex-delegate definition exists yet
and the offer has not already been applied/dismissed. Non-interactive runs
never prompt or apply; they print the manual commands instead.

Options:
  --quiet-if-noop     Suppress the later-update reminder when not eligible.
  --non-interactive   Force the non-interactive branch (testing/CI).
EOF
            exit 0 ;;
        *)
            echo "ensure-codex-delegate-seed.sh: unknown arg '$arg'" >&2
            exit 2 ;;
    esac
done

warn() { printf '%s\n' "$*" >&2; }

# Run the MCP Python core with scripts/ on PYTHONPATH (single source of truth
# for eligibility, texts, and the apply path).
_run_py() {
    PYTHONPATH="$MCP_PY_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 -m mcp.cli "$@"
}

# Pull one field out of the seed-status JSON without a JSON parser dependency:
# the Python core emits a stable indented object, so a single field is matched
# with a focused grep (same convention as ensure-mcp-onboarding.sh).
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
    $QUIET_IF_NOOP || warn "python3 not found; skipping codex-delegate seed check."
    exit 0
fi

status_json="$(_run_py seed-codex-delegate-status 2>/dev/null || true)"
if [ -z "$status_json" ]; then
    $QUIET_IF_NOOP || warn "Could not read codex-delegate seed status; skipping."
    exit 0
fi

should_offer="$(_status_field "$status_json" shouldOffer)"
entry_present="$(_status_field "$status_json" entryPresent)"

# Not eligible. An existing delegation entry is the steady state — stay
# silent. A previously dismissed offer gets a short reminder (suppressed
# under --quiet-if-noop). Never prompt.
if [ "$should_offer" != "true" ]; then
    if [ "$entry_present" != "true" ] && ! $QUIET_IF_NOOP; then
        echo ""
        _run_py seed-codex-delegate-text reminder
    fi
    exit 0
fi

# Eligible. Decide interactivity. A non-interactive run (no TTY, or the test
# seam) prints the manual commands and does NOT mark the offer seen, so a
# later interactive update can still offer it.
interactive=true
if $FORCE_NONINTERACTIVE || [ ! -t 0 ] || [ ! -t 1 ]; then
    interactive=false
fi

if ! $interactive; then
    echo ""
    echo "==> Trusted Codex delegation (MCP) is available."
    _run_py seed-codex-delegate-text followup
    exit 0
fi

# Interactive + eligible: present the offer (with the exact access boundary)
# and ask. Accepting is the host confirmation the `boxa mcp mode` flow
# otherwise collects, so the apply may pass --yes. A failed apply marks
# nothing, so a fixed environment gets the offer again on the next update.
echo ""
printf '\033[1;36m==> Prepare trusted Codex delegation (codex-delegate MCP entry)?\033[0m\n'
echo ""
_run_py seed-codex-delegate-text offer
echo ""
read -r -p "Add the 'codex-delegate' entry with the agent-trusted grant now? [y/N] " ans || {
    echo "Skipping (no confirmation read)."
    exit 0
}

case "$ans" in
    y|Y|yes|YES)
        echo ""
        if _run_py seed-codex-delegate-apply --yes; then
            echo ""
            echo "Nothing is active yet. Enable it per Project on the host:"
            echo "  boxa mcp readiness codex-delegate --project <path>   # checks 'codex login'"
            echo "  boxa mcp activate codex-delegate --project <path> --for claude"
        else
            warn "codex-delegate seed failed; run 'boxa mcp add codex-delegate -- codex mcp-server' manually."
        fi
        ;;
    n|N|no|NO)
        echo "Skipping. Seed later with 'boxa mcp add codex-delegate -- codex mcp-server'."
        _run_py seed-codex-delegate-mark-seen dismissed || \
            warn "Note: could not record seed state; you may be asked again."
        ;;
    *)
        echo "Skipping for now; 'boxa update' will offer again."
        ;;
esac

exit 0
