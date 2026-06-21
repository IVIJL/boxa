#!/bin/bash
set -euo pipefail
# Idempotent host-side install/refresh of the boxa shell completions
# (ADR 0017 § 2 category A). A no-op when the installed completion file is
# already current.
#
# This consolidates the two previously-duplicated copies of the completion
# install logic — install.sh's _install_zsh_completion/_install_bash_completion
# and the inline zsh block in the `boxa update` flow — into one
# implementation. Called from install.sh during fresh install and, via
# lib/provisioning.sh, from `boxa doctor` / the `boxa update` self-heal
# chain for existing installs. Mirrors the shape of ensure-mkcert.sh /
# ensure-agent-allowlist-example.sh.
#
# Two parallel completion files live in completions/:
#   _boxa       — zsh (`#compdef boxa`, native fpath-installed)
#   boxa.bash   — bash (`complete -F _boxa boxa`, sourced from .bashrc)
#
# The routine routes by $SHELL:
#   - zsh:  copy _boxa into a completion dir. Prefer a WRITABLE fpath dir
#           (no sudo, skipping the repo dir itself); fall back to `sudo -n cp`
#           into an fpath dir (non-interactive, cached credentials only); when
#           neither works, emit a clear informational note. No .zshrc edits.
#   - bash: idempotent .bashrc edit (marker-gated) that sources the bundled
#           completions/boxa.bash directly.
#   - else: skipped with a notice.
#
# Idempotent. Honours --quiet-if-noop: stays silent when the installed file is
# already current. Exits 0 when completions are present/current (or the shell
# is unsupported); exits non-zero only on a real write failure.

BOXA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QUIET_IF_NOOP=false

for arg in "$@"; do
    case "$arg" in
        --quiet-if-noop) QUIET_IF_NOOP=true ;;
        -h|--help)
            cat <<'EOF'
Usage: ensure-completions.sh [--quiet-if-noop]

Idempotently install/refresh the boxa shell completion file for the current
shell ($SHELL). zsh: copy _boxa into a writable fpath dir, else `sudo -n cp`,
else print a note. bash: marker-gated .bashrc edit sourcing boxa.bash.

Options:
  --quiet-if-noop   Suppress output when nothing needed to be done.
EOF
            exit 0 ;;
        *)
            echo "ensure-completions.sh: unknown arg '$arg'" >&2
            exit 2 ;;
    esac
done

log() { $QUIET_IF_NOOP || printf '%s\n' "$*"; }
loud() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# --- zsh ---------------------------------------------------------------------
# Returns 0 on success (file present/current or freshly installed), non-zero on
# a real failure. Prints actions to stdout; stays silent on a no-op under
# --quiet-if-noop.
ensure_zsh_completion() {
    local src="$BOXA_DIR/completions/_boxa"
    if [ ! -f "$src" ]; then
        warn "zsh completion source not found at $src."
        return 1
    fi

    # Ask zsh for its current fpath entries.
    local fpath_dirs
    fpath_dirs=$(zsh -c 'echo $fpath' 2>/dev/null | tr ' ' '\n')

    # The EFFECTIVE completion is the `_boxa` in the earliest fpath dir — that
    # is the one zsh autoloads, shadowing any copy in a later dir. So precedence
    # matters: find the first fpath dir that already holds a `_boxa`.
    local dir effective_dir=""
    while IFS= read -r dir; do
        [ -d "$dir" ] || continue
        case "$dir" in "$BOXA_DIR"*) continue ;; esac  # skip the repo dir
        if [ -f "$dir/_boxa" ]; then effective_dir="$dir"; break; fi
    done <<< "$fpath_dirs"

    # No-op only when that effective (earliest) copy is current. A current copy
    # in a LATER dir does not count — zsh would still load the earlier stale one.
    if [ -n "$effective_dir" ] && cmp -s "$src" "$effective_dir/_boxa"; then
        log "zsh completion already current at $effective_dir/_boxa (no changes)."
        return 0
    fi

    # Install targets: when a stale copy occupies the effective dir, it must be
    # refreshed THERE (a fresh copy in a later dir would be shadowed by it).
    # Otherwise (no copy anywhere yet) install into the first usable fpath dir.
    local targets="$fpath_dirs"
    [ -n "$effective_dir" ] && targets="$effective_dir"

    # Priority 1: writable target — no sudo, no .zshrc changes.
    while IFS= read -r dir; do
        [ -d "$dir" ] || continue
        case "$dir" in "$BOXA_DIR"*) continue ;; esac
        if [ -w "$dir" ]; then
            if cp "$src" "$dir/_boxa"; then
                loud "Installed zsh completion in $dir"
                return 0
            fi
        fi
    done <<< "$targets"

    # Priority 2: target via `sudo -n` — non-interactive, cached
    # credentials only. Never prompts: a missing sudo degrades to the note.
    while IFS= read -r dir; do
        [ -d "$dir" ] || continue
        case "$dir" in "$BOXA_DIR"*) continue ;; esac
        if sudo -n cp "$src" "$dir/_boxa" 2>/dev/null; then
            loud "Installed zsh completion in $dir (via sudo)"
            return 0
        fi
    done <<< "$targets"

    # Priority 3: a user-owned dir under $HOME — NO sudo. Create
    # ~/.zsh/completions, install the file there, and prepend it to fpath via a
    # marker-gated .zshrc block that re-runs compinit. This is the common path
    # when every system fpath dir is root-owned and sudo is unavailable (the
    # original installer relied on it); without it, such hosts could never get
    # completion without elevation. Prepending + re-running compinit makes the
    # fresh copy win precedence over any stale system copy, and is portable
    # (no GNU/BSD `sed` differences).
    local user_dir="$HOME/.zsh/completions"
    local zshrc="$HOME/.zshrc"
    local marker="# Boxa: zsh completion fpath"
    # Idempotency for THIS fallback: a non-interactive `zsh -c 'echo $fpath'`
    # does not source .zshrc, so the earlier fpath scan above can never discover
    # ~/.zsh/completions once it is installed. Detect a prior fallback install
    # directly — marker in .zshrc AND a current file — and treat it as a no-op,
    # otherwise every `boxa update` / doctor run would rewrite it and report a
    # bogus repair.
    if grep -qF "$marker" "$zshrc" 2>/dev/null \
       && [ -f "$user_dir/_boxa" ] && cmp -s "$src" "$user_dir/_boxa"; then
        log "zsh completion already current at $user_dir/_boxa (no changes)."
        return 0
    fi
    if mkdir -p "$user_dir" && cp "$src" "$user_dir/_boxa"; then
        if grep -qF "$marker" "$zshrc" 2>/dev/null; then
            loud "Installed zsh completion in $user_dir"
            return 0
        fi
        # shellcheck disable=SC2016  # $fpath is a zsh var, intentionally literal
        if printf '\n%s\nfpath=(%s $fpath)\nautoload -Uz compinit && compinit\n' \
               "$marker" "$user_dir" >> "$zshrc"; then
            loud "Installed zsh completion in $user_dir (added to fpath in $zshrc)"
            return 0
        fi
    fi

    # Priority 4: even the user-writable fallback failed (e.g. $HOME not
    # writable). Completion is genuinely unprovisioned. Emit the note on STDERR
    # (never stdout: the provisioning registry treats stdout as a
    # successful-repair signal) and return NON-ZERO so the registry records a
    # failed step and `boxa doctor` reports it as unhealthy rather than
    # silently "OK". install.sh calls this provisioner inside an `if`, so the
    # non-zero is recorded as SKIPPED there, never aborting the install.
    warn "Note: zsh completion not updated (no writable location found)."
    warn "      Re-run with elevated privileges or run install.sh to (re)install it."
    return 1
}

# --- bash --------------------------------------------------------------------
# Marker-gated .bashrc edit sourcing the bundled boxa.bash. Idempotent: a
# matching marker is a no-op.
ensure_bash_completion() {
    local src="$BOXA_DIR/completions/boxa.bash"
    if [ ! -f "$src" ]; then
        warn "bash completion source not found at $src."
        return 1
    fi

    local bashrc="$HOME/.bashrc"
    local marker="# Boxa: bash completion"
    local source_line="source \"$src\""

    if grep -qF "$marker" "$bashrc" 2>/dev/null; then
        log "bash completion already configured in $bashrc (no changes)."
        return 0
    fi

    if ! printf '\n%s\n%s\n' "$marker" "$source_line" >> "$bashrc"; then
        warn "Failed to append bash completion to $bashrc."
        return 1
    fi
    loud "Configured bash completion in $bashrc"
    return 0
}

# --- Dispatch by shell -------------------------------------------------------
shell_name="$(basename "${SHELL:-/bin/bash}")"
case "$shell_name" in
    zsh)  ensure_zsh_completion ;;
    bash) ensure_bash_completion ;;
    *)
        log "Shell completion skipped (shell is $shell_name, not zsh or bash)."
        exit 0
        ;;
esac
