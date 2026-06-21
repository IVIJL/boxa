# shellcheck shell=bash
# =============================================================================
# Boxa allow-for window helpers (ADR 0009)
# =============================================================================
# Sourced by the three in-container scripts that drive the allow-for window:
#   - start-allow-for-window   (root) opens the window
#   - teardown-allow-for-window (root) closes it and writes the harvest log
#   - show-allow-for-status     (node) prints status while a window is active
#
# Functions never assume which user is calling — read-only operations stay
# permission-clean for the node user; write paths are root-only and protected
# by filesystem perms set at install time (see ensure-allow-for-host-state.sh).
# =============================================================================

# Constants consumed by sourcing scripts; shellcheck can't see that.
# shellcheck disable=SC2034

# --- Paths -------------------------------------------------------------------
ALLOW_FOR_SENTINEL="/etc/boxa-shared/.allow-for.state"
ALLOW_FOR_DNSMASQ_CONF="/etc/dnsmasq.d/boxa-allow-for.conf"
ALLOW_FOR_LOG_DIR="/var/log/boxa/allow-for"
# Pending notification files (Phase 3 hand-off to the host deliver script)
# live in a separate subdirectory that is host-user-owned, so the host-side
# deliver script can atomically rename-claim them. The parent ALLOW_FOR_LOG_DIR
# stays root:root 0755 for the tamper-proof harvest-log guarantee (ADR 0009
# §3-4); only this subdir is host-user-writable. See
# scripts/ensure-allow-for-host-state.sh for the provisioning step.
ALLOW_FOR_PENDING_DIR="/var/log/boxa/allow-for/pending"
# Root-only scratch space for the teardown daemon's atomic publish of
# pending JSON files. Sibling of pending/ inside the same bind mount —
# critical because rename(2) requires same-filesystem operands and the
# pending dir is on a separate mount from the container rootfs. The .tmp/
# parent (allow-for/) is root:root 0755, so the in-container node user
# cannot rmdir or replace .tmp/ even though they own pending/; the
# subdir itself is 0700 root:root, so the attacker can't enumerate or
# pre-create files inside. Together those properties close the TOCTOU
# race where an attacker could swap a tempfile for a symlink between
# mktemp and the daemon's `cat >`.
ALLOW_FOR_TMP_DIR="/var/log/boxa/allow-for/.tmp"
# Daemon's stdout/stderr go inside the bind-mounted log dir as a dotfile
# so they're visible from the host alongside harvest logs (useful when
# diagnosing window-open failures) without colliding with `<container>-
# <ts>.log` filenames. A `mkdir -p` in start-allow-for-window keeps this
# path working even if the container was started before Phase 1 host
# state existed (in that case the dir lives on container rootfs, not on
# the host — diagnostic-only, gone on restart).
ALLOW_FOR_DAEMON_LOG="/var/log/boxa/allow-for/.daemon.log"
ALLOW_FOR_IPSET="harvest-pool"
ALLOW_FOR_DNSMASQ_QUERIES="/var/log/dnsmasq-queries.log"

# --- Sentinel parsing --------------------------------------------------------
# The sentinel is a tiny key=value file. Keys: started_at, expires_at,
# container, daemon_pid, log_start_byte. Values are unquoted scalars; the
# format is intentionally trivial so a `grep | cut` reader works for the
# node user without any parser library.
#
# Usage: allow_for::get_field <field>
# Prints the value on stdout; returns 1 if the field or sentinel is missing.
allow_for::get_field() {
    local field="$1"
    [ -f "$ALLOW_FOR_SENTINEL" ] || return 1
    local line
    line=$(grep -E "^${field}=" "$ALLOW_FOR_SENTINEL" 2>/dev/null | head -1) || return 1
    [ -n "$line" ] || return 1
    printf '%s\n' "${line#*=}"
}

# True if a sentinel exists. Doesn't say whether the window is still live —
# use `allow_for::is_expired` for that.
allow_for::sentinel_exists() {
    [ -f "$ALLOW_FOR_SENTINEL" ]
}

# True if the sentinel's expires_at is in the past (or unparseable, which
# we treat as expired to fail safe — better to teardown an unknown state
# than leak the window).
allow_for::is_expired() {
    local expires_at now_epoch exp_epoch
    expires_at=$(allow_for::get_field expires_at) || return 0
    now_epoch=$(date +%s)
    exp_epoch=$(date -d "$expires_at" +%s 2>/dev/null) || return 0
    [ "$now_epoch" -ge "$exp_epoch" ]
}

# --- Harvest aggregation -----------------------------------------------------
# Read dnsmasq query log from a byte offset and emit the unique set of
# A/AAAA-queried domains that are NOT covered by the allowlist (exact or
# subdomain match). Mirrors the `MODE=blocked` semantics in docker-run.sh.
#
# Usage: allow_for::harvest_domains <start_byte> [allowlist_file]
#   - start_byte:     0 reads the whole file; non-zero starts after that offset.
#   - allowlist_file: defaults to /etc/boxa-shared/allowed-domains.conf.
#
# Prints one domain per line, sorted, deduplicated. Empty output is normal
# (no non-allowlist queries yet).
allow_for::harvest_domains() {
    local start_byte="${1:-0}"
    local allowlist_file="${2:-/etc/boxa-shared/allowed-domains.conf}"

    [ -f "$ALLOW_FOR_DNSMASQ_QUERIES" ] || return 0

    # Slice the log to just-this-window. `tail -c +N` is 1-indexed; the
    # sentinel stores a 0-based byte count (post-restart wc -c), so +1.
    local skip=$((start_byte + 1))
    local queried
    queried=$(tail -c "+${skip}" "$ALLOW_FOR_DNSMASQ_QUERIES" 2>/dev/null \
        | grep -E "query\[(A|AAAA)\]" \
        | grep -oP "query\[(A|AAAA)\] \K[^ ]+" \
        | sort -u || true)

    [ -n "$queried" ] || return 0

    # Build the allowlist set with `*.` stripped — `*.foo.com` and `foo.com`
    # are equivalent under our convention (lib/allowlist.sh).
    local allowed
    if [ -f "$allowlist_file" ]; then
        allowed=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                      -e 's/^\*\.//' "$allowlist_file" \
            | grep -v '^$' \
            | sort -u || true)
    else
        allowed=""
    fi

    # Emit queried domains that are neither exact matches nor subdomains
    # of any allowlist entry. Same comparison as docker-run.sh:2316-2324.
    local domain allow is_allowed
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        is_allowed=false
        while IFS= read -r allow; do
            [ -z "$allow" ] && continue
            if [ "$domain" = "$allow" ] || [[ "$domain" == *.${allow} ]]; then
                is_allowed=true
                break
            fi
        done <<< "$allowed"
        [ "$is_allowed" = false ] && printf '%s\n' "$domain"
    done <<< "$queried"
}

# --- Time helpers ------------------------------------------------------------
# ISO 8601 in the local timezone — used for machine-parseable fields
# (sentinel state, pending JSON). Kept ISO because the host-side
# deliver script's iso_to_epoch parses both GNU `date -d` and BSD
# `date -j -f '%Y-%m-%dT%H:%M:%S%z'`, and the latter requires the
# fixed `T`-separated shape.
allow_for::now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# "+15 min" → ISO 8601 timestamp, local TZ.
allow_for::iso_plus_minutes() {
    local minutes="$1"
    date -d "+${minutes} minutes" '+%Y-%m-%dT%H:%M:%S%z'
}

# Convert ISO 8601 → `YYYY-MM-DD HH:MM:SS TZ` for display in the harvest
# log header and `show-allow-for-status` output. Containers run with
# `TZ=Europe/Prague` (or whichever the user's host uses) inherited at
# image build, so the rendered local time and TZ abbreviation match
# what the user sees on the host clock. Falls back to the raw ISO if
# `date -d` can't parse — defensive only, our writers always emit
# canonical shape.
allow_for::human_time() {
    local iso="$1"
    [ -z "$iso" ] && { printf '\n'; return 0; }
    date -d "$iso" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s\n' "$iso"
}

# Human-friendly "Xm Ys remaining" for status output. Negative deltas
# print as "0s remaining" rather than negative — the teardown daemon will
# pick the window up on its next heartbeat.
allow_for::format_remaining() {
    local expires_at="$1"
    local exp now diff m s
    exp=$(date -d "$expires_at" +%s 2>/dev/null) || { printf 'unknown\n'; return 0; }
    now=$(date +%s)
    diff=$((exp - now))
    [ "$diff" -lt 0 ] && diff=0
    m=$((diff / 60))
    s=$((diff % 60))
    printf '%dm %02ds\n' "$m" "$s"
}

# --- Harvest closeout (shared between teardown daemon and restart closeout) --
# Reads the sentinel, aggregates non-allowlist domains from the dnsmasq
# queries log, writes the harvest log to the bind-mounted host log dir, and
# drops a pending JSON for the host-side notification delivery script.
#
# Pure data path: never touches the firewall, never removes the sentinel.
# Caller decides whether to undo iptables/ipset/dnsmasq state and when to
# delete the sentinel. Two distinct call sites exercise this:
#
#   teardown-allow-for-window do_teardown — running daemon path. Caller
#   tears down firewall + removes sentinel after this helper returns.
#
#   closeout-allow-for-on-restart — boot path invoked from init-firewall
#   before any flushing. No firewall to undo (init-firewall is about to
#   wipe everything); caller just removes the sentinel after this returns.
#
# Args:
#   $1   reason — written into harvest log header and pending JSON.
#                 One of: expired, stopped, interrupted.
#
# Output:
#   stdout — one summary line: `Allow-for window closed for <container>
#            (reason=<reason>, N domains captured) — <log_path>`.
#   files  — harvest log at $ALLOW_FOR_LOG_DIR/<container>-<ts_safe>.log,
#            pending JSON at $ALLOW_FOR_PENDING_DIR/.pending-... (when
#            host-state dirs exist).
#
# Returns 0 unconditionally — best-effort by design. Missing sentinel fields
# render as "unknown" in the header; an empty harvest is normal output.
allow_for::write_harvest_closeout() {
    local reason="$1"
    local started_at expires_at container log_start_byte
    started_at=$(allow_for::get_field started_at || echo "unknown")
    expires_at=$(allow_for::get_field expires_at || echo "unknown")
    container=$(allow_for::get_field container || echo "unknown")
    log_start_byte=$(allow_for::get_field log_start_byte || echo 0)

    # Filename-safe variant of started_at: strip colons that confuse
    # Windows tooling when File Explorer opens the file via \\wsl$\... .
    # Drop the timezone offset's sign-prefix `+`/`-` collision with the
    # date separator by replacing colons only — `2026-05-16T07-30-15+0200`
    # stays unambiguous.
    local ts_safe="${started_at//:/-}"
    local log_path="${ALLOW_FOR_LOG_DIR}/${container}-${ts_safe}.log"

    mkdir -p "$ALLOW_FOR_LOG_DIR" 2>/dev/null || true

    # Harvest aggregation runs against the post-restart byte offset
    # captured at window open. An empty result is normal — the user may
    # have closed the window before anything outside the allowlist was
    # queried. On the restart closeout path the dnsmasq log may not exist
    # at all (fresh container fs after `boxa build`); that case also
    # falls through to "no domains" without an error.
    local domains domain_count top_lines
    domains=$(allow_for::harvest_domains "$log_start_byte" || true)
    domain_count=0
    [ -n "$domains" ] && domain_count=$(printf '%s\n' "$domains" | wc -l)

    # Timestamps are rendered in human-readable form here (TZ-named, no
    # `T` separator) because this file is opened by the user via the
    # Windows toast click. Sentinel + pending JSON keep the ISO 8601
    # shape (machine-parseable). Container inherits host TZ via the
    # `TZ` env baked into the image, so the displayed local time and
    # TZ abbreviation match the user's host clock.
    {
        echo "# boxa allow-for harvest log"
        echo "container:   $container"
        echo "started_at:  $(allow_for::human_time "$started_at")"
        echo "expires_at:  $(allow_for::human_time "$expires_at")"
        echo "ended_at:    $(allow_for::human_time "$(allow_for::now_iso)")"
        echo "reason:      $reason"
        echo "domain_count: $domain_count"
        echo "# ----------------------------------------------------------------"
        if [ -n "$domains" ]; then
            printf '%s\n' "$domains"
        else
            echo "# (no non-allowlist domains were queried during the window)"
        fi
    } > "$log_path"
    chmod 0644 "$log_path"

    # Build the top-3 list for the toast body — most-queried, then
    # alphabetical for ties. The dnsmasq log has one line per query, so
    # `sort | uniq -c | sort -rn` ranks correctly.
    top_lines=""
    if [ -n "$domains" ]; then
        local sb=$((log_start_byte + 1))
        top_lines=$(tail -c "+${sb}" "$ALLOW_FOR_DNSMASQ_QUERIES" 2>/dev/null \
            | grep -oP "query\[(A|AAAA)\] \K[^ ]+" \
            | grep -Fxf <(printf '%s\n' "$domains") \
            | sort | uniq -c | sort -rn -k1,1 -k2,2 \
            | awk '{print $2}' | head -3 | tr '\n' '|' | sed 's/|$//' || true)
    fi

    # Notification handoff for Phase 3. Pending JSON files are picked up
    # by the host-side delivery script on the next `boxa` invocation
    # (or by a one-shot watcher started alongside the window). Writing
    # the file is fire-and-forget — if no delivery runs, the harvest log
    # is still the canonical record.
    #
    # The pending dir is host-user-owned (see ensure-allow-for-host-state.sh)
    # so the deliver script can rename-claim atomically; the file itself
    # is still written as root:root 0644, so its CONTENTS can't be forged
    # mid-flight by the in-container node user. If the pending dir is
    # missing (pre-Phase-3 install upgraded without `boxa update`), skip
    # the handoff — the harvest log is canonical and the next update will
    # provision the dir.
    if [ -d "$ALLOW_FOR_PENDING_DIR" ] && [ -d "$ALLOW_FOR_TMP_DIR" ]; then
        local pending="${ALLOW_FOR_PENDING_DIR}/.pending-${container}-${ts_safe}.json"
        # Atomic publish via root-only scratch dir + cross-subdir rename.
        # See teardown-allow-for-window.sh and ensure-allow-for-host-state.sh
        # for the full TOCTOU-defence rationale.
        local pending_tmp
        if pending_tmp=$(mktemp "${ALLOW_FOR_TMP_DIR}/pending.XXXXXXXXXX"); then
            cat > "$pending_tmp" <<EOF
{
  "container": "${container}",
  "log_path": "${log_path}",
  "started_at": "${started_at}",
  "ended_at": "$(allow_for::now_iso)",
  "reason": "${reason}",
  "domain_count": ${domain_count},
  "top_domains": "${top_lines}"
}
EOF
            chmod 0644 "$pending_tmp"
            mv "$pending_tmp" "$pending" 2>/dev/null || rm -f "$pending_tmp"
        fi
    fi

    printf 'Allow-for window closed for %s (reason=%s, %d domains captured) — %s\n' \
        "$container" "$reason" "$domain_count" "$log_path"
}
