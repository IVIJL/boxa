#!/bin/bash
set -euo pipefail
# =============================================================================
# One-time migration: move a pre-existing `devbox` install over to `boxa`.
#
# TEMPORARY SCRIPT — delete it once every existing install has migrated.
# A fresh `boxa` install never needs this; it exists only because the project
# was renamed devbox → boxa and a handful of existing installs carry state
# under the old name (docker objects, ~/.config, /var/log, OS users).
#
# What it does (data-preserving, idempotent):
#   1. Stops + removes every `devbox[-_]*` container. Project containers are
#      recreated from their volumes on the next `boxa <project>`; the shared
#      Traefik/dnsmasq infra is recreated by bootstrap. Containers hold no
#      durable state of their own (claude config is bind-mounted from the
#      host; project files live on the host bind mount).
#   2. Copies every `devbox[-_]*` volume into a `boxa[-_]*`-named volume
#      (`alpine cp -a`), then removes the old one. Mirrors the volume-copy
#      pattern the old naming migration used.
#   3. Merges the user config dir ~/.config/devbox into ~/.config/boxa
#      (entry-by-entry, keeping anything install.sh already wrote), and
#      rewrites carried-over Traefik routes + `connect` records to the new
#      `boxa-<project>` container names. Merging (not a plain rename) makes this
#      step order-independent: it works whether it runs before OR after
#      install.sh has seeded ~/.config/boxa.
#   4. Drops the stale /usr/local/bin/devbox symlink, completion files, the old
#      ~/.local/share/devbox checkout, and the orphaned `devbox` agent skill.
#   5. Re-renders MCP entries (devbox-* → boxa-*) when the boxa CLI is present.
#   6. Reports leftover state that is deliberately NOT auto-removed: the
#      `/var/log/devbox` dir (owned by the old `devbox-agent` UID — a rename
#      would leave it unreadable by the freshly-created `boxa-agent`), the
#      `devbox-agent` / `devbox-mcp` users, the `devbox-bridge` group, and the
#      old `vlcak/devbox:latest` image (your rollback). Fresh equivalents are
#      created by install.sh / `boxa doctor`; remove the old ones by hand.
#
# Run order for a migrating user (migrate + install order no longer matters —
# the config dir is merged either way):
#   curl -fsSL https://raw.githubusercontent.com/IVIJL/boxa/main/install.sh | bash -s -- --yes
#   ~/.local/share/boxa/scripts/migrate-from-devbox.sh
#   boxa build          # build the image (install does not)
#
# Usage:
#   migrate-from-devbox.sh            interactive (asks once, then runs)
#   migrate-from-devbox.sh --check    report what would change; mutate nothing
#   migrate-from-devbox.sh --auto     run without prompting
# =============================================================================

MODE="run"
case "${1:-}" in
    --check) MODE="check" ;;
    --auto)  MODE="auto" ;;
    "")      MODE="run" ;;
    *) echo "usage: $(basename "$0") [--check|--auto]" >&2; exit 2 ;;
esac

c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_cyn=$'\033[1;36m'; c_yel=$'\033[1;33m'; c_rst=$'\033[0m'
WARNINGS=()
warn() { WARNINGS+=("$1"); echo "${c_yel}WARN:${c_rst} $1" >&2; }
say()  { echo "${c_cyn}==>${c_rst} $1"; }
did()  { echo "  ${c_grn}✓${c_rst} $1"; }

# --- discovery (no mutation) -------------------------------------------------
# Match ONLY boxa-owned legacy objects — never a user's unrelated `devbox_*`:
#   - project objects use the dash prefix `devbox-<project>` (only
#     `devbox::sanitize` ever produced those names);
#   - the shared infra used EXACTLY two underscore names, `devbox_traefik` and
#     `devbox_dns` (ADR 0007 reserved the underscore namespace for infra).
# A personal `devbox_postgres` container/volume is therefore left untouched.
# Volumes only ever use the dash prefix (infra has no volumes).
mapfile -t OLD_CONTAINERS < <(docker ps -a --format '{{.Names}}' 2>/dev/null \
    | grep -E '^devbox-|^devbox_traefik$|^devbox_dns$' || true)
mapfile -t OLD_VOLUMES < <(docker volume ls --format '{{.Name}}' 2>/dev/null \
    | grep -E '^devbox-' || true)

OLD_CFG="$HOME/.config/devbox"; NEW_CFG="$HOME/.config/boxa"
OLD_LOG="/var/log/devbox"
OLD_SHARE="$HOME/.local/share/devbox"   # old CLI checkout (held install.sh)
# Orphaned `devbox` agent skill dir + the Claude/Codex symlinks that point at it.
OLD_SKILLS=()
for _sk in "$HOME/.agents/skills/devbox" "$HOME/.claude/skills/devbox" "$HOME/.codex/skills/devbox"; do
    if [ -e "$_sk" ] || [ -L "$_sk" ]; then OLD_SKILLS+=("$_sk"); fi
done

new_name() {
    # devbox-<x> → boxa-<x> ; devbox_<x> → boxa_<x>
    printf '%s' "$1" | sed -E 's/^devbox([-_])/boxa\1/'
}

# --- report ------------------------------------------------------------------
say "Scanning for a legacy 'devbox' install…"
echo "  containers : ${#OLD_CONTAINERS[@]}"
echo "  volumes    : ${#OLD_VOLUMES[@]}"
echo "  config dir : $([ -d "$OLD_CFG" ] && echo "$OLD_CFG" || echo 'none')"
echo "  log dir    : $([ -d "$OLD_LOG" ] && echo "$OLD_LOG" || echo 'none')"
echo "  install dir: $([ -d "$OLD_SHARE" ] && echo "$OLD_SHARE" || echo 'none')"
echo "  agent skill: ${#OLD_SKILLS[@]}"

nothing=1
[ "${#OLD_CONTAINERS[@]}" -gt 0 ] && nothing=0
[ "${#OLD_VOLUMES[@]}" -gt 0 ] && nothing=0
[ -d "$OLD_CFG" ] && nothing=0
[ -d "$OLD_LOG" ] && nothing=0
[ -d "$OLD_SHARE" ] && nothing=0
[ "${#OLD_SKILLS[@]}" -gt 0 ] && nothing=0
if [ "$nothing" = 1 ]; then
    say "${c_grn}Nothing to migrate — no legacy 'devbox' state found.${c_rst}"
    exit 0
fi

if [ "$MODE" = "check" ]; then
    echo
    say "Dry run (--check). The above would be migrated to 'boxa'. No changes made."
    exit 0
fi

if [ "$MODE" = "run" ]; then
    echo
    read -r -p "Migrate this devbox install to boxa now? [y/N] " ans || ans=""
    case "$ans" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 0 ;; esac
fi

# --- 1. stop + remove legacy containers --------------------------------------
if [ "${#OLD_CONTAINERS[@]}" -gt 0 ]; then
    say "Removing ${#OLD_CONTAINERS[@]} legacy container(s) (recreated under 'boxa' on next use)…"
    for c in "${OLD_CONTAINERS[@]}"; do
        if docker rm -f "$c" >/dev/null 2>&1; then
            did "removed container $c"
        else
            warn "could not remove container $c"
        fi
    done
fi

# --- 2. copy legacy volumes into boxa-named volumes --------------------------
if [ "${#OLD_VOLUMES[@]}" -gt 0 ]; then
    say "Migrating ${#OLD_VOLUMES[@]} volume(s) (data-copied, then old removed)…"
    for src in "${OLD_VOLUMES[@]}"; do
        dst="$(new_name "$src")"
        if docker volume inspect "$dst" >/dev/null 2>&1; then
            warn "target volume '$dst' already exists — leaving '$src' in place (resolve manually)"
            continue
        fi
        docker volume create "$dst" >/dev/null
        # No masking on the copy: `cp -a` must propagate a non-zero exit on any
        # read/space/permission failure so we DON'T remove the source after a
        # half-written copy (that would silently lose the user's data).
        if docker run --rm -v "$src":/from:ro -v "$dst":/to alpine \
                sh -c 'cp -a /from/. /to/'; then
            if docker volume rm "$src" >/dev/null 2>&1; then
                did "migrated volume $src → $dst"
            else
                warn "copied '$src' → '$dst' but could not remove old '$src'"
            fi
        else
            warn "data copy '$src' → '$dst' failed — source '$src' KEPT intact; resolve manually"
            docker volume rm "$dst" >/dev/null 2>&1 || true
        fi
    done
fi

# --- 3. user config dir (MERGE, order-independent) ---------------------------
# MERGE rather than refuse-on-exists: install.sh seeds ~/.config/boxa (writes
# dotfiles.conf + the agent-browser example) before the user might run this, so
# a plain `mv` would abort and silently skip the real config (certs, traefik
# routes, connect records, dns/https/mcp). Moving entry-by-entry — keeping any
# file the new dir already holds — makes this step work regardless of whether
# migrate runs before or after install, and never clobbers install's writes.
if [ -d "$OLD_CFG" ]; then
    mkdir -p "$NEW_CFG"
    merged=0
    shopt -s dotglob nullglob
    for entry in "$OLD_CFG"/*; do
        base="$(basename "$entry")"
        if [ -e "$NEW_CFG/$base" ]; then
            warn "kept existing $NEW_CFG/$base (not overwritten by devbox copy)"
        elif mv "$entry" "$NEW_CFG/$base"; then
            merged=1
        else
            warn "could not move $entry → $NEW_CFG/"
        fi
    done
    shopt -u dotglob nullglob
    [ "$merged" = 1 ] && did "merged $OLD_CFG → $NEW_CFG"
    # Drop the old dir only if everything moved out; otherwise leave the
    # kept-back remnants for the user to eyeball.
    if rmdir "$OLD_CFG" 2>/dev/null; then
        did "removed empty $OLD_CFG"
    else
        warn "$OLD_CFG still holds entries that already existed under $NEW_CFG — review + remove by hand"
    fi

    # The config dir carries Traefik route files named after the OLD container:
    # `devbox-<project>-<port>.yml` (+ `.pre-https-backup`). Left in place,
    # Boxa's Traefik would keep serving host rules that point at the now-removed
    # `devbox-<project>` containers. Drop them; `boxa <project>` regenerates
    # `boxa-...` routes on next start. The per-project `<project>-tls.yml` cert
    # config is keyed by project (no `devbox-` prefix) and stays valid, so it is
    # preserved.
    dyn="$NEW_CFG/traefik/dynamic"
    if [ -d "$dyn" ]; then
        shopt -s nullglob
        for rf in "$dyn"/devbox-*.yml "$dyn"/devbox-*.yml.pre-https-backup; do
            case "$rf" in *-tls.yml|*-tls.yml.pre-https-backup) continue ;; esac
            if rm -f "$rf"; then
                did "removed stale route $(basename "$rf")"
            else
                warn "could not remove stale route $rf"
            fi
        done
        shopt -u nullglob
    fi
    # Rewrite persisted `boxa connect` records. Each line in
    # connect/<source>.tsv is `alias\ttarget_container\tport\tlocal`; the
    # target_container column still names `devbox-<project>`, but the recreated
    # container is `boxa-<project>`. Without this rewrite start_boxa_connections
    # keeps pointing socat at the dead `devbox-*` hostname and persisted
    # forwards silently break.
    conn="$NEW_CFG/connect"
    if [ -d "$conn" ]; then
        shopt -s nullglob
        tab="$(printf '\t')"
        for tsv in "$conn"/*.tsv; do
            grep -q "${tab}devbox-" "$tsv" 2>/dev/null || continue
            tmp="${tsv}.tmp"
            if awk -F'\t' 'BEGIN{OFS=FS} $2 ~ /^devbox-/ { sub(/^devbox-/, "boxa-", $2) } { print }' \
                    "$tsv" > "$tmp" && mv "$tmp" "$tsv"; then
                did "rewrote connect targets in $(basename "$tsv")"
            else
                rm -f "$tmp"
                warn "could not rewrite connect record $tsv"
            fi
        done
        shopt -u nullglob
    fi
fi

# --- 4. stale CLI symlink + completions --------------------------------------
if [ -L /usr/local/bin/devbox ] || [ -e /usr/local/bin/devbox ]; then
    if sudo rm -f /usr/local/bin/devbox 2>/dev/null; then
        did "removed stale /usr/local/bin/devbox symlink"
    else
        warn "could not remove /usr/local/bin/devbox (remove by hand)"
    fi
fi
for comp in \
    /usr/share/zsh/site-functions/_devbox \
    /etc/bash_completion.d/devbox.bash \
    /usr/share/bash-completion/completions/devbox; do
    if [ -e "$comp" ]; then
        if sudo rm -f "$comp" 2>/dev/null; then
            did "removed stale completion $comp"
        else
            warn "could not remove $comp (remove by hand)"
        fi
    fi
done

# --- 4b. stale install dir + agent skill (orphaned by the rename) ------------
# The old CLI lived in ~/.local/share/devbox (a git checkout) and shipped a
# `devbox` agent skill into ~/.agents/skills with Claude/Codex symlinks.
# install.sh creates the boxa equivalents; these devbox copies carry no user
# data (config/volumes hold that).
#
# Removing the old checkout is GATED on `boxa` already being installed: when a
# user runs this from the legacy checkout BEFORE installing (the old
# git pull → migrate → install order), ~/.local/share/devbox may be the very
# tree holding the install.sh they still need — deleting it would strand them.
# Once `boxa` exists on PATH, install.sh has clearly run from its own source and
# the old checkout is a true orphan, safe to drop.
if [ -d "$OLD_SHARE" ]; then
    if command -v boxa >/dev/null 2>&1; then
        if rm -rf "$OLD_SHARE"; then
            did "removed stale $OLD_SHARE"
        else
            warn "could not remove $OLD_SHARE (remove by hand)"
        fi
    else
        warn "kept $OLD_SHARE for now (may hold the install.sh you still need) — remove it after install"
    fi
fi
# Skills are never an installer source, so drop them regardless of install state.
# (Guard the expansion: `"${arr[@]}"` on an empty array trips `set -u` on bash
# older than 4.4.)
if [ "${#OLD_SKILLS[@]}" -gt 0 ]; then
    for sk in "${OLD_SKILLS[@]}"; do
        if rm -rf "$sk"; then
            did "removed stale skill $sk"
        else
            warn "could not remove $sk (remove by hand)"
        fi
    done
fi

# --- 5. report leftover state (deliberately not auto-moved) ------------------
# State tied to the old devbox-agent UID is NOT migrated: moving
# /var/log/devbox would carry devbox-agent ownership/modes onto /var/log/boxa,
# which boxa-agent (a freshly-created, different UID) then could not read. A
# fresh boxa gets a clean /var/log/boxa with correct ownership via provisioning.
leftovers=()
[ -d "$OLD_LOG" ] && leftovers+=("$OLD_LOG (log/audit archives, owned by devbox-agent)")
id devbox-agent >/dev/null 2>&1 && leftovers+=("devbox-agent (user)")
id devbox-mcp   >/dev/null 2>&1 && leftovers+=("devbox-mcp (user)")
getent group devbox-bridge >/dev/null 2>&1 && leftovers+=("devbox-bridge (group)")
docker image inspect vlcak/devbox:latest >/dev/null 2>&1 \
    && leftovers+=("vlcak/devbox:latest image (~7GB, your rollback to devbox)")
if [ "${#leftovers[@]}" -gt 0 ]; then
    say "Leftover devbox state (left in place — install.sh / 'boxa doctor' create fresh equivalents):"
    for u in "${leftovers[@]}"; do echo "    - $u"; done
    echo "    Remove the old ones by hand once you're happy, e.g.:"
    echo "      sudo rm -rf $OLD_LOG"
    echo "      sudo userdel -r devbox-agent ; sudo userdel -r devbox-mcp ; sudo groupdel devbox-bridge"
    echo "      docker rmi vlcak/devbox:latest"
fi

# --- MCP re-render (only if an MCP profile exists) ---------------------------
# Rendered MCP entries live in the SHARED ~/.claude / ~/.codex agent configs,
# not under ~/.config, so moving the config dir cannot reach them. They still
# carry `devbox-*` entries that invoke the removed `devbox-mcp-run` wrapper; a
# render strips the legacy prefix (scripts/mcp/render.py is_managed_or_legacy)
# and rewrites them as `boxa-*`. Run it automatically when the `boxa` CLI is
# already installed (this script may run after install.sh); otherwise remind.
if [ -d "$NEW_CFG/mcp" ]; then
    if command -v boxa >/dev/null 2>&1; then
        say "Re-rendering MCP entries (devbox-* → boxa-*)…"
        if boxa mcp render >/dev/null 2>&1; then
            did "re-rendered managed MCP entries"
        else
            warn "boxa mcp render failed — run 'boxa mcp render' by hand once the CLI works"
        fi
    else
        say "MCP follow-up (required — you have an MCP profile):"
        echo "    Shared ~/.claude / ~/.codex configs still hold stale 'devbox-*'"
        echo "    MCP entries calling the removed 'devbox-mcp-run'. After install,"
        echo "    run:  boxa mcp render   (strips legacy, re-renders as boxa-*)."
    fi
fi

# --- next steps --------------------------------------------------------------
if command -v boxa >/dev/null 2>&1; then
    if docker image inspect ivijl/boxa:latest >/dev/null 2>&1; then
        say "Next: start a project →  cd <project> && boxa"
    else
        say "Next: build the image →  boxa build"
    fi
else
    say "Next: run ./install.sh (sets up the 'boxa' CLI), then  boxa build"
fi

# --- final verification ------------------------------------------------------
# Audit the auto-migrated state at a glance (the sudo/rollback leftovers above
# are reported separately by step 5).
say "Verification — auto-migrated state:"
vol_left=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -cE '^devbox-' || true)
ctr_left=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -cE '^devbox-|^devbox_traefik$|^devbox_dns$' || true)
ok() { echo "    ${c_grn}✓${c_rst} $1"; }
no() { echo "    ${c_yel}•${c_rst} $1"; }
if [ "$vol_left" -eq 0 ]; then ok "no devbox-* volumes left"; else no "$vol_left devbox-* volume(s) left"; fi
if [ "$ctr_left" -eq 0 ]; then ok "no devbox containers left"; else no "$ctr_left devbox container(s) left"; fi
if [ -e "$OLD_CFG" ]; then no "$OLD_CFG still present"; else ok "config dir merged into $NEW_CFG"; fi
if [ -e "$HOME/.local/share/devbox" ]; then no "old install dir (.local/share/devbox) left"; else ok "old install dir removed"; fi
if [ -L /usr/local/bin/devbox ] || [ -e /usr/local/bin/devbox ]; then no "/usr/local/bin/devbox symlink left"; else ok "CLI symlink removed"; fi

# --- summary -----------------------------------------------------------------
echo
if [ "${#WARNINGS[@]}" -eq 0 ]; then
    say "${c_grn}Migration complete.${c_rst}"
else
    say "${c_red}Migration finished with ${#WARNINGS[@]} warning(s):${c_rst}"
    for w in "${WARNINGS[@]}"; do echo "  ${c_yel}•${c_rst} $w"; done
    echo "  Resolve the above; everything else migrated."
fi
