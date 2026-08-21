#!/bin/bash
# Plain-bash assertions for lib/picker.sh. Runs in any bash, no harness needed.
#
# Usage: bash tests/picker.sh
#
# Tests target the pure _picker::select function so no fzf/tty/stdin dance is
# required. The I/O wrappers (picker::one / picker::many) are thin shims around
# _picker::select.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/picker.sh disable=SC1091
source "$SCRIPT_DIR/../lib/picker.sh"

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

assert_fail() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf 'FAIL  %s (expected failure but succeeded)\n' "$label"
        fail_count=$((fail_count + 1))
    else
        printf 'PASS  %s\n' "$label"
    fi
}

# --- single select -----------------------------------------------------------

assert_eq "one: pick first"  "alpha"  "$(_picker::select one 0 1 alpha beta gamma)"
assert_eq "one: pick second" "beta"   "$(_picker::select one 0 2 alpha beta gamma)"
assert_eq "one: pick last"   "gamma"  "$(_picker::select one 0 3 alpha beta gamma)"

assert_fail "one: q cancels"           _picker::select one 0 "q" alpha beta
assert_fail "one: empty cancels"       _picker::select one 0 "" alpha beta
assert_fail "one: out of range high"   _picker::select one 0 "5" alpha beta
assert_fail "one: out of range zero"   _picker::select one 0 "0" alpha beta
assert_fail "one: non-numeric"         _picker::select one 0 "abc" alpha beta
assert_fail "one: a without first-opt" _picker::select one 0 "a" alpha beta

# --- single select with first-option ----------------------------------------

# With one first-option, items[0] is the sentinel; index 1 means first real item.
assert_eq "one+first: pick first real" \
    "alpha" "$(_picker::select one 1 "1" "* All" alpha beta)"
assert_eq "one+first: pick second real" \
    "beta"  "$(_picker::select one 1 "2" "* All" alpha beta)"
assert_eq "one+first: 'a' returns sentinel" \
    "* All" "$(_picker::select one 1 "a" "* All" alpha beta)"

assert_fail "one+first: out of range" _picker::select one 1 "3" "* All" alpha beta

# --- single select with two first-options -----------------------------------

# Two sentinels: a→first sentinel, b→second sentinel, 1→first real item.
assert_eq "one+2first: 'a' returns first sentinel" \
    "* Allow all firewall" "$(_picker::select one 2 "a" "* Allow all firewall" "* Allow all browser" alpha beta)"
assert_eq "one+2first: 'b' returns second sentinel" \
    "* Allow all browser"  "$(_picker::select one 2 "b" "* Allow all firewall" "* Allow all browser" alpha beta)"
assert_eq "one+2first: pick first real (index 1)" \
    "alpha" "$(_picker::select one 2 "1" "* Allow all firewall" "* Allow all browser" alpha beta)"
assert_fail "one+2first: 'c' invalid (only 2 sentinels)" \
    _picker::select one 2 "c" "* Allow all firewall" "* Allow all browser" alpha beta

# --- multi select ------------------------------------------------------------

assert_eq "many: single index"     "alpha" "$(_picker::select many 0 "1" alpha beta gamma)"

multi_out=$(_picker::select many 0 "1,3" alpha beta gamma)
assert_eq "many: comma 1,3" "alpha
gamma" "$multi_out"

multi_spaces=$(_picker::select many 0 "1, 3" alpha beta gamma)
assert_eq "many: comma w/ spaces" "alpha
gamma" "$multi_spaces"

multi_all=$(_picker::select many 0 "1,2,3" alpha beta gamma)
assert_eq "many: all three" "alpha
beta
gamma" "$multi_all"

assert_fail "many: invalid index in list" _picker::select many 0 "1,99" alpha beta
assert_fail "many: empty cancels"         _picker::select many 0 "" alpha beta
assert_fail "many: q cancels"             _picker::select many 0 "q" alpha beta

# --- multi select with first-option -----------------------------------------

assert_eq "many+first: pick reals" \
    "alpha
beta" "$(_picker::select many 1 "1,2" "* All" alpha beta gamma)"
assert_eq "many+first: 'a' returns sentinel" \
    "* All" "$(_picker::select many 1 "a" "* All" alpha beta)"
assert_eq "many+first: mixed letter and number preserves order" \
    "* All
beta" "$(_picker::select many 1 "a,2" "* All" alpha beta gamma)"

duplicate_error="$(_picker::select many 1 "a,a" "* All" alpha beta 2>&1 >/dev/null)"
duplicate_rc=$?
if [ "$duplicate_rc" -ne 0 ] && [ "$duplicate_error" = "Duplicate choice: a" ]; then
    printf 'PASS  many+first: duplicate rejected clearly\n'
else
    printf 'FAIL  many+first: duplicate rejected clearly\n      rc: %s\n      stderr: %q\n' \
        "$duplicate_rc" "$duplicate_error"
    fail_count=$((fail_count + 1))
fi

# --- whitespace trim ---------------------------------------------------------

assert_eq "trim leading space"  "alpha" "$(_picker::select one 0 "  1" alpha beta)"
assert_eq "trim trailing space" "alpha" "$(_picker::select one 0 "1  " alpha beta)"

# --- end-to-end fallback (regression: stdin items + tty-stub choice) --------
#
# Verifies _picker::run consumes piped items via cat AND reads the choice
# from /dev/tty (stubbed via BOXA_PICKER_TEST_CHOICE), instead of trying
# to read from the same exhausted pipe.

export BOXA_PICKER_FZF=0

run_e2e() {
    # $1 = test choice value, rest = picker args; items passed via stdin.
    # Subshell + export so the variable reaches the right side of the pipe.
    local choice="$1"; shift
    (
        export BOXA_PICKER_TEST_CHOICE="$choice"
        printf '%s\n' alpha beta gamma | "$@" 2>/dev/null
    )
}

assert_eq "e2e one: pick second"   "beta"  "$(run_e2e 2 picker::one --prompt "P:")"
assert_eq "e2e one+first: 'a'"     "* All" \
    "$(run_e2e a picker::one --prompt "P:" --first-option "* All")"
assert_eq "e2e many: comma 1,3"    "alpha
gamma" "$(run_e2e 1,3 picker::many --prompt "P:")"
assert_eq "e2e many+first: mixed a,2" "* All
beta" "$(run_e2e a,2 picker::many --prompt "P:" --first-option "* All")"

sectioned_out="$(
    printf '%s\n' \
        $'New                 alpha\timp-new' \
        $'Changed (reimport)  beta\timp-changed' \
        | BOXA_PICKER_TEST_CHOICE="1,2" picker::many --prompt "Import" \
            --header "New and Changed (reimport); 2 entries in sync" 2>/dev/null
)"
assert_eq "e2e many: one sectioned New + Changed pass" \
    $'New                 alpha\timp-new\nChanged (reimport)  beta\timp-changed' \
    "$sectioned_out"

update_picker_out="$(
    printf '%s\n' \
        $'entry-stdio\tlocal tools\tstdio' \
        $'entry-http\tremote tools\thttp' \
        | BOXA_PICKER_TEST_CHOICE=2 picker::one \
            --prompt "Select MCP catalog entry: " 2>/dev/null
)"
assert_eq "mcp update picker: preserves selected id/name/type row" \
    $'entry-http\tremote tools\thttp' "$update_picker_out"

secret_entry_out="$(
    printf '%s\n' $'entry-one\tone missing' $'entry-two\ttwo missing' \
        | BOXA_PICKER_TEST_CHOICE=2 picker::one \
            --prompt "Select MCP catalog entry with a missing secret: " 2>/dev/null
)"
assert_eq "mcp secret picker: selects only supplied missing-entry rows" \
    $'entry-two\ttwo missing' "$secret_entry_out"
assert_eq "mcp secret picker: selects one of multiple missing keys" \
    "X-Api-Key" \
    "$(printf '%s\n' Authorization X-Api-Key \
        | BOXA_PICKER_TEST_CHOICE=2 picker::one \
            --prompt "Select missing secret key: " 2>/dev/null)"

assert_fail "e2e one: empty cancels" \
    bash -c 'export BOXA_PICKER_FZF=0 BOXA_PICKER_TEST_CHOICE=""; \
             source "'"$SCRIPT_DIR"'/../lib/picker.sh"; \
             printf "alpha\nbeta\n" | picker::one --prompt "P:"'
assert_fail "e2e one: q cancels" \
    bash -c 'export BOXA_PICKER_FZF=0 BOXA_PICKER_TEST_CHOICE=q; \
             source "'"$SCRIPT_DIR"'/../lib/picker.sh"; \
             printf "alpha\nbeta\n" | picker::one --prompt "P:"'
assert_fail "e2e: empty stdin returns 1" \
    bash -c 'export BOXA_PICKER_FZF=0 BOXA_PICKER_TEST_CHOICE=1; \
             source "'"$SCRIPT_DIR"'/../lib/picker.sh"; \
             : | picker::one --prompt "P:"'

# --header: stdout is unchanged (just the selection), header lands on stderr
# in the fallback path. fzf path's header is exercised by fzf itself; we only
# need to verify it isn't passed through to the selection output.
header_stdout="$(run_e2e 1 picker::one --prompt "P:" --header "no session for X")"
assert_eq "e2e one+header: stdout unchanged" "alpha" "$header_stdout"
header_stderr="$(BOXA_PICKER_FZF=0 BOXA_PICKER_TEST_CHOICE=1 \
    bash -c 'source "'"$SCRIPT_DIR"'/../lib/picker.sh"; \
             printf "%s\n" alpha beta \
                 | picker::one --prompt "P:" --header "no session for X" 2>&1 1>/dev/null')"
case "$header_stderr" in
    *"no session for X"*) printf 'PASS  e2e one+header: header on stderr\n' ;;
    *) printf 'FAIL  e2e one+header: header on stderr\n      stderr: %q\n' "$header_stderr"
       fail_count=$((fail_count + 1)) ;;
esac

many_fallback_stderr="$(BOXA_PICKER_FZF=0 BOXA_PICKER_TEST_CHOICE=a,2 \
    bash -c 'source "'"$SCRIPT_DIR"'/../lib/picker.sh"; \
             printf "%s\n" alpha beta \
                 | picker::many --prompt "P:" --header "Choose items" \
                     --first-option "* All" 2>&1 1>/dev/null')"
case "$many_fallback_stderr" in
    *Tab*)
        printf 'FAIL  e2e many fallback: hint omits Tab\n      stderr: %q\n' \
            "$many_fallback_stderr"
        fail_count=$((fail_count + 1))
        ;;
    *"(comma-separated: numbers and a/q)"*)
        printf 'PASS  e2e many fallback: hint omits Tab and explains selection\n'
        ;;
    *)
        printf 'FAIL  e2e many fallback: hint explains selection\n      stderr: %q\n' \
            "$many_fallback_stderr"
        fail_count=$((fail_count + 1))
        ;;
esac

# Called indirectly by _picker::fzf after command lookup.
# shellcheck disable=SC2317
fzf() {
    printf '%s\n' "$*" >&2
    local selected
    IFS= read -r selected
    printf '%s\n' "$selected"
}
fzf_stderr="$(_picker::fzf many "P:" "Choose items" alpha beta 2>&1 1>/dev/null)"
unset -f fzf
case "$fzf_stderr" in
    *"Choose items"*"Tab selects multiple"*)
        printf 'PASS  fzf many: header explains Tab selection\n'
        ;;
    *)
        printf 'FAIL  fzf many: header explains Tab selection\n      stderr: %q\n' \
            "$fzf_stderr"
        fail_count=$((fail_count + 1))
        ;;
esac

unset BOXA_PICKER_FZF

# --- summary -----------------------------------------------------------------

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count" >&2
    exit 1
fi
printf '\nAll tests passed.\n'
