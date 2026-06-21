# shellcheck shell=bash
# =============================================================================
# Boxa per-project cert lifecycle — ensure_project_cert + helpers
# =============================================================================
# Sourced by docker-run.sh on host. Owns the contract that, when HTTPS is
# active, every running project has a fresh mkcert-signed leaf cert
# alongside a Traefik TLS config that points at it. Until Phase 4 flips
# `https_active`, callers gate every entry point on `boxa::https_active`
# so this file's behavior is a noop on a freshly-upgraded install.
#
# Requires (caller-sourced):
#   lib/https.sh   — boxa::https_active, boxa::external_provider via dns.conf
#   lib/mkcert.sh  — _mkcert::resolve_bin, _mkcert::ca_fingerprint, _mkcert::version
#   lib/naming.sh  — BOXA_LOCAL_TLD, boxa::external_provider
#
# Layout (host paths; container paths land in Phase 4):
#   $BOXA_CERTS_DIR/<project>.pem        mkcert-signed leaf
#   $BOXA_CERTS_DIR/<project>.key        leaf private key (chmod 600)
#   $BOXA_CERTS_DIR/<project>.meta       shell-style metadata (provenance)
#   $BOXA_CERT_TLS_DIR/<project>-tls.yml Traefik file-provider TLS config
#
# SAN set per project (4 entries, both wildcard + apex on each TLD):
#   <project>.<BOXA_LOCAL_TLD>
#   *.<project>.<BOXA_LOCAL_TLD>
#   <project>.127.0.0.1.<external_provider>
#   *.<project>.127.0.0.1.<external_provider>
#
# Regeneration triggers (any one fires a regen):
#   1. Any of pem/key/meta missing.
#   2. meta.expires_at within BOXA_CERT_EXPIRY_WARN_DAYS of now.
#   3. meta.ca_fingerprint != current rootCA fingerprint (CA rotated).
#   4. meta.sans != currently-computed SAN set (provider change, scheme tweak).
#   The provider-change case in plan §Phase 3 is covered by (4) since the
#   provider name flows into two of the four SANs — explicit provider check
#   would be redundant.
# =============================================================================

# --- Tunables (env-overridable for tests) ------------------------------------

BOXA_CERTS_DIR="${BOXA_CERTS_DIR:-$HOME/.config/boxa/certs}"
BOXA_CERT_TLS_DIR="${BOXA_CERT_TLS_DIR:-$HOME/.config/boxa/traefik/dynamic}"
BOXA_CERT_CONTAINER_PATH="${BOXA_CERT_CONTAINER_PATH:-/etc/traefik/certs}"
BOXA_CERT_EXPIRY_WARN_DAYS="${BOXA_CERT_EXPIRY_WARN_DAYS:-10}"

# Reason string from the last _cert::should_regenerate call. Lifted out as a
# return channel so _warn lines stay informative without duplicating the
# trigger-decision branch in the caller.
_BOXA_CERT_LAST_REASON=

# --- Warn helper -------------------------------------------------------------

# Single warn site: always prints a yellow stderr line so a `boxa <project>`
# tail never goes silent on a regen. When the caller maintains a `WARNINGS`
# bash array in the scope of the call (dns-install.sh / future migrate-routes-
# to-https.sh do), the message is appended for the colored end-summary too —
# this is the WARNINGS=() collector contract from feedback_no_silent_failures.
_cert::_warn() {
    local YELLOW='\033[1;33m' NC='\033[0m'
    printf "${YELLOW}WARN: %s${NC}\n" "$*" >&2
    if [ "${WARNINGS+set}" = "set" ] \
        && declare -p WARNINGS 2>/dev/null | grep -q 'declare \-a'; then
        WARNINGS+=("$*")
    fi
}

# --- SAN computation ---------------------------------------------------------

# Yield the canonical SAN list for a project, comma-joined. Single source so
# generation, meta-write, and drift-detection all agree byte-for-byte.
_cert::compute_sans() {
    local project="$1"
    local provider
    provider="$(boxa::external_provider)"
    printf '%s,%s,%s,%s' \
        "${project}.${BOXA_LOCAL_TLD}" \
        "*.${project}.${BOXA_LOCAL_TLD}" \
        "${project}.127.0.0.1.${provider}" \
        "*.${project}.127.0.0.1.${provider}"
}

# Same SAN list but newline-separated for piping into `mkcert "${sans[@]}"`.
_cert::compute_sans_array() {
    local project="$1"
    local provider
    provider="$(boxa::external_provider)"
    printf '%s\n%s\n%s\n%s\n' \
        "${project}.${BOXA_LOCAL_TLD}" \
        "*.${project}.${BOXA_LOCAL_TLD}" \
        "${project}.127.0.0.1.${provider}" \
        "*.${project}.127.0.0.1.${provider}"
}

# --- Meta file I/O -----------------------------------------------------------

# Parse <project>.meta into caller-named variables. Strict key=value parser
# matching lib/https.sh's load_https_conf style: `#` comments, leading and
# trailing whitespace tolerated, fixed key allow-list. Unknown keys are
# silently ignored so a future field added by a newer boxa doesn't blow up
# an older one mid-startup.
#
# Usage: _cert::read_meta <meta-path> <out-prefix>
#   Sets <prefix>_issued_at, <prefix>_expires_at, <prefix>_ca_fingerprint,
#   <prefix>_mkcert_version, <prefix>_external_provider, <prefix>_sans.
_cert::read_meta() {
    local path="$1" prefix="$2"
    eval "${prefix}_issued_at=''"
    eval "${prefix}_expires_at=''"
    eval "${prefix}_ca_fingerprint=''"
    eval "${prefix}_mkcert_version=''"
    eval "${prefix}_external_provider=''"
    eval "${prefix}_sans=''"
    [ -f "$path" ] || return 0
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" = "$line" ] && continue
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        case "$key" in
            issued_at)         eval "${prefix}_issued_at=\$value" ;;
            expires_at)        eval "${prefix}_expires_at=\$value" ;;
            ca_fingerprint)    eval "${prefix}_ca_fingerprint=\$value" ;;
            mkcert_version)    eval "${prefix}_mkcert_version=\$value" ;;
            external_provider) eval "${prefix}_external_provider=\$value" ;;
            sans)              eval "${prefix}_sans=\$value" ;;
        esac
    done < "$path"
}

# Read the leaf cert's notAfter (in epoch seconds), or empty on failure. We
# probe both GNU and BSD date syntaxes so the same code runs on Linux and
# macOS hosts. Empty result is non-fatal — meta records empty `expires_at=`
# and _cert::should_regenerate then skips the expiry trigger (no infinite
# regen loop). The CA-fingerprint and SAN-drift triggers still cover the
# important rotation cases.
_cert::extract_expires_epoch() {
    local pem="$1"
    [ -f "$pem" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    local end
    end="$(openssl x509 -in "$pem" -noout -enddate 2>/dev/null)" || return 1
    end="${end#notAfter=}"
    [ -n "$end" ] || return 1
    if date -u -d "$end" +%s 2>/dev/null; then
        return 0
    fi
    # BSD date (macOS): `Apr  5 12:34:56 2028 GMT` — note the double space.
    date -u -j -f "%b %e %H:%M:%S %Y %Z" "$end" +%s 2>/dev/null
}

# Emit the meta file. Captures everything _cert::should_regenerate needs to
# decide whether to regen on a later run, plus diagnostic fields for
# `boxa dns-status` (Phase 8).
_cert::write_meta() {
    local project="$1"
    local pem="$BOXA_CERTS_DIR/${project}.pem"
    local meta="$BOXA_CERTS_DIR/${project}.meta"
    local issued_at expires_at ca_fp version provider sans
    issued_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    expires_at="$(_cert::extract_expires_epoch "$pem" 2>/dev/null || true)"
    ca_fp="$(_mkcert::ca_fingerprint 2>/dev/null || true)"
    version="$(_mkcert::version 2>/dev/null || true)"
    provider="$(boxa::external_provider)"
    sans="$(_cert::compute_sans "$project")"
    cat > "$meta" <<META
# Boxa per-project cert metadata — managed by ensure_project_cert.
# Safe to delete to force regeneration on next 'boxa <project>'.
project=${project}
issued_at=${issued_at}
expires_at=${expires_at}
ca_fingerprint=${ca_fp}
mkcert_version=${version}
external_provider=${provider}
sans=${sans}
META
}

# Emit the Traefik dynamic TLS config that binds the leaf into the file
# provider. The container-side paths assume Phase 4's bind-mount
# (`-v $BOXA_CERTS_DIR:$BOXA_CERT_CONTAINER_PATH:ro`); written ahead of
# Phase 4 so the artifact is ready when bootstrap_traefik flips on.
#
# Content-compare-then-write: skip the rewrite when nothing changed so
# Traefik's file watcher isn't woken on every `boxa <project>` invocation.
_cert::write_tls_yml() {
    local project="$1"
    local out="$BOXA_CERT_TLS_DIR/${project}-tls.yml"
    mkdir -p "$BOXA_CERT_TLS_DIR" || return 1
    local pem_path="$BOXA_CERT_CONTAINER_PATH/${project}.pem"
    local key_path="$BOXA_CERT_CONTAINER_PATH/${project}.key"
    local rendered
    rendered="tls:
  certificates:
    - certFile: ${pem_path}
      keyFile: ${key_path}
"
    if [ -f "$out" ]; then
        local current
        current="$(cat "$out" 2>/dev/null)"
        [ "$current" = "${rendered%$'\n'}" ] && return 0
    fi
    printf '%s' "$rendered" > "$out"
}

# --- Trigger matrix ----------------------------------------------------------

# Return 0 (regen needed) on any of: missing files, expiring soon, CA
# fingerprint drift, SAN drift. Sets _BOXA_CERT_LAST_REASON to a short
# description so the caller's WARN line is informative.
_cert::should_regenerate() {
    local project="$1"
    local pem="$BOXA_CERTS_DIR/${project}.pem"
    local key="$BOXA_CERTS_DIR/${project}.key"
    local meta="$BOXA_CERTS_DIR/${project}.meta"
    _BOXA_CERT_LAST_REASON=

    if [ ! -f "$pem" ] || [ ! -f "$key" ] || [ ! -f "$meta" ]; then
        _BOXA_CERT_LAST_REASON="missing cert/key/meta"
        return 0
    fi

    local m_issued_at m_expires_at m_ca_fingerprint
    local m_mkcert_version m_external_provider m_sans
    _cert::read_meta "$meta" m
    # `m_mkcert_version` and `m_issued_at` are recorded for diagnostics only,
    # not for trigger decisions — silence the unused warning.
    : "${m_mkcert_version-}" "${m_issued_at-}"

    if [ -n "$m_expires_at" ] && [ "$m_expires_at" -gt 0 ] 2>/dev/null; then
        local now threshold
        now="$(date +%s)"
        threshold=$(( now + BOXA_CERT_EXPIRY_WARN_DAYS * 86400 ))
        if [ "$m_expires_at" -lt "$threshold" ]; then
            _BOXA_CERT_LAST_REASON="expires within ${BOXA_CERT_EXPIRY_WARN_DAYS} days"
            return 0
        fi
    fi

    # Regenerate whenever we cannot prove the leaf is still signed by the
    # currently-trusted CA. Three failure modes collapse to "regen":
    #   - current fingerprint unreadable (CAROOT/rootCA.pem missing, e.g.
    #     after `mkcert -uninstall` or a stray rm — mkcert seeds a fresh CA
    #     on the next signing call, so regenerating is also the self-heal)
    #   - recorded fingerprint absent in meta (older meta, or Phase 1's
    #     write_https_field for ca_fingerprint failed at install time)
    #   - both present and they differ (the textbook rotation case)
    # Leaving a leaf in place with no provable CA link would have Traefik
    # serve a cert signed by a CA the trust store no longer holds.
    local current_ca
    current_ca="$(_mkcert::ca_fingerprint 2>/dev/null || true)"
    if [ -z "$current_ca" ]; then
        _BOXA_CERT_LAST_REASON="rootCA fingerprint unreadable (CAROOT missing?)"
        return 0
    fi
    if [ -z "$m_ca_fingerprint" ]; then
        _BOXA_CERT_LAST_REASON="meta is missing ca_fingerprint"
        return 0
    fi
    if [ "$current_ca" != "$m_ca_fingerprint" ]; then
        _BOXA_CERT_LAST_REASON="root CA fingerprint changed"
        return 0
    fi

    local current_sans
    current_sans="$(_cert::compute_sans "$project")"
    if [ "$current_sans" != "$m_sans" ]; then
        _BOXA_CERT_LAST_REASON="SAN set changed (provider/scheme drift)"
        # m_external_provider is folded into m_sans — keeping the field
        # in meta as a fast diagnostic without making it a separate trigger.
        : "${m_external_provider-}"
        return 0
    fi

    return 1
}

# --- Generation --------------------------------------------------------------

# Drive mkcert to produce a fresh leaf for the project. Writes to tmp paths
# inside $BOXA_CERTS_DIR, then `mv` into place so a concurrent read by a
# running Traefik (Phase 4) never observes a half-written file.
_cert::generate() {
    local project="$1"
    local pem="$BOXA_CERTS_DIR/${project}.pem"
    local key="$BOXA_CERTS_DIR/${project}.key"
    mkdir -p "$BOXA_CERTS_DIR" || return 1
    chmod 700 "$BOXA_CERTS_DIR" 2>/dev/null || true

    local bin
    if ! bin="$(_mkcert::resolve_bin)"; then
        _cert::_warn "cert(${project}): mkcert binary unavailable; cannot generate"
        return 1
    fi

    local tmp_pem tmp_key
    tmp_pem="$(mktemp "${pem}.XXXXXX")" || return 1
    tmp_key="$(mktemp "${key}.XXXXXX")" || { rm -f "$tmp_pem"; return 1; }

    local -a sans=()
    while IFS= read -r san; do
        [ -n "$san" ] && sans+=("$san")
    done < <(_cert::compute_sans_array "$project")

    if ! "$bin" -cert-file "$tmp_pem" -key-file "$tmp_key" "${sans[@]}" >&2; then
        rm -f "$tmp_pem" "$tmp_key"
        _cert::_warn "cert(${project}): mkcert leaf signing failed"
        return 1
    fi

    chmod 600 "$tmp_key" 2>/dev/null || true
    mv "$tmp_pem" "$pem" || { rm -f "$tmp_pem" "$tmp_key"; return 1; }
    mv "$tmp_key" "$key" || { rm -f "$tmp_key"; return 1; }
}

# --- Public entry point ------------------------------------------------------

# Ensure <project>.{pem,key,meta} + <project>-tls.yml are present and current.
# Idempotent: a second call in the same session with no drift is a noop.
# Non-fatal on any internal failure — boxa falls back to HTTP-only routing
# (Phase 4 keys off the route file content, not on cert presence).
#
# Usage: ensure_project_cert <project>
ensure_project_cert() {
    local project="$1"
    if [ -z "$project" ]; then
        _cert::_warn "ensure_project_cert: project name required"
        return 1
    fi

    if ! _mkcert::resolve_bin >/dev/null 2>&1; then
        _cert::_warn "cert(${project}): no usable mkcert binary; HTTPS leaf skipped"
        return 1
    fi

    if _cert::should_regenerate "$project"; then
        local reason="${_BOXA_CERT_LAST_REASON:-unknown reason}"
        _cert::_warn "cert(${project}): (re)generating leaf — ${reason}"
        if ! _cert::generate "$project"; then
            return 1
        fi
        if ! _cert::write_meta "$project"; then
            _cert::_warn "cert(${project}): failed writing meta file"
            return 1
        fi
    fi

    if ! _cert::write_tls_yml "$project"; then
        _cert::_warn "cert(${project}): failed writing Traefik TLS config"
        return 1
    fi
}
