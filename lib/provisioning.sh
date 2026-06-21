# shellcheck shell=bash
# =============================================================================
# Boxa host-provisioning registry — single source of truth (ADR 0017)
# =============================================================================
# Sourced by:
#   - docker-run.sh (host) for `boxa doctor`
#   - (later slices) install.sh and the `boxa update` self-heal chain
#
# The registry is declarative data: an ordered list of provisioning steps,
# each a triple `id | script | category`. The backing scripts are the
# existing `scripts/ensure-<concern>.sh` files, invoked through one shared
# dispatch function so install / update / doctor can never drift onto
# parallel hand-maintained lists.
#
# Categories (ADR 0017 § 2):
#   A — unconditional: always performed; cheap, idempotent, no downside.
#       Repaired silently.
#   B — elective: gated on a past user choice (opt-out / seen marker).
#   C — environment prerequisite: external precondition boxa cannot
#       reliably repair; diagnosed, never silently mutated.
#
# Issue 01 seeded the five already-wired category-A steps and the
# category-A repair path. Issue 02 added the two extracted steps (mkcert,
# agent-allowlist-example). Issue 03 added the consolidated `completions`
# step (one impl replacing the install.sh + `boxa update` copies). Issue 04
# adds the category-B (elective) steps plus the report/`--fix`/`--fix <step>`
# surface. Category C and the install/update rewires land in later slices.
#
# Category-B steps are not plain `ensure-*.sh --quiet-if-noop` no-op-detectors:
# each is gated on a past user choice and has three states — `ok` (active /
# provisioned), `declined` (the user opted out or dismissed it), and `missing`
# (never decided). A non-mutating PROBE (`boxa::provisioning_probe <id>`)
# reports that state; the matching REPAIR (`boxa::repair_elective <id>`) runs
# the existing action for that step. Probe and repair read the SAME source of
# truth (the https.conf opt-out, the MCP onboarding state, the token files), so
# the report can never disagree with what a fix would do (ADR 0017 § 3).
# =============================================================================

# --- Sourcing guard ----------------------------------------------------------
[ -n "${_BOXA_PROVISIONING_SH:-}" ] && return 0
_BOXA_PROVISIONING_SH=1

# --- Registry ----------------------------------------------------------------
# Ordered list of provisioning steps. Each entry is `id|script|category`,
# where `script` is a path relative to the boxa repo root. Order is
# meaningful: dispatch walks the list top-to-bottom.
#
# Consumed via the accessor functions below; shellcheck can't see that the
# array is read by sourcing scripts.
# shellcheck disable=SC2034
BOXA_PROVISIONING_STEPS=(
    "mkcert|scripts/ensure-mkcert.sh|A"
    "allow-for-host-state|scripts/ensure-allow-for-host-state.sh|A"
    "agent-browser-helpers|scripts/ensure-agent-browser-helpers.sh|A"
    "agent-browser-host-state|scripts/ensure-agent-browser-host-state.sh|A"
    "upstream-agent-browser-skill|scripts/ensure-upstream-agent-browser-skill.sh|A"
    "agent-allowlist-example|scripts/ensure-agent-allowlist-example.sh|A"
    "boxa-skill|scripts/ensure-boxa-skill.sh|A"
    "completions|scripts/ensure-completions.sh|A"
    "mcp-onboarding|scripts/ensure-mcp-onboarding.sh|B"
    "claude-token|-|B"
    "https|-|B"
    "git|-|C"
    "docker|-|C"
    "docker-group|-|C"
    "boxa-symlink|-|C"
)

# --- Registry accessors ------------------------------------------------------

# Split a registry entry into its fields. Usage:
#   boxa::provisioning_field <entry> <id|script|category>
boxa::provisioning_field() {
    local entry="$1" field="$2"
    case "$field" in
        id)       printf '%s' "${entry%%|*}" ;;
        script)   local rest="${entry#*|}"; printf '%s' "${rest%%|*}" ;;
        category) printf '%s' "${entry##*|}" ;;
        *)        return 2 ;;
    esac
}

# --- Category-B elective probes & repairs ------------------------------------

# Probe one elective step WITHOUT mutating anything. Prints exactly one of:
#   ok       — active / provisioned (no action needed, nothing to report)
#   declined — the user opted out or dismissed it earlier
#   missing  — never decided (offer it / report it as not configured)
#
# Each probe reads the same state the matching repair acts on, so the report
# and a subsequent fix can never disagree.
boxa::provisioning_probe() {
    local id="$1"
    case "$id" in
        https)
            # Shared source of truth: https.conf (read via lib/https.sh).
            # active -> ok; opted out -> declined; neither decided -> missing.
            # shellcheck source=lib/https.sh
            source "$BOXA_DIR/lib/https.sh"
            if boxa::https_active; then
                printf 'ok'
            elif boxa::https_optout; then
                printf 'declined'
            else
                printf 'missing'
            fi
            ;;
        claude-token)
            # Provisioned when an auth path the CONTAINER can use exists: a token
            # file or a token in the environment. On non-macOS, host OAuth
            # credentials (~/.claude/.credentials.json) also count because they
            # are shared into the container via bind mount. On macOS they do NOT
            # count: the host login is never shared in and the app deletes that
            # file on /login (ADR 0016), so only a token authenticates the
            # container fleet — match setup_claude_token + the runtime injection.
            # No opt-out marker, so the only states are ok / missing.
            if [ -f "$HOME/.config/boxa/claude-token" ] \
               || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
                printf 'ok'
            elif [ "$(uname -s 2>/dev/null || echo Unknown)" != "Darwin" ] \
               && [ -f "$HOME/.claude/.credentials.json" ]; then
                printf 'ok'
            else
                printf 'missing'
            fi
            ;;
        mcp-onboarding)
            # Eligibility lives in the MCP Python core (single source of truth,
            # shared with ensure-mcp-onboarding.sh). profileExists -> ok;
            # seen/dismissed -> declined; otherwise (shouldOffer) -> missing.
            local status_json should_offer profile_exists
            if ! command -v python3 >/dev/null 2>&1; then
                printf 'missing'; return 0
            fi
            status_json="$(PYTHONPATH="$BOXA_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}" \
                python3 -m mcp.cli onboarding-status 2>/dev/null || true)"
            if [ -z "$status_json" ]; then printf 'missing'; return 0; fi
            should_offer="$(_boxa::json_bool "$status_json" shouldOffer)"
            profile_exists="$(_boxa::json_bool "$status_json" profileExists)"
            if [ "$profile_exists" = "true" ]; then
                printf 'ok'
            elif [ "$should_offer" = "true" ]; then
                printf 'missing'
            else
                printf 'declined'
            fi
            ;;
        *)
            printf 'missing'; return 2 ;;
    esac
}

# Minimal field reader for the MCP onboarding-status JSON (the Python core emits
# a stable indented object). Avoids a JSON-parser dependency, matching the same
# approach in ensure-mcp-onboarding.sh.
_boxa::json_bool() {
    local json="$1" field="$2"
    printf '%s\n' "$json" \
        | grep -E "\"$field\"[[:space:]]*:" \
        | head -n1 \
        | sed -E "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"?([^\",]*)\"?.*/\1/"
}

# Repair one elective step by running its existing action. Reuses the canonical
# implementations rather than reimplementing them:
#   https         -> _boxa::run_https_upgrade (defined in docker-run.sh; in
#                    scope when `boxa doctor` runs in-process)
#   mcp-onboarding -> scripts/ensure-mcp-onboarding.sh (interactive offer)
#   claude-token  -> re-exec the `boxa claude-token` command
# Returns the action's exit status.
boxa::repair_elective() {
    local id="$1"
    case "$id" in
        https)
            if declare -F _boxa::run_https_upgrade >/dev/null 2>&1; then
                _boxa::run_https_upgrade
            else
                printf 'repair_elective: HTTPS upgrade is only available from boxa doctor\n' >&2
                return 1
            fi
            ;;
        mcp-onboarding)
            # Genuinely re-offer even a previously dismissed onboarding: clear
            # the one-time seen marker first, then run the offer. A no-op when
            # nothing was dismissed (a missing onboarding has no marker), and
            # profile_exists() still suppresses an offer over a real profile.
            if command -v python3 >/dev/null 2>&1; then
                PYTHONPATH="$BOXA_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}" \
                    python3 -m mcp.cli onboarding-rearm >/dev/null 2>&1 || true
            fi
            "$BOXA_DIR/scripts/ensure-mcp-onboarding.sh"
            ;;
        claude-token)
            "$BOXA_DIR/docker-run.sh" claude-token
            ;;
        *)
            printf 'repair_elective: unknown elective step %s\n' "$id" >&2
            return 2 ;;
    esac
}

# --- Category-C environment prerequisites ------------------------------------
# External preconditions boxa cannot reliably repair on its own (they need a
# re-login, a package manager, or a running daemon). These are DIAGNOSE-ONLY:
# never mutated, not even under `--fix`. Each has a non-mutating check and a
# remediation message printing the exact command for the user to run.

# The installed `boxa` command symlink (matches install.sh's SYMLINK_PATH).
BOXA_SYMLINK_PATH="${BOXA_SYMLINK_PATH:-/usr/local/bin/boxa}"

# Print 'ok' or 'missing' for a prerequisite, WITHOUT mutating anything. A
# prerequisite that does not apply to this platform reports 'ok' (n/a).
boxa::prereq_state() {
    local id="$1"
    case "$id" in
        git)
            command -v git >/dev/null 2>&1 && printf 'ok' || printf 'missing' ;;
        docker)
            # Binary present AND daemon responding (mirrors install.sh).
            if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
                printf 'ok'
            else
                printf 'missing'
            fi
            ;;
        docker-group)
            # Linux-only and only meaningful when a `docker` group exists
            # (Docker Desktop / rootless setups have none — treat as n/a).
            if [ "$(uname -s 2>/dev/null || echo Unknown)" != "Linux" ] \
               || ! command -v docker >/dev/null 2>&1 \
               || ! getent group docker >/dev/null 2>&1; then
                printf 'ok'
            elif id -nG 2>/dev/null | grep -qw docker; then
                # Inspect the CURRENT process's groups, not `id -nG <user>`
                # (the account database): after `usermod -aG docker` the db
                # lists the group before the login session inherits it, so the
                # db view would falsely report OK until the user re-logs in.
                printf 'ok'
            else
                printf 'missing'
            fi
            ;;
        boxa-symlink)
            # Not enough that SOMETHING sits at the path — it must be a symlink
            # that actually resolves to THIS checkout's docker-run.sh and is
            # executable. Another binary, or a link into an obsolete checkout,
            # means `boxa` does not run this installation.
            local _link_target _expected
            if [ -L "$BOXA_SYMLINK_PATH" ] \
               && _link_target="$(readlink -f "$BOXA_SYMLINK_PATH" 2>/dev/null)" \
               && _expected="$(readlink -f "$BOXA_DIR/docker-run.sh" 2>/dev/null)" \
               && [ "$_link_target" = "$_expected" ] \
               && [ -x "$_link_target" ]; then
                printf 'ok'
            else
                printf 'missing'
            fi
            ;;
        *)
            printf 'missing'; return 2 ;;
    esac
}

# Print the remediation command/instruction for a prerequisite.
boxa::prereq_remedy() {
    local id="$1"
    case "$id" in
        git)
            printf 'Install git via your package manager (e.g. apt install git / brew install git).' ;;
        docker)
            printf 'Start the Docker daemon (Docker Desktop, OrbStack, or: sudo systemctl start docker).' ;;
        docker-group)
            printf 'Run: sudo usermod -aG docker %s  — then log out and back in.' "${USER:-$(id -un)}" ;;
        boxa-symlink)
            printf 'Re-run install.sh to (re)create the boxa command symlink at %s.' "$BOXA_SYMLINK_PATH" ;;
        *)
            printf 'Unknown prerequisite %s.' "$id" ;;
    esac
}

# --- Dispatch ----------------------------------------------------------------

# Run one category-A step (`ensure-*.sh --quiet-if-noop`) and record its
# result. The `--quiet-if-noop` contract guarantees silence on a no-op, so any
# stdout means the step provisioned something — the dispatch uses that as the
# change signal (the only contract the existing scripts expose). Stderr
# (warnings) is left attached so it surfaces to the user as usual.
_boxa::run_step_a() {
    local id="$1" script="$2"
    local path="$BOXA_DIR/$script"
    if [ ! -x "$path" ]; then
        BOXA_PROVISIONING_SKIPPED+=("$id")
        return 0
    fi
    local out rc
    out="$("$path" --quiet-if-noop)" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        BOXA_PROVISIONING_FAILED+=("$id")
    elif [ -n "$out" ]; then
        printf '%s\n' "$out"
        BOXA_PROVISIONING_REPAIRED+=("$id")
    else
        BOXA_PROVISIONING_OK+=("$id")
    fi
}

# True when <id> is a registered step.
boxa::provisioning_has_step() {
    local want="$1" entry
    for entry in "${BOXA_PROVISIONING_STEPS[@]}"; do
        [ "${entry%%|*}" = "$want" ] && return 0
    done
    return 1
}

# Walk the registry and run provisioning steps.
#
# Usage: boxa::run_provisioning <mode> [step…]
#
# Modes:
#   repair-a          Repair every category-A step silently. Optional trailing
#                     ids restrict the run to those (still category-A only).
#   report-electives  Probe every category-B step WITHOUT mutating; classify
#                     each as ok / missing / declined for the caller's report.
#   default           One pass that repairs every category-A step AND probes
#                     every category-B step (no elective mutation). Backs `boxa
#                     doctor`'s default behaviour with a single result reset, so
#                     the A and B results coexist in one summary.
#   fix [ids…]        Repair steps. With NO ids: repair all category-A steps
#                     plus every category-B step whose probe is `missing` (a
#                     declined elective is left alone — not silently
#                     re-triggered). With ids: repair exactly those steps,
#                     forcing category-B repair regardless of declined state
#                     (the user named it explicitly). Unknown ids are rejected.
#
# Requires BOXA_DIR to point at the repo root (set by docker-run.sh).
# Results are reported through the global arrays below, reset on each call:
#   BOXA_PROVISIONING_REPAIRED — ids of steps that performed actions
#   BOXA_PROVISIONING_OK       — ids already provisioned / active
#   BOXA_PROVISIONING_FAILED   — ids whose action exited non-zero
#   BOXA_PROVISIONING_SKIPPED  — ids of category-A steps with no runnable script
#   BOXA_PROVISIONING_MISSING  — ids of electives never decided (report mode)
#   BOXA_PROVISIONING_DECLINED — ids of electives the user opted out of
#   BOXA_PROVISIONING_PREREQ_MISSING — ids of unmet category-C prerequisites
# shellcheck disable=SC2034  # populated for the caller's summary
boxa::run_provisioning() {
    local mode="$1"; shift
    local -a want_ids=("$@")

    BOXA_PROVISIONING_REPAIRED=()
    BOXA_PROVISIONING_OK=()
    BOXA_PROVISIONING_FAILED=()
    BOXA_PROVISIONING_SKIPPED=()
    BOXA_PROVISIONING_MISSING=()
    BOXA_PROVISIONING_DECLINED=()
    BOXA_PROVISIONING_PREREQ_MISSING=()

    local has_ids=false
    [ "${#want_ids[@]}" -gt 0 ] && has_ids=true

    # Reject unknown ids up front so callers can surface a clear error.
    if $has_ids; then
        local want
        for want in "${want_ids[@]}"; do
            boxa::provisioning_has_step "$want" || {
                printf 'boxa::run_provisioning: unknown step %s\n' "$want" >&2
                return 3
            }
        done
    fi

    case "$mode" in
        repair-a|report-electives|fix|default) ;;
        *) printf 'boxa::run_provisioning: unknown mode %s\n' "$mode" >&2; return 2 ;;
    esac

    local entry id script category state
    for entry in "${BOXA_PROVISIONING_STEPS[@]}"; do
        id="$(boxa::provisioning_field "$entry" id)"
        script="$(boxa::provisioning_field "$entry" script)"
        category="$(boxa::provisioning_field "$entry" category)"

        # Optional id filter: when ids were passed, run only those.
        if $has_ids; then
            local matched=false want
            for want in "${want_ids[@]}"; do
                [ "$want" = "$id" ] && { matched=true; break; }
            done
            $matched || continue
        fi

        case "$mode" in
            repair-a)
                [ "$category" = "A" ] || continue
                _boxa::run_step_a "$id" "$script"
                ;;
            report-electives)
                [ "$category" = "B" ] || continue
                state="$(boxa::provisioning_probe "$id")"
                case "$state" in
                    missing)  BOXA_PROVISIONING_MISSING+=("$id") ;;
                    declined) BOXA_PROVISIONING_DECLINED+=("$id") ;;
                    *)        BOXA_PROVISIONING_OK+=("$id") ;;
                esac
                ;;
            default)
                if [ "$category" = "A" ]; then
                    _boxa::run_step_a "$id" "$script"
                elif [ "$category" = "B" ]; then
                    state="$(boxa::provisioning_probe "$id")"
                    case "$state" in
                        missing)  BOXA_PROVISIONING_MISSING+=("$id") ;;
                        declined) BOXA_PROVISIONING_DECLINED+=("$id") ;;
                        *)        BOXA_PROVISIONING_OK+=("$id") ;;
                    esac
                elif [ "$category" = "C" ]; then
                    # Diagnose-only: never mutated.
                    if [ "$(boxa::prereq_state "$id")" = "missing" ]; then
                        BOXA_PROVISIONING_PREREQ_MISSING+=("$id")
                    else
                        BOXA_PROVISIONING_OK+=("$id")
                    fi
                fi
                ;;
            fix)
                if [ "$category" = "A" ]; then
                    _boxa::run_step_a "$id" "$script"
                elif [ "$category" = "B" ]; then
                    # Bare `fix` only repairs electives that were never decided;
                    # an explicit id forces the repair regardless of state.
                    if ! $has_ids; then
                        state="$(boxa::provisioning_probe "$id")"
                        case "$state" in
                            declined) BOXA_PROVISIONING_DECLINED+=("$id"); continue ;;
                            ok)       BOXA_PROVISIONING_OK+=("$id"); continue ;;
                        esac
                    fi
                    if boxa::repair_elective "$id"; then
                        # Verify the action actually resolved the elective before
                        # claiming success: some actions exit 0 without
                        # provisioning anything (a non-interactive mcp-onboarding
                        # only prints a follow-up command; a missing python
                        # soft-exits 0). Re-probe and classify by the real state
                        # so a still-missing elective is reported, not faked as
                        # repaired.
                        state="$(boxa::provisioning_probe "$id")"
                        case "$state" in
                            ok)       BOXA_PROVISIONING_REPAIRED+=("$id") ;;
                            declined) BOXA_PROVISIONING_DECLINED+=("$id") ;;
                            *)        BOXA_PROVISIONING_MISSING+=("$id") ;;
                        esac
                    else
                        BOXA_PROVISIONING_FAILED+=("$id")
                    fi
                elif [ "$category" = "C" ]; then
                    # Prerequisites are diagnose-only — never mutated, even when
                    # explicitly named in `--fix <step>`.
                    if [ "$(boxa::prereq_state "$id")" = "missing" ]; then
                        BOXA_PROVISIONING_PREREQ_MISSING+=("$id")
                    else
                        BOXA_PROVISIONING_OK+=("$id")
                    fi
                fi
                ;;
        esac
    done
}
