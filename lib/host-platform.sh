# shellcheck shell=bash
# =============================================================================
# Boxa host-platform dispatch (ADR 0010 § Cross-platform abstraction)
# =============================================================================
# Single source of truth for per-OS branching on the host side. Sourced by
# host-side scripts that need to know which platform they run on or that
# need to launch host-only artifacts (Chrome, system users, notifications).
#
# Three platforms are supported, mirroring the rest of boxa's host story:
#   - linux  — native Linux desktop (X11/Wayland)
#   - wsl2   — Linux distro under WSL2 on Windows (WSLg renders GUIs)
#   - macos  — Darwin
#
# Why this file exists separately from `scripts/dns-install.sh`'s
# `_dns::detect_platform`: dns-install reports `linux-resolved` /
# `linux-nm` because the DNS install branch matters per stack. The
# agent-browser feature only needs the OS family, not the resolver
# variant. Keeping these two detect functions distinct prevents one
# concern (DNS install) from accidentally widening the contract of the
# other (host-platform dispatch). Both stay grep-able for `uname -s`.
#
# Functions are namespaced with the `host_platform::` prefix, matching
# the repo's existing `allow_for::`, `allowlist::`, `_mkcert::` style.
# =============================================================================

# --- Detection ---------------------------------------------------------------

# Echo one of: linux | wsl2 | macos. Non-zero on unknown OS.
#
# WSL2 is checked before generic Linux because it needs different binaries
# (PowerShell for toasts, %USERPROFILE% paths) and different Chrome
# semantics (Chrome runs as a Linux binary inside the WSL distro, rendered
# through WSLg — not the host Windows Chrome, which has no CDP we can
# trust). Detection uses /proc/sys/fs/binfmt_misc/WSLInterop as the
# primary signal (set by WSL itself, distro-agnostic), falling back to
# /proc/version content for older WSL builds.
host_platform::detect() {
    case "$(uname -s 2>/dev/null || echo Unknown)" in
        Darwin) printf 'macos\n'; return 0 ;;
        Linux)  ;;
        *)      return 1 ;;
    esac
    if [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] \
        || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        printf 'wsl2\n'
        return 0
    fi
    printf 'linux\n'
}

# --- Chrome binary discovery -------------------------------------------------

# Echo the absolute path to an executable Chrome/Chromium binary, or fail
# (rc=1) with a clear stderr install hint naming the canonical command for
# the detected platform.
#
# Search order is documented inline per platform. WSL2 deliberately uses
# the Linux search because Host agent Chrome must render through WSLg as a
# Linux process — the host Windows Chrome is the user's personal browser
# (rejected in ADR 0010 considered options) and CDP through interop would
# punch through WSL's network namespace anyway.
host_platform::chrome_binary() {
    local platform
    if ! platform="$(host_platform::detect)"; then
        printf 'host_platform::chrome_binary: unknown OS (%s)\n' "$(uname -s)" >&2
        return 1
    fi

    local candidates=()
    case "$platform" in
        linux|wsl2)
            # PATH first (distro packages, user installs), then canonical
            # /usr/bin locations (Chrome's .deb / Chromium snap-shim).
            local name
            for name in google-chrome google-chrome-stable chromium chromium-browser; do
                local found
                found="$(command -v "$name" 2>/dev/null || true)"
                [ -n "$found" ] && candidates+=("$found")
            done
            local glob
            for glob in /usr/bin/google-chrome /usr/bin/google-chrome-stable \
                        /usr/bin/chromium /usr/bin/chromium-browser \
                        /snap/bin/chromium; do
                [ -x "$glob" ] && candidates+=("$glob")
            done
            ;;
        macos)
            # /Applications first (system-wide install — the default for
            # both Google Chrome.app and Chromium.app), then ~/Applications
            # for per-user installs.
            local app
            for app in \
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                "/Applications/Chromium.app/Contents/MacOS/Chromium" \
                "${HOME}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                "${HOME}/Applications/Chromium.app/Contents/MacOS/Chromium"; do
                [ -x "$app" ] && candidates+=("$app")
            done
            ;;
    esac

    local cand
    for cand in "${candidates[@]+"${candidates[@]}"}"; do
        if [ -x "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done

    case "$platform" in
        linux)
            printf 'host_platform::chrome_binary: no Chrome/Chromium found.\n' >&2
            printf '  Install one of:\n' >&2
            printf '    sudo apt-get install -y chromium      # Debian/Ubuntu\n' >&2
            printf '    sudo dnf install -y chromium          # Fedora/RHEL\n' >&2
            printf '    sudo pacman -S chromium               # Arch\n' >&2
            printf '  Or Google Chrome from https://www.google.com/chrome/\n' >&2
            ;;
        wsl2)
            printf 'host_platform::chrome_binary: no Chrome/Chromium found inside the WSL2 distro.\n' >&2
            printf '  Host agent Chrome runs as a Linux binary under WSLg, not the host Windows Chrome.\n' >&2
            printf '  Install inside this distro:\n' >&2
            printf '    sudo apt-get install -y chromium\n' >&2
            printf '  Or Google Chrome for Linux from https://www.google.com/chrome/\n' >&2
            ;;
        macos)
            printf 'host_platform::chrome_binary: no Chrome/Chromium found in /Applications or ~/Applications.\n' >&2
            printf '  Install one of:\n' >&2
            printf '    brew install --cask google-chrome\n' >&2
            printf '    brew install --cask chromium\n' >&2
            printf '  Or download Google Chrome from https://www.google.com/chrome/\n' >&2
            ;;
    esac
    return 1
}

# --- boxa-agent OS user ----------------------------------------------------

# Idempotently create the `boxa-agent` OS user that Host agent Chrome
# runs under (ADR 0010 § Actor 1). The OS identity is the primary defence
# against `file://` reads of the developer's home and download-to-autostart
# attacks; `--user-data-dir` alone does not change process write perms.
#
# Linux/WSL2 path uses `useradd` and accepts the system-account treatment
# (--system, nologin shell) — the agent never logs in interactively, so
# the system-account distinction has no downsides on Linux.
#
# macOS path uses `sysadminctl -addUser` and intentionally creates a
# regular user (not an underscore-prefixed system user). ADR 0010
# considered options block calls this out: `_boxa-agent` triggers
# LaunchServices edge cases (no notarisation prompts for downloads, hidden
# from login screen but still surfaces in some File Open dialogs, no
# Quartz seat by default) that complicate the visual-audit story. A
# regular user with a shell of `/usr/bin/false` is the simpler reliable
# shape.
host_platform::ensure_agent_user() {
    local platform
    if ! platform="$(host_platform::detect)"; then
        printf 'host_platform::ensure_agent_user: unknown OS (%s)\n' "$(uname -s)" >&2
        return 1
    fi

    case "$platform" in
        linux|wsl2)
            _host_platform::ensure_agent_user_linux
            ;;
        macos)
            _host_platform::ensure_agent_user_macos
            ;;
    esac
}

# Idempotently add a developer user to the `boxa-agent` group so they can
# read group-owned artefacts (netlog, proxy log, summary) at mode 0640. ADR
# 0010 § Tamper-proof property documents this read path; without the
# membership the user cannot open the files the CLI/toasts advertise.
host_platform::ensure_agent_user_in_group() {
    local user="$1"
    [ -n "$user" ] || { printf 'host_platform::ensure_agent_user_in_group: user arg required\n' >&2; return 1; }

    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx boxa-agent; then
        return 0
    fi

    local platform
    if ! platform="$(host_platform::detect)"; then
        printf 'host_platform::ensure_agent_user_in_group: unknown OS (%s)\n' "$(uname -s)" >&2
        return 1
    fi

    case "$platform" in
        linux|wsl2)
            # `usermod -aG` works on shadow systems; BusyBox `adduser
            # boxa-agent <user>` adds an existing user to a group on
            # Alpine. Pick by tool availability.
            if command -v usermod >/dev/null 2>&1; then
                sudo usermod -aG boxa-agent "$user"
            elif command -v addgroup >/dev/null 2>&1; then
                sudo addgroup "$user" boxa-agent
            else
                printf 'host_platform::ensure_agent_user_in_group: no usermod or addgroup\n' >&2
                return 1
            fi
            ;;
        macos)
            # Defensive: ensure the group exists. ensure_agent_user_macos
            # creates it on fresh installs, but a pre-existing boxa-agent
            # user from an older install may predate the group provisioning.
            if ! dseditgroup -o read boxa-agent >/dev/null 2>&1; then
                if ! sudo dseditgroup -o create boxa-agent; then
                    printf 'host_platform::ensure_agent_user_in_group: failed to create boxa-agent group\n' >&2
                    return 1
                fi
            fi
            sudo dseditgroup -o edit -a "$user" -t user boxa-agent
            ;;
    esac
}

# --- Internal helpers --------------------------------------------------------

_host_platform::ensure_agent_user_linux() {
    if id boxa-agent >/dev/null 2>&1; then
        return 0
    fi

    # `useradd` (shadow) is the tool on Debian/Ubuntu/Fedora/RHEL/Arch/
    # openSUSE. Alpine ships only BusyBox `adduser` with different flag
    # syntax; install.sh's PM list (`apk`) supports Alpine explicitly,
    # so this branch must too.
    #
    # `/usr/sbin/nologin` is shadow's canonical path; BusyBox systems
    # put it at `/sbin/nologin`. Fall back to `/bin/false` if neither
    # exists — the account is never logged into interactively, so any
    # non-shell is equivalent here.
    local cand nologin_shell=""
    for cand in /usr/sbin/nologin /sbin/nologin /bin/false; do
        if [ -x "$cand" ]; then
            nologin_shell="$cand"
            break
        fi
    done
    if [ -z "$nologin_shell" ]; then
        printf 'host_platform::ensure_agent_user: no nologin/false shell found\n' >&2
        return 1
    fi

    if command -v useradd >/dev/null 2>&1; then
        # `--system` because the account is never logged into.
        # `--user-group` creates a matching `boxa-agent` group, which
        # the log-dir provisioning in later slices will add the
        # developer to (read-only on the proxy log).
        if ! sudo useradd --system --user-group \
                --create-home \
                --shell "$nologin_shell" \
                boxa-agent; then
            printf 'host_platform::ensure_agent_user: useradd failed for boxa-agent\n' >&2
            return 1
        fi
    elif command -v adduser >/dev/null 2>&1; then
        # BusyBox adduser (Alpine): -S system, -D no password,
        # -h home dir, -s shell. System users get an auto-created
        # matching group, equivalent to shadow's `--user-group`.
        if ! sudo adduser -S -D -h /home/boxa-agent \
                -s "$nologin_shell" boxa-agent; then
            printf 'host_platform::ensure_agent_user: adduser failed for boxa-agent\n' >&2
            return 1
        fi
    else
        printf 'host_platform::ensure_agent_user: neither useradd nor adduser found\n' >&2
        return 1
    fi
}

_host_platform::ensure_agent_user_macos() {
    if id boxa-agent >/dev/null 2>&1; then
        return 0
    fi

    # On macOS, `sysadminctl -addUser` does not create a matching group, and
    # the new account's primary group defaults to `staff`. We need a real
    # `boxa-agent` group for the broker's `chown boxa-agent:boxa-agent`
    # + 0640 read path to work, paralleling the Linux `useradd --user-group`
    # shape. Create the group first (idempotent via `dseditgroup -o read`),
    # then create the user with that group as primary.
    if ! dseditgroup -o read boxa-agent >/dev/null 2>&1; then
        if ! sudo dseditgroup -o create boxa-agent; then
            printf 'host_platform::ensure_agent_user: failed to create boxa-agent group\n' >&2
            return 1
        fi
    fi

    local group_gid
    group_gid="$(dscl . -read /Groups/boxa-agent PrimaryGroupID 2>/dev/null \
        | awk '/PrimaryGroupID:/ {print $2}')"
    if [ -z "$group_gid" ]; then
        printf 'host_platform::ensure_agent_user: failed to resolve boxa-agent group GID\n' >&2
        return 1
    fi

    # sysadminctl needs admin; sudo prompts the GUI for an admin password
    # (matches mkcert -install UX on macOS).
    #
    # `-password` is a mandatory argument: sysadminctl exits non-zero if
    # omitted. The account is never logged into interactively, so we
    # assign a random one-shot password; sudo from an admin account does
    # not need this password to launch Chrome as boxa-agent. The shell
    # is `/usr/bin/false` to additionally block `su boxa-agent`.
    #
    # sysadminctl does NOT support setting the primary group at creation
    # time (no -GID flag in the documented arg list). Primary group is
    # set immediately after via dscl — same shape ensure-agent-browser-
    # host-state.sh uses for the upgrade path.
    local one_shot_password
    one_shot_password="$(openssl rand -base64 24 2>/dev/null \
        || dd if=/dev/urandom bs=18 count=1 2>/dev/null | base64)"

    if ! sudo sysadminctl -addUser boxa-agent \
            -fullName "Boxa Agent" \
            -password "$one_shot_password" \
            -shell /usr/bin/false 2>&1 \
            | grep -v -E 'Creating user record|Setting up home directory|done' \
            >&2; then
        :
    fi
    unset one_shot_password

    if ! id boxa-agent >/dev/null 2>&1; then
        printf 'host_platform::ensure_agent_user: sysadminctl did not create boxa-agent\n' >&2
        return 1
    fi

    if ! sudo dscl . -create /Users/boxa-agent PrimaryGroupID "$group_gid"; then
        printf 'host_platform::ensure_agent_user: failed to set boxa-agent primary group to %s\n' "$group_gid" >&2
        return 1
    fi
}

# --- boxa-agent mkcert root-CA trust ---------------------------------------

# Idempotently import the developer's mkcert root CA into the boxa-agent
# user's NSS DB (~/.pki/nssdb), so Host agent Chrome — which runs as
# boxa-agent — trusts HTTPS certs issued by the developer's local CA.
#
# Why a separate trust seed is needed: `mkcert -install` seeds the
# *invoking* user's NSS DB. Host agent Chrome runs as boxa-agent (a
# separate system user with its own home), so it never inherits that
# trust and silently rejects every mkcert-signed boxa project URL.
#
# Idempotence: compares fingerprint of the existing nick against the
# source rootCA.pem. Re-imports only on missing/mismatched fingerprint
# (CA rotation, fresh install). No-op on match — safe to call from
# every `boxa update`.
#
# Platforms:
#   - linux/wsl2: NSS DB at ~boxa-agent/.pki/nssdb, certutil required
#     (libnss3-tools on Debian, nss-tools on Fedora/Alpine).
#   - macOS: Chrome reads the System/login Keychain; boxa-agent has
#     no login keychain (system user, no GUI session), so Chrome falls
#     back to the System Keychain. Seeding that needs admin every run
#     and conflicts with the developer's own `mkcert -install`. Skipped
#     here; tracked for a later dedicated macOS slice.
#
# Soft-fails (returns 0 with a warning on stderr) when:
#   - mkcert binary unavailable (HTTPS rollout not bootstrapped yet)
#   - CAROOT/rootCA.pem missing (mkcert -install never run)
#   - certutil unavailable (developer opted out of NSS tooling)
# These are all developer-driven states; the failure mode is "Chrome
# shows cert warning" which the developer can self-diagnose. Hard-fail
# (returns 1) only for sudo / user-existence problems that indicate a
# broken boxa install.
#
# Requires lib/mkcert.sh sourced by the caller for _mkcert::caroot and
# _mkcert::ca_fingerprint. Soft-fails with a clear diagnostic if either
# helper is missing.
host_platform::ensure_agent_mkcert_trust() {
    local platform
    if ! platform="$(host_platform::detect)"; then
        printf 'host_platform::ensure_agent_mkcert_trust: unknown OS (%s)\n' "$(uname -s)" >&2
        return 1
    fi
    case "$platform" in
        linux|wsl2)
            _host_platform::ensure_agent_mkcert_trust_linux
            ;;
        macos)
            # See header comment; pending separate macOS slice.
            return 0
            ;;
    esac
}

_host_platform::ensure_agent_mkcert_trust_linux() {
    if ! id boxa-agent >/dev/null 2>&1; then
        printf 'host_platform::ensure_agent_mkcert_trust: boxa-agent user missing; run ensure_agent_user first\n' >&2
        return 1
    fi

    if ! command -v _mkcert::caroot >/dev/null 2>&1; then
        printf 'host_platform::ensure_agent_mkcert_trust: lib/mkcert.sh not sourced; skipping NSS seed\n' >&2
        return 0
    fi

    local caroot
    caroot="$(_mkcert::caroot 2>/dev/null || true)"
    if [ -z "$caroot" ] || [ ! -f "$caroot/rootCA.pem" ]; then
        printf 'host_platform::ensure_agent_mkcert_trust: no mkcert rootCA.pem yet; run install-mkcert.sh first (HTTPS for boxa-agent Chrome will fail until then)\n' >&2
        return 0
    fi

    if ! command -v certutil >/dev/null 2>&1; then
        printf 'host_platform::ensure_agent_mkcert_trust: certutil missing; install libnss3-tools (Debian) / nss-tools (Fedora/Alpine) or rerun: bash scripts/install-mkcert.sh --with-nss\n' >&2
        return 0
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        printf 'host_platform::ensure_agent_mkcert_trust: openssl missing; cannot compare cert fingerprints\n' >&2
        return 0
    fi

    # DER-encoded fingerprint of the source rootCA. PEM-of-PEM hashing
    # would be fragile (line wrapping / header variants across exporters
    # change the byte stream without changing the cert itself); converting
    # to DER first normalises to the canonical X.509 bytes. This is
    # independent of _mkcert::ca_fingerprint (file-content SHA, used by
    # lib/cert.sh for leaf-cert invalidation against CA churn) — different
    # invariant, different consumer.
    local src_fp
    src_fp="$(sudo cat "$caroot/rootCA.pem" 2>/dev/null \
        | openssl x509 -outform DER 2>/dev/null \
        | sha256sum 2>/dev/null | awk '{print $1}')"
    if [ -z "$src_fp" ]; then
        printf 'host_platform::ensure_agent_mkcert_trust: cannot compute DER fingerprint of rootCA.pem at %s\n' "$caroot" >&2
        return 0
    fi

    # Resolve boxa-agent's home dir from /etc/passwd. `getent` is
    # available everywhere we care about; bypasses NSS module quirks
    # that occasionally bite `~boxa-agent` shell expansion.
    local agent_home
    agent_home="$(getent passwd boxa-agent 2>/dev/null | cut -d: -f6)"
    if [ -z "$agent_home" ]; then
        printf 'host_platform::ensure_agent_mkcert_trust: cannot resolve boxa-agent home dir\n' >&2
        return 1
    fi

    local nssdb_dir="$agent_home/.pki/nssdb"
    # Create + initialise the NSS DB as boxa-agent if missing. The
    # mkdir and `certutil -N` are independent gates: a prior aborted
    # run (mkdir succeeded, certutil -N failed) leaves the directory
    # without `cert9.db`, and a directory-only check would skip init
    # forever, causing every subsequent `certutil -A` to fail. Probe
    # the actual DB presence via `certutil -L` (returns non-zero on
    # uninitialised dir) instead of stat'ing the directory.
    #
    # `-N --empty-password` creates a passwordless SQL-backed DB (the
    # `sql:` prefix on the path is the new-style DB; certutil falls
    # back to the legacy DBM format without it, which Chrome 50+ ignores).
    if ! sudo test -d "$nssdb_dir"; then
        if ! sudo -u boxa-agent mkdir -p "$nssdb_dir"; then
            printf 'host_platform::ensure_agent_mkcert_trust: mkdir %s failed\n' "$nssdb_dir" >&2
            return 1
        fi
    fi
    if ! sudo -u boxa-agent certutil -L -d "sql:$nssdb_dir" >/dev/null 2>&1; then
        if ! sudo -u boxa-agent certutil -d "sql:$nssdb_dir" -N --empty-password >/dev/null 2>&1; then
            printf 'host_platform::ensure_agent_mkcert_trust: certutil -N failed for boxa-agent NSS DB at %s\n' "$nssdb_dir" >&2
            return 1
        fi
    fi

    # Probe the current trust state. The nick is repo-namespaced so it
    # cannot collide with whatever `mkcert -install` writes when run as
    # boxa-agent directly (developer escape hatch, not used by us).
    local nick="boxa mkcert root"
    local current_fp=""
    if sudo -u boxa-agent certutil -L -d "sql:$nssdb_dir" -n "$nick" >/dev/null 2>&1; then
        current_fp="$(sudo -u boxa-agent certutil -L -d "sql:$nssdb_dir" -n "$nick" -a 2>/dev/null \
            | openssl x509 -outform DER 2>/dev/null \
            | sha256sum 2>/dev/null | awk '{print $1}')"
    fi
    if [ -n "$current_fp" ] && [ "$current_fp" = "$src_fp" ]; then
        return 0
    fi

    # Stage rootCA.pem in /tmp where boxa-agent can read it (CAROOT
    # is 0700 owned by the developer). The staging file is short-lived
    # and contains only the public cert. Trap on EXIT for cleanup —
    # local trap (subshell isolation would require RETURN trap with set
    # +e gymnastics; the function is short enough to scope an EXIT trap
    # via an inner subshell).
    local rc=0
    (
        set -e
        staged="$(mktemp /tmp/boxa-agent-rootca.XXXXXX.pem)"
        trap 'rm -f -- "$staged"' EXIT
        # The redirect target ($staged) is in /tmp and owned by the
        # invoking user from mktemp — sudo elevation is needed only for
        # the read side (CAROOT is 0700 owned by the developer). SC2024
        # warns about sudo-write-redirect, which we deliberately avoid:
        # only the read is elevated.
        # shellcheck disable=SC2024
        if ! sudo cat "$caroot/rootCA.pem" > "$staged"; then
            printf 'host_platform::ensure_agent_mkcert_trust: cannot stage rootCA.pem from %s\n' "$caroot" >&2
            exit 1
        fi
        chmod 0644 "$staged"

        if [ -n "$current_fp" ]; then
            # Stale entry — fingerprint differs from source. Remove
            # before re-adding (certutil -A would error on duplicate nick).
            sudo -u boxa-agent certutil -D -d "sql:$nssdb_dir" -n "$nick" >/dev/null 2>&1 || true
        fi
        # `-t C,,` = trust for SSL CA only (no email, no code-signing).
        # Matches the trust bits mkcert -install uses for its own nick.
        if ! sudo -u boxa-agent certutil -A -d "sql:$nssdb_dir" \
                -n "$nick" -t "C,," -i "$staged" >/dev/null 2>&1; then
            printf 'host_platform::ensure_agent_mkcert_trust: certutil -A failed\n' >&2
            exit 1
        fi
    ) || rc=$?

    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi

    if [ -n "$current_fp" ]; then
        printf 'Refreshed mkcert root CA in boxa-agent NSS DB (CA rotated)\n'
    else
        printf 'Imported mkcert root CA into boxa-agent NSS DB (Host agent Chrome now trusts boxa HTTPS)\n'
    fi
}
