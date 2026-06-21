#!/bin/bash
set -euo pipefail
# Idempotent host-side install/refresh of the upstream vercel-labs/agent-browser
# skill (ADR 0011 § "Upstream agent-browser skill").
#
# The upstream `skills` CLI writes content to ~/.agents/skills/agent-browser/
# and creates per-agent symlinks at ~/.claude/skills/agent-browser and
# ~/.codex/skills/agent-browser. We invoke it with two `--yes` flags:
#  - outer `--yes` suppresses npx's own "install package?" prompt;
#  - inner `--yes` suppresses the `skills` CLI confirmation prompts.
#
# Called from install.sh during fresh install and from `boxa update` as a
# self-heal so existing installs pick up upstream refreshes without an extra
# manual step. The install must run on host because ~/.agents/ is read-only
# inside containers per ADR 0002.
#
# Non-fatal-on-failure: a missing `npx` binary or a network outage collects
# into WARNINGS and surfaces in the end-of-script summary instead of aborting
# the install (per the no-silent-failures rule — every soft failure must be
# visible).
#
# Pre-existing custom user skill at ~/.claude/skills/agent-browser:
# overwrite behaviour is the `skills` CLI's concern. We detect a non-symlink
# target (or a symlink that does not point at the shared ~/.agents/ source)
# and emit a warning so the user knows their fork is at risk; if the CLI
# clobbers it anyway, that is an upstream behaviour worth filing as an issue
# against vercel-labs/skills rather than a bug in this script.

QUIET_IF_NOOP=false
REFRESH=false
for arg in "$@"; do
    case "$arg" in
        --quiet-if-noop) QUIET_IF_NOOP=true ;;
        --refresh) REFRESH=true ;;
        -h|--help)
            cat <<EOF
Usage: ensure-upstream-agent-browser-skill.sh [--quiet-if-noop] [--refresh]

Installs the upstream vercel-labs/agent-browser skill into
~/.agents/skills/agent-browser/ plus the per-agent symlinks for Claude Code
and Codex. By default, skips when the skill is already installed so 'boxa
update' stays quiet on steady-state. Use --refresh to force re-running the
upstream installer and pick up new releases.

Options:
  --quiet-if-noop   Suppress output when nothing needed to be done.
  --refresh         Force re-install even when the skill is already present
                    (the path to pick up upstream releases).
EOF
            exit 0 ;;
        *)
            echo "ensure-upstream-agent-browser-skill.sh: unknown arg '$arg'" >&2
            exit 2 ;;
    esac
done

log() { $QUIET_IF_NOOP || printf '%s\n' "$*"; }
loud() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

WARNINGS=()

print_summary() {
    if [ "${#WARNINGS[@]}" -eq 0 ]; then
        return
    fi
    warn ""
    warn "Upstream agent-browser skill install — warnings:"
    for w in "${WARNINGS[@]}"; do
        warn "  - $w"
    done
}

CONFLICT_DETECTED=false

# Detect a pre-existing custom user skill at the per-agent symlink path.
# The `skills` CLI manages this path as a symlink into ~/.agents/skills/;
# anything else (a real directory, or a symlink pointing elsewhere) signals
# the user has their own fork.
#
# Why this matters: the upstream `skills add` CLI removes/replaces the target
# non-interactively when given `--yes`, so a `boxa update` run could
# silently destroy a user's customisation. The acceptance contract is
# "warned, not silently clobbered" — so when this function flags a conflict,
# the caller skips the install entirely and prints the warning. The user
# resolves it by moving their fork aside, then re-running `boxa update`.
#
# All branches return 0 — this function only collects state. A broken
# relative symlink (target whose parent no longer exists) is treated as a
# conflict so `set -e` cannot abort the helper mid-traversal and so the
# preserved-but-broken link does not become a foot-gun on the next run.
check_user_skill_conflict() {
    local agent_skill_dir="$1"
    local agent_name="$2"
    local agents_root="$HOME/.agents/skills/agent-browser"

    if [ ! -e "$agent_skill_dir" ] && [ ! -L "$agent_skill_dir" ]; then
        return 0
    fi

    if [ -L "$agent_skill_dir" ]; then
        local target resolved parent_dir
        target="$(readlink "$agent_skill_dir")"
        # Resolve relative symlinks against the link's parent directory so
        # the comparison matches the layout `skills` CLI produces
        # (`../../.agents/skills/agent-browser`). Use a guarded `cd` so a
        # missing intermediate directory degrades to a warning instead of
        # tripping `set -e`.
        case "$target" in
            /*) resolved="$target" ;;
            *)
                parent_dir="$(dirname "$agent_skill_dir")"
                if resolved="$(cd "$parent_dir" 2>/dev/null && cd "$(dirname "$target")" 2>/dev/null && pwd)"; then
                    resolved="$resolved/$(basename "$target")"
                else
                    WARNINGS+=("$agent_name skill at $agent_skill_dir is a broken relative symlink (target '$target' unreachable); skipping install to avoid clobbering. Remove or repair the link, then re-run 'boxa update'.")
                    CONFLICT_DETECTED=true
                    return 0
                fi
                ;;
        esac
        if [ "$resolved" = "$agents_root" ]; then
            return 0
        fi
        WARNINGS+=("$agent_name skill at $agent_skill_dir is a symlink to $resolved (not the shared ~/.agents/ source); skipping install to avoid clobbering your custom skill. Move it aside if you want the upstream version, then re-run 'boxa update'.")
        CONFLICT_DETECTED=true
        return 0
    fi

    WARNINGS+=("$agent_name skill at $agent_skill_dir is a custom directory (not a symlink); skipping install to avoid clobbering your custom skill. Move it aside if you want the upstream version, then re-run 'boxa update'.")
    CONFLICT_DETECTED=true
}

# Skip-if-installed: the upstream `skills` CLI prints a multi-screen ASCII
# banner + install summary every run, so unconditionally invoking it on
# every `boxa update` floods the terminal. Default behaviour is now
# skip-when-present; pass --refresh to opt into the upstream re-pull
# (used to pick up new releases of the skill).
agents_skill_md="$HOME/.agents/skills/agent-browser/SKILL.md"
if [ -f "$agents_skill_md" ] && [ "$REFRESH" = false ]; then
    log "Upstream agent-browser skill already installed at ~/.agents/skills/agent-browser/ (pass --refresh to re-pull)."
    exit 0
fi

# Exit-code contract: 0 = skill installed (or already up to date), non-zero
# = soft failure (npx missing, network down). install.sh uses the exit code
# to categorise the step as CONFIGURED vs SKIPPED so the final summary stays
# honest. docker-run.sh's update branch chains the call with `|| true` and
# only relies on stderr warnings.
if ! command -v npx >/dev/null 2>&1; then
    WARNINGS+=("'npx' not found on PATH — upstream agent-browser skill install skipped. Install Node.js (which provides npx) and re-run 'boxa update' to recover.")
    print_summary
    log "Upstream agent-browser skill install skipped (npx unavailable)."
    exit 1
fi

# Conflict probe targets the per-agent location the `skills` CLI actually
# writes to. Behaviour differs per agent (verified against `skills@0.x` in
# ~/.npm/_npx/.../skills/dist/cli.mjs):
#
#  - Claude Code is a non-universal agent (skillsDir = ".claude/skills"),
#    so `--agent claude-code --global` writes to
#    ${CLAUDE_CONFIG_DIR:-~/.claude}/skills/agent-browser. A user fork
#    there WILL be replaced by `skills add --yes`, so we must check it.
#
#  - Codex is a universal agent (skillsDir = ".agents/skills"), so
#    `--agent codex --global` writes to ~/.agents/skills/agent-browser
#    and does NOT touch ${CODEX_HOME:-~/.codex}/skills/agent-browser.
#    A user fork at ~/.codex/skills/agent-browser is therefore SAFE from
#    `skills add` and we do not block install on its presence.
#
#  - ~/.agents/skills/agent-browser is the canonical install target itself.
#    ADR 0011 § Consequences explicitly accepts that hand-customisations
#    there are overwritten on `boxa update`; we do not guard it.
claude_skill_root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/agent-browser"
check_user_skill_conflict "$claude_skill_root" "Claude Code"

if [ "$CONFLICT_DETECTED" = true ]; then
    # Honour "warned, not silently clobbered" from the acceptance contract:
    # do not invoke the upstream installer when a custom user skill is
    # present, because `skills add --yes` would non-interactively replace
    # it. The warning collector already explains the user's path forward.
    print_summary
    log "Upstream agent-browser skill install skipped (custom user skill detected; see warnings)."
    exit 1
fi

log "Installing upstream vercel-labs/agent-browser skill via 'skills' CLI..."

# Inner --yes is the `skills` CLI's own confirmation; outer --yes is npx's
# package-install prompt. We capture combined stdout+stderr because the
# skills CLI's interactive-style banner (ASCII art, box-drawing summary)
# is verbose enough to fill a terminal screen on every `boxa update`.
# On success we drop the captured output and emit one line; on failure we
# surface the captured output so the user has the failure context.
install_status=0
install_log=$(npx --yes skills@latest add vercel-labs/agent-browser \
        --skill agent-browser \
        --agent claude-code codex \
        --global \
        --yes 2>&1) || install_status=$?

if [ "$install_status" -eq 0 ]; then
    loud "Upstream agent-browser skill installed at ~/.agents/skills/agent-browser/."
else
    WARNINGS+=("'npx skills add vercel-labs/agent-browser' failed (network down or upstream registry unreachable?). Re-run 'boxa update' once connectivity is restored.")
    warn ""
    warn "Captured installer output:"
    printf '%s\n' "$install_log" >&2
fi

print_summary
exit "$install_status"
