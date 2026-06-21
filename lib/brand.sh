# shellcheck shell=bash
# =============================================================================
# Boxa brand — single source of truth for the product name and every
# runtime value derived from it (ADR 0005 family; release issue #05).
# =============================================================================
# Sourced by:
#   - docker-run.sh (host)        for IMAGE, the config dir, shared-infra names
#   - build.sh      (host)        for IMAGE and the container-name pattern
#   - install.sh    (host)        — see note below; the repo slug is needed
#                                   pre-clone so install keeps its own copy of
#                                   CLI_NAME but cross-checks against this file
#                                   once the repo is in place.
#
# WHY THIS FILE EXISTS
# --------------------
# The product name "boxa" is woven into ~180 files: image tags, ~/.config
# paths, /var/log paths, docker container/volume names, OS users, a bridge
# group, the GitHub repo slug, and the BOXA_* env-var prefix. A rename used
# to mean a coordinated edit across all of them. This file makes the name a
# single constant (`CLI_NAME`) plus a set of derived values, so the rename
# (release issue #06) becomes a one-line flip here plus a prose/filenames
# sweep — not a hunt through every script.
#
# HISTORY: issue #05 introduced this file with `CLI_NAME="devbox"` so every
# derived value expanded byte-for-byte to the literal it replaced. Issue #06
# then flipped `CLI_NAME` to "boxa" and swept the remaining inlined literals
# (fixed filenames, prose, help text). This file now owns the brand; the rest
# of the tree derives from it or was swept once.
# =============================================================================

# All constants are consumed by sourcing scripts; shellcheck can't see that.
# shellcheck disable=SC2034

# --- Sourcing guard ----------------------------------------------------------
[ -n "${_BOXA_BRAND_SH:-}" ] && return 0
_BOXA_BRAND_SH=1

# --- The brand ---------------------------------------------------------------
# The one thing a rename changes. Everything else derives from it.
CLI_NAME="boxa"

# Uppercased form, used as the env-var prefix (BOXA_*). Computed, not
# hand-typed, so it stays in lockstep with CLI_NAME.
CLI_NAME_UPPER="$(printf '%s' "$CLI_NAME" | tr '[:lower:]' '[:upper:]')"

# --- Image ------------------------------------------------------------------
# The image is built locally (no registry — local-first is a design goal) and
# tagged under a namespace kept as its own constant, so it can move
# independently of the CLI name. Aligned to the repo owner: `ivijl/boxa:latest`.
BRAND_IMAGE_NAMESPACE="ivijl"
BRAND_IMAGE_TAG="latest"
BRAND_IMAGE="${BRAND_IMAGE_NAMESPACE}/${CLI_NAME}:${BRAND_IMAGE_TAG}"

# --- Host config / log dirs --------------------------------------------------
# User config dir (XDG): ~/.config/<cli>. Callers append the leaf file.
BRAND_CONFIG_DIR_NAME="$CLI_NAME"
# System log dir for allow-for / agent-browser harvest logs (ADR 0009/0010).
BRAND_LOG_DIR="/var/log/${CLI_NAME}"

# --- Docker object names -----------------------------------------------------
# Per-project objects use the dash prefix (`<cli>-<project>`); shared infra
# uses an underscore separator so it can never collide with a sanitized
# project token (ADR 0007). Shared volumes follow the dash prefix.
BRAND_OBJECT_PREFIX="$CLI_NAME"                 # boxa-<project>, boxa-npm-global, …
BRAND_TRAEFIK_CONTAINER="${CLI_NAME}_traefik"   # boxa_traefik
BRAND_DNS_CONTAINER="${CLI_NAME}_dns"           # boxa_dns

# Container-name pattern matching every boxa-managed container: the broad
# dash-prefix half (only `boxa::sanitize` produces those) plus the two
# explicit underscore infra names. Mirrors BOXA_CONTAINER_PATTERN in
# build.sh and BOXA_SHARED_CONTAINER_NAMES in docker-run.sh.
BRAND_CONTAINER_PATTERN="^${BRAND_OBJECT_PREFIX}-|^${BRAND_TRAEFIK_CONTAINER}\$|^${BRAND_DNS_CONTAINER}\$"

# --- OS users / group (agent-browser, MCP broker) ----------------------------
BRAND_AGENT_USER="${CLI_NAME}-agent"     # Host agent Chrome runs as this user
BRAND_MCP_USER="${CLI_NAME}-mcp"         # MCP broker peer user
BRAND_BRIDGE_GROUP="${CLI_NAME}-bridge"  # shared bridge group

# --- Source repository -------------------------------------------------------
# GitHub owner/repo slug. install.sh needs this BEFORE the repo is cloned, so
# it cannot source this file for the bootstrap clone; it carries its own copy
# and is expected to match BRAND_REPO_SLUG once the checkout exists.
BRAND_REPO_OWNER="IVIJL"
BRAND_REPO_SLUG="${BRAND_REPO_OWNER}/${CLI_NAME}"
BRAND_REPO_URL="https://github.com/${BRAND_REPO_SLUG}.git"

# --- Default dotfiles starter (chezmoi) --------------------------------------
# The default dotfiles source offered during `install.sh` and used as the
# fallback CHEZMOI_REPO in docker-run.sh when the user has not chosen otherwise
# (release issues #09/#10). This is the `bundled` sentinel: boxa ships a curated
# chezmoi starter inside the image (Dockerfile COPYs `dotfiles/` →
# /usr/local/share/boxa/dotfiles) and setup-chezmoi.sh applies it locally with
# `chezmoi apply --source` — no network, no clone, no separate repo to trust
# (same local-first stance as ADR 0018). A user who picks their own chezmoi repo
# at install time gets a real URL here instead, which takes the remote path.
BRAND_DOTFILES_REPO="bundled"
