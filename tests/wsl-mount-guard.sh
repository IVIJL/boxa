#!/usr/bin/env bash
# Framework-free tests for scripts/ensure-wsl-mount-guard.sh.
# Run: bash tests/wsl-mount-guard.sh
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/ensure-wsl-mount-guard.sh"
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

contains() {
    local haystack="$1" needle="$2"
    case "$haystack" in
        *"$needle"*) printf yes ;;
        *)           printf no ;;
    esac
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

new_case() {
    case_dir="$tmp/$1"
    conf="$case_dir/wsl.conf"
    mount_c="$case_dir/mnt/c"
    rm -rf "$case_dir"
    mkdir -p "$mount_c"
    chmod 777 "$mount_c"
    export BOXA_WSL_CONF="$conf"
    export BOXA_WSL_DRVFS_DIRS="$mount_c"
    export BOXA_WSL_FORCE_PLATFORM=wsl2
}

run_guard() {
    out="$("$SCRIPT" "$@" 2>&1)"
    rc=$?
}

# 1. non-WSL platform -> exit 0, no conf created
new_case non-wsl
export BOXA_WSL_FORCE_PLATFORM=other
run_guard --quiet-if-noop
check "non-WSL rc" "0" "$rc"
check "non-WSL no conf" "missing" "$([ -e "$conf" ] && printf exists || printf missing)"

# 2. no wsl.conf + open mount -> conf created with [automount] + umask=077
new_case create
run_guard --quiet-if-noop
check "create rc" "0" "$rc"
check "create content" $'[automount]\noptions = "umask=077"' "$(cat "$conf")"
check "create notice" "yes" "$(contains "$out" "Hardened")"

# 3. unrelated content, no [automount] -> section appended, original preserved
new_case append
printf '# keep me\n[network]\ngenerateResolvConf = false\n' > "$conf"
run_guard --quiet-if-noop
check "append rc" "0" "$rc"
check "append preserves prefix" "yes" "$(contains "$(cat "$conf")" $'# keep me\n[network]\ngenerateResolvConf = false\n')"
check "append automount" "yes" "$(contains "$(cat "$conf")" $'[automount]\noptions = "umask=077"')"

# 4. [automount] present without options -> options line added in-section
new_case add-options
printf '[automount]\nroot = /mnt\n[network]\ngenerateHosts = false\n' > "$conf"
run_guard --quiet-if-noop
check "add options rc" "0" "$rc"
check "add options in section" "yes" "$(contains "$(cat "$conf")" $'[automount]\nroot = /mnt\noptions = "umask=077"\n[network]')"

# 5. options = "metadata" -> merged to "metadata,umask=077"
new_case merge
printf '[automount]\noptions = "metadata"\n' > "$conf"
run_guard --quiet-if-noop
check "merge rc" "0" "$rc"
check "merge content" $'[automount]\noptions = "metadata,umask=077"' "$(cat "$conf")"

# 5b. inline comment after quoted options -> merged, comment preserved
new_case merge-comment
printf '[automount]\noptions = "metadata" # keep drives quiet\n' > "$conf"
run_guard --quiet-if-noop
check "merge comment rc" "0" "$rc"
check "merge comment content" $'[automount]\noptions = "metadata,umask=077" # keep drives quiet' "$(cat "$conf")"

# 5c. inline comment after unquoted options -> merged, comment preserved
new_case merge-comment-unquoted
printf '[automount]\noptions = metadata # keep\n' > "$conf"
run_guard --quiet-if-noop
check "merge unquoted comment rc" "0" "$rc"
check "merge unquoted comment content" $'[automount]\noptions = "metadata,umask=077" # keep' "$(cat "$conf")"

# 5d. hardened options with inline comment -> detection unaffected, restart pending
new_case comment-detection
printf '[automount]\noptions = "umask=077" # hardened by boxa\n' > "$conf"
before="$(cat "$conf")"
run_guard --quiet-if-noop
check "comment detection rc" "0" "$rc"
check "comment detection unchanged" "$before" "$(cat "$conf")"
check "comment detection restart warn" "yes" "$(contains "$out" "wsl.exe --shutdown")"

# 6. options with umask=022 -> file unchanged, warning, exit 1 (unresolved
#    hole must surface as a provisioning failure, not count as configured)
new_case different-umask
printf '[automount]\noptions = "metadata,umask=022"\n' > "$conf"
before="$(cat "$conf")"
run_guard --quiet-if-noop
check "different umask rc" "1" "$rc"
check "different umask unchanged" "$before" "$(cat "$conf")"
check "different umask warns" "yes" "$(contains "$out" "Manual fix required")"

# 7. options with fmask present -> file unchanged, warning, exit 1
new_case fmask
printf '[automount]\noptions = metadata,fmask=0111\n' > "$conf"
before="$(cat "$conf")"
run_guard --quiet-if-noop
check "fmask rc" "1" "$rc"
check "fmask unchanged" "$before" "$(cat "$conf")"
check "fmask warns" "yes" "$(contains "$out" "Manual fix required")"

# 8. already umask=077 but mount still open -> unchanged, restart warning
new_case restart-pending
printf '[automount]\noptions = "metadata,umask=077"\n' > "$conf"
before="$(cat "$conf")"
run_guard --quiet-if-noop
check "restart pending rc" "0" "$rc"
check "restart pending unchanged" "$before" "$(cat "$conf")"
check "restart pending warns" "yes" "$(contains "$out" "wsl.exe --shutdown")"

# 8b. umask=077 undermined by permissive dmask -> manual-fix failure (the
#     explicit dmask overrides umask for dirs on drvfs, hole stays open)
new_case undermined-umask
printf '[automount]\noptions = "umask=077,dmask=000"\n' > "$conf"
before="$(cat "$conf")"
run_guard --quiet-if-noop
check "undermined umask rc" "1" "$rc"
check "undermined umask unchanged" "$before" "$(cat "$conf")"
check "undermined umask warns" "yes" "$(contains "$out" "Manual fix required")"

# 8c. umask=077 with group/other-closed fmask -> hardened, restart pending
new_case restrictive-fmask
printf '[automount]\noptions = "umask=077,fmask=177"\n' > "$conf"
before="$(cat "$conf")"
run_guard --quiet-if-noop
check "restrictive fmask rc" "0" "$rc"
check "restrictive fmask unchanged" "$before" "$(cat "$conf")"
check "restrictive fmask restart warn" "yes" "$(contains "$out" "wsl.exe --shutdown")"

# 9. mount already closed -> silent no-op with --quiet-if-noop
new_case closed
chmod 700 "$mount_c"
run_guard --quiet-if-noop
check "closed rc" "0" "$rc"
check "closed silent" "" "$out"
check "closed no conf" "missing" "$([ -e "$conf" ] && printf exists || printf missing)"

# 10. idempotency: run case-2 result again -> no rewrite, only restart warning
new_case idempotent
run_guard --quiet-if-noop
before="$(cat "$conf")"
touch -d '2001-01-01 00:00:00' "$conf"
mtime_before="$(stat -c '%Y' "$conf")"
run_guard --quiet-if-noop
mtime_after="$(stat -c '%Y' "$conf")"
check "idempotent rc" "0" "$rc"
check "idempotent content unchanged" "$before" "$(cat "$conf")"
check "idempotent mtime unchanged" "$mtime_before" "$mtime_after"
check "idempotent warning" "yes" "$(contains "$out" "wsl.exe --shutdown")"

# 11. section-awareness: [network] options must not count as automount options
new_case section-aware
printf '[network]\noptions = "metadata"\n' > "$conf"
run_guard --quiet-if-noop
check "section aware rc" "0" "$rc"
check "section aware network preserved" "yes" "$(contains "$(cat "$conf")" $'[network]\noptions = "metadata"')"

# 12. stream routing: the provisioning runner classifies repaired-vs-OK from
#     stdout, so the repair notice must land on stdout and the pure warning
#     (restart pending) must keep stdout empty.
new_case stream-routing
guard_stdout="$("$SCRIPT" --quiet-if-noop 2>/dev/null)"
check "repair notice on stdout" "yes" "$(contains "$guard_stdout" "Hardened")"
guard_stdout="$("$SCRIPT" --quiet-if-noop 2>/dev/null)"
guard_stderr="$("$SCRIPT" --quiet-if-noop 2>&1 >/dev/null)"
check "restart-pending stdout empty" "" "$guard_stdout"
check "restart-pending warning on stderr" "yes" "$(contains "$guard_stderr" "wsl.exe --shutdown")"
check "section aware automount appended" "yes" "$(contains "$(cat "$conf")" $'[automount]\noptions = "umask=077"')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
