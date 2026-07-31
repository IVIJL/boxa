#!/bin/bash
set -euo pipefail
# Seed Claude Code config in /home/node/.claude (= host ~/.claude bind mount).
# See docs/adr/0002 for why we share the dir directly instead of symlinking.
# Boxa-specific defaults are seeded only when the host file is missing,
# so existing host config is never overwritten.

readonly DEFAULTS="${BOXA_CLAUDE_DEFAULTS:-/etc/claude-defaults}"
readonly TARGET="${BOXA_CLAUDE_TARGET:-/home/node/.claude}"
readonly PROJECT_NAME="${BOXA_PROJECT_NAME:-}"

WARNINGS=()
seeded=0

# First-start. Seed-if-missing — host wins (atomic-rename refresh from host
# or any container is visible to all instances via the shared bind mount).
seed_defaults() {
    [ -d "$DEFAULTS" ] || return 0

    [ -f "$TARGET/settings.json" ] || { cp "$DEFAULTS/settings.json" "$TARGET/settings.json"; seeded=$((seeded+1)); }
    [ -f "$TARGET/statusline-info.sh" ] || { cp "$DEFAULTS/statusline-info.sh" "$TARGET/statusline-info.sh"; seeded=$((seeded+1)); }

    mkdir -p "$TARGET/hooks"
    for hook in "$DEFAULTS/hooks/"*.sh; do
        local name
        name=$(basename "$hook")
        [ -f "$TARGET/hooks/$name" ] || { cp "$hook" "$TARGET/hooks/$name"; seeded=$((seeded+1)); }
    done
}

# Every-start until completed once. Retire Boxa's old global Project MCP
# approval without overwriting any unrelated host settings. The durable marker
# lets a user deliberately restore the setting after this upgrade.
migrate_enable_all_project_mcp_servers() {
    local migration_dir="$TARGET/.boxa-migrations"
    local marker="$migration_dir/enable-all-project-mcp-servers"
    local status=0
    [ ! -e "$marker" ] || return 0

    mkdir -p "$migration_dir"
    (
        flock 9 || exit 3
        [ ! -e "$marker" ] || exit 0

        if [ ! -e "$TARGET/settings.json" ]; then
            : > "$marker"
            exit 0
        fi
        local attempts_left=3 source="" tmp=""
        while [ "$attempts_left" -gt 0 ]; do
            attempts_left=$((attempts_left - 1))
            source=$(mktemp "$TARGET/settings.json.source.XXXXXX") || exit 3
            trap '[ -z "${source:-}" ] || rm -f "$source"; [ -z "${tmp:-}" ] || rm -f "$tmp"' EXIT
            tmp=$(mktemp "$TARGET/settings.json.XXXXXX") || exit 3
            if ! cp -- "$TARGET/settings.json" "$source" \
               || ! jq -e . "$source" >/dev/null 2>&1; then
                exit 2
            fi

            if ! jq -e \
                'type == "object" and has("enableAllProjectMcpServers")' \
                "$source" >/dev/null; then
                rm -f "$source" "$tmp"
                source=""
                tmp=""
                trap - EXIT
                : > "$marker"
                exit 0
            fi
            if ! jq 'del(.enableAllProjectMcpServers)' "$source" > "$tmp"; then
                exit 3
            fi
            # Claude does not share this lock, so a small revalidate-to-rename
            # race remains. Rechecking here narrows it as far as possible.
            if ! cmp -s "$source" "$TARGET/settings.json"; then
                rm -f "$source" "$tmp"
                source=""
                tmp=""
                trap - EXIT
                continue
            fi
            mv "$tmp" "$TARGET/settings.json"
            rm -f "$source"
            source=""
            tmp=""
            trap - EXIT
            : > "$marker"
            exit 0
        done
        exit 4
    ) 9>"$migration_dir/enable-all-project-mcp-servers.lock" || status=$?

    if [ "$status" -eq 2 ]; then
        WARNINGS+=("Claude settings migration skipped — $TARGET/settings.json is unreadable or invalid JSON")
    elif [ "$status" -eq 4 ]; then
        WARNINGS+=("Claude settings migration deferred — concurrent Claude settings update detected; it will retry on next start (the final revalidate/rename window cannot be locked against Claude)")
    elif [ "$status" -ne 0 ]; then
        WARNINGS+=("Claude settings migration failed — could not retire enableAllProjectMcpServers")
    fi
}

# Every-start. Add boxa's keep-awake client hook to existing shared Claude
# config without replacing unrelated user hooks or settings. Re-running is a
# no-op once all three exact entries are present.
migrate_agent_awake_hooks() {
    local migration_dir="$TARGET/.boxa-migrations"
    local status=0

    mkdir -p "$TARGET/hooks" "$migration_dir"
    if [ -f "$DEFAULTS/hooks/agent-awake.sh" ] \
        && [ ! -f "$TARGET/hooks/agent-awake.sh" ]; then
        cp "$DEFAULTS/hooks/agent-awake.sh" "$TARGET/hooks/agent-awake.sh"
        seeded=$((seeded+1))
    fi
    [ -e "$TARGET/settings.json" ] || return 0

    (
        flock 9 || exit 3

        local attempts_left=3 source="" tmp=""
        while [ "$attempts_left" -gt 0 ]; do
            attempts_left=$((attempts_left - 1))
            source=$(mktemp "$TARGET/settings.json.source.XXXXXX") || exit 3
            trap '[ -z "${source:-}" ] || rm -f "$source"; [ -z "${tmp:-}" ] || rm -f "$tmp"' EXIT
            tmp=$(mktemp "$TARGET/settings.json.XXXXXX") || exit 3
            if ! cp -- "$TARGET/settings.json" "$source" \
               || ! jq -e '
                    . as $settings
                    | type == "object"
                    and (.hooks == null or (.hooks | type == "object"))
                    and (["UserPromptSubmit", "PreToolUse", "Stop"] | all(
                        . as $event
                        | ($settings.hooks[$event] == null
                           or ($settings.hooks[$event] | type == "array"))
                    ))
                ' "$source" >/dev/null 2>&1; then
                exit 2
            fi

            if ! jq '
                def ensure_hook($event; $command):
                    {hooks: [{type: "command", command: $command}]} as $entry
                    | .hooks = (.hooks // {})
                    | .hooks[$event] = ((.hooks[$event] // []) as $entries
                        | if ($entries | index($entry)) == null
                          then $entries + [$entry]
                          else $entries
                          end);
                ensure_hook("UserPromptSubmit"; "/home/node/.claude/hooks/agent-awake.sh busy")
                | ensure_hook("PreToolUse"; "/home/node/.claude/hooks/agent-awake.sh busy")
                | ensure_hook("Stop"; "/home/node/.claude/hooks/agent-awake.sh idle")
            ' "$source" > "$tmp"; then
                exit 3
            fi
            if cmp -s "$source" "$tmp"; then
                rm -f "$source" "$tmp"
                source=""
                tmp=""
                trap - EXIT
                exit 0
            fi
            # Claude does not share this lock; revalidate immediately before
            # rename and retry if it changed the shared file meanwhile.
            if ! cmp -s "$source" "$TARGET/settings.json"; then
                rm -f "$source" "$tmp"
                source=""
                tmp=""
                trap - EXIT
                continue
            fi
            mv "$tmp" "$TARGET/settings.json"
            rm -f "$source"
            source=""
            tmp=""
            trap - EXIT
            exit 0
        done
        exit 4
    ) 9>"$migration_dir/agent-awake-hooks.lock" || status=$?

    if [ "$status" -eq 2 ]; then
        WARNINGS+=("Claude keep-awake hook migration skipped — $TARGET/settings.json has an unsupported shape or invalid JSON")
    elif [ "$status" -eq 4 ]; then
        WARNINGS+=("Claude keep-awake hook migration deferred — concurrent Claude settings update detected; it will retry on next start")
    elif [ "$status" -ne 0 ]; then
        WARNINGS+=("Claude keep-awake hook migration failed")
    fi
}

# Every-start. Backwards-compat alias /workspace/<name> -> host project path
# (ADR 0004). /workspace is created and chown'd to node:node in the Dockerfile,
# so node can write here without sudo.
make_workspace_symlink() {
    [ -n "$PROJECT_NAME" ] || return 0
    [ -n "${BOXA_PROJECT_HOST_PATH:-}" ] || return 0
    ln -sfn "$BOXA_PROJECT_HOST_PATH" "/workspace/$PROJECT_NAME"
}

# Every-start. Pre-accept trust for both host path and /workspace alias so
# Claude doesn't prompt regardless of which CWD the user enters from.
#
# Multi-instance safety: ~/.claude is bind-mounted (ADR 0002) so concurrent
# container starts race on this file. flock serialises the read-modify-write
# and mktemp gives each process its own staging file — a fixed .tmp name
# would let two redirects truncate each other's content and leave a 0-byte
# file after one of the renames. Self-heals an empty/corrupt .claude.json so
# a survivor of any past race recovers on next start.
pretrust_workspace_paths() {
    [ -n "$PROJECT_NAME" ] || return 0

    local paths=()
    [ -n "${BOXA_PROJECT_HOST_PATH:-}" ] && paths+=("$BOXA_PROJECT_HOST_PATH")
    paths+=("/workspace/$PROJECT_NAME")

    (
        flock 9

        if [ ! -s "$TARGET/.claude.json" ] \
           || ! jq -e . "$TARGET/.claude.json" >/dev/null 2>&1; then
            echo '{}' > "$TARGET/.claude.json"
        fi

        local needs_update=0 ws
        for ws in "${paths[@]}"; do
            if ! jq -e --arg ws "$ws" \
                '.projects[$ws].hasTrustDialogAccepted == true' \
                "$TARGET/.claude.json" >/dev/null 2>&1; then
                needs_update=1
                break
            fi
        done
        [ "$needs_update" -eq 1 ] || exit 0

        local paths_json tmp
        paths_json=$(printf '%s\n' "${paths[@]}" | jq -R . | jq -s .)
        tmp=$(mktemp "$TARGET/.claude.json.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        jq --argjson paths "$paths_json" \
            'reduce $paths[] as $ws (.; .projects[$ws].hasTrustDialogAccepted = true)' \
            "$TARGET/.claude.json" > "$tmp"
        mv "$tmp" "$TARGET/.claude.json"
        trap - EXIT
    ) 9>"$TARGET/.claude.json.lock"
}

# Every-start. zshrc PATH filter ($^path(N-/)) drops missing dirs, so this
# must exist before the shell starts.
ensure_npm_global_path() {
    mkdir -p /usr/local/share/npm-global/bin
}

# First-start (after volume reset). Existing boxa-npm-global volumes
# (created before Codex moved here) don't auto-populate from the image.
bootstrap_codex_cli() {
    [ ! -x /usr/local/share/npm-global/bin/codex ] || return 0
    echo "Bootstrapping Codex CLI into npm-global volume..."
    if npm install -g @openai/codex; then
        echo "Codex CLI installed"
    else
        WARNINGS+=("Codex CLI install failed — run 'npm install -g @openai/codex' manually")
    fi
}

# Same problem as bootstrap_codex_cli: upgraded boxaes have a pre-existing
# boxa-npm-global volume that masks the image-layer `npm install -g
# agent-browser@${AGENT_BROWSER_VERSION}`, so the CLI is invisible after the
# rebuild. Bootstrap with the image-pinned version (Dockerfile sets ENV
# AGENT_BROWSER_VERSION) so image-layer and bootstrap stay in lockstep.
bootstrap_agent_browser_cli() {
    [ ! -x /usr/local/share/npm-global/bin/agent-browser ] || return 0
    local version="${AGENT_BROWSER_VERSION:-}"
    if [ -z "$version" ]; then
        WARNINGS+=("agent-browser CLI not installed and AGENT_BROWSER_VERSION unset — rebuild the image")
        return 0
    fi
    echo "Bootstrapping agent-browser CLI ($version) into npm-global volume..."
    if npm install -g "agent-browser@${version}"; then
        echo "agent-browser CLI installed"
    else
        WARNINGS+=("agent-browser CLI install failed — run 'npm install -g agent-browser@${version}' manually")
    fi
}

# Every-start. ~/.local/bin/claude lives in the image layer and docker run
# resets it; re-link to the highest version under ~/.local/share/claude/versions.
# That dir is the RO host bind mount on Linux/WSL2 and the shared
# boxa-mac-claude-bin named volume on macOS — either way it holds Linux
# binaries, so this relink is OS-agnostic and needs no change.
repair_claude_bin() {
    [ -d /home/node/.local/share/claude/versions ] || return 0
    local latest
    latest=$(find /home/node/.local/share/claude/versions/ -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
        | sort -V | tail -1)
    [ -n "$latest" ] || return 0
    ln -sf "/home/node/.local/share/claude/versions/$latest" /home/node/.local/bin/claude
    echo "Claude symlink -> $latest"
}

# Every-start. The runtime snapshot is node-readable; convergence never needs
# the gated host MCP store and a stale render must not block Container setup.
converge_mcp_state() {
    # Pre-convergence images lack the wrapper; that is a rebuild, not a fault.
    command -v boxa-mcp-converge >/dev/null 2>&1 || return 0
    if ! boxa-mcp-converge --quiet; then
        WARNINGS+=("MCP convergence incomplete — run 'boxa-mcp-converge' inside the Container for details")
    fi
}

print_summary() {
    if [ "$seeded" -gt 0 ]; then
        echo "Claude Code config seeded ($seeded file(s))"
    else
        echo "Claude Code config OK"
    fi

    if [ "${#WARNINGS[@]}" -gt 0 ]; then
        echo
        echo -e "\033[1;31m==> Setup completed with ${#WARNINGS[@]} warning(s):\033[0m"
        for w in "${WARNINGS[@]}"; do
            echo -e "    \033[1;33m• $w\033[0m"
        done
    fi
}

main() {
    seed_defaults
    migrate_enable_all_project_mcp_servers
    migrate_agent_awake_hooks
    make_workspace_symlink     # before pretrust (logical order, not strict dep)
    pretrust_workspace_paths
    ensure_npm_global_path     # must precede bootstrap_codex (shared parent dir)
    bootstrap_codex_cli
    bootstrap_agent_browser_cli
    repair_claude_bin
    converge_mcp_state
    print_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
