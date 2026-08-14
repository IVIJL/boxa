#!/usr/bin/env bash
set -euo pipefail

# Migrations of the seeded Claude config (scripts/setup-claude.sh): retirement
# of hooks boxa used to seed but no longer ships. The agent-awake hook
# migrations live in tests/keep-awake.sh with the rest of that feature.

BOXA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

fail_count=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      expected: %q\n      actual:   %q\n' \
            "$label" "$expected" "$actual"
        fail_count=$((fail_count + 1))
    fi
}

file_exists() {
    [ -e "$1" ] && printf true || printf false
}

claude_defaults="$BOXA_DIR/config/claude"
claude_target="$TMPROOT/claude-target"
mkdir -p "$claude_target/hooks"

# Managed defaults ship neither the notify hooks nor the interaction hook
# (notifications are user-brought, ADR 0025).
assert_eq "managed defaults ship no notify hook wiring" 0 \
    "$(jq '[.hooks[][]?.hooks[]? | select(.command | test("(success_notify|question_notify|check_error)"))] | length' \
        "$claude_defaults/settings.json")"
assert_eq "managed defaults ship no notify hook files" 0 \
    "$(find "$claude_defaults/hooks" \
        \( -name 'success_notify.sh' -o -name 'question_notify.sh' -o -name 'check_error.sh' \) | wc -l)"
assert_eq "managed defaults ship no interaction hook" 0 \
    "$(jq '[.hooks[][]?.hooks[]? | select(.command | endswith("/interaction_notify.sh"))] | length' \
        "$claude_defaults/settings.json")"

# The retired Interaction hook is unwired and deleted only while the file is
# still byte-for-byte the copy boxa shipped; a customized copy is the user's
# and keeps both its file and its wiring.
run_interaction_retirement() {
    BOXA_CLAUDE_DEFAULTS="$claude_defaults" BOXA_CLAUDE_TARGET="$claude_target" \
        bash -c 'source "$1"; migrate_remove_interaction_notify' \
        _ "$BOXA_DIR/scripts/setup-claude.sh"
}
retired_hook="$claude_target/hooks/interaction_notify.sh"
cp "$BOXA_DIR/tests/fixtures/claude-hooks/interaction_notify_shipped.sh" "$retired_hook"
cat > "$claude_target/settings.json" <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "/home/node/.claude/hooks/interaction_notify.sh"}]},
      {"hooks": [{"type": "command", "command": "~/.claude/hooks/agent-awake.sh busy"}]}
    ]
  }
}
EOF
run_interaction_retirement
assert_eq "interaction retirement deletes the shipped copy" false \
    "$(file_exists "$retired_hook")"
assert_eq "interaction retirement unwires the settings entry" 0 \
    "$(jq '[.hooks[][]?.hooks[]? | select(.command | endswith("/interaction_notify.sh"))] | length' \
        "$claude_target/settings.json")"
assert_eq "interaction retirement keeps the prompt heartbeat" 1 \
    "$(jq '[.hooks.UserPromptSubmit[]?.hooks[]? | select(.command == "~/.claude/hooks/agent-awake.sh busy")] | length' \
        "$claude_target/settings.json")"
run_interaction_retirement
assert_eq "interaction retirement is idempotent" 1 \
    "$(jq '.hooks.UserPromptSubmit | length' "$claude_target/settings.json")"
cp "$BOXA_DIR/tests/fixtures/claude-hooks/interaction_notify_shipped.sh" "$retired_hook"
printf '# my custom tweak\n' >> "$retired_hook"
jq '.hooks.UserPromptSubmit += [{"hooks": [{"type": "command", "command": "~/.claude/hooks/interaction_notify.sh"}]}]' \
    "$claude_target/settings.json" > "$claude_target/settings.json.tmp" \
    && mv "$claude_target/settings.json.tmp" "$claude_target/settings.json"
run_interaction_retirement
assert_eq "customized interaction hook keeps its file" true \
    "$(file_exists "$retired_hook")"
assert_eq "customized interaction hook keeps its wiring" 1 \
    "$(jq '[.hooks[][]?.hooks[]? | select(.command | endswith("/interaction_notify.sh"))] | length' \
        "$claude_target/settings.json")"
rm -f "$retired_hook"
run_interaction_retirement
assert_eq "dangling interaction wiring is removed once the file is gone" 0 \
    "$(jq '[.hooks[][]?.hooks[]? | select(.command | endswith("/interaction_notify.sh"))] | length' \
        "$claude_target/settings.json")"

# The retired notify hooks are unwired and deleted only while the file is
# still byte-for-byte a copy boxa shipped; a customized copy — or a shipped
# copy the user wired up themselves — is the user's and stays untouched.
run_notify_retirement() {
    BOXA_CLAUDE_DEFAULTS="$claude_defaults" BOXA_CLAUDE_TARGET="$claude_target" \
        bash -c 'source "$1"; migrate_retire_notify_hooks' \
        _ "$BOXA_DIR/scripts/setup-claude.sh"
}
cp "$BOXA_DIR/tests/fixtures/claude-hooks/success_notify_ntfy_shipped.sh" \
    "$claude_target/hooks/success_notify.sh"
cp "$BOXA_DIR/tests/fixtures/claude-hooks/question_notify_ntfy_shipped.sh" \
    "$claude_target/hooks/question_notify.sh"
printf '# my custom tweak\n' >> "$claude_target/hooks/question_notify.sh"
cp "$BOXA_DIR/tests/fixtures/claude-hooks/check_error_ntfy_shipped.sh" \
    "$claude_target/hooks/check_error.sh"
cat > "$claude_target/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "/home/node/.claude/hooks/success_notify.sh"}]},
      {"hooks": [{"type": "command", "command": "~/.claude/hooks/agent-awake.sh idle"}]}
    ],
    "Notification": [
      {"hooks": [{"type": "command", "command": "/home/node/.claude/hooks/question_notify.sh"}]}
    ]
  }
}
EOF
run_notify_retirement
assert_eq "notify retirement deletes the shipped success copy" false \
    "$(file_exists "$claude_target/hooks/success_notify.sh")"
assert_eq "notify retirement unwires the success entry, keeps agent-awake" \
    '["~/.claude/hooks/agent-awake.sh idle"]' \
    "$(jq -c '[.hooks.Stop[]?.hooks[]?.command]' "$claude_target/settings.json")"
assert_eq "customized question hook keeps its file" true \
    "$(file_exists "$claude_target/hooks/question_notify.sh")"
assert_eq "customized question hook keeps its wiring" \
    '["/home/node/.claude/hooks/question_notify.sh"]' \
    "$(jq -c '[.hooks.Notification[]?.hooks[]?.command]' "$claude_target/settings.json")"
assert_eq "unwired check_error shipped copy is deleted" false \
    "$(file_exists "$claude_target/hooks/check_error.sh")"
cp "$BOXA_DIR/tests/fixtures/claude-hooks/check_error_ntfy_shipped.sh" \
    "$claude_target/hooks/check_error.sh"
jq '.hooks.PostToolUse = [{"hooks": [{"type": "command", "command": "/home/node/.claude/hooks/check_error.sh"}]}]' \
    "$claude_target/settings.json" > "$claude_target/settings.json.tmp" \
    && mv "$claude_target/settings.json.tmp" "$claude_target/settings.json"
run_notify_retirement
assert_eq "user-wired check_error shipped copy is kept" true \
    "$(file_exists "$claude_target/hooks/check_error.sh")"
# An entry the user extended (matcher/timeout/extra command) is no longer
# the seeded shape — wiring and file both stay.
cp "$BOXA_DIR/tests/fixtures/claude-hooks/success_notify_ntfy_shipped.sh" \
    "$claude_target/hooks/success_notify.sh"
jq '.hooks.Stop += [{"matcher": "custom", "hooks": [{"type": "command", "command": "/home/node/.claude/hooks/success_notify.sh"}]}]' \
    "$claude_target/settings.json" > "$claude_target/settings.json.tmp" \
    && mv "$claude_target/settings.json.tmp" "$claude_target/settings.json"
run_notify_retirement
assert_eq "customized wiring of a shipped copy survives retirement" 1 \
    "$(jq '[.hooks.Stop[]? | select(.matcher? == "custom")] | length' \
        "$claude_target/settings.json")"
assert_eq "its shipped file survives too" true \
    "$(file_exists "$claude_target/hooks/success_notify.sh")"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count"
    exit 1
fi

printf '\nAll claude-migrations tests passed.\n'
