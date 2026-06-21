#!/bin/bash
set -euo pipefail
# Active migration: rewrite every per-project Traefik dynamic config that
# still routes through the HTTP `web` entrypoint into the websecure +
# `tls: {}` template produced by docker-run.sh::apply_port_routes. Used by
# `boxa update`'s Phase 6 HTTPS upgrade hook so a single update flips
# every running project to HTTPS without per-project restarts.
#
# Why active migration instead of warn-only (per feedback_active_migration_for_breakfix):
# the dead `web` routes keep working at HTTP — but the entrypoint-level
# redirect installed alongside `websecure` only fires once Traefik is
# restarted with the HTTPS flags, AND only when bootstrap_traefik tears
# down + recreates the Traefik container (the static config is baked in at
# create time). Leaving stale `web` routes in place after the user opted
# into HTTPS would have boxa advertise `https://...` URLs that 404 on
# the unrouted websecure entrypoint. Rewriting them in lock-step with the
# Traefik recreate avoids any visible regression window.
#
# Strategy: parse `<container>-<port>.yml` to recover the project + port,
# back the original file up to `<file>.pre-https-backup`, refresh the per-project cert via
# `ensure_project_cert`, then rewrite the route YAML in place using the
# same websecure template the live apply_port_routes uses.
#
# Idempotent: rerunning on an already-HTTPS config is a noop (the
# `entryPoints: web` literal is the only trigger).

CYAN=$'\033[1;36m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; NC=$'\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source-path=SCRIPTDIR source=../lib/naming.sh disable=SC1091
source "$BOXA_DIR/lib/naming.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/https.sh disable=SC1091
source "$BOXA_DIR/lib/https.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/mkcert.sh disable=SC1091
source "$BOXA_DIR/lib/mkcert.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/cert.sh disable=SC1091
source "$BOXA_DIR/lib/cert.sh"

TRAEFIK_CONFIG_DIR="${TRAEFIK_CONFIG_DIR:-$HOME/.config/boxa/traefik/dynamic}"

# WARNINGS=() collector — lib/cert.sh::_cert::_warn appends to this when
# present, matching the feedback_no_silent_failures contract used by
# scripts/dns-install.sh. The end-of-run summary is what tells the user
# whether per-project cert regeneration emitted any non-fatal warnings.
WARNINGS=()

usage() {
    cat <<USAGE
Usage: migrate-routes-to-https.sh [--check | --auto | --help]

  --check    Exit 0 iff at least one dynamic Traefik config still routes
             only through the HTTP \`web\` entrypoint. Used by 'boxa update'
             to decide whether to invoke the migration.
  --auto     Run the migration non-interactively (default).
  --help     Show this message.
USAGE
}

# Echo every per-project route file whose entryPoints list still contains
# `web` and does not contain `websecure`. The grep-then-grep dance keeps
# the trigger surface narrow: a route that already lists websecure (or one
# that's been hand-edited to dual-entry) is not touched.
list_http_routes() {
    [ -d "$TRAEFIK_CONFIG_DIR" ] || return 0
    local f
    for f in "$TRAEFIK_CONFIG_DIR"/*.yml; do
        [ -f "$f" ] || continue
        # Only per-project route files (boxa-<project>-<port>.yml).
        # Skip <project>-tls.yml fragments and any unrelated dynamic file.
        case "$(basename "$f")" in
            boxa-*-*.yml) ;;
            *) continue ;;
        esac
        # POSIX character classes only — macOS/BSD grep does not portably
        # recognize `\s` as a whitespace shorthand, so the WSL2-only `\s` form
        # would silently match nothing on a macOS host and skip the entire
        # migration on the supported platform Phase 6's done-criteria covers.
        if grep -qE '^[[:space:]]*-[[:space:]]*web[[:space:]]*$' "$f" \
            && ! grep -qE '^[[:space:]]*-[[:space:]]*websecure[[:space:]]*$' "$f"; then
            printf '%s\n' "$f"
        fi
    done
}

# Rewrite one route file in place. Keep the body byte-for-byte identical to
# docker-run.sh::apply_port_routes' websecure branch so the next live
# apply_port_routes call doesn't immediately overwrite what we just wrote
# with whitespace drift (which would wake Traefik's file watcher again).
rewrite_route() {
    local f="$1"
    local base port container project router_name host_rule sep="" host
    base="$(basename "$f" .yml)"
    port="${base##*-}"
    container="${base%-*}"
    project="${container#boxa-}"
    router_name="${container}-${port}"

    if [ -z "$port" ] || [ -z "$container" ] || [ "$container" = "$base" ]; then
        printf "  ${YELLOW}skip %s — filename does not match <container>-<port>.yml${NC}\n" "$f" >&2
        return 1
    fi

    # Backup BEFORE ensure_project_cert: if cert generation fails the route
    # file is still intact and the backup is a no-op-overwrite of the same
    # bytes. Doing it after would risk leaving the user with neither a
    # backup nor a rewritten file on cert failure.
    if ! cp "$f" "$f.pre-https-backup"; then
        printf "  ${RED}backup failed for %s — refusing to rewrite${NC}\n" "$f" >&2
        return 1
    fi

    if ! ensure_project_cert "$project"; then
        printf "  ${YELLOW}cert generation failed for %s — leaving HTTP route in place${NC}\n" "$project" >&2
        return 1
    fi

    host_rule=""
    while IFS= read -r host; do
        host_rule+="${sep}Host(\`${host}\`)"
        sep=" || "
    done < <(boxa::route_hosts "$project" "$port")

    cat > "$f" <<YAML
http:
  routers:
    ${router_name}:
      rule: "${host_rule}"
      entryPoints:
        - websecure
      tls: {}
      service: ${router_name}
  services:
    ${router_name}:
      loadBalancer:
        servers:
          - url: "http://${container}:${port}"
YAML
}

print_warnings() {
    [ "${#WARNINGS[@]}" -eq 0 ] && return 0
    echo
    printf "${RED}==> migrate-routes-to-https finished with %d warning(s):${NC}\n" "${#WARNINGS[@]}"
    local w
    for w in "${WARNINGS[@]}"; do
        printf "    ${YELLOW}- %s${NC}\n" "$w"
    done
}

main() {
    local mode="${1:-}"
    case "$mode" in
        --help|-h) usage; exit 0 ;;
        --check)
            [ -n "$(list_http_routes)" ] && exit 0
            exit 1
            ;;
        --auto|""|--run) ;;
        *)
            printf "${RED}Unknown flag: %s${NC}\n" "$mode" >&2
            usage >&2
            exit 2
            ;;
    esac

    local routes
    routes="$(list_http_routes)"
    if [ -z "$routes" ]; then
        printf '%sNo HTTP-only routes found. Nothing to migrate.%s\n' "$GREEN" "$NC"
        exit 0
    fi

    # Materialize the cert dir before counting. On a first-time HTTPS opt-in
    # with existing HTTP route files, $BOXA_CERTS_DIR usually does not
    # exist yet — `_cert::generate` creates it on demand later in the loop.
    # Under `set -euo pipefail` the pre-loop `find ... | wc -l` substitution
    # below would otherwise inherit `find`'s rc=1 (directory absent) and
    # abort the migration before any route was rewritten. mkdir is a noop
    # when the dir already exists.
    mkdir -p "$BOXA_CERTS_DIR"

    local migrated=0 failed=0 generated_before generated_after generated=0
    local migrated_files=()
    # Count cert files before so the end-summary can report how many new
    # certs the migration produced (vs. ones that already existed from a
    # prior partial run).
    generated_before="$(find "${BOXA_CERTS_DIR}" -maxdepth 1 -name '*.pem' 2>/dev/null | wc -l)"

    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if rewrite_route "$f"; then
            migrated=$((migrated + 1))
            migrated_files+=("$f")
        else
            failed=$((failed + 1))
        fi
    done <<< "$routes"

    generated_after="$(find "${BOXA_CERTS_DIR}" -maxdepth 1 -name '*.pem' 2>/dev/null | wc -l)"
    generated=$(( generated_after - generated_before ))
    [ "$generated" -lt 0 ] && generated=0

    # On partial failure restore every file we already rewrote, so the
    # caller's `active=false` rollback leaves the system in a coherent
    # HTTP-only state. Without this, those YAMLs would still bind to the
    # `websecure` entrypoint the still-HTTP Traefik does not have, and the
    # affected projects would 404 until the user manually copied each
    # .pre-https-backup back. Backups themselves are kept in place — same
    # behavior as a successful run; their contents now match the .yml on
    # disk byte-for-byte.
    if [ "$failed" -gt 0 ] && [ "${#migrated_files[@]}" -gt 0 ]; then
        local mf restored=0
        for mf in "${migrated_files[@]}"; do
            [ -f "$mf.pre-https-backup" ] || continue
            if cp "$mf.pre-https-backup" "$mf" 2>/dev/null; then
                restored=$((restored + 1))
            fi
        done
        printf '%sRestored %d already-migrated route(s) to HTTP from .pre-https-backup.%s\n' \
            "$YELLOW" "$restored" "$NC" >&2
    fi

    printf '\n%sMigrated %d route(s); %d new leaf cert(s) generated.%s\n' \
        "$GREEN" "$migrated" "$generated" "$NC"
    if [ "$failed" -gt 0 ]; then
        printf '%s%d route(s) FAILED to migrate — caller should roll back active=false.%s\n' \
            "$RED" "$failed" "$NC"
    fi
    printf '%sOriginal route files preserved as <name>.pre-https-backup alongside each rewritten file.%s\n' \
        "$CYAN" "$NC"
    print_warnings
    # Surface failures to the caller. `boxa update`'s HTTPS hook branches
    # on this rc to decide whether to recreate Traefik with HTTPS flags — a
    # silent exit-0 here would have it advertise HTTPS over routes that
    # still bind only to `web`, leaving those projects unreachable until
    # the next `boxa <project>` overwrites the file.
    [ "$failed" -eq 0 ]
}

main "$@"
