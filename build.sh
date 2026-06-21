#!/bin/bash
set -euo pipefail

# =============================================================================
# Boxa — build script
# =============================================================================
# Run './build.sh --help' for usage information.
# =============================================================================

show_help() {
    cat <<'EOF'
Boxa — build script

Usage:
  ./build.sh                       Build image (uses cache)
  ./build.sh --no-cache            Full rebuild without cache
  ./build.sh --progress=plain      Show full build log
  ./build.sh --clean               Wipe build cache + dangling images, then rebuild
  ./build.sh --uninstall           Full reset without rebuild
  ./build.sh --uninstall --purge-ca
                                   Full reset AND remove mkcert root CA from
                                   system trust stores (WSL2 fires one UAC).

All other flags pass through to docker build.
Set BOXA_SUDO_PASSWORD env var for non-interactive builds.
To reclaim build cache space without rebuilding, use: boxa prune
EOF
    exit 0
}

case "${1:-}" in
    -h|--help) show_help ;;
esac

CLEAN=false
UNINSTALL=false
# 'auto' = prompt interactively (default n) or skip in non-interactive.
# 'yes'  = --purge-ca explicit; no prompt, fire UAC / sudo.
PURGE_CA=auto
DOCKER_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --clean)     CLEAN=true ;;
        --uninstall) UNINSTALL=true ;;
        --purge-ca)  PURGE_CA=yes ;;
        *)           DOCKER_ARGS+=("$arg") ;;
    esac
done

# Brand module — single source of truth for CLI_NAME and the derived image
# tag / container-name pattern. See lib/brand.sh and release issue #05.
BOXA_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/brand.sh
source "$BOXA_DIR/lib/brand.sh"

IMAGE="$BRAND_IMAGE"

# Boxa-managed container name pattern — both the dash-prefix user
# projects (`boxa-<project>`) and the two explicit underscore shared-infra
# names (`boxa_traefik`, `boxa_dns`, introduced by ADR 0007). The
# dash-prefix half can stay broad because `boxa::sanitize` is the only
# producer of those names; the underscore half must list the two infra
# names exactly so a hand-created Docker container that happens to start
# with `boxa_` (e.g. a personal `boxa_postgres`) is not caught and
# torn down. Keep this in sync with `BOXA_SHARED_CONTAINER_NAMES` in
# docker-run.sh.
BOXA_CONTAINER_PATTERN="$BRAND_CONTAINER_PATTERN"

# Prune build cache + dangling images. Does NOT touch running containers
# or volumes — the user keeps their work and existing per-project state
# across rebuilds.
prune_build_artifacts() {
    echo "Pruning all build cache..."
    docker builder prune --all -f 2>/dev/null || true

    echo "Pruning dangling images..."
    docker image prune -f 2>/dev/null || true

    echo ""
}

# Stop and remove every boxa-managed container. Only used by the
# uninstall path; `--clean` deliberately does not call this.
remove_all_boxa_containers() {
    CONTAINERS=$(docker ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -E "$BOXA_CONTAINER_PATTERN" || true)
    if [ -n "$CONTAINERS" ]; then
        echo "Stopping boxa containers..."
        while IFS= read -r c; do
            docker stop -t 15 "$c" > /dev/null 2>&1 || true
            docker rm "$c" > /dev/null 2>&1 || true
            echo "  Removed: $c"
        done <<< "$CONTAINERS"
    fi
}

# Wipe all boxa-* volumes. Destructive: kills per-project shell history,
# DinD storage, and shared caches (boxa-npm-global, etc.). Only used by
# the uninstall path; `--clean` deliberately does not call this.
remove_all_boxa_volumes() {
    VOLUMES=$(docker volume ls -q --filter "name=boxa-" 2>/dev/null || true)
    if [ -n "$VOLUMES" ]; then
        echo "Removing boxa volumes:"
        echo "$VOLUMES"
        # shellcheck disable=SC2086  # intentional word splitting — each volume name is a separate arg
        docker volume rm $VOLUMES || true
        # Verify deletion
        REMAINING=$(docker volume ls -q --filter "name=boxa-" 2>/dev/null || true)
        if [ -n "$REMAINING" ]; then
            echo "ERROR: Failed to remove volumes (containers still running?):"
            echo "$REMAINING"
            exit 1
        fi
        echo "All boxa volumes removed"
    else
        echo "No boxa volumes found"
    fi
}

# --- Uninstall: full reset without rebuild -----------------------------------

if [ "$UNINSTALL" = true ]; then
    echo "=== Uninstall: full reset ==="

    # Tear down the host-side DNS resolver wiring first. It lives outside
    # Docker (per-OS resolver drop-ins, Windows NRPT, ~/.config/boxa/dns.conf)
    # so the container / volume / image cleanup below wouldn't touch any of it.
    # May prompt for sudo and on WSL2 may pop a UAC dialog for the NRPT
    # rule — same expectations as `boxa dns-install`. `|| true` so a
    # UAC decline (or any partial failure) doesn't abort the rest of the
    # uninstall flow; users can re-run `boxa dns-uninstall` standalone.
    SCRIPT_PARENT="$(cd "$(dirname "$0")" && pwd)"
    if [ -x "$SCRIPT_PARENT/scripts/dns-install.sh" ]; then
        echo ""
        echo "Removing host DNS resolver configuration..."
        "$SCRIPT_PARENT/scripts/dns-install.sh" uninstall || true
    fi

    # CA purge is opt-in: mkcert is sometimes shared with non-boxa projects,
    # so we never strip the root CA from the user's trust stores without an
    # explicit signal. The trust-store removal fires a UAC prompt on WSL2 +
    # a sudo / Touch ID prompt on Linux / macOS, which is also why we keep
    # it strictly behind interactive confirmation when --purge-ca was not
    # passed: a surprise UAC popup during `boxa uninstall` would feel
    # broken even though it is correct cleanup.
    should_purge_ca=false
    case "$PURGE_CA" in
        yes)
            should_purge_ca=true
            ;;
        auto)
            # Only offer when there is something to purge — a missing
            # https.conf means the user never enabled HTTPS on this host,
            # so the question would be confusing.
            if [ -f "$HOME/.config/boxa/https.conf" ]; then
                if [ -t 0 ]; then
                    echo ""
                    echo "Remove mkcert root CA from system trust stores?"
                    echo "  This affects ALL mkcert-issued certs on this host, not just boxa."
                    echo "  Fires a UAC prompt on WSL2 (Windows side) or sudo / Touch ID on Linux / macOS."
                    printf "Purge CA? [y/N] "
                    read -r answer
                    case "$answer" in
                        y|Y) should_purge_ca=true ;;
                    esac
                else
                    echo ""
                    echo "Skipped CA purge (non-interactive). Re-run with --purge-ca to remove the mkcert root CA."
                fi
            fi
            ;;
    esac

    if [ "$should_purge_ca" = true ] \
        && [ -x "$SCRIPT_PARENT/scripts/dns-install.sh" ]; then
        echo ""
        echo "Purging mkcert root CA from trust stores..."
        "$SCRIPT_PARENT/scripts/dns-install.sh" purge-ca || true
    fi

    remove_all_boxa_containers
    remove_all_boxa_volumes
    prune_build_artifacts

    # Remove boxa image
    if docker images -q "$IMAGE" 2>/dev/null | grep -q .; then
        echo "Removing boxa image..."
        docker rmi "$IMAGE" 2>/dev/null || true
    fi

    # Remove traefik image
    if docker images -q "traefik" 2>/dev/null | grep -q .; then
        echo "Removing traefik image..."
        docker rmi traefik:v3 2>/dev/null || true
    fi

    # Remove devproxy network
    if docker network inspect devproxy >/dev/null 2>&1; then
        echo "Removing devproxy network..."
        docker network rm devproxy 2>/dev/null || true
    fi

    # Remove symlink
    if [ -L "/usr/local/bin/boxa" ]; then
        echo "Removing /usr/local/bin/boxa symlink..."
        sudo rm -f /usr/local/bin/boxa
    fi

    # Remove install directory (if installed via install.sh)
    INSTALL_DIR="$HOME/.local/share/boxa"
    if [ -d "$INSTALL_DIR" ]; then
        echo "Removing install directory: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi

    # Ask about config directory
    CONFIG_DIR="$HOME/.config/boxa"
    # Also check old location
    [ -d "$HOME/.boxa" ] && [ ! -d "$CONFIG_DIR" ] && CONFIG_DIR="$HOME/.boxa"
    if [ -d "$CONFIG_DIR" ]; then
        echo ""
        echo "Config directory found: $CONFIG_DIR"
        echo "  Contains: allowed-domains.conf, default-ports.conf, traefik configs"
        if [ -t 0 ]; then
            printf "Remove config directory? [y/N] "
            read -r answer
            if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
                rm -rf "$CONFIG_DIR"
                echo "Removed: $CONFIG_DIR"
            else
                echo "Kept: $CONFIG_DIR"
            fi
        else
            echo "  Skipped (non-interactive). Remove manually: rm -rf $CONFIG_DIR"
        fi
    fi

    # Ask about /var/log/boxa/ — owns allow-for harvest logs (ADR 0009)
    # and agent-browser session archives (ADR 0010). Root-owned, so removal
    # requires sudo. Kept opt-in because both kinds document past outbound
    # traffic from autonomous agents — some users will want to preserve
    # them across reinstalls (forensics, allowlist audit trail).
    BOXA_LOG_DIR="/var/log/boxa"
    if [ -d "$BOXA_LOG_DIR" ]; then
        # Per-subdir guards. Either subdir may be missing — a host that
        # only ever ran agent-browser won't have allow-for/, and vice
        # versa. Running `find` against a non-existent path exits 1; with
        # `set -euo pipefail` that would abort the whole uninstall before
        # the prompt.
        #
        # The agent-browser dir is also 0750 boxa-agent (ADR 0010), so
        # a shell without an active boxa-agent group membership (fresh
        # install before re-login or `newgrp`) cannot traverse it — find
        # exits non-zero even when the dir exists. The count is purely a
        # hint for the user; `sudo rm -rf` below clears the dir regardless
        # of whether we could enumerate it, so a failed count falls back
        # to "?" rather than aborting the whole uninstall.
        allow_for_count=0
        agent_browser_count=0
        if [ -d "$BOXA_LOG_DIR/allow-for" ]; then
            if ! allow_for_count=$(find "$BOXA_LOG_DIR/allow-for" -maxdepth 1 -type f -name '*.log' 2>/dev/null | wc -l); then
                allow_for_count="?"
            fi
        fi
        if [ -d "$BOXA_LOG_DIR/agent-browser" ]; then
            if ! agent_browser_count=$(find "$BOXA_LOG_DIR/agent-browser" -maxdepth 1 -type f \
                \( -name '*.netlog.json' -o -name '*.proxy.log' -o -name '*.summary.md' \) 2>/dev/null | wc -l); then
                agent_browser_count="?"
            fi
        fi
        echo ""
        echo "Boxa log directory found: $BOXA_LOG_DIR"
        # String compare so the "?" placeholder also prints — the user
        # should see we know the dir is non-empty even when we can't count.
        [ "$allow_for_count" != "0" ]     && echo "  Allow-for harvest logs:       $allow_for_count file(s)"
        [ "$agent_browser_count" != "0" ] && echo "  Agent-browser session files:  $agent_browser_count file(s)"
        if [ -t 0 ]; then
            printf "Remove boxa logs? [y/N] "
            read -r answer
            if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
                sudo rm -rf "$BOXA_LOG_DIR"
                echo "Removed: $BOXA_LOG_DIR"
            else
                echo "Kept: $BOXA_LOG_DIR"
            fi
        else
            echo "  Skipped (non-interactive). Remove manually: sudo rm -rf $BOXA_LOG_DIR"
        fi
    fi

    # Ask about the WSL2 toast notification AppId (ADR 0009). The HKCU key
    # itself is harmless if left behind — without the harvest-log dir it
    # simply never gets fired — but a thorough purge should sweep it.
    if grep -qi microsoft /proc/version 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; then
        # Cheap probe: Test-Path is one PowerShell round-trip (~200 ms).
        # Skip the whole block when the key isn't there to avoid prompting
        # the user about something that doesn't exist.
        if powershell.exe -NoProfile -Command \
            "if (Test-Path 'HKCU:\\Software\\Classes\\AppUserModelId\\Boxa.AllowFor') { exit 0 } else { exit 1 }" \
            >/dev/null 2>&1; then
            echo ""
            echo "Windows toast AppId found: HKCU\\...\\AppUserModelId\\Boxa.AllowFor"
            if [ -t 0 ]; then
                printf "Remove HKCU AppId? [y/N] "
                read -r answer
                if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
                    if powershell.exe -NoProfile -Command \
                        "Remove-Item -Path 'HKCU:\\Software\\Classes\\AppUserModelId\\Boxa.AllowFor' -Recurse -Force" \
                        >/dev/null 2>&1; then
                        echo "Removed: HKCU\\...\\AppUserModelId\\Boxa.AllowFor"
                    else
                        echo "WARN: Failed to remove HKCU AppId (check Windows event log)."
                    fi
                else
                    echo "Kept: HKCU\\...\\AppUserModelId\\Boxa.AllowFor"
                fi
            else
                echo "  Skipped (non-interactive). Remove manually via Windows PowerShell:"
                echo "    Remove-Item -Path 'HKCU:\\Software\\Classes\\AppUserModelId\\Boxa.AllowFor' -Recurse -Force"
            fi
        fi
    fi

    echo ""
    echo "=== Uninstall done ==="
    exit 0
fi

# --- Sudo password prompt ---------------------------------------------------
# Password is set at build time so sudo inside the container requires authentication.
# This prevents AI agents / untrusted code from modifying firewall rules via sudo.
# Passed via --mount=type=secret to avoid leaking into image layers/metadata.
SUDO_PASSWORD_FILE=$(mktemp)
trap 'rm -f "$SUDO_PASSWORD_FILE"' EXIT
if [ -t 0 ]; then
    read -s -r -p "Set sudo password for boxa: " SUDO_PASSWORD
    echo ""
    read -s -r -p "Confirm password: " SUDO_PASSWORD_CONFIRM
    echo ""
    if [ "$SUDO_PASSWORD" != "$SUDO_PASSWORD_CONFIRM" ]; then
        echo "ERROR: Passwords don't match"
        exit 1
    fi
    if [ -z "$SUDO_PASSWORD" ]; then
        echo "ERROR: Password cannot be empty"
        exit 1
    fi
else
    # Non-interactive: use env var or default
    SUDO_PASSWORD="${BOXA_SUDO_PASSWORD:-boxa}"
fi
printf '%s' "$SUDO_PASSWORD" > "$SUDO_PASSWORD_FILE"
unset SUDO_PASSWORD SUDO_PASSWORD_CONFIRM
DOCKER_ARGS+=(--secret "id=sudo_password,src=$SUDO_PASSWORD_FILE")
# Force cache invalidation — secret content alone doesn't bust Docker build cache
DOCKER_ARGS+=(--build-arg "SUDO_CACHE_BUST=$(date +%s)")

if [ "$CLEAN" = true ]; then
    echo "=== Clean: prune build cache + dangling images ==="
    prune_build_artifacts
fi

# Capture old image ID before build (for dangling cleanup)
OLD_IMAGE_ID=$(docker images -q "$IMAGE" 2>/dev/null || true)

echo "=== Building $IMAGE ==="
docker build -t "$IMAGE" "${DOCKER_ARGS[@]}" "$(dirname "$0")"

NEW_IMAGE_ID=$(docker images -q "$IMAGE" 2>/dev/null || true)

echo ""
echo "=== Cleanup ==="

# Remove old boxa image if it became dangling (replaced by new build)
if [ -n "$OLD_IMAGE_ID" ] && [ "$OLD_IMAGE_ID" != "$NEW_IMAGE_ID" ]; then
    echo "Removing old boxa image ($OLD_IMAGE_ID)..."
    docker rmi "$OLD_IMAGE_ID" 2>/dev/null || true
fi

# Remove any remaining dangling images from boxa builds
DANGLING=$(docker images -q --filter "dangling=true" 2>/dev/null || true)
if [ -n "$DANGLING" ]; then
    echo "Removing dangling images..."
    # shellcheck disable=SC2086  # intentional word splitting — each image ID is a separate arg
    docker rmi $DANGLING 2>/dev/null || true
fi


echo ""
echo "=== Done ==="
docker images "$IMAGE" --format "Image: {{.Repository}}:{{.Tag}}  Size: {{.Size}}  Created: {{.CreatedSince}}"
echo ""
echo "Build cache usage:"
docker system df --format '{{.Type}}\t{{.Size}} total, {{.Reclaimable}} reclaimable' 2>/dev/null | grep -i "build" || true

# Heads-up about containers running the OLD image. Each one keeps its
# pinned image ID until stopped & restarted, so the rebuild does not
# affect them automatically. We deliberately do not stop them here.
RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -E "$BOXA_CONTAINER_PATTERN" || true)
if [ -n "$RUNNING" ]; then
    echo ""
    echo "Note: the following boxa containers are still running the previous image."
    echo "      Stop and restart them to pick up the new build:"
    while IFS= read -r c; do
        echo "  - $c"
    done <<< "$RUNNING"
fi

echo ""
echo "Tip: run 'boxa build --clean' to wipe build cache + dangling images and rebuild"
echo "      run 'boxa uninstall' for full removal"
