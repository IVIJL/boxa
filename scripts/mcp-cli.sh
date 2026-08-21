#!/bin/bash
set -euo pipefail

# =============================================================================
# mcp-cli — host-side dispatcher for `boxa mcp <subcommand>` (ADR 0013)
# =============================================================================
# Thin shell front-end for the MCP command group. It parses the subcommand and
# flags, prints human-readable output, and delegates all candidate-model / JSON
# work to the Python core in `scripts/mcp/` (`python3 -m mcp.cli ...`). Keeping
# the dispatcher thin means later slices (02-10) add providers, classification,
# and profile merge in unit-testable Python rather than in shell.
#
# `boxa mcp` is a host-side command like every other boxa command: it must
# run without Docker for `--help`, `import` (empty), `list --inherited`
# (empty), and any `--json` path. Read-only commands in this slice write
# nothing under ~/.config/boxa/mcp/, ~/.claude, or ~/.codex.
#
# This slice (issue 02) adds the first real import provider — read-only Claude
# Code MCP discovery:
#   - `--help` lists all planned subcommands;
#   - `import` scans the current Project record + global Claude config and
#     prints discovered Inherited MCP candidates (dry-run; no writes);
#   - `import --project <name-or-path>` scans one explicit Project;
#   - `import --all` scans every known Claude project record;
#   - `import --json` / `list --inherited --json` emit the versioned candidate
#     envelope from the Python core.
# Everything else (profile writes via --apply, render, wrapper, install,
# enable/disable/remove) is a later issue and is rejected with a clear
# "not implemented yet" message.
#
# Claude keys its project records by ABSOLUTE PATH in ~/.claude/.claude.json.
# The dispatcher resolves the current working directory (default scope) or an
# explicit `--project` token to that record-key form, then passes it to the
# Python core. No secret values ever cross this boundary — the Python core
# only emits env-var names.
#
# Why this file lives in scripts/ and not lib/: it is a multi-subcommand
# dispatcher invoked via `exec` from docker-run.sh, mirroring
# scripts/agent-browser-broker.sh. lib/ holds reusable sourced modules.
# =============================================================================

BOXA_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

# Locate the Python core package (scripts/mcp/). Putting scripts/ on
# PYTHONPATH lets `python3 -m mcp.cli` resolve `import mcp`.
MCP_PY_DIR="$BOXA_DIR/scripts"

# Naming helpers (boxa::sanitize) — used to match a bare `--project <name>`
# token against Claude's absolute-path record keys via ADR 0005 sanitized
# basenames. Sourced read-only; defines no globals we mutate here.
# shellcheck source-path=SCRIPTDIR source=../lib/naming.sh disable=SC1091
. "$BOXA_DIR/lib/naming.sh"

# Shared interactive picker (ADR 0006): fzf when present, a numbered fallback
# (comma multi-select, `q` cancel, /dev/tty reads) otherwise. The import wizard
# (issue 12) drives picker::many for the multi-select and picker::one for the
# project picker, so fzf-vs-fallback and the cancel UX stay consistent with the
# rest of boxa and are exercised by tests/picker.sh.
# shellcheck source-path=SCRIPTDIR source=../lib/picker.sh disable=SC1091
. "$BOXA_DIR/lib/picker.sh"

# --- Usage -------------------------------------------------------------------

_usage() {
    cat <<'EOF'
Usage: boxa mcp <subcommand> [args]

Manage the user-wide MCP catalog, Project activations, and durable everywhere
marks (ADR 0021, ADR 0029).
Catalog membership, runtime readiness, activation, launch-time injection, and
execution identity are separate states. Catalog membership exposes nothing.

Subcommands:
  migrate     Migrate legacy profiles into catalog + explicit activations.
  catalog     List prepared MCP catalog definitions (never activates them).
  readiness   Check whether one entry can run in a running Project.
  activate    Activate one entry for a Project or mark it everywhere.
  deactivate  Deactivate in one Project; everywhere opt-outs are sticky.
  mode        Change a catalog entry's execution identity (host-only).
  update      Rename or transactionally update one catalog definition.
  import      Discover Inherited MCP servers from agent config and classify
              them as import candidates (dry-run; no writes).
  list        Show catalog/readiness/activation/injection/mode for one Project.
  status      Show the same effective Project state, including isolation status.
  doctor      Diagnose catalog, readiness, activation and launch profile state.
  add         Add a service-isolated definition to the user-wide MCP catalog.
  install     Prepare one catalog runtime in a running Project; never activate.
  remove      Destroy one catalog identity and cascade its activations.
  reload      Re-stage changed MCP secrets into running Container(s) without a
              stop/start (host-initiated momentary root exec; no restart).
  secret      Fill a missing declared secret via a picker and hidden prompt.

Mental model and common flow:
  1. 'add' records a durable user-wide catalog definition; it does not install
     the command named after '--' and does not expose the server to any agent.
  2. 'install' prepares runtimes that need materialization. Direct commands
     already present in the Container (for example 'codex') need no install.
  3. 'readiness' verifies the entry against one running Project.
  4. 'activate' exposes it to selected consumers in one Project, or in every
     present and future Project only when explicitly marked --everywhere.
  Catalog definitions and execution mode survive Container and host restarts.
  To reuse a prepared entry elsewhere, activate it there or deliberately mark
  it --everywhere.

Trusted Codex delegation to Claude (run on the host):
  Fresh installs and 'boxa update' offer to seed the 'codex-delegate' entry
  (definition + confirmed agent-trusted grant) one time; when accepted, the
  'add' and 'mode' steps below are already done and only per-Project
  'readiness' + 'activate' remain.

  cd /path/to/my-project
  boxa up
  boxa mcp add codex-delegate -- codex mcp-server
  boxa mcp mode codex-delegate agent-trusted
  boxa mcp readiness codex-delegate --project "$PWD"
  boxa mcp activate codex-delegate --project "$PWD" --for claude

  'codex-delegate' is only the catalog name; 'codex mcp-server' after '--' is
  the command Boxa will launch. Boxa does not install Codex here. The Boxa
  Container image provides it, and readiness also checks the mounted node
  user's existing 'codex login' (including ChatGPT subscription login). No API
  key is required for that login. Agent trust grants the server the same
  node-user repository/private-state access as the launching agent, so review
  the preview before confirming. Add and grant trust once; Codex
  self-activation is refused.

  In another Project the definition and trust grant are reused; only activate:
  cd /path/to/other-project
  boxa up
  boxa mcp activate codex-delegate --project "$PWD" --for claude

Activation:
  boxa mcp activate <entry> [--project <p>] --for claude|codex|claude,codex
      [--accept-degraded-secret-isolation] [--json]
      Record the selected consumers in the host-owned activation store. New
      Container sessions receive them from the launch wrapper and runtime snapshot.
  boxa mcp activate <entry> --everywhere --for claude|codex|claude,codex
      [--yes] [--accept-degraded-secret-isolation] [--json]
      Activate in every known Project and inherit into future Projects. --yes
      explicitly accepts future-Project trust when the entry is agent-trusted.
  boxa mcp activate <entry> --no-everywhere [--json]
      Stop future inheritance without changing existing Project activations.
  boxa mcp deactivate <entry> [--project <p>] [--json]
      Remove this Project activation from future launch-time profiles and keep
      a sticky opt-out if the entry is or later becomes marked everywhere.

Status and doctor:
  boxa mcp list|status [--project <p>] [--json]
      Show catalog membership, readiness, activation, selected consumers,
      execution mode/concrete user, and isolation distinctly.
  boxa mcp doctor [--fix] [--json]
      Diagnose stopped targets, missing prerequisites, stale references,
      forbidden agent-trusted secrets, runtime-snapshot drift, and degraded
      Docker isolation. --fix may repair only Boxa-owned directories/wrapper
      and the secret-free runtime snapshot.
      It never installs, starts, activates, grants trust, accepts a degradation,
      or modifies a Project file.

Definition import (write) path:
  boxa mcp import --apply [scope]             Import selected definitions.
      Interactive TTY  -> one sectioned multi-select picker: New + Changed
                          (reimport); in-sync entries are summarized only.
      Non-interactive  -> requires an explicit selection:
        --server <name>     Apply by server name (repeatable; fails on
                            ambiguity — use --import-id instead).
        --import-id <id>    Apply by stable import id (repeatable).
        --all-applicable    Apply every applicable (container) candidate.
        --reimport          Let --server/--import-id select catalog matches.
        --all-changed       Reimport every changed catalog match.
        --conflict update|skip
                            Resolve same-named catalog definition conflicts.
        --force             Import an explicitly selected host-only candidate.
  boxa mcp import --activate --project <p> --for claude|codex|claude,codex
      [selection] [--conflict update|skip] [--yes] [--json]
      Import, check readiness, and activate in one command. --yes with no
      selection accepts every applicable proposal for non-interactive use.
  Import adds secret-free, service-isolated catalog definitions only. It never
  installs a runtime, copies credential values silently, or infers agent trust.
  Each discovered secret header/env value requires its own default-no consent;
  non-TTY and --json runs declare names only and print the secret-set next step. The
  default --apply path creates no activation; --activate is the explicit
  one-shot exception. Host-only candidates require --force; unknown and
  excluded candidates remain non-importable.

Install (materialize) path:
  boxa mcp install <entry> [--project <p>] [--allow-for <min>] [--keep-window] [--json]
      Prepare a catalog entry in one RUNNING Project, then re-check readiness.
      It never starts the Project or activates the entry.
      npm/npx
      servers install into the persistent npm-global prefix; Docker-backed
      servers pull into Project-scoped rootless Docker state.
      Runtime state survives Container recreation. --allow-for <min> is an
      explicit network window for materialization; readiness itself is local.

Add (record a new server) path:
  boxa mcp add <name> [--json] -- <command spec...>
  boxa mcp add <name> [--json] --url <http(s)-url>
      [--header <name=value>]... [--secret-header-key <name>]...
      Add a service-isolated command definition or a remote HTTP definition.
      This never activates, starts, installs, or probes the server. The
      returned opaque ID survives rename/updates.

Execution mode:
  boxa mcp mode <entry> service-isolated|agent-trusted [--yes] [--json]
      Host-only. Shows the stable ID, resolved command/runtime, and exact access
      boundary before confirmation. Mode is immutable while any activation
      exists; agent-trusted is incompatible with declared or retained secrets.

Catalog update:
  boxa mcp update
      In a TTY, pick a catalog entry. HTTP entries offer one guided action:
      add a secret authentication header and store its value immediately.
  boxa mcp update <entry> [--name <new-name>] [--description <text>]
      [--url <http(s)-url>]
      [--header <name=value>]... [--secret-header-key <name>]...
      [--clear-headers] [--clear-secret-header-keys]
      [--json] [-- <command spec...>]
      Rename/cosmetic changes preserve stable identity and trust. Runtime
      changes preflight every activated Project, then atomically switch the
      catalog and broker runtime snapshot.
  boxa mcp remove <entry> [--json]
      Cascade every activation and update future launch-time profiles.

Migration:
  boxa mcp migrate [--allow-tracked-mcp-json]
      [--allow-tracked-codex-config] [--json]
      Copy legacy definitions into the catalog once. Former global definitions
      get no activation; Project definitions retain only originally rendered
      consumers. Then surgically remove recorded Boxa content from the retired
      shared Project files and local Git excludes. Migration never infers agent
      trust, retains legacy source profiles, and refuses tracked cleanup unless
      the matching one-shot consent flag is supplied.

Reload (re-stage secrets into a running Container) path:
  boxa mcp reload [--global | --project <p>] [--json]
      Re-stage changed MCP secrets into the running in-scope Container(s) via a
      momentary 'docker exec -u 0' of the same staging step container start
      uses — no 'boxa stop'/'start' and no persistent in-container root
      process. The broker re-reads the staged secrets per spawn, so the NEXT MCP
      server session in each Container uses the new value (a server already
      running keeps its environment, the same limit as a restart). Default scope
      = current Project + global: a global secret change reaches every running
      boxa Container (each re-stages only its own scope); --project <p> targets
      that Project's Container only; --global targets every running Container.
      Run this after an 'import --apply' / 'add' that copied a secret value into
      a scope whose Container is already running (the command tells you when).

Secret value path:
  boxa mcp secret set
      In a TTY, pick an entry and missing declared header/environment key for
      the current Project, then enter its value through a hidden prompt.
  boxa mcp secret set <entry> <header> [--json]
      Prompt interactively for a declared secretHeaderKeys value. The value is
      read from the terminal, never from argv, and stored in the host-only MCP
      secret store. A running Container receives it after 'boxa mcp reload'.

Scope flags (import / list):
  (default)                 Current Project record + global Claude config.
  --project <name-or-path>  Scan one explicit Project (repeatable).
  --all                     Scan every known Claude project record.

Common flags:
  --json      Emit machine-readable JSON (valid even when the result is empty).
  -h, --help  Show this help.
EOF
}

# --- Python JSON delegation --------------------------------------------------

# Run the Python core with scripts/ on PYTHONPATH. All JSON serialization of
# the candidate model lives there (single source of truth).
_run_py() {
    PYTHONPATH="$MCP_PY_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 -m mcp.cli "$@"
}

# --- Project-key resolution --------------------------------------------------

# Resolve a `--project <name-or-path>` token to the absolute-path record key
# Claude uses in ~/.claude/.claude.json. Prints the resolved key on stdout.
#
# Resolution order:
#   1. A token that looks like a path (contains '/', starts with '.' or '~',
#      or names an existing directory) -> canonical absolute path.
#   2. Otherwise a bare project name -> match against known Claude project
#      record keys by ADR 0005 sanitized basename. A single match wins; zero
#      or multiple matches is an error (the caller must disambiguate by path).
_resolve_project_key() {
    local token="$1"
    local expanded="$token"

    # Expand a leading ~ to $HOME for path-like tokens. The case patterns use a
    # literal tilde to *detect* the prefix; the substitution does the expanding.
    local tilde='~'
    case "$expanded" in
        "$tilde") expanded="$HOME" ;;
        "$tilde"/*) expanded="$HOME/${expanded#"$tilde"/}" ;;
    esac

    # Path-like tokens: a leading dot or slash, an embedded slash, or a token
    # that names an existing directory. Otherwise treat as a bare project name.
    local is_path=false
    case "$token" in
        .*|/*|*/*) is_path=true ;;
    esac
    if [ "$is_path" = true ] || [ -d "$expanded" ]; then
        # Canonicalize. readlink -f works whether or not the path exists, but a
        # real directory gives the most reliable Claude record key.
        local abs
        abs="$(readlink -f "$expanded" 2>/dev/null || true)"
        [ -z "$abs" ] && abs="$expanded"
        printf '%s\n' "$abs"
        return 0
    fi

    # Bare name: match against Claude record keys by sanitized basename.
    local want
    want="$(boxa::sanitize "$token")"
    local matches=()
    local key base
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        base="$(boxa::sanitize "$(basename "$key")")"
        [ "$base" = "$want" ] && matches+=("$key")
    done < <(_run_py project-keys)

    case "${#matches[@]}" in
        1) printf '%s\n' "${matches[0]}"; return 0 ;;
        0)
            echo "No Claude project record matches name '$token'." >&2
            echo "Pass an explicit path, e.g. --project /home/you/Projekty/$token" >&2
            return 1
            ;;
        *)
            echo "Project name '$token' is ambiguous; matched:" >&2
            printf '  %s\n' "${matches[@]}" >&2
            echo "Disambiguate with an explicit path." >&2
            return 1
            ;;
    esac
}

# Resolve the scope flags shared by `import` and `list --inherited` into the
# argument list passed to the Python core. Inputs (as positional args):
#   $1   subcommand label (for error messages, e.g. "mcp import")
#   $2   "true"/"false" — whether --all was given
#   $3.. the collected --project tokens (may be empty)
# Result is written, one element per line, to stdout so the caller can read it
# into an array. Returns non-zero on a scope error (message already on stderr).
_build_scope_args() {
    local label="$1" all="$2"
    shift 2
    local -a tokens=("$@")

    if [ "$all" = true ]; then
        # --all scans every known Claude project record; explicit --project
        # tokens are redundant in that mode, so flag the conflict rather than
        # silently ignore them.
        if [ "${#tokens[@]}" -gt 0 ]; then
            echo "'$label --all' cannot be combined with --project." >&2
            return 1
        fi
        printf '%s\n' "--all"
        return 0
    fi

    if [ "${#tokens[@]}" -gt 0 ]; then
        # Explicit Project(s): resolve each token to a Claude record key.
        local token key
        for token in "${tokens[@]}"; do
            if ! key="$(_resolve_project_key "$token")"; then
                return 1
            fi
            printf '%s\n%s\n' "--project" "$key"
        done
        return 0
    fi

    # Default scope: current working directory's Project + global config.
    local cwd_key
    cwd_key="$(readlink -f "$PWD" 2>/dev/null || printf '%s' "$PWD")"
    printf '%s\n%s\n' "--project" "$cwd_key"
}

# --- Subcommands -------------------------------------------------------------

cmd_import() {
    local json=false
    local all=false
    local apply=false
    local activate=false
    local all_applicable=false
    local all_changed=false
    local reimport=false
    local yes=false
    local force=false
    local consumer=""
    local conflict=""
    local -a projects=()
    local -a servers=()
    local -a import_ids=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json) json=true ;;
            --all) all=true ;;
            --apply) apply=true ;;
            --activate) apply=true; activate=true ;;
            --all-applicable) all_applicable=true ;;
            --all-changed) all_changed=true; reimport=true ;;
            --reimport) reimport=true ;;
            --yes) yes=true ;;
            --force) force=true ;;
            --for)
                shift
                [ "$#" -gt 0 ] || { echo "'mcp import --for' requires a consumer." >&2; return 2; }
                consumer="$1"
                ;;
            --for=*) consumer="${1#--for=}" ;;
            --conflict)
                shift
                [ "$#" -gt 0 ] || { echo "'mcp import --conflict' requires update or skip." >&2; return 2; }
                conflict="$1"
                ;;
            --conflict=*) conflict="${1#--conflict=}" ;;
            --project)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp import --project' requires a name or path." >&2
                    return 2
                fi
                projects+=("$1")
                ;;
            --project=*) projects+=("${1#--project=}") ;;
            --server)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp import --server' requires a server name." >&2
                    return 2
                fi
                servers+=("$1")
                ;;
            --server=*) servers+=("${1#--server=}") ;;
            --import-id)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp import --import-id' requires an id." >&2
                    return 2
                fi
                import_ids+=("$1")
                ;;
            --import-id=*) import_ids+=("${1#--import-id=}") ;;
            -h|--help) _usage; return 0 ;;
            -*)
                echo "Unknown flag for 'mcp import': $1" >&2
                return 2
                ;;
            *)
                if [ "${#servers[@]}" -gt 0 ]; then
                    echo "'mcp import' takes at most one positional server name; use repeatable --server for more." >&2
                    return 2
                fi
                servers+=("$1")
                ;;
        esac
        shift
    done

    local scope_out
    if ! scope_out="$(_build_scope_args "mcp import" "$all" "${projects[@]+"${projects[@]}"}")"; then
        return 2
    fi
    local -a scope_args=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && scope_args+=("$line")
    done <<< "$scope_out"

    # Selection flags are only meaningful for an apply. Reject them on a plain
    # dry-run rather than silently ignoring the user's choice.
    if [ "$apply" != true ]; then
        if [ "${#import_ids[@]}" -gt 0 ] || [ "$all_applicable" = true ] \
            || [ "$all_changed" = true ] || [ "$reimport" = true ] || [ "$yes" = true ] \
            || [ "$force" = true ] || [ -n "$consumer" ] || [ -n "$conflict" ]; then
            echo "Selection, acceptance, force, and activation flags require --apply or --activate." >&2
            return 2
        fi
        if [ "$json" = true ]; then
            local -a view_args=("${scope_args[@]}")
            local selected_server
            for selected_server in "${servers[@]+"${servers[@]}"}"; do
                view_args+=(--server "$selected_server")
            done
            _run_py import-json "${view_args[@]}"
            return $?
        fi
        # Dry-run by default (ADR 0013 / local-plan-mcp.md decision 10). No writes.
        local -a view_args=("${scope_args[@]}")
        local selected_server
        for selected_server in "${servers[@]+"${servers[@]}"}"; do
            view_args+=(--server "$selected_server")
        done
        _run_py import-text "${view_args[@]}"
        return $?
    fi

    if [ "$activate" = true ]; then
        if [ "$all" = true ] || [ "${#projects[@]}" -ne 1 ]; then
            echo "'mcp import --activate' requires exactly one --project target." >&2
            return 2
        fi
        [ -n "$consumer" ] || {
            echo "'mcp import --activate' requires --for claude, codex, or both." >&2
            return 2
        }
    elif [ -n "$consumer" ]; then
        echo "'mcp import --for' requires --activate." >&2
        return 2
    fi
    if [ "$yes" = true ] && [ "${#servers[@]}" -eq 0 ] \
        && [ "${#import_ids[@]}" -eq 0 ] && [ "$all_applicable" != true ] \
        && [ "$all_changed" != true ]; then
        all_applicable=true
    fi
    cmd_import_apply "$json" "$all_applicable" "$all_changed" "$reimport" "$activate" "$yes" \
        "$force" "$consumer" "$conflict" "${projects[0]:-}" \
        scope_args servers import_ids
}

# Run the apply path of `boxa mcp import --apply`. Selection resolution and
# all writes live in the Python core; this function only decides HOW the user
# selected candidates:
#   * explicit --server/--import-id/--all-applicable -> pass straight through;
#   * interactive TTY with no explicit selection -> run a multi-select picker;
#   * non-interactive with no selection -> fail with examples (no writes).
# Array arguments are passed BY NAME (nameref) to avoid re-quoting issues.
cmd_import_apply() {
    local json="$1" all_applicable="$2" all_changed=false reimport=false
    local activate=false yes=false force=false consumer="" conflict="" target_project=""
    local scope_name servers_name import_ids_name
    if [ "$#" -eq 5 ]; then
        scope_name="$3"
        servers_name="$4"
        import_ids_name="$5"
    elif [ "$#" -eq 11 ]; then
        activate="$3"
        yes="$4"
        force="$5"
        consumer="$6"
        conflict="$7"
        target_project="$8"
        scope_name="$9"
        servers_name="${10}"
        import_ids_name="${11}"
    elif [ "$#" -eq 7 ]; then
        all_changed="$3"
        reimport="$4"
        scope_name="$5"
        servers_name="$6"
        import_ids_name="$7"
    else
        all_changed="$3"
        reimport="$4"
        activate="$5"
        yes="$6"
        force="$7"
        consumer="$8"
        conflict="$9"
        target_project="${10}"
        scope_name="${11}"
        servers_name="${12}"
        import_ids_name="${13}"
    fi
    local -n _scope_args="$scope_name"
    local -n _servers="$servers_name"
    local -n _import_ids="$import_ids_name"

    local -a sel_args=()
    local s
    for s in "${_servers[@]+"${_servers[@]}"}"; do
        sel_args+=("--server" "$s")
    done
    for s in "${_import_ids[@]+"${_import_ids[@]}"}"; do
        sel_args+=("--import-id" "$s")
    done
    [ "$all_applicable" = true ] && sel_args+=("--all-applicable")
    [ "$all_changed" = true ] && sel_args+=("--all-changed")
    [ "$reimport" = true ] && sel_args+=("--reimport")
    [ "$force" = true ] && sel_args+=("--force")
    [ -n "$conflict" ] && sel_args+=("--conflict" "$conflict")

    local have_selection=false
    [ "${#sel_args[@]}" -gt 0 ] && have_selection=true

    if [ "$have_selection" != true ]; then
        # No explicit selection. Interactive -> wizard; non-interactive -> fail.
        if [ -t 0 ] && [ -t 1 ]; then
            local wizard_args wizard_rc
            # Capture the wizard's own exit status: a `! cmd` test would reset
            # $? to 0 inside the then-branch, masking a wizard failure. The
            # wizard prints the resolved --import-id / --override args (one per
            # line) on stdout; all interaction goes to /dev/tty.
            wizard_args="$(_apply_wizard "${_scope_args[@]}")"
            wizard_rc=$?
            if [ "$wizard_rc" -ne 0 ]; then
                return "$wizard_rc"
            fi
            local -a picked_args=()
            local pline
            while IFS= read -r pline; do
                [ -n "$pline" ] && picked_args+=("$pline")
            done <<< "$wizard_args"
            if [ "${#picked_args[@]}" -eq 0 ]; then
                echo "No candidates selected; nothing applied." >&2
                return 0
            fi
            sel_args=("${picked_args[@]}")
        else
            echo "Non-interactive 'mcp import --apply' needs an explicit selection." >&2
            echo "Examples:" >&2
            echo "  boxa mcp import --apply --server context7" >&2
            echo "  boxa mcp import --apply --import-id imp-abcdef123456" >&2
            echo "  boxa mcp import --apply --all-applicable" >&2
            echo "  boxa mcp import --apply --all-changed" >&2
            echo "See 'boxa mcp import' (dry-run) for names and import IDs." >&2
            return 2
        fi
    fi

    if [ "$activate" = true ]; then
        local command="import-activate-text"
        [ "$json" = true ] && command="import-activate-json"
        local -a flow_args=(--target-project "$target_project" --for "$consumer")
        [ "$yes" = true ] && flow_args+=(--yes)
        local rc=0
        _run_py_secret_write "$command" "${flow_args[@]}" \
            "${_scope_args[@]}" "${sel_args[@]}" || rc=$?
        _finish_secret_write
        return "$rc"
    elif [ "$json" = true ]; then
        local rc=0
        _run_py_secret_write apply-json "${_scope_args[@]}" \
            "${sel_args[@]}" || rc=$?
        _finish_secret_write
        return "$rc"
    else
        local rc=0
        _run_py_secret_write apply-text "${_scope_args[@]}" \
            "${sel_args[@]}" || rc=$?
        _finish_secret_write
        return "$rc"
    fi
}

cmd_migrate() {
    local json=false
    local -a mig_args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json) json=true ;;
            --allow-tracked-mcp-json) mig_args+=("$1") ;;
            --allow-tracked-codex-config) mig_args+=("$1") ;;
            -h|--help) _usage; return 0 ;;
            *) echo "Unknown argument for 'mcp migrate': $1" >&2; return 2 ;;
        esac
        shift
    done
    if [ "$json" = true ]; then
        _run_py migrate-json "${mig_args[@]}"
    else
        _run_py migrate-text "${mig_args[@]}"
    fi
}

# =============================================================================
# Secret-change detection prompt (ADR 0014, issue 17)
# =============================================================================
# A secret-writing command (`import --apply` / `add` that copies a secret VALUE)
# stages the value on the host, but a Container that is ALREADY running captured
# its secrets at start — so the new value does not reach it until a re-stage.
# After such a command, if a relevant Container is running, tell the user that
# `boxa mcp reload` will load the staged secrets into it. When no relevant
# Container is running, stay quiet: the value stages at the Container's next
# start, so there is nothing to do now.
#
# The Python core writes the AFFECTED scopes (global / project<TAB><key>, never a
# secret value or env name) to the file named by BOXA_MCP_SCOPES_OUT when a
# write copies a secret value. This function reads that file and decides whether
# any in-scope Container is currently running.

# Print the detection prompt when a relevant Container is running for one of the
# scopes a secret value was just staged into. SECRET-FREE: names scope/Container
# and the exact `boxa mcp reload` command only.
#   $1  path to the scopes file the Python core wrote (may be absent/empty)
_maybe_secret_reload_prompt() {
    local scopes_file="$1"
    [ -f "$scopes_file" ] || return 0

    # docker is required to reach a running Container; without it there is
    # nothing to reload and nothing to prompt about.
    command -v docker >/dev/null 2>&1 || return 0

    # Snapshot the running boxa Containers once.
    local -a running=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && running+=("$line")
    done < <(_running_boxa_containers)
    [ "${#running[@]}" -eq 0 ] && return 0

    local scope key container c
    local prompt_global=false
    local -a prompt_projects=()
    while IFS=$'\t' read -r scope key; do
        [ -n "$scope" ] || continue
        if [ "$scope" = "global" ]; then
            # A global secret change is relevant to EVERY running Container.
            prompt_global=true
        elif [ "$scope" = "project" ] && [ -n "$key" ]; then
            container="$(_container_for_project_key "$key")"
            for c in "${running[@]}"; do
                if [ "$c" = "$container" ]; then
                    prompt_projects+=("${container#boxa-}")
                    break
                fi
            done
        fi
    done < "$scopes_file"

    if [ "$prompt_global" != true ] && [ "${#prompt_projects[@]}" -eq 0 ]; then
        # Secrets were staged on the host, but no in-scope Container is running —
        # stay quiet; they stage at the next Container start.
        return 0
    fi

    echo >&2
    echo "Secrets were staged on the host. A running Container captured its" >&2
    echo "secrets at start, so re-stage to load the new value(s) into it:" >&2
    if [ "$prompt_global" = true ]; then
        echo "  boxa mcp reload            (all running Containers; each its own scope)" >&2
    else
        # Project-only scope(s): name the specific Container(s) to reload.
        local p
        for p in "${prompt_projects[@]}"; do
            echo "  boxa mcp reload --project ${p}" >&2
        done
    fi
    echo "Without a reload, the new value reaches a Container at its next start." >&2
}

# Run a secret-writing Python core command (apply-*/add-*) with the scopes-out
# side channel enabled, then emit the detection prompt. The command and its args
# are passed positionally; the caller handles its exit status via the returned
# code. A temp file collects the affected scopes (secret-free) for the prompt.
#   $1.. the _run_py command and arguments
_run_py_secret_write() {
    local scopes_file rc=0
    scopes_file="$(mktemp "${TMPDIR:-/tmp}/boxa-mcp-scopes.XXXXXX")" || scopes_file=""
    if [ -n "$scopes_file" ]; then
        BOXA_MCP_SCOPES_OUT="$scopes_file" _run_py "$@" || rc=$?
    else
        _run_py "$@" || rc=$?
    fi
    # Stash the path so the caller can prompt after auto-render (which prints its
    # own output); the prompt belongs last so it is the final thing the user sees.
    _LAST_SECRET_SCOPES_FILE="$scopes_file"
    return "$rc"
}

# Clean up and prompt from the last secret-write's scopes file. Call after
# auto-render so the reload hint is the final line. Removes the temp file.
_finish_secret_write() {
    local scopes_file="${_LAST_SECRET_SCOPES_FILE:-}"
    _LAST_SECRET_SCOPES_FILE=""
    if [ -n "$scopes_file" ]; then
        _maybe_secret_reload_prompt "$scopes_file"
        rm -f "$scopes_file"
    fi
}

# =============================================================================
# Interactive apply wizard (ADR 0013 amendment, issue 12)
# =============================================================================
# Drives `boxa mcp import [--all] --apply` in a TTY when no explicit
# selection was given. Flow:
#   1. fzf multi-select (TAB) over the in-scope Container-safe candidates, or a
#      numeric multi-select menu when fzf is absent;
#   2. per selected server, a scope toggle (default = inherited scope, offers
#      the other scope in both directions);
#   3. whenever the resulting scope is project, a project picker built from
#      issue 11's enumerator (source project pre-highlighted when applicable;
#      no default for global->project).
# The wizard PRINTS the resolved Python apply args on stdout — `--import-id <id>`
# for every selection plus `--override <id> <scope> [<key>]` whenever the user
# changed the scope from the inherited one. All interaction reads from /dev/tty
# and writes prompts to /dev/tty, so stdout stays a clean arg stream the caller
# captures. Returns non-zero only on a hard error / explicit cancel.
#
# Apply itself stays in the Python core (continue-on-error via apply_selection):
# the wizard contributes ONLY the selection + per-server override choices.

# Read one line from the controlling terminal regardless of stdin redirection,
# so the scope-toggle prompt works even when the wizard's stdout is captured by
# the caller. Writes the answer to the named output variable.
_tty_read() {
    local -n _out="$1"
    local prompt="$2"
    [ -n "$prompt" ] && printf '%s' "$prompt" >/dev/tty
    IFS= read -r _out </dev/tty || _out=""
}

# The machine KEY of a picker row. Each wizard menu row is "<display><TAB><key>"
# where <key> is an `imp-...` import id or an ABSOLUTE project path; the chosen
# row maps back to its key by taking everything after the final TAB. A tab
# separator (not whitespace) is used so a project path containing spaces is
# preserved verbatim — splitting on whitespace would truncate it. Neither an
# import id nor a host path can contain a literal tab, so the split is exact.
_row_key() {
    printf '%s' "${1##*$'\t'}"
}

# Multi-select the applicable candidates via the shared picker (fzf or the
# numbered fallback). Populates the caller's arrays (by nameref) with the CHOSEN
# ids/names/scopes/project-keys, in menu order, de-duplicated. Returns non-zero
# on a hard error or an empty/cancelled selection.
#   $1..$4  nameref out arrays: ids names scopes pkeys
#   $5..    the Python scope args
_wizard_select() {
    local -n _ids="$1"
    local -n _names="$2"
    local -n _scopes="$3"
    local -n _pkeys="$4"
    local -n _catalog_statuses="$5"
    local -n _placements="$6"
    local -n _reasons="$7"
    shift 7

    local applicable
    applicable="$(_run_py list-applicable-wizard "$@")"
    if [ -z "$applicable" ]; then
        echo "No applicable (container) candidates to import." >&2
        return 1
    fi

    # Index every applicable candidate. Each menu row is "<display><TAB><id>";
    # the import id after the final TAB lets a chosen row map back to its
    # candidate (an import id has no spaces, but the TAB scheme is shared with
    # the project picker, whose key — a host path — can contain spaces).
    local -a all_ids=() all_names=() all_scopes=() all_pkeys=()
    local -a all_catalog_statuses=() all_placements=() all_reasons=()
    local -a menu_new=() menu_changed=() menu=()
    local in_sync_count=0
    local id name scope pkey catalog_status placement reason
    while IFS=$'\t' read -r id name scope pkey catalog_status placement reason; do
        [ -n "$id" ] || continue
        if [ "$catalog_status" = "in-sync" ]; then
            in_sync_count=$((in_sync_count + 1))
            continue
        fi
        all_ids+=("$id")
        all_names+=("$name")
        all_scopes+=("$scope")
        all_pkeys+=("$pkey")
        all_catalog_statuses+=("$catalog_status")
        all_placements+=("${placement:-container}")
        all_reasons+=("$reason")
        local menu_row
        menu_row="$(printf '%-24s %-8s %s' "$name" "$scope" \
            "${placement:-container}")"$'\t'"$id"
        if [ "$catalog_status" = "changed" ]; then
            menu_changed+=("Changed (reimport)  $menu_row")
        else
            menu_new+=("New                 $menu_row")
        fi
    done <<< "$applicable"

    menu=("${menu_new[@]+"${menu_new[@]}"}" "${menu_changed[@]+"${menu_changed[@]}"}")

    echo "New: ${#menu_new[@]}; Changed (reimport): ${#menu_changed[@]}" >/dev/tty
    if [ "$in_sync_count" -gt 0 ]; then
        echo "$in_sync_count entries in sync with host configs" >/dev/tty
    fi
    if [ "${#all_ids[@]}" -eq 0 ]; then
        echo "No new or changed MCP servers; nothing applied." >&2
        return 2
    fi

    local picked
    picked="$(printf '%s\n' "${menu[@]}" | picker::many \
        --prompt "Select MCP servers to import" \
        --header "New and Changed (reimport); choose one or more (q to cancel)")" \
        || { echo "Selection cancelled; nothing applied." >&2; return 2; }

    local -a chosen_ids=()
    local cid line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        cid="$(_row_key "$line")"
        [ -n "$cid" ] && chosen_ids+=("$cid")
    done <<< "$picked"

    if [ "${#chosen_ids[@]}" -eq 0 ]; then
        return 2
    fi

    # Map each chosen id back to its row, de-duplicating while preserving order.
    local i seen
    _ids=(); _names=(); _scopes=(); _pkeys=(); _catalog_statuses=()
    _placements=(); _reasons=()
    for cid in "${chosen_ids[@]}"; do
        seen=false
        for id in "${_ids[@]+"${_ids[@]}"}"; do
            [ "$id" = "$cid" ] && { seen=true; break; }
        done
        [ "$seen" = true ] && continue
        for i in "${!all_ids[@]}"; do
            if [ "${all_ids[$i]}" = "$cid" ]; then
                _ids+=("${all_ids[$i]}")
                _names+=("${all_names[$i]}")
                _scopes+=("${all_scopes[$i]}")
                _pkeys+=("${all_pkeys[$i]}")
                _catalog_statuses+=("${all_catalog_statuses[$i]}")
                _placements+=("${all_placements[$i]}")
                _reasons+=("${all_reasons[$i]}")
                break
            fi
        done
    done
    return 0
}

# Scope toggle for one server. $1 inherited scope ("global"/"project"); prints
# the CHOSEN scope ("global"/"project") on stdout. Default = inherited; pressing
# Enter keeps it, any "y" answer flips to the other scope (both directions).
_wizard_scope_toggle() {
    local inherited="$1" name="$2"
    local other reply
    if [ "$inherited" = "global" ]; then
        other="project"
    else
        other="global"
    fi
    printf 'Server %s — scope [%s]. Switch to %s? [y/N] ' \
        "$name" "$inherited" "$other" >/dev/tty
    _tty_read reply ''
    case "$reply" in
        y|Y|yes|YES) printf '%s\n' "$other" ;;
        *) printf '%s\n' "$inherited" ;;
    esac
}

# Project picker for a project-scoped server, via the shared picker. Enumerates
# issue 11's targets; the source project (when present) is offered as the FIRST
# option so the user can pick it with one keystroke (pre-highlight in the no-fzf
# fallback; fzf has no default-row API, so the source is simply listed first).
# Prints the chosen absolute project key on stdout. Returns non-zero on cancel /
# no targets.
#   $1  the server name (for the prompt)
#   $2  the default (source) project key, or "" for no default
_wizard_project_picker() {
    local name="$1" default_key="$2"
    local targets
    # Let stderr through: project-targets-text reports basename collisions
    # there (two host paths sanitizing to one name, omitted from stdout for
    # explicit disambiguation). Swallowing it would leave a user unable to see
    # WHY a valid initialized Project is missing from the picker.
    targets="$(_run_py project-targets-text)"
    # project-targets-text prints a human note (not tab-separated) when empty;
    # rows with a tab are real "<name>\t<key>" targets.
    local -a tkeys=() tnames=()
    local tname tkey
    while IFS=$'\t' read -r tname tkey; do
        [ -n "$tkey" ] || continue
        tnames+=("$tname")
        tkeys+=("$tkey")
    done <<< "$targets"

    if [ "${#tkeys[@]}" -eq 0 ]; then
        echo "No initialized boxa Projects to target for '$name'." >&2
        echo "A target must be known to Claude AND have a boxa-<name>-history volume." >&2
        echo "Initialize the Project (run 'boxa <name>' once) and re-run import." >&2
        return 2
    fi

    # Build the menu as "<display><TAB><key>" rows. The absolute key after the
    # final TAB is recovered verbatim by _row_key even when the host path
    # contains spaces (a plain trailing token would be truncated). The source
    # project, when it is among the targets, is prepended as a first-option so it
    # is the obvious default; the remaining targets follow in enumerator order.
    local -a menu=()
    local i default_row=""
    for i in "${!tkeys[@]}"; do
        local row
        row="$(printf '%-20s' "${tnames[$i]}")"$'\t'"${tkeys[$i]}"
        if [ -n "$default_key" ] && [ "${tkeys[$i]}" = "$default_key" ]; then
            default_row="$row"
            continue
        fi
        menu+=("$row")
    done

    local picked
    if [ -n "$default_row" ]; then
        picked="$(printf '%s\n' "${menu[@]+"${menu[@]}"}" | picker::one \
            --prompt "Pick the boxa Project for '$name'" \
            --header "Source project is the default (a)" \
            --first-option "$default_row")" \
            || { echo "No Project chosen for '$name'." >&2; return 2; }
    else
        picked="$(printf '%s\n' "${menu[@]}" | picker::one \
            --prompt "Pick the boxa Project for '$name'" \
            --header "Choose a target Project (q to cancel)")" \
            || { echo "No Project chosen for '$name'." >&2; return 2; }
    fi

    local key
    key="$(_row_key "$picked")"
    if [ -z "$key" ]; then
        echo "No Project chosen for '$name'." >&2
        return 2
    fi
    printf '%s\n' "$key"
}

# Pick one or more initialized Projects for an interactive catalog activation.
# The current Project is listed as the first/default option when available.
_activation_project_picker() {
    local default_key targets
    default_key="$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")"
    targets="$(_run_py activation-project-targets-text --current "$default_key")"

    local -a menu=()
    local default_row="" name key row
    while IFS=$'\t' read -r name key; do
        [ -n "$key" ] || continue
        row="$(printf '%-20s' "$name")"$'\t'"$key"
        if [ "$key" = "$default_key" ]; then
            default_row="$row"
        else
            menu+=("$row")
        fi
    done <<< "$targets"
    if [ -z "$default_row" ] && [ "${#menu[@]}" -eq 0 ]; then
        echo "No initialized boxa Projects are available for activation." >&2
        return 2
    fi

    local picked
    if [ -n "$default_row" ]; then
        picked="$(printf '%s\n' "${menu[@]+"${menu[@]}"}" | picker::many \
            --prompt "Activate in Projects" \
            --header "Choose one or more Projects; current Project is the default (a)" \
            --first-option "$default_row")" \
            || { echo "No Project chosen; nothing activated." >&2; return 2; }
    else
        picked="$(printf '%s\n' "${menu[@]}" | picker::many \
            --prompt "Activate in Projects" \
            --header "Choose one or more Projects")" \
            || { echo "No Project chosen; nothing activated." >&2; return 2; }
    fi

    while IFS= read -r row; do
        key="$(_row_key "$row")"
        [ -n "$key" ] && printf '%s\n' "$key"
    done <<< "$picked"
}

# Full apply wizard. Prints the resolved Python apply args (one per line:
# --import-id <id> ... and --override <id> <scope> [<key>] ...) on stdout. All
# interaction is on /dev/tty. Returns non-zero on a hard error or a cancel.
_apply_wizard() {
    local -a sel_ids=() sel_names=() sel_scopes=() sel_pkeys=()
    local -a sel_catalog_statuses=() sel_placements=() sel_reasons=()
    local rc
    _wizard_select sel_ids sel_names sel_scopes sel_pkeys sel_catalog_statuses \
        sel_placements sel_reasons "$@"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        # rc 1 = no applicable candidates; rc 2 = empty/cancelled selection.
        if [ "$rc" -eq 2 ]; then
            echo "No candidates selected; nothing applied." >&2
            return 0
        fi
        return "$rc"
    fi

    local -a out_args=()
    local i id name inherited pkey chosen_scope chosen_key conflict_reply force_reply
    local reimport_reply
    for i in "${!sel_ids[@]}"; do
        id="${sel_ids[$i]}"
        name="${sel_names[$i]}"
        inherited="${sel_scopes[$i]}"
        pkey="${sel_pkeys[$i]}"

        if [ "${sel_catalog_statuses[$i]}" = "changed" ]; then
            printf "'%s' differs from catalog fields: %s. Reimport with host values? [y/N] " \
                "$name" "${sel_reasons[$i]}" >/dev/tty
            _tty_read reimport_reply ''
            case "$reimport_reply" in
                y|Y|yes|YES) out_args+=("--reimport") ;;
                *) continue ;;
            esac
        fi

        if [ "${sel_placements[$i]}" = "host-only" ]; then
            printf "'%s' is host-only: %s. Force import anyway? [y/N] " \
                "$name" "${sel_reasons[$i]}" >/dev/tty
            _tty_read force_reply ''
            case "$force_reply" in
                y|Y|yes|YES) out_args+=("--force") ;;
                *) continue ;;
            esac
        fi

        chosen_scope="$(_wizard_scope_toggle "$inherited" "$name")"

        out_args+=("--import-id" "$id")
        if [ "${sel_catalog_statuses[$i]}" = "conflict" ]; then
            printf "'%s' differs from the same-named catalog entry. Update it? [y/N] " \
                "$name" >/dev/tty
            _tty_read conflict_reply ''
            case "$conflict_reply" in
                y|Y|yes|YES) out_args+=("--catalog-conflict" "$id" "update") ;;
                *) out_args+=("--catalog-conflict" "$id" "skip") ;;
            esac
        fi

        if [ "$chosen_scope" = "global" ]; then
            # An override is needed only when the scope actually changed.
            if [ "$inherited" != "global" ]; then
                out_args+=("--override" "$id" "global")
            fi
            continue
        fi

        # Resulting scope is project -> always run the project picker. The
        # source project (when the server came from a project) is the default.
        if ! chosen_key="$(_wizard_project_picker "$name" "$pkey")"; then
            return 2
        fi
        # Emit a project override whenever the scope changed (global->project)
        # OR the chosen project key differs from the inherited source key. When
        # the user keeps the inherited project unchanged, no override is needed.
        if [ "$inherited" != "project" ] || [ "$chosen_key" != "$pkey" ]; then
            out_args+=("--override" "$id" "project" "$chosen_key")
        fi
    done

    printf '%s\n' "${out_args[@]}"
}

cmd_list() {
    local inherited=false
    local json=false
    local all=false
    local -a projects=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --inherited) inherited=true ;;
            --json) json=true ;;
            --all) all=true ;;
            --project)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp list --project' requires a name or path." >&2
                    return 2
                fi
                projects+=("$1")
                ;;
            --project=*) projects+=("${1#--project=}") ;;
            -h|--help) _usage; return 0 ;;
            -*)
                echo "Unknown flag for 'mcp list': $1" >&2
                return 2
                ;;
            *)
                echo "Unexpected argument for 'mcp list': $1" >&2
                return 2
                ;;
        esac
        shift
    done

    local scope_out
    if ! scope_out="$(_build_scope_args "mcp list" "$all" "${projects[@]+"${projects[@]}"}")"; then
        return 2
    fi
    local -a scope_args=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && scope_args+=("$line")
    done <<< "$scope_out"

    if [ "$inherited" = true ]; then
        # Readable inherited table (issue 04): provider, scope, status/placement,
        # runtime, and source columns. Same candidate shape and scope as import,
        # no writes.
        if [ "$json" = true ]; then
            _run_py list-inherited-json "${scope_args[@]}"
            return $?
        fi
        _run_py list-inherited-text "${scope_args[@]}"
        return $?
    fi

    # ADR 0021 effective Project view: catalog availability is distinct from
    # this Project's explicit activation. Legacy profile list remains available
    # through the Python core until migration issue 08.
    if [ "$all" != true ] && [ "${#scope_args[@]}" -eq 2 ] \
        && [ "${scope_args[0]}" = "--project" ]; then
        if [ "$json" = true ]; then
            _run_py catalog-effective-list-json "${scope_args[@]}"
        else
            _run_py catalog-effective-list-text "${scope_args[@]}"
        fi
        return $?
    fi

    # Effective MCP profile view (issue 08): global + Project entries, with a
    # Project entry shadowing a same-named global entry for the current Project.
    # --all shows global plus every project profile. Reads profile state only;
    # no writes. NAME/SCOPE/STATUS/PLACEMENT/RUNTIME/SOURCE columns.
    if [ "$json" = true ]; then
        _run_py list-json "${scope_args[@]}"
        return $?
    fi
    _run_py list-text "${scope_args[@]}"
}

# Parse the shared scope flags for the lifecycle commands (enable / disable /
# remove). Resolves an optional `--project <name-or-path>` token to a Claude
# record key and validates mutual exclusion with `--global`. Outputs, one per
# line, the resolved Python args (e.g. `--project`, `<key>`, or `--global`)
# followed by the positional server name. Returns non-zero on a parse error
# (message already on stderr). `--purge` (remove only) is forwarded verbatim.
#   $1  subcommand label for error messages
#   $2  "true"/"false" — whether --purge is accepted for this command
#   $3.. the raw subcommand argv
_lifecycle_collect() {
    local label="$1" allow_purge="$2"
    shift 2
    local is_global=false purge=false project_token="" name=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --global) is_global=true ;;
            --purge)
                if [ "$allow_purge" != true ]; then
                    echo "'$label' does not accept --purge." >&2
                    return 2
                fi
                purge=true
                ;;
            --project)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'$label --project' requires a name or path." >&2
                    return 2
                fi
                project_token="$1"
                ;;
            --project=*)
                project_token="${1#--project=}"
                if [ -z "$project_token" ]; then
                    echo "'$label --project=' requires a non-empty name or path." >&2
                    return 2
                fi
                ;;
            -*)
                echo "Unknown flag for '$label': $1" >&2
                return 2
                ;;
            *)
                if [ -n "$name" ]; then
                    echo "'$label' takes exactly one server name." >&2
                    return 2
                fi
                name="$1"
                ;;
        esac
        shift
    done

    if [ -z "$name" ]; then
        echo "'$label' requires a server name." >&2
        return 2
    fi
    if [ "$is_global" = true ] && [ -n "$project_token" ]; then
        echo "'$label': --global and --project are mutually exclusive." >&2
        return 2
    fi

    if [ -n "$project_token" ]; then
        local key
        if ! key="$(_resolve_project_key "$project_token")"; then
            return 2
        fi
        printf '%s\n%s\n' "--project" "$key"
    elif [ "$is_global" = true ]; then
        printf '%s\n' "--global"
    fi
    [ "$purge" = true ] && printf '%s\n' "--purge"
    printf '%s\n' "$name"
}

# Read a newline-delimited arg list (from _lifecycle_collect) into the named
# array. Empty lines are dropped.
_read_lines_into() {
    local -n _dest="$1"
    local payload="$2"
    local line
    _dest=()
    while IFS= read -r line; do
        [ -n "$line" ] && _dest+=("$line")
    done <<< "$payload"
}

cmd_enable() {
    local json=false
    local -a raw=()
    local a
    for a in "$@"; do
        case "$a" in
            -h|--help) _usage; return 0 ;;
            --json) json=true ;;
            *) raw+=("$a") ;;
        esac
    done
    local out rc
    out="$(_lifecycle_collect "mcp enable" false "${raw[@]+"${raw[@]}"}")"
    rc=$?
    [ "$rc" -ne 0 ] && return "$rc"
    local -a args=()
    _read_lines_into args "$out"
    if [ "$json" = true ]; then
        _run_py enable-json "${args[@]}"
        return $?
    fi
    _run_py enable-text "${args[@]}"
}

cmd_disable() {
    local json=false
    local -a raw=()
    local a
    for a in "$@"; do
        case "$a" in
            -h|--help) _usage; return 0 ;;
            --json) json=true ;;
            *) raw+=("$a") ;;
        esac
    done
    local out rc
    out="$(_lifecycle_collect "mcp disable" false "${raw[@]+"${raw[@]}"}")"
    rc=$?
    [ "$rc" -ne 0 ] && return "$rc"
    local -a args=()
    _read_lines_into args "$out"
    if [ "$json" = true ]; then
        _run_py disable-json "${args[@]}"
        return $?
    fi
    _run_py disable-text "${args[@]}"
}

cmd_remove() {
    local json=false
    local -a raw=()
    local a
    for a in "$@"; do
        case "$a" in
            -h|--help) _usage; return 0 ;;
            --json) json=true ;;
            *) raw+=("$a") ;;
        esac
    done
    local has_legacy_scope=false
    for a in "${raw[@]}"; do
        case "$a" in --global|--project|--project=*) has_legacy_scope=true ;; esac
    done
    if [ "$has_legacy_scope" != true ]; then
        if [ "${#raw[@]}" -ne 1 ]; then
            echo "'mcp remove' takes exactly one catalog entry name or id." >&2
            return 2
        fi
        local -a catalog_args=("${raw[0]}")
        if [ "$json" = true ]; then
            _run_py catalog-remove-json "${catalog_args[@]}"
        else
            _run_py catalog-remove-text "${catalog_args[@]}"
        fi
        return $?
    fi
    local out rc
    out="$(_lifecycle_collect "mcp remove" true "${raw[@]+"${raw[@]}"}")"
    rc=$?
    [ "$rc" -ne 0 ] && return "$rc"
    local -a args=()
    _read_lines_into args "$out"

    # Runtime/secret purge is never implicit (ADR 0013 decision 20). If --purge
    # was not passed but the server has scoped secrets, require an interactive
    # confirmation; refuse non-interactively so a scripted remove never silently
    # leaves (or, with a future runtime, deletes) credential state unreviewed.
    local has_purge=false
    local arg
    for arg in "${args[@]}"; do
        [ "$arg" = "--purge" ] && has_purge=true
    done
    if [ "$has_purge" != true ]; then
        local secret_keys
        secret_keys="$(_run_py remove-secret-check "${args[@]}")" || return $?
        if [ -n "$secret_keys" ]; then
            local key_list
            # Join the newline-delimited key NAMES into a readable, comma-free
            # single line for the prompt (names only; never values).
            key_list="$(printf '%s' "$secret_keys" | tr '\n' ' ')"
            echo "Server has scoped secret(s) in the boxa secret store: ${key_list}" >&2
            echo "Removing the profile entry will leave these secrets orphaned." >&2
            if [ -t 0 ] && [ -t 1 ]; then
                printf 'Also purge the stored secret(s)? [y/N] ' >&2
                local reply
                IFS= read -r reply || reply=""
                case "$reply" in
                    y|Y|yes|YES) args+=("--purge") ;;
                    *) echo "Keeping secrets; removing profile entry only." >&2 ;;
                esac
            else
                echo "Re-run with --purge to delete them, or accept they remain." >&2
            fi
        fi
    fi

    if [ "$json" = true ]; then
        _run_py remove-json "${args[@]}"
        return $?
    fi
    _run_py remove-text "${args[@]}"
}

# --- reload (re-stage secrets into running Containers) -----------------------

# `boxa mcp reload [--global|--project <p>] [--json]` re-stages changed MCP
# secrets into the running in-scope Container(s) via a momentary root exec of the
# reusable staging step (no stop/start, no persistent root — ADR 0003/0014).
# Targeting and the docker exec live in the Python core (mcp.reload), so it is
# unit-tested with a mocked docker; this front-end only resolves the scope and
# (for a Project) the target Container name.
#   * default / --global -> every running boxa Container (each re-stages only
#     its own scope: global + its own Project — never a foreign Project's);
#   * --project <p>       -> that Project's Container only.
cmd_reload() {
    local json=false is_global=false project_token=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) _usage; return 0 ;;
            --json) json=true ;;
            --global) is_global=true ;;
            --project)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp reload --project' requires a name or path." >&2
                    return 2
                fi
                project_token="$1"
                ;;
            --project=*)
                project_token="${1#--project=}"
                if [ -z "$project_token" ]; then
                    echo "'mcp reload --project=' requires a non-empty name or path." >&2
                    return 2
                fi
                ;;
            -*)
                echo "Unknown flag for 'mcp reload': $1" >&2
                return 2
                ;;
            *)
                echo "Unexpected argument for 'mcp reload': $1" >&2
                return 2
                ;;
        esac
        shift
    done

    if [ "$is_global" = true ] && [ -n "$project_token" ]; then
        echo "'mcp reload': --global and --project are mutually exclusive." >&2
        return 2
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo "'mcp reload' re-stages secrets into a running Container and needs Docker." >&2
        return 2
    fi

    local py_cmd
    if [ "$json" = true ]; then
        py_cmd="reload-json"
    else
        py_cmd="reload-text"
    fi

    if [ -n "$project_token" ]; then
        # A Project reload targets that Project's Container only. Resolve the
        # token to its absolute key, derive the container name from the sanitized
        # basename (ADR 0005), and pass a display label for the summary.
        local key container label
        if ! key="$(_resolve_project_key "$project_token")"; then
            return 2
        fi
        container="$(_container_for_project_key "$key")"
        label="${container#boxa-}"
        _run_py "$py_cmd" --scope project --container "$container" \
            --project-label "$label"
        return $?
    fi

    # Default scope (and --global): re-stage every running boxa Container. Each
    # one stages only its OWN scope (global + its own Project), so a global secret
    # change reaches all of them without leaking one Project's secrets to another,
    # AND the current Project's Container is covered too.
    _run_py "$py_cmd" --scope global
}

cmd_doctor() {
    local json=false
    local -a args=()
    local a
    for a in "$@"; do
        case "$a" in
            --json) json=true ;;
            -h|--help) _usage; return 0 ;;
            *) args+=("$a") ;;
        esac
    done
    if [ "$json" = true ]; then
        _run_py doctor-json "${args[@]+"${args[@]}"}"
        return $?
    fi
    _run_py doctor-text "${args[@]+"${args[@]}"}"
}

# --- install (materialize) ---------------------------------------------------

# Path to the boxa entrypoint, so install can drive `boxa allow-for` and
# the container lifecycle (start/stop) for a global materialization. mcp-cli.sh
# lives in scripts/; the entrypoint is docker-run.sh at the repo root.
_BOXA_ENTRYPOINT="$BOXA_DIR/docker-run.sh"

# List RUNNING user boxa project containers (one name per line). Mirrors
# docker-run.sh's list_boxa_container_names but without sourcing that file:
# shared infrastructure containers (boxa_traefik, boxa_dns, …) are excluded
# by the `boxa-` project-name prefix the user containers carry.
_running_boxa_containers() {
    docker ps --filter "name=^boxa-" --format '{{.Names}}' 2>/dev/null || true
}

# List EXISTING (any state) user boxa project containers, one name per line.
_existing_boxa_containers() {
    docker ps -a --filter "name=^boxa-" --format '{{.Names}}' 2>/dev/null || true
}

# Resolve the target container for a GLOBAL install (ADR 0013 / plan decision
# 15). A global server installs into shared runtime, but the install runs INSIDE
# an existing boxa runtime — never by creating a new Project in an unintended
# location. Rules:
#   * exactly one RUNNING container          -> use it;
#   * multiple running + TTY                 -> picker;
#   * multiple running + non-interactive     -> require --project;
#   * none running but exactly one EXISTING  -> caller starts it, runs, stops;
#   * none running, multiple existing + TTY  -> picker;
#   * none running, multiple existing, non-TTY -> require --project;
#   * no boxa container exists at all      -> require an explicit --project.
# Prints "<state>\t<container>" on stdout (state is "running" or "stopped") so
# the caller can read BOTH out of the command substitution — a global assignment
# would be lost in the subshell. Returns non-zero (message on stderr) when the
# user must disambiguate or provide a target.
_resolve_global_container() {
    local -a running=() existing=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && running+=("$line")
    done < <(_running_boxa_containers)
    while IFS= read -r line; do
        [ -n "$line" ] && existing+=("$line")
    done < <(_existing_boxa_containers)

    if [ "${#existing[@]}" -eq 0 ]; then
        echo "No boxa Project container exists yet." >&2
        echo "A global MCP install runs inside an existing boxa runtime; it will not" >&2
        echo "create a new Project in an unintended location. Create or name a Project:" >&2
        echo "  boxa mcp install <server> --project <name-or-path>" >&2
        return 2
    fi

    if [ "${#running[@]}" -eq 1 ]; then
        printf 'running\t%s\n' "${running[0]}"
        return 0
    fi
    if [ "${#running[@]}" -gt 1 ]; then
        if [ -t 0 ] && [ -t 1 ]; then
            _pick_container "running" "${running[@]}"
            return $?
        fi
        echo "Multiple running boxa containers; choose one with --project <name>:" >&2
        printf '  %s\n' "${running[@]}" >&2
        return 2
    fi

    # None running. Fall back to existing (stopped) containers.
    if [ "${#existing[@]}" -eq 1 ]; then
        printf 'stopped\t%s\n' "${existing[0]}"
        return 0
    fi
    if [ -t 0 ] && [ -t 1 ]; then
        _pick_container "stopped" "${existing[@]}"
        return $?
    fi
    echo "No running boxa container and multiple stopped Projects exist." >&2
    echo "Choose one with --project <name>:" >&2
    printf '  %s\n' "${existing[@]}" >&2
    return 2
}

# Interactive container picker. $1 is the state label ("running"/"stopped"); the
# rest are container names. Prints "<state>\t<chosen-name>" on stdout (prompts go
# to stderr so the command substitution captures only the result line).
_pick_container() {
    local state="$1"
    shift
    local -a names=("$@")
    echo "Select a boxa container for the global MCP install:" >&2
    local i
    for i in "${!names[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${names[$i]}" >&2
    done
    printf 'Enter a number (blank to cancel): ' >&2
    local reply
    IFS= read -r reply || reply=""
    case "$reply" in
        ''|*[!0-9]*)
            echo "No selection; nothing installed." >&2
            return 2
            ;;
    esac
    local idx="$((reply - 1))"
    if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#names[@]}" ]; then
        echo "Out-of-range selection; nothing installed." >&2
        return 2
    fi
    printf '%s\t%s\n' "$state" "${names[$idx]}"
}

# Map a resolved project key (absolute path) to the boxa container name. The
# Project name is the sanitized basename of the key (ADR 0005); the container is
# `boxa-<name>`. Reuses the shared naming helper sourced at the top.
_container_for_project_key() {
    local key="$1"
    boxa::names_from_token "$(basename "$key")"
    printf '%s\n' "$BOXA_CONTAINER_NAME"
}

# Run the Python install core ON THE HOST, pointing its runtime commands INTO
# the target container. The canonical MCP profile lives on the host
# (~/.config/boxa/mcp), which is NOT bind-mounted into containers — so the
# profile read/rewrite must happen host-side. Only the install COMMANDS
# (npm install -g, docker pull, the post-install binary probe) must run in the
# container, where the runtime lives. The core's --exec-prefix prepends a
# `docker exec` to every such command so the split is honoured.
#   $1   container name
#   $2   "install-json" | "install-text"
#   $3.. the Python core scope+name args (e.g. --global <name>)
_run_install_in_container() {
    local container="$1" py_cmd="$2"
    shift 2
    # The prefix runs install commands as the node user inside the container.
    local exec_prefix="docker exec -u node $container"
    _run_py "$py_cmd" --exec-prefix "$exec_prefix" "$@"
}

cmd_install() {
    local json=false is_global=false keep_window=false
    local project_token="" name="" allow_for=""
    local catalog_install=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) _usage; return 0 ;;
            --json) json=true ;;
            --global) is_global=true ;;
            --keep-window) keep_window=true ;;
            --allow-for)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp install --allow-for' requires a number of minutes." >&2
                    return 2
                fi
                allow_for="$1"
                ;;
            --allow-for=*) allow_for="${1#--allow-for=}" ;;
            --project)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp install --project' requires a name or path." >&2
                    return 2
                fi
                project_token="$1"
                ;;
            --project=*) project_token="${1#--project=}" ;;
            -*)
                echo "Unknown flag for 'mcp install': $1" >&2
                return 2
                ;;
            *)
                if [ -n "$name" ]; then
                    echo "'mcp install' takes exactly one server name." >&2
                    return 2
                fi
                name="$1"
                ;;
        esac
        shift
    done

    if [ -z "$name" ]; then
        echo "'mcp install' requires a server name." >&2
        echo "Usage: boxa mcp install <server> [--global|--project <p>] [--allow-for <min>] [--keep-window]" >&2
        return 2
    fi
    if [ "$is_global" = true ] && [ -n "$project_token" ]; then
        echo "'mcp install': --global and --project are mutually exclusive." >&2
        return 2
    fi
    if [ -n "$allow_for" ] && ! [[ "$allow_for" =~ ^[1-9][0-9]*$ ]]; then
        echo "'mcp install --allow-for' minutes must be a positive integer (got: '$allow_for')." >&2
        return 2
    fi
    if [ "$keep_window" = true ] && [ -z "$allow_for" ]; then
        echo "'mcp install --keep-window' only applies with --allow-for." >&2
        return 2
    fi

    # New catalog semantics are the default. An explicit --global remains the
    # legacy profile escape hatch through migration issue 08. With --project,
    # a catalog identity/name wins; an unknown token falls back to the legacy
    # Project profile so existing automation keeps working.
    if [ "$is_global" = false ]; then
        if [ -z "$project_token" ] || _run_py catalog-resolve "$name" >/dev/null 2>&1; then
            catalog_install=true
        fi
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo "'mcp install' materializes runtime inside a Container and needs Docker." >&2
        return 2
    fi

    # Resolve the target container and the Python-core scope args. A project
    # install targets that Project's container and passes --project <key>; a
    # global install runs inside a resolved boxa runtime and passes --global.
    local container="" project_key="" started_here=false target_state=""
    local -a scope_args=()
    if [ "$catalog_install" = true ]; then
        if [ -z "$project_token" ]; then
            project_token="$PWD"
        fi
        if ! project_key="$(_resolve_project_key "$project_token")"; then
            return 2
        fi
        container="$(_container_for_project_key "$project_key")"
        if ! _running_boxa_containers | grep -qx "$container"; then
            echo "Target Boxa '$container' is not running; MCP install never starts it." >&2
            echo "Start the Project explicitly, then rerun the install." >&2
            return 1
        fi
        target_state="running"
    elif [ -n "$project_token" ]; then
        if ! project_key="$(_resolve_project_key "$project_token")"; then
            return 2
        fi
        container="$(_container_for_project_key "$project_key")"
        scope_args=("--project" "$project_key")
        if _running_boxa_containers | grep -qx "$container"; then
            target_state="running"
        elif _existing_boxa_containers | grep -qx "$container"; then
            target_state="stopped"
        else
            echo "No boxa container named '$container' for Project '$project_token'." >&2
            echo "Start it first: boxa $(basename "$project_key")" >&2
            return 2
        fi
    else
        # _resolve_global_container prints "<state>\t<container>" so BOTH the
        # state and the name survive the command substitution (a global var set
        # inside it would be lost to the subshell).
        local resolved
        if ! resolved="$(_resolve_global_container)"; then
            return 2
        fi
        target_state="${resolved%%$'\t'*}"
        container="${resolved#*$'\t'}"
        scope_args=("--global")
    fi

    # Start a stopped target so the install can run inside it; stop it again
    # afterward only if we started it (leave a user's running container alone).
    # `docker start` resumes the EXISTING container without attaching a shell,
    # which is what a background install needs (a bare `boxa <name>` attaches
    # an interactive session). The container's entrypoint re-runs the firewall
    # setup on start, so the runtime is ready for the install + Allow-for window.
    if [ "$target_state" = "stopped" ]; then
        echo "Starting container '$container' for the install..." >&2
        if ! docker start "$container" >/dev/null 2>&1; then
            echo "Failed to start container '$container'." >&2
            return 1
        fi
        started_here=true
        # Give the entrypoint a moment to finish firewall/runtime setup before
        # the install reaches for the network.
        sleep 2
    fi

    # Open an Allow-for window before the install when requested, so the
    # network-fetching install can reach package registries that are not yet on
    # the Allowlist, and the window's harvest log records what it hit.
    local window_opened=false
    if [ -n "$allow_for" ]; then
        echo "Opening an Allow-for window (${allow_for} min) for '${container#boxa-}'..." >&2
        if "$_BOXA_ENTRYPOINT" allow-for "$allow_for" "${container#boxa-}"; then
            window_opened=true
        else
            echo "Failed to open the Allow-for window; continuing without it." >&2
            echo "The install may fail on blocked domains; review with 'boxa blocked'." >&2
        fi
    fi

    # Run the install inside the container.
    local py_cmd rc=0
    if [ "$catalog_install" = true ] && [ "$json" = true ]; then
        py_cmd="catalog-install-json"
    elif [ "$catalog_install" = true ]; then
        py_cmd="catalog-install-text"
    elif [ "$json" = true ]; then
        py_cmd="install-json"
    else
        py_cmd="install-text"
    fi
    if [ "$catalog_install" = true ]; then
        _run_py "$py_cmd" "$name" --project "$project_key" || rc=$?
    else
        _run_install_in_container "$container" "$py_cmd" "${scope_args[@]}" "$name" || rc=$?
    fi

    # Close the Allow-for window after the attempt by default so the harvest log
    # is produced immediately; --keep-window leaves it open until normal expiry.
    if [ "$window_opened" = true ]; then
        if [ "$keep_window" = true ]; then
            echo "Leaving the Allow-for window open (--keep-window) until it expires." >&2
        else
            echo "Closing the Allow-for window (harvest log produced)..." >&2
            "$_BOXA_ENTRYPOINT" allow-for --stop "${container#boxa-}" \
                || echo "Note: could not close the window; it will expire on its own." >&2
        fi
    fi

    # Stop a container we started for the install (global install into a stopped
    # Project), leaving the user's environment as we found it.
    if [ "$started_here" = true ]; then
        echo "Stopping container '$container' (started only for the install)..." >&2
        "$_BOXA_ENTRYPOINT" stop "${container#boxa-}" >/dev/null 2>&1 \
            || echo "Note: could not stop '$container'; stop it manually if needed." >&2
    fi

    if [ "$rc" -eq 4 ]; then
        # Blocked-network exit from the Python core already printed the
        # boxa blocked / rerun guidance; surface a short pointer too.
        echo "Install hit the default-deny firewall. See the guidance above." >&2
    fi
    return "$rc"
}

# =============================================================================
# add (record a new Boxa MCP server) — ADR 0013 amendment, issue 13
# =============================================================================
# `boxa mcp add <name> [--global|--project <p>] -- <command spec...>` records
# an EXPLICIT new server (distinct from `import`, which discovers inherited
# ones). Scope is always an explicit decision: a flag sets it non-interactively;
# in a TTY with no flag the SAME project picker the import wizard uses offers
# global + every boxa Project (current pre-highlighted); without a TTY and no
# flag it fails with examples. A picked Project resolves to its absolute host key
# through issue 11's shared resolver/enumerator — never a bare name.

# True when a resolved project key names an INITIALIZED boxa Project — i.e. it
# appears in issue 11's volume-gated enumerator (Claude-known AND has a
# `boxa-<name>-history` volume), the same set the interactive picker offers.
# Compares the FULL path (not just the basename): two different paths can share
# a basename, so a basename match would wrongly accept an unrelated path. Both
# sides are canonicalized with `readlink -f` so a symlink difference between
# `_resolve_project_key`'s key and Claude's stored record key still matches.
#   $1  the resolved absolute project key
_project_target_exists() {
    local want tname tkey canon
    want="$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")"
    while IFS=$'\t' read -r tname tkey; do
        [ -n "$tkey" ] || continue
        canon="$(readlink -f "$tkey" 2>/dev/null || printf '%s' "$tkey")"
        [ "$canon" = "$want" ] && return 0
    done < <(_run_py project-targets-text)
    return 1
}

# Interactive scope picker for `add`: offers a synthetic "global" row first, then
# every boxa Project (issue 11's enumerator), with the CURRENT directory's
# Project pre-highlighted when it is among the targets. Prints the resolved
# scope args (one per line: "--global", or "--project" then the absolute key) on
# stdout; all interaction is on /dev/tty. Returns non-zero on cancel.
#   $1  the server name (for the prompt)
_add_scope_picker() {
    local name="$1"
    local targets
    # Let stderr through so basename collisions are visible (same rationale as
    # the import wizard's project picker).
    targets="$(_run_py project-targets-text)"

    # The current directory's Project key, used to pre-highlight its row.
    local cwd_key
    cwd_key="$(readlink -f "$PWD" 2>/dev/null || printf '%s' "$PWD")"

    # A sentinel key marks the synthetic global row so _row_key recovers it.
    local global_key='<global>'
    local -a menu=()
    menu+=("$(printf '%-20s' "global")"$'\t'"$global_key")

    # Build the Project rows. The current directory's Project, when present, is
    # held out as the pre-highlighted FIRST option (passed via --first-option)
    # rather than added to the menu body, so it is not listed twice (the picker
    # prepends first-options to the item list).
    local default_row="" tname tkey
    while IFS=$'\t' read -r tname tkey; do
        [ -n "$tkey" ] || continue
        local row
        row="$(printf '%-20s' "$tname")"$'\t'"$tkey"
        if [ "$tkey" = "$cwd_key" ]; then
            default_row="$row"
            continue
        fi
        menu+=("$row")
    done <<< "$targets"

    local picked
    if [ -n "$default_row" ]; then
        picked="$(printf '%s\n' "${menu[@]}" | picker::one \
            --prompt "Pick the scope for '$name'" \
            --header "global, or a boxa Project (current is the default)" \
            --first-option "$default_row")" \
            || { echo "No scope chosen for '$name'; nothing added." >&2; return 2; }
    else
        picked="$(printf '%s\n' "${menu[@]}" | picker::one \
            --prompt "Pick the scope for '$name'" \
            --header "global, or a boxa Project (q to cancel)")" \
            || { echo "No scope chosen for '$name'; nothing added." >&2; return 2; }
    fi

    local key
    key="$(_row_key "$picked")"
    if [ "$key" = "$global_key" ]; then
        printf '%s\n' "--global"
        return 0
    fi
    if [ -z "$key" ]; then
        echo "No scope chosen for '$name'; nothing added." >&2
        return 2
    fi
    printf '%s\n%s\n' "--project" "$key"
}

cmd_add() {
    local json=false is_global=false
    local project_token="" name="" remote_url="" saw_dashdash=false
    local -a spec=() remote_header_args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) _usage; return 0 ;;
            --) saw_dashdash=true; shift; spec=("$@"); break ;;
            --json) json=true ;;
            --url)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp add --url' requires an HTTP(S) URL." >&2
                    return 2
                fi
                remote_url="$1"
                ;;
            --url=*) remote_url="${1#--url=}" ;;
            --header|--secret-header-key)
                local remote_option="$1"
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp add $remote_option' requires a value." >&2
                    return 2
                fi
                remote_header_args+=("$remote_option" "$1")
                ;;
            --header=*) remote_header_args+=("--header" "${1#--header=}") ;;
            --secret-header-key=*)
                remote_header_args+=("--secret-header-key" "${1#--secret-header-key=}")
                ;;
            --global) is_global=true ;;
            --project)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp add --project' requires a name or path." >&2
                    return 2
                fi
                project_token="$1"
                ;;
            --project=*)
                project_token="${1#--project=}"
                if [ -z "$project_token" ]; then
                    echo "'mcp add --project=' requires a non-empty name or path." >&2
                    return 2
                fi
                ;;
            -*)
                echo "Unknown flag for 'mcp add': $1" >&2
                return 2
                ;;
            *)
                if [ -n "$name" ]; then
                    echo "'mcp add' takes one server name before '--' (got: $1)." >&2
                    return 2
                fi
                name="$1"
                ;;
        esac
        shift
    done

    if [ -z "$name" ]; then
        echo "'mcp add' requires a server name." >&2
        echo "Usage: boxa mcp add <name> [--global|--project <p>] -- <command spec...>" >&2
        return 2
    fi
    if [ "$is_global" = true ] && [ -n "$project_token" ]; then
        echo "'mcp add': --global and --project are mutually exclusive." >&2
        return 2
    fi
    if [ -n "$remote_url" ]; then
        if [ "$saw_dashdash" = true ]; then
            echo "'mcp add' accepts either --url or a command spec, not both." >&2
            return 2
        fi
    elif [ "$saw_dashdash" != true ] || [ "${#spec[@]}" -eq 0 ]; then
        echo "'mcp add' requires either --url <http(s)-url> or a command spec after '--'." >&2
        return 2
    fi
    if [ -z "$remote_url" ] && [ "${#remote_header_args[@]}" -gt 0 ]; then
        echo "'mcp add': header options require --url." >&2
        return 2
    fi
    if [ -n "$remote_url" ] && { [ "$is_global" = true ] || [ -n "$project_token" ]; }; then
        echo "'mcp add --url' records a catalog entry and does not accept legacy scope flags." >&2
        return 2
    fi

    # ADR 0021 catalog path. Explicit legacy scope flags remain available until
    # issue 08 performs the real migration; the scope-free command never writes
    # a profile and never triggers agent rendering.
    if [ "$is_global" != true ] && [ -z "$project_token" ]; then
        if [ "$json" = true ]; then
            if [ -n "$remote_url" ]; then
                _run_py catalog-add-json "$name" --url "$remote_url" \
                    "${remote_header_args[@]}"
            else
                _run_py catalog-add-json "$name" -- "${spec[@]}"
            fi
        else
            if [ -n "$remote_url" ]; then
                _run_py catalog-add-text "$name" --url "$remote_url" \
                    "${remote_header_args[@]}"
            else
                _run_py catalog-add-text "$name" -- "${spec[@]}"
            fi
        fi
        return $?
    fi

    # Resolve the scope into the Python-core scope args. The scope is ALWAYS an
    # explicit decision (ADR 0013: never silently promote to global).
    local -a scope_args=()
    if [ "$is_global" = true ]; then
        scope_args=("--global")
    elif [ -n "$project_token" ]; then
        local key
        if ! key="$(_resolve_project_key "$project_token")"; then
            return 2
        fi
        # Gate the explicit --project on the SAME criterion the interactive
        # picker uses: the key must be an INITIALIZED boxa Project (issue 11
        # enumerator — Claude-known AND existing -history volume). Otherwise add
        # would write a project profile boxa cannot run (ADR 0013: init the
        # Project first, then re-run).
        if ! _project_target_exists "$key"; then
            echo "'mcp add --project': '$project_token' is not an initialized boxa Project." >&2
            echo "It must be known to Claude and have a boxa volume; initialize it first, then re-run." >&2
            return 2
        fi
        scope_args=("--project" "$key")
    elif [ -t 0 ] && [ -t 1 ]; then
        # Interactive: pick global or a boxa Project (same picker as import).
        local picker_out picker_rc
        picker_out="$(_add_scope_picker "$name")"
        picker_rc=$?
        if [ "$picker_rc" -ne 0 ]; then
            return "$picker_rc"
        fi
        local line
        while IFS= read -r line; do
            [ -n "$line" ] && scope_args+=("$line")
        done <<< "$picker_out"
    else
        echo "Non-interactive 'mcp add' needs an explicit scope." >&2
        echo "Examples:" >&2
        echo "  boxa mcp add context7 --global -- npx -y @upstash/context7-mcp@latest" >&2
        echo "  boxa mcp add myserver --project myapp -- uvx my-mcp-tool" >&2
        return 2
    fi

    local py_cmd
    if [ "$json" = true ]; then
        py_cmd="add-json"
    else
        py_cmd="add-text"
    fi

    if [ "$json" = true ]; then
        _run_py_secret_write "$py_cmd" "${scope_args[@]}" "$name" -- "${spec[@]}" || return $?
        _finish_secret_write
        return 0
    fi
    _run_py_secret_write "$py_cmd" "${scope_args[@]}" "$name" -- "${spec[@]}" || return $?
    _finish_secret_write
    return 0
}

cmd_catalog() {
    local json=false verbose=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) _usage; return 0 ;;
            --json) json=true ;;
            --verbose) verbose=true ;;
            *) echo "Unknown argument for 'mcp catalog': $1" >&2; return 2 ;;
        esac
        shift
    done
    if [ "$json" = true ]; then
        if [ "$verbose" = true ]; then
            _run_py catalog-json --verbose
        else
            _run_py catalog-json
        fi
    else
        if [ "$verbose" = true ]; then
            _run_py catalog-text --verbose
        else
            _run_py catalog-text
        fi
    fi
}

cmd_update() {
    if [ "$#" -eq 0 ] && _mcp_interactive; then
        local rows picked token name type action header value rc=0
        rows="$(_run_py catalog-update-picker)" || return $?
        if [ -z "$rows" ]; then
            echo "MCP catalog is empty; nothing updated." >&2
            return 1
        fi
        picked="$(printf '%s\n' "$rows" | picker::one \
            --prompt "Select MCP catalog entry: ")" || return 1
        IFS=$'\t' read -r token name type <<< "$picked"
        if [ "$type" != "http" ]; then
            echo "No guided update is available for '$name'; use update flags instead." >&2
            return 1
        fi
        action="$(printf '%s\n' $'add secret (auth) header\tadd-secret-header' \
            | picker::one --prompt "Select update action: ")" || return 1
        [ "${action##*$'\t'}" = "add-secret-header" ] || return 1
        printf 'Header name [Authorization]: ' >&2
        IFS= read -r header || header=""
        case "$header" in
            q|Q) return 1 ;;
            "") header="Authorization" ;;
        esac
        _mcp_prompt_secret_value "$name" "$header" header true || return $?
        value="$_MCP_SECRET_VALUE"
        _MCP_SECRET_VALUE=""
        _run_py_secret_write guided-secret-header-text "$token" "$header" <<< "$value" \
            || rc=$?
        value=""
        _finish_secret_write
        return "$rc"
    fi
    local json=false after_marker=false
    local -a args=()
    local arg
    for arg in "$@"; do
        if [ "$after_marker" = true ]; then
            args+=("$arg")
            continue
        fi
        case "$arg" in
            --json) json=true ;;
            --)
                after_marker=true
                args+=("$arg")
                ;;
            -h|--help) _usage; return 0 ;;
            *) args+=("$arg") ;;
        esac
    done
    if [ "$json" = true ]; then
        _run_py catalog-update-json "${args[@]}"
    else
        _run_py catalog-update-text "${args[@]}"
    fi
}

cmd_mode() {
    local json=false yes=false token="" mode=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json) json=true ;;
            --yes) yes=true ;;
            -h|--help) _usage; return 0 ;;
            -*) echo "Unknown flag for 'mcp mode': $1" >&2; return 2 ;;
            *)
                if [ -z "$token" ]; then
                    token="$1"
                elif [ -z "$mode" ]; then
                    mode="$1"
                else
                    echo "'mcp mode' takes one catalog entry and one mode." >&2
                    return 2
                fi
                ;;
        esac
        shift
    done
    if [ -z "$token" ] || [ -z "$mode" ]; then
        echo "Usage: boxa mcp mode <entry> service-isolated|agent-trusted [--yes]" >&2
        return 2
    fi
    if [ -f /etc/boxa/identity.json ]; then
        echo "'boxa mcp mode' is host-only; in-Container callers may use but cannot grant agent trust." >&2
        return 2
    fi
    case "$mode" in
        service-isolated|agent-trusted) ;;
        *) echo "Execution mode must be service-isolated or agent-trusted." >&2; return 2 ;;
    esac
    if [ "$json" = true ]; then
        if [ "$yes" != true ]; then
            echo "Non-interactive JSON mode change requires explicit --yes." >&2
            return 2
        fi
        _run_py catalog-mode-apply-json "$token" "$mode" --yes
        return $?
    fi
    _run_py catalog-mode-preview-text "$token" "$mode" || return $?
    if [ "$yes" != true ]; then
        if [ ! -t 0 ] || [ ! -t 1 ]; then
            echo "Non-interactive mode change requires explicit --yes." >&2
            return 2
        fi
        printf 'Apply this execution identity to the stable catalog entry? [y/N] ' >&2
        local reply
        IFS= read -r reply || reply=""
        case "$reply" in
            y|Y|yes|YES) ;;
            *) echo "Cancelled; MCP catalog and activations are unchanged." >&2; return 1 ;;
        esac
    fi
    _run_py catalog-mode-apply-text "$token" "$mode" --yes
}

cmd_readiness() {
    local json=false project="" token=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json) json=true ;;
            --project)
                shift
                [ "$#" -gt 0 ] || { echo "'mcp readiness --project' requires a path." >&2; return 2; }
                project="$1"
                ;;
            --project=*) project="${1#--project=}" ;;
            -h|--help) _usage; return 0 ;;
            -*) echo "Unknown flag for 'mcp readiness': $1" >&2; return 2 ;;
            *)
                [ -z "$token" ] || { echo "'mcp readiness' takes one catalog entry." >&2; return 2; }
                token="$1"
                ;;
        esac
        shift
    done
    [ -n "$token" ] || { echo "'mcp readiness' requires a catalog entry." >&2; return 2; }
    [ -n "$project" ] || project="$PWD"
    project="$(_resolve_project_key "$project")" || return 2
    if [ "$json" = true ]; then
        _run_py readiness-json "$token" --project "$project"
    else
        _run_py readiness-text "$token" --project "$project"
    fi
}

_mcp_interactive() {
    [ "${BOXA_MCP_TEST_INTERACTIVE:-}" = "1" ] || { [ -t 0 ] && [ -t 1 ]; }
}

_MCP_SECRET_VALUE=""

_mcp_prompt_secret_value() {
    local token="$1" key="$2" kind="${3:-header}"
    local cancel_q="${4:-false}" value=""
    _MCP_SECRET_VALUE=""
    if [ "$kind" = "header" ]; then
        printf "Expected format: the full header value (typically 'Bearer <token>'), without quotes.\n" >&2
    fi
    printf "Secret value for %s '%s' on '%s': " "$kind" "$key" "$token" >&2
    IFS= read -r -s value || value=""
    echo >&2
    if [ "$cancel_q" = true ] && { [ "$value" = "q" ] || [ "$value" = "Q" ]; }; then
        echo "Cancelled; nothing changed." >&2
        return 1
    fi
    if [ -z "$value" ]; then
        echo "Secret header value must not be empty; nothing changed." >&2
        return 2
    fi
    _MCP_SECRET_VALUE="$value"
}

cmd_secret() {
    local action="${1:-}" json=false token="" header="" value="" py_cmd
    local picked_interactively=false
    [ "$#" -gt 0 ] && shift
    if [ "$action" != "set" ]; then
        echo "Usage: boxa mcp secret set <entry> <header> [--json]" >&2
        return 2
    fi
    if [ "$#" -eq 0 ] && _mcp_interactive; then
        picked_interactively=true
        local entries picked keys key_count key_row kind
        entries="$(_run_py secret-missing-entry-picker)" || return $?
        if [ -z "$entries" ]; then
            echo "No MCP catalog entries have missing secret values." >&2
            return 1
        fi
        picked="$(printf '%s\n' "$entries" | picker::one \
            --prompt "Select MCP catalog entry with a missing secret: ")" \
            || return 1
        token="${picked%%$'\t'*}"
        keys="$(_run_py secret-missing-key-picker "$token")" || return $?
        key_count="$(printf '%s\n' "$keys" | awk 'NF { count++ } END { print count + 0 }')"
        if [ "$key_count" -eq 1 ]; then
            key_row="$keys"
        else
            key_row="$(printf '%s\n' "$keys" | picker::one \
                --prompt "Select missing secret key: ")" || return 1
        fi
        IFS=$'\t' read -r header kind <<< "$key_row"
    fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json) json=true ;;
            -h|--help) _usage; return 0 ;;
            -*) echo "Unknown flag for 'mcp secret set': $1" >&2; return 2 ;;
            *)
                if [ -z "$token" ]; then
                    token="$1"
                elif [ -z "$header" ]; then
                    header="$1"
                else
                    echo "'mcp secret set' takes one catalog entry and header name." >&2
                    return 2
                fi
                ;;
        esac
        shift
    done
    if [ -z "$token" ] || [ -z "$header" ]; then
        echo "Usage: boxa mcp secret set <entry> <header> [--json]" >&2
        return 2
    fi
    if ! _mcp_interactive; then
        echo "'mcp secret set' requires an interactive terminal." >&2
        return 2
    fi
    _mcp_prompt_secret_value "$token" "$header" "${kind:-header}" \
        "$picked_interactively" || return $?
    value="$_MCP_SECRET_VALUE"
    _MCP_SECRET_VALUE=""
    py_cmd="secret-set-text"
    [ "$json" = true ] && py_cmd="secret-set-json"
    _run_py_secret_write "$py_cmd" "$token" "$header" <<< "$value" || {
        local rc=$?
        value=""
        return "$rc"
    }
    value=""
    _finish_secret_write
}

cmd_activation() {
    local action="$1"
    shift
    local json=false project="" consumer="" token="" accept_degraded=false
    local everywhere=false no_everywhere=false yes=false
    local project_explicit=false
    local import_offer_id=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json) json=true ;;
            --project)
                shift
                [ "$#" -gt 0 ] || { echo "'mcp $action --project' requires a path." >&2; return 2; }
                project="$1"
                project_explicit=true
                ;;
            --project=*) project="${1#--project=}"; project_explicit=true ;;
            --for)
                shift
                [ "$#" -gt 0 ] || { echo "'mcp $action --for' requires a consumer." >&2; return 2; }
                consumer="$1"
                ;;
            --for=*) consumer="${1#--for=}" ;;
            --accept-degraded-secret-isolation) accept_degraded=true ;;
            --everywhere) everywhere=true ;;
            --no-everywhere) no_everywhere=true ;;
            --yes) yes=true ;;
            -h|--help) _usage; return 0 ;;
            -*) echo "Unknown flag for 'mcp $action': $1" >&2; return 2 ;;
            *)
                [ -z "$token" ] || { echo "'mcp $action' takes one catalog entry." >&2; return 2; }
                token="$1"
                ;;
        esac
        shift
    done
    if [ -z "$token" ]; then
        if [ "$action" = "activate" ] && [ "$everywhere" != true ] \
            && [ "$no_everywhere" != true ]; then
            local offer_project="${project:-$PWD}"
            offer_project="$(_resolve_project_key "$offer_project")" || return 2
            if [ "$yes" = true ] && ! _mcp_interactive; then
                local -a import_args=(--activate --yes --project "$offer_project")
                [ "$json" = true ] && import_args+=(--json)
                [ -n "$consumer" ] && import_args+=(--for "$consumer")
                cmd_import "${import_args[@]}"
                return $?
            fi
            if _mcp_interactive; then
                local offers offer_count offer_reply
                offers="$(_run_py list-applicable --project "$offer_project")"
                offer_count="$(printf '%s\n' "$offers" | awk 'NF { count++ } END { print count + 0 }')"
                if [ "$offer_count" -gt 0 ]; then
                    printf 'Found %s MCP server(s) in your agent config — add one? [y/N] ' \
                        "$offer_count" >&2
                    IFS= read -r offer_reply || offer_reply=""
                    case "$offer_reply" in
                        y|Y|yes|YES)
                            local picked_offer
                            picked_offer="$(printf '%s\n' "$offers" | picker::one \
                                --prompt "Select inherited MCP server: ")" || return 1
                            import_offer_id="${picked_offer%%$'\t'*}"
                            project="$offer_project"
                            project_explicit=true
                            ;;
                    esac
                fi
            fi
        fi
        if [ -n "$import_offer_id" ]; then
            token="$import_offer_id"
        elif _mcp_interactive; then
            local picked
            picked="$(_run_py catalog-picker | picker::one --prompt "Select MCP catalog entry: ")" || return 1
            token="${picked%%$'\t'*}"
            [ -n "$token" ] || { echo "MCP catalog is empty." >&2; return 1; }
        else
            echo "'mcp $action' requires a catalog entry name or id." >&2
            return 2
        fi
    fi
    if [ "$everywhere" = true ] && [ "$no_everywhere" = true ]; then
        echo "'mcp activate' accepts only one of --everywhere and --no-everywhere." >&2
        return 2
    fi
    if { [ "$everywhere" = true ] || [ "$no_everywhere" = true ]; } && [ -n "$project" ]; then
        echo "--everywhere/--no-everywhere cannot be combined with --project." >&2
        return 2
    fi
    if [ "$action" != "activate" ] && { [ "$everywhere" = true ] || [ "$no_everywhere" = true ] || [ "$yes" = true ]; }; then
        echo "'mcp deactivate' does not accept everywhere flags or --yes." >&2
        return 2
    fi
    local -a args=("$token") projects=()
    if [ "$everywhere" = true ]; then
        args+=(--everywhere)
    elif [ "$no_everywhere" = true ]; then
        args+=(--no-everywhere)
    else
        if [ "$action" = "activate" ] && [ "$project_explicit" != true ] \
            && _mcp_interactive; then
            local picked_project
            while IFS= read -r picked_project; do
                [ -n "$picked_project" ] && projects+=("$picked_project")
            done < <(_activation_project_picker "$PWD")
            [ "${#projects[@]}" -gt 0 ] \
                || { echo "No Project chosen; nothing activated." >&2; return 2; }
        else
            [ -n "$project" ] || project="$PWD"
            project="$(_resolve_project_key "$project")" || return 2
            projects+=("$project")
        fi
        local selected_project
        for selected_project in "${projects[@]}"; do
            args+=(--project "$selected_project")
        done
        project="${projects[0]}"
    fi
    if [ "$action" = "activate" ]; then
        if [ "$no_everywhere" = true ]; then
            if [ -n "$consumer" ] || [ "$accept_degraded" = true ] || [ "$yes" = true ]; then
                echo "'mcp activate --no-everywhere' does not accept activation or acknowledgement flags." >&2
                return 2
            fi
        else
            if [ -z "$consumer" ]; then
                if _mcp_interactive; then
                    consumer="$(printf '%s\n' claude codex claude,codex | picker::one --prompt "Activate for consumer: ")" || return 1
                else
                    echo "Non-interactive 'mcp activate' requires --for claude, codex, or both." >&2
                    return 2
                fi
            fi
            args+=(--for "$consumer")
            if [ -n "$import_offer_id" ]; then
                local import_command="import-activate-text"
                [ "$json" = true ] && import_command="import-activate-json"
                local -a offered_args=(
                    --target-project "$project" --for "$consumer"
                    --project "$project" --import-id "$import_offer_id"
                )
                [ "$yes" = true ] && offered_args+=(--yes)
                _run_py "$import_command" "${offered_args[@]}"
                return $?
            fi
            if [ "$accept_degraded" = true ]; then
                args+=(--accept-degraded-secret-isolation)
            elif _mcp_interactive \
                && [ "$(_run_py activation-degradation-text "$token" --project "${project:-$PWD}")" = "degraded-secret-isolation" ]; then
                printf '%s\n' "WARNING: degraded-secret-isolation: node owns the Docker daemon and can inspect this server's container environment." >&2
                printf 'Accept this temporary secret-isolation limitation? [y/N] ' >&2
                local degraded_reply
                IFS= read -r degraded_reply || degraded_reply=""
                case "$degraded_reply" in
                    y|Y|yes|YES) args+=(--accept-degraded-secret-isolation) ;;
                    *)
                        echo "Cancelled; no MCP activation, acknowledgement, or agent config changed." >&2
                        return 1
                        ;;
                esac
            fi
            if [ "$everywhere" = true ] \
                && [ "$(_run_py activation-agent-trusted-text "$token")" = "true" ]; then
                printf '%s\n' "WARNING: agent-identity trust will extend to every present and future Project." >&2
                if [ "$yes" != true ]; then
                    if ! _mcp_interactive; then
                        echo "Non-interactive agent-trusted everywhere activation requires explicit --yes." >&2
                        return 2
                    fi
                    printf 'Extend agent-identity trust to every future Project? [y/N] ' >&2
                    local trust_reply
                    IFS= read -r trust_reply || trust_reply=""
                    case "$trust_reply" in
                        y|Y|yes|YES) ;;
                        *) echo "Cancelled; the everywhere mark and Project activations are unchanged." >&2; return 1 ;;
                    esac
                fi
                args+=(--yes)
            elif [ "$yes" = true ]; then
                args+=(--yes)
            fi
            # An interactive user may explicitly compose the otherwise separate
            # install and activation operations. Cancellation returns before any
            # activation/config mutation. Non-interactive callers get the normal
            # readiness refusal and must run install themselves.
            if [ "$everywhere" != true ] && _mcp_interactive; then
                local readiness_error=""
                for selected_project in "${projects[@]}"; do
                    if readiness_error="$(_run_py readiness-json "$token" --project "$selected_project" 2>&1 >/dev/null)"; then
                        continue
                    fi
                    case "$readiness_error" in
                        *"is not running; readiness never starts it implicitly"*)
                            # The Python activation core records this exact state as
                            # pending; install cannot run until the Container starts.
                            ;;
                        *)
                            printf "Entry is not ready. Install it in this running Project, re-check, and activate? [y/N] " >&2
                            local reply
                            IFS= read -r reply || reply=""
                            case "$reply" in
                                y|Y|yes|YES)
                                    cmd_install "$token" --project "$selected_project" || return $?
                                    _run_py readiness-json "$token" --project "$selected_project" >/dev/null || return $?
                                    ;;
                                *)
                                    echo "Cancelled; no MCP activation or agent config changed." >&2
                                    return 1
                                    ;;
                            esac
                            ;;
                    esac
                done
            fi
        fi
    elif [ -n "$consumer" ] || [ "$accept_degraded" = true ]; then
        echo "'mcp deactivate' does not accept activation flags." >&2
        return 2
    fi
    if [ "$json" = true ]; then
        _run_py "${action}-json" "${args[@]}"
    else
        _run_py "${action}-text" "${args[@]}"
    fi
}

# --- Dispatch ----------------------------------------------------------------

main() {
    local sub="${1:-}"
    case "$sub" in
        ''|-h|--help|help)
            _usage
            exit 0
            ;;
    esac
    shift
    case "$sub" in
        catalog) cmd_catalog "$@" ;;
        update) cmd_update "$@" ;;
        mode) cmd_mode "$@" ;;
        readiness|ready) cmd_readiness "$@" ;;
        secret)  cmd_secret "$@" ;;
        activate) cmd_activation activate "$@" ;;
        deactivate) cmd_activation deactivate "$@" ;;
        import)  cmd_import "$@" ;;
        migrate) cmd_migrate "$@" ;;
        list)    cmd_list "$@" ;;
        status)  cmd_list "$@" ;;
        enable)  cmd_enable "$@" ;;
        disable) cmd_disable "$@" ;;
        remove)  cmd_remove "$@" ;;
        reload)  cmd_reload "$@" ;;
        doctor)  cmd_doctor "$@" ;;
        install) cmd_install "$@" ;;
        add)     cmd_add "$@" ;;
        *)
            echo "Unknown mcp subcommand: $sub" >&2
            _usage >&2
            exit 2
            ;;
    esac
}

# Run the dispatcher only when executed directly; when sourced (e.g. by a unit
# test exercising an individual cmd_* function) the functions are defined but
# main does not run.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
