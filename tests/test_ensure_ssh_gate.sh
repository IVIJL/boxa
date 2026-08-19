#!/usr/bin/env bash
# Behaviour tests for the one-time SSH gate provisioning offer.
# Usage: bash tests/test_ensure_ssh_gate.sh
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_DIR/scripts/ensure-ssh-gate.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
export HOME="$TMP_ROOT/home"
export BOXA_SSH_CONF="$HOME/.config/boxa/ssh.conf"
export BOXA_SSH_GATE_MARKER="$HOME/.config/boxa/ssh-gate-seen"
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/ssh-add" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -l ] && exit 0
exit 1
EOF
chmod +x "$TMP_ROOT/bin/ssh-add"
export PATH="$TMP_ROOT/bin:$PATH"

check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'ok   %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' \
            "$label" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

reset_state() {
    rm -f "$BOXA_SSH_CONF" "$BOXA_SSH_GATE_MARKER"
}

reset_state
check "missing state probes missing" "missing" "$("$HOOK" probe)"
noninteractive_output="$("$HOOK" offer --non-interactive)"
check "non-interactive prints follow-up" "yes" \
    "$([[ "$noninteractive_output" == *'boxa ssh on --global'* ]] && printf yes || printf no)"
check "non-interactive leaves config absent" "absent" \
    "$([ -e "$BOXA_SSH_CONF" ] && printf present || printf absent)"
check "non-interactive leaves marker absent" "absent" \
    "$([ -e "$BOXA_SSH_GATE_MARKER" ] && printf present || printf absent)"

printf '\n' | "$HOOK" offer --interactive >/dev/null
check "No writes marker" "present" \
    "$([ -f "$BOXA_SSH_GATE_MARKER" ] && printf present || printf absent)"
check "No leaves config absent" "absent" \
    "$([ -e "$BOXA_SSH_CONF" ] && printf present || printf absent)"
check "marker probes declined" "declined" "$("$HOOK" probe)"
repeat_output="$(printf 'y\n' | "$HOOK" offer --interactive)"
check "marker suppresses repeat prompt" "" "$repeat_output"
check "suppressed Yes does not create config" "absent" \
    "$([ -e "$BOXA_SSH_CONF" ] && printf present || printf absent)"

reset_state
mkdir -p "${BOXA_SSH_CONF%/*}"
printf 'agent = off\n' > "$BOXA_SSH_CONF"
off_before="$(cksum "$BOXA_SSH_CONF")"
off_output="$(printf 'y\n' | "$HOOK" offer --interactive)"
check "global off suppresses prompt" "" "$off_output"
check "global off remains unchanged" "$off_before" "$(cksum "$BOXA_SSH_CONF")"
check "global off probes declined" "declined" "$("$HOOK" probe)"

printf 'agent = on\n' > "$BOXA_SSH_CONF"
on_output="$(printf 'n\n' | "$HOOK" offer --interactive)"
check "global on suppresses prompt" "" "$on_output"
check "global on does not create marker" "absent" \
    "$([ -e "$BOXA_SSH_GATE_MARKER" ] && printf present || printf absent)"
check "global on probes ok" "ok" "$("$HOOK" probe)"

reset_state
mkdir -p "${BOXA_SSH_CONF%/*}"
printf '[/work/app]\nagent = on\n' > "$BOXA_SSH_CONF"
project_output="$(printf 'n\n' | "$HOOK" offer --interactive)"
check "project-only choice does not suppress prompt" "yes" \
    "$([[ "$project_output" == *'Zapnout forwarding? [y/N]'* ]] && printf yes || printf no)"
check "project-only decline writes marker" "present" \
    "$([ -f "$BOXA_SSH_GATE_MARKER" ] && printf present || printf absent)"

reset_state
yes_output="$(printf 'y\n' | "$HOOK" offer --interactive)"
check "Yes writes global on" "agent = on" "$(cat "$BOXA_SSH_CONF")"
check "Yes does not need marker" "absent" \
    "$([ -e "$BOXA_SSH_GATE_MARKER" ] && printf present || printf absent)"
check "Yes reports enabled" "yes" \
    "$([[ "$yes_output" == *'SSH agent forwarding enabled globally.'* ]] && printf yes || printf no)"

# A fixture-local ssh library records that enable chains the existing helper.
STUB_ROOT="$TMP_ROOT/stub"
mkdir -p "$STUB_ROOT/scripts" "$STUB_ROOT/lib"
cp "$HOOK" "$STUB_ROOT/scripts/ensure-ssh-gate.sh"
: > "$STUB_ROOT/lib/resources.sh"
: > "$STUB_ROOT/lib/picker.sh"
cat > "$STUB_ROOT/lib/ssh.sh" <<'EOF'
_boxa::resolve_ssh_gate() { _BOXA_SSH_SOURCE=default; }
_boxa::write_ssh_conf() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$BOXA_TEST_WRITE_LOG"; }
_boxa::ssh_add_keys_if_agent_unready() { printf 'called\n' > "$BOXA_TEST_PICKER_LOG"; }
EOF
export BOXA_TEST_WRITE_LOG="$TMP_ROOT/write.log"
export BOXA_TEST_PICKER_LOG="$TMP_ROOT/picker.log"
"$STUB_ROOT/scripts/ensure-ssh-gate.sh" enable >/dev/null
check "enable uses global config writer" "global||on" "$(cat "$BOXA_TEST_WRITE_LOG")"
check "enable chains key picker helper" "called" "$(cat "$BOXA_TEST_PICKER_LOG")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
