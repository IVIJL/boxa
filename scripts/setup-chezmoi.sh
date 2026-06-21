#!/bin/bash
set -euo pipefail

# =============================================================================
# Chezmoi dotfiles setup (idempotent - runs on every container start)
#
# CHEZMOI_REPO selects the dotfiles source (seeded by docker-run.sh from the
# user's install-time choice in ~/.config/boxa/dotfiles.conf):
#   - empty      → no dotfiles (pure bash); skip entirely.
#   - "bundled"  → apply boxa's image-bundled starter locally (no network).
#   - <url>      → init/update a remote chezmoi repo, then apply.
# =============================================================================

CHEZMOI_BIN="$HOME/.local/bin/chezmoi"
CHEZMOI_REPO="${CHEZMOI_REPO:-}"

# Image-bundled starter (see Dockerfile: COPY dotfiles/ → here). Read-only.
BUNDLED_DOTFILES_DIR="/usr/local/share/boxa/dotfiles"

if [ ! -x "$CHEZMOI_BIN" ]; then
    echo "ERROR: chezmoi not found at $CHEZMOI_BIN"
    exit 1
fi

# --- None ---------------------------------------------------------------------
if [ -z "$CHEZMOI_REPO" ]; then
    echo "No dotfiles configured (CHEZMOI_REPO empty), skipping"
    exit 0
fi

# --- Bundled (local-first default) -------------------------------------------
# Apply straight from the read-only image directory each start. Stateless and
# idempotent; no clone, no ~/.local/share/chezmoi source to maintain. The
# bundled tree's own .chezmoiignore skips files that conflict with boxa's
# read-only bind mounts (e.g. ~/.config/git/ignore).
if [ "$CHEZMOI_REPO" = "bundled" ]; then
    if [ ! -d "$BUNDLED_DOTFILES_DIR" ]; then
        echo "ERROR: bundled dotfiles not found at $BUNDLED_DOTFILES_DIR"
        exit 1
    fi
    echo "Applying boxa's bundled dotfiles from $BUNDLED_DOTFILES_DIR..."
    "$CHEZMOI_BIN" apply --source "$BUNDLED_DOTFILES_DIR" --destination "$HOME" --force
    echo "Chezmoi setup complete (bundled)"
    exit 0
fi

# --- Remote chezmoi repo (user-provided URL) ---------------------------------
# Init only if not already initialized
if [ ! -d "$HOME/.local/share/chezmoi" ]; then
    echo "Initializing chezmoi from $CHEZMOI_REPO..."
    "$CHEZMOI_BIN" init "$CHEZMOI_REPO"
else
    echo "Chezmoi already initialized, updating source..."
    "$CHEZMOI_BIN" update --apply=false || true
fi

# Ignore files that are bind-mounted read-only from host
CHEZMOI_IGNORE="$HOME/.local/share/chezmoi/.chezmoiignore"
if ! grep -qxF ".config/git/ignore" "$CHEZMOI_IGNORE" 2>/dev/null; then
    echo ".config/git/ignore" >> "$CHEZMOI_IGNORE"
fi

# Always apply (idempotent)
echo "Applying chezmoi dotfiles..."
"$CHEZMOI_BIN" apply --force

echo "Chezmoi setup complete"
