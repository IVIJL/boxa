#!/bin/bash
# Plain-bash assertions for lib/resources.sh. Runs without Docker.
# Usage: bash tests/resources.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/resources.sh disable=SC1091
source "$SCRIPT_DIR/../lib/resources.sh"

_TMPROOT="$(mktemp -d)"
export BOXA_RESOURCES_CONF="$_TMPROOT/resources.conf"
export BOXA_MEMINFO_FILE="$_TMPROOT/meminfo"
export BOXA_RUNNING_MEMORY_LIMITS_FILE="$_TMPROOT/running-limits"
export BOXA_SYSCTL_CMD="$_TMPROOT/sysctl"
export BOXA_DOCKER_INFO_CMD="$_TMPROOT/docker"
trap 'rm -rf "$_TMPROOT"' EXIT

printf '%s\n' \
    '#!/bin/sh' \
    "[ \"\$1\" = \"-n\" ] && [ \"\$2\" = \"hw.memsize\" ] || exit 2" \
    "[ -n \"\${BOXA_TEST_SYSCTL_MEMSIZE:-}\" ] || exit 1" \
    "printf \"%s\\n\" \"\$BOXA_TEST_SYSCTL_MEMSIZE\"" \
    > "$BOXA_SYSCTL_CMD"
chmod +x "$BOXA_SYSCTL_CMD"

printf '%s\n' \
    '#!/bin/sh' \
    "[ \"\$1\" = \"info\" ] && [ \"\$2\" = \"--format\" ] && [ \"\$3\" = \"{{.MemTotal}}\" ] || exit 2" \
    "[ -n \"\${BOXA_TEST_DOCKER_MEMTOTAL:-}\" ] || exit 1" \
    "printf \"%s\\n\" \"\$BOXA_TEST_DOCKER_MEMTOTAL\"" \
    > "$BOXA_DOCKER_INFO_CMD"
chmod +x "$BOXA_DOCKER_INFO_CMD"

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

assert_ok() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      expected success\n' "$label"
        fail_count=$((fail_count + 1))
    fi
}

assert_fail() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'FAIL  %s\n      expected failure\n' "$label"
        fail_count=$((fail_count + 1))
    else
        printf 'PASS  %s\n' "$label"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      missing: %q\n      actual:  %q\n' \
            "$label" "$needle" "$haystack"
        fail_count=$((fail_count + 1))
    fi
}

assert_file_eq() {
    local label="$1" expected="$2" actual="$3"
    if cmp -s "$expected" "$actual"; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      file bytes differ\n' "$label"
        diff -u "$expected" "$actual" || true
        fail_count=$((fail_count + 1))
    fi
}

seed_conf() {
    _boxa::reset_resources_cache
    : > "$BOXA_RESOURCES_CONF"
    local line
    for line in "$@"; do
        printf '%s\n' "$line" >> "$BOXA_RESOURCES_CONF"
    done
}

set_host_gib() {
    local gib="$1"
    printf 'MemTotal:       %s kB\n' "$((gib * 1024 * 1024))" > "$BOXA_MEMINFO_FILE"
}

resolve_ok() {
    _boxa::resolve_resources "$@"
}

set_host_gib 10
: > "$BOXA_RUNNING_MEMORY_LIMITS_FILE"

# --- Size parser ------------------------------------------------------------

assert_eq "parse 512m"  "536870912"  "$(_boxa::parse_size 512m)"
assert_eq "parse 5g"    "5368709120" "$(_boxa::parse_size 5g)"
assert_eq "parse 6GiB"  "6442450944" "$(_boxa::parse_size 6GiB)"
assert_eq "parse 6MB"   "6291456"    "$(_boxa::parse_size 6MB)"
assert_ok "accept exact 6 MiB floor" _boxa::parse_size 6m
assert_fail "reject below 6 MiB" _boxa::parse_size 5m
assert_fail "reject zero" _boxa::parse_size 0g
assert_fail "reject negative" _boxa::parse_size -1g
assert_fail "reject garbage" _boxa::parse_size nonsense
assert_fail "reject missing unit" _boxa::parse_size 512

# --- Strict config parser ---------------------------------------------------

marker="$_TMPROOT/should-not-exist"
seed_conf \
    "memory = 7g" \
    "memory_swap=8g" \
    "unknown_key=99g" \
    "evil=\$(touch $marker)" \
    "[/work/other]" \
    "memory=6g" \
    "memory_swap = 6GiB"
resolve_ok /work/other
assert_eq "project memory parsed" "6442450944" "$_BOXA_MEMORY_BYTES"
assert_eq "project memory_swap parsed" "6442450944" "$_BOXA_MEMORY_SWAP_BYTES"
assert_eq "project source" "project config" "$_BOXA_MEMORY_SOURCE"
assert_eq "config is never sourced" "absent" "$([ -e "$marker" ] && printf present || printf absent)"

resolve_ok /work/global
assert_eq "global memory parsed" "7516192768" "$_BOXA_MEMORY_BYTES"
assert_eq "global memory_swap parsed" "8589934592" "$_BOXA_MEMORY_SWAP_BYTES"
assert_eq "global source" "global config" "$_BOXA_MEMORY_SOURCE"

# --- Precedence and derived default ----------------------------------------

resolve_ok /work/other 9g 10g
assert_eq "CLI memory wins" "9663676416" "$_BOXA_MEMORY_BYTES"
assert_eq "CLI memory_swap wins" "10737418240" "$_BOXA_MEMORY_SWAP_BYTES"
assert_eq "CLI source" "CLI flag" "$_BOXA_MEMORY_SOURCE"

seed_conf "memory=7g" "[/work/project]" "memory=6g"
resolve_ok /work/project
assert_eq "section beats global" "6442450944" "$_BOXA_MEMORY_BYTES"
assert_eq "missing memory_swap defaults to memory" "6442450944" "$_BOXA_MEMORY_SWAP_BYTES"

seed_conf
resolve_ok /work/default
assert_eq "derived default is 65 percent" "6979321856" "$_BOXA_MEMORY_BYTES"
assert_eq "derived source" "derived" "$_BOXA_MEMORY_SOURCE"
assert_eq "derived swap defaults to memory" "6979321856" "$_BOXA_MEMORY_SWAP_BYTES"
assert_eq "derived startup display" "6.5g" "$(_boxa::format_size "$_BOXA_MEMORY_BYTES")"

# --- Portable host RAM detection and graceful degradation ------------------

rm -f "$BOXA_MEMINFO_FILE"
export BOXA_TEST_SYSCTL_MEMSIZE=17179869184
export BOXA_TEST_DOCKER_MEMTOTAL=8589934592
assert_eq "docker info wins over sysctl when meminfo is absent" \
    "8589934592" "$(_boxa::host_memtotal_bytes)"

unset BOXA_TEST_DOCKER_MEMTOTAL
assert_eq "sysctl fallback reads hw.memsize bytes" \
    "17179869184" "$(_boxa::host_memtotal_bytes)"

unset BOXA_TEST_SYSCTL_MEMSIZE
seed_conf
explicit_stderr="$_TMPROOT/explicit.stderr"
if _boxa::resolve_resources /work/explicit 7g 2> "$explicit_stderr"; then
    printf 'PASS  explicit limit works without host MemTotal\n'
else
    printf 'FAIL  explicit limit works without host MemTotal\n      expected success\n'
    fail_count=$((fail_count + 1))
fi
assert_eq "explicit limit keeps resolved bytes without host MemTotal" \
    "7516192768" "$_BOXA_MEMORY_BYTES"
assert_eq "RAM-dependent warnings have no host total" "" "$_BOXA_HOST_MEMTOTAL_BYTES"
assert_eq "missing optional host MemTotal stays silent" "" "$(< "$explicit_stderr")"

derived_stderr="$_TMPROOT/derived.stderr"
if _boxa::resolve_resources /work/default 2> "$derived_stderr"; then
    printf 'FAIL  derived default fails without any host RAM source\n      expected failure\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  derived default fails without any host RAM source\n'
fi
assert_contains "derived failure explains missing host RAM" \
    "Unable to determine host RAM" "$(< "$derived_stderr")"

set_host_gib 10

# --- Validation -------------------------------------------------------------

seed_conf "memory=7g" "memory_swap=6g"
assert_fail "reject memory_swap below memory" _boxa::resolve_resources /work/project

seed_conf "memory=5m"
assert_fail "reject configured value below floor" _boxa::resolve_resources /work/project

seed_conf "memory=garbage"
assert_fail "reject invalid configured value" _boxa::resolve_resources /work/project

seed_conf "memory="
assert_fail "reject empty configured value" _boxa::resolve_resources /work/project

seed_conf "memory=7g" "[relative/path]" "memory=9g"
resolve_ok /work/project
assert_eq "relative section is ignored, not global" "7516192768" "$_BOXA_MEMORY_BYTES"

# --- Structure-preserving config writer ------------------------------------

expected_conf="$_TMPROOT/expected.conf"
printf '%s\n' \
    '# global comment' \
    'memory = 7g' \
    'unknown_global = keep me' \
    '' \
    '[/work/target]' \
    '  memory = 9g  # target memory comment' \
    'memory_swap=10g# target swap comment' \
    'unknown = untouched' \
    '' \
    '[/work/other]' \
    'memory = 6g' > "$expected_conf"
printf '%s\n' \
    '# global comment' \
    'memory = 7g' \
    'unknown_global = keep me' \
    '' \
    '[/work/target]' \
    '  memory = 5g  # target memory comment' \
    'memory_swap=6g# target swap comment' \
    'unknown = untouched' \
    '' \
    '[/work/other]' \
    'memory = 6g' > "$BOXA_RESOURCES_CONF"
_boxa::write_resources_conf project /work/target 9g 10g
assert_file_eq "project rewrite preserves comments, formatting, unknown lines, and other scopes" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

printf '%s\n' 'memory = 7g' '[/work/other]' 'memory = 6g' > "$BOXA_RESOURCES_CONF"
printf '%s\n' 'memory = 7g' '[/work/other]' 'memory = 6g' '' \
    '[/work/new project]' 'memory = 8g' 'memory_swap = 9g' > "$expected_conf"
_boxa::write_resources_conf project '/work/new project' 8g 9g
assert_file_eq "missing project section is appended" "$expected_conf" "$BOXA_RESOURCES_CONF"

printf '%s' $'# keep byte-identical\nmemory = 7g' > "$BOXA_RESOURCES_CONF"
cp "$BOXA_RESOURCES_CONF" "$expected_conf"
writer_stderr="$_TMPROOT/writer.stderr"
if _boxa::write_resources_conf project '/work/C#' 8g 2> "$writer_stderr"; then
    printf 'FAIL  mem set rejects a project path containing #\n      expected failure\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  mem set rejects a project path containing #\n'
fi
assert_contains "mem set error names the unrepresentable project path" \
    "/work/C#" "$(< "$writer_stderr")"
assert_contains "mem set error explains the resources.conf limitation" \
    "resources.conf cannot represent" "$(< "$writer_stderr")"
assert_contains "mem set error points to the one-shot --memory workaround" \
    "--memory" "$(< "$writer_stderr")"
assert_file_eq "rejected mem set leaves config byte-identical" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

if _boxa::write_resources_conf project '/work/C#' '' 2> "$writer_stderr"; then
    printf 'FAIL  mem unset rejects a project path containing #\n      expected failure\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  mem unset rejects a project path containing #\n'
fi
assert_contains "mem unset error names the unrepresentable project path" \
    "/work/C#" "$(< "$writer_stderr")"
assert_contains "mem unset error explains the resources.conf limitation" \
    "resources.conf cannot represent" "$(< "$writer_stderr")"
assert_contains "mem unset error points to the one-shot --memory workaround" \
    "--memory" "$(< "$writer_stderr")"
assert_file_eq "rejected mem unset leaves config byte-identical" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

for invalid_path in $'/work/carriage\rreturn' $'/work/line\nfeed'; do
    cp "$BOXA_RESOURCES_CONF" "$expected_conf"
    assert_fail "mem set rejects a project path containing CR or LF" \
        _boxa::write_resources_conf project "$invalid_path" 8g
    assert_file_eq "rejected CR/LF mem set leaves config byte-identical" \
        "$expected_conf" "$BOXA_RESOURCES_CONF"

    assert_fail "mem unset rejects a project path containing CR or LF" \
        _boxa::write_resources_conf project "$invalid_path" ''
    assert_file_eq "rejected CR/LF mem unset leaves config byte-identical" \
        "$expected_conf" "$BOXA_RESOURCES_CONF"
done

printf '%s\n' '# keep' '[/work/app]' 'memory = 6g' > "$BOXA_RESOURCES_CONF"
printf '%s\n' '# keep' 'memory = 8g' 'memory_swap = 9g' '[/work/app]' 'memory = 6g' > "$expected_conf"
_boxa::write_resources_conf global '' 8g 9g
assert_file_eq "missing global keys are inserted before project sections" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

printf '%s\n' 'memory = 7g' '[/work/app]' 'memory = 6g' > "$BOXA_RESOURCES_CONF"
printf '%s\n' 'memory = 8g' 'memory_swap = 9g' '[/work/app]' 'memory = 6g' > "$expected_conf"
_boxa::write_resources_conf global '' 8g 9g
assert_file_eq "missing global memory_swap is appended independently" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

printf '%s' $'# global\nmemory=7g # keep\nmemory_swap = 8g\n[/work/app]\nmemory=6g' \
    > "$BOXA_RESOURCES_CONF"
printf '%s' $'# global\nmemory=9g # keep\nmemory_swap = 10g\n[/work/app]\nmemory=6g' \
    > "$expected_conf"
_boxa::write_resources_conf global '' 9g 10g
assert_file_eq "global rewrite preserves inline comments, project bytes, and no-final-newline state" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

rm -f "$BOXA_RESOURCES_CONF"
printf '%s' 'memory = 8g' > "$expected_conf"
_boxa::write_resources_conf global '' 8g
assert_file_eq "missing config is created without adding unrelated bytes" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

printf '%s' $'# untouched\nmemory = 7g\nmemory_swap = 8g' > "$BOXA_RESOURCES_CONF"
cp "$BOXA_RESOURCES_CONF" "$expected_conf"
assert_fail "writer rejects invalid Memory size" \
    _boxa::write_resources_conf global '' nonsense
assert_file_eq "invalid size leaves config untouched" "$expected_conf" "$BOXA_RESOURCES_CONF"

assert_fail "writer rejects inherited memory_swap below new memory" \
    _boxa::write_resources_conf global '' 9g
assert_file_eq "invalid resulting pair leaves config untouched" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

printf '%s\n' 'memory = 4g' 'memory_swap = 8g' \
    '[/work/swap-only]' 'memory_swap = 6g' > "$BOXA_RESOURCES_CONF"
cp "$BOXA_RESOURCES_CONF" "$expected_conf"
writer_stderr="$_TMPROOT/writer.stderr"
if _boxa::write_resources_conf global '' 7g 8g 2> "$writer_stderr"; then
    printf 'FAIL  global writer rejects invalid effective project pair\n      expected failure\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  global writer rejects invalid effective project pair\n'
fi
assert_contains "global writer error names the offending project section" \
    "[/work/swap-only]" "$(< "$writer_stderr")"
assert_file_eq "invalid effective project pair leaves config untouched" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

printf '%s\n' 'memory = 7g' '[/work/app]' 'memory = 6g' > "$BOXA_RESOURCES_CONF"
_boxa::write_resources_conf project /work/app 8g 8g
resolve_ok /work/app
assert_eq "writer cache reset exposes new project Memory value" \
    "8589934592" "$_BOXA_MEMORY_BYTES"
assert_eq "writer stores --swap in the same project scope" \
    "8589934592" "$_BOXA_MEMORY_SWAP_BYTES"

# --- Structure-preserving config removal -----------------------------------

printf '%s\n' \
    '# global' \
    'memory = 8g' \
    'memory_swap = 9g' \
    '[/work/app]' \
    'memory = 6g' \
    'memory_swap = 7g' \
    'unknown = preserve' \
    '[/work/other]' \
    'memory = 5g' > "$BOXA_RESOURCES_CONF"
printf '%s\n' \
    '# global' \
    'memory = 8g' \
    'memory_swap = 9g' \
    '[/work/app]' \
    'unknown = preserve' \
    '[/work/other]' \
    'memory = 5g' > "$expected_conf"
_boxa::write_resources_conf project /work/app ''
assert_file_eq "project unset removes both keys and preserves remaining section content" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"
assert_eq "project unset reports a change" "1" "$_BOXA_RESOURCES_CONF_CHANGED"
resolve_ok /work/app
assert_eq "project unset exposes global Memory fallback" "8589934592" "$_BOXA_MEMORY_BYTES"
assert_eq "project unset exposes global source" "global config" "$_BOXA_MEMORY_SOURCE"

printf '%s\n' 'memory = 8g' 'memory_swap = 7g' \
    '[/work/masked]' 'memory = 5g' > "$BOXA_RESOURCES_CONF"
cp "$BOXA_RESOURCES_CONF" "$expected_conf"
if _boxa::write_resources_conf project /work/masked '' 2> "$writer_stderr"; then
    printf 'FAIL  project unset rejects invalid inherited effective pair\n      expected failure\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  project unset rejects invalid inherited effective pair\n'
fi
assert_contains "project unset error names the offending project section" \
    "[/work/masked]" "$(< "$writer_stderr")"
assert_file_eq "invalid inherited pair after project unset leaves config untouched" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

printf '%s\n' '# keep' '[/work/app]' 'memory = 6g' 'memory_swap = 7g' \
    '[/work/other]' 'memory = 5g' > "$BOXA_RESOURCES_CONF"
printf '%s\n' '# keep' '[/work/other]' 'memory = 5g' > "$expected_conf"
_boxa::write_resources_conf project /work/app ''
assert_file_eq "project unset drops a section left empty" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

printf '%s\n' '[/work/app]' 'memory = 6g' 'memory_swap = 7g' \
    > "$BOXA_RESOURCES_CONF"
: > "$expected_conf"
_boxa::write_resources_conf project /work/app ''
assert_file_eq "project unset leaves no blank line when the whole file is removed" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

printf '%s' $'# global\nmemory = 8g # remove\nmemory_swap=9g\nunknown = preserve\n[/work/app]\nmemory = 6g' \
    > "$BOXA_RESOURCES_CONF"
printf '%s' $'# global\nunknown = preserve\n[/work/app]\nmemory = 6g' > "$expected_conf"
_boxa::write_resources_conf global '' ''
assert_file_eq "global unset preserves unrelated bytes and final-newline state" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

printf '%s\n' 'memory = 4g' '[/work/swap-only]' 'memory_swap = 6g' \
    > "$BOXA_RESOURCES_CONF"
cp "$BOXA_RESOURCES_CONF" "$expected_conf"
if _boxa::write_resources_conf global '' '' 2> "$writer_stderr"; then
    printf 'FAIL  global unset rejects invalid derived effective project pair\n      expected failure\n'
    fail_count=$((fail_count + 1))
else
    printf 'PASS  global unset rejects invalid derived effective project pair\n'
fi
assert_contains "global unset error names the offending project section" \
    "[/work/swap-only]" "$(< "$writer_stderr")"
assert_file_eq "invalid effective pair after global unset leaves config untouched" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

cp "$BOXA_RESOURCES_CONF" "$expected_conf"
_boxa::write_resources_conf project /work/missing ''
assert_eq "unset missing scope reports no change" "" "$_BOXA_RESOURCES_CONF_CHANGED"
assert_file_eq "unset missing scope leaves config untouched" \
    "$expected_conf" "$BOXA_RESOURCES_CONF"

# --- Running-container sum seam --------------------------------------------

printf '%s\n' 2147483648 3221225472 0 > "$BOXA_RUNNING_MEMORY_LIMITS_FILE"
assert_eq "sum running limits" "5368709120" "$(_boxa::running_memory_limit_sum)"
assert_ok "joint exhaustion detected" _boxa::would_jointly_exhaust_host 6442450944 10737418240
assert_fail "sum within host RAM" _boxa::would_jointly_exhaust_host 4294967296 10737418240
assert_eq "joint-exhaustion warning reuses canonical wording" \
    "WARNING: Running boxa Containers can jointly exhaust host RAM; use the .wslconfig VM backstop." \
    "$(_boxa::joint_exhaustion_warning 6442450944 10737418240)"

seed_conf \
    'memory = 1g' \
    '[/work/target]' \
    'memory = 5g' \
    '[/work/other]' \
    'memory = 2g'
printf '%s\t%s\n' \
    4294967296 /work/target \
    2147483648 /work/other \
    > "$BOXA_RUNNING_MEMORY_LIMITS_FILE"
assert_eq "projected sum replaces target Container old limit" "7516192768" \
    "$(_boxa::running_memory_limit_sum effective)"
assert_fail "project update projected sum stays within host RAM" \
    _boxa::would_jointly_exhaust_host 0 10737418240 effective

seed_conf \
    'memory = 4g' \
    '[/work/special]' \
    'memory = 2g'
printf '%s\t%s\n' \
    1073741824 /work/first \
    1073741824 /work/second \
    1073741824 /work/special \
    > "$BOXA_RUNNING_MEMORY_LIMITS_FILE"
assert_eq "projected sum applies global limit to every inheriting Container" "10737418240" \
    "$(_boxa::running_memory_limit_sum effective)"
assert_ok "global update projected sum can exhaust host RAM" \
    _boxa::would_jointly_exhaust_host 0 9663676416 effective

# --- `boxa ls` MEM cell -------------------------------------------------------

assert_eq "mem cell usage/limit percent" "2.3g/6.5g 35%" \
    "$(_boxa::mem_cell $'2469606195\n6979321856\n0')"
assert_eq "mem cell rounds percent to nearest" "2g/3g 67%" \
    "$(_boxa::mem_cell $'2147483648\n3221225472\n0')"
assert_eq "mem cell appends oom marker with count" "512m/1g 50% !oom×3" \
    "$(_boxa::mem_cell $'536870912\n1073741824\n3')"
assert_eq "mem cell limitless" "no limit" \
    "$(_boxa::mem_cell $'1073741824\nmax\n0')"
assert_eq "mem cell limitless keeps oom marker" "no limit !oom×2" \
    "$(_boxa::mem_cell $'1073741824\nmax\n2')"
assert_eq "mem cell empty probe degrades" "-" "$(_boxa::mem_cell '')"
assert_eq "mem cell partial probe degrades" "-" "$(_boxa::mem_cell $'123')"
assert_eq "mem cell garbage probe degrades" "-" \
    "$(_boxa::mem_cell 'cat: /sys/fs/cgroup/memory.current: No such file')"
assert_eq "mem cell zero max degrades" "-" "$(_boxa::mem_cell $'1\n0\n0')"
assert_eq "mem cell non-numeric oom count degrades" "-" \
    "$(_boxa::mem_cell $'1073741824\nmax\nnope')"

# --- Exited-Container OOM marker ---------------------------------------------

assert_eq "exited marker on lifetime flag" \
    "oom seen during run — see 'boxa mem foo'" \
    "$(_boxa::exited_oom_marker true foo)"
assert_eq "exited marker silent when false" "" \
    "$(_boxa::exited_oom_marker false foo)"
assert_eq "exited marker silent when flag missing" "" \
    "$(_boxa::exited_oom_marker '' foo)"

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count" >&2
    exit 1
fi
printf '\nAll tests passed.\n'
