#!/bin/bash
# Plain-bash assertions for the check-only `boxa doctor` report on a leftover
# `codex mcp-server` catalog entry (ADR 0037).
# Usage: bash tests/doctor-retired-codex-delegate.sh
#
# The doctor step is extracted from docker-run.sh and run in isolation, with
# HOME / XDG_CONFIG_HOME in a throwaway dir, so it reads a fixture catalog and
# never touches the developer's own ~/.config/boxa/mcp/catalog.json.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOXA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
_TMPROOT="$(mktemp -d)"
trap 'rm -rf "$_TMPROOT"' EXIT

fail_count=0

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

extract_function() {
    local name="$1" output="$2"
    awk -v signature="${name}() {" '
        $0 == signature { capture=1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$BOXA_DIR/docker-run.sh" > "$output"
}

extracted="$_TMPROOT/report_retired_codex_delegate_entries.sh"
extract_function report_retired_codex_delegate_entries "$extracted"
assert_contains "doctor step is extractable from docker-run.sh" \
    "python3 -m mcp.cli retired-codex-delegate-text" "$(< "$extracted")"
# Static guard: the step is actually wired into the `boxa doctor` mode block
# (between its MODE guard and its healthy exit), not just defined.
doctor_block="$(awk '
    /^if \[ "\$MODE" = "doctor" \]; then$/ { capture=1 }
    capture { print }
    capture && /^fi$/ { exit }
' "$BOXA_DIR/docker-run.sh")"
assert_contains "boxa doctor runs the check-only step" \
    "report_retired_codex_delegate_entries" "$doctor_block"
# shellcheck source=/dev/null
source "$extracted"

export HOME="$_TMPROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$XDG_CONFIG_HOME"

# A host that never had the entry: doctor says nothing at all.
assert_eq "clean catalog produces no doctor output" "" \
    "$(report_retired_codex_delegate_entries)"

# A host carrying the old entry: the explanation plus the removal command,
# under the entry's REAL name (the seed's default name is not assumed).
PYTHONPATH="$BOXA_DIR/scripts" python3 - <<'PY'
from mcp import catalog

catalog.add_entry("my-codex", ["codex", "mcp-server"])
PY
output="$(report_retired_codex_delegate_entries)"
assert_contains "doctor names the leftover entry" "'my-codex'" "$output"
assert_contains "doctor explains the removed subcommand" \
    "codex mcp-server" "$output"
assert_contains "doctor says the entry can never start" \
    "can never start" "$output"
assert_contains "doctor points at the Jobs replacement" \
    "boxa-job start --codex" "$output"
assert_contains "doctor points at the Jobs documentation" \
    "docs/jobs.md" "$output"
assert_contains "doctor prints the removal command with the real name" \
    "boxa mcp remove my-codex" "$output"

# Check-only: the report never mutates the catalog.
names="$(PYTHONPATH="$BOXA_DIR/scripts" python3 -c '
from mcp import catalog

print(",".join(e["name"] for e in catalog.entries_sorted(catalog.load_catalog())))
')"
assert_eq "doctor leaves the catalog entry in place" "my-codex" "$names"

# A host without python3 must not fail the doctor run: the step is
# best-effort, so an unreachable interpreter yields no output and no error.
assert_eq "doctor step degrades silently without python3" "" \
    "$(PATH=/nonexistent report_retired_codex_delegate_entries 2>/dev/null)"

echo ""
if [ "$fail_count" -eq 0 ]; then
    echo "All doctor retired-codex-delegate assertions passed."
else
    echo "$fail_count assertion(s) failed."
    exit 1
fi
