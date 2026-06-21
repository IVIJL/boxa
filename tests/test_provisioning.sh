#!/usr/bin/env bash
# Smoke test for lib/provisioning.sh — the host-provisioning registry and
# dispatch (ADR 0017, issue 01). Framework-free: stubs the ensure-*.sh
# scripts under a throwaway BOXA_DIR so the test exercises dispatch logic
# without touching real host state. Run: bash tests/test_provisioning.sh
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'ok   %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$label" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

# --- Fixture -----------------------------------------------------------------
# A stub BOXA_DIR whose ensure-*.sh scripts honour the --quiet-if-noop
# contract: the first one prints once (simulating a repair) then stays silent;
# the rest are immediate no-ops (already provisioned).
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export BOXA_DIR="$tmp"
mkdir -p "$tmp/scripts"

cat > "$tmp/scripts/ensure-allow-for-host-state.sh" <<'EOF'
#!/usr/bin/env bash
[ -f "$BOXA_DIR/_done" ] || { echo "provisioned"; touch "$BOXA_DIR/_done"; }
exit 0
EOF
chmod +x "$tmp/scripts/ensure-allow-for-host-state.sh"
for s in mkcert agent-browser-helpers agent-browser-host-state \
         upstream-agent-browser-skill agent-allowlist-example boxa-skill \
         completions; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/scripts/ensure-$s.sh"
    chmod +x "$tmp/scripts/ensure-$s.sh"
done

# shellcheck source=../lib/provisioning.sh
source "$REPO_DIR/lib/provisioning.sh"

# --- Field accessor ----------------------------------------------------------
entry="allow-for-host-state|scripts/ensure-allow-for-host-state.sh|A"
check "field id"       "allow-for-host-state" "$(boxa::provisioning_field "$entry" id)"
check "field script"   "scripts/ensure-allow-for-host-state.sh" "$(boxa::provisioning_field "$entry" script)"
check "field category" "A" "$(boxa::provisioning_field "$entry" category)"

# --- Registry: 8 category-A + 3 category-B + 4 category-C steps ---------------
check "registry size" "15" "${#BOXA_PROVISIONING_STEPS[@]}"

# --- First run repairs the one stub that has work, rest already OK ------------
boxa::run_provisioning repair-a >/dev/null
check "run1 repaired" "allow-for-host-state" "${BOXA_PROVISIONING_REPAIRED[*]}"
check "run1 ok count" "7" "${#BOXA_PROVISIONING_OK[@]}"
check "run1 failed"   ""  "${BOXA_PROVISIONING_FAILED[*]}"

# --- Second run is idempotent: everything already provisioned ----------------
boxa::run_provisioning repair-a >/dev/null
check "run2 repaired (none)" "" "${BOXA_PROVISIONING_REPAIRED[*]}"
check "run2 ok count"        "8" "${#BOXA_PROVISIONING_OK[@]}"

# --- Id filter restricts the run to named steps ------------------------------
boxa::run_provisioning repair-a boxa-skill >/dev/null
check "filter ok" "boxa-skill" "${BOXA_PROVISIONING_OK[*]}"

# --- Unknown mode is rejected ------------------------------------------------
boxa::run_provisioning bogus >/dev/null 2>&1
check "unknown mode rc" "2" "$?"

# --- Missing/non-executable script is reported as skipped --------------------
rm "$tmp/scripts/ensure-boxa-skill.sh"
boxa::run_provisioning repair-a >/dev/null
check "missing script skipped" "boxa-skill" "${BOXA_PROVISIONING_SKIPPED[*]}"

# A category-A step whose script exits non-zero is recorded as FAILED (this is
# how ensure-completions.sh signals "could not install (no writable fpath / no
# sudo)" so doctor reports it as unhealthy instead of silently OK).
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/scripts/ensure-completions.sh"
chmod +x "$tmp/scripts/ensure-completions.sh"
boxa::run_provisioning repair-a completions >/dev/null
check "failing step -> FAILED" "completions" "${BOXA_PROVISIONING_FAILED[*]}"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/scripts/ensure-completions.sh"  # restore

# --- Category-B electives (issue 04) -----------------------------------------
# has_step accessor
if boxa::provisioning_has_step https; then check "has_step https" "0" "0"; else check "has_step https" "0" "1"; fi
if boxa::provisioning_has_step nope;  then check "has_step unknown" "1" "0"; else check "has_step unknown" "1" "1"; fi

# Unknown id is rejected with rc 3 (used by `boxa doctor --fix <bad>`).
boxa::run_provisioning fix bogus-id >/dev/null 2>&1
check "fix unknown id rc" "3" "$?"

# Probe: HTTPS state via a stub lib/https.sh under the throwaway BOXA_DIR.
# TEST_HTTPS_STATE is a plain shell var; the probe's command substitution runs
# in a subshell that inherits it, so it must be assigned on its own line (not
# as a `VAR=val cmd` prefix, which would not reach the substitution).
mkdir -p "$tmp/lib"
cat > "$tmp/lib/https.sh" <<'EOF'
#!/usr/bin/env bash
boxa::https_active() { [ "${TEST_HTTPS_STATE:-}" = "active" ]; }
boxa::https_optout() { [ "${TEST_HTTPS_STATE:-}" = "optout" ]; }
EOF
TEST_HTTPS_STATE=active
check "probe https ok"       "ok"       "$(boxa::provisioning_probe https)"
TEST_HTTPS_STATE=optout
check "probe https declined" "declined" "$(boxa::provisioning_probe https)"
TEST_HTTPS_STATE=""
check "probe https missing"  "missing"  "$(boxa::provisioning_probe https)"

# Probe: claude-token via a controlled HOME (no token / creds / env -> missing).
export HOME="$tmp/home"; mkdir -p "$HOME/.config/boxa"
unset CLAUDE_CODE_OAUTH_TOKEN
check "probe token missing" "missing" "$(boxa::provisioning_probe claude-token)"
printf 'x\n' > "$HOME/.config/boxa/claude-token"
check "probe token ok"      "ok"      "$(boxa::provisioning_probe claude-token)"
rm "$HOME/.config/boxa/claude-token"

# Stub the MCP Python core so the mcp-onboarding probe is DETERMINISTIC,
# independent of any ambient `mcp` package in site-packages: shouldOffer=true
# (missing) until a marker file appears, then profileExists=true (ok). The
# probe runs `python3 -m mcp.cli onboarding-status` with PYTHONPATH prefixed by
# BOXA_DIR/scripts, so this stub shadows any real install; BOXA_DIR is
# exported, so the subprocess sees the marker path.
mkdir -p "$tmp/scripts/mcp"
: > "$tmp/scripts/mcp/__init__.py"
cat > "$tmp/scripts/mcp/cli.py" <<'PYEOF'
import os, sys
if len(sys.argv) > 1 and sys.argv[1] == "onboarding-status":
    d = os.environ.get("BOXA_DIR", "")
    if os.path.exists(os.path.join(d, "_mcp_done")):
        print('{ "shouldOffer": false, "profileExists": true, "seen": false }')
    elif os.path.exists(os.path.join(d, "_mcp_declined")):
        print('{ "shouldOffer": false, "profileExists": false, "seen": true }')
    else:
        print('{ "shouldOffer": true, "profileExists": false, "seen": false }')
PYEOF

# report-electives: no mutation, classifies all three as missing in this fixture
# (https stub unset; no token; mcp stub returns shouldOffer -> missing).
# shellcheck disable=SC2034  # read by the sourced https.sh stub via subshell
TEST_HTTPS_STATE=""
boxa::run_provisioning report-electives >/dev/null
check "report missing count" "3" "${#BOXA_PROVISIONING_MISSING[@]}"

# fix re-probes after the action (P2): an action that runs but does NOT resolve
# the elective is reported as still-missing, never faked as repaired.
cat > "$tmp/scripts/ensure-mcp-onboarding.sh" <<'EOF'
#!/usr/bin/env bash
touch "$BOXA_DIR/_mcp_ran"   # runs, but does not change onboarding state
EOF
chmod +x "$tmp/scripts/ensure-mcp-onboarding.sh"
rm -f "$tmp/_mcp_done"
boxa::run_provisioning fix mcp-onboarding >/dev/null
case " ${BOXA_PROVISIONING_MISSING[*]} " in
    *" mcp-onboarding "*) check "fix unresolved -> missing" "0" "0" ;;
    *)                    check "fix unresolved -> missing" "0" "1" ;;
esac
check "fix unresolved not repaired" "" "${BOXA_PROVISIONING_REPAIRED[*]}"
if [ -f "$tmp/_mcp_ran" ]; then _r=0; else _r=1; fi
check "fix ran elective" "0" "$_r"

# An action that DOES resolve the elective (stub flips the probe) -> repaired.
cat > "$tmp/scripts/ensure-mcp-onboarding.sh" <<'EOF'
#!/usr/bin/env bash
touch "$BOXA_DIR/_mcp_done"   # flips the stub probe to provisioned
EOF
chmod +x "$tmp/scripts/ensure-mcp-onboarding.sh"
boxa::run_provisioning fix mcp-onboarding >/dev/null
check "fix resolved -> repaired" "mcp-onboarding" "${BOXA_PROVISIONING_REPAIRED[*]}"

# An action whose post-state is declined (user dismissed) -> DECLINED, never
# faked as repaired (Codex round 4).
rm -f "$tmp/_mcp_done"
cat > "$tmp/scripts/ensure-mcp-onboarding.sh" <<'EOF'
#!/usr/bin/env bash
touch "$BOXA_DIR/_mcp_declined"
EOF
chmod +x "$tmp/scripts/ensure-mcp-onboarding.sh"
boxa::run_provisioning fix mcp-onboarding >/dev/null
case " ${BOXA_PROVISIONING_DECLINED[*]} " in
    *" mcp-onboarding "*) check "fix declined -> declined" "0" "0" ;;
    *)                    check "fix declined -> declined" "0" "1" ;;
esac
check "fix declined not repaired" "" "${BOXA_PROVISIONING_REPAIRED[*]}"
rm -f "$tmp/_mcp_declined"

# --- Category-C prerequisites (issue 05) -------------------------------------
# boxa-symlink is fully controllable via BOXA_SYMLINK_PATH (exported so the
# sourced check function reads it; export also keeps shellcheck happy). It must
# be a symlink resolving to THIS checkout's docker-run.sh and be executable.
printf '#!/usr/bin/env bash\n' > "$tmp/docker-run.sh"; chmod +x "$tmp/docker-run.sh"
export BOXA_SYMLINK_PATH="$tmp/no-such-boxa"
check "prereq symlink missing" "missing" "$(boxa::prereq_state boxa-symlink)"
ln -s "$tmp/docker-run.sh" "$tmp/boxa-link"
export BOXA_SYMLINK_PATH="$tmp/boxa-link"
check "prereq symlink ok" "ok" "$(boxa::prereq_state boxa-symlink)"
# a plain file (not a symlink to docker-run.sh) is rejected
: > "$tmp/plain-boxa"
export BOXA_SYMLINK_PATH="$tmp/plain-boxa"
check "prereq symlink rejects non-link" "missing" "$(boxa::prereq_state boxa-symlink)"
# remedy is a non-empty instruction
if [ -n "$(boxa::prereq_remedy docker)" ]; then _r=0; else _r=1; fi
check "prereq remedy nonempty" "0" "$_r"
# default mode diagnoses a forced-missing prerequisite WITHOUT mutating it
export BOXA_SYMLINK_PATH="$tmp/no-such-boxa"
boxa::run_provisioning default >/dev/null 2>&1
case " ${BOXA_PROVISIONING_PREREQ_MISSING[*]} " in
    *" boxa-symlink "*) check "default diagnoses prereq" "0" "0" ;;
    *)                    check "default diagnoses prereq" "0" "1" ;;
esac
check "prereq not mutated" "ok" "$([ ! -e "$tmp/no-such-boxa" ] && echo ok || echo created)"
# `--fix` never repairs a category-C prerequisite, even when named explicitly
boxa::run_provisioning fix boxa-symlink >/dev/null 2>&1
case " ${BOXA_PROVISIONING_PREREQ_MISSING[*]} " in
    *" boxa-symlink "*) check "fix leaves prereq diagnose-only" "0" "0" ;;
    *)                    check "fix leaves prereq diagnose-only" "0" "1" ;;
esac

# --- Summary -----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
