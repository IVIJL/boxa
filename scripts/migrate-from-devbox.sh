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
#   3. Renames the user config dir  ~/.config/devbox → ~/.config/boxa, and
#      rewrites carried-over Traefik routes + `connect` records to the new
#      `boxa-<project>` container names.
#   4. Drops the stale /usr/local/bin/devbox symlink and old completion files.
#   5. Reports leftover state that is deliberately NOT moved: the
#      `/var/log/devbox` dir (owned by the old `devbox-agent` UID — a rename
#      would leave it unreadable by the freshly-created `boxa-agent`) plus the
#      `devbox-agent` / `devbox-mcp` users and `devbox-bridge` group. Fresh
#      equivalents are created by `boxa update` (ADR 0017 provisioning); remove
#      the old ones by hand once you're happy.
#
# Run order for a migrating user:
#   git pull            # checkout now speaks `boxa`
#   ./scripts/migrate-from-devbox.sh
#   ./install.sh        # installs the `boxa` CLI + recreates host provisioning
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

nothing=1
[ "${#OLD_CONTAINERS[@]}" -gt 0 ] && nothing=0
[ "${#OLD_VOLUMES[@]}" -gt 0 ] && nothing=0
[ -d "$OLD_CFG" ] && nothing=0
[ -d "$OLD_LOG" ] && nothing=0
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

# --- 3. user config dir ------------------------------------------------------
if [ -d "$OLD_CFG" ]; then
    if [ -e "$NEW_CFG" ]; then
        warn "$NEW_CFG already exists — leaving $OLD_CFG in place (merge manually)"
    else
        mkdir -p "$(dirname "$NEW_CFG")"
        if mv "$OLD_CFG" "$NEW_CFG"; then
            did "moved $OLD_CFG → $NEW_CFG"
            # The config dir carries Traefik route files named after the OLD
            # container: `devbox-<project>-<port>.yml` (+ `.pre-https-backup`).
            # Left in place, Boxa's Traefik would keep serving host rules that
            # point at the now-removed `devbox-<project>` containers. Drop them;
            # `boxa <project>` regenerates `boxa-...` routes on next start. The
            # per-project `<project>-tls.yml` cert config is keyed by project
            # (no `devbox-` prefix) and stays valid, so it is preserved.
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
            # connect/<source>.tsv is `alias\ttarget_container\tport\tlocal`;
            # the target_container column still names `devbox-<project>`, but
            # the recreated container is `boxa-<project>`. Without this rewrite
            # start_boxa_connections keeps pointing socat at the dead
            # `devbox-*` hostname and persisted forwards silently break.
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
        else
            warn "could not move $OLD_CFG → $NEW_CFG"
        fi
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
if [ "${#leftovers[@]}" -gt 0 ]; then
    say "Leftover devbox state (left in place — boxa recreates fresh equivalents):"
    for u in "${leftovers[@]}"; do echo "    - $u"; done
    echo "    'boxa update' creates fresh boxa-agent / boxa-mcp / boxa-bridge + /var/log/boxa."
    echo "    Remove the old ones by hand once you're happy, e.g.:"
    echo "      sudo rm -rf $OLD_LOG"
    echo "      sudo userdel -r devbox-agent ; sudo userdel -r devbox-mcp ; sudo groupdel devbox-bridge"
fi

# --- MCP re-render reminder (only if MCP was ever used) ----------------------
# Rendered MCP entries live in the SHARED ~/.claude / ~/.codex agent configs,
# not under ~/.config, so moving the config dir cannot reach them. They still
# carry `devbox-*` entries that invoke the removed `devbox-mcp-run` wrapper. A
# render now strips the legacy prefix (scripts/mcp/render.py is_managed_or_legacy),
# so one re-render fixes them — but the user must trigger it.
if [ -d "$NEW_CFG/mcp" ]; then
    say "MCP follow-up (required — you have an MCP profile):"
    echo "    The shared ~/.claude / ~/.codex configs still hold stale 'devbox-*'"
    echo "    MCP entries that call the removed 'devbox-mcp-run'. After"
    echo "    ./install.sh, run inside a container:  boxa mcp render"
    echo "    It strips the legacy 'devbox-*' entries and re-renders them as"
    echo "    'boxa-*'. Until then those MCP servers stay broken."
fi

# --- summary -----------------------------------------------------------------
echo
if [ "${#WARNINGS[@]}" -eq 0 ]; then
    say "${c_grn}Migration complete.${c_rst} Next: run ./install.sh to set up the 'boxa' CLI."
else
    say "${c_red}Migration finished with ${#WARNINGS[@]} warning(s):${c_rst}"
    for w in "${WARNINGS[@]}"; do echo "  ${c_yel}•${c_rst} $w"; done
    echo "  Resolve the above, then run ./install.sh."
fi
