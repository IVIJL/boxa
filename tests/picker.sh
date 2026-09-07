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

wizard_projects_out="$(
    BOXA_PICKER_FZF=0 BOXA_PICKER_TEST_CHOICE=a,1 \
        bash -c '
            source "$1"
            _run_py() {
                printf "%s\n" $'"'"'Source Project\t/source'"'"' \
                    $'"'"'Other Project\t/other'"'"'
            }
            _wizard_project_picker server /source
        ' "$SCRIPT_DIR/../scripts/_harness.sh" \
            "$SCRIPT_DIR/../scripts/mcp-cli.sh" 2>/dev/null
)"
assert_eq "import Project picker: fallback selects destination + activation Project" \
    $'/source\n/other' "$wizard_projects_out"

wizard_projects_fallback="$(
    BOXA_PICKER_FZF=0 BOXA_PICKER_TEST_CHOICE=1,2 \
        bash -c '
            source "$1"
            _run_py() {
                printf "%s\n" $'"'"'api\t/work/a/api'"'"' \
                    $'"'"'api\t/work/b/api'"'"' \
                    "Ambiguous Project name '"'"'api'"'"'; paths shown for disambiguation"
            }
            _wizard_project_picker server ""
        ' "$SCRIPT_DIR/../scripts/_harness.sh" \
            "$SCRIPT_DIR/../scripts/mcp-cli.sh" 2>&1
)"
case "$wizard_projects_fallback" in
    *"Ambiguous Project name 'api'"*"/work/a/api"*"/work/b/api"*)
        printf 'PASS  import Project picker: fallback shows both paths and diagnostic\n'
        ;;
    *)
        printf 'FAIL  import Project picker: fallback shows both paths and diagnostic\n      output: %q\n' \
            "$wizard_projects_fallback"
        fail_count=$((fail_count + 1))
        ;;
esac

wizard_projects_fzf="$(
    BOXA_PICKER_FZF=1 bash -c '
        source "$1"
        _run_py() {
            printf "%s\n" $'"'"'api\t/work/a/api'"'"' \
                $'"'"'api\t/work/b/api'"'"' \
                "Ambiguous Project name '"'"'api'"'"'; paths shown for disambiguation"
        }
        fzf() {
            printf "FZF_ARGS:%s\n" "$*" >&2
            local rows
            rows="$(cat)"
            printf "FZF_ROWS:%s\n" "$rows" >&2
            printf "\n%s\n" "${rows%%$'"'"'\n'"'"'*}"
        }
        _wizard_project_picker server "" one
    ' "$SCRIPT_DIR/../scripts/_harness.sh" \
        "$SCRIPT_DIR/../scripts/mcp-cli.sh" 2>&1
)"
case "$wizard_projects_fzf" in
    *"FZF_ARGS:"*"Ambiguous Project name 'api'"*"FZF_ROWS:"*"/work/a/api"*"/work/b/api"*)
        printf 'PASS  import Project picker: fzf shows both paths and diagnostic header\n'
        ;;
    *)
        printf 'FAIL  import Project picker: fzf shows both paths and diagnostic header\n      output: %q\n' \
            "$wizard_projects_fzf"
        fail_count=$((fail_count + 1))
        ;;
esac

# shellcheck disable=SC2016 # $1 is intentionally expanded by the child shell.
assert_fail "import Project picker: q cancels" \
    env BOXA_PICKER_FZF=0 BOXA_PICKER_TEST_CHOICE=q \
        bash -c '
            source "$1"
            _run_py() { printf "%s\n" $'"'"'Source Project\t/source'"'"'; }
            _wizard_project_picker server /source
        ' "$SCRIPT_DIR/../scripts/_harness.sh" \
            "$SCRIPT_DIR/../scripts/mcp-cli.sh"

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
    *"(comma-separated: numbers and a/q)"*'P: * All, beta')
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
    if [[ "$*" = *--version* ]]; then
        return 0
    fi
    printf 'FZF_ARGS:%s\n' "$*" >&2
    # Real fzf --print-query emits the typed filter (empty here) first.
    printf '\nalpha\nbeta\n'
}
fzf_stderr_file="$(mktemp "${TMPDIR:-/tmp}/boxa-picker-fzf.XXXXXX")"
fzf_stdout="$(_picker::fzf many "P:" "Choose items" 0 alpha beta \
    2>"$fzf_stderr_file")"
fzf_stderr="$(<"$fzf_stderr_file")"
rm -f "$fzf_stderr_file"
unset -f fzf
if [[ "$fzf_stdout" = $'alpha\nbeta' \
    && "$fzf_stderr" = *"FZF_ARGS:"*"--height=~40%"*"--min-height=10"*"--layout=reverse"* \
    && "$fzf_stderr" = *"--multi"* \
    && "$fzf_stderr" = *"--print-query"* \
    && "$fzf_stderr" = *"Choose items"*"Tab selects multiple"* \
    && "$fzf_stderr" = *'P: alpha, beta' ]]; then
    printf 'PASS  fzf many: renders inline and echoes the multi-selection\n'
else
    printf 'FAIL  fzf many: renders inline and echoes the multi-selection\n      stdout: %q\n      stderr: %q\n' \
        "$fzf_stdout" "$fzf_stderr"
    fail_count=$((fail_count + 1))
fi

# shellcheck disable=SC2317
fzf() {
    if [[ "$*" = *--version* ]]; then
        return 2
    fi
    printf 'FZF_ARGS:%s\n' "$*" >&2
    printf '\nalpha\n'
}
legacy_fzf_stderr="$(_picker::fzf one "P:" "" 0 alpha beta 2>&1 1>/dev/null)"
unset -f fzf
if [[ "$legacy_fzf_stderr" = *"FZF_ARGS:"*"--height=40%"* \
    && "$legacy_fzf_stderr" != *"--height=~40%"* \
    && "$legacy_fzf_stderr" = *"--layout=reverse"* \
    && "$legacy_fzf_stderr" = *'P: alpha' ]]; then
    printf 'PASS  fzf legacy: falls back to plain inline height\n'
else
    printf 'FAIL  fzf legacy: falls back to plain inline height\n      stderr: %q\n' \
        "$legacy_fzf_stderr"
    fail_count=$((fail_count + 1))
fi

# --- accept-query: text typed into the picker instead of a choice -----------
# Regression: a user pasted a GitLab token into the fzf token-source menu; fzf
# matched nothing, Enter exited 1 and the paste was silently lost.

# shellcheck disable=SC2317
fzf() {
    if [[ "$*" = *--version* ]]; then
        return 0
    fi
    # No item matched: fzf prints only the query line and exits 1.
    printf 'glpat-typed-into-the-menu-1234\n'
    return 1
}
aq_stderr_file="$(mktemp "${TMPDIR:-/tmp}/boxa-picker-aq.XXXXXX")"
aq_stdout="$(_picker::fzf one "Token source:" "" 1 alpha beta 2>"$aq_stderr_file")"
aq_status=$?
aq_stderr="$(<"$aq_stderr_file")"
rm -f "$aq_stderr_file"
if [ "$aq_status" -eq 0 ] && [ "$aq_stdout" = 'glpat-typed-into-the-menu-1234' ] \
    && [[ "$aq_stderr" != *glpat-* ]] \
    && [[ "$aq_stderr" = *'Token source: (typed value accepted)'* ]]; then
    printf 'PASS  fzf accept-query: no-match query is returned and not echoed\n'
else
    printf 'FAIL  fzf accept-query: no-match query is returned and not echoed\n      status: %s stdout: %q stderr: %q\n' \
        "$aq_status" "$aq_stdout" "$aq_stderr"
    fail_count=$((fail_count + 1))
fi
assert_fail "fzf accept-query off: no-match query still cancels" \
    _picker::fzf one "P:" "" 0 alpha beta

# Esc (exit 130) cancels even with accept-query on.
# shellcheck disable=SC2317
fzf() {
    if [[ "$*" = *--version* ]]; then
        return 0
    fi
    printf 'glpat-typed-then-escaped-1234\n'
    return 130
}
assert_fail "fzf accept-query: Esc cancels despite typed query" \
    _picker::fzf one "P:" "" 1 alpha beta
unset -f fzf

# Fallback: the same guarantee without fzf.
export BOXA_PICKER_FZF=0
aq_fallback() {
    local choice="$1"; shift
    printf 'alpha\nbeta\n' | BOXA_PICKER_TEST_CHOICE="$choice" \
        picker::one --prompt 'P:' "$@"
}
assert_eq "fallback accept-query: free text returned" \
    "glpat-typed-into-the-menu-1234" \
    "$(aq_fallback 'glpat-typed-into-the-menu-1234' --accept-query 2>/dev/null)"
assert_eq "fallback accept-query: numbers still select" "beta" \
    "$(aq_fallback 2 --accept-query 2>/dev/null)"
assert_fail "fallback accept-query: q still cancels" aq_fallback q --accept-query
assert_fail "fallback accept-query off: free text is invalid" aq_fallback glpat-x
assert_fail "is_free_text: letter"     _picker::is_free_text one a
assert_fail "is_free_text: number"     _picker::is_free_text one 12
assert_fail "is_free_text: q"          _picker::is_free_text one q
assert_fail "is_free_text: empty"      _picker::is_free_text one ""
assert_fail "is_free_text many: list"  _picker::is_free_text many "a, 2,3"
if _picker::is_free_text one "glpat-abc" && _picker::is_free_text many "glpat-abc"; then
    printf 'PASS  is_free_text: token-like text\n'
else
    printf 'FAIL  is_free_text: token-like text\n'
    fail_count=$((fail_count + 1))
fi

unset BOXA_PICKER_FZF

# --- summary -----------------------------------------------------------------

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count" >&2
    exit 1
fi
printf '\nAll tests passed.\n'
