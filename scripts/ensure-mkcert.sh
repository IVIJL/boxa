#!/bin/bash
set -euo pipefail
# Idempotent host-side install of the mkcert BINARY at the pinned version
# (ADR 0008, ADR 0017 § 2 category A). A no-op when a usable mkcert is
# already present.
#
# This is the registry-facing wrapper around scripts/install-mkcert.sh —
# the standalone downloader that owns the version pin, the SHA-256 table,
# the platform detection, and the actual fetch + verify + placement. Keeping
# the download logic in install-mkcert.sh (where the HTTPS upgrade
# orchestration also calls it) and the registry contract here avoids
# duplicating any of that logic.
#
# Called from install.sh during fresh install and, via lib/provisioning.sh,
# from `boxa doctor` / the `boxa update` self-heal chain for existing
# installs. Mirrors the shape of ensure-boxa-skill.sh /
# ensure-allow-for-host-state.sh.
#
# The mkcert binary lands at $HOME/.local/bin/mkcert (no sudo). On Linux,
# the optional NSS-tools install (`--with-nss`, certutil missing) DOES need
# sudo. This script is category A but must not abort the whole provisioning
# run when sudo is unavailable non-interactively: a missing sudo degrades to
# a reported problem (warning + non-zero exit) rather than a hard failure
# that aborts the dispatch.
#
# Exits 0 when a usable mkcert is present at the end of the run. Exits
# non-zero on a real install failure (network, hash mismatch, unsupported
# platform, or sudo required but unavailable).

BOXA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QUIET_IF_NOOP=false
WITH_NSS=false

for arg in "$@"; do
    case "$arg" in
        --quiet-if-noop) QUIET_IF_NOOP=true ;;
        --with-nss) WITH_NSS=true ;;
        -h|--help)
            cat <<'EOF'
Usage: ensure-mkcert.sh [--quiet-if-noop] [--with-nss]

Idempotently install the mkcert binary at the pinned version. Delegates the
download + SHA-256 verify + placement to scripts/install-mkcert.sh. A no-op
when a usable mkcert is already present.

Options:
  --quiet-if-noop   Suppress output when nothing needed to be done.
  --with-nss        Linux only: also install NSS tools (libnss3-tools or the
                    equivalent) when certutil is missing, so mkcert -install
                    can write the Firefox/Chrome trust store. Needs sudo.
EOF
            exit 0 ;;
        *)
            echo "ensure-mkcert.sh: unknown arg '$arg'" >&2
            exit 2 ;;
    esac
done

loud() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

provisioner="$BOXA_DIR/scripts/install-mkcert.sh"
if [ ! -x "$provisioner" ]; then
    warn "scripts/install-mkcert.sh missing or non-executable; cannot install mkcert."
    exit 1
fi

# Probe FIRST so the print-on-action contract (lib/provisioning.sh) holds:
# stdout stays empty on a no-op (mkcert already usable) and carries the
# resolved binary path only when a real install happened. install-mkcert.sh
# always prints the path on success, so we cannot just forward its stdout —
# we have to know up front whether work was needed.
#
# The probe reuses lib/mkcert.sh's _mkcert::resolve_bin in a subshell, the
# same predicate install-mkcert.sh uses to decide it can skip the download,
# so this wrapper and the downloader agree on what "already usable" means.
resolved=""
already_usable=false
if resolved="$(
    # shellcheck source=../lib/mkcert.sh disable=SC1091
    source "$BOXA_DIR/lib/mkcert.sh"
    _mkcert::resolve_bin 2>/dev/null
)"; then
    already_usable=true
fi

# Short-circuit the common no-op: a usable mkcert is already present and no NSS
# setup was requested. Do NOT invoke the downloader at all — install-mkcert.sh
# prints a "Found usable mkcert" diagnostic to stderr even when it skips the
# download, which would break the quiet no-op contract on every steady-state
# `boxa update`. NSS setup (--with-nss) still needs the downloader even with
# the binary present, so only skip when NSS was not requested.
if [ "$already_usable" = "true" ] && [ "$WITH_NSS" = "false" ]; then
    $QUIET_IF_NOOP || loud "mkcert already present at $resolved (no changes)."
    exit 0
fi

# Either there is no usable binary yet, or NSS setup was requested. Run the
# downloader. It sends diagnostics to stderr and the final binary path to
# stdout; capture stdout so the registry's change signal stays accurate, and
# let stderr pass through so real download progress / warnings surface.
extra_args=()
[ "$WITH_NSS" = "true" ] && extra_args+=("--with-nss")
rc=0
resolved="$("$provisioner" "${extra_args[@]}")" || rc=$?

if [ "$rc" -ne 0 ]; then
    # A real install failure (network, hash mismatch, unsupported platform,
    # or sudo needed but unavailable). Report it; do NOT abort the caller's
    # whole provisioning run — the dispatch records this as a failed step.
    warn "mkcert install failed (see warnings above)."
    exit 1
fi

if [ "$already_usable" = "true" ]; then
    # The binary already existed; the downloader ran only for NSS setup, so the
    # binary itself is a no-op. Stay silent under --quiet-if-noop.
    $QUIET_IF_NOOP || loud "mkcert already present at $resolved (no changes)."
    exit 0
fi

# A real binary install happened — print the resolved path on stdout so the
# registry dispatch counts it as a repair and install.sh can name it in the
# INSTALLED summary.
loud "$resolved"
