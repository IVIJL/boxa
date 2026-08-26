#!/usr/bin/env bash
# Behaviour tests for the Agent identity provisioning state machine.
# Usage: bash tests/test_ensure_agent_identity.sh
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_DIR/scripts/ensure-agent-identity.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
export HOME="$TMP_ROOT/home"
export BOXA_AGENT_IDENTITY_DIR="$HOME/.config/boxa/agent-identity"
export BOXA_AGENT_IDENTITY_MARKER="$HOME/.config/boxa/agent-identity-seen"
export BOXA_SSH_CONF="$HOME/.config/boxa/ssh.conf"
export BOXA_FORGE_CONF="$HOME/.config/boxa/forge.conf"
export BOXA_FORGE_DIR="$HOME/.config/boxa/forge"

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
    rm -rf "$HOME"
    mkdir -p "$HOME"
}

reset_state
check "empty state probes missing" "missing" "$("$HOOK" probe)"
noninteractive_output="$("$HOOK" offer --non-interactive)"
check "non-interactive offer prints follow-up" "yes" \
    "$([[ "$noninteractive_output" == *'boxa doctor --fix agent-identity'* ]] \
        && printf yes || printf no)"
check "non-interactive offer leaves state absent" "absent" \
    "$([ -e "$HOME/.config/boxa" ] && printf present || printf absent)"

enable_output="$("$HOOK" enable --non-interactive)"
check "non-interactive repair prints follow-up" "yes" \
    "$([[ "$enable_output" == *'boxa doctor --fix agent-identity'* ]] \
        && printf yes || printf no)"
check "non-interactive repair leaves state absent" "absent" \
    "$([ -e "$HOME/.config/boxa" ] && printf present || printf absent)"

mkdir -p "$BOXA_AGENT_IDENTITY_DIR"
ssh-keygen -q -t ed25519 -N '' -C test-agent \
    -f "$BOXA_AGENT_IDENTITY_DIR/id_ed25519"
check "key without usage remains missing" "missing" "$("$HOOK" probe)"

mkdir -p "${BOXA_FORGE_CONF%/*}"
printf 'forge = on\n' > "$BOXA_FORGE_CONF"
check "key plus global forge usage probes ok" "ok" "$("$HOOK" probe)"

printf 'forge = off\n' > "$BOXA_FORGE_CONF"
printf '[/work/app]\ngate = on\n' > "$BOXA_SSH_CONF"
check "key plus Project gate on probes ok" "ok" "$("$HOOK" probe)"

printf '[/work/app]\ngate = off\n' > "$BOXA_SSH_CONF"
check "gate off does not count" "missing" "$("$HOOK" probe)"

printf 'dismissed\n' > "$BOXA_AGENT_IDENTITY_MARKER"
check "seen marker probes declined" "declined" "$("$HOOK" probe)"
repeat_output="$("$HOOK" offer --non-interactive)"
check "seen marker suppresses repeat offer" "" "$repeat_output"

printf 'gate = on\n' > "$BOXA_SSH_CONF"
check "complete state wins over old marker" "ok" "$("$HOOK" probe)"

mkdir -p "$BOXA_FORGE_DIR"
printf '%s\n' 'version=1' "created_at=$(date +%s)" \
    'username=token-user' 'host=' 'token=github-token' \
    > "$BOXA_FORGE_DIR/github"
summary_bin="$TMP_ROOT/bin"
mkdir -p "$summary_bin"
cat > "$summary_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'Hi ssh-user! You have successfully authenticated.\n' >&2
exit 1
EOF
chmod +x "$summary_bin/ssh"
summary_output="$(PATH="$summary_bin:$PATH" "$HOOK" summary)"
check "identity summary combines SSH and token identities" \
    "GitHub Agent: SSH as ssh-user; token as token-user" "$summary_output"
cat > "$summary_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh: connect to host github.com port 22: Network is unreachable\n' >&2
exit 255
EOF
offline_summary_rc=0
offline_summary_output="$(PATH="$summary_bin:$PATH" "$HOOK" summary 2>&1)" \
    || offline_summary_rc=$?
check "offline identity summary remains successful" 0 "$offline_summary_rc"
check "offline identity summary silently keeps the stored token identity" \
    "GitHub Agent: token as token-user" "$offline_summary_output"
check "doctor requests the additive Agent identity summary" "yes" \
    "$(grep -q 'ensure-agent-identity.sh.*summary' "$REPO_DIR/docker-run.sh" \
        && printf yes || printf no)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
