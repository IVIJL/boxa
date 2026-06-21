#!/bin/bash
# Plain-bash assertions for the host ufw-slot logic in
# scripts/agent-browser-broker.sh. The broker normally runs on the HOST and
# drives real ufw/docker/ip; here we MOCK those externals and exercise the
# pure shell logic for the two issue-14 round-4 findings:
#
#   F1  Pending-vs-owned ufw slot ownership: the crash-window marker carries
#       the subnet only in `ufw_slot_pending_subnet` (NOT the deletable
#       `ufw_slot_subnet`) until ufw confirms the add. Deletion paths key off
#       the owned field only, so a crash while pending never deletes an admin
#       rule.
#   F2  Route-based subnet derivation: `_container_bridge_subnet` picks the
#       network that ROUTES to the relay IP (via `ip route get`), not merely
#       the first network; falls back to the first network WITH a warning when
#       the route lookup fails.
#
# Usage: bash tests/agent-browser-broker.sh
# Each assertion prints PASS/FAIL; non-zero exit on any FAIL.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BROKER="$SCRIPT_DIR/../scripts/agent-browser-broker.sh"

# Source every function definition WITHOUT triggering the final `main "$@"`
# dispatch (which would run a real subcommand / exit). The broker's last line
# is exactly `main "$@"`; strip it. `_log`/`_warn` are real (they write to
# stderr), which is fine for tests.
# shellcheck disable=SC1090
source <(sed '$d' "$BROKER")

# The broker sets `set -euo pipefail` at its top, which the source above
# inherits. This harness DELIBERATELY drives the helpers down their failing
# return paths (refused ufw selectors return 1, etc.) and inspects `$?`, so
# re-enable lenient mode: keep `-u` (unset-var safety) but drop `-e`/pipefail
# so an intentional non-zero return does not abort the whole run.
set +e +o pipefail

fail_count=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n        expected: [%s]\n        actual:   [%s]\n' \
            "$label" "$expected" "$actual"
        fail_count=$((fail_count + 1))
    fi
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) printf 'PASS  %s\n' "$label" ;;
        *) printf 'FAIL  %s\n        expected substring: [%s]\n        in: [%s]\n' \
            "$label" "$needle" "$haystack"; fail_count=$((fail_count + 1)) ;;
    esac
}

# ----------------------------------------------------------------------------
# F1 — pending/owned marker fields + sweep deletion gating
# ----------------------------------------------------------------------------

# A crash-window marker exactly as cmd_start writes it BEFORE `ufw allow`:
# pending subnet set, owned (deletable) ufw_slot_subnet null.
write_pending_marker() {
    local file="$1" subnet="$2"
    cat > "$file" <<EOF
{
  "container": "c1",
  "chrome_pid": 111,
  "bridge_pid_in_container": null,
  "relay_pid_host": null,
  "proxy_pid": 222,
  "watchdog_pid": null,
  "cdp_port_host": 40000,
  "proxy_port_host": 40001,
  "profile_dir": "/var/lib/boxa-agent/profiles/c1-x",
  "download_dir": "/var/lib/boxa-agent/downloads/c1-x",
  "host_allow_ip": "192.168.65.254",
  "ufw_slot_subnet": null,
  "ufw_slot_pending_subnet": "${subnet}",
  "active_network_window": null
}
EOF
}

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# --- the pre-`ufw allow` marker keeps the subnet ONLY in the pending field ---
write_pending_marker "$TMP" "172.20.0.0/16"
assert_eq "F1 marker: deletable ufw_slot_subnet is empty (null) pre-add" \
    "" "$(_state_get "$TMP" ufw_slot_subnet)"
assert_eq "F1 marker: pending subnet carries the value pre-add" \
    "172.20.0.0/16" "$(_state_get "$TMP" ufw_slot_pending_subnet)"

# --- sweep deletion path sees an EMPTY owned subnet → no `ufw delete` ---
# _release_or_retain_ufw_slot is the single deletion gate used by stop/sweep/
# rollback. It must NOT call _close_host_ufw_slot when the owned subnet is
# empty/null. Mock _close_host_ufw_slot to record any invocation.
# SC2317: the mock is invoked indirectly by the code under test, not from
# this top-level script, so shellcheck's reachability analysis flags it.
# Snapshot the REAL helper before shadowing it with the call-counting mock,
# so the F4 selector-validation tests below (which exercise the real close
# chokepoint) can restore it. A bare `unset -f` after the mock would delete
# the real definition outright, not unstack it.
eval "_real_close_host_ufw_slot() $(declare -f _close_host_ufw_slot | sed '1d')"
CLOSE_CALLS=0
# shellcheck disable=SC2317
_close_host_ufw_slot() { CLOSE_CALLS=$((CLOSE_CALLS + 1)); return 0; }

CLOSE_CALLS=0
pending_subnet="$(_state_get "$TMP" ufw_slot_subnet)"   # = "" for a pending marker
_release_or_retain_ufw_slot "192.168.65.254" "40000" "$pending_subnet"; rc=$?
assert_eq "F1 sweep: pending-only marker → release-or-retain returns 0 (nothing to do)" "0" "$rc"
assert_eq "F1 sweep: pending-only marker → _close_host_ufw_slot NOT called (admin rule safe)" \
    "0" "$CLOSE_CALLS"

# Literal JSON "null" (jq-less fallback parse shape) must also be a no-op.
CLOSE_CALLS=0
_release_or_retain_ufw_slot "192.168.65.254" "40000" "null"; rc=$?
assert_eq "F1 sweep: literal null subnet → no close" "0" "$CLOSE_CALLS"
assert_eq "F1 sweep: literal null subnet → returns 0" "0" "$rc"

# --- rc 0 (newly added): promote pending → owned, then the slot IS deletable ---
write_pending_marker "$TMP" "172.20.0.0/16"
_promote_ufw_marker_slot "$TMP" "172.20.0.0/16"
assert_eq "F1 rc0: owned ufw_slot_subnet populated after promote" \
    "172.20.0.0/16" "$(_state_get "$TMP" ufw_slot_subnet)"
assert_eq "F1 rc0: pending field cleared after promote" \
    "" "$(_state_get "$TMP" ufw_slot_pending_subnet)"
CLOSE_CALLS=0
owned_subnet="$(_state_get "$TMP" ufw_slot_subnet)"
_release_or_retain_ufw_slot "192.168.65.254" "40000" "$owned_subnet" >/dev/null
assert_eq "F1 rc0: owned slot → stop/sweep DOES call ufw delete" "1" "$CLOSE_CALLS"

# --- rc 2 (admin pre-existing): clear pending, owned stays empty → never deleted ---
write_pending_marker "$TMP" "172.20.0.0/16"
_clear_ufw_marker_pending "$TMP"
assert_eq "F1 rc2: owned ufw_slot_subnet stays empty (admin rule untouched)" \
    "" "$(_state_get "$TMP" ufw_slot_subnet)"
assert_eq "F1 rc2: pending field cleared" \
    "" "$(_state_get "$TMP" ufw_slot_pending_subnet)"
CLOSE_CALLS=0
admin_subnet="$(_state_get "$TMP" ufw_slot_subnet)"
_release_or_retain_ufw_slot "192.168.65.254" "40000" "$admin_subnet" >/dev/null
assert_eq "F1 rc2: admin marker → ufw delete NOT issued" "0" "$CLOSE_CALLS"

# --- rc 1 (add failed): same as rc2 — no owned slot ---
write_pending_marker "$TMP" "172.20.0.0/16"
_clear_ufw_marker_pending "$TMP"
assert_eq "F1 rc1: no owned slot recorded after failed add" \
    "" "$(_state_get "$TMP" ufw_slot_subnet)"

# restore the real close helper for the F4 selector-validation tests below
eval "_close_host_ufw_slot() $(declare -f _real_close_host_ufw_slot | sed '1d')"
unset -f _real_close_host_ufw_slot

# ----------------------------------------------------------------------------
# F1b — CIDR-contains correctness (used by F2's src→subnet mapping)
# ----------------------------------------------------------------------------
_ipv4_in_cidr "172.20.0.5"   "172.20.0.0/16" && r=0 || r=1
assert_eq "CIDR: 172.20.0.5 ∈ 172.20.0.0/16" "0" "$r"
_ipv4_in_cidr "172.18.0.5"   "172.20.0.0/16" && r=0 || r=1
assert_eq "CIDR: 172.18.0.5 ∉ 172.20.0.0/16" "1" "$r"
_ipv4_in_cidr "10.0.0.7"     "10.0.0.0/24"   && r=0 || r=1
assert_eq "CIDR: 10.0.0.7 ∈ 10.0.0.0/24" "0" "$r"
_ipv4_in_cidr "10.0.1.7"     "10.0.0.0/24"   && r=0 || r=1
assert_eq "CIDR: 10.0.1.7 ∉ 10.0.0.0/24" "1" "$r"
_ipv4_in_cidr "172.18.0.2"   "172.18.0.0/16" && r=0 || r=1
assert_eq "CIDR: 172.18.0.2 ∈ 172.18.0.0/16" "0" "$r"
_ipv4_in_cidr "1.2.3.4"      "0.0.0.0/0"     && r=0 || r=1
assert_eq "CIDR: any ∈ 0.0.0.0/0" "0" "$r"
_ipv4_in_cidr "notanip"      "10.0.0.0/24"   && r=0 || r=1
assert_eq "CIDR: malformed ip → not contained" "1" "$r"
_ipv4_in_cidr "10.0.0.1"     "10.0.0.0"      && r=0 || r=1
assert_eq "CIDR: missing prefix → not contained" "1" "$r"

# ----------------------------------------------------------------------------
# F2 — route-based subnet derivation with mocked docker/ip
# ----------------------------------------------------------------------------
# Two networks: net_a=172.18.0.0/16 (FIRST reported), net_b=172.20.0.0/16
# (SECOND). The relay is reached via net_b's src IP, so the chosen subnet MUST
# be net_b's — proving we follow the route, not the first network.
RELAY_IP="192.168.65.254"

# Mock `docker` for inspect (network list) + network inspect (subnet) + exec
# (ip route get). MOCK_ROUTE_SRC controls what `ip route get` reports.
# SC2317: this mock's body is reached only via the function under test.
MOCK_ROUTE_SRC="172.20.0.9"   # an address on net_b (the SECOND network)
# shellcheck disable=SC2317
docker() {
    case "$1" in
        inspect)
            # `docker inspect <c> --format '{{range .Networks}}...'` → net names
            printf 'net_a\nnet_b\n'
            ;;
        network)
            # `docker network inspect <name> --format '...Subnet...'`
            case "$3" in
                net_a) printf '172.18.0.0/16 \n' ;;
                net_b) printf '172.20.0.0/16 \n' ;;
                *) return 1 ;;
            esac
            ;;
        exec)
            # `docker exec <c> ip -o route get <relay_ip>`
            if [ "$MOCK_ROUTE_SRC" = "__FAIL__" ]; then
                return 1
            fi
            printf '%s via 172.20.0.1 dev eth1 src %s uid 1000 \n' \
                "$RELAY_IP" "$MOCK_ROUTE_SRC"
            ;;
        *) return 1 ;;
    esac
}

# --- multi-network: route src on the SECOND network → second subnet chosen ---
MOCK_ROUTE_SRC="172.20.0.9"
got="$(_container_bridge_subnet "c1" "$RELAY_IP" 2>/dev/null)"
assert_eq "F2 multi-net: subnet follows the ROUTE (net_b), not the first network" \
    "172.20.0.0/16" "$got"

# --- route src on the FIRST network → first subnet chosen (still correct) ---
MOCK_ROUTE_SRC="172.18.0.5"
got="$(_container_bridge_subnet "c1" "$RELAY_IP" 2>/dev/null)"
assert_eq "F2 multi-net: route src on net_a → net_a subnet" \
    "172.18.0.0/16" "$got"

# --- route lookup FAILS → fall back to first network WITH a warning ---
MOCK_ROUTE_SRC="__FAIL__"
warn_out="$(_container_bridge_subnet "c1" "$RELAY_IP" 2>&1 >/dev/null)"
got="$(_container_bridge_subnet "c1" "$RELAY_IP" 2>/dev/null)"
assert_eq "F2 fallback: route lookup failure → first network subnet" \
    "172.18.0.0/16" "$got"
assert_contains "F2 fallback: failure warns visibly (no silent change)" \
    "falling back to the first network" "$warn_out"

# --- route src not in ANY subnet → fall back to first network WITH a warning ---
MOCK_ROUTE_SRC="10.99.99.9"
warn_out="$(_container_bridge_subnet "c1" "$RELAY_IP" 2>&1 >/dev/null)"
got="$(_container_bridge_subnet "c1" "$RELAY_IP" 2>/dev/null)"
assert_eq "F2 fallback: src in no subnet → first network subnet" \
    "172.18.0.0/16" "$got"
assert_contains "F2 fallback: no-match warns visibly" \
    "falling back to the first network" "$warn_out"

# --- single-network container behaves exactly as before (no warning) ---
# shellcheck disable=SC2317
docker() {
    case "$1" in
        inspect) printf 'net_a\n' ;;
        network) [ "$3" = net_a ] && printf '172.18.0.0/16 \n' || return 1 ;;
        exec)    printf '%s via 172.18.0.1 dev eth0 src 172.18.0.7 \n' "$RELAY_IP" ;;
        *) return 1 ;;
    esac
}
got="$(_container_bridge_subnet "c1" "$RELAY_IP" 2>/dev/null)"
assert_eq "F2 single-net: unchanged behaviour (the one subnet)" \
    "172.18.0.0/16" "$got"
warn_out="$(_container_bridge_subnet "c1" "$RELAY_IP" 2>&1 >/dev/null)"
assert_eq "F2 single-net: no fallback warning emitted" "" "$warn_out"

# --- no relay IP arg → straight to first-network fallback, no route attempt ---
got="$(_container_bridge_subnet "c1" "" 2>/dev/null)"
assert_eq "F2 no-relay: first-network fallback" "172.18.0.0/16" "$got"

unset -f docker

# ----------------------------------------------------------------------------
# F3 — strict ufw-selector validators (#14 review)
# ----------------------------------------------------------------------------
# The relay IP, CDP port and bridge subnet flow from the developer-writable
# session JSON into a privileged `sudo ufw allow|delete`. _is_ipv4 /
# _is_tcp_port / _is_ipv4_cidr are the strict validators that gate them.

# --- _is_ipv4 ---
for good in 192.168.65.254 0.0.0.0 255.255.255.255 172.18.0.1 1.2.3.4; do
    _is_ipv4 "$good" && r=0 || r=1
    assert_eq "validator: _is_ipv4 accepts ${good}" "0" "$r"
done
for bad in "1.2.3.999" "1.2.3" "1.2.3.4.5" "256.0.0.1" "1.2.3.4 " " 1.2.3.4" \
           "1.2.3.-1" "a.b.c.d" "1.2.3.04" "010.0.0.1" "; rm -rf" "1.2.3.4; reboot" ""; do
    _is_ipv4 "$bad" && r=0 || r=1
    assert_eq "validator: _is_ipv4 rejects [${bad}]" "1" "$r"
done

# --- _is_tcp_port ---
for good in 1 22 80 443 40000 65535; do
    _is_tcp_port "$good" && r=0 || r=1
    assert_eq "validator: _is_tcp_port accepts ${good}" "0" "$r"
done
for bad in "0" "70000" "65536" "08" "22; reboot" "-1" " 80" "80 " "abc" "4e4" ""; do
    _is_tcp_port "$bad" && r=0 || r=1
    assert_eq "validator: _is_tcp_port rejects [${bad}]" "1" "$r"
done

# --- _is_ipv4_cidr ---
for good in "172.18.0.0/16" "10.0.0.0/24" "0.0.0.0/0" "192.168.1.0/32"; do
    _is_ipv4_cidr "$good" && r=0 || r=1
    assert_eq "validator: _is_ipv4_cidr accepts ${good}" "0" "$r"
done
for bad in "172.18.0.0/33" "172.18.0.0" "999.0.0.0/16" "172.18.0.0/-1" \
           "172.18.0.0/16/8" "10.0.0.0/ 8" "10.0.0.0/0x10" "; rm -rf /16" \
           "172.18.0.0/16; reboot" ""; do
    _is_ipv4_cidr "$bad" && r=0 || r=1
    assert_eq "validator: _is_ipv4_cidr rejects [${bad}]" "1" "$r"
done

# ----------------------------------------------------------------------------
# F4 — open/close chokepoints refuse to invoke `sudo ufw` on bad selectors
# ----------------------------------------------------------------------------
# Mock `sudo ufw ...` so a real invocation is recorded. The open path runs
# `ufw` inside a command-substitution subshell ($(...)), so a shell-variable
# counter would not survive back to the parent; record into a temp file
# instead and read it back. Each recorded `sudo ufw` invocation appends its
# full argv line; ufw_calls()/ufw_last() read it.
# SC2317: the mock body is reached only via the helpers under test.
UFW_CALL_LOG="$(mktemp)"
trap 'rm -f "$TMP" "$UFW_CALL_LOG"' EXIT
ufw_calls() { grep -c . "$UFW_CALL_LOG" 2>/dev/null || true; }
ufw_last()  { tail -n1 "$UFW_CALL_LOG" 2>/dev/null || true; }
reset_ufw_log() { : > "$UFW_CALL_LOG"; }
reset_ufw_log
# shellcheck disable=SC2317
sudo() {
    if [ "${1:-}" = "ufw" ]; then
        printf '%s\n' "$*" >> "$UFW_CALL_LOG"
        # `ufw allow ...` → "Rule added"; `ufw delete ...` → silent success.
        case "${2:-}" in
            allow) printf 'Rule added\n' ;;
        esac
        return 0
    fi
    # Any other sudo use in these helpers is unexpected for the test.
    return 0
}
# command -v ufw must succeed for _close_host_ufw_slot to proceed past its
# "ufw absent → no-op" guard. Mock it so the real-binary check passes.
# shellcheck disable=SC2317
command() {
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "ufw" ]; then
        return 0
    fi
    builtin command "$@"
}

GOOD_IP="192.168.65.254"; GOOD_PORT="40000"; GOOD_SUBNET="172.18.0.0/16"

# --- OPEN: well-formed → ufw IS invoked (adds the rule, rc 0) ---
reset_ufw_log
_open_host_ufw_slot "$GOOD_IP" "$GOOD_PORT" "$GOOD_SUBNET" >/dev/null 2>&1; rc=$?
assert_eq "open good: ufw allow invoked once" "1" "$(ufw_calls)"
assert_eq "open good: returns 0 (newly added)" "0" "$rc"
assert_contains "open good: selector well-formed" "allow proto tcp from 172.18.0.0/16 to 192.168.65.254 port 40000" "$(ufw_last)"

# --- OPEN: malformed relay IP → NO ufw call, refuses (rc 1), warns ---
for bad_ip in "1.2.3.999" "1.2.3" "; rm -rf" ""; do
    reset_ufw_log
    warn="$(_open_host_ufw_slot "$bad_ip" "$GOOD_PORT" "$GOOD_SUBNET" 2>&1 >/dev/null)"; rc=$?
    assert_eq "open bad-ip [${bad_ip}]: NO ufw invocation" "0" "$(ufw_calls)"
    assert_eq "open bad-ip [${bad_ip}]: refuses (rc 1)" "1" "$rc"
    # Empty IP hits the empty-arg guard (also rc 1, no call); non-empty hits
    # the named-field warning.
    if [ -n "$bad_ip" ]; then
        assert_contains "open bad-ip [${bad_ip}]: warns naming relay IP" "malformed relay IP" "$warn"
    fi
done

# --- OPEN: malformed port → NO ufw call ---
for bad_port in "0" "70000" "22; reboot" "08"; do
    reset_ufw_log
    warn="$(_open_host_ufw_slot "$GOOD_IP" "$bad_port" "$GOOD_SUBNET" 2>&1 >/dev/null)"; rc=$?
    assert_eq "open bad-port [${bad_port}]: NO ufw invocation" "0" "$(ufw_calls)"
    assert_eq "open bad-port [${bad_port}]: refuses (rc 1)" "1" "$rc"
    assert_contains "open bad-port [${bad_port}]: warns naming port" "malformed CDP port" "$warn"
done

# --- OPEN: malformed subnet → NO ufw call ---
for bad_subnet in "172.18.0.0/33" "172.18.0.0" "999.0.0.0/16" "172.18.0.0/16; reboot"; do
    reset_ufw_log
    warn="$(_open_host_ufw_slot "$GOOD_IP" "$GOOD_PORT" "$bad_subnet" 2>&1 >/dev/null)"; rc=$?
    assert_eq "open bad-subnet [${bad_subnet}]: NO ufw invocation" "0" "$(ufw_calls)"
    assert_eq "open bad-subnet [${bad_subnet}]: refuses (rc 1)" "1" "$rc"
    assert_contains "open bad-subnet [${bad_subnet}]: warns naming subnet" "malformed bridge subnet" "$warn"
done

# --- CLOSE: well-formed → ufw delete IS invoked, returns 0 ---
reset_ufw_log
_close_host_ufw_slot "$GOOD_IP" "$GOOD_PORT" "$GOOD_SUBNET" >/dev/null 2>&1; rc=$?
assert_eq "close good: ufw delete invoked once" "1" "$(ufw_calls)"
assert_eq "close good: returns 0" "0" "$rc"
assert_contains "close good: delete selector well-formed" "delete allow proto tcp from 172.18.0.0/16 to 192.168.65.254 port 40000" "$(ufw_last)"

# --- CLOSE: malformed relay IP → NO ufw delete, returns 1 (retain), warns ---
for bad_ip in "1.2.3.999" "1.2.3" "; rm -rf"; do
    reset_ufw_log
    warn="$(_close_host_ufw_slot "$bad_ip" "$GOOD_PORT" "$GOOD_SUBNET" 2>&1 >/dev/null)"; rc=$?
    assert_eq "close bad-ip [${bad_ip}]: NO ufw delete invocation" "0" "$(ufw_calls)"
    assert_eq "close bad-ip [${bad_ip}]: returns 1 (cannot safely release → retain)" "1" "$rc"
    assert_contains "close bad-ip [${bad_ip}]: warns naming relay IP" "malformed relay IP" "$warn"
done

# --- CLOSE: malformed port → NO ufw delete, returns 1 ---
for bad_port in "0" "70000" "22; reboot" "08"; do
    reset_ufw_log
    warn="$(_close_host_ufw_slot "$GOOD_IP" "$bad_port" "$GOOD_SUBNET" 2>&1 >/dev/null)"; rc=$?
    assert_eq "close bad-port [${bad_port}]: NO ufw delete invocation" "0" "$(ufw_calls)"
    assert_eq "close bad-port [${bad_port}]: returns 1 (retain)" "1" "$rc"
    assert_contains "close bad-port [${bad_port}]: warns naming port" "malformed CDP port" "$warn"
done

# --- CLOSE: malformed subnet → NO ufw delete, returns 1 ---
for bad_subnet in "172.18.0.0/33" "172.18.0.0" "999.0.0.0/16" "172.18.0.0/16; reboot"; do
    reset_ufw_log
    warn="$(_close_host_ufw_slot "$GOOD_IP" "$GOOD_PORT" "$bad_subnet" 2>&1 >/dev/null)"; rc=$?
    assert_eq "close bad-subnet [${bad_subnet}]: NO ufw delete invocation" "0" "$(ufw_calls)"
    assert_eq "close bad-subnet [${bad_subnet}]: returns 1 (retain)" "1" "$rc"
    assert_contains "close bad-subnet [${bad_subnet}]: warns naming subnet" "malformed bridge subnet" "$warn"
done

# --- _release_or_retain_ufw_slot: a malformed (non-empty/non-null) selector
#     passes the empty/null guard but the close chokepoint blocks it → RETAIN ---
reset_ufw_log
warn="$(_release_or_retain_ufw_slot "1.2.3.999" "$GOOD_PORT" "$GOOD_SUBNET" 2>&1 >/dev/null)"; rc=$?
assert_eq "release malformed: NO ufw delete invocation" "0" "$(ufw_calls)"
assert_eq "release malformed: returns 1 (retain state file)" "1" "$rc"
assert_contains "release malformed: surfaces retain warning" "Retaining the session state" "$warn"

# --- _release_or_retain_ufw_slot: well-formed selector still deletes (rc 0) ---
reset_ufw_log
_release_or_retain_ufw_slot "$GOOD_IP" "$GOOD_PORT" "$GOOD_SUBNET" >/dev/null 2>&1; rc=$?
assert_eq "release good: ufw delete invoked" "1" "$(ufw_calls)"
assert_eq "release good: returns 0 (may drop state)" "0" "$rc"

unset -f sudo
unset -f command

# ----------------------------------------------------------------------------
# F5 — X display grant revoke (#12 review): revoke the shared per-uid
#      `xhost +SI:localuser:boxa-agent` grant ONLY when the last
#      agent-browser session goes away, never while another session is live.
#
# The broker runs on the HOST and drives a real xhost/X server, which can't
# run here. We MOCK `host_platform::detect`, `command -v`, and `xhost`, point
# SESSIONS_DIR at a scratch dir, and exercise the pure reference-count + gate
# logic in `_count_other_live_sessions`, `_revoke_agent_x_display_access`, and
# `_revoke_x_display_if_last_session`.
# ----------------------------------------------------------------------------

X_SESSIONS_DIR="$(mktemp -d)"
SESSIONS_DIR="$X_SESSIONS_DIR"
# The broker derives XHOST_GRANT_LOCKFILE from SESSIONS_DIR at source time (when
# it still points at the real ~/.local/state path). Re-point it at the scratch
# dir so the X-grant flock (finding 1) is taken against a writable test path —
# otherwise the broker would fall back to its lock-free warning branch here.
# SC2034: read by the sourced broker (`_with_xhost_grant_lock`), not by this
# harness directly, so shellcheck cannot see the use.
# shellcheck disable=SC2034
XHOST_GRANT_LOCKFILE="$X_SESSIONS_DIR/.xhost-grant.lock"

# Record every `xhost ...` invocation so assertions can check call count and
# the exact selector. SC2317: the mock body is reached only via the helpers
# under test, not called directly from this script.
XHOST_CALL_LOG="$(mktemp)"
trap 'rm -f "$TMP" "$XHOST_CALL_LOG"; rm -rf "$X_SESSIONS_DIR"' EXIT
xhost_calls() { grep -c . "$XHOST_CALL_LOG" 2>/dev/null || true; }
xhost_last()  { tail -n1 "$XHOST_CALL_LOG" 2>/dev/null || true; }
reset_xhost_log() { : > "$XHOST_CALL_LOG"; }
reset_xhost_log
# shellcheck disable=SC2317
xhost() { printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"; return 0; }

# `command -v xhost` / `command -v host_platform::detect` must report present
# so the revoke proceeds past its missing-tool guard. Default: xhost present.
# Toggle XHOST_PRESENT=0 to simulate the missing-tool teardown path.
XHOST_PRESENT=1
# shellcheck disable=SC2317
command() {
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "xhost" ]; then
        [ "$XHOST_PRESENT" = "1" ] && return 0
        return 1
    fi
    builtin command "$@"
}

# Mock the platform detector. Default linux (the only platform that grants).
MOCK_PLATFORM="linux"
# shellcheck disable=SC2317
host_platform::detect() { printf '%s\n' "$MOCK_PLATFORM"; }

# Chrome-liveness mocks (#12 review finding 2). `_state_file_is_display_consumer`
# now validates a claimed-running chrome_pid against the broker's real liveness
# check (`_pid_matches_marker` on the profile-dir marker, falling back to
# `_pid_alive_on_host`) before counting the file as a consumer — so a crashed
# Chrome or a stale post-reboot file does not pin the shared grant. We can't run
# real processes here, so mock both probes to consult a controllable set of
# "alive" PIDs. ALIVE_PIDS is a space-delimited list of PIDs the mocks treat as
# alive; a PID outside it is "dead" (the crashed-Chrome / stale-file case).
# SC2317: the helper + the two mocks are reached only via the predicate under
# test, not from this top-level script.
ALIVE_PIDS=" 4242 "        # the default stub chrome_pid
# shellcheck disable=SC2317
pid_is_alive() { case " $ALIVE_PIDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
# shellcheck disable=SC2317
_pid_matches_marker() { pid_is_alive "${1:-}"; }
# shellcheck disable=SC2317
_pid_alive_on_host() { pid_is_alive "${1:-}"; }

# Process START-TIME identity mock (#12 review P2). The real
# `_pid_starttime_on_host` reads field 22 of `/proc/<pid>/stat`; we can't run
# real processes, so map PID → its recorded starttime here. A PID absent from
# the map (and the default-stub PIDs) returns the deterministic default
# `DEFAULT_STARTTIME`, so the existing F18 claim-write tests stay reproducible
# regardless of what the host's real /proc happens to contain at that PID. Set
# `PID_STARTTIME[<pid>]=""` to model an UNREADABLE /proc (bare-liveness
# fallback). SC2317: reached only via the helpers under test.
DEFAULT_STARTTIME="100"
declare -A PID_STARTTIME=()
# shellcheck disable=SC2317
_pid_starttime_on_host() {
    local pid="${1:-}"
    [ -n "$pid" ] || { printf '%s\n' ""; return 0; }
    if [ -n "${PID_STARTTIME[$pid]+set}" ]; then
        printf '%s\n' "${PID_STARTTIME[$pid]}"
        return 0
    fi
    printf '%s\n' "$DEFAULT_STARTTIME"
}

# Helper: drop a LIVE display-consumer session state file (has a non-null
# chrome_pid whose PID is mocked ALIVE, a profile_dir for the identity marker,
# no ufw_retry_only marker) for a container into SESSIONS_DIR.
# Post-#12-review, the X-revoke reference count
# (`_count_other_live_sessions` → `_state_file_is_display_consumer`) only
# counts files whose Chrome is still up AND alive (finding 2), so a sibling that
# should BLOCK the revoke must carry a live chrome_pid.
#
# Per-display-refcount review: the grant is per-DISPLAY, so a live sibling that
# should BLOCK the revoke of display D must also carry `granted_display: D`. The
# optional second arg is that display (default `:0`, the common single-display
# case these tests model). `write_session_stub_on <c> <display>` drops a peer on
# a SPECIFIC display for the per-display scoping tests (F10).
write_session_stub_on() {
    printf '{ "chrome_pid": 4242, "proxy_pid": 4243, "granted_display": "%s", "profile_dir": "/var/lib/boxa-agent/profiles/%s-x" }\n' \
        "$2" "$1" > "$SESSIONS_DIR/$1.json"
}
write_session_stub() {
    write_session_stub_on "$1" "${2:-:0}"
}
# Helper: drop a ufw-retry-only RETAINED state file (Chrome torn down): nulled
# PIDs + the explicit `ufw_retry_only: true` marker. This is what cmd_stop
# leaves behind when a `sudo ufw delete` is deferred — it must NOT be counted
# as a live display consumer.
write_retry_only_stub() {
    cat > "$SESSIONS_DIR/$1.json" <<'EOF'
{
  "ufw_retry_only": true,
  "chrome_pid": null,
  "proxy_pid": null,
  "host_allow_ip": "192.168.65.254",
  "cdp_port_host": 40000,
  "ufw_slot_subnet": "172.18.0.0/16"
}
EOF
}
# Per-display broker-ownership marker (#12 review finding 3). The revoke now
# fires ONLY when the broker OWNS the grant on that display — i.e. the marker
# `$SESSIONS_DIR/xhost-owned-<sanitized-display>` exists (the broker created it
# at grant time because boxa-agent was NOT already authorized). The F5-F11
# scenarios all model "the broker added the grant", so by default we seed the
# ownership markers for the displays those tests exercise (:0, :1, :7). The
# dedicated F12 section drives the marker-absent / query-fail / sanitization
# cases explicitly. `broker_owns_display <display>` creates one marker via the
# real path helper so the filename sanitization is exercised end-to-end.
# X-session token mock (#12 review P1). The real `_x_session_token` reads the X
# socket inode/mtime + boot id; we can't run a real X server, so return a
# controllable token. `MOCK_X_TOKEN` is the CURRENT X session's token (what a
# fresh grant stamps and the already-authorized revalidation compares against).
# Set it to "" to model an UNDERIVABLE token (no boot id / no X socket), which
# the safe default must treat as "keep the marker". SC2317: reached only via the
# grant helper under test.
MOCK_X_TOKEN="boot=AAA;sock=1:1000"
# Snapshot the REAL `_x_session_token` (local-vs-remote socket identity, #12
# review P2) BEFORE shadowing it with the mock, so the dedicated F24 section can
# restore and exercise it directly. SC2317: the body is reached only via that
# restore + the grant helper under test.
eval "_real_x_session_token() $(declare -f _x_session_token | sed '1d')"
# A SECOND, never-unset snapshot of the real token derivation, owned by the F1
# (server-identity) block. F24 `unset`s `_real_x_session_token` when it finishes,
# but F1 runs later and still needs the genuine socket-backed token to verify
# that `:N` and a socket-present `localhost:N` derive the SAME (real) token.
# SC2317: reached only via the F1 token-consistency assertions.
eval "_f1_real_x_session_token() $(declare -f _x_session_token | sed '1d')"
# shellcheck disable=SC2317
_x_session_token() { printf '%s\n' "$MOCK_X_TOKEN"; }

# Stamp a broker-ownership marker with a SPECIFIC X-session token (the second
# arg; defaults to the current MOCK_X_TOKEN), exactly as the real grant path
# writes it (`xsession=<token>`). The marker's mere existence is still the
# ownership signal the revoke path keys on; the token is extra content used only
# by the already-authorized staleness check.
broker_owns_display() {
    local m token="${2-$MOCK_X_TOKEN}"
    m="$(_xhost_ownership_marker_path "$1")"
    [ -n "$m" ] && printf 'xsession=%s\n' "$token" > "$m"
}
seed_owned_markers() {
    broker_owns_display ":0"
    broker_owns_display ":1"
    broker_owns_display ":7"
}
clear_markers() { rm -f "$SESSIONS_DIR"/xhost-owned-* 2>/dev/null || true; }
# Default clear: wipe state files AND re-seed the broker-owned markers so the
# reference-count / env-independence / per-display tests (which assume the
# broker added the grant) see a revoke fire when the count says "last".
clear_sessions() { rm -f "$SESSIONS_DIR"/*.json 2>/dev/null || true; clear_markers; seed_owned_markers; }

# Baseline gates: linux + DISPLAY set.
export DISPLAY=":0"

# --- _count_other_live_sessions excludes THIS container ---
clear_sessions
write_session_stub "easyjukebox-api"
assert_eq "count: only own session present → 0 others" \
    "0" "$(_count_other_live_sessions "easyjukebox-api")"
write_session_stub "otherproj"
assert_eq "count: one sibling session → 1 other" \
    "1" "$(_count_other_live_sessions "easyjukebox-api")"
write_session_stub "thirdproj"
assert_eq "count: two sibling sessions → 2 others" \
    "2" "$(_count_other_live_sessions "easyjukebox-api")"

# --- LAST session going away (no other state files) → revoke IS called ---
# Post-#12-review the revoke targets a PERSISTED granted_display passed by the
# caller (cmd_stop / the failed-start cleanup), NOT the ambient $DISPLAY — so
# the common no-$DISPLAY teardown paths still release the grant (finding 1). The
# tests pass the persisted display explicitly, mirroring those call sites.
clear_sessions
reset_xhost_log
_revoke_x_display_if_last_session "easyjukebox-api" ":0"
assert_eq "last session: xhost revoke invoked once" "1" "$(xhost_calls)"
assert_contains "last session: revoke selector is the per-uid removal" \
    "xhost -SI:localuser:boxa-agent" "$(xhost_last)"
# Revoke logs visibly (stdout via _log). Re-seed the broker-ownership marker:
# the revoke above consumed it (finding 3 removes the marker once the broker-
# added grant is gone), so a fresh "broker owns the grant" state is needed for
# this second revoke to fire and log.
clear_sessions
reset_xhost_log
revoke_log="$(_revoke_x_display_if_last_session "easyjukebox-api" ":0" 2>&1)"
assert_contains "last session: revoke is logged (not silent)" \
    "Revoking boxa-agent X display access" "$revoke_log"

# --- ANOTHER live session present → revoke NOT called (grant preserved) ---
clear_sessions
write_session_stub "survivor"
reset_xhost_log
_revoke_x_display_if_last_session "easyjukebox-api"
assert_eq "sibling alive: revoke NOT invoked (grant preserved for survivor)" \
    "0" "$(xhost_calls)"

# --- revoke gate: NO persisted granted_display → no-op (finding 1) ---
# The revoke is now gated on a persisted granted_display argument, NOT the
# ambient $DISPLAY. An absent/empty persisted display means the session never
# granted (a headless start), so the revoke is a clean no-op — independent of
# whatever $DISPLAY the teardown process happens to have.
clear_sessions
reset_xhost_log
saved_display="$DISPLAY"
unset DISPLAY
_revoke_agent_x_display_access ":0"   # persisted display present → DOES revoke
assert_eq "gate no ambient DISPLAY: persisted display still revokes (env-independent)" \
    "1" "$(xhost_calls)"
assert_contains "gate no ambient DISPLAY: revoke targets the persisted display :0" \
    "xhost -SI:localuser:boxa-agent" "$(xhost_last)"
reset_xhost_log
_revoke_agent_x_display_access ""      # no persisted display → no-op
assert_eq "gate empty persisted display: revoke is a no-op" "0" "$(xhost_calls)"
reset_xhost_log
_revoke_agent_x_display_access "null"  # literal null (jq-less parse) → no-op
assert_eq "gate null persisted display: revoke is a no-op" "0" "$(xhost_calls)"
export DISPLAY="$saved_display"

# --- revoke gate: non-linux platform → no-op (even with a persisted display) ---
clear_sessions
reset_xhost_log
MOCK_PLATFORM="wsl2"
_revoke_agent_x_display_access ":0"
assert_eq "gate non-linux: revoke is a no-op" "0" "$(xhost_calls)"
MOCK_PLATFORM="macos"
_revoke_agent_x_display_access ":0"
assert_eq "gate macos: revoke is a no-op" "0" "$(xhost_calls)"
MOCK_PLATFORM="linux"

# --- revoke gate: xhost missing at teardown → warn/no-op, no _die ---
clear_sessions
reset_xhost_log
XHOST_PRESENT=0
revoke_missing="$(_revoke_agent_x_display_access ":0" 2>&1)"; rc=$?
assert_eq "gate xhost missing: no xhost invocation" "0" "$(xhost_calls)"
assert_eq "gate xhost missing: returns 0 (no _die on teardown)" "0" "$rc"
assert_contains "gate xhost missing: warns visibly" \
    "cannot revoke boxa-agent X display access" "$revoke_missing"
XHOST_PRESENT=1

# --- cmd_start rollback semantics, modelled on the per-uid gate ---
# A failed start with NO other session → revoke fires (single-session case:
# a failed launch leaves no lingering grant, the reviewer's exact concern). The
# rollback path passes the captured granted_display (here :0), env-independent.
clear_sessions
reset_xhost_log
_revoke_x_display_if_last_session "easyjukebox-api" ":0"
assert_eq "start rollback (no sibling): revoke fires" "1" "$(xhost_calls)"
# A failed start WITH another live session → revoke must NOT fire.
clear_sessions
write_session_stub "concurrent-other"
reset_xhost_log
_revoke_x_display_if_last_session "easyjukebox-api" ":0"
assert_eq "start rollback (sibling alive): revoke does NOT fire" "0" "$(xhost_calls)"

# ----------------------------------------------------------------------------
# F6 — X display grant LIFECYCLE robustness (#12 review round-7): the grant
#      lives iff ≥1 live DISPLAY-CONSUMING session exists; it is revoked the
#      moment the last consumer goes away — via clean stop, failed-start
#      rollback, OR a `set -e`/trap abort. A state file retained ONLY for a
#      deferred ufw-delete (Chrome torn down) is NOT a display consumer.
# ----------------------------------------------------------------------------

# --- display-consumer predicate: live vs ufw-retry-only vs no-chrome ---
clear_sessions
write_session_stub "live-one"
_state_file_is_display_consumer "$SESSIONS_DIR/live-one.json" && r=0 || r=1
assert_eq "predicate: live chrome_pid file IS a display consumer" "0" "$r"

write_retry_only_stub "retry-one"
_state_file_is_display_consumer "$SESSIONS_DIR/retry-one.json" && r=0 || r=1
assert_eq "predicate: ufw-retry-only file is NOT a display consumer" "1" "$r"

printf '{ "chrome_pid": null }\n' > "$SESSIONS_DIR/nochrome.json"
_state_file_is_display_consumer "$SESSIONS_DIR/nochrome.json" && r=0 || r=1
assert_eq "predicate: null chrome_pid file is NOT a display consumer" "1" "$r"

# --- count EXCLUDES ufw-retry-only siblings, COUNTS live ones ---
clear_sessions
write_retry_only_stub "retry-sibling"
assert_eq "count: a ufw-retry-only sibling is NOT counted (not a consumer)" \
    "0" "$(_count_other_live_sessions "easyjukebox-api")"
write_session_stub "live-sibling"
assert_eq "count: live sibling counted, retry-only still excluded → 1" \
    "1" "$(_count_other_live_sessions "easyjukebox-api")"

# --- cmd_stop FINDING 1: ufw delete FAILS (retain) + no other live consumer
#     → X revoke IS called (decoupled from ufw-retain), and the retained file
#     is marked Chrome-torn-down. We exercise the real decoupled gate the new
#     cmd_stop runs: mark-retry-only THEN revoke-if-last. ---
clear_sessions
# This session's own FULL state file (as cmd_start wrote it: live chrome_pid +
# a broker-owned ufw_slot_subnet), retained + marked by the new cmd_stop before
# the decoupled revoke. No OTHER session present.
cat > "$SESSIONS_DIR/easyjukebox-api.json" <<'EOF'
{
  "container": "easyjukebox-api",
  "granted_display": ":0",
  "chrome_pid": 4242,
  "proxy_pid": 4243,
  "host_allow_ip": "192.168.65.254",
  "cdp_port_host": 40000,
  "ufw_slot_subnet": "172.18.0.0/16",
  "active_network_window": null
}
EOF
# cmd_stop captures granted_display BEFORE marking the file (finding 1).
captured_display="$(_state_get "$SESSIONS_DIR/easyjukebox-api.json" granted_display)"
_mark_state_file_ufw_retry_only "$SESSIONS_DIR/easyjukebox-api.json"
assert_eq "F1 decouple: retained file marked ufw_retry_only=true" \
    "true" "$(_state_get "$SESSIONS_DIR/easyjukebox-api.json" ufw_retry_only)"
assert_eq "F1 decouple: retained file chrome_pid nulled" \
    "" "$(_state_get "$SESSIONS_DIR/easyjukebox-api.json" chrome_pid)"
assert_eq "F1 decouple: retained file keeps ufw_slot_subnet for sweep retry" \
    "172.18.0.0/16" "$(_state_get "$SESSIONS_DIR/easyjukebox-api.json" ufw_slot_subnet)"
assert_eq "F1 decouple: granted_display survives the retry-only mark" \
    ":0" "$(_state_get "$SESSIONS_DIR/easyjukebox-api.json" granted_display)"
reset_xhost_log
# Decoupled revoke: even though THIS session's file is still on disk (retained),
# it is not a consumer (excluded by name AND by the retry-only marker), and no
# OTHER consumer exists → revoke fires against the captured display.
_revoke_x_display_if_last_session "easyjukebox-api" "$captured_display"
assert_eq "F1 decouple: ufw deferred + no other consumer → X revoke FIRES" \
    "1" "$(xhost_calls)"

# --- a retained ufw-retry-only file present while ANOTHER session stops:
#     the retained file is NOT counted, so the truly-last live session's stop
#     revokes; a genuinely live other session DOES block it. ---
clear_sessions
write_retry_only_stub "retained-elsewhere"   # not a consumer
reset_xhost_log
# "otherproj" is the last LIVE consumer stopping; the retry-only file must not
# keep the grant alive. Its captured granted_display (:0) is passed through.
_revoke_x_display_if_last_session "otherproj" ":0"
assert_eq "F1 decouple: retry-only sibling does NOT block last live stop's revoke" \
    "1" "$(xhost_calls)"
# Now add a genuinely live sibling: it MUST block the revoke.
write_session_stub "genuinely-live"
reset_xhost_log
_revoke_x_display_if_last_session "otherproj" ":0"
assert_eq "F1 decouple: a live consumer sibling DOES block revoke" \
    "0" "$(xhost_calls)"

# ----------------------------------------------------------------------------
# F7 — consolidated failed-start cleanup + EXIT trap (#12 review, finding 2).
#      _cleanup_failed_start is the single idempotent teardown chokepoint armed
#      by an EXIT trap at the grant. Mock the externals it touches and drive it
#      directly with the `_CFS_*` tracking vars cmd_start would have set.
# ----------------------------------------------------------------------------

# Mocks: docker (container-side slot close is a no-op here — container "not
# running"), sudo (kill is a no-op), and a kill-recording log. The X revoke
# path reuses the xhost mock above.
# shellcheck disable=SC2317
docker() {
    case "$1" in
        ps) return 0 ;;            # _container_running greps output; print none
        exec) return 0 ;;
        *) return 0 ;;
    esac
}
# Record kill targets so we can assert the tracked PIDs were torn down.
KILL_LOG="$(mktemp)"
# shellcheck disable=SC2317
sudo() {
    if [ "${1:-}" = "-u" ] && [ "${3:-}" = "kill" ]; then
        printf '%s\n' "${4:-}" >> "$KILL_LOG"
        return 0
    fi
    # `sudo test -d ...` (used by _cleanup_session_dirs) → say "absent".
    return 1
}
# command -v xhost present; _container_running uses `docker ps | grep -q .`
# which returns 1 (no output) so the container-side slot close is skipped.
reset_kill_log() { : > "$KILL_LOG"; }

# Host-PID identity guard (#12 review, the host-side analog of F17's in-container
# guard). The cleanup now gates EACH host kill on `_pid_matches_marker`, reusing
# the same markers cmd_stop / the sweep use:
#   Chrome — `--user-data-dir=<profile_dir>`
#   relay  — `TCP-LISTEN:<cdp_port>`
#   proxy  — `--listen 127.0.0.1:<proxy_port>`
# We can't run real processes, so model identity with a controllable map from PID
# → the cmdline-marker that PID would expose. `_pid_matches_marker pid marker`
# returns 0 only when the PID is in EXPECTED_MARKER and the queried marker equals
# the one that PID actually carries — exactly the real predicate's contract (PID
# alive AND its cmdline contains the marker). An empty/unmapped PID, or a marker
# that does not match the PID's recorded one (the PID-reuse / already-gone case),
# returns 1 → no kill. This OVERRIDES the simpler F5 mock for the F7 block.
declare -A EXPECTED_MARKER=()
reset_expected_markers() { EXPECTED_MARKER=(); }
# shellcheck disable=SC2317
_pid_matches_marker() {
    local pid="${1:-}" marker="${2:-}"
    [ -n "$pid" ] || return 1
    [ -n "$marker" ] || return 1
    [ -n "${EXPECTED_MARKER[$pid]:-}" ] || return 1   # PID gone / not ours
    [ "${EXPECTED_MARKER[$pid]}" = "$marker" ] || return 1   # PID reused → mismatch
    return 0
}

# Reset the CFS tracking vars to a known clean baseline before each scenario.
# `_CFS_GRANTED_DISPLAY` is the display captured at grant time; the cleanup
# revokes against it env-independently (finding 1), so the trap path tears the
# grant down even when fired from a context with no ambient $DISPLAY.
#
# Args: container chrome_pid proxy_pid [relay_pid]. The profile dir / cdp port /
# proxy port are seeded to fixed values so the cleanup can rebuild the SAME
# identity markers the kills are gated on; the per-scenario EXPECTED_MARKER map
# decides MATCH vs MISMATCH for each PID.
CFS_PROFILE="/var/lib/boxa-agent/profiles/cfs-x"
CFS_CDP_PORT="9100"
CFS_PROXY_PORT="9200"
cfs_reset() {
    _CFS_DONE=0
    _CFS_CONTAINER="$1"
    _CFS_PROFILE_DIR="$CFS_PROFILE"
    _CFS_DOWNLOAD_DIR=""
    _CFS_CHROME_PID="$2"
    _CFS_RELAY_PID="${4:-}"
    _CFS_PROXY_PID="$3"
    _CFS_PROXY_PORT="$CFS_PROXY_PORT"
    _CFS_HOST_ALLOW_IP=""
    _CFS_CDP_PORT="$CFS_CDP_PORT"
    _CFS_UFW_SLOT_SUBNET=""
    _CFS_GRANTED_DISPLAY=":0"
}
# Seed EXPECTED_MARKER so each tracked PID reports as its REAL process (identity
# MATCHES) — the common "processes still alive at rollback" case.
cfs_mark_all_alive() {
    reset_expected_markers
    [ -n "$_CFS_CHROME_PID" ] && EXPECTED_MARKER[$_CFS_CHROME_PID]="--user-data-dir=$_CFS_PROFILE_DIR"
    [ -n "$_CFS_RELAY_PID" ]  && EXPECTED_MARKER[$_CFS_RELAY_PID]="TCP-LISTEN:${_CFS_CDP_PORT}"
    [ -n "$_CFS_PROXY_PID" ]  && EXPECTED_MARKER[$_CFS_PROXY_PID]="--listen 127.0.0.1:${_CFS_PROXY_PORT}"
    return 0
}

# --- single-session abort (no sibling) → cleanup kills tracked PIDs AND
#     revokes the grant (the set -e / trap path the reviewer flagged). All three
#     tracked host PIDs report MATCHING identity, so every kill is issued. ---
clear_sessions
reset_xhost_log
reset_kill_log
cfs_reset "easyjukebox-api" "9001" "9002" "9003"   # chrome / proxy / relay
cfs_mark_all_alive
_cleanup_failed_start
assert_eq "F2 trap (single): Chrome PID killed (identity match)" "1" "$(grep -c '^9001$' "$KILL_LOG")"
assert_eq "F2 trap (single): relay PID killed (identity match)" "1" "$(grep -c '^9003$' "$KILL_LOG")"
assert_eq "F2 trap (single): proxy PID killed (identity match)" "1" "$(grep -c '^9002$' "$KILL_LOG")"
assert_eq "F2 trap (single): X grant revoked (last consumer)" "1" "$(xhost_calls)"

# --- idempotency: a SECOND call (explicit branch + EXIT trap both fire) is a
#     no-op — no double-revoke, no double-kill. ---
reset_xhost_log
reset_kill_log
_cleanup_failed_start   # _CFS_DONE is already 1 from the call above
assert_eq "F2 trap idempotent: second call does NOT re-kill" "0" "$(grep -c '^9001$' "$KILL_LOG")"
assert_eq "F2 trap idempotent: second call does NOT re-revoke" "0" "$(xhost_calls)"

# --- abort WITH another live consumer present → grant PRESERVED ---
clear_sessions
write_session_stub "concurrent-live"
reset_xhost_log
reset_kill_log
cfs_reset "easyjukebox-api" "9101" "9102"
cfs_mark_all_alive
# The sibling's live Chrome (stub chrome_pid 4242, profile_dir
# concurrent-live-x) must report MATCH so the display-consumer count keeps the
# grant — the F7 override consults EXPECTED_MARKER for the sibling too.
EXPECTED_MARKER[4242]="--user-data-dir=/var/lib/boxa-agent/profiles/concurrent-live-x"
_cleanup_failed_start
assert_eq "F2 trap (sibling live): tracked PIDs still killed" \
    "1" "$(grep -c '^9101$' "$KILL_LOG")"
assert_eq "F2 trap (sibling live): X grant PRESERVED (not last consumer)" \
    "0" "$(xhost_calls)"

# ----------------------------------------------------------------------------
# F7b — host-PID identity guard before killing in failed-start cleanup
#       (#12 review). Each tracked host PID (Chrome/relay/proxy) is killed
#       ONLY when `_pid_matches_marker` confirms the PID still belongs to OUR
#       process. A PID that already exited (and may be REUSED by an unrelated
#       boxa-agent process) is NOT signalled. Mirrors F17's in-container guard.
# ----------------------------------------------------------------------------

# --- F7b-match: all three host PIDs report MATCHING identity → all three
#     killed. Distinct PIDs so each kill is independently asserted. ---
clear_sessions
reset_xhost_log
reset_kill_log
cfs_reset "guard-match" "8001" "8002" "8003"   # chrome / proxy / relay
cfs_mark_all_alive
_cleanup_failed_start
assert_eq "F7b match: Chrome killed (--user-data-dir marker matches)" \
    "1" "$(grep -c '^8001$' "$KILL_LOG")"
assert_eq "F7b match: relay killed (TCP-LISTEN marker matches)" \
    "1" "$(grep -c '^8003$' "$KILL_LOG")"
assert_eq "F7b match: proxy killed (--listen 127.0.0.1 marker matches)" \
    "1" "$(grep -c '^8002$' "$KILL_LOG")"

# --- F7b-mismatch: every tracked PID is alive but REUSED by an unrelated
#     process (its cmdline no longer carries our marker) → NO kill issued for
#     any of them. Model the reuse by mapping each PID to a FOREIGN marker. ---
clear_sessions
reset_xhost_log
reset_kill_log
cfs_reset "guard-reuse" "8101" "8102" "8103"
reset_expected_markers
EXPECTED_MARKER[8101]="--user-data-dir=/some/other/boxa-agent/profile"  # reused
EXPECTED_MARKER[8102]="--listen 127.0.0.1:55555"                          # reused
EXPECTED_MARKER[8103]="TCP-LISTEN:55556"                                  # reused
_cleanup_failed_start
assert_eq "F7b mismatch: Chrome PID reused → NOT killed" "0" "$(grep -c '^8101$' "$KILL_LOG")"
assert_eq "F7b mismatch: proxy PID reused → NOT killed" "0" "$(grep -c '^8102$' "$KILL_LOG")"
assert_eq "F7b mismatch: relay PID reused → NOT killed" "0" "$(grep -c '^8103$' "$KILL_LOG")"
assert_eq "F7b mismatch: NO host kill issued at all" "0" "$(grep -cE '^810[0-9]$' "$KILL_LOG")"

# --- F7b-gone: tracked PIDs already exited (absent from the identity map) →
#     no kill, no warn-spam (the cleanup still completes its other steps). ---
clear_sessions
reset_xhost_log
reset_kill_log
cfs_reset "guard-gone" "8201" "8202" "8203"
reset_expected_markers   # nothing alive → every _pid_matches_marker returns 1
_cleanup_failed_start
assert_eq "F7b gone: no host kill issued for already-exited PIDs" \
    "0" "$(grep -cE '^820[0-9]$' "$KILL_LOG")"
assert_eq "F7b gone: X grant still revoked (cleanup completed its other steps)" \
    "1" "$(xhost_calls)"

# --- F7b-unset: tracked PIDs are unset/empty → no kill, no-op (pre-existing
#     guard preserved; the identity check never even runs on an empty PID). ---
clear_sessions
reset_xhost_log
reset_kill_log
cfs_reset "guard-unset" "" ""   # chrome + proxy unset; relay defaults unset too
cfs_mark_all_alive             # nothing to mark (all PIDs empty)
_cleanup_failed_start
assert_eq "F7b unset: empty tracked PIDs → no host kill issued" \
    "0" "$(wc -l < "$KILL_LOG" | tr -d ' ')"

# --- F7b-partial: Chrome MATCHES (killed), proxy REUSED (skipped), relay GONE
#     (skipped) → only the matching PID is signalled; the cleanup's non-kill
#     steps (X revoke) still run. Confirms per-PID independence of the guard. ---
clear_sessions
reset_xhost_log
reset_kill_log
cfs_reset "guard-partial" "8301" "8302" "8303"   # chrome / proxy / relay
reset_expected_markers
EXPECTED_MARKER[8301]="--user-data-dir=$_CFS_PROFILE_DIR"   # chrome MATCH
EXPECTED_MARKER[8302]="--listen 127.0.0.1:44444"           # proxy reused (mismatch)
# relay 8303 absent from the map → already gone
_cleanup_failed_start
assert_eq "F7b partial: matching Chrome PID killed" "1" "$(grep -c '^8301$' "$KILL_LOG")"
assert_eq "F7b partial: reused proxy PID NOT killed" "0" "$(grep -c '^8302$' "$KILL_LOG")"
assert_eq "F7b partial: gone relay PID NOT killed" "0" "$(grep -c '^8303$' "$KILL_LOG")"
assert_eq "F7b partial: X grant still revoked (non-kill steps ran)" "1" "$(xhost_calls)"

# --- F7b-idempotent: after a first guarded cleanup, a SECOND call is a no-op —
#     no re-kill even though the identity map still reports MATCH (the _CFS_DONE
#     run-once guard short-circuits before any kill). Composes with the EXIT
#     trap (round 7). ---
clear_sessions
reset_xhost_log
reset_kill_log
cfs_reset "guard-idem" "8401" "8402" "8403"
cfs_mark_all_alive
_cleanup_failed_start
first_kills="$(grep -cE '^840[0-9]$' "$KILL_LOG")"
reset_xhost_log
reset_kill_log
_cleanup_failed_start   # _CFS_DONE already 1 from the call above
assert_eq "F7b idempotent: first call killed the matching PIDs" "3" "$first_kills"
assert_eq "F7b idempotent: second call does NOT re-kill" \
    "0" "$(grep -cE '^840[0-9]$' "$KILL_LOG")"
assert_eq "F7b idempotent: second call does NOT re-revoke" "0" "$(xhost_calls)"

# --- successful start models: trap DISARMED → cleanup never runs → grant kept.
#     We model the disarm by NOT invoking _cleanup_failed_start at all and
#     confirming no revoke leaked from the established-session path. (cmd_start
#     runs `trap - EXIT; _CFS_DONE=1` on success.) ---
clear_sessions
reset_xhost_log
# Established session: trap disarmed, body never entered.
_CFS_DONE=1
assert_eq "F2 success: trap disarmed → no spurious revoke on success" \
    "0" "$(xhost_calls)"

# Restore the simpler PID-aliveness `_pid_matches_marker` mock the F8-F16
# display-consumer / sweep sections rely on (they consult ALIVE_PIDS via session
# stub files, NOT the EXPECTED_MARKER map the F7b host-PID-guard cases use).
# shellcheck disable=SC2317
_pid_matches_marker() { pid_is_alive "${1:-}"; }

# ----------------------------------------------------------------------------
# F8 — persisted granted_display + early starting-claim (#12 review):
#      the convergent mechanism that closes BOTH findings.
#        F1: revoke is env-independent — it targets the PERSISTED granted_display
#            from the session state, NOT the ambient $DISPLAY, so the common
#            no-$DISPLAY teardown paths (detached watchdog, container-stop, SSH)
#            still release the grant instead of leaking it.
#        F2: an in-progress early starting-claim (status:"starting",
#            granted_display set, NO chrome_pid yet) counts as a display consumer
#            immediately, so a concurrently-starting sibling's rollback cannot
#            revoke the shared grant out from under it.
# The xhost / command / host_platform / sudo / docker mocks from F7 are still
# active here. Baseline: linux + xhost present.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1

# --- F8a (finding 1): teardown with NO ambient $DISPLAY but a persisted
#     granted_display in state → revoke IS called against the PERSISTED display.
clear_sessions
cat > "$SESSIONS_DIR/headless-stop.json" <<'EOF'
{
  "container": "headless-stop",
  "granted_display": ":7",
  "chrome_pid": 5555,
  "proxy_pid": 5556
}
EOF
reset_xhost_log
saved_display="${DISPLAY:-}"
unset DISPLAY                      # the detached-watchdog / container-stop case
captured="$(_state_get "$SESSIONS_DIR/headless-stop.json" granted_display)"
# cmd_stop removes its own file before the revoke on the non-retain path; model
# that the captured value (not a live re-read) drives the revoke.
rm -f "$SESSIONS_DIR/headless-stop.json"
_revoke_x_display_if_last_session "headless-stop" "$captured"
assert_eq "F8a finding1: revoke fires despite unset ambient \$DISPLAY (env-independent)" \
    "1" "$(xhost_calls)"
assert_contains "F8a finding1: revoke selector is the per-uid removal" \
    "xhost -SI:localuser:boxa-agent" "$(xhost_last)"
[ -n "$saved_display" ] && export DISPLAY="$saved_display"

# --- F8b (finding 1): granted_display ABSENT in state (a non-graphical start
#     that never granted) → revoke is a no-op even with the teardown path active.
clear_sessions
cat > "$SESSIONS_DIR/never-granted.json" <<'EOF'
{
  "container": "never-granted",
  "granted_display": null,
  "chrome_pid": 6001,
  "proxy_pid": 6002
}
EOF
reset_xhost_log
captured="$(_state_get "$SESSIONS_DIR/never-granted.json" granted_display)"
rm -f "$SESSIONS_DIR/never-granted.json"
_revoke_x_display_if_last_session "never-granted" "$captured"
assert_eq "F8b finding1: granted_display absent → revoke is a no-op" \
    "0" "$(xhost_calls)"

# --- F8c (finding 2): an early starting-claim (status:starting, granted_display
#     set, NO chrome_pid) IS a display consumer. ---
clear_sessions
# Exactly what _write_starting_claim emits before the grant.
_write_starting_claim "$SESSIONS_DIR/startingA.json" "startingA" ":0"
assert_eq "F8c claim shape: status is \"starting\"" \
    "starting" "$(_state_get "$SESSIONS_DIR/startingA.json" status)"
assert_eq "F8c claim shape: granted_display persisted in the claim" \
    ":0" "$(_state_get "$SESSIONS_DIR/startingA.json" granted_display)"
assert_eq "F8c claim shape: chrome_pid is null (Chrome not up yet)" \
    "" "$(_state_get "$SESSIONS_DIR/startingA.json" chrome_pid)"
_state_file_is_display_consumer "$SESSIONS_DIR/startingA.json" && r=0 || r=1
assert_eq "F8c predicate: starting-claim (no chrome_pid) IS a display consumer" "0" "$r"

# --- F8d (finding 2): concurrent start — session A has ONLY the early claim;
#     session B's revoke-if-last must COUNT A and NOT revoke. ---
clear_sessions
_write_starting_claim "$SESSIONS_DIR/containerA.json" "containerA" ":0"   # A: mid-start
assert_eq "F8d count: A's starting-claim counts as a live consumer for B" \
    "1" "$(_count_other_live_sessions "containerB")"
reset_xhost_log
# B grants, then FAILS before A writes its full state → B's rollback runs
# revoke-if-last. A is still a consumer → MUST NOT revoke (A needs the grant).
_revoke_x_display_if_last_session "containerB" ":0"
assert_eq "F8d finding2: B's rollback does NOT revoke while A is mid-start" \
    "0" "$(xhost_calls)"

# --- F8e: once A finishes tearing down (file gone) OR is marked ufw_retry_only,
#     it is no longer counted, so B's last-session revoke then fires. ---
clear_sessions
_write_starting_claim "$SESSIONS_DIR/containerA.json" "containerA" ":0"
_mark_state_file_ufw_retry_only "$SESSIONS_DIR/containerA.json"   # A torn down
assert_eq "F8e count: a torn-down (ufw_retry_only) ex-claim is NOT counted" \
    "0" "$(_count_other_live_sessions "containerB")"
_state_file_is_display_consumer "$SESSIONS_DIR/containerA.json" && r=0 || r=1
assert_eq "F8e predicate: ufw_retry_only beats a stale starting marker → NOT a consumer" "1" "$r"
reset_xhost_log
_revoke_x_display_if_last_session "containerB" ":0"
assert_eq "F8e finding2: with A gone, B's last-session revoke FIRES" \
    "1" "$(xhost_calls)"

# --- F8f: a non-graphical start writes a claim with granted_display=null; that
#     claim still counts as a consumer (status:starting) BUT its revoke is a
#     no-op (no display to revoke), so a headless start neither blocks nor leaks.
clear_sessions
_write_starting_claim "$SESSIONS_DIR/headlessClaim.json" "headlessClaim" ""
assert_eq "F8f claim shape: headless claim granted_display is null" \
    "" "$(_state_get "$SESSIONS_DIR/headlessClaim.json" granted_display)"
_state_file_is_display_consumer "$SESSIONS_DIR/headlessClaim.json" && r=0 || r=1
assert_eq "F8f predicate: headless starting-claim still counts as a consumer" "0" "$r"

# ----------------------------------------------------------------------------
# F10 — PER-DISPLAY grant reference counting (review finding 2): the xhost grant
#       is per-DISPLAY (it authorizes boxa-agent on a SPECIFIC X display), so
#       the revoke of display D must reference-count ONLY peers on D. A peer on
#       `:1` neither blocks nor is affected by revoking `:0`, and each display is
#       revoked exactly when its OWN last consumer goes away. xhost/command/
#       host_platform/SESSIONS_DIR mocks from F5/F7 are still active.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1

# --- predicate scoping: a file is a consumer ON D iff granted_display == D ---
clear_sessions
write_session_stub_on "peer-on-0" ":0"
_state_file_is_display_consumer "$SESSIONS_DIR/peer-on-0.json" ":0" && r=0 || r=1
assert_eq "F10 predicate: granted_display :0 IS a consumer on :0" "0" "$r"
_state_file_is_display_consumer "$SESSIONS_DIR/peer-on-0.json" ":1" && r=0 || r=1
assert_eq "F10 predicate: granted_display :0 is NOT a consumer on :1" "1" "$r"
# null/absent granted_display → consumer on NO display (even though live chrome).
printf '{ "chrome_pid": 7000, "granted_display": null }\n' > "$SESSIONS_DIR/nulldisp.json"
_state_file_is_display_consumer "$SESSIONS_DIR/nulldisp.json" ":0" && r=0 || r=1
assert_eq "F10 predicate: null granted_display is a consumer on no display" "1" "$r"
# Unscoped (empty target) keeps legacy any-display behaviour.
_state_file_is_display_consumer "$SESSIONS_DIR/peer-on-0.json" "" && r=0 || r=1
assert_eq "F10 predicate: empty target → unscoped consumer (legacy)" "0" "$r"

# --- count scoping: only peers on the queried display are counted ---
clear_sessions
write_session_stub_on "peerB-1" ":1"      # a sibling on display :1
assert_eq "F10 count: a :1 peer is NOT counted toward :0" \
    "0" "$(_count_other_live_sessions "myc" ":0")"
assert_eq "F10 count: a :1 peer IS counted toward :1" \
    "1" "$(_count_other_live_sessions "myc" ":1")"

# --- revoking :0 while a :1 peer is live → :0 IS revoked, targeting :0 ---
clear_sessions
write_session_stub_on "peerB-1" ":1"
reset_xhost_log
_revoke_x_display_if_last_session "myc" ":0"
assert_eq "F10 revoke :0: a :1 peer does NOT block → :0 revoked" "1" "$(xhost_calls)"
assert_contains "F10 revoke :0: targets the per-uid removal" \
    "xhost -SI:localuser:boxa-agent" "$(xhost_last)"

# --- a peer ON :0 present → revoking :0 is BLOCKED (same-display refcount) ---
clear_sessions
write_session_stub_on "peerA-0" ":0"
reset_xhost_log
_revoke_x_display_if_last_session "myc" ":0"
assert_eq "F10 revoke :0: a same-display :0 peer DOES block → no revoke" "0" "$(xhost_calls)"

# --- now tear :1 down later → counts only :1 peers, revokes :1 independently ---
# peerA-0 on :0 is still live, but it must NOT keep :1 authorized.
clear_sessions
write_session_stub_on "peerA-0" ":0"      # live on :0, unrelated to :1's revoke
reset_xhost_log
_revoke_x_display_if_last_session "myc-on-1" ":1"
assert_eq "F10 revoke :1: a :0 peer does NOT block :1's revoke (independent)" \
    "1" "$(xhost_calls)"
assert_contains "F10 revoke :1: still the per-uid removal selector" \
    "xhost -SI:localuser:boxa-agent" "$(xhost_last)"

# --- two peers on :1 → revoking :1 blocked until both go (same-display refcount,
#     no regression to the per-display count itself) ---
clear_sessions
write_session_stub_on "peer1-a" ":1"
write_session_stub_on "peer1-b" ":1"
assert_eq "F10 count: two :1 peers both counted" \
    "2" "$(_count_other_live_sessions "myc-on-1" ":1")"
reset_xhost_log
_revoke_x_display_if_last_session "myc-on-1" ":1"
assert_eq "F10 revoke :1: a same-display peer still blocks (no regression)" \
    "0" "$(xhost_calls)"

# ----------------------------------------------------------------------------
# F9 — early starting-claim is written BEFORE the grant in cmd_start.
#      We can't run the full cmd_start (it launches Chrome/proxy/docker), so we
#      assert the ORDERING contract directly: at the moment the grant runs, the
#      state file must already exist with granted_display + a starting marker.
#      We stub _grant_agent_x_display_access to snapshot the state file the
#      instant it is called, and drive only the claim→grant prologue.
# ----------------------------------------------------------------------------
clear_sessions
GRANT_SNAPSHOT="$(mktemp)"
# Snapshot the REAL grant before shadowing it, so F13 below (which exercises the
# real ownership-marker logic in `_grant_agent_x_display_access`) can restore it.
# A bare `unset -f` would delete the real definition outright.
eval "_real_grant_agent_x_display_access() $(declare -f _grant_agent_x_display_access | sed '1d')"
# shellcheck disable=SC2317
_grant_agent_x_display_access() {
    # Snapshot whatever state file exists for the container under test at the
    # instant the grant fires. If the claim was written FIRST (the contract),
    # the file already exists here with status:starting + granted_display.
    cp -f "$SESSIONS_DIR/order-c.json" "$GRANT_SNAPSHOT" 2>/dev/null || : > "$GRANT_SNAPSHOT"
}
# Drive the exact claim→grant prologue cmd_start runs (mirrors the broker:
# compute display, write claim, then grant).
order_display=":0"
_write_starting_claim "$SESSIONS_DIR/order-c.json" "order-c" "$order_display"
_grant_agent_x_display_access
assert_eq "F9 ordering: state file EXISTS at grant time with status:starting" \
    "starting" "$(_state_get "$GRANT_SNAPSHOT" status)"
assert_eq "F9 ordering: granted_display already persisted at grant time" \
    ":0" "$(_state_get "$GRANT_SNAPSHOT" granted_display)"
_state_file_is_display_consumer "$GRANT_SNAPSHOT" && r=0 || r=1
assert_eq "F9 ordering: the claim present at grant time IS a display consumer" "0" "$r"
rm -f "$GRANT_SNAPSHOT"
# Restore the real grant (do NOT leave it unset — F13 exercises it).
eval "_grant_agent_x_display_access() $(declare -f _real_grant_agent_x_display_access | sed '1d')"
unset -f _real_grant_agent_x_display_access

# ----------------------------------------------------------------------------
# F11 — failed-start cleanup terminates the IN-CONTAINER bridge (review
#       finding 1). _cleanup_failed_start must kill the tracked bridge socat via
#       the SAME `docker exec <container> kill <pid>` path cmd_stop/sweep use, so
#       a failed/aborted start never orphans socat bound to 127.0.0.1:9222
#       inside the container. Guarded: no-op when the bridge was never started
#       (PID unset), and a WARN (not an abort) when the container has vanished.
# ----------------------------------------------------------------------------

# Re-mock docker to record `docker exec <c> kill <pid>` AND to drive
# _container_running deterministically. CONTAINER_RUNNING toggles whether
# `docker ps` reports the container (it greps for a non-empty name line).
CONTAINER_RUNNING=1
DOCKER_EXEC_LOG="$(mktemp)"
reset_docker_exec_log() { : > "$DOCKER_EXEC_LOG"; }
docker_exec_calls() { grep -c . "$DOCKER_EXEC_LOG" 2>/dev/null || true; }
reset_docker_exec_log
# shellcheck disable=SC2317
docker() {
    case "$1" in
        ps)
            # `_container_running` does `docker ps ... | grep -q .`; emit a name
            # line only when the container is "running".
            [ "$CONTAINER_RUNNING" = "1" ] && printf 'somecontainer\n'
            return 0
            ;;
        exec)
            # Record `docker exec <container> kill <pid>` as "<container> <pid>".
            # argv: exec <container> kill <pid>  (no -u/-d in the bridge kill).
            if [ "${3:-}" = "kill" ]; then
                printf '%s %s\n' "${2:-}" "${4:-}" >> "$DOCKER_EXEC_LOG"
            fi
            return 0
            ;;
        *) return 0 ;;
    esac
}
# sudo kill recorder is still the F7 mock (still defined); reuse its KILL_LOG.

# --- bridge PID tracked + container running → cleanup issues the in-container
#     kill with the tracked PID/container ---
clear_sessions
reset_docker_exec_log
reset_kill_log
reset_xhost_log
CONTAINER_RUNNING=1
cfs_reset "brc" "8001" "8002"
_CFS_BRIDGE_PID_IN_CONTAINER="9222"
_cleanup_failed_start
assert_eq "F11 bridge tracked: in-container kill issued once" \
    "1" "$(docker_exec_calls)"
assert_eq "F11 bridge tracked: kill targets the tracked container+PID" \
    "brc 9222" "$(tail -n1 "$DOCKER_EXEC_LOG")"

# --- bridge never started (PID unset) → NO in-container kill ---
clear_sessions
reset_docker_exec_log
CONTAINER_RUNNING=1
cfs_reset "brc" "8001" "8002"
_CFS_BRIDGE_PID_IN_CONTAINER=""     # bridge launch never reached
_cleanup_failed_start
assert_eq "F11 bridge unset: no in-container kill issued" \
    "0" "$(docker_exec_calls)"

# --- literal null PID (jq-less parse shape) → also no kill ---
clear_sessions
reset_docker_exec_log
CONTAINER_RUNNING=1
cfs_reset "brc" "8001" "8002"
_CFS_BRIDGE_PID_IN_CONTAINER="null"
_cleanup_failed_start
assert_eq "F11 bridge null: no in-container kill issued" \
    "0" "$(docker_exec_calls)"

# --- container gone → WARN, no kill, cleanup STILL completes (revoke runs) ---
clear_sessions
reset_docker_exec_log
reset_xhost_log
CONTAINER_RUNNING=0                  # container vanished mid-teardown
cfs_reset "brc" "8001" "8002"
_CFS_BRIDGE_PID_IN_CONTAINER="9222"
warn_out="$(_cleanup_failed_start 2>&1)"
assert_eq "F11 container gone: in-container kill NOT issued (container running check)" \
    "0" "$(docker_exec_calls)"
assert_contains "F11 container gone: warns visibly (no silent skip)" \
    "no longer running" "$warn_out"
assert_eq "F11 container gone: cleanup still completes → X revoke fires" \
    "1" "$(xhost_calls)"

# --- direct helper: docker exec kill failure (container vanished between the
#     running check and the exec) → WARN, never aborts ---
clear_sessions
reset_docker_exec_log
# Make `docker exec ... kill` fail to model a mid-teardown vanish.
# shellcheck disable=SC2317
docker() {
    case "$1" in
        ps) printf 'somecontainer\n'; return 0 ;;   # running
        exec) [ "${3:-}" = "kill" ] && return 1; return 0 ;;
        *) return 0 ;;
    esac
}
warn_out="$(_kill_bridge_in_container "brc" "9222" 2>&1)"; rc=$?
assert_eq "F11 helper exec-fail: returns 0 (never aborts caller)" "0" "$rc"
assert_contains "F11 helper exec-fail: warns on kill failure" \
    "could not kill in-container bridge" "$warn_out"

unset -f docker
rm -f "$KILL_LOG" "$DOCKER_EXEC_LOG"

# ----------------------------------------------------------------------------
# F12 — Chrome-liveness validation in the display-consumer predicate (#12
#       review finding 2). A file claiming a RUNNING chrome_pid is counted as a
#       consumer ONLY if that PID is alive AND ours; a crashed Chrome or a stale
#       post-reboot file is NOT counted, so stopping the last REAL session
#       releases the grant. A "starting" claim (no chrome_pid yet) STILL counts.
#       The liveness probes (`_pid_matches_marker`/`_pid_alive_on_host`) are
#       mocked to consult ALIVE_PIDS. xhost/command/host_platform/liveness mocks
#       from F5/F7 are still active.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1

# --- ALIVE chrome_pid → counted ---
clear_sessions
ALIVE_PIDS=" 4242 "
write_session_stub_on "live-real" ":0"      # chrome_pid 4242, profile_dir set
_state_file_is_display_consumer "$SESSIONS_DIR/live-real.json" && r=0 || r=1
assert_eq "F12 liveness: an ALIVE chrome_pid IS a consumer" "0" "$r"
assert_eq "F12 liveness: alive sibling counted" \
    "1" "$(_count_other_live_sessions "otherc")"

# --- DEAD chrome_pid (same file, PID no longer alive) → NOT counted ---
ALIVE_PIDS=" "                               # nothing alive now (Chrome crashed)
_state_file_is_display_consumer "$SESSIONS_DIR/live-real.json" && r=0 || r=1
assert_eq "F12 liveness: a DEAD chrome_pid is NOT a consumer" "1" "$r"
assert_eq "F12 liveness: dead chrome sibling NOT counted" \
    "0" "$(_count_other_live_sessions "otherc")"

# --- the last REAL session's stop revokes when the only peer is a DEAD file ---
# A crashed peer must not keep the grant alive: with peer dead, the stopping
# session is effectively last → revoke fires (marker present from clear_sessions).
clear_sessions
ALIVE_PIDS=" "
write_session_stub_on "crashed-peer" ":0"   # claims chrome 4242 but it's dead
reset_xhost_log
_revoke_x_display_if_last_session "stopping-real" ":0"
assert_eq "F12 liveness: a crashed peer does NOT pin the grant → revoke fires" \
    "1" "$(xhost_calls)"

# --- a GENUINELY alive peer still blocks the revoke (no over-revoke) ---
clear_sessions
ALIVE_PIDS=" 4242 "
write_session_stub_on "alive-peer" ":0"
reset_xhost_log
_revoke_x_display_if_last_session "stopping-real" ":0"
assert_eq "F12 liveness: an ALIVE peer still blocks the revoke" "0" "$(xhost_calls)"

# --- a "starting" claim (no chrome_pid) is a consumer regardless of ALIVE_PIDS ---
clear_sessions
ALIVE_PIDS=" "                               # no live chrome anywhere
_write_starting_claim "$SESSIONS_DIR/mid-start.json" "mid-start" ":0"
_state_file_is_display_consumer "$SESSIONS_DIR/mid-start.json" && r=0 || r=1
assert_eq "F12 liveness: a starting claim (no chrome_pid) STILL counts" "0" "$r"
reset_xhost_log
_revoke_x_display_if_last_session "other-stop" ":0"
assert_eq "F12 liveness: a starting peer blocks revoke even with no live chrome" \
    "0" "$(xhost_calls)"
ALIVE_PIDS=" 4242 "                          # restore default

# ----------------------------------------------------------------------------
# F13 — per-display broker-ownership marker (#12 review finding 3). The broker
#       revokes ONLY a grant it ADDED: at grant time it queries the X access
#       list and creates the per-display marker iff boxa-agent was NOT already
#       authorized. Teardown revokes only when the marker exists, then removes
#       it. A pre-existing authorization (no marker), or a failed query (safe
#       default), is NEVER revoked. xhost/command/host_platform mocks active.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1

# --- marker filename sanitization ---
assert_eq "F13 sanitize: :0 → 0" "0" "$(_sanitize_display_for_marker ":0")"
assert_eq "F13 sanitize: :1 → 1" "1" "$(_sanitize_display_for_marker ":1")"
assert_eq "F13 sanitize: :1.0 → 1.0" "1.0" "$(_sanitize_display_for_marker ":1.0")"
assert_eq "F13 sanitize: host:0 → host_0" "host_0" "$(_sanitize_display_for_marker "host:0")"
assert_eq "F13 sanitize: empty → empty" "" "$(_sanitize_display_for_marker "")"
assert_eq "F13 sanitize: null → empty" "" "$(_sanitize_display_for_marker "null")"
# no path-traversal / slashes survive into the filename
case "$(_xhost_ownership_marker_path ":1")" in
    */xhost-owned-1) r=0 ;; *) r=1 ;;
esac
assert_eq "F13 marker path: :1 → .../xhost-owned-1" "0" "$r"
sanitized_evil="$(_sanitize_display_for_marker '../../etc/x:0')"
case "$sanitized_evil" in */*) r=1 ;; *) r=0 ;; esac
assert_eq "F13 sanitize: traversal attempt yields no slash" "0" "$r"

# --- grant when NOT already authorized → marker CREATED ---
# Mock xhost: with no args (the access-list query), print a list WITHOUT
# boxa-agent → `_xhost_agent_already_authorized` returns 1 (not authorized).
# With +SI/-SI args, record the call as before.
# shellcheck disable=SC2317
xhost() {
    if [ "$#" -eq 0 ]; then
        # access-control list query: NO boxa-agent entry.
        printf 'access control enabled, only authorized clients can connect\nSI:localuser:root\n'
        return 0
    fi
    printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"
    return 0
}
clear_markers
export DISPLAY=":4"
reset_xhost_log
_grant_agent_x_display_access
grant_marker="$(_xhost_ownership_marker_path ":4")"
[ -e "$grant_marker" ] && r=0 || r=1
assert_eq "F13 grant: not-yet-authorized → ownership marker CREATED" "0" "$r"
assert_contains "F13 grant: the +SI grant ran" "+SI:localuser:boxa-agent" "$(xhost_last)"
# teardown owns it → revoke fires AND removes the marker
reset_xhost_log
_revoke_agent_x_display_access ":4"
assert_eq "F13 teardown: broker-owned grant → revoke fires" "1" "$(xhost_calls)"
[ -e "$grant_marker" ] && r=0 || r=1
assert_eq "F13 teardown: marker removed after revoke" "1" "$r"

# --- grant when ALREADY authorized → NO marker, teardown does NOT revoke ---
# shellcheck disable=SC2317
xhost() {
    if [ "$#" -eq 0 ]; then
        # access-control list query: boxa-agent ALREADY present.
        printf 'access control enabled, only authorized clients can connect\nSI:localuser:boxa-agent\n'
        return 0
    fi
    printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"
    return 0
}
clear_markers
export DISPLAY=":5"
reset_xhost_log
grant_log="$(_grant_agent_x_display_access 2>&1)"
preexisting_marker="$(_xhost_ownership_marker_path ":5")"
[ -e "$preexisting_marker" ] && r=0 || r=1
assert_eq "F13 pre-existing: already-authorized → NO ownership marker created" "1" "$r"
assert_contains "F13 pre-existing: logs the no-revoke decision at grant" \
    "already authorized" "$grant_log"
# teardown must NOT revoke a pre-existing non-broker authorization
reset_xhost_log
norevoke_log="$(_revoke_agent_x_display_access ":5" 2>&1)"
assert_eq "F13 pre-existing: teardown does NOT revoke (no marker)" "0" "$(xhost_calls)"
assert_contains "F13 pre-existing: teardown logs the preserve decision" \
    "broker does not own this grant" "$norevoke_log"

# --- query FAILS → FAIL CLOSED: grant ABORTS, no +SI, no marker (#12 review P2) ---
# When ownership cannot be queried, the broker must NOT grant: a successful grant
# with no ownership marker would leak (teardown treats it as pre-existing and
# never revokes). The grant helper returns non-zero and issues NO `xhost +SI`.
# shellcheck disable=SC2317
xhost() {
    if [ "$#" -eq 0 ]; then
        return 1                       # the access-list query itself fails
    fi
    printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"
    return 0
}
clear_markers
export DISPLAY=":6"
reset_xhost_log
qfail_log="$(_grant_agent_x_display_access 2>&1)"; qfail_rc=$?
qfail_marker="$(_xhost_ownership_marker_path ":6")"
[ -e "$qfail_marker" ] && r=0 || r=1
assert_eq "F13 query-fail: NO ownership marker created (fail closed)" "1" "$r"
assert_eq "F13 query-fail: grant ABORTS with non-zero return" "1" "$qfail_rc"
assert_eq "F13 query-fail: NO 'xhost +SI' grant issued" "0" "$(xhost_calls)"
assert_contains "F13 query-fail: clear error refuses untrackable grant" \
    "could not query X access control list" "$qfail_log"
assert_contains "F13 query-fail: error names the untracked-revoke rationale" \
    "teardown could not revoke" "$qfail_log"
reset_xhost_log
_revoke_agent_x_display_access ":6"
assert_eq "F13 query-fail: teardown does NOT revoke (nothing granted)" "0" "$(xhost_calls)"
export DISPLAY=":0"

# ----------------------------------------------------------------------------
# F25 — rc-1 (not-authorized → broker adds grant) FAILS CLOSED on a marker-write
#       failure, and REMOVES the just-written marker if the +SI grant then fails
#       (#12 review P2). The marker is written BEFORE granting (atomically): a
#       grant with no ownership record leaks (teardown treats it as pre-existing,
#       never revokes). And a marker for a grant that never took must not linger.
# ----------------------------------------------------------------------------
# boxa-agent NOT yet authorized → the grant takes the rc-1 add-grant branch.
# shellcheck disable=SC2317
xhost() {
    if [ "$#" -eq 0 ]; then
        printf 'access control enabled, only authorized clients can connect\nSI:localuser:root\n'
        return 0
    fi
    printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"
    return 0
}

# --- marker write FAILS → grant ABORTS: no +SI, clear error, non-zero, no marker
# Steer the marker path into a NON-EXISTENT subdir so the atomic temp write (and
# its mv) cannot succeed, while SESSIONS_DIR itself stays writable. Snapshot the
# real helper so the later sections restore it.
eval "_real_xhost_ownership_marker_path() $(declare -f _xhost_ownership_marker_path | sed '1d')"
F25_BAD_DIR="$SESSIONS_DIR/f25-no-such-subdir"
rm -rf "$F25_BAD_DIR" 2>/dev/null || true        # ensure the parent is ABSENT
# shellcheck disable=SC2317
_xhost_ownership_marker_path() { printf '%s/xhost-owned-25\n' "$F25_BAD_DIR"; }
export DISPLAY=":25"
reset_xhost_log
f25_fail_log="$(_grant_agent_x_display_access "c-f25-mwfail" 2>&1)"; f25_fail_rc=$?
f25_bad_marker="$(_xhost_ownership_marker_path ":25")"
assert_eq "F25 marker-write-fail: grant ABORTS with non-zero return" "1" "$f25_fail_rc"
assert_eq "F25 marker-write-fail: NO 'xhost +SI' grant issued" "0" "$(xhost_calls)"
[ -e "$f25_bad_marker" ] && r=0 || r=1
assert_eq "F25 marker-write-fail: NO marker left behind" "1" "$r"
# No half-written temp marker either (atomic temp+mv leaves nothing on failure).
f25_tmp_count="$(find "$F25_BAD_DIR" -maxdepth 1 -name 'xhost-owned-25*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "F25 marker-write-fail: no half-written temp marker left" "0" "$f25_tmp_count"
assert_contains "F25 marker-write-fail: clear error refuses untrackable grant" \
    "could not write X-grant ownership marker" "$f25_fail_log"
assert_contains "F25 marker-write-fail: error names the untracked-revoke rationale" \
    "teardown could not revoke" "$f25_fail_log"
# Restore the real marker-path helper.
eval "_xhost_ownership_marker_path() $(declare -f _real_xhost_ownership_marker_path | sed '1d')"
unset -f _real_xhost_ownership_marker_path

# --- marker write SUCCEEDS but `xhost +SI` FAILS → just-written marker REMOVED ---
# A grant that did not take owns nothing; the marker for it must be cleaned up.
# shellcheck disable=SC2317
xhost() {
    if [ "$#" -eq 0 ]; then
        printf 'access control enabled, only authorized clients can connect\nSI:localuser:root\n'
        return 0
    fi
    printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"
    return 1                          # the +SI grant itself FAILS
}
clear_markers
export DISPLAY=":26"
reset_xhost_log
# `_grant_agent_x_display_access` `_die`s (exit 1) on a +SI failure — run it in a
# subshell so the harness survives; capture the warn output + rc.
f25_gf_log="$( ( _grant_agent_x_display_access "c-f25-grantfail" ) 2>&1 )"; f25_gf_rc=$?
f25_gf_marker="$(_xhost_ownership_marker_path ":26")"
assert_eq "F25 grant-fail: +SI was attempted (marker written first)" "1" "$(xhost_calls)"
[ -e "$f25_gf_marker" ] && r=0 || r=1
assert_eq "F25 grant-fail: the just-written marker is REMOVED (no grant → no ownership)" "1" "$r"
assert_eq "F25 grant-fail: grant reports failure (non-zero)" "1" "$( [ "$f25_gf_rc" -ne 0 ] && echo 1 || echo 0)"
assert_contains "F25 grant-fail: surfaces the grant-failure error" \
    "Failed to grant boxa-agent X display access" "$f25_gf_log"

# --- happy path: marker written THEN +SI succeeds → marker present, grant ran ---
# shellcheck disable=SC2317
xhost() {
    if [ "$#" -eq 0 ]; then
        printf 'access control enabled, only authorized clients can connect\nSI:localuser:root\n'
        return 0
    fi
    printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"
    return 0
}
clear_markers
export DISPLAY=":27"
reset_xhost_log
_grant_agent_x_display_access "c-f25-ok"
f25_ok_marker="$(_xhost_ownership_marker_path ":27")"
[ -e "$f25_ok_marker" ] && r=0 || r=1
assert_eq "F25 happy: marker present after a successful grant" "0" "$r"
assert_eq "F25 happy: marker STAMPED with the current X-session token" \
    "$MOCK_X_TOKEN" "$(_x_session_token_from_marker "$f25_ok_marker")"
assert_contains "F25 happy: the +SI grant ran" "+SI:localuser:boxa-agent" "$(xhost_last)"
clear_markers
export DISPLAY=":0"
# restore the plain recording xhost mock
# shellcheck disable=SC2317
xhost() { printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"; return 0; }

# ----------------------------------------------------------------------------
# F24 — `_x_session_token` LOCAL-vs-REMOTE identity + UNKNOWN sentinel (#12
#       review P2). The token must:
#         - for a LOCAL display (`:N`) with a readable X socket, embed the socket
#           inode:mtime so it CHANGES when the X server restarts (socket
#           recreated → new inode/mtime);
#         - for a LOCAL display whose socket is MISSING, return the UNKNOWN
#           sentinel (empty) — NOT a boot-id-only token (which would false-match
#           across an X restart);
#         - for a REMOTE display (`host:0`), return the UNKNOWN sentinel AND NOT
#           read the unrelated local `X0` socket (a different X server);
#       and the already-authorized staleness compare must treat an UNKNOWN
#       current token (or an unknown marker token) as CANNOT-DETERMINE → KEEP the
#       marker (safe default), never a confident clear and never a confident
#       match. We restore the REAL `_x_session_token` for this section and drive
#       its filesystem dependencies with a REAL throwaway UNIX socket under
#       `/tmp/.X11-unix/` on a high, collision-unlikely display number.
# ----------------------------------------------------------------------------
eval "_x_session_token() $(declare -f _real_x_session_token | sed '1d')"

# Helper: create a real UNIX socket at /tmp/.X11-unix/X<n>. Returns 0 on success.
# Tries python3 (always present in this repo's host env); the test asserts that
# it succeeded so a silent skip can't hide a regression.
F24_XDIR="/tmp/.X11-unix"
make_x_socket() {
    local n="$1"
    mkdir -p "$F24_XDIR" 2>/dev/null || return 1
    rm -f "$F24_XDIR/X${n}" 2>/dev/null || true
    python3 - "$F24_XDIR/X${n}" <<'PY' 2>/dev/null || return 1
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
PY
    [ -S "$F24_XDIR/X${n}" ]
}

# --- LOCAL `:N` with a readable socket → token embeds socket identity ---
F24_DNUM=98
if make_x_socket "$F24_DNUM"; then
    tok_local_1="$(_x_session_token ":${F24_DNUM}")"
    case "$tok_local_1" in *"sock="*:*) r=0 ;; *) r=1 ;; esac
    assert_eq "F24 local :N readable socket: token includes socket inode:mtime" "0" "$r"
    assert_eq "F24 local :N readable socket: token is NOT the unknown sentinel" \
        "0" "$( [ -n "$tok_local_1" ] && echo 0 || echo 1)"
    # Recreate the socket (new inode/mtime) → token MUST change (X-restart detect).
    sleep 1
    make_x_socket "$F24_DNUM"
    tok_local_2="$(_x_session_token ":${F24_DNUM}")"
    assert_eq "F24 local :N socket recreated: token CHANGES (X-restart detected)" \
        "0" "$( [ "$tok_local_1" != "$tok_local_2" ] && echo 0 || echo 1)"
    # Canonical-number equivalence: `:98.0` keys off the same X98 socket as `:98`.
    tok_local_screen="$(_x_session_token ":${F24_DNUM}.0")"
    assert_eq "F24 local :N.screen: same socket as :N (screen suffix dropped)" \
        "$tok_local_2" "$tok_local_screen"
    rm -f "$F24_XDIR/X${F24_DNUM}" 2>/dev/null || true
else
    assert_eq "F24 local socket setup: could not create test UNIX socket" \
        "0" "1"
fi

# --- LOCAL `:N` with a MISSING socket → UNKNOWN sentinel (NOT boot-id-only) ---
F24_MISS=97
rm -f "$F24_XDIR/X${F24_MISS}" 2>/dev/null || true
tok_local_missing="$(_x_session_token ":${F24_MISS}")"
assert_eq "F24 local :N missing socket: UNKNOWN sentinel (empty), no boot-id fallback" \
    "" "$tok_local_missing"

# --- REMOTE `host:N` → UNKNOWN sentinel AND does not read the local X<N> ---
# Use a host name that is NOT this machine's hostname so the local-host check
# fails and the display is classified REMOTE. We create a REAL local X<N> socket
# on a high number and confirm the REMOTE display on the SAME number still yields
# the UNKNOWN sentinel — proving the remote path did NOT borrow the local socket.
# (We deliberately avoid touching X0 so a real X server's socket is never
# clobbered.)
F24_REM=96
if make_x_socket "$F24_REM"; then
    tok_local_for_rem="$(_x_session_token ":${F24_REM}")"      # LOCAL → real token
    tok_remote="$(_x_session_token "definitely-not-localhost-xyz:${F24_REM}")"
    assert_eq "F24 remote host:N: UNKNOWN sentinel (does not read local X${F24_REM})" \
        "" "$tok_remote"
    assert_eq "F24 remote vs local :N: remote stays empty while local :N is a real token" \
        "0" "$( [ -n "$tok_local_for_rem" ] && [ "$tok_remote" != "$tok_local_for_rem" ] && echo 0 || echo 1)"
    rm -f "$F24_XDIR/X${F24_REM}" 2>/dev/null || true
else
    assert_eq "F24 remote socket setup: could not create test UNIX socket" "0" "1"
fi

# --- `localhost:N` is SERVER-IDENTITY-keyed on the LOCAL X<N> SOCKET (#12 review
#     supersedes the prior always-unknown stance). The xhost ACL is server-wide,
#     so a `localhost:N` that reaches the local X<N> server shares its identity:
#       - SOCKET PRESENT → `localhost:N` derives the SAME real token as `:N`.
#       - SOCKET ABSENT (the SSH-forwarded `localhost:10.0` case, no X10) →
#         UNKNOWN sentinel: it does NOT reach a local server on N. ---
F24_LH=95
if make_x_socket "$F24_LH"; then
    tok_local_for_lh="$(_x_session_token ":${F24_LH}")"           # local-unix → real token
    tok_localhost="$(_x_session_token "localhost:${F24_LH}.0")"   # socket-backed → same server
    assert_eq "F24 localhost:N.screen (socket present): SAME real token as local :N (same X${F24_LH} server)" \
        "$tok_local_for_lh" "$tok_localhost"
    assert_eq "F24 localhost:N (socket present): token is NOT the unknown sentinel" \
        "0" "$( [ -n "$tok_localhost" ] && echo 0 || echo 1)"
    rm -f "$F24_XDIR/X${F24_LH}" 2>/dev/null || true
    # SOCKET ABSENT → SSH-forwarded case → UNKNOWN sentinel (does not reach a
    # local server on N).
    tok_localhost_nosock="$(_x_session_token "localhost:${F24_LH}.0")"
    assert_eq "F24 localhost:N.screen (socket absent, SSH case): UNKNOWN sentinel" \
        "" "$tok_localhost_nosock"
else
    assert_eq "F24 localhost socket setup: could not create test UNIX socket" "0" "1"
fi

# --- empty / null / colonless display → UNKNOWN sentinel ---
assert_eq "F24 empty display: UNKNOWN sentinel" "" "$(_x_session_token "")"
assert_eq "F24 null display: UNKNOWN sentinel" "" "$(_x_session_token "null")"
assert_eq "F24 colonless display: UNKNOWN sentinel" "" "$(_x_session_token "garbage")"

# --- staleness compare: UNKNOWN current token + a marker with a REAL token →
#     ownership UNVERIFIABLE → marker DROPPED (#12 review — supersedes the prior
#     keep-on-uncertainty default). The broker must never claim ownership it
#     cannot prove. ---
# Drive the grant's already-authorized branch with the MOCK token set to the
# UNKNOWN sentinel while the marker carries a real token; the marker must be
# REMOVED. Re-install the controllable MOCK for the grant-path staleness
# assertions (the grant helper calls _x_session_token internally; we steer it via
# MOCK_X_TOKEN).
# shellcheck disable=SC2317
_x_session_token() { printf '%s\n' "$MOCK_X_TOKEN"; }
# already-authorized xhost mock (boxa-agent present) so the grant takes the
# revalidation branch; +SI/-SI recorded.
# shellcheck disable=SC2317
xhost() {
    if [ "$#" -eq 0 ]; then
        printf 'SI:localuser:boxa-agent\n'; return 0
    fi
    printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"; return 0
}
export DISPLAY=":24"
clear_markers
broker_owns_display ":24" "boot=REAL;sock=9:9000"   # marker carries a REAL token
saved_tok="$MOCK_X_TOKEN"
MOCK_X_TOKEN=""                                      # CURRENT token = UNKNOWN sentinel
f24_unverif_log="$(_grant_agent_x_display_access "c-unknown-current" 2>&1)"
unknown_marker="$(_xhost_ownership_marker_path ":24")"
[ -e "$unknown_marker" ] && r=0 || r=1
assert_eq "F24 staleness: UNKNOWN current token + real marker token → marker DROPPED (unverifiable)" "1" "$r"
assert_contains "F24 staleness: the unverifiable-marker drop is logged" \
    "clearing unverifiable X-grant ownership marker" "$f24_unverif_log"
MOCK_X_TOKEN="$saved_tok"

# --- marker with an UNKNOWN (empty) token + a real current token → DROPPED ---
clear_markers
broker_owns_display ":24" ""                         # marker token = UNKNOWN
MOCK_X_TOKEN="boot=REAL;sock=9:9000"                 # current token KNOWN
f24_unverif_log2="$(_grant_agent_x_display_access "c-unknown-marker" 2>&1)"
[ -e "$unknown_marker" ] && r=0 || r=1
assert_eq "F24 staleness: UNKNOWN marker token + real current token → marker DROPPED (unverifiable)" "1" "$r"
assert_contains "F24 staleness: the empty-marker-token drop is logged" \
    "clearing unverifiable X-grant ownership marker" "$f24_unverif_log2"
MOCK_X_TOKEN="$saved_tok"
export DISPLAY=":0"
clear_markers
# Clean up any throwaway sockets we created.
rm -f "$F24_XDIR/X${F24_DNUM}" "$F24_XDIR/X${F24_MISS}" "$F24_XDIR/X${F24_REM}" "$F24_XDIR/X${F24_LH}" 2>/dev/null || true
unset -f _real_x_session_token make_x_socket
# Restore the controllable MOCK token helper for the remaining F19/F-suite blocks.
# shellcheck disable=SC2317
_x_session_token() { printf '%s\n' "$MOCK_X_TOKEN"; }

# restore the plain recording xhost mock for any later use
# shellcheck disable=SC2317
xhost() { printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"; return 0; }

# ----------------------------------------------------------------------------
# F19 — REVALIDATE a surviving ownership marker on the ALREADY-AUTHORIZED grant
#       path by X-SERVER-SESSION TOKEN (#12 review P1). The ownership marker is a
#       disk FILE that can outlive the X-server-session-scoped grant it recorded
#       (e.g. across an X server reset). On a later start the broker finds
#       boxa-agent already authorized and takes the already-authorized branch.
#       Staleness is now decided by the marker's stamped X-session token vs the
#       CURRENT token — NOT by a live-consumer count (the prior round-15 heuristic
#       that wrongly deleted a LIVE grant retained after a failed revoke):
#         - token MISMATCH (prior X server / reboot) → STALE → cleared + logged;
#           teardown then treats the authorization as pre-existing (no revoke).
#         - token MATCH (this X session) → LIVE broker-owned grant (possibly
#           retained after a failed revoke, ZERO current consumers) → KEPT.
#         - marker token MISSING (old marker) / current token UNDERIVABLE → SAFE
#           DEFAULT: KEEP (never delete on uncertainty).
#       xhost/command/host_platform mocks active; MOCK_X_TOKEN is the current
#       X-session token.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1
MOCK_X_TOKEN="boot=AAA;sock=1:1000"

# xhost mock: the no-arg access-list query reports boxa-agent ALREADY
# authorized (the post-reset / pre-existing state); +SI/-SI calls are recorded.
# shellcheck disable=SC2317
xhost() {
    if [ "$#" -eq 0 ]; then
        printf 'access control enabled, only authorized clients can connect\nSI:localuser:boxa-agent\n'
        return 0
    fi
    printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"
    return 0
}

# --- F19a: already-authorized + marker token MISMATCH (prior X server) + NO
#           consumer → STALE → marker CLEARED + logged; teardown does NOT revoke.
#           This is exactly the X-server-reset case round-15 targeted, now decided
#           by token identity instead of consumer count. ---
clear_sessions                 # wipes state files, re-seeds :0/:1/:7 markers
clear_markers                  # start from a clean marker slate for this display
export DISPLAY=":8"
f18_marker="$(_xhost_ownership_marker_path ":8")"
# A marker stamped against a DIFFERENT (prior) X server session.
broker_owns_display ":8" "boot=OLD;sock=9:9000"
[ -e "$f18_marker" ] && r=0 || r=1
assert_eq "F19a setup: prior-session marker present before grant" "0" "$r"
reset_xhost_log
# This container's own starting claim, as cmd_start writes it before the grant.
_write_starting_claim "$SESSIONS_DIR/c-stale.json" "c-stale" ":8"
f18a_log="$(_grant_agent_x_display_access "c-stale" 2>&1)"
[ -e "$f18_marker" ] && r=0 || r=1
assert_eq "F19a: token mismatch (prior X server) → stale marker CLEARED" "1" "$r"
assert_contains "F19a: the stale-marker clearing is logged visibly" \
    "clearing stale X-grant ownership marker" "$f18a_log"
assert_contains "F19a: clearing names the token-mismatch cause" \
    "token mismatch" "$f18a_log"
assert_contains "F19a: still logs the pre-existing no-revoke decision" \
    "already authorized" "$f18a_log"
# Teardown now treats the authorization as pre-existing (no marker) → NO revoke.
reset_xhost_log
f18a_revoke_log="$(_revoke_agent_x_display_access ":8" 2>&1)"
assert_eq "F19a: teardown does NOT revoke after marker cleared (pre-existing)" \
    "0" "$(xhost_calls)"
assert_contains "F19a: teardown logs the preserve decision" \
    "broker does not own this grant" "$f18a_revoke_log"
rm -f "$SESSIONS_DIR/c-stale.json"

# --- F19b (P1 REGRESSION GUARD): already-authorized + marker token MATCHES the
#           current X session + NO other consumer → marker KEPT. This is the
#           round-11 retained-after-failed-revoke case the round-15 consumer-count
#           logic leaked: a live broker-owned grant with zero current consumers
#           must NOT be misclassified stale. The subsequent teardown can then
#           still revoke it. ---
clear_sessions
clear_markers
export DISPLAY=":8"
f18_marker="$(_xhost_ownership_marker_path ":8")"
# Marker stamped against the CURRENT X session (token match) — a live grant
# retained after a failed revoke. NO other consumer is present.
broker_owns_display ":8" "$MOCK_X_TOKEN"
reset_xhost_log
_write_starting_claim "$SESSIONS_DIR/c-live.json" "c-live" ":8"
f18b_log="$(_grant_agent_x_display_access "c-live" 2>&1)"
[ -e "$f18_marker" ] && r=0 || r=1
assert_eq "F19b: token match + no consumer → marker KEPT (live retained grant, not stale)" \
    "0" "$r"
case "$f18b_log" in
    *"clearing stale X-grant ownership marker"*) r=1 ;; *) r=0 ;;
esac
assert_eq "F19b: does NOT log a stale-marker clearing" "0" "$r"
# The retained marker survives → the subsequent teardown CAN still revoke it
# (the leak round-15 introduced is closed: the marker was never deleted).
rm -f "$SESSIONS_DIR/c-live.json"
reset_xhost_log
_revoke_agent_x_display_access ":8"
assert_eq "F19b: kept marker → teardown CAN still revoke the broker-owned grant" \
    "1" "$(xhost_calls)"
assert_contains "F19b: revoke targets the right display" \
    "xhost -SI:localuser:boxa-agent" "$(xhost_last)"

# --- F19b2: token MATCH but ANOTHER live consumer on the display → still KEPT
#            (the ordinary multi-session shared-grant case). ---
clear_sessions
clear_markers
export DISPLAY=":8"
f18_marker="$(_xhost_ownership_marker_path ":8")"
broker_owns_display ":8" "$MOCK_X_TOKEN"
write_session_stub_on "live-peer" ":8"
reset_xhost_log
_write_starting_claim "$SESSIONS_DIR/c-shared.json" "c-shared" ":8"
_grant_agent_x_display_access "c-shared" >/dev/null 2>&1
[ -e "$f18_marker" ] && r=0 || r=1
assert_eq "F19b2: token match + live peer → marker KEPT (shared grant)" "0" "$r"
rm -f "$SESSIONS_DIR/live-peer.json" "$SESSIONS_DIR/c-shared.json"

# --- F19b3: marker token MISSING (old marker, empty content) → ownership
#            UNVERIFIABLE → marker DROPPED + logged (#12 review — supersedes the
#            prior keep-on-uncertainty default). The broker never claims ownership
#            it cannot prove; an unverifiable marker could make teardown revoke a
#            USER's pre-existing grant. ---
clear_sessions
clear_markers
export DISPLAY=":8"
f18_marker="$(_xhost_ownership_marker_path ":8")"
: > "$f18_marker"              # an OLD marker with no xsession= line
reset_xhost_log
_write_starting_claim "$SESSIONS_DIR/c-old.json" "c-old" ":8"
f18b3_log="$(_grant_agent_x_display_access "c-old" 2>&1)"
[ -e "$f18_marker" ] && r=0 || r=1
assert_eq "F19b3: marker missing a token → DROPPED (unverifiable, never claim unprovable ownership)" \
    "1" "$r"
assert_contains "F19b3: untokenized marker → unverifiable-drop logged" \
    "clearing unverifiable X-grant ownership marker" "$f18b3_log"
# It is NOT logged as a stale (token-mismatch) clear — it is the unverifiable arm.
case "$f18b3_log" in
    *"clearing stale X-grant ownership marker"*) r=1 ;; *) r=0 ;;
esac
assert_eq "F19b3: untokenized marker → NOT logged as a token-mismatch stale clear" "0" "$r"
rm -f "$SESSIONS_DIR/c-old.json"

# --- F19b4: current token UNDERIVABLE (no boot id / no X socket — exotic display)
#            → ownership UNVERIFIABLE → marker DROPPED + logged, even when the
#            marker carries a (now-incomparable) token (#12 review). ---
clear_sessions
clear_markers
export DISPLAY=":8"
f18_marker="$(_xhost_ownership_marker_path ":8")"
broker_owns_display ":8" "boot=OLD;sock=9:9000"   # marker has a token
reset_xhost_log
saved_token="$MOCK_X_TOKEN"
MOCK_X_TOKEN=""               # the current token cannot be derived
_write_starting_claim "$SESSIONS_DIR/c-noctok.json" "c-noctok" ":8"
f18b4_log="$(_grant_agent_x_display_access "c-noctok" 2>&1)"
[ -e "$f18_marker" ] && r=0 || r=1
assert_eq "F19b4: current token underivable → marker DROPPED (unverifiable)" "1" "$r"
assert_contains "F19b4: underivable current token → unverifiable-drop logged" \
    "clearing unverifiable X-grant ownership marker" "$f18b4_log"
case "$f18b4_log" in
    *"clearing stale X-grant ownership marker"*) r=1 ;; *) r=0 ;;
esac
assert_eq "F19b4: underivable current token → NOT logged as a token-mismatch stale clear" "0" "$r"
MOCK_X_TOKEN="$saved_token"
rm -f "$SESSIONS_DIR/c-noctok.json"

# --- F19c: already-authorized + NO marker (pure pre-existing user grant) →
#           unchanged: no marker created, no clearing, teardown does NOT revoke. ---
clear_sessions
clear_markers
export DISPLAY=":8"
f18_marker="$(_xhost_ownership_marker_path ":8")"
[ -e "$f18_marker" ] && r=0 || r=1
assert_eq "F19c setup: no marker present" "1" "$r"
reset_xhost_log
_write_starting_claim "$SESSIONS_DIR/c-pure.json" "c-pure" ":8"
f18c_log="$(_grant_agent_x_display_access "c-pure" 2>&1)"
[ -e "$f18_marker" ] && r=0 || r=1
assert_eq "F19c: no marker → none created on already-authorized path" "1" "$r"
case "$f18c_log" in
    *"clearing stale X-grant ownership marker"*) r=1 ;; *) r=0 ;;
esac
assert_eq "F19c: no marker → nothing to clear (no stale-marker log)" "0" "$r"
reset_xhost_log
_revoke_agent_x_display_access ":8"
assert_eq "F19c: teardown does NOT revoke a pure pre-existing grant" \
    "0" "$(xhost_calls)"
rm -f "$SESSIONS_DIR/c-pure.json"

# --- F19d: NOT-yet-authorized branch — marker CREATED, STAMPED with the current
#           X-session token, grant added, teardown revokes (regression guard +
#           the new token-stamping assertion). ---
# shellcheck disable=SC2317
xhost() {
    if [ "$#" -eq 0 ]; then
        printf 'access control enabled, only authorized clients can connect\nSI:localuser:root\n'
        return 0
    fi
    printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"
    return 0
}
clear_sessions
clear_markers
export DISPLAY=":8"
f18_marker="$(_xhost_ownership_marker_path ":8")"
reset_xhost_log
_write_starting_claim "$SESSIONS_DIR/c-add.json" "c-add" ":8"
_grant_agent_x_display_access "c-add"
[ -e "$f18_marker" ] && r=0 || r=1
assert_eq "F19d: not-yet-authorized → marker CREATED" "0" "$r"
assert_eq "F19d: marker STAMPED with the current X-session token" \
    "$MOCK_X_TOKEN" "$(_x_session_token_from_marker "$f18_marker")"
assert_contains "F19d: the +SI grant ran" "+SI:localuser:boxa-agent" "$(xhost_last)"
rm -f "$SESSIONS_DIR/c-add.json"
reset_xhost_log
_revoke_agent_x_display_access ":8"
assert_eq "F19d: broker-owned grant → teardown revokes" "1" "$(xhost_calls)"

export DISPLAY=":0"
clear_markers
seed_owned_markers
# restore the plain recording xhost mock for any later use
# shellcheck disable=SC2317
xhost() { printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"; return 0; }

# ----------------------------------------------------------------------------
# F14 — the X-grant critical sections are SERIALIZED under a host flock (#12
#       review finding 1). A real concurrency race is impractical to drive in
#       bash, so we assert the LOCKED-REGION COMPOSITION + ordering invariant:
#       both the grant/claim and the count→revoke run *inside* a held lock, and
#       a missing `flock` degrades to a warned lock-free fallback (still works).
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1

# Mock `flock` to record that the lock was acquired, in order, around the
# critical section. The real `_with_xhost_grant_lock` runs `flock -x 9` inside a
# subshell; our mock just records the acquisition to a log and returns 0 so the
# wrapped command runs. SC2317: invoked only via the wrapper under test.
FLOCK_LOG="$(mktemp)"
# shellcheck disable=SC2317
flock() { printf 'LOCK\n' >> "$FLOCK_LOG"; return 0; }
FLOCK_PRESENT=1
# Re-point command -v so flock presence is togglable for the fallback test.
# shellcheck disable=SC2317
command() {
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "flock" ]; then
        [ "$FLOCK_PRESENT" = "1" ] && return 0
        return 1
    fi
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "xhost" ]; then
        [ "$XHOST_PRESENT" = "1" ] && return 0
        return 1
    fi
    builtin command "$@"
}

# --- the revoke critical section acquires the lock, then runs count→revoke ---
clear_sessions
: > "$FLOCK_LOG"
reset_xhost_log
FLOCK_PRESENT=1
_revoke_x_display_if_last_session "lockc" ":0"
assert_eq "F14 lock: the teardown count→revoke acquired the flock" \
    "1" "$(grep -c '^LOCK$' "$FLOCK_LOG")"
assert_eq "F14 lock: and the revoke fired inside the held lock" "1" "$(xhost_calls)"

# --- a peer present → the locked region still runs the count and DECLINES to
#     revoke (the ordering invariant: count+decide+revoke are one locked unit) ---
clear_sessions
ALIVE_PIDS=" 4242 "
write_session_stub_on "lock-peer" ":0"
: > "$FLOCK_LOG"
reset_xhost_log
_revoke_x_display_if_last_session "lockc" ":0"
assert_eq "F14 lock: locked region acquired even when it will not revoke" \
    "1" "$(grep -c '^LOCK$' "$FLOCK_LOG")"
assert_eq "F14 lock: peer present → no revoke (count inside the lock saw it)" \
    "0" "$(xhost_calls)"

# --- flock MISSING → warned lock-free fallback, the section STILL runs ---
clear_sessions
FLOCK_PRESENT=0
: > "$FLOCK_LOG"
reset_xhost_log
_XHOST_FLOCK_WARNED=0                  # reset the one-time warning latch
fallback_log="$(_revoke_x_display_if_last_session "lockc" ":0" 2>&1)"
assert_eq "F14 fallback: flock missing → NO flock acquisition recorded" \
    "0" "$(grep -c '^LOCK$' "$FLOCK_LOG")"
assert_contains "F14 fallback: warns that the section runs unserialized" \
    "UNSERIALIZED" "$fallback_log"
assert_eq "F14 fallback: the revoke STILL fires (functionality preserved)" \
    "1" "$(xhost_calls)"
# The warning is one-time PER PROCESS (latched in `_XHOST_FLOCK_WARNED`). Drive
# two fallback sections in ONE subshell and confirm only the FIRST warns — the
# command-substitution subshells above each reset the latch, so the latch must
# be checked within a single process to be observable.
onetime_out="$( { _XHOST_FLOCK_WARNED=0; _with_xhost_grant_lock true; _with_xhost_grant_lock true; } 2>&1 )"
warn_hits="$(printf '%s\n' "$onetime_out" | grep -c 'UNSERIALIZED' || true)"
assert_eq "F14 fallback: warning is one-time per process (latched)" "1" "$warn_hits"
FLOCK_PRESENT=1
_XHOST_FLOCK_WARNED=0

# ----------------------------------------------------------------------------
# F15 — retain the per-display ownership marker when `xhost -SI` revoke FAILS
#       (#12/#14 review finding 1). A `stop` over SSH with no usable X
#       authorization makes the revoke command fail; deleting the marker then
#       would make every future teardown treat the still-active grant as
#       pre-existing (no marker → no revoke) → a permanent leak. So the marker
#       is removed ONLY when `xhost -SI` SUCCEEDS; on failure it is RETAINED and
#       a warning fires, so a later cmd_stop / sweep retries the revoke.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1

# A fail-aware xhost mock: the access-list query (no args) reports boxa-agent
# NOT yet authorized (so grant would own it); the `-SI` revoke fails when
# XHOST_FAIL=1, records + succeeds otherwise. Still logs every grant/revoke arg.
# SC2317: reached only via the helpers under test.
XHOST_FAIL=0
# shellcheck disable=SC2317
xhost() {
    if [ "$#" -eq 0 ]; then
        printf 'access control enabled, only authorized clients can connect\nSI:localuser:root\n'
        return 0
    fi
    printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"
    case "$*" in
        -SI:localuser:boxa-agent) [ "$XHOST_FAIL" = "1" ] && return 1 ;;
    esac
    return 0
}

# --- revoke FAILS → marker RETAINED + warning ---
clear_markers
broker_owns_display ":2"
f15_marker="$(_xhost_ownership_marker_path ":2")"
reset_xhost_log
XHOST_FAIL=1
f15_fail_log="$(_revoke_agent_x_display_access ":2" 2>&1)"
assert_eq "F15 revoke-fail: the -SI revoke WAS attempted" "1" "$(xhost_calls)"
[ -e "$f15_marker" ] && r=0 || r=1
assert_eq "F15 revoke-fail: ownership marker RETAINED (not deleted on failure)" "0" "$r"
assert_contains "F15 revoke-fail: warns it will retry on next teardown/sweep" \
    "will retry on next teardown/sweep" "$f15_fail_log"

# --- a SUBSEQUENT teardown with the retained marker RETRIES the revoke ---
# The marker survived above, so this second attempt must fire again (the retry
# path the retain enables). This time the revoke SUCCEEDS → marker removed.
reset_xhost_log
XHOST_FAIL=0
_revoke_agent_x_display_access ":2"
assert_eq "F15 retry: retained marker → next teardown RETRIES the revoke" \
    "1" "$(xhost_calls)"
[ -e "$f15_marker" ] && r=0 || r=1
assert_eq "F15 retry: revoke now SUCCEEDS → marker removed" "1" "$r"

# --- revoke SUCCEEDS first time → marker deleted immediately ---
clear_markers
broker_owns_display ":3"
f15_marker_ok="$(_xhost_ownership_marker_path ":3")"
reset_xhost_log
XHOST_FAIL=0
_revoke_agent_x_display_access ":3"
assert_eq "F15 revoke-ok: the -SI revoke ran" "1" "$(xhost_calls)"
[ -e "$f15_marker_ok" ] && r=0 || r=1
assert_eq "F15 revoke-ok: ownership marker deleted on success" "1" "$r"

XHOST_FAIL=0

# ----------------------------------------------------------------------------
# F16 — `_sweep_if_stale` releases a crashed session's persisted X grant
#       (#12/#14 review finding 2). cmd_stop / start-rollback already
#       revoke-if-last; the sweep was the missing path. A crashed session whose
#       replacement is headless or on a DIFFERENT display would otherwise leak
#       its old-display authorization + ownership marker forever. The sweep must
#       invoke the SAME locked last-session revoke (honouring the per-display
#       ownership marker), and must NOT count the just-swept session's own
#       now-dead Chrome as a live consumer blocking its own revoke.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1

# The sweep only reaches its cleanup branch when NOTHING is alive. Model that
# with all PIDs dead (outside ALIVE_PIDS) and the container gone, so the bridge
# / container-firewall branches are skipped. `_container_running` is mocked to
# report the container down. SC2317: reached only via the sweep under test.
# shellcheck disable=SC2317
_container_running() { return 1; }

# Restore the recording (non-failing, always-revoke) xhost mock for the sweep
# revoke assertions — F16 asserts the revoke FIRES, not failure handling.
# shellcheck disable=SC2317
xhost() { printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"; return 0; }

# A stale crashed-session state file: dead Chrome PID (9999 ∉ ALIVE_PIDS), null
# bridge/relay/proxy/watchdog, null ufw + profile fields (so those cleanup
# branches no-op), and a persisted granted_display to revoke against.
write_stale_session() {
    local container="$1" display="$2"
    cat > "$SESSIONS_DIR/$container.json" <<EOF
{
  "container": "${container}",
  "chrome_pid": 9999,
  "bridge_pid_in_container": null,
  "relay_pid_host": null,
  "proxy_pid": null,
  "watchdog_pid": null,
  "cdp_port_host": null,
  "proxy_port_host": null,
  "profile_dir": null,
  "download_dir": null,
  "host_allow_ip": null,
  "ufw_slot_subnet": null,
  "granted_display": "${display}"
}
EOF
}

# --- stale session, no other consumer on its display → locked revoke fires ---
clear_sessions                       # re-seeds owned markers for :0/:1/:7
ALIVE_PIDS=" "                       # nothing alive: the crashed session is dead
write_stale_session "stale-1" ":0"
: > "$FLOCK_LOG"
reset_xhost_log
_sweep_if_stale "stale-1"; rc=$?
assert_eq "F16 sweep: stale session swept (state file removed → rc 0)" "0" "$rc"
[ -e "$SESSIONS_DIR/stale-1.json" ] && r=0 || r=1
assert_eq "F16 sweep: stale state file discarded" "1" "$r"
assert_eq "F16 sweep: last-consumer X revoke fired for the stale display" \
    "1" "$(xhost_calls)"
assert_contains "F16 sweep: revoke targeted the per-uid removal selector" \
    "xhost -SI:localuser:boxa-agent" "$(xhost_last)"
assert_eq "F16 sweep: the revoke ran inside the held flock (locked helper reused)" \
    "1" "$(grep -c '^LOCK$' "$FLOCK_LOG")"

# --- another LIVE consumer on the SAME display → sweep does NOT revoke ---
clear_sessions
ALIVE_PIDS=" 4242 "                  # the live peer's chrome_pid
write_session_stub_on "live-on-0" ":0"   # a live consumer on :0
write_stale_session "stale-2" ":0"
reset_xhost_log
_sweep_if_stale "stale-2"; rc=$?
assert_eq "F16 sweep+peer: stale session still swept (rc 0)" "0" "$rc"
assert_eq "F16 sweep+peer: a live :0 consumer blocks the revoke (grant preserved)" \
    "0" "$(xhost_calls)"

# --- the stale session's OWN now-dead Chrome must not block its own revoke ---
# Model it as the ONLY file on its display, marked dead. The revoke must STILL
# fire — proving self is excluded (by name) and the dead Chrome is not counted.
clear_sessions
ALIVE_PIDS=" "                       # the stale session's chrome 9999 is dead
write_stale_session "stale-self" ":1"
reset_xhost_log
_sweep_if_stale "stale-self" >/dev/null
assert_eq "F16 self: stale session's own dead Chrome does NOT block its revoke" \
    "1" "$(xhost_calls)"

# --- pre-existing (non-broker) grant: NO ownership marker → sweep does NOT revoke ---
clear_sessions
clear_markers                        # no marker for any display → broker owns none
ALIVE_PIDS=" "
write_stale_session "stale-nomark" ":0"
reset_xhost_log
_sweep_if_stale "stale-nomark" >/dev/null
assert_eq "F16 marker-honored: no ownership marker → sweep leaves grant intact" \
    "0" "$(xhost_calls)"

# --- ufw delete FAILS during the sweep → state file RETAINED for ufw retry, but
#     the X grant is STILL revoked (decoupling; #12/#14 review). A failed
#     `sudo ufw delete` (sudo could not authenticate mid-sweep) must not leave
#     the dead session's broker-owned X authorization alive — the ufw-retain
#     decision governs ONLY whether the state file is kept for a retry. Mirrors
#     cmd_stop's round-6/finding-1 decoupling.
#
# Force the real `_release_or_retain_ufw_slot` to RETAIN without a mock or a real
# `sudo ufw delete`: give the stale session an owned ufw slot triple whose relay
# IP is MALFORMED, so the real `_close_host_ufw_slot` selector validation refuses
# the privileged delete and returns 1 (retain) BEFORE any sudo call (the same
# refuse-on-malformed path F4 verifies). `command -v ufw` must report present so
# validation runs; the container-side slot branch is skipped because
# `_container_running` is mocked down for the whole F16 block. No redefinition of
# the close chokepoint — keeps shellcheck's reachability clean.
UFW_PRESENT=1
# shellcheck disable=SC2317
command() {
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "xhost" ]; then
        [ "$XHOST_PRESENT" = "1" ] && return 0
        return 1
    fi
    if [ "${1:-}" = "-v" ] && [ "${2:-}" = "ufw" ]; then
        [ "$UFW_PRESENT" = "1" ] && return 0
        return 1
    fi
    builtin command "$@"
}
# A stale crashed-session file WITH an owned host-ufw slot triple whose relay IP
# is malformed, so the real `_close_host_ufw_slot` refuses to delete and the
# release helper returns 1 (retain). SC-clean: defined once, used below.
write_stale_session_bad_ufw() {
    local container="$1" display="$2"
    cat > "$SESSIONS_DIR/$container.json" <<EOF
{
  "container": "${container}",
  "chrome_pid": 9999,
  "bridge_pid_in_container": null,
  "relay_pid_host": null,
  "proxy_pid": null,
  "watchdog_pid": null,
  "cdp_port_host": 40000,
  "proxy_port_host": null,
  "profile_dir": null,
  "download_dir": null,
  "host_allow_ip": "not-an-ip",
  "ufw_slot_subnet": "172.20.0.0/16",
  "granted_display": "${display}"
}
EOF
}
clear_sessions
ALIVE_PIDS=" "                       # the crashed session is fully dead
write_stale_session_bad_ufw "stale-ufwfail" ":0"
: > "$FLOCK_LOG"
reset_xhost_log
_sweep_if_stale "stale-ufwfail" >/dev/null 2>&1; rc=$?
assert_eq "F16 ufw-fail: sweep refuses (rc 1) so start won't launch over the open slot" \
    "1" "$rc"
[ -e "$SESSIONS_DIR/stale-ufwfail.json" ] && r=0 || r=1
assert_eq "F16 ufw-fail: state file RETAINED for the ufw retry (not discarded)" \
    "0" "$r"
assert_eq "F16 ufw-fail: retained file marked ufw_retry_only (not a display consumer)" \
    "1" "$(grep -c '"ufw_retry_only"' "$SESSIONS_DIR/stale-ufwfail.json" 2>/dev/null || true)"
assert_eq "F16 ufw-fail: X grant STILL revoked despite the ufw retain (decoupled)" \
    "1" "$(xhost_calls)"
assert_contains "F16 ufw-fail: revoke targeted the per-uid removal selector" \
    "xhost -SI:localuser:boxa-agent" "$(xhost_last)"
assert_eq "F16 ufw-fail: the revoke ran inside the held flock (locked helper reused)" \
    "1" "$(grep -c '^LOCK$' "$FLOCK_LOG")"

# --- ufw delete FAILS AND a live consumer on the same display → revoke blocked ---
# The decoupled revoke still honours the same-display refcount: a genuinely
# alive peer on :0 must keep the grant even when the sweep retains for ufw.
clear_sessions
ALIVE_PIDS=" 4242 "                  # the live peer's chrome_pid
write_session_stub_on "live-on-0b" ":0"  # a live consumer on :0
write_stale_session_bad_ufw "stale-ufwfail-peer" ":0"
reset_xhost_log
_sweep_if_stale "stale-ufwfail-peer" >/dev/null 2>&1; rc=$?
assert_eq "F16 ufw-fail+peer: sweep still refuses (rc 1)" "1" "$rc"
assert_eq "F16 ufw-fail+peer: a live :0 consumer blocks the decoupled revoke" \
    "0" "$(xhost_calls)"
[ -e "$SESSIONS_DIR/stale-ufwfail-peer.json" ] && r=0 || r=1
assert_eq "F16 ufw-fail+peer: state file still RETAINED for the ufw retry" "0" "$r"

unset -f _container_running          # restore the real container probe
ALIVE_PIDS=" 4242 "                  # restore default

# ----------------------------------------------------------------------------
# F18 — expire ABANDONED `status:"starting"` claims via the broker `starting_pid`
#       liveness (#12 review P2). The early starting-claim (round 8) is counted
#       as a display consumer to close the concurrent-start race, but ONLY while
#       the broker driving the start is alive. A broker killed AFTER writing the
#       early claim but BEFORE the full-state write leaves an orphaned starting
#       file; without a liveness gate it would be treated as a live consumer
#       INDEFINITELY, so the last REAL session's stop could never revoke the
#       broker-owned X grant (permanent leak). The fix: persist the cmd_start
#       broker PID as `starting_pid` in the claim and count the claim ONLY while
#       that PID is alive; a dead PID = abandoned = NOT a consumer, and the sweep
#       reclaims it. `_pid_alive_on_host` is the (mocked) liveness primitive;
#       ALIVE_PIDS controls which PIDs are "alive". xhost/flock/sudo/command
#       mocks from F16 are still active.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1

# A starting-claim carrying an explicit `starting_pid` (mirrors what cmd_start
# now persists via _write_starting_claim's 4th arg — the broker `$$`).
write_starting_claim_pid() {
    local container="$1" display="$2" starting_pid="$3"
    _write_starting_claim "$SESSIONS_DIR/$container.json" "$container" "$display" "$starting_pid"
}

# --- claim-shape: starting_pid is persisted into the claim JSON ---
clear_sessions
write_starting_claim_pid "claimP" ":0" "5555"
assert_eq "F18 shape: starting_pid persisted into the claim" \
    "5555" "$(_state_get "$SESSIONS_DIR/claimP.json" starting_pid)"

# --- ALIVE starting_pid → claim IS a consumer (round-8 race fix intact) ---
clear_sessions
ALIVE_PIDS=" 5555 "                   # the in-progress broker is alive
write_starting_claim_pid "live-start" ":0" "5555"
_state_file_is_display_consumer "$SESSIONS_DIR/live-start.json" && r=0 || r=1
assert_eq "F18 live: starting claim with ALIVE broker IS a display consumer" "0" "$r"
# A concurrently-starting sibling's revoke-if-last must NOT revoke while the
# in-progress start's broker is alive (the round-8 concurrent-start race).
reset_xhost_log
_revoke_x_display_if_last_session "siblingB" ":0"
assert_eq "F18 live: an in-progress start (alive broker) blocks the sibling's revoke" \
    "0" "$(xhost_calls)"

# --- DEAD starting_pid (broker killed mid-start) → claim NOT a consumer ---
clear_sessions
ALIVE_PIDS=" "                        # the broker that wrote the claim is gone
write_starting_claim_pid "abandoned" ":0" "5555"
_state_file_is_display_consumer "$SESSIONS_DIR/abandoned.json" && r=0 || r=1
assert_eq "F18 abandoned: starting claim with DEAD broker is NOT a consumer" "1" "$r"
assert_eq "F18 abandoned: an abandoned claim is not counted as a live peer" \
    "0" "$(_count_other_live_sessions "otherc" ":0")"

# --- last REAL session's stop on that display revokes despite the orphaned
#     claim (the leak this fix closes) ---
clear_sessions
ALIVE_PIDS=" "                        # only the dead-broker orphan remains
write_starting_claim_pid "abandoned" ":0" "5555"
reset_xhost_log
_revoke_x_display_if_last_session "stopping-real" ":0"
assert_eq "F18 abandoned: orphaned claim does NOT pin the grant → revoke fires" \
    "1" "$(xhost_calls)"

# --- a fully-established session (status no longer "starting") is UNAFFECTED by
#     the starting_pid logic: it is validated by its live chrome_pid, never
#     mis-expired by a stale/absent starting_pid (the full-state writer omits the
#     status field). Model it with a dead starting_pid value present but a LIVE
#     chrome — it must still count. ---
clear_sessions
ALIVE_PIDS=" 4242 "                   # chrome alive; the stray starting_pid is dead
cat > "$SESSIONS_DIR/established.json" <<'EOF'
{
  "container": "established",
  "chrome_pid": 4242,
  "starting_pid": 9999,
  "granted_display": ":0",
  "profile_dir": "/var/lib/boxa-agent/profiles/established-x"
}
EOF
_state_file_is_display_consumer "$SESSIONS_DIR/established.json" && r=0 || r=1
assert_eq "F18 established: a live-chrome session is a consumer (status not starting → starting_pid ignored)" \
    "0" "$r"

# --- _sweep_if_stale reclaims an ABANDONED starting claim (dead broker, no live
#     chrome/proxy): file removed AND the revoke-if-last honored. ---
# shellcheck disable=SC2317
_container_running() { return 1; }    # container gone → bridge/fw branches no-op
clear_sessions                        # re-seeds owned markers for :0
ALIVE_PIDS=" "                        # the broker (5555) is dead, no chrome
write_starting_claim_pid "sweep-orphan" ":0" "5555"
: > "$FLOCK_LOG"
reset_xhost_log
_sweep_if_stale "sweep-orphan"; rc=$?
assert_eq "F18 sweep: abandoned starting claim swept (rc 0)" "0" "$rc"
[ -e "$SESSIONS_DIR/sweep-orphan.json" ] && r=0 || r=1
assert_eq "F18 sweep: abandoned starting-claim file removed" "1" "$r"
assert_eq "F18 sweep: revoke-if-last fired for the orphan's display" \
    "1" "$(xhost_calls)"
assert_eq "F18 sweep: the revoke ran inside the held flock (locked helper reused)" \
    "1" "$(grep -c '^LOCK$' "$FLOCK_LOG")"

# --- a genuinely IN-PROGRESS start (ALIVE broker) must NOT be swept: the sweep
#     refuses (rc 1) so it never races a live start by tearing its claim. ---
clear_sessions
ALIVE_PIDS=" 5555 "                   # the broker driving the start is alive
write_starting_claim_pid "sweep-inprogress" ":0" "5555"
reset_xhost_log
_sweep_if_stale "sweep-inprogress"; rc=$?
assert_eq "F18 sweep: an in-progress start (alive broker) is NOT swept (rc 1)" "1" "$rc"
[ -e "$SESSIONS_DIR/sweep-inprogress.json" ] && r=0 || r=1
assert_eq "F18 sweep: the in-progress start's claim is preserved" "0" "$r"
assert_eq "F18 sweep: no revoke fired against a live in-progress start" \
    "0" "$(xhost_calls)"

unset -f _container_running          # restore the real container probe
ALIVE_PIDS=" 4242 "                  # restore default

# ----------------------------------------------------------------------------
# F18b — starting_pid IDENTITY (start-time), not just liveness (#12 review P2,
#        finding 2). A bare `_pid_alive_on_host` check is PID-REUSE-unsafe: after
#        a crash/reboot the kernel may hand `starting_pid` to an unrelated host
#        process, so the abandoned claim would be treated as a live in-progress
#        start forever (refusing the sweep AND pinning the X grant). The fix
#        records the broker's `/proc/<pid>/stat` START TIME alongside the PID and
#        the shared `_starting_pid_is_live` guard requires BOTH a live PID AND a
#        matching starttime. A reused PID (alive, starttime MISMATCH) is treated
#        as ABANDONED; an absent recorded starttime (old claim) falls back to
#        bare liveness. `PID_STARTTIME` controls the mocked live starttime.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1

# --- claim-shape: the start time is persisted alongside starting_pid ---
clear_sessions
PID_STARTTIME=([7777]="424242")
ALIVE_PIDS=" 7777 "
write_starting_claim_pid "claimT" ":0" "7777"
assert_eq "F18b shape: starting_pid persisted" \
    "7777" "$(_state_get "$SESSIONS_DIR/claimT.json" starting_pid)"
assert_eq "F18b shape: starting_pid_starttime persisted (process identity)" \
    "424242" "$(_state_get "$SESSIONS_DIR/claimT.json" starting_pid_starttime)"

# --- alive PID + MATCHING starttime → live in-progress start (consumer; sweep
#     refuses) — round-8 race fix intact under the identity check ---
clear_sessions
PID_STARTTIME=([7777]="424242")
ALIVE_PIDS=" 7777 "
write_starting_claim_pid "ident-live" ":0" "7777"
_state_file_is_display_consumer "$SESSIONS_DIR/ident-live.json" && r=0 || r=1
assert_eq "F18b live: alive PID + matching starttime IS a consumer" "0" "$r"
# shellcheck disable=SC2317
_container_running() { return 1; }
reset_xhost_log
_sweep_if_stale "ident-live"; rc=$?
assert_eq "F18b live: sweep REFUSES a live identity-matched in-progress start (rc 1)" "1" "$rc"
[ -e "$SESSIONS_DIR/ident-live.json" ] && r=0 || r=1
assert_eq "F18b live: the in-progress claim is preserved" "0" "$r"
unset -f _container_running

# --- alive PID but starttime MISMATCH (reused PID) → ABANDONED: NOT a consumer,
#     and the sweep reclaims it. This is the PID-reuse leak the fix closes. ---
clear_sessions
ALIVE_PIDS=" 7777 "                  # PID is alive throughout
# Stamp the claim with the ORIGINAL broker's start time (the claim records
# whatever _pid_starttime_on_host reports at write time).
PID_STARTTIME=([7777]="111111")
write_starting_claim_pid "ident-reused" ":0" "7777"
assert_eq "F18b reuse setup: claim stamped with the original starttime" \
    "111111" "$(_state_get "$SESSIONS_DIR/ident-reused.json" starting_pid_starttime)"
# Now the SAME PID belongs to a DIFFERENT process (reused after a crash/reboot):
# alive, but its live start time no longer matches the recorded one.
PID_STARTTIME=([7777]="222222")
_state_file_is_display_consumer "$SESSIONS_DIR/ident-reused.json" && r=0 || r=1
assert_eq "F18b reuse: alive PID + MISMATCHED starttime is NOT a consumer" "1" "$r"
assert_eq "F18b reuse: reused-PID claim not counted as a live peer" \
    "0" "$(_count_other_live_sessions "otherc" ":0")"
# shellcheck disable=SC2317
_container_running() { return 1; }
reset_xhost_log
_sweep_if_stale "ident-reused"; rc=$?
assert_eq "F18b reuse: sweep RECLAIMS the abandoned reused-PID claim (rc 0)" "0" "$rc"
[ -e "$SESSIONS_DIR/ident-reused.json" ] && r=0 || r=1
assert_eq "F18b reuse: reused-PID claim file removed" "1" "$r"
assert_eq "F18b reuse: orphan does NOT pin the grant → revoke fires" \
    "1" "$(xhost_calls)"
unset -f _container_running

# --- recorded starttime ABSENT (older claim pre-dating the field) → fall back to
#     bare liveness: an alive PID still counts (backward compatible). ---
clear_sessions
ALIVE_PIDS=" 7777 "
cat > "$SESSIONS_DIR/oldclaim.json" <<'EOF'
{
  "container": "oldclaim",
  "status": "starting",
  "granted_display": ":0",
  "starting_pid": 7777,
  "chrome_pid": null
}
EOF
_state_file_is_display_consumer "$SESSIONS_DIR/oldclaim.json" && r=0 || r=1
assert_eq "F18b old-claim: absent starttime → bare-liveness fallback (alive → consumer)" "0" "$r"
# And a dead PID with no recorded starttime is still NOT a consumer.
ALIVE_PIDS=" "
_state_file_is_display_consumer "$SESSIONS_DIR/oldclaim.json" && r=0 || r=1
assert_eq "F18b old-claim: absent starttime + dead PID → not a consumer" "1" "$r"

PID_STARTTIME=()                     # restore default-starttime behaviour
ALIVE_PIDS=" 4242 "                  # restore default

# ----------------------------------------------------------------------------
# F17 — `_kill_bridge_in_container` verifies the bridge PID identity before
#       killing (#12/#14 review finding 3). If the container RESTARTED after the
#       PID was recorded, `_container_running` passes against the NEW container
#       and a bare kill could terminate an UNRELATED process that reused the
#       small PID. The helper now confirms the PID still belongs to OUR socat
#       (via `_pid_matches_marker_in_container`) and kills ONLY on a match; on a
#       mismatch it SKIPs + warns. Pre-existing guards preserved: no-op on an
#       unset PID, warn-not-abort when the container is gone.
# ----------------------------------------------------------------------------
# Record any in-container `docker exec <c> kill <pid>` so we can assert it ran
# (or did not). SC2317: the mocks below are reached only via the helper.
BRIDGE_KILL_LOG="$(mktemp)"
bridge_kills() { grep -c . "$BRIDGE_KILL_LOG" 2>/dev/null || true; }
reset_bridge_kill_log() { : > "$BRIDGE_KILL_LOG"; }
# shellcheck disable=SC2317
docker() {
    if [ "${1:-}" = "exec" ] && [ "${3:-}" = "kill" ]; then
        printf 'kill %s\n' "${4:-}" >> "$BRIDGE_KILL_LOG"
        return 0
    fi
    return 0
}
# Container is RUNNING by default for these cases (the restart hazard the guard
# protects against). SC2317: reached only via the helper.
F17_CONTAINER_UP=1
# shellcheck disable=SC2317
_container_running() { [ "$F17_CONTAINER_UP" = "1" ]; }
# Identity probe togglable MATCH/MISMATCH. SC2317: reached only via the helper.
F17_PID_MATCHES=1
# shellcheck disable=SC2317
_pid_matches_marker_in_container() { [ "$F17_PID_MATCHES" = "1" ]; }

# --- identity MATCH → kill issued ---
F17_CONTAINER_UP=1; F17_PID_MATCHES=1
reset_bridge_kill_log
_kill_bridge_in_container "c1" "7"
assert_eq "F17 match: identity confirmed → in-container kill issued" \
    "1" "$(bridge_kills)"

# --- identity MISMATCH (PID reused / container restarted) → NO kill + warn ---
F17_CONTAINER_UP=1; F17_PID_MATCHES=0
reset_bridge_kill_log
f17_mismatch_log="$(_kill_bridge_in_container "c1" "7" 2>&1)"
assert_eq "F17 mismatch: PID no longer ours → NO kill issued" \
    "0" "$(bridge_kills)"
assert_contains "F17 mismatch: warns the original bridge is already gone" \
    "no longer matches our socat" "$f17_mismatch_log"

# --- PID unset → no-op (identity probe never consulted) ---
F17_CONTAINER_UP=1; F17_PID_MATCHES=1
reset_bridge_kill_log
_kill_bridge_in_container "c1" ""
assert_eq "F17 unset: empty bridge PID → no kill (no-op)" "0" "$(bridge_kills)"
_kill_bridge_in_container "c1" "null"
assert_eq "F17 null: literal null bridge PID → no kill (no-op)" "0" "$(bridge_kills)"

# --- container gone → warn, no kill, no abort (return 0) ---
F17_CONTAINER_UP=0; F17_PID_MATCHES=1
reset_bridge_kill_log
f17_gone_log="$(_kill_bridge_in_container "c1" "7" 2>&1)"; rc=$?
assert_eq "F17 gone: container down → no kill" "0" "$(bridge_kills)"
assert_eq "F17 gone: container down → returns 0 (cleanup not aborted)" "0" "$rc"
assert_contains "F17 gone: warns the container is no longer running" \
    "no longer running" "$f17_gone_log"

unset -f docker
unset -f _container_running
unset -f _pid_matches_marker_in_container
rm -f "$BRIDGE_KILL_LOG"

# ----------------------------------------------------------------------------
# F20 — ABORT the start before granting when the starting-claim cannot be
#       written (#12 review P2). `_start_x_claim_and_grant_locked` runs under the
#       caller's `|| exit 1`, which SUPPRESSES `set -e`, so a failed
#       `_write_starting_claim` (disk full / unwritable state dir) would silently
#       fall through to granting the X display with no claim to protect a sibling
#       start and no state to revoke against. The locked helper must check the
#       write's rc EXPLICITLY, NOT grant on failure, name the unwritable state
#       dir, and propagate non-zero so the call site's `|| exit 1` fires the EXIT
#       trap → cleanup (which no-ops since nothing was granted). The success path
#       is unchanged: claim written, then the grant runs.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1
export DISPLAY=":0"

# We do NOT mock `_write_starting_claim` or `_grant_agent_x_display_access`:
# instead we exercise the REAL writer's failure path by pointing the claim at an
# UNWRITABLE path (a state file under a non-existent directory), so its
# `cat > "$file"` redirect genuinely fails — proving the rc actually propagates,
# not just that a mock returned 1. The grant attempt is observed via the existing
# recording `xhost` mock: a real grant would emit `+SI:localuser:boxa-agent`,
# so an empty xhost log proves the grant did NOT run. The current X-grant gating
# (linux + DISPLAY set + xhost present + broker-owns-marker logic) is already in
# force from the prior blocks.
clear_sessions
clear_markers                        # no marker → not-yet-authorized → a grant would +SI

# --- claim write FAILS (unwritable state dir) → helper returns non-zero, grant
#     NOT attempted (no xhost +SI), error names the state dir ---
reset_xhost_log
f20_bad_file="$SESSIONS_DIR/no-such-subdir/claimfail.json"   # parent missing → write fails
f20_fail_log="$(_start_x_claim_and_grant_locked "$f20_bad_file" "claimfail" ":0" 9100 2>&1)"; rc=$?
assert_eq "F20 claim-fail: locked helper returns non-zero (abort propagates to || exit 1)" \
    "1" "$rc"
assert_eq "F20 claim-fail: the X grant was NOT attempted (no xhost call → nothing half-granted)" \
    "0" "$(xhost_calls)"
assert_contains "F20 claim-fail: error names the unwritable state dir" \
    "$SESSIONS_DIR/no-such-subdir" "$f20_fail_log"
assert_contains "F20 claim-fail: error explains it aborts before granting" \
    "aborting start before granting" "$f20_fail_log"

# --- claim write SUCCEEDS → the grant DOES run (unchanged success path) ---
reset_xhost_log
f20_ok_file="$SESSIONS_DIR/claimok.json"
_start_x_claim_and_grant_locked "$f20_ok_file" "claimok" ":0" 9101; rc=$?
assert_eq "F20 claim-ok: helper returns 0 on a successful claim write" "0" "$rc"
assert_contains "F20 claim-ok: the grant runs AFTER a successful claim write (xhost +SI issued)" \
    "+SI:localuser:boxa-agent" "$(xhost_last)"
assert_eq "F20 claim-ok: the claim was actually written (granted_display persisted)" \
    ":0" "$(_state_get "$f20_ok_file" granted_display)"

rm -f "$f20_ok_file"

# ----------------------------------------------------------------------------
# F21 — a failed X-grant REVOKE signals rc 2 and RETAINS the session state file
#       so a later stop/sweep can retry (#12 review P2). Round 11 already retains
#       the ownership MARKER on a failed `xhost -SI`; but cmd_stop had already
#       deleted the STATE FILE that holds `granted_display`, so a repeated stop
#       was a no-op (no state to read) and could never retry. The fix mirrors the
#       ufw-retain pattern: `_revoke_agent_x_display_access` returns rc 2 iff the
#       actual `xhost -SI` it attempted FAILED (distinct from every no-op path,
#       all rc 0), `_revoke_x_display_if_last_session` propagates it verbatim, and
#       cmd_stop / `_cleanup_failed_start` / `_sweep_if_stale` retain the file
#       (marked non-consumer) on rc 2. A SECOND sweep then retries the revoke.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1

# A fail-aware xhost mock: the no-arg access-list query reports boxa-agent NOT
# yet authorized (so a grant would own the marker); the `-SI` revoke fails when
# F21_XHOST_FAIL=1, succeeds (and records) otherwise.
# SC2317: reached only via the helpers under test.
F21_XHOST_FAIL=0
# shellcheck disable=SC2317
xhost() {
    if [ "$#" -eq 0 ]; then
        printf 'access control enabled, only authorized clients can connect\nSI:localuser:root\n'
        return 0
    fi
    printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"
    case "$*" in
        -SI:localuser:boxa-agent) [ "$F21_XHOST_FAIL" = "1" ] && return 1 ;;
    esac
    return 0
}

# --- rc-2 SIGNAL: the actual `xhost -SI` FAILED → rc 2 (distinct from no-op) ---
clear_sessions                       # re-seeds owned markers for :0/:1/:7
clear_markers
broker_owns_display ":0"
reset_xhost_log
F21_XHOST_FAIL=1
_revoke_agent_x_display_access ":0" >/dev/null 2>&1; rc=$?
assert_eq "F21 signal: a FAILED xhost -SI returns rc 2 (retain signal)" "2" "$rc"
assert_eq "F21 signal: the -SI revoke WAS attempted" "1" "$(xhost_calls)"

# --- rc-2 propagates through _revoke_x_display_if_last_session verbatim ---
clear_sessions
clear_markers
broker_owns_display ":0"
reset_xhost_log
F21_XHOST_FAIL=1
_revoke_x_display_if_last_session "soloc" ":0"; rc=$?
assert_eq "F21 propagate: last-session wrapper surfaces the rc-2 X-revoke failure" \
    "2" "$rc"

# --- NO-OP paths must NOT signal rc 2 (only an actual xhost -SI failure does) ---
# (a) "not last consumer": a live peer on :0 → wrapper returns 0, no revoke.
clear_sessions
ALIVE_PIDS=" 4242 "
write_session_stub_on "f21-peer" ":0"
reset_xhost_log
F21_XHOST_FAIL=1                      # would fail IF it tried — but it must not
_revoke_x_display_if_last_session "stopping" ":0"; rc=$?
assert_eq "F21 no-op: 'not last consumer' is rc 0 (no retain), even with XHOST_FAIL set" \
    "0" "$rc"
assert_eq "F21 no-op: 'not last consumer' issues NO xhost -SI" "0" "$(xhost_calls)"
ALIVE_PIDS=" 4242 "

# (b) "no marker / not broker-owned": no ownership marker → no revoke, rc 0.
clear_sessions
clear_markers                        # broker owns nothing
reset_xhost_log
F21_XHOST_FAIL=1
_revoke_agent_x_display_access ":0"; rc=$?
assert_eq "F21 no-op: 'no ownership marker' is rc 0 (no retain)" "0" "$rc"
assert_eq "F21 no-op: 'no ownership marker' issues NO xhost -SI" "0" "$(xhost_calls)"

# (c) "nothing to revoke": empty persisted granted_display → rc 0, no revoke.
clear_sessions
reset_xhost_log
F21_XHOST_FAIL=1
_revoke_agent_x_display_access ""; rc=$?
assert_eq "F21 no-op: 'nothing to revoke' (empty display) is rc 0" "0" "$rc"
assert_eq "F21 no-op: 'nothing to revoke' issues NO xhost -SI" "0" "$(xhost_calls)"

# --- cmd_stop / sweep RETAIN on rc 2: the sweep is the env-independent full
#     teardown path that reads the same rc; a failed X revoke must RETAIN the
#     state file (marked non-consumer, granted_display preserved) + warn, and a
#     SECOND sweep must RETRY the revoke. `_container_running` mocked DOWN so the
#     bridge / container-slot branches are skipped (a fully crashed session).
# shellcheck disable=SC2317
_container_running() { return 1; }

clear_sessions
clear_markers
broker_owns_display ":0"
ALIVE_PIDS=" "                       # the crashed session is fully dead
write_stale_session "f21-stale" ":0"
: > "$FLOCK_LOG"
reset_xhost_log
F21_XHOST_FAIL=1
f21_stop_log="$(_sweep_if_stale "f21-stale" 2>&1)"; rc=$?
assert_eq "F21 retain: a failed X revoke makes the sweep refuse (rc 1, state kept for retry)" \
    "1" "$rc"
[ -e "$SESSIONS_DIR/f21-stale.json" ] && r=0 || r=1
assert_eq "F21 retain: the state file is RETAINED (not discarded) on an X-revoke failure" \
    "0" "$r"
assert_eq "F21 retain: granted_display preserved in the retained file (for the retry)" \
    ":0" "$(_state_get "$SESSIONS_DIR/f21-stale.json" granted_display)"
assert_eq "F21 retain: retained file marked ufw_retry_only (torn-down → NOT a display consumer)" \
    "true" "$(_state_get "$SESSIONS_DIR/f21-stale.json" ufw_retry_only)"
assert_contains "F21 retain: warns it will retry the X revoke on the next stop/sweep" \
    "retry on next stop/sweep" "$f21_stop_log"
_state_file_is_display_consumer "$SESSIONS_DIR/f21-stale.json" ":0" && r=0 || r=1
assert_eq "F21 retain: the retained file does NOT pin the grant for other sessions" "1" "$r"

# --- SECOND sweep RETRIES the revoke; this time it SUCCEEDS → file removed ---
: > "$FLOCK_LOG"
reset_xhost_log
F21_XHOST_FAIL=0                      # the X authorization is usable now
_sweep_if_stale "f21-stale"; rc=$?
assert_eq "F21 retry: a second sweep RE-issues the xhost -SI revoke (retry path)" \
    "1" "$(xhost_calls)"
assert_contains "F21 retry: the retry targeted the per-uid removal selector" \
    "xhost -SI:localuser:boxa-agent" "$(xhost_last)"
assert_eq "F21 retry: the revoke now SUCCEEDS → swept (rc 0)" "0" "$rc"
[ -e "$SESSIONS_DIR/f21-stale.json" ] && r=0 || r=1
assert_eq "F21 retry: state file removed once the X revoke finally succeeds" "1" "$r"

# --- X revoke SUCCEEDS first time → state file removed as before (no retain) ---
clear_sessions
clear_markers
broker_owns_display ":0"
ALIVE_PIDS=" "
write_stale_session "f21-ok" ":0"
reset_xhost_log
F21_XHOST_FAIL=0
_sweep_if_stale "f21-ok"; rc=$?
assert_eq "F21 success: a clean X revoke sweeps the session (rc 0)" "0" "$rc"
[ -e "$SESSIONS_DIR/f21-ok.json" ] && r=0 || r=1
assert_eq "F21 success: state file removed when the X revoke succeeds (no needless retain)" \
    "1" "$r"

# --- COMBINE-with-ufw: ufw release FAILS too → still retained (either failure
#     keeps the file). The bad-ufw stub forces the real close to refuse (retain);
#     the X revoke also fails here, so BOTH retries need the file. ---
clear_sessions
clear_markers
broker_owns_display ":0"
ALIVE_PIDS=" "
write_stale_session_bad_ufw "f21-both" ":0"
: > "$FLOCK_LOG"
reset_xhost_log
F21_XHOST_FAIL=1
f21_both_log="$(_sweep_if_stale "f21-both" 2>&1)"; rc=$?
assert_eq "F21 combine: ufw-fail OR x-revoke-fail → sweep refuses (rc 1)" "1" "$rc"
[ -e "$SESSIONS_DIR/f21-both.json" ] && r=0 || r=1
assert_eq "F21 combine: state file RETAINED when BOTH ufw and X revoke fail" "0" "$r"
assert_contains "F21 combine: warning names the X-revoke failure alongside the ufw retain" \
    "X grant revoke failed" "$f21_both_log"

unset -f _container_running          # restore the real container probe
ALIVE_PIDS=" 4242 "                  # restore default
F21_XHOST_FAIL=0
# Restore the plain recording xhost mock for any later use.
# shellcheck disable=SC2317
xhost() { printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"; return 0; }

# ----------------------------------------------------------------------------
# F22 — DISPLAY is canonicalized (screen suffix dropped) for the per-display
#       reference count, the ownership-marker filename, and every comparison
#       (#12 review P2). `:0` and `:0.0` are ALIASES for the same X server, so a
#       peer on one alias must count when the other is stopped — otherwise the
#       surviving Chrome's grant is wrongly revoked. The grant is per X SERVER,
#       not per screen.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1
unset -f _container_running 2>/dev/null || true

# --- unit: _canonical_display reduces to [host]:displaynumber, drops .screen ---
assert_eq "F22 canon: ':0' → ':0' (already canonical)"     ":0"     "$(_canonical_display ":0")"
assert_eq "F22 canon: ':0.0' → ':0' (drop screen suffix)"  ":0"     "$(_canonical_display ":0.0")"
assert_eq "F22 canon: ':1.2' → ':1' (drop screen suffix)"  ":1"     "$(_canonical_display ":1.2")"
assert_eq "F22 canon: 'host:0.0' → 'host:0' (keep host)"   "host:0" "$(_canonical_display "host:0.0")"
assert_eq "F22 canon: 'host:0' → 'host:0' (already canon)" "host:0" "$(_canonical_display "host:0")"
# Odd / non-matching values are returned UNCHANGED (be conservative).
assert_eq "F22 canon: odd value (no colon) unchanged"      "weird"  "$(_canonical_display "weird")"
assert_eq "F22 canon: non-numeric display part unchanged"  ":abc"   "$(_canonical_display ":abc")"
assert_eq "F22 canon: empty value unchanged (empty)"       ""       "$(_canonical_display "")"
assert_eq "F22 canon: literal 'null' unchanged"            "null"   "$(_canonical_display "null")"

# --- bare `:N` / `unix:N` are ALWAYS the local server → collapse to ':N' ---
# These are socket-existence INDEPENDENT (local-unix by X convention even if the
# socket is momentarily absent). The screen suffix drops too.
F22_SELF_HOST="$(hostname 2>/dev/null || true)"
assert_eq "F22 canon: ':0' (local-unix) → ':0'"             ":0"  "$(_canonical_display ":0")"
assert_eq "F22 canon: 'unix:0' (local-unix) → ':0'"         ":0"  "$(_canonical_display "unix:0")"
assert_eq "F22 canon: 'unix:0.0' (local-unix+screen) → ':0'" ":0" "$(_canonical_display "unix:0.0")"
# A genuine FOREIGN remote host keeps its host part (only the screen suffix
# drops) regardless of any local socket — it is a DIFFERENT machine's X server.
assert_eq "F22 canon: real-remote 'host:0' → 'host:0'"      "host:0" "$(_canonical_display "host:0")"
assert_eq "F22 canon: real-remote 'host:0.1' → 'host:0'"    "host:0" "$(_canonical_display "host:0.1")"

# --- F1: SERVER-IDENTITY via local-socket existence (#12 review). The xhost ACL
#     is SERVER-WIDE, so `:N`/`unix:N`/`localhost:N`/`<own-host>:N` ALL collapse
#     to the bare `:N` WHEN `/tmp/.X11-unix/X<n>` EXISTS (same server). With NO
#     socket, the TCP forms keep their own key (SSH-forwarded case), while
#     `:N`/`unix:N` stay `:N`. A FOREIGN host never collapses. Use HIGH display
#     numbers with a controllable throwaway socket so we never touch real X0. ---
F1_XDIR="/tmp/.X11-unix"
f1_make_socket() {
    local n="$1"
    mkdir -p "$F1_XDIR" 2>/dev/null || return 1
    rm -f "$F1_XDIR/X${n}" 2>/dev/null || true
    python3 - "$F1_XDIR/X${n}" <<'PY' 2>/dev/null || return 1
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
PY
    [ -S "$F1_XDIR/X${n}" ]
}

# (a) SOCKET PRESENT on X<n> → every local-ish alias collapses to `:N`.
F1_PRESENT=94
if f1_make_socket "$F1_PRESENT"; then
    assert_eq "F1 canon socket-present: ':N' → ':N'" \
        ":${F1_PRESENT}" "$(_canonical_display ":${F1_PRESENT}")"
    assert_eq "F1 canon socket-present: 'unix:N' → ':N'" \
        ":${F1_PRESENT}" "$(_canonical_display "unix:${F1_PRESENT}")"
    assert_eq "F1 canon socket-present: 'localhost:N' → ':N' (SAME server)" \
        ":${F1_PRESENT}" "$(_canonical_display "localhost:${F1_PRESENT}")"
    assert_eq "F1 canon socket-present: 'localhost:N.0' (screen) → ':N'" \
        ":${F1_PRESENT}" "$(_canonical_display "localhost:${F1_PRESENT}.0")"
    if [ -n "$F22_SELF_HOST" ]; then
        assert_eq "F1 canon socket-present: '<own-host>:N' → ':N' (SAME server)" \
            ":${F1_PRESENT}" "$(_canonical_display "${F22_SELF_HOST}:${F1_PRESENT}")"
    fi
    # A FOREIGN host is a DIFFERENT machine's server → never collapses, even with
    # a local X<n> socket present.
    assert_eq "F1 canon socket-present: FOREIGN 'remote:N' → 'remote:N' (NOT ':N')" \
        "definitely-not-localhost-xyz:${F1_PRESENT}" \
        "$(_canonical_display "definitely-not-localhost-xyz:${F1_PRESENT}")"
    # marker + refcount: `:N` and `localhost:N` (same server) share ONE marker.
    assert_eq "F1 marker socket-present: ':N' and 'localhost:N' → SAME marker file" \
        "$(_xhost_ownership_marker_path ":${F1_PRESENT}")" \
        "$(_xhost_ownership_marker_path "localhost:${F1_PRESENT}")"
    # concurrent `:N` + `localhost:N` peers: stopping one does NOT revoke.
    clear_sessions
    broker_owns_display ":${F1_PRESENT}"
    ALIVE_PIDS=" 4242 "
    write_session_stub_on "f1-localhost-peer" "localhost:${F1_PRESENT}"
    assert_eq "F1 refcount socket-present: 'localhost:N' peer counts toward a ':N' revoke" \
        "1" "$(_count_other_live_sessions "f1-stopping" ":${F1_PRESENT}")"
    reset_xhost_log
    _revoke_x_display_if_last_session "f1-stopping" ":${F1_PRESENT}"; rc=$?
    assert_eq "F1 e2e socket-present: 'localhost:N' survivor blocks the ':N' revoke (no xhost -SI)" \
        "0" "$(xhost_calls)"
    assert_eq "F1 e2e socket-present: 'not last consumer' returns rc 0" "0" "$rc"
    rm -f "$SESSIONS_DIR"/xhost-owned-* "$SESSIONS_DIR"/f1-localhost-peer.json 2>/dev/null || true
    # token consistency: socket-backed local-ish forms get a real (non-empty)
    # token; they all key off the SAME X<n> socket. Restore the REAL derivation
    # from the F1-owned snapshot (F24 already unset its own copy).
    eval "_x_session_token() $(declare -f _f1_real_x_session_token | sed '1d')"
    f1_tok_bare="$(_x_session_token ":${F1_PRESENT}")"
    f1_tok_localhost="$(_x_session_token "localhost:${F1_PRESENT}")"
    assert_eq "F1 token socket-present: ':N' token is NOT the unknown sentinel" \
        "0" "$( [ -n "$f1_tok_bare" ] && echo 0 || echo 1)"
    assert_eq "F1 token socket-present: 'localhost:N' token EQUALS ':N' token (same server)" \
        "$f1_tok_bare" "$f1_tok_localhost"
    # SSH-forwarded socket-less localhost:N → UNKNOWN sentinel (does not reach a
    # local server on N). Remove the socket first to model the SSH case.
    rm -f "$F1_XDIR/X${F1_PRESENT}" 2>/dev/null || true
    f1_tok_localhost_nosock="$(_x_session_token "localhost:${F1_PRESENT}")"
    assert_eq "F1 token socket-absent: SSH-forwarded 'localhost:N' → UNKNOWN sentinel" \
        "" "$f1_tok_localhost_nosock"
    # shellcheck disable=SC2317
    _x_session_token() { printf '%s\n' "$MOCK_X_TOKEN"; }
else
    assert_eq "F1 socket-present setup: could not create test UNIX socket" "0" "1"
fi

# (b) SOCKET ABSENT on X<n> → TCP forms keep their own key (SSH-forwarded case);
#     bare `:N`/`unix:N` still collapse to `:N`.
F1_ABSENT=93
rm -f "$F1_XDIR/X${F1_ABSENT}" 2>/dev/null || true
assert_eq "F1 canon socket-absent: ':N' → ':N' (still local-unix)" \
    ":${F1_ABSENT}" "$(_canonical_display ":${F1_ABSENT}")"
assert_eq "F1 canon socket-absent: 'unix:N' → ':N' (still local-unix)" \
    ":${F1_ABSENT}" "$(_canonical_display "unix:${F1_ABSENT}")"
assert_eq "F1 canon socket-absent: SSH-forwarded 'localhost:N.0' → 'localhost:N' (kept)" \
    "localhost:${F1_ABSENT}" "$(_canonical_display "localhost:${F1_ABSENT}.0")"
assert_eq "F1 canon socket-absent: SSH-forwarded 'localhost:N' → 'localhost:N' (kept)" \
    "localhost:${F1_ABSENT}" "$(_canonical_display "localhost:${F1_ABSENT}")"
# A foreign remote host keeps its key regardless of any local socket.
assert_eq "F1 canon socket-absent: FOREIGN 'remote:N' → 'remote:N'" \
    "definitely-not-localhost-xyz:${F1_ABSENT}" \
    "$(_canonical_display "definitely-not-localhost-xyz:${F1_ABSENT}")"
# marker: `:N` and a socket-less `localhost:N` are DIFFERENT transports.
[ "$(_xhost_ownership_marker_path ":${F1_ABSENT}")" != "$(_xhost_ownership_marker_path "localhost:${F1_ABSENT}")" ] && r=0 || r=1
assert_eq "F1 marker socket-absent: ':N' and 'localhost:N' → DIFFERENT marker files" "0" "$r"

# --- shared `_display_resolves_to_local_server` server-identity probe ---
# TRUE for bare `:N`/`unix:N` always; for local-ish TCP forms only with a socket;
# FALSE for SSH-forwarded socket-less localhost:N, foreign hosts, colonless.
_display_resolves_to_local_server ":0"          && r=0 || r=1
assert_eq "F1 resolve: ':0' resolves to the local server"      "0" "$r"
_display_resolves_to_local_server "unix:0"      && r=0 || r=1
assert_eq "F1 resolve: 'unix:0' resolves to the local server"  "0" "$r"
_display_resolves_to_local_server "localhost:${F1_ABSENT}" && r=0 || r=1
assert_eq "F1 resolve: socket-less 'localhost:N' does NOT resolve (SSH case)" "1" "$r"
if f1_make_socket "$F1_PRESENT"; then
    _display_resolves_to_local_server "localhost:${F1_PRESENT}" && r=0 || r=1
    assert_eq "F1 resolve: socket-backed 'localhost:N' DOES resolve to the local server" "0" "$r"
    rm -f "$F1_XDIR/X${F1_PRESENT}" 2>/dev/null || true
fi
_display_resolves_to_local_server "definitely-not-localhost-xyz:0" && r=0 || r=1
assert_eq "F1 resolve: a real remote host does NOT resolve to the local server" "1" "$r"
_display_resolves_to_local_server "garbage"     && r=0 || r=1
assert_eq "F1 resolve: colonless value does NOT resolve to the local server"    "1" "$r"
unset -f f1_make_socket _f1_real_x_session_token

# --- markers: ':0' and ':0.0' resolve to the SAME ownership-marker file ---
assert_eq "F22 marker: ':0' and ':0.0' map to the SAME marker path" \
    "$(_xhost_ownership_marker_path ":0")" "$(_xhost_ownership_marker_path ":0.0")"

# --- markers: ':0' and 'unix:0' (local-socket alias) → the SAME marker file ---
assert_eq "F22 marker: ':0' and 'unix:0' map to the SAME marker path" \
    "$(_xhost_ownership_marker_path ":0")" "$(_xhost_ownership_marker_path "unix:0")"
# NOTE: the ':N'-vs-'localhost:N' marker SAME/DIFFERENT cases now depend on the
# X<n> SOCKET EXISTENCE (server-wide ACL identity, #12 review) and are covered
# deterministically in the F1 block above (socket-present → SAME, socket-absent →
# DIFFERENT), using high display numbers so the result never depends on whether
# this host happens to run a real X0.

# --- concurrent ':0' + 'unix:0' sessions count as peers → stopping ':0' does
#     NOT revoke (the 'unix:0' survivor keeps the shared grant) ---
clear_sessions                       # re-seeds owned markers (incl. canonical :0)
ALIVE_PIDS=" 4242 "
write_session_stub_on "f22-unix-peer" "unix:0"   # peer persisted under the local alias
assert_eq "F22 alias: a 'unix:0' peer counts toward a ':0' revoke decision" \
    "1" "$(_count_other_live_sessions "f22-stopping" ":0")"
_state_file_is_display_consumer "$SESSIONS_DIR/f22-unix-peer.json" ":0" && r=0 || r=1
assert_eq "F22 alias: predicate treats a 'unix:0' file as a consumer on ':0'" "0" "$r"
reset_xhost_log
_revoke_x_display_if_last_session "f22-stopping" ":0"; rc=$?
assert_eq "F22 alias: a 'unix:0' survivor blocks the ':0' revoke (no xhost -SI)" \
    "0" "$(xhost_calls)"
assert_eq "F22 alias: 'not last consumer' returns rc 0 (no retain)" "0" "$rc"

# --- refcount: a peer on ':0.0' counts as a consumer on ':0' (and vice versa) ---
clear_sessions                       # re-seeds owned markers for :0/:1/:7
ALIVE_PIDS=" 4242 "
write_session_stub_on "f22-alias-peer" ":0.0"   # peer persisted under the alias
# Stopping a session whose granted_display is ':0' must SEE the ':0.0' peer.
assert_eq "F22 refcount: a ':0.0' peer counts toward a ':0' revoke decision" \
    "1" "$(_count_other_live_sessions "f22-stopping" ":0")"
# And the predicate matches alias-to-alias directly.
_state_file_is_display_consumer "$SESSIONS_DIR/f22-alias-peer.json" ":0" && r=0 || r=1
assert_eq "F22 refcount: predicate treats ':0.0' file as a consumer on ':0'" "0" "$r"

# --- end-to-end: stopping one alias does NOT revoke while the other alias lives ---
# The surviving peer on ':0.0' must block the ':0' last-session revoke.
clear_sessions
ALIVE_PIDS=" 4242 "
write_session_stub_on "f22-survivor" ":0.0"
reset_xhost_log
_revoke_x_display_if_last_session "f22-stopping" ":0"; rc=$?
assert_eq "F22 alias: a ':0.0' survivor blocks the ':0' revoke (no xhost -SI)" \
    "0" "$(xhost_calls)"
assert_eq "F22 alias: 'not last consumer' returns rc 0 (no retain)" "0" "$rc"

# Conversely: no peer on the canonical display → revoke fires (sanity).
clear_sessions
ALIVE_PIDS=" "
reset_xhost_log
_revoke_x_display_if_last_session "f22-solo" ":0.0"; rc=$?   # persisted alias form
assert_eq "F22 alias: a lone ':0.0' session DOES revoke (canonical ':0' marker owned)" \
    "1" "$(xhost_calls)"
assert_contains "F22 alias: the revoke targeted the per-uid removal selector" \
    "xhost -SI:localuser:boxa-agent" "$(xhost_last)"

# An OLDER non-canonical persisted granted_display ':0.0' still matches a ':0'
# target at COMPARE time (back-compat: canonicalized on read too).
clear_sessions
ALIVE_PIDS=" 4242 "
write_session_stub_on "f22-old-noncanon" ":0.0"
assert_eq "F22 backcompat: old non-canonical ':0.0' file normalizes & matches ':0'" \
    "1" "$(_count_other_live_sessions "f22-other" ":0")"

# --- SSH-forwarded `localhost:N` (NO local X<n> socket) and local-unix `:N` are
#     DIFFERENT transports (#12 review): a socket-less `localhost:10` peer must
#     NOT count toward a `:10` revoke, and a lone `:10` session DOES revoke even
#     with such a peer alive. They are separate transport ends, each with its own
#     grant/marker/refcount. Ensure NO `X10` socket exists so `localhost:10` does
#     NOT collapse to `:10` (it would, server-wide, if a local X10 were up). ---
rm -f "/tmp/.X11-unix/X10" 2>/dev/null || true
clear_sessions
broker_owns_display ":10"            # broker owns the :10 (local-unix) grant
ALIVE_PIDS=" 4242 "
write_session_stub_on "f22-localhost-peer" "localhost:10"   # TCP peer, different key
assert_eq "F22 transport-split: a 'localhost:10' peer does NOT count toward a ':10' revoke" \
    "0" "$(_count_other_live_sessions "f22-stopping" ":10")"
_state_file_is_display_consumer "$SESSIONS_DIR/f22-localhost-peer.json" ":10" && r=0 || r=1
assert_eq "F22 transport-split: predicate treats 'localhost:10' as NOT a consumer on ':10'" "1" "$r"
reset_xhost_log
_revoke_x_display_if_last_session "f22-stopping" ":10"; rc=$?
assert_eq "F22 transport-split: lone ':10' DOES revoke despite a 'localhost:10' peer (separate transports)" \
    "1" "$(xhost_calls)"
rm -f "$SESSIONS_DIR"/xhost-owned-10 2>/dev/null || true

# ----------------------------------------------------------------------------
# F23 — cmd_stop refuses to tear down a LIVE in-progress starting claim (#12
#       review P2), mirroring `_sweep_if_stale`'s starting-claim guard. A
#       `status:"starting"` claim whose `starting_pid` is live + identity-matched
#       is a genuine in-progress start that will rewrite full state — stopping it
#       would revoke the grant / delete the claim out from under the launch. A
#       DEAD/abandoned starting_pid (or any established session) proceeds to
#       normal teardown.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1

# A `status:"starting"` early claim exactly as `_write_starting_claim` writes it:
# null resource PIDs, a granted_display, a starting_pid + its recorded starttime.
write_starting_claim_stub() {
    local container="$1" display="$2" spid="$3" sstart="$4"
    cat > "$SESSIONS_DIR/$container.json" <<EOF
{
  "container": "${container}",
  "status": "starting",
  "starting_pid": ${spid},
  "starting_pid_starttime": ${sstart},
  "chrome_pid": null,
  "bridge_pid_in_container": null,
  "relay_pid_host": null,
  "proxy_pid": null,
  "watchdog_pid": null,
  "cdp_port_host": null,
  "proxy_port_host": null,
  "profile_dir": null,
  "download_dir": null,
  "host_allow_ip": null,
  "ufw_slot_subnet": null,
  "granted_display": "${display}"
}
EOF
}

# Drive the REAL cmd_stop end-to-end against the mocked externals already in
# place for this file (xhost / sudo / docker / host_platform::detect). The
# claim/session stubs carry NULL resource fields (no profile/ufw/netlog/PIDs), so
# every host-touching teardown branch (Chrome kill, ufw release, archive, dir rm)
# no-ops cleanly without further stubbing. We deliberately do NOT redefine the
# real broker teardown helpers (`_release_or_retain_ufw_slot`,
# `_revoke_x_display_if_last_session`) — they are exercised live elsewhere in
# this file, and the PROCEED signal we assert is the SAME observable F16/F21 use:
# whether the last-session X revoke fired `xhost -SI`. On a refused live claim the
# guard returns BEFORE any of that, so xhost is never called.
#
# Two helpers with no live behaviour worth exercising here are stubbed to keep
# the run hermetic: the toast emitter (would touch the pending-events spool) and
# the archive pruner (would scan the archive dir). Both have no callers earlier
# in this file. SC2317: reached only via cmd_stop under test.
# shellcheck disable=SC2317
_emit_pending_event() { return 0; }
# shellcheck disable=SC2317
_prune_archive_for() { return 0; }
# Point the summarizer at a missing path so cmd_stop warns-and-skips that block
# (no real python3 summarizer invocation). SC2034: read by the sourced broker's
# cmd_stop file-existence test, not by this harness directly, so shellcheck
# cannot see the use.
# shellcheck disable=SC2034
AGENT_SUMMARIZE_BIN="/nonexistent/agent-browser-summarize.py"
# Container reported DOWN so the bridge / container-firewall branches skip
# without a real `docker ps`. F16/F21 use the same stub; defined fresh here
# because F21 unset it. SC2317: reached only via cmd_stop.
# shellcheck disable=SC2317
_container_running() { return 1; }

# --- LIVE starting claim (PID alive + starttime matches) → REFUSE ---
clear_sessions
ALIVE_PIDS=" 7777 "
PID_STARTTIME[7777]="500"
write_starting_claim_stub "f23-live" ":0" 7777 500
reset_xhost_log
[ -e "$SESSIONS_DIR/f23-live.json" ] && r=0 || r=1
assert_eq "F23 live: claim present before stop" "0" "$r"
f23_live_log="$(cmd_stop "f23-live" 2>&1)"; rc=$?
assert_eq "F23 live: cmd_stop on a live starting claim returns rc 0 (refused cleanly)" \
    "0" "$rc"
assert_contains "F23 live: warns a start is in progress (clear refuse message)" \
    "a start is in progress for f23-live" "$f23_live_log"
[ -e "$SESSIONS_DIR/f23-live.json" ] && r=0 || r=1
assert_eq "F23 live: the starting claim is NOT torn down (state file retained)" "0" "$r"
assert_eq "F23 live: NO xhost -SI issued under the in-progress start (no revoke)" \
    "0" "$(xhost_calls)"

# --- DEAD/abandoned starting_pid → PROCEED to teardown (reclaim the claim) ---
clear_sessions
ALIVE_PIDS=" "                       # 8888 is NOT alive → abandoned start
write_starting_claim_stub "f23-dead" ":0" 8888 500
reset_xhost_log
f23_dead_log="$(cmd_stop "f23-dead" 2>&1)"; rc=$?
: "$f23_dead_log"
assert_eq "F23 dead: cmd_stop on an abandoned starting claim returns rc 0 (proceeded)" \
    "0" "$rc"
[ -e "$SESSIONS_DIR/f23-dead.json" ] && r=0 || r=1
assert_eq "F23 dead: abandoned claim is torn down (state file removed)" "1" "$r"
assert_eq "F23 dead: teardown reached the last-session X revoke (proceeded past guard)" \
    "1" "$(xhost_calls)"

# --- LIVE PID but starttime MISMATCH (reused PID) → PROCEED (not really ours) ---
clear_sessions
ALIVE_PIDS=" 7777 "
PID_STARTTIME[7777]="999"            # recorded 500 ≠ live 999 → reused PID
write_starting_claim_stub "f23-reused" ":0" 7777 500
reset_xhost_log
cmd_stop "f23-reused" >/dev/null 2>&1; rc=$?
[ -e "$SESSIONS_DIR/f23-reused.json" ] && r=0 || r=1
assert_eq "F23 reused: a live-but-reused starting_pid is abandoned → torn down" "1" "$r"
assert_eq "F23 reused: reused-PID claim proceeds to the X revoke" "1" "$(xhost_calls)"
PID_STARTTIME[7777]="500"            # restore for any later use

# --- established session (no status:"starting") → normal stop, unaffected ---
clear_sessions
ALIVE_PIDS=" "                       # Chrome dead so its kill branch no-ops fast
write_stale_session "f23-established" ":0"   # full session, NO status:starting
reset_xhost_log
cmd_stop "f23-established" >/dev/null 2>&1; rc=$?
assert_eq "F23 established: a non-starting session stops normally (rc 0)" "0" "$rc"
[ -e "$SESSIONS_DIR/f23-established.json" ] && r=0 || r=1
assert_eq "F23 established: established session torn down (state file removed)" "1" "$r"
assert_eq "F23 established: established stop reaches the X revoke (guard not triggered)" \
    "1" "$(xhost_calls)"

# Restore mocked-over helpers so they don't leak into any later block.
unset -f _emit_pending_event _prune_archive_for _container_running
ALIVE_PIDS=" 4242 "

# ----------------------------------------------------------------------------
# F26 — `_xhost_agent_already_authorized` matches the EXACT access-control token
#       (#12 review). The no-arg `xhost` ACL is grepped to decide whether
#       boxa-agent is already authorized (→ skip marker + grant). A SUBSTRING
#       match wrongly treats an entry like `SI:localuser:boxa-agent2` as the
#       real `boxa-agent`, skipping the required `xhost +SI` grant → Chrome
#       startup fails. The check must match the WHOLE `SI:localuser:boxa-agent`
#       token. We drive the helper directly with a controllable ACL body.
# ----------------------------------------------------------------------------
MOCK_PLATFORM="linux"
XHOST_PRESENT=1
# Controllable ACL: `f26_acl` holds what the no-arg `xhost` query prints; with
# args (the +SI/-SI grant) the mock records into the call log as usual.
# SC2317: the mock body is reached only via the helper under test.
f26_acl=""
# shellcheck disable=SC2317
xhost() {
    if [ "$#" -eq 0 ]; then
        printf '%s' "$f26_acl"
        return 0
    fi
    printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"
    return 0
}

# --- a LONGER username (boxa-agent2) must NOT satisfy the exact-token check ---
f26_acl=$'access control enabled, only authorized clients can connect\nSI:localuser:boxa-agent2\n'
_xhost_agent_already_authorized ":0"; rc=$?
assert_eq "F26 exact: 'boxa-agent2' substring does NOT count as authorized (rc 1 → grant proceeds)" \
    "1" "$rc"

# --- the EXACT entry is still detected as authorized (no regression) ---
f26_acl=$'access control enabled, only authorized clients can connect\nSI:localuser:boxa-agent\n'
_xhost_agent_already_authorized ":0"; rc=$?
assert_eq "F26 exact: the real 'SI:localuser:boxa-agent' entry IS authorized (rc 0)" \
    "0" "$rc"

# --- indented / whitespace-padded exact entry still matches (xhost may indent) ---
f26_acl=$'INET:somehost\n    SI:localuser:boxa-agent  \n'
_xhost_agent_already_authorized ":0"; rc=$?
assert_eq "F26 exact: an indented exact entry still authorizes (rc 0)" "0" "$rc"

# --- a prefixed username (foo-boxa-agent) must NOT match either ---
f26_acl=$'SI:localuser:foo-boxa-agent\n'
_xhost_agent_already_authorized ":0"; rc=$?
assert_eq "F26 exact: a PREFIXED 'foo-boxa-agent' is NOT authorized (rc 1)" "1" "$rc"

# --- empty / garbled ACL → NOT authorized (unchanged: rc 1, grant proceeds) ---
f26_acl=""
_xhost_agent_already_authorized ":0"; rc=$?
assert_eq "F26 empty ACL: NOT authorized (rc 1)" "1" "$rc"
f26_acl=$'garbled nonsense line\nanother line with boxa-agent inside prose\n'
_xhost_agent_already_authorized ":0"; rc=$?
assert_eq "F26 garbled ACL: prose mentioning boxa-agent is NOT an exact token (rc 1)" "1" "$rc"

# --- query FAILURE still returns rc 2 (caller takes the safe pre-existing path) ---
# shellcheck disable=SC2317
xhost() { [ "$#" -eq 0 ] && return 1; printf 'xhost %s\n' "$*" >> "$XHOST_CALL_LOG"; return 0; }
_xhost_agent_already_authorized ":0"; rc=$?
assert_eq "F26 query-fail: rc 2 (safe default unchanged)" "2" "$rc"

unset -f xhost

unset -f flock
rm -f "$FLOCK_LOG"

unset -f sudo
unset -f xhost
unset -f command
unset -f host_platform::detect

# ----------------------------------------------------------------------------
echo "----------------------------------------"
if [ "$fail_count" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "$fail_count TEST(S) FAILED"
exit 1
