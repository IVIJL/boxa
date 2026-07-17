#!/bin/bash
# Sources below use runtime-resolved BOXA_DIR paths with source= annotations.
# shellcheck disable=SC1091
# Boxa uses bash 4+ features (mapfile, associative arrays). macOS ships
# bash 3.2, so transparently re-exec under a newer bash if one is installed
# (Homebrew), otherwise fail with an actionable message.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    for _newer_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [ -x "$_newer_bash" ]; then
            exec "$_newer_bash" "$0" "$@"
        fi
    done
    echo "boxa requires bash 4 or newer (this is bash ${BASH_VERSION})." >&2
    echo "On macOS, install a modern bash:  brew install bash" >&2
    exit 1
fi
set -euo pipefail

# =============================================================================
# Boxa — portable dev container with default-deny firewall
# =============================================================================
# Run 'boxa --help' for usage information.
# Install: sudo ln -s /path/to/boxa/docker-run.sh /usr/local/bin/boxa
# =============================================================================

show_help() {
    cat <<'EOF'
Boxa — portable dev container with default-deny firewall

Usage:

Containers:
  boxa [--ssh-config] [--memory SIZE] [--memory-swap SIZE] [path]
                                   Start/attach container for project
  boxa <name>                    Attach to running boxa-<name>
  boxa ls                        List running containers
  boxa mem [project|path]        Show per-project memory diagnostics
  boxa stop [name] [--clean]     Stop container (--clean removes volumes)
  boxa remove [name]             Remove project data (volumes)

Ports & connect:
  boxa port <port>               Expose port via Traefik
  boxa ports [--all] [--external]
                                   List active port routes
  boxa connect                   Pick source, targets, and services
  boxa connect <target> <port>   Forward one TCP port to another boxa
  boxa connections               List cross-boxa TCP forwards

Firewall:
  boxa allow [domain]            List or add allowed firewall domain
  boxa deny [domain]             Remove allowed domain (interactive)
  boxa blocked                   Show blocked DNS queries, allow interactively
  boxa allow-for [N] [name]      Open/status an Allow-for window
  boxa allow-for --stop [name]   Close the active window immediately

Agent-browser:
  boxa agent-browser <cmd> [args]
                                   Manage the Agent-browser command family

MCP:
  boxa mcp <cmd> [args]          Manage MCP servers for boxa Containers

DNS:
  boxa dns-install [--local|--external]
                                   Configure host resolver for *.test (per-OS)
  boxa dns-status                Show DNS mode + resolver state + verification
  boxa dns-uninstall             Remove host resolver config + dns.conf

Maintenance:
  boxa build [--no-cache|--clean|--progress=plain]
                                   Build/rebuild the boxa image
  boxa update                    Update boxa (pull repo + rebuild image)
  boxa doctor [--fix [step…]]    Check or repair host provisioning
  boxa prune [--all]             Remove old build cache (--all = everything)
  boxa uninstall [--purge-ca]    Remove everything (containers, volumes, image).
  boxa claude-token              Generate/regenerate Claude Code token
  boxa sync-skills               Sync host skills to all running containers

Editors & misc:
  boxa cursor [name]             Open Cursor attached to running boxa
  boxa code [name]               Open VS Code attached to running boxa
  boxa clip                      Grab clipboard image for container use
  boxa ssh-config [add|edit]     Manage boxa SSH config

Examples:
  boxa                           Mount CWD at host project path inside container
  boxa ~/projects/app            Mount specific project
  boxa port 3000                 Route 3000.<project>.test (and external fallback URL)
  boxa allow pypi.org            Allow pypi.org (and *.pypi.org) through firewall
  boxa cursor                    Open Cursor for CWD project

Run 'boxa <command> --help' for details.
EOF
    exit 0
}

show_command_help() {
    local command="${1:-}"

    case "$command" in
        agent-browser)
            cat <<'EOF'
Usage: boxa agent-browser <command> [args]

Manage the Agent-browser session for a boxa Container. The session launches
Host agent Chrome on the host and an in-Container CDP bridge. See ADR 0010.

Commands:
  start [--no-open] [project]             Start a session
  stop [project]                          Stop a session
  status [project]                        Show session status
  open [--project|-p NAME] <url> [...]    Open one or more URLs
  allow-for <N> [project]                 Open a network window for N minutes
  allow-for --stop [project]              Close the window immediately
  allow [domain]                          List or add an allowlist entry
  deny <domain>                           Remove an allowlist entry
  blocked [--project|-p NAME]             Pick denied hosts and allow them

The allow-for window puts the proxy in harvest mode and records a JSONL log.
Agent-browser allowlist entries match only the literal host, unlike boxa allow.
Quote a glob for subdomains (for example, '*.example.com'). Allow automatically
pairs apex and www hosts (qr.cz also adds www.qr.cz); deny removes both. Both
commands SIGHUP every live proxy.

blocked reads the last session's live or archived proxy log. It resolves an
explicit project, then the CWD basename, then offers a picker over live sessions
and Containers with archived logs.

Examples:
  boxa agent-browser start my-app
  boxa agent-browser open https://example.com
  boxa agent-browser allow '*.example.com'
  boxa agent-browser blocked -p my-app
EOF
            ;;
        mcp)
            "$BOXA_DIR/scripts/mcp-cli.sh" --help
            ;;
        allow-for)
            cat <<'EOF'
Usage:
  boxa allow-for [N] [project]
  boxa allow-for --stop [project]

Open an Allow-for window for N minutes (default 15) in one Container. Domains
outside the Allowlist are passively allowed and recorded. With no arguments,
show the CWD Container's status when a window is active; otherwise start a
15-minute window. Starting again resets the clock. See ADR 0009.

Examples:
  boxa allow-for 30
  boxa allow-for 30 my-app
  boxa allow-for --stop
EOF
            ;;
        allow)
            cat <<'EOF'
Usage: boxa allow [domain]

With no domain, list the firewall Allowlist. Otherwise add the domain; an entry
matches that domain and all of its subdomains.

Example:
  boxa allow pypi.org
EOF
            ;;
        mem)
            cat <<'EOF'
Usage: boxa mem [project|path]

Show one Project's configured Memory and Memory+swap limits, current Container
usage, remaining headroom, and recent OOM evidence. The target defaults to the
Project for the current directory. Process detail is best-effort where the
platform does not expose per-process cgroup attribution. See ADR 0020.

Examples:
  boxa mem
  boxa mem my-app
  boxa mem ~/projects/app
EOF
            ;;
        doctor)
            cat <<'EOF'
Usage: boxa doctor [--fix [step…]]

Check host provisioning regardless of repository state. The default run
silently repairs unconditional steps and reports skipped or declined elective
steps. --fix repairs every elective step, or only the named step ids. Run plain
boxa doctor to list the available ids. See ADR 0017.

Examples:
  boxa doctor
  boxa doctor --fix
  boxa doctor --fix mcp-onboarding
EOF
            ;;
        build)
            cat <<'EOF'
Usage: boxa build [--no-cache|--clean|--progress=plain]

Build or rebuild the boxa image. Builds use the cache by default.

Options:
  --no-cache        Perform a full rebuild without cache
  --clean           Wipe build cache and dangling images before rebuilding
  --progress=plain  Show the full build log

Examples:
  boxa build
  boxa build --no-cache
EOF
            ;;
        uninstall)
            cat <<'EOF'
Usage: boxa uninstall [--purge-ca]

Remove all boxa Containers, volumes, and the image. --purge-ca also removes the
mkcert root CA from system trust stores; on WSL2 this requires UAC approval.
EOF
            ;;
        ports)
            cat <<'EOF'
Usage: boxa ports [--all] [--external] [-m|--machine-readable]

List active port routes. By default, include only running Containers and ports
that are currently listening.

Options:
  --all       Include stopped Containers and skip the listening filter
  --external  Show the external sslip.io URL alongside the active URL
  -m, --machine-readable
              Emit tab-separated rows
              (container<TAB>port<TAB>url[<TAB>external]) without headers,
              separators, or column alignment

Example:
  boxa ports --all
EOF
            ;;
        connect)
            cat <<'EOF'
Usage:
  boxa connect
  boxa connect <target> <port> [local-port] [--from source]

With no arguments, pick a source, target boxaes, and published TCP services.
The explicit form forwards one TCP port from the source boxa to a target.
Inner Docker connects to the forward at 10.0.2.2:<local-port>.

Examples:
  boxa connect api 5432
  boxa connect db 5432 15432
  boxa connect api 5432 --from web
EOF
            ;;
        ls)             printf 'boxa ls                        List running containers\n' ;;
        stop)           printf 'boxa stop [name] [--clean]     Stop container (--clean removes volumes)\n' ;;
        remove)         printf 'boxa remove [name]             Remove project data (volumes)\n' ;;
        port)           printf 'boxa port <port>               Expose port via Traefik\n' ;;
        connections)    printf 'boxa connections               List cross-boxa TCP forwards\n' ;;
        deny)           printf 'boxa deny [domain]             Remove allowed domain (interactive)\n' ;;
        blocked)        printf 'boxa blocked                   Show blocked DNS queries, allow interactively\n' ;;
        dns-install)    printf 'boxa dns-install [--local|--external]\n                                   Configure host resolver for *.test (per-OS)\n' ;;
        dns-status)     printf 'boxa dns-status                Show DNS mode + resolver state + verification\n' ;;
        dns-uninstall)  printf 'boxa dns-uninstall             Remove host resolver config + dns.conf\n' ;;
        update)         printf 'boxa update                    Update boxa (pull repo + rebuild image)\n' ;;
        prune)          printf 'boxa prune [--all]             Remove old build cache (--all = everything)\n' ;;
        claude-token)   printf 'boxa claude-token              Generate/regenerate Claude Code token\n' ;;
        sync-skills)    printf 'boxa sync-skills               Sync host skills to all running containers\n' ;;
        cursor)         printf 'boxa cursor [name]             Open Cursor attached to running boxa\n' ;;
        code)           printf 'boxa code [name]               Open VS Code attached to running boxa\n' ;;
        clip)           printf 'boxa clip                      Grab clipboard image for container use\n' ;;
        ssh-config)     printf 'boxa ssh-config [add|edit]     Manage boxa SSH config\n' ;;
        '')
            show_help
            ;;
        *)
            printf "Unknown boxa command: %s\nRun 'boxa help' for the command overview.\n" "$command" >&2
            exit 2
            ;;
    esac

    case "$command" in
        agent-browser|mcp|allow-for|allow|mem|doctor|build|uninstall|ports|connect) ;;
        *) printf "\nRun 'boxa <command> --help' for details.\n" ;;
    esac
    exit 0
}

SSH_WARNING=""
BOXA_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Brand module — single source of truth for CLI_NAME and the values derived
# from it (image tag, shared-infra container names, …). Sourced first so the
# derived assignments below read from it; a rename touches lib/brand.sh only.
# See lib/brand.sh and release issue #05.
# shellcheck source=lib/brand.sh
source "$BOXA_DIR/lib/brand.sh"

IMAGE="$BRAND_IMAGE"
TRAEFIK_CONFIG_DIR="$HOME/.config/$CLI_NAME/traefik/dynamic"
CONNECT_CONFIG_DIR="$HOME/.config/$CLI_NAME/connect"
DNS_CONFIG_DIR="$HOME/.config/$CLI_NAME/dns"

# Container names that belong to shared boxa infrastructure, not to any
# user project. Enumeration / cleanup sites filter these out via
# `filter_user_containers` so per-project loops never accidentally stop or
# tear down the shared proxy / resolver.
#
# Naming convention: shared infra uses an UNDERSCORE separator
# (`boxa_traefik`, `boxa_dns`) — `boxa::sanitize` converts `_` to
# `-`, so no user project token can ever produce these names, making the
# project / infra namespaces provably disjoint (see ADR 0007).
BOXA_SHARED_CONTAINER_NAMES=(
    "$BRAND_TRAEFIK_CONTAINER"
    "$BRAND_DNS_CONTAINER"
)

# Allowlist module — defines ALLOWLIST_HOST_FILE, IPSET_NAME, allowlist::* fns
# shellcheck source=lib/allowlist.sh
source "$BOXA_DIR/lib/allowlist.sh"

# Naming module — owns the format of container names, volumes, hostname,
# workspace alias and traefik route hosts. See lib/naming.sh and
# docs/adr/0005-project-naming-from-sanitized-basename.md.
# shellcheck source=lib/naming.sh
source "$BOXA_DIR/lib/naming.sh"

# Per-project Memory and Memory+swap limit resolution (ADR 0020).
# shellcheck source=lib/resources.sh
source "$BOXA_DIR/lib/resources.sh"

# Per-project Memory autopsy: cgroup live data, inspect post-mortem state,
# project-aggregate RSS, OOM archives, and concrete recovery commands.
# shellcheck source=lib/mem-report.sh
source "$BOXA_DIR/lib/mem-report.sh"

# Picker module — single + multi interactive selection with consistent UX
# across fzf and the no-fzf fallback. See lib/picker.sh and
# docs/adr/0006-interactive-picker-conventions.md.
# shellcheck source=lib/picker.sh
source "$BOXA_DIR/lib/picker.sh"

# HTTPS state + cert lifecycle modules. Sourced unconditionally — every entry
# point that touches cert files gates on `boxa::https_active`, which is
# false until the user opts in via dns-install --enable-https (Phase 6). See
# lib/https.sh, lib/mkcert.sh, lib/cert.sh and docs/adr/0008.
# shellcheck source=lib/https.sh
source "$BOXA_DIR/lib/https.sh"
# shellcheck source=lib/mkcert.sh
source "$BOXA_DIR/lib/mkcert.sh"
# shellcheck source=lib/cert.sh
source "$BOXA_DIR/lib/cert.sh"

# --- Helper functions --------------------------------------------------------

# Percent-encode a filesystem path for embedding in a URI path component.
# RFC 3986 unreserved chars and `/` pass through; everything else is
# %-encoded. Needed because host project paths can contain spaces or
# diacritics (e.g. ~/Code/My App) that would otherwise produce an invalid
# folder URI for vscode-remote://.
url_encode_path() {
    local LC_ALL=C s="$1" out="" c
    local -i i
    for ((i=0; i<${#s}; i++)); do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9._~/-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

set_tab_title() {
    # shellcheck disable=SC1003 # literal backslash for OSC escape terminator
    printf '\033]0;%s\033\\' "$1"
}

# Portable fire-and-forget background launcher. setsid + nohup gives a
# bulletproof detach on Linux (new session + SIGHUP ignored); macOS BSD
# coreutils lacks `setsid`, so degrade to plain `nohup`. Both survive
# parent shell exit — the new-session isolation that only setsid provides
# isn't needed for the helper jobs we launch here (they don't read tty
# and don't fork further job-control trees).
#
# Stdin/stdout/stderr are detached so the child can't tail-pipe noise
# into the user's terminal even if it crashes early.
detach_bg() {
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$@" </dev/null >/dev/null 2>&1 &
    else
        nohup "$@" </dev/null >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
}

# Filter a stream of `docker ps` output (one container per line, optional
# tab-separated extra fields) down to user-owned boxa containers. Drops
# BOXA_SHARED_CONTAINER_NAMES entries. awk-based so empty result still
# exits 0 (unlike `grep -v` which needs trailing `|| true`).
filter_user_containers() {
    awk -F '\t' -v shared="${BOXA_SHARED_CONTAINER_NAMES[*]}" '
        BEGIN {
            n = split(shared, arr, " ")
            for (i = 1; i <= n; i++) excl[arr[i]] = 1
        }
        !($1 in excl)
    '
}

# Probe TCP listeners that would clash with our `-p 127.0.0.1:<port>:<port>`
# publish for Traefik. The conflict set is narrow:
#   - 127.0.0.1:<port>           direct overlap with our IPv4 bind.
#   - 0.0.0.0:<port> / *:<port>  IPv4 wildcard, also serves 127.0.0.1.
#   - [::]:<port>                IPv6 wildcard; with IPV6_V6ONLY=0 it also
#                                claims the IPv4 wildcard. We can't see
#                                the V6ONLY flag from a probe, so we
#                                flag it conservatively — false-positive
#                                aborts beat docker's nameless bind error.
# Listeners on other addresses coexist with our bind and are ignored:
#   - 127.0.0.2:<port> (or any other 127.x alias)
#   - [::1]:<port>               pure IPv6 loopback, distinct address
#                                family from 127.0.0.1.
#   - any non-loopback interface address (192.168.x.x:<port>, etc.).
#
# When held, echoes a single descriptive line (`pid <N> (<comm>)`
# when ss/lsof can see the owner; a "needs root to inspect" hint
# otherwise) and returns 0. When free, prints nothing and returns 1.
# Mirrors the predicate shape of _dns::port_53_held_by_other in
# scripts/dns-install.sh.
#
# Usage: _boxa::port_held_by_other <port>
_boxa::port_held_by_other() {
    local port="$1"
    local listeners=""
    if command -v ss >/dev/null 2>&1; then
        # ss -p surfaces `users:(("name",pid=N,fd=M))` when this process
        # (or root) can read the owning task; column is empty otherwise.
        # awk's dynamic-regex form double-escapes backslashes: `\\.` in the
        # literal collapses to `\.` for the regex engine.
        listeners="$(ss -lntp 2>/dev/null \
            | awk -v port="$port" 'NR>1 && $4 ~ "(^127\\.0\\.0\\.1|^0\\.0\\.0\\.0|^\\*|^\\[::\\]):"port"$"')"
    elif command -v lsof >/dev/null 2>&1; then
        # lsof NAME column always has the form `<addr>:<port> (LISTEN)`;
        # match the conflict-set addresses explicitly so a service bound
        # to e.g. 192.168.x.x:<port> or [::1]:<port> doesn't block startup.
        # This matters most on macOS, where ss is absent and lsof is the path.
        listeners="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null \
            | awk -v port="$port" 'NR>1 && $0 ~ " (127\\.0\\.0\\.1|0\\.0\\.0\\.0|\\*|\\[::\\]):"port" \\(LISTEN\\)$"')"
    else
        # No probe tool available — we cannot prove a conflict, so let
        # docker run surface the bind error in its own words.
        return 1
    fi
    [ -n "$listeners" ] || return 1

    local desc=""
    if command -v ss >/dev/null 2>&1; then
        desc="$(printf '%s\n' "$listeners" \
            | grep -oE 'users:\(\("[^"]+",pid=[0-9]+' \
            | sed -E 's/users:\(\("([^"]+)",pid=([0-9]+)/pid \2 (\1)/' \
            | head -1)"
    else
        desc="$(printf '%s\n' "$listeners" | awk 'NR==1 {printf "pid %s (%s)", $2, $1}')"
    fi
    [ -z "$desc" ] && desc="(listener present; rerun with sudo to see PID)"
    printf '%s\n' "$desc"
    return 0
}

# Tell whether the existing boxa_traefik container was started in HTTPS
# mode. We look for the websecure entrypoint flag in `docker inspect` because
# the container's `docker run` args are the single source of truth: bind
# mounts and port publishes are fixed at create time, so the flag's presence
# in `.Config.Cmd` cleanly distinguishes a HTTP-only container from an
# HTTPS-capable one regardless of run/exited state.
# Returns 0 (HTTPS) when the flag is set, 1 (HTTP-only or no container).
_boxa::traefik_has_https() {
    docker inspect boxa_traefik 2>/dev/null \
        | grep -q -- '--entrypoints.websecure.address=:443'
}

# Effective URL scheme to advertise to the user — `https` only when both the
# persisted `https_active` opt-in is on AND the running boxa_traefik was
# actually started with the `websecure` entrypoint. Combining both checks
# closes the degraded-HTTPS hole: bootstrap_traefik can downgrade to HTTP-only
# when 127.0.0.1:443 is held at startup, and apply_port_routes then writes
# `web` routers via the same _boxa::traefik_has_https gate — so displayed
# URLs must follow the running mode, not the persisted wish, or every printed
# `https://` URL would 404. Returns the bare scheme (no `://`) so URL shape
# stays explicit at the call site.
boxa::url_scheme() {
    if boxa::https_active && _boxa::traefik_has_https; then
        printf '%s' 'https'
    else
        printf '%s' 'http'
    fi
}

bootstrap_traefik() {
    docker network inspect devproxy >/dev/null 2>&1 || docker network create devproxy

    mkdir -p "$TRAEFIK_CONFIG_DIR"
    seed_allowed_domains
    seed_default_ports

    # Reconcile a degraded HTTPS start. When `https_active` is on but the
    # existing boxa_traefik was created HTTP-only (a previous run hit a
    # transient 127.0.0.1:443 squatter and downgraded), recreate it as soon
    # as port 443 is free again — otherwise the WARN's promise that "freeing
    # 443 and re-running enables HTTPS" would silently fail forever, because
    # neither the restart-if-exited branch nor the run-if-missing branch
    # below ever touches a present container. We only flip the HTTP → HTTPS
    # direction; HTTPS → HTTP belongs to Phase 6's active migration once the
    # user explicitly opts out via dns-install --disable-https.
    if docker ps -a --filter "name=^boxa_traefik$" --format '{{.ID}}' | grep -q .; then
        if boxa::https_active \
            && ! _boxa::traefik_has_https \
            && ! _boxa::port_held_by_other 443 >/dev/null; then
            echo "Recreating Traefik to enable HTTPS (127.0.0.1:443 is now free)..."
            docker stop boxa_traefik >/dev/null 2>&1 || true
            docker rm boxa_traefik >/dev/null
        fi
    fi

    # If traefik exists but is exited, restart it. The container's docker run
    # args are baked in at create time, so a flip in `https_active` since the
    # previous start is not picked up here — that path is owned by Phase 6's
    # active migration (stop + remove + start). The reconcile block above
    # already handles the one Phase-4 case where the persistent intent is
    # HTTPS but the running container is HTTP-only.
    if docker ps -a --filter "name=^boxa_traefik$" --filter "status=exited" --format '{{.ID}}' | grep -q .; then
        echo "Restarting Traefik proxy..."
        docker start boxa_traefik
        return
    fi

    if ! docker ps --format '{{.Names}}' | grep -qx boxa_traefik; then
        # Pre-flight: docker run -p 127.0.0.1:80:80 would fail with
        # "bind: address already in use" but never names the offender.
        # Probe first so we can fail loud with PID + comm — the user can
        # stop the process or remap its port in a single step.
        local owner
        if owner="$(_boxa::port_held_by_other 80)"; then
            echo -e "\033[1;31m==> Cannot start Traefik: 127.0.0.1:80 is occupied by ${owner}\033[0m" >&2
            echo "    Stop that process (or remap its port) and re-run." >&2
            exit 1
        fi

        # Resolve the effective HTTPS mode for this `docker run`. We branch
        # off `boxa::https_active` (the persisted opt-in) but downgrade to
        # off when 127.0.0.1:443 is already taken: serving HTTP-only is
        # strictly better than aborting the whole boxa start. The persisted
        # https.conf is left alone — a transient port-443 squatter must not
        # silently flip the user's preference.
        local https_mode="off"
        if boxa::https_active; then
            local owner443
            if owner443="$(_boxa::port_held_by_other 443)"; then
                echo -e "\033[1;33mWARN: HTTPS disabled for this Traefik start — 127.0.0.1:443 is occupied by ${owner443}.\033[0m" >&2
                echo "      Free port 443 and re-run to enable HTTPS; HTTP-only routing continues meanwhile." >&2
            else
                https_mode="on"
            fi
        fi

        echo "Starting Traefik proxy..."

        # Build the publish, mount, and Traefik flag sets as arrays so the
        # HTTPS branch is a single additive block instead of duplicated
        # docker-run invocations.
        local -a publish_args=(
            -p 127.0.0.1:80:80
        )
        local -a mount_args=(
            -v /var/run/docker.sock:/var/run/docker.sock:ro
            -v "$TRAEFIK_CONFIG_DIR:/etc/traefik/dynamic:ro"
        )
        local -a traefik_args=(
            --providers.docker=true
            --providers.docker.exposedbydefault=false
            --providers.docker.network=devproxy
            --providers.file.directory=/etc/traefik/dynamic
            --providers.file.watch=true
            --entrypoints.web.address=:80
        )

        if [ "$https_mode" = "on" ]; then
            # Ensure the certs dir exists before docker bind-mounts it,
            # otherwise the daemon would create it as root-owned and
            # subsequent host-side cert writes by ensure_project_cert
            # (running as the user) would fail.
            mkdir -p "$BOXA_CERTS_DIR"
            publish_args+=(-p 127.0.0.1:443:443)
            mount_args+=(-v "$BOXA_CERTS_DIR:$BOXA_CERT_CONTAINER_PATH:ro")
            # Permanent 301 from web → websecure happens at the entrypoint
            # level, before any router rule evaluates, so every HTTP request
            # to any host gets redirected. The websecure entrypoint serves
            # the per-project leaf certs picked up via the file provider's
            # <project>-tls.yml fragments written by _cert::write_tls_yml.
            traefik_args+=(
                --entrypoints.websecure.address=:443
                --entrypoints.web.http.redirections.entrypoint.to=websecure
                --entrypoints.web.http.redirections.entrypoint.scheme=https
                --entrypoints.web.http.redirections.entrypoint.permanent=true
            )
        fi

        docker run -d --name boxa_traefik --restart unless-stopped \
            --network devproxy \
            "${publish_args[@]}" \
            "${mount_args[@]}" \
            traefik:v3 \
            "${traefik_args[@]}"
    fi
}

seed_allowed_domains() {
    allowlist::ensure_seeded "$ALLOWLIST_HOST_FILE" "$BOXA_DIR/config/default-allowlist.conf"
}

# Keep ~/.config/boxa/dns/boxa.conf bit-for-bit identical to the
# baked-in template at $BOXA_DIR/config/dns/boxa.conf. Two scenarios
# are handled here, both transparent to the user:
#
#   1. Missing file        → seed from template (first run).
#   2. Template drifted    → in-place rewrite + restart boxa_dns if it
#                            is running, so dnsmasq picks up the new
#                            config. SIGHUP is NOT enough — dnsmasq's
#                            documented SIGHUP semantics explicitly skip
#                            re-reading the config file.
#
# The rewrite path uses `cat > "$runtime"` (not `rm + cp`) so the file's
# inode stays the same. Docker Desktop snapshots bind-mounted files
# under /run/desktop/mnt/host/...; an unlink-then-create cycle invalidates
# the snapshot, and the next `docker restart boxa_dns` then fails with
# "mount src ... no such file or directory" — observed during the
# listen-address fix rollout.
#
# Custom user edits to the runtime file are NOT preserved: this is
# internal boxa plumbing and the template owns the canonical config.
# Per-host dnsmasq tweaks should patch config/dns/boxa.conf in the
# repo (which then ships through this mechanism to every install).
ensure_dns_runtime_config() {
    local template="$BOXA_DIR/config/dns/boxa.conf"
    local runtime="$DNS_CONFIG_DIR/boxa.conf"
    mkdir -p "$DNS_CONFIG_DIR"

    if [ ! -f "$runtime" ]; then
        cat "$template" > "$runtime"
        return 0
    fi

    if cmp -s "$template" "$runtime"; then
        return 0
    fi

    echo "Refreshing boxa_dns config from updated template..."
    cat "$template" > "$runtime"
    if docker ps --format '{{.Names}}' | grep -qx boxa_dns; then
        docker restart boxa_dns >/dev/null
    fi
}

# Restore ~/.config/boxa/dns.conf when the meta config has gone missing
# but a previous local-mode install left state behind. boxa_dns is only
# ever created by bootstrap_dns in local mode (external mode skips the
# container entirely), so its presence — running or stopped — is a safe
# tell that the user was on local mode before the file vanished.
#
# Does NOT auto-invoke `boxa dns-install`: that path writes host
# resolver files and prompts for sudo / UAC, neither of which belongs
# mid-`boxa <project>` invocation. Active repair of a missing host
# resolver drop-in lives in the `boxa update` flow instead, where the
# user has already opted into an interactive session — see
# `_boxa::resolver_drop_in_missing` and its call site.
ensure_dns_meta_config() {
    local conf="$HOME/.config/boxa/dns.conf"
    [ -f "$conf" ] && return 0
    docker ps -a --filter "name=^boxa_dns$" --format '{{.ID}}' | grep -q . || return 0

    mkdir -p "$(dirname "$conf")"
    cat > "$conf" <<EOF
# Restored after dns.conf went missing — boxa inferred local mode from
# the existing boxa_dns container. Re-run 'boxa dns-install' if you
# need host resolver setup or want a different mode.
preferred=local
active_domain=$BOXA_LOCAL_TLD
external_provider=sslip.io
EOF
    boxa::reset_dns_cache
    echo "Restored ~/.config/boxa/dns.conf (inferred local mode from boxa_dns container)."
}

# Soft-broken state detector for the host DNS resolver: dns.conf is present
# (so the user already ran `boxa dns-install` at some point) but the
# per-platform resolver drop-in is gone — wiped by an OS upgrade, a system
# reinstall, or a stray `dns-install uninstall`. In this state the resolver
# container still runs and external (sslip.io) URLs still work, but the
# browser cannot resolve `*.test`, and `bootstrap_dns`'s self-heal can't
# repair it without prompting for sudo mid-`boxa <project>`. The fix lives
# in the `boxa update` flow, which is already interactive.
#
# Also fires for the degraded state a failed `dns-install --auto` leaves
# behind (preferred=local + external active_domain): there the install never
# completed, so the retry is short-circuited in before the platform probes —
# crucially so WSL2 NRPT-only degraded installs aren't missed by the Linux
# drop-in checks below.
#
# Returns 0 when self-heal is needed, 1 otherwise. The predicate keys off
# *the live runtime* rather than `_dns::detect_platform`: we check for the
# drop-in path that the *currently running* host resolver would consume.
# That diverges from `_dns::detect_platform` for one case — WSL2 distros
# without systemd-resolved active. There `_dns::install_wsl2` deliberately
# only installs the Windows NRPT rule (NRPT-only is a supported partial
# setup) and never creates `/etc/systemd/resolved.conf.d/boxa.conf`, so
# mirroring the platform string would loop us into an idempotent repair
# that re-fires the UAC prompt every update without ever satisfying the
# check. Probing NRPT itself costs a PowerShell round-trip per invocation;
# we leave that verification to `boxa dns-status`.
_boxa::resolver_drop_in_missing() {
    [ -f "$HOME/.config/boxa/dns.conf" ] || return 1

    local domain preferred
    domain="$(boxa::route_domain)"
    preferred="$(boxa::dns_preferred)"

    # Pure external-mode users (preferred=external) deliberately have no host
    # drop-in and must be skipped, or we'd force-flip them to local:
    # `dns-install --auto` defaults to local-first.
    if [ "$domain" != "$BOXA_LOCAL_TLD" ] && [ "$preferred" != "local" ]; then
        return 1
    fi

    # Degraded state: preferred=local but advertising the external fallback
    # because a prior resolver setup FAILED. Nothing landed on disk on ANY
    # platform — and on a WSL2 NRPT-only setup the Linux drop-in checks below
    # would wrongly report "nothing missing" and skip the retry the degraded
    # banner promised. Flag it for self-heal here, before any platform probe.
    if [ "$domain" != "$BOXA_LOCAL_TLD" ]; then
        return 0
    fi

    # Normal local mode (active_domain=test): verify the platform-specific
    # drop-in the *currently running* host resolver consumes is actually
    # present. (NRPT-only WSL2 has no Linux drop-in by design — see the header
    # note — so it falls through to `return 1`; that path is a successful
    # install, not a degraded one, and is left to `boxa dns-status` to verify.)
    local uname_s
    uname_s="$(uname -s 2>/dev/null || echo Unknown)"
    case "$uname_s" in
        Darwin)
            [ ! -f "/etc/resolver/$BOXA_LOCAL_TLD" ]
            return $?
            ;;
        Linux) ;;
        *) return 1 ;;
    esac
    if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        [ ! -f "/etc/systemd/resolved.conf.d/boxa.conf" ]
        return $?
    fi
    if grep -hE '^[[:space:]]*dns[[:space:]]*=' \
        /etc/NetworkManager/NetworkManager.conf \
        /etc/NetworkManager/conf.d/*.conf 2>/dev/null \
        | grep -q dnsmasq; then
        [ ! -f "/etc/NetworkManager/dnsmasq.d/boxa.conf" ]
        return $?
    fi
    return 1
}

# Detect-and-repair entry point used by the `boxa update` flow. Called once
# outside the BOXA_UPDATE_PULLED gate so the "already up to date" path also
# self-heals between updates. Idempotent — once the drop-in is in place, the
# predicate returns false and nothing further runs.
#
# `--local` (not `--auto`) so a port-53 conflict or sudo failure surfaces as
# an error instead of silently rewriting dns.conf to external mode. The
# predicate already gated on the user being in local mode; honour that on
# failure too.
_boxa::self_heal_resolver_drop_in() {
    _boxa::resolver_drop_in_missing || return 0
    echo ""
    echo -e "\033[1;36m==> dns.conf present but host resolver drop-in missing — re-running dns-install to repair\033[0m"
    if ! "$BOXA_DIR/scripts/dns-install.sh" install --local; then
        echo -e "\033[1;33mWARN: dns-install reported errors; *.${BOXA_LOCAL_TLD} URLs may not resolve. Existing dns.conf left unchanged — run 'boxa dns-status' to diagnose.\033[0m" >&2
    fi
}

# Start the boxa_dns dnsmasq container in local mode (active_domain=test).
# Skipped in external mode — sslip.io needs no host-side resolver. Mirrors
# bootstrap_traefik: lazy network create, restart-if-exited, run-if-missing.
#
# Runs dnsmasq as root inside the container so it can bind the privileged
# port 53; the host-side port mapping stays loopback-only per ADR 0007.
#
# Image guard: the resolver reuses the boxa image (dnsmasq is already
# baked in per ADR 0001). On a clean checkout without `boxa build`, the
# image is absent; we degrade with a visible WARNING rather than letting
# `docker run` implicit-pull an unrelated `ivijl/boxa:latest` from a
# registry. The user's own container creation later in this script still
# fails-loud at its own image-inspect guard.
bootstrap_dns() {
    # Phase 4 self-heal: ensure_dns_meta_config runs first because it can
    # flip the active mode (when dns.conf was missing and we infer local
    # from container presence), which then affects the route_domain guard.
    ensure_dns_meta_config

    [ "$(boxa::route_domain)" = "$BOXA_LOCAL_TLD" ] || return 0

    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "WARNING: boxa_dns not started — image $IMAGE not built locally." >&2
        echo "         .test URLs will not resolve from the host until you run: boxa build" >&2
        return 0
    fi

    docker network inspect devproxy >/dev/null 2>&1 || docker network create devproxy
    ensure_dns_runtime_config

    if docker ps -a --filter "name=^boxa_dns$" --filter "status=exited" --format '{{.ID}}' | grep -q .; then
        echo "Restarting DNS resolver..."
        docker start boxa_dns
        return
    fi

    if ! docker ps --format '{{.Names}}' | grep -qx boxa_dns; then
        echo "Starting DNS resolver..."
        docker run -d --name boxa_dns --pull=never --restart unless-stopped \
            --network devproxy \
            -u root \
            -p 127.0.0.1:53:53/udp \
            -p 127.0.0.1:53:53/tcp \
            -v "$DNS_CONFIG_DIR/boxa.conf:/etc/boxa-dns.conf:ro" \
            --entrypoint dnsmasq \
            "$IMAGE" \
            --keep-in-foreground --conf-file=/etc/boxa-dns.conf
    fi
}

seed_default_ports() {
    local ports_file="$HOME/.config/boxa/default-ports.conf"
    mkdir -p "$HOME/.config/boxa"
    if [ ! -f "$ports_file" ]; then
        cat > "$ports_file" <<'PORTS'
3000
3001
4173
4200
5000
5173
5174
8000
8080
8081
8090
8888
9000
9090
PORTS
    fi
    # Ensure required ports are present (e.g. markdown-preview on 8090)
    grep -qxF "8090" "$ports_file" 2>/dev/null || echo "8090" >> "$ports_file"
}

# Phase 3 hook: when HTTPS is active, refresh the per-project leaf cert and
# Traefik TLS file-provider config before route files are written. Until
# Phase 4 flips https_active on, this is a noop. Failures inside the cert
# pipeline are non-fatal — boxa keeps serving HTTP-only routes — and the
# cert lib emits its own colored WARN lines so no failure goes silent.
ensure_https_for_container() {
    local container="$1"
    boxa::https_active || return 0
    local project="${container#boxa-}"
    ensure_project_cert "$project" || true
}

apply_port_routes() {
    local container="$1"
    local project="${container#boxa-}"
    ensure_https_for_container "$container"
    local ports_file="$HOME/.config/boxa/default-ports.conf"
    [ -f "$ports_file" ] || return 0

    # Decide the entrypoint flavor once per call based on the *running*
    # Traefik, not the persisted opt-in. When `https_active=true` but
    # 127.0.0.1:443 was held at bootstrap, bootstrap_traefik silently
    # downgrades the container to HTTP-only — pointing routers at a
    # non-existent `websecure` entrypoint would then 404 every port.
    # Every apply_port_routes call site (main flow, restart_exited_container,
    # `boxa port`) runs after bootstrap_traefik has materialised the
    # Traefik container in its effective mode, so the inspect result is
    # authoritative. The persisted flag still drives ensure_https_for_container
    # above so per-project certs keep getting refreshed in the background:
    # the moment port 443 frees and bootstrap_traefik recreates Traefik
    # with `websecure`, the next apply_port_routes pass flips the YAML.
    local websecure_mode="false"
    if _boxa::traefik_has_https; then
        websecure_mode="true"
    fi

    while read -r port _rest; do
        port="${port%%#*}"
        [ -z "$port" ] && continue

        local host_rule="" sep="" host
        while IFS= read -r host; do
            host_rule+="${sep}Host(\`${host}\`)"
            sep=" || "
        done < <(boxa::route_hosts "$project" "$port")
        local config_file="${TRAEFIK_CONFIG_DIR}/${container}-${port}.yml"
        local router_name="${container}-${port}"

        # `tls: {}` makes Traefik pick the matching cert out of the
        # per-project <project>-tls.yml fragment written by
        # _cert::write_tls_yml (via ensure_https_for_container above). The
        # entrypoint-level web→websecure redirect set by bootstrap_traefik
        # means we don't list `web` here at all when HTTPS is on — every
        # HTTP hit is upgraded before any router rule runs.
        if [ "$websecure_mode" = "true" ]; then
            cat > "$config_file" <<YAML
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
        else
            cat > "$config_file" <<YAML
http:
  routers:
    ${router_name}:
      rule: "${host_rule}"
      entryPoints:
        - web
      service: ${router_name}
  services:
    ${router_name}:
      loadBalancer:
        servers:
          - url: "http://${container}:${port}"
YAML
        fi
    done < "$ports_file"
}

# Remove per-project HTTPS artifacts (leaf cert + key + meta + Traefik TLS
# fragment). Used by `boxa remove` and by `boxa stop --clean`, alongside
# the per-port route-file cleanup (`rm -f $TRAEFIK_CONFIG_DIR/boxa-<project>-*.yml`).
# A plain `boxa stop` deliberately leaves both the routes and these
# artifacts in place — the project's identity (cert + routes) is tied to
# the project lifecycle, not the container lifecycle, per ADR 0008. Silent
# (2>/dev/null) so a remove on a project that never had HTTPS active
# doesn't generate spurious WARNs.
#
# Usage: _boxa::remove_project_https_artifacts <project>
_boxa::remove_project_https_artifacts() {
    local project="$1"
    [ -n "$project" ] || return 0
    rm -f \
        "$BOXA_CERTS_DIR/${project}.pem" \
        "$BOXA_CERTS_DIR/${project}.key" \
        "$BOXA_CERTS_DIR/${project}.meta" \
        "$BOXA_CERT_TLS_DIR/${project}-tls.yml" \
        2>/dev/null || true
}

# Remove agent-browser session archives (.netlog.json + .proxy.log +
# .summary.md) that belong to this project's container. Files live under
# /var/log/boxa/agent-browser/ and are owned by the boxa-agent user
# (ADR 0010), so deletion goes through `sudo -u boxa-agent rm` — same
# identity the broker uses when archiving on `agent-browser stop`. Silent
# no-op when the dir is missing or the project never ran an agent-browser
# session.
#
# The archive filename shape is `boxa-<project>-<ISO_TS>.<ext>` where
# `<ISO_TS>` matches `[0-9]{8}T[0-9]{6}Z`. A naive `boxa-<project>-*.<ext>`
# glob would catch prefix-collision projects (`foo` matching `foo-bar`'s
# files), so we walk the glob explicitly, verify the last dash-segment is
# the ISO ts shape, and require the pre-ts prefix to equal `boxa-<project>`
# before deleting. Same defence as _boxa::remove_project_route_yamls.
#
# Usage: _boxa::remove_project_agent_browser_archives <project>
_boxa::remove_project_agent_browser_archives() {
    local project="$1"
    [ -n "$project" ] || return 0
    local archive_dir="/var/log/boxa/agent-browser"
    [ -d "$archive_dir" ] || return 0
    local container="boxa-${project}"

    # Enumerate as boxa-agent. The archive dir is 0750 boxa-agent
    # (ADR 0010), so a host shell without an active boxa-agent group
    # membership cannot list it directly — `boxa remove` immediately
    # after install / before `newgrp` would otherwise see an empty glob
    # and silently leave this project's archives behind. Sudo for the
    # listing parallels the sudo for deletion below; if enumeration fails
    # we surface a warning rather than masking the cleanup gap.
    local listing
    if ! listing=$(sudo -u boxa-agent \
        find "$archive_dir" -maxdepth 1 -type f \
             \( -name "${container}-*.netlog.json" \
             -o -name "${container}-*.proxy.log" \
             -o -name "${container}-*.summary.md" \) 2>/dev/null); then
        echo "  WARN: could not enumerate $archive_dir — agent-browser logs for this project may remain" >&2
        return 0
    fi

    local -a victims=()
    local f base ts head ext
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        base="$(basename "$f")"
        # Strip the longest known extension. Order matters: `.netlog.json`
        # must be tried before `.json` would be — we only know three exts
        # so an explicit case is cleaner than a generic strip.
        case "$base" in
            *.netlog.json) ext="netlog.json"; base="${base%.netlog.json}" ;;
            *.proxy.log)   ext="proxy.log";   base="${base%.proxy.log}"   ;;
            *.summary.md)  ext="summary.md";  base="${base%.summary.md}"  ;;
            *) continue ;;
        esac
        ts="${base##*-}"
        # ISO 8601 basic-format ts: 8 digits, literal T, 6 digits, Z.
        [[ "$ts" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
        head="${base%-"$ts"}"
        [ "$head" = "$container" ] || continue
        # Re-build the validated path rather than trusting $f post-find,
        # so a future change to the loop can't accidentally widen scope.
        victims+=("$archive_dir/${container}-${ts}.${ext}")
    done <<< "$listing"

    [ "${#victims[@]}" -gt 0 ] || return 0

    if sudo -u boxa-agent rm -f -- "${victims[@]}" 2>/dev/null; then
        echo "  Removed ${#victims[@]} agent-browser archive file(s)"
    else
        echo "  WARN: failed to remove some agent-browser archive files in $archive_dir" >&2
    fi
}

# Remove per-port Traefik route YAMLs for a project, plus any sibling
# `.pre-https-backup` files left by scripts/migrate-routes-to-https.sh.
# Companion to _boxa::remove_project_https_artifacts — the three
# together represent the full Traefik footprint of a project. Live route
# files are named `boxa-<project>-<port>.yml` by apply_port_routes;
# backups add a `.pre-https-backup` suffix on top. Both must go: leftover
# backups would be resurrected by _boxa::restore_https_route_backups
# during a later HTTPS rollback, recreating routes for a project whose
# data was already removed.
#
# A naive `boxa-<project>-*.yml*` glob is unsafe twice over: it would
# catch route files of any project whose sanitized name starts with
# `<project>-` (e.g. removing `foo` would eat `boxa-foo-bar-8080.yml`
# for the unrelated project `foo-bar`), and it would also catch any
# non-route YAML that happens to share the prefix. Walk the glob
# explicitly, strip both possible suffixes to get the bare
# `boxa-<project>-<port>` shape, require the final dash segment to be
# a numeric port (mirroring the guard in _boxa::list_routed_containers),
# and then require the pre-port prefix to equal `boxa-<project>` so
# prefix-collision projects survive untouched. The `<project>-tls.yml`
# cert fragment lacks the `boxa-` prefix and is owned by the cert
# helper above.
#
# Usage: _boxa::remove_project_route_yamls <project>
_boxa::remove_project_route_yamls() {
    local project="$1"
    [ -n "$project" ] || return 0
    [ -d "$TRAEFIK_CONFIG_DIR" ] || return 0
    local f base suffix prefix
    for f in "$TRAEFIK_CONFIG_DIR/boxa-${project}-"*.yml \
             "$TRAEFIK_CONFIG_DIR/boxa-${project}-"*.yml.pre-https-backup; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        base="${base%.pre-https-backup}"
        base="${base%.yml}"
        suffix="${base##*-}"
        case "$suffix" in
            ''|*[!0-9]*) continue ;;
        esac
        prefix="${base%-*}"
        [ "$prefix" = "boxa-${project}" ] || continue
        rm -f "$f" 2>/dev/null || true
    done
}

# --- HTTPS lifecycle orchestration (ADR 0008 Phase 6) ------------------------

# Helper used by both upgrade and downgrade paths: emit the unique list of
# per-project containers that currently have at least one `<container>-<port>.yml`
# under $TRAEFIK_CONFIG_DIR. Stdin is unused; output one container name per
# line. Empty when the dir is missing or contains no per-project files.
_boxa::list_routed_containers() {
    [ -d "$TRAEFIK_CONFIG_DIR" ] || return 0
    local f base suffix
    {
        for f in "$TRAEFIK_CONFIG_DIR"/boxa-*-*.yml; do
            [ -f "$f" ] || continue
            base="$(basename "$f" .yml)"
            # Only per-project route files have a numeric port as their
            # final dash-segment. <project>-tls.yml fragments emitted by
            # _cert::write_tls_yml (and any future non-route dynamic
            # config) end on a non-numeric suffix — stripping the last
            # dash group would otherwise yield a bogus container name for
            # any project whose own sanitized name starts with `boxa-`
            # (e.g. project `boxa-foo` has both `boxa-boxa-foo-3000.yml`
            # AND `boxa-foo-tls.yml` under this dir).
            suffix="${base##*-}"
            case "$suffix" in
                ''|*[!0-9]*) continue ;;
            esac
            printf '%s\n' "${base%-*}"
        done
    } | sort -u
}

# Restore every `<name>.yml` from its `<name>.yml.pre-https-backup` sibling
# under $TRAEFIK_CONFIG_DIR. Used by the HTTPS upgrade rollback path when
# the post-bootstrap verification detects that Traefik came up HTTP-only
# despite migration already having rewritten the YAMLs. Iterating every
# backup file is safe even if some are leftovers from an earlier successful
# upgrade: those routes' .yml is currently websecure, and restoring the
# backup brings it back to its original HTTP form — which matches the
# `active=false` state the caller is rolling back to.
#
# Prints the number of files restored. Returns 0; missing backups or copy
# failures are reported on stderr but never bubble up — the caller has
# already committed to a rollback and there is nothing useful to abort to.
_boxa::restore_https_route_backups() {
    [ -d "$TRAEFIK_CONFIG_DIR" ] || return 0
    local b target restored=0
    for b in "$TRAEFIK_CONFIG_DIR"/*.pre-https-backup; do
        [ -f "$b" ] || continue
        target="${b%.pre-https-backup}"
        if cp "$b" "$target" 2>/dev/null; then
            restored=$((restored + 1))
        else
            echo "WARN: could not restore $target from $b" >&2
        fi
    done
    [ "$restored" -gt 0 ] \
        && echo "    Restored $restored route file(s) to HTTP from .pre-https-backup."
    return 0
}

# Full HTTPS upgrade orchestration. The two entry points that call it
# (`boxa update`'s prompt and `boxa dns-install --enable-https`) must
# go through the same path, otherwise the standalone command would only
# flip `active=true` and leave the running Traefik + every existing route
# file pointing at the wrong entrypoint — the regression Codex flagged in
# Phase 6 review round 3.
#
# Returns 0 on full success. Returns 1 on any failure, with `active=false`
# rolled back so the system ends in a coherent HTTP-only state. https.conf
# is intentionally left untouched on a 443-busy pre-flight bail: that is a
# transient blocker, not a user decision, so the next `boxa update` still
# offers the prompt.
_boxa::run_https_upgrade() {
    local owner443="" skip_port_check=0
    # Idempotency carve-out: if our own HTTPS-mode boxa_traefik is
    # already running, it is the listener on 127.0.0.1:443 and probing
    # for an "other" owner would spuriously flag ourselves and block a
    # re-enable. The orchestration below tears down and recreates that
    # container anyway, so a real external squatter would still surface
    # via bootstrap_traefik's own pre-flight + the post-recreate HTTPS
    # verification, which together drive the rollback path.
    if docker ps --filter "name=^boxa_traefik$" --format '{{.ID}}' | grep -q . \
        && _boxa::traefik_has_https; then
        skip_port_check=1
    fi
    if [ "$skip_port_check" -eq 0 ] && owner443="$(_boxa::port_held_by_other 443)"; then
        echo -e "\033[1;33m==> Cannot enable HTTPS now: 127.0.0.1:443 is occupied by ${owner443}.\033[0m"
        echo "    Free port 443, then rerun 'boxa dns-install --enable-https' (or 'boxa update')."
        echo "    https.conf is left untouched."
        return 1
    fi
    # `_BOXA_HTTPS_FLIP_ONLY=1` tells dns-install.sh that the wrapper
    # is driving the full lifecycle: it should do the bare state flip
    # (CA install + https.conf active=true) and skip the re-exec into
    # this orchestration that direct script invocations get routed
    # through.
    if ! _BOXA_HTTPS_FLIP_ONLY=1 "$BOXA_DIR/scripts/dns-install.sh" --enable-https; then
        echo -e "\033[1;31m==> HTTPS enable failed. Boxa stays HTTP-only; rerun 'boxa dns-install --enable-https' to retry.\033[0m"
        return 1
    fi
    # Drop the in-process cache so the migrator and the Traefik recreate
    # below both see `active=true` from the freshly-written https.conf
    # instead of the stale `false` we loaded when this command started.
    boxa::reset_https_cache
    if "$BOXA_DIR/scripts/migrate-routes-to-https.sh" --auto; then
        # Static Traefik flags (entrypoints, redirect) are baked in at
        # `docker run` time, so a live restart would keep the old HTTP-only
        # command line. Tear down (when present) and bootstrap right here —
        # leaving it to the next `boxa <project>` would blackhole every
        # already-running project until the user touches one of them again,
        # and on a clean install would leave `boxa ports` reporting HTTP
        # URLs immediately after a green "HTTPS enabled" message because
        # `boxa::url_scheme` keys off a live HTTPS Traefik, not https.conf.
        if docker ps -a --filter "name=^boxa_traefik$" --format '{{.ID}}' | grep -q .; then
            echo "Recreating boxa_traefik with HTTPS entrypoints..."
            docker stop boxa_traefik >/dev/null 2>&1 || true
            docker rm boxa_traefik >/dev/null 2>&1 || true
        fi
        # Subshell-wrap so bootstrap_traefik's own `exit 1` (fires when
        # 127.0.0.1:80 is grabbed in the race window) cannot tear down
        # the whole boxa process before we get to roll the upgrade
        # back. A docker-run failure in the function's final docker
        # invocation propagates the same way: the subshell exits with
        # the failing rc and `! ( ... )` catches it.
        if ! ( bootstrap_traefik ); then
            echo -e "\033[1;31m==> bootstrap_traefik failed during HTTPS upgrade (likely a port :80/:443 race or docker run error).\033[0m" >&2
            echo "    Rolling back to HTTP — route files restored from backup, https.conf active=false." >&2
            _boxa::restore_https_route_backups
            boxa::write_https_field active false || true
            boxa::reset_https_cache
            return 1
        fi
        # TOCTOU defence: a process could have grabbed 127.0.0.1:443 between
        # the pre-flight probe at the top of this function and the
        # bootstrap_traefik call above. bootstrap_traefik handles that by
        # downgrading the recreated container to HTTP-only and warning, but
        # it returns success — so without this check we would print
        # "HTTPS enabled" while every websecure route file points at an
        # entrypoint the container does not have. Verify the running
        # container really is HTTPS-capable; if not, roll the whole upgrade
        # back to a coherent HTTP-only state. Runs unconditionally now that
        # we always bootstrap above: a fresh-install Traefik can lose :443
        # to the same race as a recreated one.
        if ! _boxa::traefik_has_https; then
            echo -e "\033[1;31m==> Traefik came up HTTP-only despite the upgrade (port 443 was lost between pre-flight and bootstrap).\033[0m" >&2
            echo "    Rolling back to HTTP — route files restored from backup, https.conf active=false." >&2
            _boxa::restore_https_route_backups
            boxa::write_https_field active false || true
            boxa::reset_https_cache
            return 1
        fi
        echo ""
        echo -e "\033[1;32mHTTPS enabled. New URL format:\033[0m"
        echo "    https://<port>.<project>.${BOXA_LOCAL_TLD}"
        echo "    https://<port>.<project>.127.0.0.1.$(boxa::external_provider)"
        echo "    HTTP requests on :80 are 301-redirected to HTTPS."
        return 0
    fi
    # Partial migration. The migrator has already restored every file it
    # successfully rewrote from .pre-https-backup, so on-disk route YAMLs
    # are coherent HTTP again. All we need to do here is roll `active`
    # back: apply_port_routes will then stop emitting the websecure
    # template on future invocations, and the existing HTTP-only Traefik
    # keeps serving the (now HTTP-only) routes without a restart. The
    # user fixes the underlying issue (typically cert generation),
    # optionally inspects *.pre-https-backup for the would-be HTTPS body,
    # and reruns 'boxa dns-install --enable-https'.
    echo -e "\033[1;31m==> Route migration failed — aborting HTTPS upgrade.\033[0m"
    echo "    Route files have been restored to HTTP; *.pre-https-backup files in"
    echo "    $TRAEFIK_CONFIG_DIR are kept for inspection."
    echo "    Fix the cert / permission issue, then rerun 'boxa dns-install --enable-https'."
    echo "    https.conf rolled back to active=false."
    boxa::write_https_field active false || true
    boxa::reset_https_cache
    return 1
}

# Full HTTPS downgrade orchestration: rewrite every per-project route YAML
# back to the HTTP `web` template, tear down the HTTPS-mode Traefik, and
# recreate it HTTP-only. Used by `boxa dns-install --disable-https`.
#
# Order matters: a naive "stop HTTPS Traefik, rewrite YAMLs, bootstrap HTTP"
# sequence creates a brief window where the HTTPS Traefik is gone but new
# YAMLs are not yet written, so requests get connection-refused. That's
# unavoidable because the static Traefik command line is fixed at create
# time; the alternative is bounded to that ~1s gap. We pick:
#
#   1. dns-install --disable-https              (flip active=false)
#   2. docker stop+rm boxa_traefik (if HTTPS) (so apply_port_routes branches HTTP)
#   3. apply_port_routes for every routed container (rewrite YAMLs)
#   4. bootstrap_traefik                        (recreate HTTP-only)
#
# Step 2 must come before step 3 because `_boxa::traefik_has_https` keys
# off `docker inspect`, not on `active` in https.conf — leaving the HTTPS
# container in place would have apply_port_routes keep emitting websecure.
_boxa::run_https_downgrade() {
    # Sentinel: see _boxa::run_https_upgrade for the rationale. Tells
    # dns-install.sh to do the bare https.conf flip instead of recursing
    # back through this orchestration via 'boxa dns-install ...'.
    if ! _BOXA_HTTPS_FLIP_ONLY=1 "$BOXA_DIR/scripts/dns-install.sh" --disable-https; then
        echo -e "\033[1;31m==> HTTPS disable failed (https.conf write error). Aborting.\033[0m" >&2
        return 1
    fi
    boxa::reset_https_cache

    local had_https_traefik=0
    if docker inspect boxa_traefik 2>/dev/null \
        | grep -q -- '--entrypoints.websecure.address=:443'; then
        had_https_traefik=1
        echo "Removing HTTPS-mode boxa_traefik..."
        docker stop boxa_traefik >/dev/null 2>&1 || true
        docker rm boxa_traefik >/dev/null 2>&1 || true
    fi

    # Rewrite every per-project route YAML via the live apply_port_routes
    # template. Now that the HTTPS Traefik is gone, `_boxa::traefik_has_https`
    # returns false, so apply_port_routes emits the `web` branch for every
    # container. Files for ports that are no longer listed in
    # default-ports.conf are not touched here — same behavior as
    # `boxa port`'s reroute pass.
    local rewritten=0 container
    while IFS= read -r container; do
        [ -z "$container" ] && continue
        apply_port_routes "$container"
        rewritten=$((rewritten + 1))
    done < <(_boxa::list_routed_containers)

    # Recreate Traefik HTTP-only. bootstrap_traefik handles the "no
    # container exists" branch by running a fresh `docker run` with the
    # HTTP-only command line (because active=false now). When no Traefik
    # was running before (had_https_traefik=0), the recreate is still
    # cheap and converges the system to the expected state.
    #
    # Subshell-wrap so a port-:80 grab in the race window (which makes
    # bootstrap_traefik `exit 1`) does not abort the whole script after
    # we have already removed the old HTTPS Traefik. We cannot un-remove
    # what we already tore down, but degrading to a clean "config and
    # routes are HTTP-only, Traefik down" state with a loud message
    # leaves the user one `boxa <project>` away from recovery instead
    # of a script that died mid-orchestration.
    if [ "$had_https_traefik" -eq 1 ]; then
        if ! ( bootstrap_traefik ); then
            echo -e "\033[1;31m==> bootstrap_traefik failed during HTTP-only recreate (likely a port :80 race or docker run error).\033[0m" >&2
            echo "    https.conf and route files are coherent HTTP-only, but boxa_traefik is down." >&2
            echo "    Free port 80 and run 'boxa <project>' to bring Traefik back up." >&2
            return 1
        fi
    fi

    echo ""
    echo -e "\033[1;32mHTTPS disabled. URLs reverted to http://. Rewrote routes for ${rewritten} container(s).\033[0m"
    return 0
}

connection_config_file() {
    local source_project="$1"
    printf '%s/%s.tsv' "$CONNECT_CONFIG_DIR" "$source_project"
}

allocate_connection_port() {
    local source="$1" target="$2" target_port="$3" used_file="$4"
    local checksum candidate i
    checksum=$(printf '%s' "${source}:${target}:${target_port}" | cksum | awk '{print $1}')
    candidate=$((15000 + checksum % 1000))

    for i in $(seq 0 999); do
        local port=$((15000 + (candidate - 15000 + i) % 1000))
        if ! awk -F '\t' -v p="$port" '$4 == p { found=1 } END { exit found ? 0 : 1 }' "$used_file" 2>/dev/null; then
            printf '%s' "$port"
            return 0
        fi
    done

    echo "No free boxa connection port in 15000-15999." >&2
    return 1
}

start_container_connection() {
    local source_container="$1" target_container="$2" target_port="$3" local_port="$4" alias="$5"
    local log_file="/tmp/boxa-connect-${local_port}.log"
    local pid_file="/tmp/boxa-connect-${local_port}.pid"

    docker exec -u node \
        -e TARGET_CONTAINER="$target_container" \
        -e TARGET_PORT="$target_port" \
        -e LOCAL_PORT="$local_port" \
        -e CONNECT_ALIAS="$alias" \
        -e LOG_FILE="$log_file" \
        -e PID_FILE="$pid_file" \
        "$source_container" bash -lc '
            set -euo pipefail
            if ss -ltn "sport = :${LOCAL_PORT}" | grep -q ":${LOCAL_PORT}"; then
                exit 0
            fi
            if ! command -v socat >/dev/null 2>&1; then
                echo "socat is not installed in this boxa image." >&2
                exit 1
            fi
            rm -f "$PID_FILE"
            nohup socat TCP-LISTEN:"${LOCAL_PORT}",bind=127.0.0.1,reuseaddr,fork TCP:"${TARGET_CONTAINER}:${TARGET_PORT}" >"$LOG_FILE" 2>&1 &
            echo $! > "$PID_FILE"
        '
}

start_boxa_connections() {
    local container="$1"
    local source_project="${container#boxa-}"
    local config_file
    config_file="$(connection_config_file "$source_project")"
    [ -f "$config_file" ] || return 0

    while IFS=$'\t' read -r alias target_container target_port local_port; do
        [ -n "${alias:-}" ] || continue
        case "$alias" in \#*) continue ;; esac
        if start_container_connection "$container" "$target_container" "$target_port" "$local_port" "$alias"; then
            echo "Connection: ${alias} 10.0.2.2:${local_port} → ${target_container}:${target_port}"
        else
            echo "Failed to start connection ${alias} for ${container}." >&2
        fi
    done < "$config_file"
}

list_boxa_container_names() {
    docker ps --filter "name=^boxa-" --format '{{.Names}}' | filter_user_containers
}

# Probe LISTENING TCP ports inside a running container by reading
# /proc/net/tcp[6] directly — no binary inside the container is required.
# Prints ports newline-separated and sorted unique on stdout.
#
# Exit code is the signal to the caller:
#   0  probe succeeded (output may be empty = genuinely no listeners)
#   != probe failed   (docker exec hung/erroreded, container gone, no perms)
#
# Distinguishing the two matters so the `ports` command can hide routes only
# when the probe affirmatively found nothing, and fall back to "show all
# routes" if the probe itself was unreliable. Uses GNU `timeout` when
# available; macOS default install lacks it, so on those hosts the call
# runs unguarded — `docker exec` on a healthy container returns promptly,
# and a true hang there is a separate problem worth surfacing anyway.
list_listening_ports_in_container() {
    local container="$1" raw rc=0
    if command -v timeout >/dev/null 2>&1; then
        raw=$(timeout 3 docker exec "$container" sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null') || rc=$?
    else
        raw=$(docker exec "$container" sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null') || rc=$?
    fi
    [ "$rc" -ne 0 ] && return "$rc"
    printf '%s\n' "$raw" \
        | awk 'BEGIN { for (i = 0; i < 256; i++) hex[sprintf("%02X", i)] = i }
               $4 == "0A" {
                 n = split($2, parts, ":")
                 h = parts[n]
                 port = hex[substr(h, 1, 2)] * 256 + hex[substr(h, 3, 2)]
                 print port
               }' \
        | sort -un
}

discover_published_tcp_services() {
    local target_container="$1"
    local target_project="${target_container#boxa-}"
    local rows
    rows=$(docker exec -u node "$target_container" bash -lc \
        'docker ps --format "{{.Names}}\t{{.Ports}}"' 2>/dev/null || true)
    [ -n "$rows" ] || return 0

    while IFS=$'\t' read -r inner_name ports; do
        [ -n "${inner_name:-}" ] || continue
        [ -n "${ports:-}" ] || continue
        IFS=',' read -ra entries <<< "$ports"
        local entry
        for entry in "${entries[@]}"; do
            entry="${entry#"${entry%%[![:space:]]*}"}"
            entry="${entry%"${entry##*[![:space:]]}"}"
            [[ "$entry" == *"->"*"/tcp"* ]] || continue

            local left right host_port private_port
            left="${entry%%->*}"
            right="${entry#*->}"
            right="${right%%/*}"
            host_port="${left##*:}"
            private_port="$right"
            [[ "$host_port" =~ ^[0-9]+$ ]] || continue
            [[ "$private_port" =~ ^[0-9]+$ ]] || continue

            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$target_project" "$target_container" "$inner_name" "$host_port" "$private_port"
        done
    done <<< "$rows"
}

upsert_connection_record() {
    local source_project="$1" alias="$2" target_container="$3" target_port="$4" local_port="$5"
    local config_file tmp
    config_file="$(connection_config_file "$source_project")"
    mkdir -p "$CONNECT_CONFIG_DIR"
    touch "$config_file"

    tmp="${config_file}.tmp"
    awk -F '\t' -v t="$target_container" -v p="$target_port" -v lp="$local_port" \
        'BEGIN { OFS = FS } !($2 == t && $3 == p) && !($4 == lp)' "$config_file" > "$tmp"
    printf '%s\t%s\t%s\t%s\n' "$alias" "$target_container" "$target_port" "$local_port" >> "$tmp"
    mv "$tmp" "$config_file"
}

# Gracefully stop a boxa container — close allow-for window first, then
# inner DinD containers, then the container itself.
graceful_stop_container() {
    local name="$1"

    # Close any live allow-for window BEFORE docker stop. Three reasons this
    # has to run here and not in the restart closeout:
    #   1. MODE=stop calls `docker rm` right after this — the container fs
    #      (including /etc/boxa-shared/.allow-for.state and the dnsmasq
    #      queries log) is about to be destroyed. After `docker rm` there's
    #      nothing for closeout-allow-for-on-restart to harvest.
    #   2. The teardown daemon dies on SIGKILL from `docker stop` without
    #      running its own teardown — no trap handler, just a sleep loop.
    #   3. Running teardown while the container is still alive gives the
    #      harvest full access to the dnsmasq queries log, so the captured
    #      domain list is complete instead of "no data available".
    # Best-effort: a failed teardown must not block container shutdown.
    # `docker exec` on a stopped container fails harmlessly via `|| true`,
    # which handles the rare race where the container exits between our
    # `test -f` and the teardown invocation.
    if docker exec -u root "$name" test -f /etc/boxa-shared/.allow-for.state 2>/dev/null; then
        docker exec -u root "$name" /usr/local/bin/teardown-allow-for-window --now 2>/dev/null || true
    fi

    # Close any live Agent-browser session BEFORE docker stop — the broker
    # signals the in-container bridge socat via `docker exec`, which needs
    # the container still alive. Silent no-op when no session JSON exists.
    # Best-effort: a failed teardown must not block container shutdown.
    if [ -x "$BOXA_DIR/scripts/closeout-agent-browser-on-stop.sh" ]; then
        "$BOXA_DIR/scripts/closeout-agent-browser-on-stop.sh" "$name" || true
    fi

    docker exec -u node "$name" bash -c '
        if [ -S "$XDG_RUNTIME_DIR/docker.sock" ] && docker info >/dev/null 2>&1; then
            inner=$(docker ps --format "{{.ID}} {{.Names}}" 2>/dev/null)
            if [ -n "$inner" ]; then
                echo "Stopping inner containers..."
                while read -r cid cname; do
                    echo "  Stopping: $cname ($cid)"
                    docker stop -t 30 "$cid" >/dev/null 2>&1 || true
                done <<< "$inner"
            fi
        fi
    ' 2>/dev/null || true
    docker stop -t 15 "$name" > /dev/null 2>&1 || true
}

stop_traefik_if_idle() {
    local remaining
    remaining=$(docker ps --filter "name=^boxa-" --format '{{.Names}}' | filter_user_containers)
    if [ -z "$remaining" ] && docker ps --format '{{.Names}}' | grep -qx boxa_traefik; then
        docker stop boxa_traefik > /dev/null
        docker rm boxa_traefik > /dev/null
        echo "Stopped: boxa_traefik (no remaining containers)"
    fi
}

stop_dns_if_idle() {
    local remaining
    remaining=$(docker ps --filter "name=^boxa-" --format '{{.Names}}' | filter_user_containers)
    if [ -z "$remaining" ] && docker ps --format '{{.Names}}' | grep -qx boxa_dns; then
        docker stop boxa_dns > /dev/null
        docker rm boxa_dns > /dev/null
        echo "Stopped: boxa_dns (no remaining containers)"
    fi
}

attach_to_container() {
    local name="$1"
    echo "Attaching to running container: $name"
    set_tab_title "${name#boxa-}"
    # Prefer the host project path advertised by Phase 2 containers; fall back
    # to /workspace/<name> for legacy containers that pre-date this layout.
    local ws
    ws=$(docker exec -u node "$name" sh -c 'printf %s "$BOXA_PROJECT_HOST_PATH"' 2>/dev/null || true)
    if [ -z "$ws" ] || ! docker exec -u node "$name" test -d "$ws" 2>/dev/null; then
        ws="/workspace/${name#boxa-}"
        if ! docker exec -u node "$name" test -d "$ws" 2>/dev/null; then
            ws="/workspace"
        fi
    fi
    exec docker exec -it -u node -w "$ws" "$name" zsh
}

# --- Docker DNS upstream detection (ADR 0015) -------------------------------
# Find the non-loopback DNS upstream(s) the Docker embedded resolver forwards
# to, so init-firewall.sh can open a narrow port-53 hole for that forward.
#
# On native Linux the embedded resolver at 127.0.0.11 forwards external queries
# FROM the container's netns to the daemon's upstream, so a non-loopback
# upstream (e.g. Omarchy's daemon.json 172.17.0.1, or a router/static
# nameserver inherited from the host's resolv.conf) hits the firewall's DNS pin
# and is rejected. A loopback upstream (systemd-resolved 127.0.0.53) is proxied
# host-side and never reaches the container firewall — nothing to allow. Docker
# Desktop forwards upstream inside its own VM (never through the container
# firewall) and reads that VM's resolv.conf, not this host's, so the
# inherited-resolv.conf path is skipped there.

ipv4_private_upstream() {
    # stdin → space-separated unique RFC1918-private dotted-quads (or nothing).
    # Only a private upstream (Docker bridge gateway, corporate stub) ever earns
    # a port-53 hole in the container firewall. Public resolvers (1.1.1.1,
    # 8.8.8.8, …) are dropped here AND refused container-side: ADR 0009 requires
    # external DNS to be unreachable from inside, and a public upstream is never
    # needed anyway — the embedded resolver forwards host-side, so dnsmasq still
    # resolves via 127.0.0.11 with no hole. Loopback (127.x) is excluded for
    # free: it is proxied host-side and is not in the private ranges below.
    grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
        | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' \
        | awk '!seen[$0]++' \
        | tr '\n' ' ' \
        | sed 's/ *$//' \
        || true
}

detect_docker_dns_upstream() {
    local conf os content
    # 1. Explicit daemon DNS (daemon.json "dns") — takes precedence over the
    #    host resolv.conf and applies on every platform. Read the ACTIVE
    #    daemon's file (rootless dockerd uses $XDG_CONFIG_HOME/docker, rootful
    #    uses /etc/docker), not a fixed order, so a stale config for the other
    #    daemon kind is never read. Parse without jq (install.sh does not
    #    provision it host-side): flatten newlines so a multi-line array
    #    matches, then isolate the bracketed "dns" value — its elements are
    #    IP/hostname strings, so [^]] stops at the array's own closing bracket
    #    and never captures IPs from sibling keys like "bip".
    if docker info --format '{{join .SecurityOptions ","}}' 2>/dev/null | grep -q 'name=rootless'; then
        conf="${XDG_CONFIG_HOME:-$HOME/.config}/docker/daemon.json"
    else
        conf="/etc/docker/daemon.json"
    fi
    if [ -r "$conf" ]; then
        # Capture the "dns" array's CONTENT (between the brackets). A present,
        # non-empty "dns" is authoritative and overrides the host resolv.conf
        # below even if every entry is loopback (→ allow nothing); only an
        # absent or empty "dns" falls through to tier 2.
        content=$(tr -d '\r\n' < "$conf" \
            | sed -n 's/.*"dns"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p')
        if [ -n "${content//[[:space:]]/}" ]; then
            printf '%s\n' "$content" | ipv4_private_upstream
            return 0
        fi
    elif [ -e "$conf" ]; then
        # Exists but root-only (e.g. 0600): we run as the invoking user, so
        # reading it would fail and abort the whole start under `set -e`. Warn
        # and emit nothing rather than guess — an explicit daemon DNS we can't
        # read must NOT silently fall through to resolv.conf. The host-visible
        # DNS probe after start is the safety net. See ADR 0015.
        echo "WARNING: $conf exists but is not readable; cannot honor an explicit Docker daemon DNS (see ADR 0015)." >&2
        return 0
    fi

    # 2. No explicit dns: a NATIVE-Linux daemon inherits the host's
    #    /etc/resolv.conf and forwards its non-loopback nameservers from the
    #    container netns (same mechanism, same breakage). Only a PRIVATE
    #    nameserver is emitted: a host that lists public resolvers (1.1.1.1,
    #    8.8.8.8) directly forwards them host-side in practice, so no hole is
    #    needed, and ADR 0009 forbids exposing them inside regardless. All-
    #    loopback resolv.conf (systemd-resolved) yields nothing — proxied
    #    host-side. Take only the address field ($2) so an inline comment or
    #    trailing metadata carrying another IP is never treated as an upstream.
    os=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)
    case "$os" in
        *"Docker Desktop"*) return 0 ;;
    esac
    [ -r /etc/resolv.conf ] || return 0
    awk '$1=="nameserver"{print $2}' /etc/resolv.conf | ipv4_private_upstream
}

# Detect the Docker DNS upstream(s) and write them to the host file that is
# bind-mounted into the container. Called on BOTH the create and the
# `docker start` restart paths so a daemon-DNS change is picked up without
# recreating the container — a docker -e env var would freeze at create time.
# Written in place (truncate, not unlink+recreate) so the bind-mount inode is
# preserved (memory: Docker Desktop snapshots bind mounts by inode).
write_dns_upstream_file() {
    mkdir -p "$(dirname "$DNS_UPSTREAM_HOST_FILE")"
    detect_docker_dns_upstream > "$DNS_UPSTREAM_HOST_FILE"
}

# Surface in-container DNS health to the host operator. init-firewall.sh runs
# its own upstream-DNS probe, but that output lands only in `docker logs` (the
# container starts detached, before we attach), so a total DNS outage can look
# like a clean boot. Re-probe here, after the firewall is up, where the output
# reaches the user's terminal. Runs on both the create and restart paths.
# See docs/adr/0015.
warn_if_dns_broken() {
    local name="$1"
    if ! docker exec -u node "$name" \
            sh -c 'dig +short +time=3 +tries=1 github.com 2>/dev/null | grep -q .'; then
        echo "WARNING: DNS resolution is failing inside the container."
        echo "         Either this host sets a non-loopback Docker daemon DNS that docker-run.sh could not"
        echo "         detect, or it points at a PUBLIC resolver (daemon.json \"dns\" or /etc/resolv.conf) that"
        echo "         boxa refuses to expose inside (ADR 0009). Point the Docker daemon DNS at a private stub"
        echo "         or loopback resolver (e.g. systemd-resolved 127.0.0.53). See docs/adr/0015 (BOXA_DNS_UPSTREAM)."
    fi
}

# Block until a freshly (re)started container either reaches its node phase or
# exits. The container runs detached (docker run -d / docker start), so when the
# root entrypoint aborts — most commonly init-firewall.sh's `exit 1` on a failed
# verification — the explanatory ERROR lands only in `docker logs` and the start
# looks silently broken: the caller would barrel on to `docker exec`, which then
# fails with a cryptic "container is not running". Detect the outcome and, on
# failure, surface the container's own log on the user's terminal with a reason.
#
# Readiness signal: PID 1's owner flips root -> node when the entrypoint drops
# privileges via setpriv, which happens ONLY after init-firewall and all other
# root setup passed. This is race-free and needs no in-container sentinel — a
# file marker under /run would read stale across restarts (/run is overlayfs,
# not tmpfs, so it persists). Returns 0 when ready, 1 (after printing the log)
# when the container died during init.
wait_for_boxa_ready() {
    local name="$1" owner waited=0
    while [ "$waited" -lt 120 ]; do
        if [ "$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)" != "running" ]; then
            echo "" >&2
            echo "ERROR: boxa failed to start — container '$name' exited during initialization." >&2
            echo "       Root setup did not pass (most often the firewall verification). Last log lines:" >&2
            echo "" >&2
            docker logs --tail 25 "$name" 2>&1 | sed 's/^/    /' >&2 || true
            echo "" >&2
            echo "       Full log:  docker logs $name" >&2
            return 1
        fi
        owner=$(docker exec "$name" stat -c '%U' /proc/1 2>/dev/null || true)
        [ "$owner" = "node" ] && return 0
        sleep 0.5
        waited=$((waited + 1))
    done
    # Still in the root phase after the cap (a pathologically slow but not-yet-
    # failed start) — don't block the user further; downstream exec still works
    # if it eventually came up, and re-fails loudly if it did not.
    return 0
}

# Preserve any pending OOM evidence while Docker can still correlate the
# Container ID to its Project. This must complete before every destructive
# removal of a user Container; the ordinary invocation-time sweep stays
# detached so non-destructive commands keep their current latency.
_boxa::remove_container_after_oom_sweep() {
    local name="$1"
    if [ -x "$BOXA_DIR/scripts/sweep-oom-events.sh" ]; then
        "$BOXA_DIR/scripts/sweep-oom-events.sh" || true
    fi
    docker rm "$name" > /dev/null
}

# Restart an exited boxa container and re-run init scripts
# Returns 1 if restart fails (stale mounts after reboot) — caller should recreate
restart_exited_container() {
    local name="$1" project_path="${2:-}" cli_memory="${3:-}" cli_memory_swap="${4:-}"
    echo "Restarting exited container: $name"
    # Containers created before the DNS upstream bind mount existed (ADR 0015)
    # would have DNS_UPSTREAM_CONTAINER_FILE absent after a plain `docker start`,
    # leaving DNS broken. Detect the missing mount and fall back to recreation
    # (rm + return 1), the same contract the caller already handles for stale
    # mounts. New containers always have the mount, so this is a one-time
    # post-upgrade recreation.
    if ! docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$name" 2>/dev/null \
            | grep -qxF "$DNS_UPSTREAM_CONTAINER_FILE"; then
        echo "Recreating container to add the DNS upstream mount (ADR 0015)..."
        _boxa::remove_container_after_oom_sweep "$name"
        return 1
    fi
    # Refresh the DNS upstream file before start: the entrypoint re-runs
    # init-firewall on every start, so a daemon-DNS change since create is
    # picked up here without recreating the container (ADR 0015).
    write_dns_upstream_file
    _boxa::converge_container_resources "$name" "$project_path" \
        "$cli_memory" "$cli_memory_swap" stopped || exit 1
    if ! docker start "$name" 2>/dev/null; then
        echo "Restart failed (stale mounts?), removing dead container..."
        _boxa::remove_container_after_oom_sweep "$name"
        return 1
    fi
    # The entrypoint re-runs the root setup (firewall verification included) on
    # every start; if it aborts, the container exits detached. Surface the cause
    # instead of failing cryptically on the node-mode exec below. A firewall
    # failure is fatal and recreating would not fix it, so stop outright.
    if ! wait_for_boxa_ready "$name"; then
        exit 1
    fi
    # Root-context setup (firewall, gitconfig, host-home symlink) is handled by
    # the entrypoint on every container start. Here we only run the user-mode
    # setup as node.
    docker exec -u node "$name" bash -c \
        '/usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh && /usr/local/bin/setup-claude.sh'
    warn_if_dns_broken "$name"
    # Re-apply port routes
    apply_port_routes "$name"
    start_boxa_connections "$name"
}

# Read the absolute host Project path recorded in a Container's environment.
# Inspecting Config.Env avoids an exec and works during early startup too.
_boxa::container_project_path() {
    local name="$1"
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null \
        | awk 'index($0, "BOXA_PROJECT_HOST_PATH=") == 1 && !found {
            sub(/^BOXA_PROJECT_HOST_PATH=/, "")
            print
            found=1
        }'
}

# Read current cgroup usage. BOXA_MEMORY_USAGE_FILE is the no-Docker unit-test
# seam; production reads the unified-cgroup value from inside the Container.
_boxa::container_memory_usage_bytes() {
    local name="$1"
    if [ -n "${BOXA_MEMORY_USAGE_FILE:-}" ]; then
        cat "$BOXA_MEMORY_USAGE_FILE"
    else
        docker exec "$name" cat /sys/fs/cgroup/memory.current 2>/dev/null
    fi
}

# Converge one existing Container. Config/CLI validation errors are returned to
# touched-container callers; Docker/race failures are silent and non-fatal.
_boxa::converge_container_resources() {
    local name="$1" project_path="${2:-}" cli_memory="${3:-}" cli_memory_swap="${4:-}"
    local container_state="${5:-running}"
    local desired_memory desired_memory_swap live live_memory live_memory_swap extra usage="" one_shot=""

    if [ -z "$project_path" ]; then
        project_path="$(_boxa::container_project_path "$name" 2>/dev/null || true)"
    fi
    [ -n "$project_path" ] || return 0

    if ! _boxa::resolve_resources "$project_path" "$cli_memory" "$cli_memory_swap"; then
        return 1
    fi
    desired_memory="$_BOXA_MEMORY_BYTES"
    desired_memory_swap="$_BOXA_MEMORY_SWAP_BYTES"

    live="$(docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}' "$name" 2>/dev/null)" \
        || return 0
    read -r live_memory live_memory_swap extra <<< "$live"
    [[ "$live_memory" =~ ^[0-9]+$ ]] || return 0
    [[ "$live_memory_swap" =~ ^-?[0-9]+$ ]] || return 0
    [ -z "$extra" ] || return 0

    if [ "$container_state" != stopped ] \
        && { [ "$live_memory" -eq 0 ] || [ "$desired_memory" -lt "$live_memory" ]; } \
        && [ "$live_memory" -ne "$desired_memory" ]; then
        usage="$(_boxa::container_memory_usage_bytes "$name" 2>/dev/null || true)"
    fi
    [ -z "$cli_memory$cli_memory_swap" ] || one_shot=1
    _boxa::plan_resource_convergence "$name" "$live_memory" "$live_memory_swap" \
        "$desired_memory" "$desired_memory_swap" "$usage" "$one_shot" \
        "$_BOXA_HOST_MEMTOTAL_BYTES"
    [ -n "$_BOXA_RESOURCE_UPDATE_NEEDED" ] || return 0

    _boxa::sweep_oom_before_resource_update
    if docker update --memory "$desired_memory" --memory-swap "$desired_memory_swap" \
            "$name" >/dev/null 2>&1; then
        printf '%s\n' "$_BOXA_RESOURCE_UPDATE_NOTICE"
        [ -z "$_BOXA_RESOURCE_UPDATE_WARNING" ] || printf '%s\n' "$_BOXA_RESOURCE_UPDATE_WARNING"
    fi
}

# Converge every running user Container except an optional one being handled
# later with a one-shot override. Per-Container failures never block the CLI.
_boxa::sweep_running_resource_limits() {
    local exclude="${1:-}" containers name project_path
    containers="$(docker ps --filter 'name=^boxa-' --format '{{.Names}}' 2>/dev/null \
        | filter_user_containers)" || return 0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$name" != "$exclude" ] || continue
        project_path="$(_boxa::container_project_path "$name" 2>/dev/null || true)"
        [ -n "$project_path" ] || continue
        _boxa::converge_container_resources "$name" "$project_path" 2>/dev/null || true
    done <<< "$containers"
}

# Identify the auto-mode Container only when raw arguments contain a one-shot
# override. The real parser below still owns validation and consumes argv.
_boxa::cli_override_container() {
    local has_override=false target
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --memory|--memory-swap)
                has_override=true
                [ "$#" -ge 2 ] || return 1
                shift 2
                ;;
            --ssh-config) shift ;;
            *) return 1 ;;
        esac
    done
    [ "$has_override" = true ] || return 1
    target="${1:-.}"
    if [ -d "$target" ]; then
        boxa::names_from_path "$(realpath "$target")"
    else
        boxa::names_from_token "$target"
    fi
    printf '%s' "$BOXA_CONTAINER_NAME"
}

list_running_containers() {
    local containers
    containers=$(docker ps --filter "name=^boxa-" --format '{{.Names}}\t{{.Status}}\t{{.RunningFor}}' | filter_user_containers)
    if [ -z "$containers" ]; then
        echo "No running boxa containers."
    else
        printf '%-25s %-50s %-20s %s\n' "NAME" "URL" "STATUS" "MEM"
        local scheme
        scheme="$(boxa::url_scheme)"
        while IFS=$'\t' read -r name status running; do
            local project url mem_probe
            project="${name#boxa-}"
            url="${scheme}://$(boxa::route_host_display "$project" '<port>')"
            # Memory posture costs one read-only exec per running container,
            # only when ls runs: the private cgroup namespace exposes the
            # container's own memcg at the cgroup root (ADR 0020). A container
            # that dies mid-ls degrades to a "-" cell via _boxa::mem_cell.
            mem_probe=$(docker exec -u root "$name" sh -c \
                'cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.max &&
                 awk '\''$1 == "oom_kill" { print $2 }'\'' /sys/fs/cgroup/memory.events' \
                2>/dev/null) || mem_probe=""
            # MEM sits last: the OOM marker's "×" is multibyte and would skew
            # printf's byte-counted padding of any column after it.
            printf '%-25s %-50s %-20s %s\n' "$name" "$url" "$status" \
                "$(_boxa::mem_cell "$mem_probe")"
        done <<< "$containers"
    fi

    local exited
    exited=$(docker ps -a --filter "name=^boxa-" --filter "status=exited" \
        --format '{{.Names}}\t{{.Status}}' | filter_user_containers)
    if [ -n "$exited" ]; then
        echo ""
        echo "Exited (use 'boxa <name>' to restart):"
        # Lifetime OOM flags for the whole section in one batched inspect —
        # no exec on exited containers. A container removed between the ps
        # snapshot and the inspect just misses from the map (no marker);
        # the inspect still reports the survivors.
        local -A exited_oom=()
        local -a exited_names=()
        local iname iflag marker
        while IFS=$'\t' read -r name status; do
            exited_names+=("$name")
        done <<< "$exited"
        while IFS=$'\t' read -r iname iflag; do
            [ -n "$iname" ] && exited_oom["${iname#/}"]="$iflag"
        done < <(docker inspect --format $'{{.Name}}\t{{.State.OOMKilled}}' \
            "${exited_names[@]}" 2>/dev/null || true)
        while IFS=$'\t' read -r name status; do
            marker="$(_boxa::exited_oom_marker "${exited_oom[$name]:-}" "${name#boxa-}")"
            if [ -n "$marker" ]; then
                printf '  %-25s %-28s %s\n' "$name" "$status" "$marker"
            else
                printf '  %-25s %s\n' "$name" "$status"
            fi
        done <<< "$exited"
    fi
}

# Print a heads-up when an allow-for window is currently live in any
# running boxa container. Called from MODE=allow and MODE=deny so the
# user knows the allowlist edit they just made interacts with the
# transient harvest pool (ADR 0009).
#
# $1 = the affected domain  (just for the message body)
# $2 = action — "allow" or "deny"
#
# Cost: one `docker exec` per running container. Acceptable: allow/deny is
# a single human-driven operation; nobody runs it in a hot loop. The probe
# is read-only (`-u node`, `test -f`, `cut`).
warn_if_allow_for_active() {
    local domain="$1" action="$2"
    local containers
    containers=$(docker ps --filter "name=^boxa-" --format '{{.Names}}' | filter_user_containers)
    [ -z "$containers" ] && return 0

    local c exp_iso exp_hhmm
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        exp_iso=$(docker exec -u node "$c" bash -c '
            f=/etc/boxa-shared/.allow-for.state
            [ -f "$f" ] || exit 1
            exp=$(grep -E "^expires_at=" "$f" | head -1 | cut -d= -f2-)
            [ -n "$exp" ] || exit 1
            now=$(date +%s)
            target=$(date -d "$exp" +%s 2>/dev/null) || exit 1
            [ "$now" -lt "$target" ] || exit 1
            echo "$exp"
        ' 2>/dev/null) || continue
        exp_hhmm=$(date -d "$exp_iso" +%H:%M 2>/dev/null || echo "$exp_iso")
        case "$action" in
            allow)
                echo "Note: allow-for window is active in ${c} until ${exp_hhmm}."
                echo "  ${domain} is being permanently allowed; effect is identical after the window closes."
                ;;
            deny)
                echo "Note: allow-for window is active in ${c} until ${exp_hhmm}."
                echo "  ${domain} remains accepted via harvest-pool until the window closes."
                echo "  Use 'boxa allow-for --stop' to close the window immediately."
                ;;
        esac
    done <<< "$containers"
}

# Trigger dnsmasq config reload in all running boxa containers.
# Implementation lives in /usr/local/bin/boxa-firewall-reload (in the image);
# this is just the per-container fan-out.
#
# Usage:
#   reload_firewall_in_containers                  # plain reload
#   reload_firewall_in_containers allow <domain>   # warm DNS cache for new domain
#   reload_firewall_in_containers deny  "<doms>"   # space-separated domains to drop from ipset
reload_firewall_in_containers() {
    local action="${1:-}"
    local domains="${2:-}"
    local containers
    containers=$(docker ps --filter "name=^boxa-" --format '{{.Names}}' | filter_user_containers)
    [ -z "$containers" ] && return 0
    while IFS= read -r container; do
        if docker exec -u root "$container" /usr/local/bin/boxa-firewall-reload "$action" "$domains"; then
            echo "  Reloaded: $container"
        else
            echo "  Failed: $container" >&2
        fi
    done <<< "$containers"
}

# Thin wrapper around picker::one for boxa containers.
# $1 = prompt text, $2 = optionally "with_all" to add "stop all" sentinel.
# Returns selected name on stdout, 1 on cancel/empty.
pick_container() {
    local prompt="$1" with_all="${2:-}"
    local running
    running=$(docker ps -a --filter "name=^boxa-" --format '{{.Names}}' | filter_user_containers)

    if [ -z "$running" ]; then
        echo "No boxa containers." >&2
        return 1
    fi

    local args=(--prompt "$prompt")
    [ "$with_all" = "with_all" ] && args+=(--first-option "* Stop all")
    printf '%s\n' "$running" | picker::one "${args[@]}"
}

# Open an IDE attached to a boxa container ($1 = cursor|code, $2 = optional target).
attach_ide() {
    local ide="$1" target="${2:-}"
    local binary display_name install_hint
    case "$ide" in
        cursor)
            binary=cursor
            display_name="Cursor"
            install_hint="Cursor → Cmd+Shift+P → 'Install cursor command in PATH'"
            ;;
        code)
            binary=code
            display_name="VS Code"
            install_hint="VS Code → Cmd+Shift+P → 'Install code command in PATH'"
            ;;
        *)
            echo "Unknown IDE: $ide" >&2
            exit 1
            ;;
    esac

    if ! command -v "$binary" &>/dev/null; then
        echo "Error: '$binary' CLI not found in PATH." >&2
        echo "Install it: $install_hint" >&2
        exit 1
    fi

    if [ -n "$target" ]; then
        boxa::names_from_token "$target"
    else
        boxa::names_from_path "$(pwd)"
    fi
    local container="$BOXA_CONTAINER_NAME"

    if ! docker ps --filter "name=^${container}$" --format '{{.Names}}' | grep -q .; then
        echo "Container $container is not running." >&2
        container=$(pick_container "Select container: ") || exit 1
    fi

    local hostpath
    hostpath=$(docker exec "$container" sh -c 'printf %s "$BOXA_PROJECT_HOST_PATH"' 2>/dev/null || true)
    if [ -z "$hostpath" ]; then
        echo "Container $container predates Phase 2 layout (ADR 0004)." >&2
        echo "Restart it to pick up the new mount: boxa stop $container && boxa" >&2
        exit 1
    fi

    local attach_json="{\"containerName\":\"/${container}\"}"
    local hex
    if command -v xxd &>/dev/null; then
        hex=$(printf '%s' "$attach_json" | xxd -p | tr -d '\n')
    else
        hex=$(printf '%s' "$attach_json" | od -A n -t x1 | tr -d ' \n')
    fi
    local encoded_path folder_uri
    encoded_path=$(url_encode_path "$hostpath")
    folder_uri="vscode-remote://attached-container+${hex}${encoded_path}"

    echo "Opening $display_name attached to $container..."
    "$binary" --folder-uri "$folder_uri"
}

# --- Allow-for notification sweep (ADR 0009, Phase 3) ------------------------
# Every `boxa` invocation kicks a background sweep of pending notification
# files left by the in-container teardown daemon. Fire-and-forget: detached
# via setsid, output redirected, errors swallowed so it never interferes
# with the user's actual command. Gated on the pending subdir existing —
# pre-Phase-3 installs lack the subdir until `boxa update` runs the
# self-heal; skipping in that window is correct (no pending files can
# exist yet).
#
# Cost when there's nothing to do: one fork + a `find -mmin +N` over an
# empty directory, single-digit ms. Worth paying for the "user reboots
# host, then runs any boxa command" case where pending files from a
# pre-reboot window finally get a chance to render.
if [ -d /var/log/boxa/allow-for/pending ] \
    && [ -x "$BOXA_DIR/scripts/deliver-allow-for-notification.sh" ]; then
    detach_bg "$BOXA_DIR/scripts/deliver-allow-for-notification.sh" --sweep
fi

# --- OOM archive sweep -------------------------------------------------------
# Read the shared kernel ring buffer after every boxa invocation and archive
# newly observed boxa memcg OOM kills. The detached worker owns all parsing,
# correlation, dedup, and notification work; this path stays one cheap guard
# plus one fire-and-forget fork. If the VM dies before a sweep, its memory-only
# dmesg evidence is irretrievably lost.
if [ -x "$BOXA_DIR/scripts/sweep-oom-events.sh" ]; then
    detach_bg "$BOXA_DIR/scripts/sweep-oom-events.sh"
fi

# --- Memory-limit convergence sweep -----------------------------------------
# Synchronous because changed Containers must be visible to the user. The
# touched Container is skipped only for a one-shot override and converged on
# its attach/restart path; every other running user Container is checked here.
convergence_sweep_exclude="$(_boxa::cli_override_container "$@" 2>/dev/null || true)"
_boxa::sweep_running_resource_limits "$convergence_sweep_exclude" || true
unset convergence_sweep_exclude

# --- Subcommand parsing ------------------------------------------------------

CLEAN_VOLUMES=false
SSH_CONFIG_MOUNT=false
CLI_MEMORY=
CLI_MEMORY_SWAP=

case "${2:-}" in
    -h|--help|help) show_command_help "${1:-}" ;;
esac

case "${1:-}" in
    -h|--help) show_help ;;
    help)     shift; show_command_help "${1:-}" ;;
    ls)      MODE="ls";      shift ;;
    mem)     MODE="mem";     shift; MEM_TARGET="${1:-}" ;;
    stop)    MODE="stop";    shift; PROJECT_FILTER=""
             # Parse --clean flag and optional project name (any order)
             for arg in "$@"; do
                 case "$arg" in
                     --clean) CLEAN_VOLUMES=true ;;
                     *)       PROJECT_FILTER="$arg" ;;
                 esac
             done
             ;;
    remove)  MODE="remove";  shift; PROJECT_FILTER="${1:-}" ;;
    port)    MODE="port";    shift; PORT_NUM="${1:-}" ;;
    ports)   MODE="ports";   shift ;;
    connect) MODE="connect"; shift ;;
    connections) MODE="connections"; shift ;;
    allow)   MODE="allow";   shift; DOMAIN="${1:-}" ;;
    deny)    MODE="deny";    shift; DOMAIN="${1:-}" ;;
    blocked)   MODE="blocked";   shift ;;
    allow-for) MODE="allow-for"; shift
             # Positionals can come in either order: a numeric token is the
             # window length in minutes, a non-numeric token is the project
             # target. --stop is a flag that swaps start → stop.
             ALLOW_FOR_MINUTES=""
             ALLOW_FOR_TARGET=""
             ALLOW_FOR_STOP=false
             for arg in "$@"; do
                 case "$arg" in
                     --stop)         ALLOW_FOR_STOP=true ;;
                     ''|*[!0-9]*)    ALLOW_FOR_TARGET="$arg" ;;
                     *)              ALLOW_FOR_MINUTES="$arg" ;;
                 esac
             done
             ;;
    agent-browser) MODE="agent-browser"; shift
             AGENT_BROWSER_SUB="${1:-}"
             [ -n "$AGENT_BROWSER_SUB" ] && shift
             # `allow-for` carries an extra positional: either <minutes>
             # or `--stop`, with an optional trailing project token.
             # `open` carries one or more URL positionals after an
             # optional project token. All other subcommands take just
             # an optional project token in AGENT_BROWSER_TARGET. The
             # broker performs final argument validation; this layer
             # only collects the tokens.
             AGENT_BROWSER_MINUTES=""
             AGENT_BROWSER_STOP=false
             AGENT_BROWSER_TARGET=""
             AGENT_BROWSER_URLS=()
             AGENT_BROWSER_START_FLAGS=()
             AGENT_BROWSER_DOMAIN=""
             AGENT_BROWSER_DOMAIN_SET=false
             if [ "$AGENT_BROWSER_SUB" = "allow-for" ]; then
                 # Position-disambiguated parse so a project name that
                 # happens to be all digits (`boxa-123`) is not
                 # mistaken for a minutes argument. --stop is a flag;
                 # other positionals fill the minutes slot first (only
                 # when numeric, to keep the `allow-for 30 myapp` shape)
                 # and then fall through to the project-name slot.
                 ab_first_positional=true
                 for arg in "$@"; do
                     case "$arg" in
                         --stop)
                             AGENT_BROWSER_STOP=true
                             ;;
                         '')
                             ;;
                         *)
                             if [ "$ab_first_positional" = true ] \
                                 && [ -z "$AGENT_BROWSER_MINUTES" ] \
                                 && [ "$AGENT_BROWSER_STOP" != true ] \
                                 && case "$arg" in *[!0-9]*) false ;; *) true ;; esac
                             then
                                 AGENT_BROWSER_MINUTES="$arg"
                             else
                                 AGENT_BROWSER_TARGET="$arg"
                             fi
                             ab_first_positional=false
                             ;;
                     esac
                 done
                 unset ab_first_positional
             elif [ "$AGENT_BROWSER_SUB" = "open" ]; then
                 # `open` shape: [--project|-p NAME] <url> [<url>...].
                 # All positionals are URLs — bare hostnames like
                 # `localhost`, `example.com`, or `about:blank` are
                 # valid browser targets and indistinguishable from a
                 # project token by syntax alone. Explicit `--project`
                 # (`-p`) overrides the default CWD-derived container.
                 ab_expect_project=false
                 for arg in "$@"; do
                     case "$arg" in
                         '') ;;
                         --project|-p)
                             ab_expect_project=true
                             ;;
                         --project=*)
                             AGENT_BROWSER_TARGET="${arg#--project=}"
                             ;;
                         -p=*)
                             AGENT_BROWSER_TARGET="${arg#-p=}"
                             ;;
                         *)
                             if [ "$ab_expect_project" = true ]; then
                                 AGENT_BROWSER_TARGET="$arg"
                                 ab_expect_project=false
                             else
                                 AGENT_BROWSER_URLS+=("$arg")
                             fi
                             ;;
                     esac
                 done
                 if [ "$ab_expect_project" = true ]; then
                     echo "agent-browser open: --project/-p requires an argument" >&2
                     exit 2
                 fi
                 unset ab_expect_project
             elif [ "$AGENT_BROWSER_SUB" = "allow" ] || [ "$AGENT_BROWSER_SUB" = "deny" ]; then
                 # `allow [<domain>]` / `deny <domain>`. No container
                 # resolution: edits are global (one Agent-browser
                 # allowlist file shared across containers). Accept at
                 # most one positional; broker validates the shape.
                 for arg in "$@"; do
                     case "$arg" in
                         '') ;;
                         *)
                             if [ "$AGENT_BROWSER_DOMAIN_SET" = true ]; then
                                 echo "Unexpected positional for agent-browser ${AGENT_BROWSER_SUB}: $arg" >&2
                                 exit 2
                             fi
                             AGENT_BROWSER_DOMAIN="$arg"
                             AGENT_BROWSER_DOMAIN_SET=true
                             ;;
                     esac
                 done
             elif [ "$AGENT_BROWSER_SUB" = "blocked" ]; then
                 # `blocked` shape: [--project|-p NAME]. No positionals
                 # — the source of denials is per-container and resolves
                 # via -p → CWD basename → picker (broker side). Mirrors
                 # the `-p` flag from `open` so users only need to learn
                 # one shape.
                 ab_expect_project=false
                 for arg in "$@"; do
                     case "$arg" in
                         '') ;;
                         --project|-p)
                             ab_expect_project=true
                             ;;
                         --project=*)
                             AGENT_BROWSER_TARGET="${arg#--project=}"
                             ;;
                         -p=*)
                             AGENT_BROWSER_TARGET="${arg#-p=}"
                             ;;
                         *)
                             if [ "$ab_expect_project" = true ]; then
                                 AGENT_BROWSER_TARGET="$arg"
                                 ab_expect_project=false
                             else
                                 echo "Unexpected positional for agent-browser blocked: $arg" >&2
                                 exit 2
                             fi
                             ;;
                     esac
                 done
                 if [ "$ab_expect_project" = true ]; then
                     echo "agent-browser blocked: --project/-p requires an argument" >&2
                     exit 2
                 fi
                 unset ab_expect_project
             elif [ "$AGENT_BROWSER_SUB" = "start" ]; then
                 # `start` shape: [--no-open] [project]. Single known
                 # flag plus an optional project token; anything else
                 # is an error so we don't silently forward typos to
                 # the broker.
                 for arg in "$@"; do
                     case "$arg" in
                         '') ;;
                         --no-open)
                             AGENT_BROWSER_START_FLAGS+=(--no-open)
                             ;;
                         -*)
                             echo "Unknown flag for agent-browser start: $arg" >&2
                             exit 2
                             ;;
                         *)
                             if [ -z "$AGENT_BROWSER_TARGET" ]; then
                                 AGENT_BROWSER_TARGET="$arg"
                             else
                                 echo "Unexpected positional for agent-browser start: $arg" >&2
                                 exit 2
                             fi
                             ;;
                     esac
                 done
             else
                 AGENT_BROWSER_TARGET="${1:-}"
             fi
             ;;
    mcp)       MODE="mcp"; shift
             # Capture the subcommand and forward all remaining args verbatim
             # to scripts/mcp-cli.sh, which owns final validation. boxa mcp
             # is a host-side command and must not resolve a container here —
             # read-only commands run without Docker.
             MCP_SUB="${1:-}"
             [ -n "$MCP_SUB" ] && shift
             MCP_ARGS=("$@")
             ;;
    cursor)    MODE="cursor";     shift; CURSOR_TARGET="${1:-}" ;;
    code)      MODE="code";       shift; CODE_TARGET="${1:-}" ;;
    ssh-config) MODE="ssh-config"; shift; SSH_CONFIG_ACTION="${1:-}" ;;
    clip)      MODE="clip";      shift ;;
    claude-token) MODE="claude-token"; shift ;;
    build)     MODE="build";     shift ;;
    update)    MODE="update";    shift ;;
    doctor)    MODE="doctor";    shift; DOCTOR_ARGS=("$@") ;;
    dns-install)   MODE="dns-install";   shift ;;
    dns-status)    MODE="dns-status";    shift ;;
    dns-uninstall) MODE="dns-uninstall"; shift ;;
    uninstall) MODE="uninstall"; shift ;;
    prune)     MODE="prune";     shift; PRUNE_ALL=false
               [[ "${1:-}" == "--all" ]] && PRUNE_ALL=true
               ;;
    sync-skills) MODE="sync-skills"; shift ;;
    *)         MODE="auto" ;;
esac

# --- boxa ls ---------------------------------------------------------------

if [ "$MODE" = "ls" ]; then
    list_running_containers
    exit 0
fi

# --- boxa mem [project|path] -----------------------------------------------

if [ "$MODE" = "mem" ]; then
    _boxa::mem_report "${MEM_TARGET:-}"
    exit $?
fi

# --- boxa build [flags] ----------------------------------------------------

# --- boxa clip -- grab clipboard image for container use -------------------

if [ "$MODE" = "clip" ]; then
    exec "$BOXA_DIR/scripts/clip-image.sh"
fi

# --- boxa sync-skills -- sync host skills to all running containers --------

if [ "$MODE" = "sync-skills" ]; then
    # Obsolete: ~/.claude is now bind-mounted directly into every container
    # (see docs/adr/0002), so host-side changes to skills/ are immediately
    # visible without any sync step.
    echo "Skills are now live-shared via the host bind mount — no sync needed."
    echo "Drop new skills into ~/.claude/skills/ and they appear in every running boxa instantly."
    exit 0
fi

if [ "$MODE" = "build" ]; then
    exec "$BOXA_DIR/build.sh" "$@"
fi

# --- boxa claude-token -----------------------------------------------------

if [ "$MODE" = "claude-token" ]; then
    claude_token_file="$HOME/.config/boxa/claude-token"
    if ! command -v claude &>/dev/null; then
        echo "Error: 'claude' command not found. Install Claude Code first:"
        echo "  curl -fsSL https://claude.ai/install.sh | bash"
        exit 1
    fi
    if [ -f "$claude_token_file" ]; then
        printf '\033[1;33m==> Token already exists at %s. Regenerate? [y/N] \033[0m' "$claude_token_file"
        read -r answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            echo "Kept existing token."
            exit 0
        fi
    fi
    mkdir -p "$HOME/.config/boxa"
    echo ""
    echo "This will open an interactive Claude setup-token session."
    echo "After authentication, the token will be printed to the screen."
    echo "Copy the token value, then paste it when prompted."
    echo ""
    echo "Press Enter to launch claude setup-token..."
    read -r
    claude setup-token
    echo ""
    printf "Paste the token value here: "
    read -r token_value
    if [ -n "$token_value" ]; then
        printf '%s\n' "$token_value" > "$claude_token_file"
        chmod 600 "$claude_token_file"
        echo "Claude token saved to $claude_token_file"
        echo "Restart your boxa containers to use the new token."
    else
        echo "No token provided. Run 'boxa claude-token' to try again."
        exit 1
    fi
    exit 0
fi

# --- boxa update -----------------------------------------------------------

if [ "$MODE" = "update" ]; then
    # Re-exec with updated script after pull (skip pull on second run)
    if [ "${BOXA_UPDATE_PULLED:-}" != "1" ]; then
        echo "Updating boxa..."
        pull_output=$(git -C "$BOXA_DIR" pull --ff-only origin main 2>&1)
        echo "$pull_output"
        if ! echo "$pull_output" | grep -q "Already up to date"; then
            echo "Re-running with updated script..."
            BOXA_UPDATE_PULLED=1 exec "$BOXA_DIR/docker-run.sh" update "$@"
        fi
    fi

    # Offer Claude token setup only if neither host OAuth credentials nor a token file exist
    claude_token_file="$HOME/.config/boxa/claude-token"
    if [ ! -f "$claude_token_file" ] \
       && [ ! -f "$HOME/.claude/.credentials.json" ] \
       && command -v claude &>/dev/null; then
        echo ""
        printf '\033[1;33m==> Claude Code token not configured. Run "boxa claude-token" to avoid daily re-login. \033[0m\n'
    fi

    # Resolver drop-in self-heal — idempotent; brings the host resolver
    # drop-in forward on every update, including the "already up to date" path.
    _boxa::self_heal_resolver_drop_in

    # Host-provisioning self-heal (ADR 0017). install.sh is the canonical
    # creator; `boxa update` brings existing installs forward by running the
    # SAME shared registry of unconditional (category-A) provisioning steps on
    # EVERY invocation — allow-for host state, the agent-browser helpers /
    # host-state / upstream skill, the boxa skill, the mkcert binary, the
    # allowlist example, and shell completions. `--quiet-if-noop` keeps a
    # steady-state run silent: only a real provisioning action or a warning
    # surfaces in the update log. This single shared seam is what keeps install
    # / update / `boxa doctor` from drifting (the bug ADR 0017 fixes).
    # shellcheck source=lib/provisioning.sh
    source "$BOXA_DIR/lib/provisioning.sh"
    boxa::run_provisioning repair-a || true
    if [ "${#BOXA_PROVISIONING_FAILED[@]}" -gt 0 ]; then
        printf '\033[1;33m==> Some provisioning steps need attention: %s. Run "boxa doctor" for details.\033[0m\n' \
            "${BOXA_PROVISIONING_FAILED[*]}"
    fi

    # MCP onboarding (ADR 0013) — an elective (category-B) step, now run on
    # EVERY update (moved out of the post-pull gate, ADR 0017 § 4). Its
    # seen/dismissed marker keeps it quiet once decided, so always-running it
    # never re-nags; a fresh eligible install still gets the one-time offer
    # regardless of whether the repo changed.
    if [ -x "$BOXA_DIR/scripts/ensure-mcp-onboarding.sh" ]; then
        "$BOXA_DIR/scripts/ensure-mcp-onboarding.sh" --quiet-if-noop || true
    fi

    if [ "${BOXA_UPDATE_PULLED:-}" = "1" ]; then
        # HTTPS upgrade prompt (ADR 0008 Phase 6). Offered exactly once per
        # install: a user who declines flips `optout=true` in https.conf and
        # the prompt never fires again. A user who accepts ends up with
        # `active=true`, all running projects' routes rewritten to websecure,
        # and `boxa_traefik` recreated with the HTTPS entrypoints — every
        # state change is gated on a single UAC (Windows trust install).
        #
        # We only prompt on an interactive TTY: non-interactive `boxa update`
        # (e.g. from a CI cron) leaves https.conf untouched so a later
        # interactive update still gets the chance to ask.
        if ! boxa::https_active \
            && ! boxa::https_optout \
            && [ -t 0 ] && [ -t 1 ]; then
            echo ""
            echo -e "\033[1;36m==> Boxa can now serve every project over HTTPS with a locally-trusted cert.\033[0m"
            echo "    Enabling this:"
            echo "      - installs a mkcert-managed root CA into your host trust stores"
            echo "        (Linux/macOS native, plus Windows on WSL2 — fires UAC once)"
            echo "      - re-emits every existing route file with the websecure entrypoint"
            echo "      - recreates boxa_traefik with the HTTPS listener on :443"
            echo "    Declining keeps boxa HTTP-only; you won't be asked again on subsequent updates."
            echo "    (Run 'boxa dns-install --enable-https' later to opt in.)"
            echo ""
            ans=""
            read -r -p "Run HTTPS upgrade now? [Y/n] " ans || ans=""
            case "$ans" in
                ""|y|Y|yes|YES)
                    # Single source of truth for the upgrade sequence —
                    # see _boxa::run_https_upgrade. Both this prompt and
                    # the standalone `boxa dns-install --enable-https`
                    # command call it, so the user lands in the same
                    # consistent state regardless of how the upgrade got
                    # triggered.
                    _boxa::run_https_upgrade || true
                    ;;
                *)
                    echo "Skipping HTTPS upgrade. Run 'boxa dns-install --enable-https' later if you change your mind."
                    if ! boxa::write_https_field optout true; then
                        echo -e "\033[1;33mWARN: failed persisting opt-out to https.conf; next update may ask again.\033[0m"
                    fi
                    ;;
            esac
        fi
        # (MCP onboarding moved to the always-run self-heal section above,
        # ADR 0017 § 4 — it no longer depends on a repo change.)
        echo "Rebuilding image..."
        exec "$BOXA_DIR/build.sh" "$@"
    else
        echo "No changes, skipping rebuild."
    fi
    exit 0
fi

# --- boxa doctor -----------------------------------------------------------

if [ "$MODE" = "doctor" ]; then
    # Repeatable host-provisioning repair, independent of any repo change
    # (ADR 0017 § 3). Default: silently repair every unconditional (category-A)
    # step and REPORT every elective (category-B) step that is missing or was
    # declined — never mutating an elective. `--fix` repairs electives too: all
    # of them, or only the named step ids. Steps request sudo only at the moment
    # they need it (the ensure-*.sh scripts use `sudo -n` internally), so there
    # is no upfront prompt.
    # shellcheck source=lib/provisioning.sh
    source "$BOXA_DIR/lib/provisioning.sh"

    # Parse `[--fix [step…]]`.
    DOCTOR_FIX=false
    DOCTOR_FIX_STEPS=()
    for _arg in "${DOCTOR_ARGS[@]:-}"; do
        [ -z "$_arg" ] && continue
        case "$_arg" in
            --fix) DOCTOR_FIX=true ;;
            -*)
                echo "boxa doctor: unknown flag '$_arg'" >&2
                echo "Usage: boxa doctor [--fix [step…]]" >&2
                exit 2 ;;
            *)
                if $DOCTOR_FIX; then
                    DOCTOR_FIX_STEPS+=("$_arg")
                else
                    echo "boxa doctor: unexpected argument '$_arg' (step ids require --fix)" >&2
                    exit 2
                fi ;;
        esac
    done

    _doctor_print_summary() {
        echo ""
        echo "=== boxa doctor summary ==="
        if [ "${#BOXA_PROVISIONING_REPAIRED[@]}" -gt 0 ]; then
            echo "Repaired:"
            for _step in "${BOXA_PROVISIONING_REPAIRED[@]}"; do echo "  - $_step"; done
        fi
        if [ "${#BOXA_PROVISIONING_OK[@]}" -gt 0 ]; then
            echo "Already OK:"
            for _step in "${BOXA_PROVISIONING_OK[@]}"; do echo "  - $_step"; done
        fi
        if [ "${#BOXA_PROVISIONING_SKIPPED[@]}" -gt 0 ]; then
            echo "Skipped (no runnable script):"
            for _step in "${BOXA_PROVISIONING_SKIPPED[@]}"; do echo "  - $_step"; done
        fi
        # Environment prerequisites are diagnose-only (ADR 0017 § 2, category C):
        # report what is missing with the exact remediation command; never fix.
        if [ "${#BOXA_PROVISIONING_PREREQ_MISSING[@]}" -gt 0 ]; then
            echo "Missing prerequisites (boxa cannot fix these for you):"
            for _step in "${BOXA_PROVISIONING_PREREQ_MISSING[@]}"; do
                echo "  - $_step"
                echo "      $(boxa::prereq_remedy "$_step")"
            done
        fi
    }

    if $DOCTOR_FIX; then
        # Repair mode. With step ids: repair exactly those. Without: repair all
        # unconditional steps plus every elective that was never decided.
        if [ "${#DOCTOR_FIX_STEPS[@]}" -gt 0 ]; then
            echo "Running boxa doctor --fix ${DOCTOR_FIX_STEPS[*]}..."
            echo ""
            # Capture the real status in an errexit-safe way: `set -e` is active
            # (line 15), so a bare non-zero call would abort before we read $?,
            # and `if ! cmd` would make $? the negation (always 0), masking rc 3
            # (unknown id). `|| _rc=$?` is both errexit-safe and rc-preserving.
            _rc=0
            boxa::run_provisioning fix "${DOCTOR_FIX_STEPS[@]}" || _rc=$?
            if [ "$_rc" -ne 0 ]; then
                if [ "$_rc" -eq 3 ]; then
                    echo "" >&2
                    echo "Valid step ids:" >&2
                    for _entry in "${BOXA_PROVISIONING_STEPS[@]}"; do
                        echo "  - ${_entry%%|*}" >&2
                    done
                fi
                exit "$_rc"
            fi
        else
            echo "Running boxa doctor --fix (unconditional + missing elective steps)..."
            echo ""
            boxa::run_provisioning fix
        fi
        _doctor_print_summary
        if [ "${#BOXA_PROVISIONING_MISSING[@]}" -gt 0 ]; then
            echo "Still not configured after --fix (the repair did not resolve these):"
            for _step in "${BOXA_PROVISIONING_MISSING[@]}"; do echo "  - $_step"; done
        fi
        if [ "${#BOXA_PROVISIONING_DECLINED[@]}" -gt 0 ]; then
            echo "Left as declined (run 'boxa doctor --fix <step>' to re-offer):"
            for _step in "${BOXA_PROVISIONING_DECLINED[@]}"; do echo "  - $_step"; done
        fi
    else
        # Default: repair unconditional steps + report electives in one pass.
        echo "Running boxa doctor (repairing unconditional host provisioning)..."
        echo ""
        boxa::run_provisioning default
        _doctor_print_summary
        if [ "${#BOXA_PROVISIONING_MISSING[@]}" -gt 0 ]; then
            echo "Not configured (elective — run the command to set up):"
            for _step in "${BOXA_PROVISIONING_MISSING[@]}"; do
                echo "  - $_step    →  boxa doctor --fix $_step"
            done
        fi
        if [ "${#BOXA_PROVISIONING_DECLINED[@]}" -gt 0 ]; then
            echo "Declined earlier (run the command to enable):"
            for _step in "${BOXA_PROVISIONING_DECLINED[@]}"; do
                echo "  - $_step    →  boxa doctor --fix $_step"
            done
        fi
    fi

    if [ "${#BOXA_PROVISIONING_FAILED[@]}" -gt 0 ]; then
        echo ""
        echo "Failed:"
        for _step in "${BOXA_PROVISIONING_FAILED[@]}"; do echo "  - $_step"; done
        echo ""
        echo "One or more provisioning steps failed; see output above."
        exit 1
    fi
    # A missing prerequisite is a non-zero signal even though doctor cannot fix
    # it — scripts/CI should notice the host is not ready.
    if [ "${#BOXA_PROVISIONING_PREREQ_MISSING[@]}" -gt 0 ]; then
        echo ""
        echo "Host provisioning is OK, but prerequisites above need your action."
        exit 1
    fi
    # Under --fix, an elective that is STILL missing after its repair ran means
    # the requested fix did not take effect (e.g. non-interactive MCP onboarding)
    # — surface it as a failure. A missing elective in the default (report) flow
    # is expected and stays exit 0.
    if $DOCTOR_FIX && [ "${#BOXA_PROVISIONING_MISSING[@]}" -gt 0 ]; then
        echo ""
        echo "Some requested fixes did not take effect; see above."
        exit 1
    fi
    echo ""
    echo "Host provisioning is healthy."
    exit 0
fi

# --- boxa uninstall --------------------------------------------------------

if [ "$MODE" = "uninstall" ]; then
    # Forward any flags (currently just --purge-ca) through to build.sh,
    # which owns the actual uninstall lifecycle (full_reset + dns-install
    # uninstall + optional CA purge + image / network / config cleanup).
    # Ordering invariant: archive OOM evidence synchronously before build.sh
    # stops and removes the Containers needed to correlate those events.
    if [ -x "$BOXA_DIR/scripts/sweep-oom-events.sh" ]; then
        "$BOXA_DIR/scripts/sweep-oom-events.sh" || true
    fi
    exec "$BOXA_DIR/build.sh" --uninstall "$@"
fi

# --- boxa dns-install / dns-status / dns-uninstall -------------------------

if [ "$MODE" = "dns-install" ]; then
    # Special-case the HTTPS state changes — they need Traefik + route
    # file orchestration that lives in docker-run.sh (bootstrap_traefik,
    # apply_port_routes). Routing through the orchestration helpers makes
    # the standalone `boxa dns-install --enable-https` end in the same
    # consistent state as the `boxa update` prompt path. The default DNS
    # resolver setup still execs through unchanged.
    case " $* " in
        *' --enable-https '*)
            _boxa::run_https_upgrade
            exit $?
            ;;
        *' --disable-https '*)
            _boxa::run_https_downgrade
            exit $?
            ;;
    esac
    exec "$BOXA_DIR/scripts/dns-install.sh" install "$@"
fi

if [ "$MODE" = "dns-status" ]; then
    exec "$BOXA_DIR/scripts/dns-install.sh" status "$@"
fi

if [ "$MODE" = "dns-uninstall" ]; then
    exec "$BOXA_DIR/scripts/dns-install.sh" uninstall "$@"
fi

# --- boxa prune ------------------------------------------------------------

if [ "$MODE" = "prune" ]; then
    if [ "${PRUNE_ALL:-false}" = true ]; then
        echo "=== Pruning ALL Docker build cache ==="
        docker builder prune --all -f
    else
        # Calculate reserve from image size + 2GB margin
        IMAGE="$BRAND_IMAGE"
        RESERVE="10gb"
        if docker image inspect "$IMAGE" >/dev/null 2>&1; then
            SIZE_STR=$(docker images "$IMAGE" --format '{{.Size}}')
            SIZE_NUM=$(echo "$SIZE_STR" | grep -oP '^[\d.]+')
            SIZE_UNIT=$(echo "$SIZE_STR" | grep -oP '[A-Z]+$')
            if [ "$SIZE_UNIT" = "GB" ]; then
                RESERVE="$(echo "$SIZE_NUM + 2" | bc | awk '{printf "%d\n", $1 + ($1 != int($1))}')gb"
            elif [ "$SIZE_UNIT" = "MB" ]; then
                RESERVE="$(echo "$SIZE_NUM / 1024 + 2" | bc | awk '{printf "%d\n", $1 + ($1 != int($1))}')gb"
            fi
        fi
        echo "=== Pruning old Docker build cache (reserving $RESERVE) ==="
        docker buildx prune --reserved-space "$RESERVE" -f
    fi
    docker image prune -f
    exit 0
fi

# --- boxa cursor [name] ---------------------------------------------------

if [ "$MODE" = "cursor" ]; then
    attach_ide cursor "${CURSOR_TARGET:-}"
    exit 0
fi

# --- boxa code [name] ----------------------------------------------------

if [ "$MODE" = "code" ]; then
    attach_ide code "${CODE_TARGET:-}"
    exit 0
fi

# --- boxa port <port> ------------------------------------------------------

if [ "$MODE" = "port" ]; then
    if [ -z "${PORT_NUM:-}" ]; then
        echo "Usage: boxa port <port>" >&2
        exit 1
    fi

    if ! [[ "$PORT_NUM" =~ ^[0-9]+$ ]]; then
        echo "Port must be a number." >&2
        exit 1
    fi

    # Persist to default-ports.conf (deduplicated)
    ports_file="$HOME/.config/boxa/default-ports.conf"
    mkdir -p "$HOME/.config/boxa"
    touch "$ports_file"
    grep -qxF "$PORT_NUM" "$ports_file" 2>/dev/null || echo "$PORT_NUM" >> "$ports_file"

    # Apply to all running containers
    running=$(docker ps --filter "name=^boxa-" --format '{{.Names}}' | filter_user_containers)
    if [ -z "$running" ]; then
        echo "Port saved to default-ports.conf. No running containers."
        exit 0
    fi

    mkdir -p "$TRAEFIK_CONFIG_DIR"
    while IFS= read -r container; do
        [ -z "$container" ] && continue
        apply_port_routes "$container"
    done <<< "$running"

    # Print summary
    echo "Route added to all running containers:"
    scheme="$(boxa::url_scheme)"
    while IFS= read -r container; do
        [ -z "$container" ] && continue
        local_project="${container#boxa-}"
        echo "  ${scheme}://$(boxa::route_host_display "$local_project" "$PORT_NUM") → ${container}:${PORT_NUM}"
    done <<< "$running"
    exit 0
fi

# --- boxa ports ------------------------------------------------------------

if [ "$MODE" = "ports" ]; then
    PORTS_SHOW_ALL=false
    PORTS_SHOW_EXTERNAL=false
    PORTS_MACHINE=false
    for arg in "$@"; do
        case "$arg" in
            --all)      PORTS_SHOW_ALL=true ;;
            --external) PORTS_SHOW_EXTERNAL=true ;;
            -m|--machine-readable) PORTS_MACHINE=true ;;
            -h|--help) show_command_help ports ;;
            *) echo "Unknown flag: $arg" >&2; exit 2 ;;
        esac
    done

    if [ ! -d "$TRAEFIK_CONFIG_DIR" ] || [ -z "$(ls -A "$TRAEFIK_CONFIG_DIR" 2>/dev/null)" ]; then
        [ "$PORTS_MACHINE" = false ] && echo "No active port routes."
        exit 0
    fi

    # Bucket registered route filenames by container. Filename format is
    # `<container>-<port>.yml` (see apply_port_routes); split off the
    # trailing -<port>.
    declare -A PORTS_BY_CONTAINER=()
    for f in "$TRAEFIK_CONFIG_DIR"/*.yml; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .yml)"
        port="${base##*-}"
        container="${base%-*}"
        { [ -n "$container" ] && [ -n "$port" ]; } || continue
        PORTS_BY_CONTAINER["$container"]+="$port "
    done

    if [ "${#PORTS_BY_CONTAINER[@]}" -eq 0 ]; then
        [ "$PORTS_MACHINE" = false ] && echo "No active port routes."
        exit 0
    fi

    any_output=false
    scheme="$(boxa::url_scheme)"
    for container in $(printf '%s\n' "${!PORTS_BY_CONTAINER[@]}" | sort); do
        running=false
        if docker ps --filter "name=^${container}$" --format '{{.ID}}' | grep -q .; then
            running=true
        fi
        if [ "$running" = false ] && [ "$PORTS_SHOW_ALL" = false ]; then
            continue
        fi

        # shellcheck disable=SC2206  # intentional word-split: space-joined ports
        routed_ports=(${PORTS_BY_CONTAINER[$container]})
        mapfile -t routed_ports < <(printf '%s\n' "${routed_ports[@]}" | sort -un)

        probe_failed=false
        if [ "$running" = true ] && [ "$PORTS_SHOW_ALL" = false ]; then
            if listening_output=$(list_listening_ports_in_container "$container"); then
                if [ -n "$listening_output" ]; then
                    mapfile -t listening_ports <<< "$listening_output"
                    declare -A listen_set=()
                    for p in "${listening_ports[@]}"; do listen_set["$p"]=1; done
                    filtered=()
                    for p in "${routed_ports[@]}"; do
                        [ "${listen_set[$p]:-0}" = 1 ] && filtered+=("$p")
                    done
                    routed_ports=("${filtered[@]}")
                    unset listen_set
                else
                    # Probe succeeded, container has zero LISTEN ports.
                    # Hide the empty group so the default view stays honest
                    # about "nothing reachable right now".
                    routed_ports=()
                fi
            else
                # Probe failed (docker exec hung/erroreded). Falling back
                # to "show all registered routes" so we never silently
                # suppress URLs the user might still reach — the header is
                # annotated below so the listing's unfiltered status is
                # visible.
                probe_failed=true
            fi
        fi

        [ "${#routed_ports[@]}" -eq 0 ] && continue

        any_output=true
        project="${container#boxa-}"

        if [ "$PORTS_MACHINE" = true ]; then
            for p in "${routed_ports[@]}"; do
                local_url="${scheme}://$(boxa::route_host_display "$project" "$p")"
                if [ "$PORTS_SHOW_EXTERNAL" = true ]; then
                    ext_url="${scheme}://${p}.${project}.127.0.0.1.$(boxa::external_provider)"
                    printf '%s\t%s\t%s\t%s\n' "$container" "$p" "$local_url" "$ext_url"
                else
                    printf '%s\t%s\t%s\n' "$container" "$p" "$local_url"
                fi
            done
            continue
        fi

        echo
        if [ "$running" = false ]; then
            echo "=== ${container} (not running) ==="
        elif [ "$probe_failed" = true ]; then
            echo "=== ${container} (probe failed — listening filter skipped) ==="
        else
            echo "=== ${container} ==="
        fi

        {
            if [ "$PORTS_SHOW_EXTERNAL" = true ]; then
                printf 'PORT\tURL\tEXTERNAL URL\n'
            else
                printf 'PORT\tURL\n'
            fi
            for p in "${routed_ports[@]}"; do
                local_url="${scheme}://$(boxa::route_host_display "$project" "$p")"
                if [ "$PORTS_SHOW_EXTERNAL" = true ]; then
                    ext_url="${scheme}://${p}.${project}.127.0.0.1.$(boxa::external_provider)"
                    printf '%s\t%s\t%s\n' "$p" "$local_url" "$ext_url"
                else
                    printf '%s\t%s\n' "$p" "$local_url"
                fi
            done
        } | column -t -s "$(printf '\t')"
    done

    if [ "$any_output" = false ] && [ "$PORTS_MACHINE" = false ]; then
        if [ "$PORTS_SHOW_ALL" = false ]; then
            echo "No listening ports on running boxa containers."
            echo "Use 'boxa ports --all' to list every registered route."
        else
            echo "No active port routes."
        fi
    fi
    exit 0
fi

# --- boxa connect <target> <port> [local-port] [--from source] -------------

if [ "$MODE" = "connect" ]; then
    if [ "$#" -eq 0 ]; then
        running="$(list_boxa_container_names)"
        if [ -z "$running" ]; then
            echo "No running boxa containers." >&2
            exit 1
        fi

        SOURCE_CONTAINER=$(printf '%s\n' "$running" | picker::one --prompt "Source boxa: ") || exit 1
        SOURCE_PROJECT="${SOURCE_CONTAINER#boxa-}"

        target_candidates=$(printf '%s\n' "$running" | grep -vx "$SOURCE_CONTAINER" || true)
        if [ -z "$target_candidates" ]; then
            echo "No other running boxa containers to connect." >&2
            exit 1
        fi

        TARGET_CONTAINERS=$(printf '%s\n' "$target_candidates" | picker::many --prompt "Target boxaes: ") || exit 1

        service_rows=""
        while IFS= read -r target_container; do
            [ -n "$target_container" ] || continue
            discovered=$(discover_published_tcp_services "$target_container")
            [ -n "$discovered" ] && service_rows=$(printf '%s\n%s' "$service_rows" "$discovered")
        done <<< "$TARGET_CONTAINERS"
        service_rows=$(printf '%s\n' "$service_rows" | grep -v '^$' | sort -u || true)

        if [ -z "$service_rows" ]; then
            echo "No published TCP ports found in selected target boxaes." >&2
            echo "Only compose services with 'ports:' can be connected across boxaes." >&2
            exit 1
        fi

        service_choices=$(while IFS=$'\t' read -r target_project _target_container inner_name host_port private_port; do
            printf '%s / %s  %s->%s/tcp\n' \
                "$target_project" "$inner_name" "$host_port" "$private_port"
        done <<< "$service_rows")

        SELECTED_SERVICES=$(printf '%s\n' "$service_choices" | picker::many --prompt "Services to connect: ") || exit 1

        mkdir -p "$CONNECT_CONFIG_DIR"
        config_file="$(connection_config_file "$SOURCE_PROJECT")"
        touch "$config_file"

        echo "Connections for ${SOURCE_CONTAINER}:"
        while IFS= read -r display; do
            [ -n "${display:-}" ] || continue
            matched=$(while IFS=$'\t' read -r row_target_project row_target_container row_inner_name row_host_port row_private_port; do
                row_display=$(printf '%s / %s  %s->%s/tcp' "$row_target_project" "$row_inner_name" "$row_host_port" "$row_private_port")
                if [ "$row_display" = "$display" ]; then
                    printf '%s\t%s\t%s\t%s\t%s\n' "$row_target_project" "$row_target_container" "$row_inner_name" "$row_host_port" "$row_private_port"
                    break
                fi
            done <<< "$service_rows")
            [ -n "$matched" ] || continue
            IFS=$'\t' read -r target_project target_container inner_name host_port private_port <<< "$matched"
            existing=$(awk -F '\t' -v t="$target_container" -v p="$host_port" '$2 == t && $3 == p { print $4; exit }' "$config_file")
            if [ -n "$existing" ]; then
                local_port="$existing"
            else
                local_port="$(allocate_connection_port "$SOURCE_PROJECT" "$target_container" "$host_port" "$config_file")"
            fi
            alias="${inner_name}.${target_project}.boxa"
            upsert_connection_record "$SOURCE_PROJECT" "$alias" "$target_container" "$host_port" "$local_port"
            start_container_connection "$SOURCE_CONTAINER" "$target_container" "$host_port" "$local_port" "$alias"
            printf '  %-32s 10.0.2.2:%s -> %s:%s\n' "${inner_name}.${target_project}.boxa" "$local_port" "$target_container" "$host_port"
        done <<< "$SELECTED_SERVICES"

        echo "Persisted in: $config_file"
        exit 0
    fi

    SOURCE_TOKEN=""
    POSITIONAL=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --from)
                shift
                SOURCE_TOKEN="${1:-}"
                [ -n "$SOURCE_TOKEN" ] || { echo "Usage: boxa connect <target> <port> [local-port] [--from source]" >&2; exit 1; }
                ;;
            --from=*)
                SOURCE_TOKEN="${1#--from=}"
                ;;
            -h|--help) show_command_help connect ;;
            *)
                POSITIONAL+=("$1")
                ;;
        esac
        shift || true
    done

    TARGET_TOKEN="${POSITIONAL[0]:-}"
    TARGET_PORT="${POSITIONAL[1]:-}"
    LOCAL_PORT="${POSITIONAL[2]:-}"

    if [ -z "$TARGET_TOKEN" ] || [ -z "$TARGET_PORT" ]; then
        echo "Usage: boxa connect <target> <port> [local-port] [--from source]" >&2
        exit 1
    fi
    if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]] || [ "$TARGET_PORT" -lt 1 ] || [ "$TARGET_PORT" -gt 65535 ]; then
        echo "Target port must be a number from 1 to 65535." >&2
        exit 1
    fi
    if [ -n "$LOCAL_PORT" ] && { ! [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || [ "$LOCAL_PORT" -lt 1 ] || [ "$LOCAL_PORT" -gt 65535 ]; }; then
        echo "Local port must be a number from 1 to 65535." >&2
        exit 1
    fi

    if [ -n "$SOURCE_TOKEN" ]; then
        boxa::names_from_token "$SOURCE_TOKEN"
    else
        boxa::names_from_path "$(pwd)"
    fi
    SOURCE_PROJECT="$BOXA_PROJECT_NAME"
    SOURCE_CONTAINER="$BOXA_CONTAINER_NAME"

    boxa::names_from_token "$TARGET_TOKEN"
    TARGET_PROJECT="$BOXA_PROJECT_NAME"
    TARGET_CONTAINER="$BOXA_CONTAINER_NAME"

    if ! docker ps --filter "name=^${SOURCE_CONTAINER}$" --format '{{.Names}}' | grep -qx "$SOURCE_CONTAINER"; then
        echo "Source container is not running: $SOURCE_CONTAINER" >&2
        echo "Use --from <source> when running outside the source project directory." >&2
        exit 1
    fi
    if ! docker ps --filter "name=^${TARGET_CONTAINER}$" --format '{{.Names}}' | grep -qx "$TARGET_CONTAINER"; then
        echo "Target container is not running: $TARGET_CONTAINER" >&2
        exit 1
    fi

    CONFIG_FILE="$(connection_config_file "$SOURCE_PROJECT")"
    mkdir -p "$CONNECT_CONFIG_DIR"
    touch "$CONFIG_FILE"

    if [ -z "$LOCAL_PORT" ]; then
        existing=$(awk -F '\t' -v t="$TARGET_CONTAINER" -v p="$TARGET_PORT" '$2 == t && $3 == p { print $4; exit }' "$CONFIG_FILE")
        if [ -n "$existing" ]; then
            LOCAL_PORT="$existing"
        else
            LOCAL_PORT="$(allocate_connection_port "$SOURCE_PROJECT" "$TARGET_CONTAINER" "$TARGET_PORT" "$CONFIG_FILE")"
        fi
    fi

    ALIAS="${TARGET_PROJECT}-${TARGET_PORT}"
    upsert_connection_record "$SOURCE_PROJECT" "$ALIAS" "$TARGET_CONTAINER" "$TARGET_PORT" "$LOCAL_PORT"

    start_container_connection "$SOURCE_CONTAINER" "$TARGET_CONTAINER" "$TARGET_PORT" "$LOCAL_PORT" "$ALIAS"

    echo "Connected: ${SOURCE_CONTAINER} -> ${TARGET_CONTAINER}:${TARGET_PORT}"
    echo "Use from inner Docker containers: 10.0.2.2:${LOCAL_PORT}"
    echo "Persisted in: $CONFIG_FILE"
    exit 0
fi

# --- boxa connections ------------------------------------------------------

if [ "$MODE" = "connections" ]; then
    if [ ! -d "$CONNECT_CONFIG_DIR" ] || [ -z "$(ls -A "$CONNECT_CONFIG_DIR" 2>/dev/null)" ]; then
        echo "No boxa connections."
        exit 0
    fi

    printf '%-25s %-28s %-16s %-8s %s\n' "SOURCE" "TARGET" "INNER ENDPOINT" "STATUS" "ALIAS"
    for f in "$CONNECT_CONFIG_DIR"/*.tsv; do
        [ -f "$f" ] || continue
        source_project="$(basename "$f" .tsv)"
        source_container="boxa-${source_project}"

        # Probe the source container's listeners once per file and reuse the
        # set for every record below — one docker exec per source container
        # plus a cheap membership test per record.
        source_running=false
        if docker ps --filter "name=^${source_container}$" --format '{{.ID}}' | grep -q .; then
            source_running=true
        fi

        declare -A listen_set=()
        probe_failed=false
        if [ "$source_running" = true ]; then
            if listening_output=$(list_listening_ports_in_container "$source_container"); then
                if [ -n "$listening_output" ]; then
                    while IFS= read -r listening_port; do
                        listen_set["$listening_port"]=1
                    done <<< "$listening_output"
                fi
            else
                # Probe failed (docker exec hung/errored). Surface it rather than
                # silently claiming the forward is up; records fall back to
                # "down" below since liveness could not be confirmed.
                probe_failed=true
                echo "WARNING: could not probe listeners in ${source_container}; STATUS shown as 'down'." >&2
            fi
        fi

        while IFS=$'\t' read -r alias target_container target_port local_port; do
            [ -n "${alias:-}" ] || continue
            case "$alias" in \#*) continue ;; esac

            # STATUS reflects the real state of the forward:
            #   stopped — source container is not running
            #   up      — source running and a listener holds the local port
            #   down    — source running but no listener (dead forward, or the
            #             liveness probe could not confirm it)
            if [ "$source_running" = false ]; then
                status="stopped"
            elif [ "$probe_failed" = false ] && [ -n "$local_port" ] && [ "${listen_set[$local_port]:-0}" = 1 ]; then
                status="up"
            else
                status="down"
            fi

            printf '%-25s %-28s %-16s %-8s %s\n' \
                "$source_container" "${target_container}:${target_port}" "10.0.2.2:${local_port}" "$status" "$alias"
        done < "$f"
    done
    exit 0
fi

# --- boxa stop [nazev] -----------------------------------------------------

if [ "$MODE" = "stop" ]; then
    remove_project_volumes() {
        local proj="$1"
        for suffix in "${BOXA_PROJECT_VOLUME_SUFFIXES[@]}"; do
            docker volume rm "$(boxa::volume_name "$proj" "$suffix")" > /dev/null 2>&1 || true
        done
    }

    if [ -n "$PROJECT_FILTER" ]; then
        boxa::names_from_token "$PROJECT_FILTER"
        name="$BOXA_CONTAINER_NAME"
        if docker ps -a --filter "name=^${name}$" --format '{{.ID}}' | grep -q .; then
            graceful_stop_container "$name"
            _boxa::remove_container_after_oom_sweep "$name"
            if [ "$CLEAN_VOLUMES" = true ]; then
                remove_project_volumes "$BOXA_PROJECT_NAME"
                _boxa::remove_project_route_yamls "$BOXA_PROJECT_NAME"
                _boxa::remove_project_https_artifacts "$BOXA_PROJECT_NAME"
                echo "Stopped + data removed:$name"
            else
                echo "Stopped:$name"
            fi
            stop_traefik_if_idle
            stop_dns_if_idle
            exit 0
        fi
        echo "Container $name is not running." >&2
    fi
    # No argument or container not found → interactive selection
    selected=$(pick_container "Stop container: " "with_all") || exit 1
    if [ "$selected" = "* Stop all" ]; then
        docker ps -a --filter "name=^boxa-" --format '{{.Names}}' | filter_user_containers | while IFS= read -r c; do
            proj="${c#boxa-}"
            graceful_stop_container "$c"
            _boxa::remove_container_after_oom_sweep "$c"
            if [ "$CLEAN_VOLUMES" = true ]; then
                remove_project_volumes "$proj"
                _boxa::remove_project_route_yamls "$proj"
                _boxa::remove_project_https_artifacts "$proj"
                echo "Stopped + data removed:$c"
            else
                echo "Stopped:$c"
            fi
        done
        stop_traefik_if_idle
        stop_dns_if_idle
    else
        proj="${selected#boxa-}"
        graceful_stop_container "$selected"
        _boxa::remove_container_after_oom_sweep "$selected"
        if [ "$CLEAN_VOLUMES" = true ]; then
            remove_project_volumes "$proj"
            _boxa::remove_project_route_yamls "$proj"
            _boxa::remove_project_https_artifacts "$proj"
            echo "Stopped + data removed: $selected"
        else
            echo "Stopped: $selected"
        fi
        stop_traefik_if_idle
        stop_dns_if_idle
    fi
    exit 0
fi

# --- boxa remove [nazev] ----------------------------------------------------

if [ "$MODE" = "remove" ]; then
    is_project_running() {
        docker ps --filter "name=^boxa-${1}$" --format '{{.ID}}' | grep -q .
    }

    remove_project_data() {
        local proj="$1"
        local found=false
        for suffix in "${BOXA_PROJECT_VOLUME_SUFFIXES[@]}"; do
            local vol
            vol="$(boxa::volume_name "$proj" "$suffix")"
            if docker volume inspect "$vol" > /dev/null 2>&1; then
                docker volume rm "$vol" > /dev/null
                echo "  Removed volume: $vol"
                found=true
            fi
        done
        _boxa::remove_project_route_yamls "$proj"
        _boxa::remove_project_https_artifacts "$proj"
        _boxa::remove_project_agent_browser_archives "$proj"
        if [ "$found" = false ]; then
            echo "  No volumes for project $proj." >&2
            return 1
        fi
    }

    # Find projects that have per-project volumes. The suffix-strip sed mirrors
    # BOXA_PROJECT_VOLUME_SUFFIXES — keep them in sync if a suffix is added.
    list_projects_with_volumes() {
        docker volume ls -q --filter "name=boxa-" 2>/dev/null \
            | grep -E -- "$(boxa::project_volume_regex)" \
            | sed 's/^boxa-//;s/-\(docker\|history\)$//' \
            | sort -u || true
    }

    if [ -n "$PROJECT_FILTER" ]; then
        # Legacy un-sanitized volumes (created before sanitize-end-to-end)
        # remain reachable: prefer the literal token when a matching volume
        # exists, otherwise use the sanitized form for the current convention.
        target="$PROJECT_FILTER"
        legacy_match=false
        for suffix in "${BOXA_PROJECT_VOLUME_SUFFIXES[@]}"; do
            if docker volume inspect "boxa-${PROJECT_FILTER}-${suffix}" >/dev/null 2>&1; then
                legacy_match=true
                break
            fi
        done
        if [ "$legacy_match" = false ]; then
            boxa::names_from_token "$PROJECT_FILTER"
            target="$BOXA_PROJECT_NAME"
        fi

        if is_project_running "$target"; then
            echo "Container boxa-${target} is running — stop it first." >&2
            exit 1
        fi
        echo "Removing data for project: $target"
        remove_project_data "$target"
        exit $?
    fi

    # Interactive: list projects with volumes
    projects=$(list_projects_with_volumes)
    if [ -z "$projects" ]; then
        echo "No boxa project volumes."
        exit 0
    fi

    selected=$(printf '%s\n' "$projects" \
        | picker::one --prompt "Remove project:" --first-option "* Remove all") || exit 1

    if [ "$selected" = "* Remove all" ]; then
        while IFS= read -r proj; do
            if is_project_running "$proj"; then
                echo "Container boxa-${proj} is running — skipping." >&2
                continue
            fi
            echo "Removing data for project: $proj"
            remove_project_data "$proj" || true
        done <<< "$projects"
    else
        if is_project_running "$selected"; then
            echo "Container boxa-${selected} is running — stop it first." >&2
            exit 1
        fi
        echo "Removing data for project: $selected"
        remove_project_data "$selected"
    fi
    exit 0
fi

# --- boxa blocked -----------------------------------------------------------

if [ "$MODE" = "blocked" ]; then
    containers=$(docker ps --filter "name=^boxa-" --format '{{.Names}}' | filter_user_containers)
    # NOTE: the agent-browser side (denied-hosts-global) is scoped to LIVE
    # sessions only, matching this view's current-state semantics (the
    # firewall dnsmasq log is wiped when `boxa stop` removes the container).
    # So browser_domains can be non-empty only when a container is running;
    # archived (closed-session) denials are reachable via
    # `boxa agent-browser blocked` instead.
    declare -a fw_domains=()
    if [ -n "$containers" ]; then
        # Collect queried domains from dnsmasq logs across all containers
        # then filter out domains that are already allowed (have ipset rules)
        all_queried=""
        while IFS= read -r container; do
            queried=$(docker exec -u root "$container" bash -c '
                [ -f /var/log/dnsmasq-queries.log ] || exit 0
                grep "^.*query\[A\]" /var/log/dnsmasq-queries.log \
                    | grep -oP "query\[A\] \K[^ ]+" \
                    | sort -u
            ' 2>/dev/null || true)
            [ -n "$queried" ] && all_queried=$(printf '%s\n%s' "$all_queried" "$queried")
        done <<< "$containers"
        all_queried=$(echo "$all_queried" | grep -v '^$' | sort -u)

        if [ -n "$all_queried" ]; then
            # Get list of allowed domains from dnsmasq ipset config (inside
            # first container). Allowlist is identical across containers
            # (rendered from the same allowed-domains.conf).
            first_container=$(echo "$containers" | head -1)
            allowed_domains=$(docker exec -u node "$first_container" bash -c '
                grep "^ipset=" /etc/dnsmasq.d/*.conf 2>/dev/null \
                    | grep -oP "ipset=/\K[^/]+" \
                    | sort -u
            ' 2>/dev/null || true)

            # Filter: show only domains NOT covered by allowed list
            blocked=""
            while IFS= read -r domain; do
                [ -z "$domain" ] && continue
                is_allowed=false
                while IFS= read -r allowed; do
                    [ -z "$allowed" ] && continue
                    # Check exact match or subdomain match (queried is *.allowed)
                    if [ "$domain" = "$allowed" ] || [[ "$domain" == *."$allowed" ]]; then
                        is_allowed=true
                        break
                    fi
                done <<< "$allowed_domains"
                if [ "$is_allowed" = false ]; then
                    blocked=$(printf '%s\n%s' "$blocked" "$domain")
                fi
            done <<< "$all_queried"
            blocked=$(echo "$blocked" | grep -v '^$' | sort -u)

            while IFS= read -r d; do
                [ -z "$d" ] && continue
                fw_domains+=("$d")
            done <<< "$blocked"
        fi
    fi

    # Agent-browser side: globally denied hosts across (live ∪ archived).
    # The broker emits nothing when no proxy logs exist anywhere, which is
    # the silent-fallback property ADR 0012 § acceptance #4 requires.
    declare -a browser_domains=()
    browser_global=$("$BOXA_DIR/scripts/agent-browser-broker.sh" denied-hosts-global 2>/dev/null || true)
    if [ -n "$browser_global" ]; then
        while IFS= read -r d; do
            [ -z "$d" ] && continue
            browser_domains+=("$d")
        done <<< "$browser_global"
    fi

    if [ "${#fw_domains[@]}" -eq 0 ] && [ "${#browser_domains[@]}" -eq 0 ]; then
        if [ -z "$containers" ]; then
            # Preserve today's behaviour: nothing to scan, nothing to show.
            echo "No running boxa containers."
        else
            echo "No blocked domains."
        fi
        exit 0
    fi

    # Build the unified row set: `[fw]     <host>` and `[browser] <host>`.
    # Fixed-width tag column so the two layers line up — `[browser]` is
    # 9 chars, `[fw]` pads to the same width via printf's `%-9s`. The
    # tag prefix renders even when only one layer has rows (it's part of
    # the unified-view design); the silent-fallback property required by
    # ADR 0012 § acceptance #4 is satisfied by NOT emitting an empty
    # browser section or a "agent-browser: none" header — never by
    # changing per-row formatting.
    declare -a unified_rows=()
    for d in "${fw_domains[@]}"; do
        unified_rows+=("$(printf '%-9s %s' '[fw]' "$d")")
    done
    for d in "${browser_domains[@]}"; do
        unified_rows+=("$(printf '%-9s %s' '[browser]' "$d")")
    done

    # Sort tag-then-host: the fixed-width prefix means a plain sort already
    # clusters by layer (`[browser]` < `[fw]` lexically), then by host
    # within each cluster.
    mapfile -t unified_rows < <(printf '%s\n' "${unified_rows[@]}" | sort)

    # First-options are per-layer (ADR 0012 § acceptance #3): only render
    # `* Allow all firewall` when fw has rows, only render
    # `* Allow all browser` when browser has rows. Both render when both
    # do; one when one does; neither in the both-empty case (already
    # short-circuited above).
    declare -a first_opts=()
    [ "${#fw_domains[@]}"     -gt 0 ] && first_opts+=(--first-option "* Allow all firewall")
    [ "${#browser_domains[@]}" -gt 0 ] && first_opts+=(--first-option "* Allow all browser")

    selected=$(printf '%s\n' "${unified_rows[@]}" \
        | picker::many \
            --prompt "Allow domain:" \
            --header "Tab/Shift-Tab to mark · Enter to confirm   (or \"1,3,5\" without fzf)" \
            "${first_opts[@]}") || exit 1

    # Route each pick by its tag. Mixed multi-pick is fine — each row
    # invokes the broker for its own layer (ADR 0012 § acceptance #2).
    while IFS= read -r sel; do
        [ -z "$sel" ] && continue
        case "$sel" in
            "* Allow all firewall")
                for d in "${fw_domains[@]}"; do
                    "$0" allow "$d"
                done
                ;;
            "* Allow all browser")
                for d in "${browser_domains[@]}"; do
                    "$0" agent-browser allow "$d"
                done
                ;;
            "[fw]"*)
                # Strip the tag + padding whitespace; the remainder is the host.
                host="${sel#"[fw]"}"
                host="${host#"${host%%[![:space:]]*}"}"
                "$0" allow "$host"
                ;;
            "[browser]"*)
                host="${sel#"[browser]"}"
                host="${host#"${host%%[![:space:]]*}"}"
                "$0" agent-browser allow "$host"
                ;;
            *)
                echo "blocked: unrecognised picker selection: $sel" >&2
                ;;
        esac
    done <<< "$selected"
    exit 0
fi

# --- boxa allow-for [N] [project] [--stop] ---------------------------------
# Opens, queries, or closes an Allow-for window in one container (ADR 0009).
# In-container heavy lifting lives in /usr/local/bin/start-allow-for-window,
# teardown-allow-for-window, and show-allow-for-status; this handler is just
# argument resolution and the right docker exec.

if [ "$MODE" = "allow-for" ]; then
    # Resolve target container. Precedence: explicit token → CWD basename →
    # interactive picker. Token resolution can yield a name whose container
    # is not running (typo, stopped); fall back to the picker rather than
    # erroring, mirroring how `cursor` / `code` recover.
    if [ -n "$ALLOW_FOR_TARGET" ]; then
        boxa::names_from_token "$ALLOW_FOR_TARGET"
    else
        boxa::names_from_path "$(pwd)"
    fi
    container="$BOXA_CONTAINER_NAME"

    if ! docker ps --filter "name=^${container}$" --format '{{.Names}}' | grep -q .; then
        if [ -n "$ALLOW_FOR_TARGET" ]; then
            echo "Container ${container} is not running." >&2
        fi
        # Pick from running containers only — the docker exec below would
        # fail on a stopped one, so offering it is just a confusing dead
        # end. `pick_container` uses `docker ps -a` (legacy quirk, not in
        # scope to change), so list running containers inline instead.
        running=$(docker ps --filter "name=^boxa-" --format '{{.Names}}' | filter_user_containers)
        if [ -z "$running" ]; then
            echo "No running boxa containers." >&2
            exit 1
        fi
        container=$(printf '%s\n' "$running" | picker::one --prompt "Pick a container for allow-for: ") || exit 1
    fi

    # Probe sentinel + runtime state in one docker exec. Three outcomes:
    #
    #   absent  — no sentinel file. No window ever opened (or already
    #             cleanly torn down).
    #   exists  — sentinel present but not genuinely live: either expired
    #             (daemon never ran or died) or runtime state was wiped by
    #             `docker restart` while the timestamp is still future-dated.
    #             Either way the firewall does NOT have the harvest pool
    #             ACCEPT installed, so any "active" message would mislead.
    #   active  — future-dated AND ipset+iptables rule both present.
    #
    # The probe needs root because `ipset list -n` and `iptables -C` both
    # require CAP_NET_ADMIN. The sentinel file alone is 0644-readable, but
    # we'd still need root for the runtime check, so consolidate into one
    # exec.
    state=$(docker exec -u root "$container" sh -c '
        f=/etc/boxa-shared/.allow-for.state
        if [ ! -f "$f" ]; then
            echo absent; exit 0
        fi
        exp=$(grep -E "^expires_at=" "$f" | head -1 | cut -d= -f2-)
        if [ -z "$exp" ]; then echo exists; exit 0; fi
        now=$(date +%s)
        target=$(date -d "$exp" +%s 2>/dev/null) || { echo exists; exit 0; }
        if [ "$now" -ge "$target" ]; then echo exists; exit 0; fi
        if ipset list -n harvest-pool >/dev/null 2>&1 \
           && iptables -C OUTPUT -m set --match-set harvest-pool dst -j ACCEPT 2>/dev/null; then
            echo active
        else
            echo exists
        fi
    ' 2>/dev/null || echo absent)

    sentinel_exists=false
    sentinel_active=false
    case "$state" in
        active) sentinel_exists=true; sentinel_active=true ;;
        exists) sentinel_exists=true ;;
    esac

    # --- --stop ------------------------------------------------------------
    # `--stop` cleans up whenever any sentinel exists, including the
    # stale/expired case where the daemon failed to run. The teardown
    # script is idempotent (no-ops on missing pieces) so it's safe to
    # invoke when only some of the runtime state remains.
    if [ "$ALLOW_FOR_STOP" = true ]; then
        if [ "$sentinel_exists" != true ]; then
            echo "No allow-for window active in ${container}."
            exit 0
        fi
        docker exec -u root "$container" /usr/local/bin/teardown-allow-for-window --now
        exit $?
    fi

    # --- status ------------------------------------------------------------
    # No minutes given AND a *genuinely* live window → show status. The
    # runtime check inside `sentinel_active` is what prevents this branch
    # from lying to the user after a `docker restart` cleared the firewall
    # but the sentinel file (a bind-mount) survived. Falling through to
    # the start branch in that case is the right recovery —
    # start-allow-for-window's own runtime_state_intact() will see the
    # missing pieces and rebuild from scratch.
    if [ -z "$ALLOW_FOR_MINUTES" ] && [ "$sentinel_active" = true ]; then
        docker exec -u node "$container" /usr/local/bin/show-allow-for-status
        exit $?
    fi

    # --- start / reset-clock ----------------------------------------------
    # Default duration when none specified. start-allow-for-window
    # handles the reset-clock case (live sentinel + intact runtime) by
    # rewriting expires_at; the runtime-gone case (sentinel survived a
    # container restart) falls through to a fresh rebuild.
    minutes="${ALLOW_FOR_MINUTES:-15}"
    docker exec -u root "$container" /usr/local/bin/start-allow-for-window "$minutes" "$container"
    start_rc=$?

    # Spawn a host-side watcher to catch the pending notification when
    # the window closes (ADR 0009 Phase 3). The watcher polls until a
    # pending matching this container arrives, or until expires_at +
    # grace passes (safety net for dead daemons). On reset-clock we
    # spawn a second watcher; both poll the same glob and the
    # rename-claim in deliver_one serialises delivery.
    #
    # Only attempt this on a successful start (or reset-clock) — a
    # failed start means no sentinel exists and reading expires_at
    # would return empty.
    if [ "$start_rc" -eq 0 ] \
        && [ -d /var/log/boxa/allow-for/pending ] \
        && [ -x "$BOXA_DIR/scripts/deliver-allow-for-notification.sh" ]; then
        # Pull expires_at directly from the sentinel — single source of
        # truth, handles reset-clock (sentinel was rewritten) and fresh
        # start identically. Sentinel is 0644 so `-u node` is enough,
        # avoiding the root exec cost.
        expires_at=$(docker exec -u node "$container" sh -c '
            grep -E "^expires_at=" /etc/boxa-shared/.allow-for.state \
                | head -1 | cut -d= -f2-' 2>/dev/null) || expires_at=""
        if [ -n "$expires_at" ]; then
            detach_bg "$BOXA_DIR/scripts/deliver-allow-for-notification.sh" \
                --watch "$container" "$expires_at"
        fi
    fi
    exit "$start_rc"
fi

# --- boxa agent-browser <cmd> [project] ------------------------------------
# --- boxa mcp <subcommand> -------------------------------------------------

# Thin wrapper over scripts/mcp-cli.sh (ADR 0013). boxa mcp is a host-side
# command: --help, import (empty), list --inherited (empty) and any --json
# path run without Docker and resolve no container here. The dispatcher owns
# subcommand validation and delegates candidate-model / JSON work to the
# Python core in scripts/mcp/.

if [ "$MODE" = "mcp" ]; then
    if [ -n "$MCP_SUB" ]; then
        exec "$BOXA_DIR/scripts/mcp-cli.sh" "$MCP_SUB" "${MCP_ARGS[@]}"
    fi
    exec "$BOXA_DIR/scripts/mcp-cli.sh"
fi

# Thin wrapper over scripts/agent-browser-broker.sh — resolves the target
# container the same way `allow-for` / `cursor` / `code` do (explicit token
# → CWD basename → interactive picker), then dispatches to the broker. The
# broker holds the actual lifecycle logic (ADR 0010 § Actor 1 + Actor 2).

if [ "$MODE" = "agent-browser" ]; then
    if [ -z "$AGENT_BROWSER_SUB" ]; then
        echo "Usage: boxa agent-browser <start|stop|status|open|allow-for|allow|deny|blocked> [args]" >&2
        exit 2
    fi
    case "$AGENT_BROWSER_SUB" in
        start|stop|status|open|allow-for|allow|deny|blocked|-h|--help|help) ;;
        *)
            echo "Unknown agent-browser subcommand: $AGENT_BROWSER_SUB" >&2
            echo "Usage: boxa agent-browser <start|stop|status|open|allow-for|allow|deny|blocked> [args]" >&2
            exit 2
            ;;
    esac

    # Help stays in this dispatcher so both public forms use one text.
    case "$AGENT_BROWSER_SUB" in
        -h|--help|help)
            show_command_help agent-browser
            ;;
    esac

    # `allow [<domain>]` / `deny <domain>` are global — no container
    # resolution. Edits write to the single shared Agent-browser
    # allowlist file; the broker SIGHUPs every live proxy.
    if [ "$AGENT_BROWSER_SUB" = "allow" ] || [ "$AGENT_BROWSER_SUB" = "deny" ]; then
        if [ "$AGENT_BROWSER_SUB" = "deny" ] && [ "$AGENT_BROWSER_DOMAIN_SET" != true ]; then
            echo "Usage: boxa agent-browser deny <domain>" >&2
            exit 2
        fi
        if [ "$AGENT_BROWSER_DOMAIN_SET" = true ]; then
            exec "$BOXA_DIR/scripts/agent-browser-broker.sh" "$AGENT_BROWSER_SUB" "$AGENT_BROWSER_DOMAIN"
        fi
        exec "$BOXA_DIR/scripts/agent-browser-broker.sh" "$AGENT_BROWSER_SUB"
    fi

    # `blocked` carries its own resolution rule: explicit -p → CWD
    # basename → broker-side picker. Unlike `start`/`open`, the source
    # data (live or archived proxy.log) is meaningful even for stopped
    # containers, so we never reject on "container not running" here —
    # the broker is the gate.
    if [ "$AGENT_BROWSER_SUB" = "blocked" ]; then
        if [ -n "$AGENT_BROWSER_TARGET" ]; then
            boxa::names_from_token "$AGENT_BROWSER_TARGET"
            exec "$BOXA_DIR/scripts/agent-browser-broker.sh" blocked "$BOXA_CONTAINER_NAME"
        fi
        boxa::names_from_path "$(pwd)"
        exec "$BOXA_DIR/scripts/agent-browser-broker.sh" blocked --from-cwd "$BOXA_CONTAINER_NAME"
    fi

    if [ -n "$AGENT_BROWSER_TARGET" ]; then
        boxa::names_from_token "$AGENT_BROWSER_TARGET"
    else
        boxa::names_from_path "$(pwd)"
    fi
    container="$BOXA_CONTAINER_NAME"

    # Picker fallback only on `start` — `stop` and `status` must work
    # against a container that has already been stopped or crashed, so the
    # host Chrome and state file can still be cleaned up. The broker
    # itself surfaces "container not running" for `start`; here we only
    # interactively recover for the start path.
    if [ "$AGENT_BROWSER_SUB" = "start" ] \
        && ! docker ps --filter "name=^${container}$" --format '{{.Names}}' | grep -q .; then
        if [ -n "$AGENT_BROWSER_TARGET" ]; then
            echo "Container ${container} is not running." >&2
        fi
        running=$(docker ps --filter "name=^boxa-" --format '{{.Names}}' | filter_user_containers)
        if [ -z "$running" ]; then
            echo "No running boxa containers." >&2
            exit 1
        fi
        container=$(printf '%s\n' "$running" | picker::one --prompt "Pick a container for agent-browser: ") || exit 1
    fi

    # `allow-for` carries an extra positional (minutes or --stop) ahead
    # of the resolved container. The broker accepts both shapes; we
    # forward the captured token in the order it expects.
    if [ "$AGENT_BROWSER_SUB" = "allow-for" ]; then
        if [ "$AGENT_BROWSER_STOP" = true ]; then
            exec "$BOXA_DIR/scripts/agent-browser-broker.sh" "$AGENT_BROWSER_SUB" --stop "$container"
        fi
        if [ -z "$AGENT_BROWSER_MINUTES" ]; then
            echo "Usage: boxa agent-browser allow-for <minutes> [name]" >&2
            echo "       boxa agent-browser allow-for --stop [name]" >&2
            exit 2
        fi
        exec "$BOXA_DIR/scripts/agent-browser-broker.sh" "$AGENT_BROWSER_SUB" "$AGENT_BROWSER_MINUTES" "$container"
    fi

    if [ "$AGENT_BROWSER_SUB" = "open" ]; then
        if [ "${#AGENT_BROWSER_URLS[@]}" -eq 0 ]; then
            echo "Usage: boxa agent-browser open [--project|-p NAME] <url> [<url>...]" >&2
            exit 2
        fi
        exec "$BOXA_DIR/scripts/agent-browser-broker.sh" open "$container" "${AGENT_BROWSER_URLS[@]}"
    fi

    if [ "$AGENT_BROWSER_SUB" = "start" ]; then
        # Assemble the full argv first so the conditional flag block
        # stays out of the exec line. Avoids the `${arr[@]+...}` guard
        # gymnastics that `set -u` otherwise demands for empty arrays.
        agent_start_argv=(start)
        if [ "${#AGENT_BROWSER_START_FLAGS[@]}" -gt 0 ]; then
            agent_start_argv+=("${AGENT_BROWSER_START_FLAGS[@]}")
        fi
        agent_start_argv+=("$container")
        exec "$BOXA_DIR/scripts/agent-browser-broker.sh" "${agent_start_argv[@]}"
    fi

    exec "$BOXA_DIR/scripts/agent-browser-broker.sh" "$AGENT_BROWSER_SUB" "$container"
fi

# --- boxa allow <domain> ----------------------------------------------------

if [ "$MODE" = "allow" ]; then
    # No domain specified → list allowed domains
    if [ -z "${DOMAIN:-}" ]; then
        echo "Allowed domains (~/.config/boxa/allowed-domains.conf):"
        allowed_list=$(allowlist::read "$ALLOWLIST_HOST_FILE" | sort)
        if [ -n "$allowed_list" ]; then
            echo "$allowed_list" | while read -r d; do echo "  $d"; done
        else
            echo "  (none)"
        fi
        echo ""
        echo "Usage: boxa allow <domain>  |  boxa deny <domain>"
        echo "Note: An entry matches the domain and all of its subdomains."
        exit 0
    fi

    if allowlist::add "$ALLOWLIST_HOST_FILE" "$DOMAIN"; then
        echo "Allowed: $DOMAIN (and all subdomains)"
    else
        echo "Already allowed: $DOMAIN"
    fi

    warn_if_allow_for_active "$DOMAIN" allow
    reload_firewall_in_containers allow "$DOMAIN"
    exit 0
fi

# --- boxa deny [domain] ----------------------------------------------------

if [ "$MODE" = "deny" ]; then
    if [ ! -f "$ALLOWLIST_HOST_FILE" ] || [ -z "$(allowlist::read "$ALLOWLIST_HOST_FILE")" ]; then
        echo "No domains to remove."
        exit 0
    fi

    DENIED=""

    if [ -z "${DOMAIN:-}" ]; then
        runtime=$(allowlist::read "$ALLOWLIST_HOST_FILE" | sort)
        selected=$(printf '%s\n' "$runtime" \
            | picker::many --prompt "Remove domain:") || exit 1

        while IFS= read -r sel; do
            [ -z "$sel" ] && continue
            if allowlist::remove "$ALLOWLIST_HOST_FILE" "$sel"; then
                echo "Removed: $sel"
                DENIED+="$sel "
            fi
        done <<< "$selected"
    else
        if allowlist::remove "$ALLOWLIST_HOST_FILE" "$DOMAIN"; then
            echo "Removed: $DOMAIN"
            DENIED="$DOMAIN"
        else
            echo "Domain $DOMAIN is not in the list." >&2
            exit 1
        fi
    fi

    warn_if_allow_for_active "$DENIED" deny
    reload_firewall_in_containers deny "$DENIED"
    exit 0
fi

# --- boxa ssh-config [add|edit] ---------------------------------------------

if [ "$MODE" = "ssh-config" ]; then
    SSH_CONFIG_FILE="$HOME/.config/boxa/ssh_config"
    mkdir -p "$HOME/.config/boxa"

    case "${SSH_CONFIG_ACTION:-}" in
        add)
            printf "Host alias (e.g. rep): "
            read -r host_alias
            [ -z "$host_alias" ] && { echo "Host alias is required." >&2; exit 1; }

            printf "HostName (server address): "
            read -r hostname
            [ -z "$hostname" ] && { echo "HostName is required." >&2; exit 1; }

            printf "Port (default 22): "
            read -r port
            port="${port:-22}"

            printf "User (optional): "
            read -r ssh_user

            {
                echo ""
                echo "Host $host_alias"
                echo "    HostName $hostname"
                [ "$port" != "22" ] && echo "    Port $port"
                [ -n "$ssh_user" ] && echo "    User $ssh_user"
            } >> "$SSH_CONFIG_FILE"

            echo "Added to $SSH_CONFIG_FILE:"
            echo "  Host $host_alias → $hostname${port:+ :$port}"
            ;;
        edit)
            if [ ! -f "$SSH_CONFIG_FILE" ]; then
                touch "$SSH_CONFIG_FILE"
            fi
            "${EDITOR:-vi}" "$SSH_CONFIG_FILE"
            ;;
        *)
            # No action → show current config
            if [ -f "$SSH_CONFIG_FILE" ] && [ -s "$SSH_CONFIG_FILE" ]; then
                echo "Boxa SSH config (~/.config/boxa/ssh_config):"
                echo ""
                cat "$SSH_CONFIG_FILE"
            else
                echo "Boxa SSH config is empty."
            fi
            echo ""
            echo "Usage:"
            echo "  boxa ssh-config          Show config"
            echo "  boxa ssh-config add      Add a host interactively"
            echo "  boxa ssh-config edit     Open in \$EDITOR"
            ;;
    esac
    exit 0
fi

# --- Auto mode: create or attach ---------------------------------------------

# Parse optional flags before path
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --ssh-config) SSH_CONFIG_MOUNT=true; shift ;;
        --memory|--memory-swap)
            flag="$1"
            if [ "$#" -lt 2 ] || [[ "$2" == --* ]]; then
                echo "$flag requires a size value." >&2
                exit 1
            fi
            _boxa::parse_size "$2" >/dev/null || exit 1
            if [ "$flag" = "--memory" ]; then
                CLI_MEMORY="$2"
            else
                CLI_MEMORY_SWAP="$2"
            fi
            shift 2
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done
unset flag

if [ -d "${1:-.}" ]; then
    # Argument is a directory (or none → CWD) → create/attach mode
    PROJECT_PATH="$(realpath "${1:-.}")"
    boxa::names_from_path "$PROJECT_PATH"
    PROJECT_NAME="$BOXA_PROJECT_NAME"
    CONTAINER_NAME="$BOXA_CONTAINER_NAME"

    if docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.ID}}' | grep -q .; then
        if [ "$SSH_CONFIG_MOUNT" = true ]; then
            echo "WARNING: --ssh-config ignored — container is already running."
            echo "  To change mounts: boxa stop && boxa --ssh-config"
        fi
        # Self-heal cross-boxa forwards on attach. The connection restore
        # runs on create and on exited→restart, but not when attaching to an
        # already-running container — so a forward killed by a crashed create
        # (or a restore that never completed) would stay dead. Re-running it
        # here is idempotent: start_container_connection exits early when the
        # listener is already present, so live forwards are untouched and only
        # the dead ones are re-established.
        _boxa::converge_container_resources "$CONTAINER_NAME" "$PROJECT_PATH" \
            "$CLI_MEMORY" "$CLI_MEMORY_SWAP" || exit 1
        start_boxa_connections "$CONTAINER_NAME"
        attach_to_container "$CONTAINER_NAME"
        # exec → script ends here
    fi

    # If container exists but is exited, restart it
    if docker ps -a --filter "name=^${CONTAINER_NAME}$" --filter "status=exited" --format '{{.ID}}' | grep -q .; then
        bootstrap_traefik
        bootstrap_dns
        if restart_exited_container "$CONTAINER_NAME" "$PROJECT_PATH" \
                "$CLI_MEMORY" "$CLI_MEMORY_SWAP"; then
            attach_to_container "$CONTAINER_NAME"
            # exec → script ends here
        fi
        # restart failed → container removed, fall through to creation
    fi

    # Container not running → create new one (detached) below
else
    # Argument is not a directory → attach by name (idempotent sanitize)
    boxa::names_from_token "$1"
    CONTAINER_NAME="$BOXA_CONTAINER_NAME"
    if docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.ID}}' | grep -q .; then
        _boxa::converge_container_resources "$CONTAINER_NAME" "" \
            "$CLI_MEMORY" "$CLI_MEMORY_SWAP" || exit 1
        start_boxa_connections "$CONTAINER_NAME"   # self-heal forwards (idempotent)
        attach_to_container "$CONTAINER_NAME"
    elif docker ps -a --filter "name=^${CONTAINER_NAME}$" --filter "status=exited" --format '{{.ID}}' | grep -q .; then
        bootstrap_traefik
        bootstrap_dns
        if restart_exited_container "$CONTAINER_NAME" "" \
                "$CLI_MEMORY" "$CLI_MEMORY_SWAP"; then
            attach_to_container "$CONTAINER_NAME"
        else
            echo "Container $CONTAINER_NAME removed. Run again to create a new one." >&2
            exit 1
        fi
    else
        echo "Container $CONTAINER_NAME is not running." >&2
        selected=$(pick_container "Pick a container: ") || exit 1
        # pick_container also lists exited containers (docker ps -a); only
        # self-heal forwards when the picked container is actually running,
        # otherwise start_boxa_connections would print a misleading
        # "Failed to start connection" for a container that simply isn't up.
        if docker ps --filter "name=^${selected}$" --format '{{.ID}}' | grep -q .; then
            _boxa::converge_container_resources "$selected" "" \
                "$CLI_MEMORY" "$CLI_MEMORY_SWAP" || exit 1
            start_boxa_connections "$selected"   # self-heal forwards (idempotent)
        fi
        attach_to_container "$selected"
    fi
fi

# --- SSH agent setup (only when creating a new container) --------------------

# SSH agent recovery - try to restore agent before giving up
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    # Try keychain's saved agent info
    keychain_sh="$HOME/.keychain/$(hostname)-sh"
    if [ -f "$keychain_sh" ]; then
        # shellcheck disable=SC1090
        . "$keychain_sh"
    fi
fi

# Verify agent is alive (socket path set but socket is dead)
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ ! -S "$SSH_AUTH_SOCK" ]; then
    unset SSH_AUTH_SOCK
fi

# If still no agent, try to start one via keychain
if [ -z "${SSH_AUTH_SOCK:-}" ] && command -v keychain &>/dev/null; then
    eval "$(keychain --eval --quiet --agents ssh)"
fi

# Final fallback: start plain ssh-agent
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    echo "Starting SSH agent..."
    eval "$(ssh-agent -s)" > /dev/null
    echo "  Add your keys with: ssh-add"
fi

# Try to load default keys (non-fatal — boxa works without SSH keys)
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    if ! ssh-add -l &>/dev/null; then
        echo "SSH agent has no keys, trying to add default keys..."
        ssh-add 2>/dev/null || echo "  No SSH keys found — SSH forwarding will have no keys. Add keys with: ssh-add"
    fi
fi

# --- Bootstrap Traefik, DNS resolver & devproxy network ---------------------

bootstrap_traefik
bootstrap_dns

# Refresh the bind-mounted Docker DNS upstream file before building docker args
# (helpers defined up top, near restart_exited_container which also calls it).
write_dns_upstream_file

# --- Build docker arguments -------------------------------------------------

_boxa::resolve_resources "$PROJECT_PATH" "$CLI_MEMORY" "$CLI_MEMORY_SWAP"

memory_display="$(_boxa::format_size "$_BOXA_MEMORY_BYTES")"
if [ "$_BOXA_MEMORY_SOURCE" = "derived" ]; then
    host_memory_display="$(_boxa::format_size "$_BOXA_HOST_MEMTOTAL_BYTES")"
    memory_source="derived from $host_memory_display host RAM"
else
    memory_source="$_BOXA_MEMORY_SOURCE"
fi
if [ -n "$CLI_MEMORY" ] || [ -n "$CLI_MEMORY_SWAP" ]; then
    echo "Memory limit: $memory_display ($memory_source; one-shot only; set ~/.config/boxa/resources.conf for a durable setting)"
else
    echo "Memory limit: $memory_display ($memory_source; override in ~/.config/boxa/resources.conf)"
fi

_boxa::memory_limit_host_warning "$_BOXA_MEMORY_BYTES" "$_BOXA_HOST_MEMTOTAL_BYTES"
if [ -n "$_BOXA_HOST_MEMTOTAL_BYTES" ] \
    && _boxa::would_jointly_exhaust_host "$_BOXA_MEMORY_BYTES" "$_BOXA_HOST_MEMTOTAL_BYTES"; then
    echo "WARNING: Running boxa Containers can jointly exhaust host RAM; use the .wslconfig VM backstop."
fi

DOCKER_ARGS=(
    --hostname "$BOXA_HOSTNAME"
    --network devproxy
    --memory "$_BOXA_MEMORY_BYTES"
    --memory-swap "$_BOXA_MEMORY_SWAP_BYTES"
    # `host.docker.internal` resolution for the in-container Agent-browser
    # bridge socat (ADR 0010). No-op on Docker Desktop (the hostname is
    # built-in), required on native Linux (no built-in mapping). Uniform
    # always — keeps the bridge command identical across platforms.
    --add-host=host.docker.internal:host-gateway
    # Entrypoint needs root to set up firewall + symlinks, then drops to node
    # via runuser. See scripts/boxa-entrypoint.sh and docs/adr/0003.
    --user 0
    --cap-add=SYS_ADMIN
    --cap-add=NET_ADMIN
    --cap-add=NET_RAW
    --security-opt seccomp=unconfined
    --security-opt apparmor=unconfined
    --security-opt systempaths=unconfined
    --device=/dev/net/tun
    --device=/dev/fuse
    # Per-project volumes
    -v "${BOXA_VOL_HISTORY}:/home/node/.local/share/atuin"
    -v "${BOXA_VOL_DOCKER}:/home/node/.local/share/docker"
    # Shared volumes
    -v boxa-nvim-data:/home/node/.local/share/nvim
    -v boxa-npm-global:/usr/local/share/npm-global
    -v boxa-cursor-server:/home/node/.cursor-server
    -v boxa-vscode-server:/home/node/.vscode-server
    -e CLAUDE_CONFIG_DIR=/home/node/.claude
    -e "BOXA_PROJECT_NAME=$BOXA_PROJECT_NAME"
    -e DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=false
)

# Docker DNS upstream(s) for init-firewall.sh — bind-mounted read-only (not a
# frozen -e env var) so `docker start` restarts re-read the current value.
# write_dns_upstream_file (above) created the host file. See ADR 0015.
DOCKER_ARGS+=(-v "$DNS_UPSTREAM_HOST_FILE:$DNS_UPSTREAM_CONTAINER_FILE:ro")

# Git config from host (staging path — copied to /etc/gitconfig by entrypoint
# so VS Code/Cursor can write credential helpers without "Device busy" error)
[ -f "$HOME/.gitconfig" ] && DOCKER_ARGS+=(-v "$HOME/.gitconfig:/home/node/.gitconfig-host:ro")

# Global gitignore from host
GIT_GLOBAL_IGNORE="$HOME/.config/git/ignore"
[ -f "$GIT_GLOBAL_IGNORE" ] && DOCKER_ARGS+=(-v "$GIT_GLOBAL_IGNORE:/home/node/.config/git/ignore:ro")

# Host ~/.claude directory (RW bind mount; full sharing — see docs/adr/0002)
mkdir -p "$HOME/.claude"
DOCKER_ARGS+=(-v "$HOME/.claude:/home/node/.claude")

# Host ~/.agents directory (RO; targets of ~/.claude/skills symlinks)
[ -d "$HOME/.agents" ] && DOCKER_ARGS+=(-v "$HOME/.agents:/home/node/.agents:ro")

# Claude binaries. On Linux/WSL2 the host and container share the same OS/arch,
# so we bind-mount the host-installed Claude Code (RO) and every container
# tracks the host's version live; falls back to the image-baked version if the
# host has no Claude installed. On macOS the host binary is a Mach-O build that
# would shadow the container's Linux ELF and break every `claude` invocation
# with "exec format error", so instead we mount a shared named volume
# (boxa-mac-claude-bin) — a fresh volume auto-populates from the image-baked
# Linux binary, and `claude update` run inside any container updates it for all
# (same shared-volume pattern as boxa-npm-global).
if [ "$(uname -s 2>/dev/null || echo Unknown)" = "Darwin" ]; then
    DOCKER_ARGS+=(-v boxa-mac-claude-bin:/home/node/.local/share/claude)
else
    [ -d "$HOME/.local/share/claude" ] && DOCKER_ARGS+=(-v "$HOME/.local/share/claude:/home/node/.local/share/claude:ro")
fi

# Host ~/.codex directory (RW; Codex CLI auth + config shared with host)
mkdir -p "$HOME/.codex"
DOCKER_ARGS+=(-v "$HOME/.codex:/home/node/.codex")

# Host MCP store (ADR 0014, issue 16): the canonical boxa MCP profile +
# scoped secret stores live in ~/.config/boxa/mcp. They reach the Container
# read-only under a ROOT/boxa-mcp-gated parent chain (NOT a node-readable
# path): the entrypoint root phase chowns the parent chain to boxa-mcp 0700 so
# node cannot traverse it, the broker reads the (secret-free) profile live from
# this mount, and the root phase stages the in-scope 0600 secret files out of it
# into a boxa-mcp-private 0400 store. A plain node-readable mount would expose
# the secrets to the agent (host 0600 -> node UID), so it MUST stay gated.
# Mounted UNCONDITIONALLY: the host store is created up front (below) so the
# bind-mount is always present. Without it, importing an MCP server into a
# RUNNING Container (boxa mcp import/add creates the host store after start)
# would leave the broker with an empty in-container mount and no way to see the
# new profile until a restart — violating ADR 0014's guarantee that enable/
# disable/add take effect next session with no restart. The store is a live
# read-only mount, so a profile written on the host after start is visible to the
# broker immediately. The host dir is created as the invoking user (matching the
# other ~/.config/boxa dirs above), so no root-owned path appears; the
# entrypoint root phase gates the in-container mount to boxa-mcp 0700 regardless.
BOXA_MCP_HOST_STORE="$HOME/.config/boxa/mcp"
mkdir -p "$BOXA_MCP_HOST_STORE"
# Normalize EXISTING store perms to broker-readable BEFORE the mount (host-side).
# save_profile()/ensure_store_dir() only fix NEWLY written profiles; a store dir
# or profile created by an older version (0700/0600) or under a restrictive host
# umask (e.g. 077) would still be untraversable/unreadable by the broker, which
# runs as boxa-mcp (a different UID). The profile is NON-SECRET (ADR 0014:
# world-readable, the broker must read it), so loosening its host metadata is
# intentional. Secret files (*.secrets.json) MUST stay 0600 and are explicitly
# excluded from the file pass. Idempotent and safe when nothing exists yet.
chmod o+rx "$BOXA_MCP_HOST_STORE" 2>/dev/null \
    || echo "WARN: could not make $BOXA_MCP_HOST_STORE broker-traversable; imported MCP servers may be unreadable in the container" >&2
if [ -d "$BOXA_MCP_HOST_STORE/projects" ]; then
    chmod o+rx "$BOXA_MCP_HOST_STORE/projects" 2>/dev/null \
        || echo "WARN: could not make $BOXA_MCP_HOST_STORE/projects broker-traversable; imported project MCP servers may be unreadable in the container" >&2
fi
# Non-secret profile files -> o+r. Match profile.json and projects/*.json but
# NEVER *.secrets.json (those carry credentials and stay 0600). find prunes the
# secret files explicitly so the glob does not loosen them.
while IFS= read -r -d '' mcp_profile_file; do
    chmod o+r "$mcp_profile_file" 2>/dev/null \
        || echo "WARN: could not make $mcp_profile_file broker-readable; that imported MCP server may be unreadable in the container" >&2
done < <(find "$BOXA_MCP_HOST_STORE" -maxdepth 2 -type f \
    \( -name 'profile.json' -o \( -path "$BOXA_MCP_HOST_STORE/projects/*.json" -a ! -name '*.secrets.json' \) \) \
    -print0 2>/dev/null)
DOCKER_ARGS+=(-v "$BOXA_MCP_HOST_STORE:/run/boxa-mcp/host/boxa/mcp:ro")

# SSH config: --ssh-config uses full host config, otherwise boxa-specific config
BOXA_SSH_CONFIG="$HOME/.config/boxa/ssh_config"
if [ "$SSH_CONFIG_MOUNT" = true ]; then
    [ -f "$HOME/.ssh/config" ] && DOCKER_ARGS+=(-v "$HOME/.ssh/config:/home/node/.ssh/config:ro")
    [ -f "$HOME/.ssh/known_hosts" ] && DOCKER_ARGS+=(-v "$HOME/.ssh/known_hosts:/home/node/.ssh/known_hosts:ro")
elif [ -f "$BOXA_SSH_CONFIG" ]; then
    DOCKER_ARGS+=(-v "$BOXA_SSH_CONFIG:/home/node/.ssh/config:ro")
fi

# SSH agent forwarding (private keys never enter the container)
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    DOCKER_ARGS+=(
        -v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock"
        -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
    )
else
    SSH_WARNING="WARNING: SSH agent not available - SSH forwarding won't work inside boxa
  Ensure keychain or ssh-agent is running, then restart boxa"
fi

# Pass through API key
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
fi

# Read Claude setup-token from config file (env var wins if already set)
CLAUDE_TOKEN_FILE="$HOME/.config/boxa/claude-token"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$CLAUDE_TOKEN_FILE" ]; then
    CLAUDE_CODE_OAUTH_TOKEN="$(cat "$CLAUDE_TOKEN_FILE")"
fi
# Decide whether to inject the OAuth token, which differs by host OS:
#   macOS  — token is the PRIMARY/ALWAYS auth path. The macOS Claude app stores
#            credentials in the Keychain and DELETES ~/.claude/.credentials.json
#            on /login (anthropics/claude-code#10039), so live host↔container
#            credential sharing is impossible. ~/.claude stays a full bind mount,
#            but auth must come from the token regardless of any stray
#            .credentials.json (an accidental in-container /login or a leftover).
#   Linux/WSL2 — token is a FALLBACK only: the host's shared .credentials.json
#            wins, so inject the token solely when no host file credentials exist.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    if [ "$(uname -s 2>/dev/null || echo Unknown)" = "Darwin" ] || [ ! -f "$HOME/.claude/.credentials.json" ]; then
        DOCKER_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN")
    fi
fi
# macOS first-run hint: host login is never shared into containers there, so a
# missing token means the container fleet has no auth. Non-fatal heads-up.
if [ "$(uname -s 2>/dev/null || echo Unknown)" = "Darwin" ] \
   && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ ! -f "$CLAUDE_TOKEN_FILE" ]; then
    echo -e "\033[1;33m==> macOS: host Claude login is NOT shared into containers. Run 'boxa claude-token' once to authenticate the container fleet.\033[0m" >&2
fi

# Auto-detect NTFY_TOKEN from host's Claude hooks if not set
if [ -z "${NTFY_TOKEN:-}" ] && [ -d "$HOME/.claude/hooks" ]; then
    NTFY_TOKEN=$(grep -ohm1 'TOKEN="tk_[^"]*"' "$HOME/.claude/hooks/"*.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi

if [ -n "${NTFY_TOKEN:-}" ]; then
    DOCKER_ARGS+=(-e "NTFY_TOKEN=$NTFY_TOKEN")
fi

# Auto-detect NTFY_URL from host's Claude hooks if not set
if [ -z "${NTFY_URL:-}" ] && [ -d "$HOME/.claude/hooks" ]; then
    NTFY_URL=$(grep -ohm1 'NTFY_URL="https://[^"]*"' "$HOME/.claude/hooks/"*.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi

if [ -n "${NTFY_URL:-}" ]; then
    DOCKER_ARGS+=(-e "NTFY_URL=$NTFY_URL")
fi

# Chezmoi dotfiles repo. Precedence:
#   1. An explicit CHEZMOI_REPO in the environment always wins.
#   2. Otherwise the choice persisted by install.sh's 3-way dotfiles prompt
#      (~/.config/boxa/dotfiles.conf) is honoured — including an empty value,
#      which means the user picked "None — pure bash" and chezmoi is skipped.
#   3. With neither present, fall back to the brand default (BRAND_DOTFILES_REPO,
#      normally the "bundled" sentinel → setup-chezmoi.sh applies the bundled
#      starter locally; a URL takes the remote path; empty skips dotfiles).
# The persisted file is sourced (it sets CHEZMOI_REPO), so the `${X+set}`
# guard distinguishes "unset" from "deliberately empty".
if [ -z "${CHEZMOI_REPO+set}" ]; then
    DOTFILES_CONF="$HOME/.config/$CLI_NAME/dotfiles.conf"
    if [ -f "$DOTFILES_CONF" ]; then
        # shellcheck source=/dev/null  # user config written by install.sh
        source "$DOTFILES_CONF"
    fi
    CHEZMOI_REPO="${CHEZMOI_REPO-$BRAND_DOTFILES_REPO}"
fi
if [ -n "$CHEZMOI_REPO" ]; then
    DOCKER_ARGS+=(-e "CHEZMOI_REPO=$CHEZMOI_REPO")
fi

# Host home directory for WezTerm OSC 7 safe fallback CWD
DOCKER_ARGS+=(-e "HOST_HOME=$HOME")

# Shared firewall allowlist (host → all containers, read-only)
mkdir -p "$ALLOWLIST_HOST_DIR"
touch "$ALLOWLIST_HOST_FILE"
DOCKER_ARGS+=(-v "$ALLOWLIST_HOST_FILE:$ALLOWLIST_CONTAINER_FILE:ro")

# Harvest log directory for `boxa allow-for` (ADR 0009). Provisioned
# root:root 0755 by install.sh / `boxa update` self-heal. Mounted RW so
# the in-container root daemon can write reports; the node user (host UID
# 1000) can read but cannot delete or overwrite — that's the tamper-proof
# half of the audit invariant. Missing host dir → degrade silently here;
# `boxa allow-for` will refuse with a clear error when invoked.
if [ -d /var/log/boxa/allow-for ]; then
    DOCKER_ARGS+=(-v /var/log/boxa/allow-for:/var/log/boxa/allow-for)
fi

# Clipboard images shared directory (host → container, same ~/.clipboard-images path)
CLIPBOARD_DIR="$HOME/.clipboard-images"
mkdir -p "$CLIPBOARD_DIR"
DOCKER_ARGS+=(-v "$CLIPBOARD_DIR:/home/node/.clipboard-images")

# Mount workspace at the host's absolute path. The entrypoint creates
# $HOST_HOME as a real directory mirroring /home/node, so binding under it
# produces a real subdir whose canonical path (getcwd(2)) matches the host
# path — which is what plugin/session parity hinges on (see docs/adr/0004).
DOCKER_ARGS+=(-v "$PROJECT_PATH:$PROJECT_PATH")
DOCKER_ARGS+=(-e "BOXA_PROJECT_HOST_PATH=$PROJECT_PATH")

# --- Start detached container ------------------------------------------------

# Check that image exists locally
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Image $IMAGE not found. Build it with: boxa build" >&2
    exit 1
fi

# Print warnings just before starting container (so they're visible)
if [ -n "$SSH_WARNING" ]; then
    echo "$SSH_WARNING"
fi

# Auto-cleanup obsolete boxa-claude-bin volume (claude binaries now bind-mounted
# from host ~/.local/share/claude). Safe: docker refuses removal if any container
# still references it, in which case we leave it for the next run.
if docker volume inspect "boxa-claude-bin" >/dev/null 2>&1; then
    if docker volume rm "boxa-claude-bin" >/dev/null 2>&1; then
        echo "Removed obsolete 'boxa-claude-bin' volume (claude now bind-mounted from host)"
    fi
fi

# Auto-cleanup obsolete boxa-codex-bin volume (Codex CLI moved to
# boxa-npm-global). Safe: docker refuses removal if any container still
# references it, in which case we leave it for the next run.
if docker volume inspect "boxa-codex-bin" >/dev/null 2>&1; then
    if docker volume rm "boxa-codex-bin" >/dev/null 2>&1; then
        echo "Removed obsolete 'boxa-codex-bin' volume (Codex now lives in boxa-npm-global)"
    fi
fi

echo "Mounting project: $PROJECT_PATH ($CONTAINER_NAME)"
echo "Starting boxa..."

# Start container in background
docker run -d --name "$CONTAINER_NAME" --stop-timeout 45 "${DOCKER_ARGS[@]}" "$IMAGE" boxa-entrypoint.sh

# Confirm the container actually came up before reporting success. The root
# entrypoint (firewall verification included) runs detached; if it aborts the
# container exits and the ERROR is buried in `docker logs`. Surface it here and
# stop, instead of printing routes as if all is well and then hitting a cryptic
# "container is not running" on the exec below.
if ! wait_for_boxa_ready "$CONTAINER_NAME"; then
    exit 1
fi

# Apply default port routes
apply_port_routes "$CONTAINER_NAME"

# Show URL info
ports_file="$HOME/.config/boxa/default-ports.conf"
if [ -f "$ports_file" ] && [ -s "$ports_file" ]; then
    echo "Port routes:"
    scheme="$(boxa::url_scheme)"
    while read -r port _rest; do
        port="${port%%#*}"
        [ -z "$port" ] && continue
        echo "  ${scheme}://$(boxa::route_host_display "$PROJECT_NAME" "$port") → ${CONTAINER_NAME}:${port}"
    done < "$ports_file"
else
    echo "  Set port: boxa port <port>"
fi

# Root-context setup (firewall, gitconfig, host-home symlink, IDE server
# ownership) is handled by the entrypoint on every container start.
docker exec -u node "$CONTAINER_NAME" bash -c \
    '/usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh && /usr/local/bin/setup-claude.sh'

warn_if_dns_broken "$CONTAINER_NAME"

start_boxa_connections "$CONTAINER_NAME"

# Attach first interactive session
set_tab_title "$PROJECT_NAME"
exec docker exec -it -u node -w "$PROJECT_PATH" "$CONTAINER_NAME" zsh
