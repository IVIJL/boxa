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

Discover, classify, and manage MCP servers for boxa Containers (ADR 0013).
Boxa stores an agent-neutral MCP profile and renders agent-specific config
for Claude Code and Codex. The first version supports Container MCP servers;
Host MCP servers are detected and explained but not launched.

Subcommands:
  import      Discover Inherited MCP servers from agent config and classify
              them as import candidates (dry-run; no writes).
  list        Show the effective MCP profile (use --inherited for detected
              Inherited MCP servers only).
  render      Preview (--dry-run) or re-render boxa-managed entries into
              Claude Code / Codex config. This version supports --dry-run only.
  doctor      Diagnose MCP profile / render / runtime problems.
  add         Record a new Boxa MCP server from an explicit command spec
              (scope is always an explicit choice; never silent global).
  install     Materialize an existing profile entry into persistent runtime.
  enable      Resume rendering a previously disabled MCP server.
  disable     Keep a definition but stop rendering it.
  remove      Delete a boxa-managed MCP server definition for one scope.
  reload      Re-stage changed MCP secrets into running Container(s) without a
              stop/start (host-initiated momentary root exec; no restart).

Read-only commands in this version:
  boxa mcp import [scope] [--json]            Dry-run discovery report.
  boxa mcp list [scope] [--json]              Effective MCP profile view
      (global + Project; a Project entry shadows a same-named global one for
      the current Project). --all shows global plus every project profile.
  boxa mcp list --inherited [scope] [--json]  Detected Inherited MCP servers.
  boxa mcp doctor [--fix] [--json]            Diagnose MCP profile / render /
      runtime problems and print concrete repair commands. --fix performs only
      safe local fixes (re-render, create missing MCP dirs, repair the wrapper
      symlink); it never installs packages, allows domains, purges runtime, or
      enables host-only servers.
  boxa mcp render --dry-run [--project <p>] [--json]
      Preview the Claude Code / Codex config boxa would render from the
      profile. Rendered names are 'boxa-' prefixed and call the wrapper
      'boxa-mcp-run <server>' (never the raw command, never secret values).
      Re-render would replace only boxa-managed entries; inherited/manual
      agent MCP entries are never modified. Codex is previewed against its
      verified TOML shape, or reported unsupported when no TOML parser exists.

Apply (write) path:
  boxa mcp import --apply [scope]             Apply selected candidates.
      Interactive TTY  -> multi-select picker of Container-safe candidates.
      Non-interactive  -> requires an explicit selection:
        --server <name>     Apply by server name (repeatable; fails on
                            ambiguity — use --import-id instead).
        --import-id <id>    Apply by stable import id (repeatable).
        --all-applicable    Apply every applicable (container) candidate.
  Applied servers are written to the boxa MCP profile, preserving inherited
  scope (global source -> global profile, project source -> Project profile).
  Inherited secret env VALUES can be copied into a scoped 0600 secret store;
  the summary reports which env KEYS were copied, never their values. Host-only,
  unknown, and excluded candidates are shown but not applied. No Claude Code or
  Codex config is modified yet.

Profile management (mutating; auto-render unless --no-render):
  boxa mcp enable  <name> [--global|--project <p>]   Resume rendering a server.
  boxa mcp disable <name> [--global|--project <p>]   Keep the definition but
      stop rendering it. A Project disable of a global server creates a
      Project-only override; the global entry is left unchanged.
  boxa mcp remove  <name> [--global|--project <p>] [--purge] [--no-render]
      Delete a boxa-managed profile entry for one scope. Never touches
      inherited/manual agent config. Scoped secrets are deleted only with
      --purge (or interactive confirmation); a Project remove never touches
      global secrets. With no scope flag the command targets the global profile.

Install (materialize) path:
  boxa mcp install <name> [--global|--project <p>] [--allow-for <min>] [--keep-window] [--json]
      Materialize an existing profile entry into persistent Container runtime
      and rewrite the canonical profile to use the materialized command. npm/npx
      servers install into the persistent npm-global prefix; Docker-backed
      servers pull into Project-scoped rootless Docker state; Python/uv reports
      that a dedicated MCP runtime volume is needed before proceeding. The
      install runs INSIDE a Container (the runtime lives there, not on the host):
      a Project install targets that Project's Container; a global install uses
      one running Container, offers a picker in a TTY when several run, and
      requires --project in non-interactive ambiguous cases (it never creates a
      new Project in an unintended location). --allow-for <min> opens an
      Allow-for window for the attempt and closes it afterward by default so the
      harvest log is produced immediately; --keep-window leaves it open. On a
      blocked network failure the command points at 'boxa blocked' and shows
      the exact rerun command.

Add (record a new server) path:
  boxa mcp add <name> [--global|--project <p>] [--no-render] [--json] -- <command spec...>
      Record a NEW Boxa MCP server straight from a command spec after '--'
      (e.g. 'npx -y @upstash/context7-mcp@latest', 'uvx my-mcp-tool',
      'docker run -i --rm -e API_KEY=... image'). The spec is classified and
      probed like an imported server: a host-only / unknown / remote spec is
      refused with a clear reason. Scope is ALWAYS explicit (ADR 0013 never
      silently promotes to global): --global or --project <p> set it
      non-interactively; in a TTY with no scope flag, the same project picker as
      the import wizard offers global or any boxa Project (current
      pre-highlighted); without a TTY and no scope flag it fails with examples.
      Inline secret env (a Docker '-e KEY=VALUE' whose KEY/VALUE looks like a
      credential) is written to the scope-correct 0600 secret store; values are
      never echoed. A successful add auto-renders unless --no-render. Distinct
      from 'import' (discovers inherited) and 'install' (materializes runtime).

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
    local all_applicable=false
    local no_render=false
    local -a projects=()
    local -a servers=()
    local -a import_ids=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json) json=true ;;
            --all) all=true ;;
            --apply) apply=true ;;
            --all-applicable) all_applicable=true ;;
            --no-render) no_render=true ;;
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
                echo "Unexpected argument for 'mcp import': $1" >&2
                return 2
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
        if [ "${#servers[@]}" -gt 0 ] || [ "${#import_ids[@]}" -gt 0 ] \
            || [ "$all_applicable" = true ]; then
            echo "--server/--import-id/--all-applicable require --apply." >&2
            return 2
        fi
        if [ "$no_render" = true ]; then
            echo "--no-render only applies to 'mcp import --apply'." >&2
            return 2
        fi
        if [ "$json" = true ]; then
            _run_py import-json "${scope_args[@]}"
            return $?
        fi
        # Dry-run by default (ADR 0013 / local-plan-mcp.md decision 10). No writes.
        _run_py import-text "${scope_args[@]}"
        return $?
    fi

    cmd_import_apply "$json" "$all_applicable" "$no_render" \
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
    local json="$1" all_applicable="$2" no_render="$3"
    local -n _scope_args="$4"
    local -n _servers="$5"
    local -n _import_ids="$6"

    local -a sel_args=()
    local s
    for s in "${_servers[@]+"${_servers[@]}"}"; do
        sel_args+=("--server" "$s")
    done
    for s in "${_import_ids[@]+"${_import_ids[@]}"}"; do
        sel_args+=("--import-id" "$s")
    done
    [ "$all_applicable" = true ] && sel_args+=("--all-applicable")

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
            echo "See 'boxa mcp import' (dry-run) for names and import IDs." >&2
            return 2
        fi
    fi

    if [ "$json" = true ]; then
        _run_py_secret_write apply-json "${_scope_args[@]}" "${sel_args[@]}" || return $?
        # Capture the render status BEFORE the cleanup so a failed auto-render is
        # surfaced (the cleanup's own exit status would otherwise mask it and the
        # JSON path would falsely report success).
        _maybe_auto_render "$no_render" true
        local render_rc=$?
        _finish_secret_write
        return "$render_rc"
    fi
    _run_py_secret_write apply-text "${_scope_args[@]}" "${sel_args[@]}" || return $?
    _maybe_auto_render "$no_render" false
    local render_rc=$?
    _finish_secret_write
    return "$render_rc"
}

# Auto-render after a successful apply (ADR 0013, issue 07). A mutating profile
# command re-renders the boxa-managed agent entries so the new server is
# usable immediately, unless the user passed --no-render. Render is idempotent
# and owns only boxa- entries, so re-rendering the full surface here is safe.
#   $1  no_render flag ("true" to skip)
#   $2  json ("true" to suppress the human note; JSON consumers parse render
#       output separately, so we stay quiet on the apply path's stdout)
_maybe_auto_render() {
    local no_render="$1" json="$2"
    if [ "$no_render" = true ]; then
        if [ "$json" != true ]; then
            echo "Skipped auto-render (--no-render); run 'boxa mcp render' to apply." >&2
        fi
        return 0
    fi
    if [ "$json" = true ]; then
        # Keep the apply JSON the sole stdout payload; render quietly, surfacing
        # only a hard failure.
        _run_py render-write-json >/dev/null || return $?
        return 0
    fi
    echo >&2
    echo "Auto-rendering boxa-managed agent entries..." >&2
    _run_py render-write-text >&2
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
    shift 4

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
    local -a menu=()
    local id name scope pkey
    while IFS=$'\t' read -r id name scope pkey; do
        [ -n "$id" ] || continue
        all_ids+=("$id")
        all_names+=("$name")
        all_scopes+=("$scope")
        all_pkeys+=("$pkey")
        menu+=("$(printf '%-24s %-8s' "$name" "$scope")"$'\t'"$id")
    done <<< "$applicable"

    local picked
    picked="$(printf '%s\n' "${menu[@]}" | picker::many \
        --prompt "Select MCP servers to import" \
        --header "Container-safe candidates (multi-select; q to cancel)")" \
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
    _ids=(); _names=(); _scopes=(); _pkeys=()
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

# Full apply wizard. Prints the resolved Python apply args (one per line:
# --import-id <id> ... and --override <id> <scope> [<key>] ...) on stdout. All
# interaction is on /dev/tty. Returns non-zero on a hard error or a cancel.
_apply_wizard() {
    local -a sel_ids=() sel_names=() sel_scopes=() sel_pkeys=()
    local rc
    _wizard_select sel_ids sel_names sel_scopes sel_pkeys "$@"
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
    local i id name inherited pkey chosen_scope chosen_key
    for i in "${!sel_ids[@]}"; do
        id="${sel_ids[$i]}"
        name="${sel_names[$i]}"
        inherited="${sel_scopes[$i]}"
        pkey="${sel_pkeys[$i]}"

        chosen_scope="$(_wizard_scope_toggle "$inherited" "$name")"

        out_args+=("--import-id" "$id")

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

cmd_render() {
    # Render (issue 07): `--dry-run` previews the planned Claude Code / Codex
    # config WITHOUT writing (issue 06 behaviour, preserved); a bare
    # `boxa mcp render` now WRITES the boxa-managed entries into the agent
    # config trees. Both paths read only the canonical profile + agent config;
    # the write path owns only `boxa-` entries and leaves inherited/manual
    # entries untouched.
    local dry_run=false
    local json=false
    local -a projects=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=true ;;
            --json) json=true ;;
            --project)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp render --project' requires a name or path." >&2
                    return 2
                fi
                projects+=("$1")
                ;;
            --project=*) projects+=("${1#--project=}") ;;
            -h|--help) _usage; return 0 ;;
            -*)
                echo "Unknown flag for 'mcp render': $1" >&2
                return 2
                ;;
            *)
                echo "Unexpected argument for 'mcp render': $1" >&2
                return 2
                ;;
        esac
        shift
    done

    # --project scopes the DRY-RUN preview only (to focus its output). The real
    # WRITE path always renders the FULL boxa-managed surface — the writers own
    # every boxa- entry and rewrite the whole set, so a scoped write would drop
    # other projects' already-rendered entries. Reject --project on the write
    # path with a clear pointer to the preview.
    if [ "$dry_run" != true ] && [ "${#projects[@]}" -gt 0 ]; then
        echo "'boxa mcp render' writes the full boxa-managed surface and does not accept --project." >&2
        echo "A scoped write would drop other projects' rendered entries." >&2
        echo "To preview one project: boxa mcp render --dry-run --project <name-or-path>" >&2
        return 2
    fi

    # Resolve explicit --project tokens to Claude record keys; the preview then
    # reads the matching project profile(s). With no --project, every project
    # profile is used. --all/--no-global are not meaningful here.
    local -a scope_args=()
    if [ "${#projects[@]}" -gt 0 ]; then
        local token key
        for token in "${projects[@]}"; do
            if ! key="$(_resolve_project_key "$token")"; then
                return 1
            fi
            scope_args+=("--project" "$key")
        done
    fi

    # Dry-run preview (write-free) vs the real write path.
    local py_cmd_json py_cmd_text
    if [ "$dry_run" = true ]; then
        py_cmd_json="render-json"
        py_cmd_text="render-text"
    else
        py_cmd_json="render-write-json"
        py_cmd_text="render-write-text"
    fi

    if [ "$json" = true ]; then
        _run_py "$py_cmd_json" "${scope_args[@]+"${scope_args[@]}"}"
        return $?
    fi
    _run_py "$py_cmd_text" "${scope_args[@]+"${scope_args[@]}"}"
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
    local json=false no_render=false
    local -a raw=()
    local a
    for a in "$@"; do
        case "$a" in
            -h|--help) _usage; return 0 ;;
            --json) json=true ;;
            --no-render) no_render=true ;;
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
        _run_py enable-json "${args[@]}" || return $?
        _maybe_auto_render "$no_render" true
        return $?
    fi
    _run_py enable-text "${args[@]}" || return $?
    _maybe_auto_render "$no_render" false
}

cmd_disable() {
    local json=false no_render=false
    local -a raw=()
    local a
    for a in "$@"; do
        case "$a" in
            -h|--help) _usage; return 0 ;;
            --json) json=true ;;
            --no-render) no_render=true ;;
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
        _run_py disable-json "${args[@]}" || return $?
        _maybe_auto_render "$no_render" true
        return $?
    fi
    _run_py disable-text "${args[@]}" || return $?
    _maybe_auto_render "$no_render" false
}

cmd_remove() {
    local json=false no_render=false
    local -a raw=()
    local a
    for a in "$@"; do
        case "$a" in
            -h|--help) _usage; return 0 ;;
            --json) json=true ;;
            --no-render) no_render=true ;;
            *) raw+=("$a") ;;
        esac
    done
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
        _run_py remove-json "${args[@]}" || return $?
        _maybe_auto_render "$no_render" true
        return $?
    fi
    _run_py remove-text "${args[@]}" || return $?
    _maybe_auto_render "$no_render" false
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

    if ! command -v docker >/dev/null 2>&1; then
        echo "'mcp install' materializes runtime inside a Container and needs Docker." >&2
        return 2
    fi

    # Resolve the target container and the Python-core scope args. A project
    # install targets that Project's container and passes --project <key>; a
    # global install runs inside a resolved boxa runtime and passes --global.
    local container="" project_key="" started_here=false target_state=""
    local -a scope_args=()
    if [ -n "$project_token" ]; then
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
    if [ "$json" = true ]; then
        py_cmd="install-json"
    else
        py_cmd="install-text"
    fi
    _run_install_in_container "$container" "$py_cmd" "${scope_args[@]}" "$name" || rc=$?

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
    local json=false no_render=false is_global=false
    local project_token="" name="" saw_dashdash=false
    local -a spec=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) _usage; return 0 ;;
            --) saw_dashdash=true; shift; spec=("$@"); break ;;
            --json) json=true ;;
            --no-render) no_render=true ;;
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
    if [ "$saw_dashdash" != true ] || [ "${#spec[@]}" -eq 0 ]; then
        echo "'mcp add' requires a command spec after '--'." >&2
        echo "Example: boxa mcp add context7 --global -- npx -y @upstash/context7-mcp@latest" >&2
        return 2
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
        # Capture the render status BEFORE the cleanup so a failed auto-render is
        # surfaced (the cleanup's own exit status would otherwise mask it and the
        # JSON path would falsely report success).
        _maybe_auto_render "$no_render" true
        local render_rc=$?
        _finish_secret_write
        return "$render_rc"
    fi
    _run_py_secret_write "$py_cmd" "${scope_args[@]}" "$name" -- "${spec[@]}" || return $?
    _maybe_auto_render "$no_render" false
    local render_rc=$?
    _finish_secret_write
    return "$render_rc"
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
        import)  cmd_import "$@" ;;
        list)    cmd_list "$@" ;;
        render)  cmd_render "$@" ;;
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
