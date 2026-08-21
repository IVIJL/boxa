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

# Decide whether boxa may replace an already-installed hook. Two ways to
# qualify: the file announces itself as boxa-owned, or it is byte-for-byte a
# hook boxa shipped before that marker existed. Matching on the descriptive
# header instead would capture files a user customized while keeping the
# comment — that header never promised boxa would overwrite them.
KEEP_AWAKE_HOOK_LEGACY_SHA256=\
11d3a8ed19e58e1cd48467e553d43f66763e7353edc8642513dfa01c82753e71

keep_awake_hook_is_boxa_owned() {
    local file="$1" digest
    grep -q 'boxa-owned: replaced by boxa on update' "$file" 2>/dev/null \
        && return 0
    command -v sha256sum >/dev/null 2>&1 || return 1
    digest="$(sha256sum < "$file" 2>/dev/null | cut -d' ' -f1)"
    [ "$digest" = "$KEEP_AWAKE_HOOK_LEGACY_SHA256" ]
}

# Every-start. Add boxa's keep-awake client hook to existing shared Claude
# config without replacing unrelated user hooks or settings. Re-running is a
# no-op once all three exact entries are present.
migrate_agent_awake_hooks() {
    local migration_dir="$TARGET/.boxa-migrations"
    local status=0

    mkdir -p "$TARGET/hooks" "$migration_dir"
    if [ -f "$DEFAULTS/hooks/agent-awake.sh" ]; then
        # Seed a missing hook, and refresh an outdated one that is still
        # boxa's — an already-seeded copy would otherwise keep an old signal
        # path forever (the loopback-only version silently stopped signalling
        # on WSL2 NAT hosts). A copy the user made their own loses the marker
        # and is left untouched.
        #
        # A symlinked hook is left alone whatever it points at: writing through
        # it would edit a file somewhere else entirely — typically the user's
        # own dotfiles repository — which is never what a boxa refresh should
        # touch. Regular files are replaced through a temporary file so a
        # concurrent Claude event never reads a half-written hook.
        local installed="$TARGET/hooks/agent-awake.sh" staged
        if [ ! -e "$installed" ] && [ ! -L "$installed" ]; then
            cp "$DEFAULTS/hooks/agent-awake.sh" "$installed"
            seeded=$((seeded+1))
        elif [ ! -L "$installed" ] && [ -f "$installed" ] \
            && keep_awake_hook_is_boxa_owned "$installed" \
            && ! cmp -s "$DEFAULTS/hooks/agent-awake.sh" "$installed"; then
            if staged="$(mktemp "$TARGET/hooks/agent-awake.sh.XXXXXX")" \
                && cp "$DEFAULTS/hooks/agent-awake.sh" "$staged" \
                && chmod 0755 "$staged" \
                && mv -f "$staged" "$installed"; then
                seeded=$((seeded+1))
            else
                rm -f "${staged:-}"
            fi
        fi
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
                # The hook command must be the TILDE form: /home/node/.claude
                # is a bind mount of the host ~/.claude, so this settings.json
                # is ALSO read by the host Claude session, where the
                # container-absolute /home/node path does not exist and every
                # hook fire surfaces a "No such file or directory" error.
                # Tilde resolves correctly on both sides of the mount.
                def rewrite_legacy($event; $old; $new):
                    .hooks = (.hooks // {})
                    | .hooks[$event] = ((.hooks[$event] // []) | map(
                        if has("hooks") then
                            .hooks = ((.hooks // []) | map(
                                if .type == "command" and .command == $old
                                then .command = $new
                                else . end))
                        else . end));
                # Order-preserving exact-duplicate removal, on BOTH levels —
                # needed when a config already carried the legacy and the
                # tilde command side by side (as two event entries, or as two
                # commands inside one entry): the rewrite above makes them
                # identical and without the dedupe each hook would fire twice.
                def dedupe_list:
                    reduce .[] as $e ([];
                        if index($e) == null then . + [$e] else . end);
                def dedupe_event($event):
                    .hooks[$event] = ((.hooks[$event] // [])
                        | map(if has("hooks") then .hooks = ((.hooks // []) | dedupe_list) else . end)
                        | dedupe_list);
                def ensure_hook($event; $command):
                    {hooks: [{type: "command", command: $command}]} as $entry
                    | .hooks = (.hooks // {})
                    | .hooks[$event] = ((.hooks[$event] // []) as $entries
                        | if ($entries | index($entry)) == null
                          then $entries + [$entry]
                          else $entries
                          end);
                rewrite_legacy("UserPromptSubmit"; "/home/node/.claude/hooks/agent-awake.sh busy"; "~/.claude/hooks/agent-awake.sh busy")
                | rewrite_legacy("PreToolUse"; "/home/node/.claude/hooks/agent-awake.sh busy"; "~/.claude/hooks/agent-awake.sh busy")
                | rewrite_legacy("Stop"; "/home/node/.claude/hooks/agent-awake.sh idle"; "~/.claude/hooks/agent-awake.sh idle")
                | dedupe_event("UserPromptSubmit")
                | dedupe_event("PreToolUse")
                | dedupe_event("Stop")
                | ensure_hook("UserPromptSubmit"; "~/.claude/hooks/agent-awake.sh busy")
                | ensure_hook("PreToolUse"; "~/.claude/hooks/agent-awake.sh busy")
                | ensure_hook("Stop"; "~/.claude/hooks/agent-awake.sh idle")
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

# Every-start, idempotent. Retirement machinery for hooks boxa used to seed
# but no longer ships. Only a copy that is still byte-for-byte one of the
# shipped versions is retired (file deleted, its exact settings entry
# unwired) — a customized or symlinked copy is the user's now and keeps both
# its file and its wiring; boxa merely stops shipping it.

# hook_digest_matches <file> <sha256>... — file is byte-for-byte one of the
# shipped versions.
hook_digest_matches() {
    local f="$1" digest sha
    shift
    digest="$(sha256sum < "$f" 2>/dev/null | cut -d' ' -f1)"
    for sha in "$@"; do
        [ "$digest" = "$sha" ] && return 0
    done
    return 1
}

# Delete $1 only while it is still a shipped copy — rechecked at the moment
# of deletion, because the shared tree is agent-writable and a copy
# customized after the initial checksum must survive.
remove_shipped_hook() {
    local f="$1"
    shift
    [ -L "$f" ] && return 0
    [ -f "$f" ] || return 0
    hook_digest_matches "$f" "$@" || return 0
    rm -f -- "$f"
}

# retire_seeded_hook <name> <event> <sha256>... — unwire the hook's exact
# seeded settings entry from <event> (empty <event> = boxa never wired it)
# and delete the shipped file. A missing file with wiring still present is a
# dangling entry from a manual delete — unwired the same way.
retire_seeded_hook() {
    local name="$1" event="$2" installed status=0
    local migration_dir="$TARGET/.boxa-migrations" delete_file=false
    shift 2
    installed="$TARGET/hooks/$name"

    [ -L "$installed" ] && return 0    # symlink → user-managed, leave alone
    if [ -f "$installed" ]; then
        command -v sha256sum >/dev/null 2>&1 || return 0
        hook_digest_matches "$installed" "$@" || return 0
        delete_file=true
    fi
    if [ -z "$event" ] || [ ! -e "$TARGET/settings.json" ]; then
        if [ "$delete_file" = true ]; then
            # Never wired by boxa (or no settings at all): delete the
            # shipped file unless the user wired it up themselves.
            if ! grep -qF "$name" "$TARGET/settings.json" 2>/dev/null; then
                remove_shipped_hook "$installed" "$@"
            fi
        fi
        return 0
    fi
    mkdir -p "$migration_dir"

    (
        flock 9 || exit 3
        local source="" tmp=""
        source=$(mktemp "$TARGET/settings.json.source.XXXXXX") || exit 3
        trap '[ -z "${source:-}" ] || rm -f "$source"; [ -z "${tmp:-}" ] || rm -f "$tmp"' EXIT
        tmp=$(mktemp "$TARGET/settings.json.XXXXXX") || exit 3
        cp -- "$TARGET/settings.json" "$source" || exit 3
        jq -e . "$source" >/dev/null 2>&1 || exit 2
        # Both command spellings: the seeded defaults used the container-
        # absolute path; tolerate a tilde-form copy of the same entry.
        # shellcheck disable=SC2088  # the tilde-form spelling is a literal
        if ! jq --arg ev "$event" \
              --arg cmda "/home/node/.claude/hooks/$name" \
              --arg cmdb "~/.claude/hooks/$name" '
            if (type == "object")
               and ((.hooks // {}) | type == "object")
               and (((.hooks // {})[$ev] // []) | type == "array")
               and ((((.hooks // {})[$ev] // []) | length) > 0)
            then
              # Exact-entry removal: only a group that still has the seeded
              # shape ({"hooks":[{type,command}]} — no matcher, no timeout,
              # no extra commands) belongs to boxa and may be taken back.
              .hooks[$ev] = ((.hooks[$ev] // []) | map(select(
                  (
                    ((keys_unsorted | sort) == ["hooks"])
                    and ((.hooks | type) == "array")
                    and ((.hooks | length) == 1)
                    and ((.hooks[0] | type) == "object")
                    and ((.hooks[0] | keys_unsorted | sort) == ["command", "type"])
                    and (.hooks[0].type == "command")
                    and ((.hooks[0].command == $cmda) or (.hooks[0].command == $cmdb))
                  ) | not)))
              | if ((.hooks[$ev] | length) == 0)
                then .hooks |= del(.[$ev]) else . end
            else . end
        ' "$source" > "$tmp"; then
            exit 3
        fi
        if cmp -s "$source" "$tmp"; then
            exit 0
        fi
        # Claude does not share this lock; skip when the shared file moved on
        # meanwhile — this migration runs every start and simply retries.
        cmp -s "$source" "$TARGET/settings.json" || exit 4
        # The tree is agent-writable: a copy customized while we rewrote
        # settings must keep its wiring too — defer to the next start. A
        # file deleted meanwhile leaves dangling wiring, which unwiring
        # handles correctly.
        if [ "$delete_file" = true ] && [ -e "$installed" ]; then
            if [ -L "$installed" ] || ! hook_digest_matches "$installed" "$@"; then
                exit 4
            fi
        fi
        mv "$tmp" "$TARGET/settings.json"
        tmp=""
        exit 0
    ) 9>"$migration_dir/retire-${name%.sh}.lock" || status=$?

    if [ "$status" -eq 0 ]; then
        if [ "$delete_file" = true ]; then
            # An unchanged copy may still be wired in a way the jq filter
            # does not match (moved to another event, custom arguments) —
            # that wiring is the user's; keep its file.
            if ! grep -qF "$name" "$TARGET/settings.json" 2>/dev/null; then
                remove_shipped_hook "$installed" "$@"
            fi
        fi
    elif [ "$status" -eq 2 ]; then
        WARNINGS+=("Hook retirement of $name skipped — $TARGET/settings.json is not valid JSON")
    elif [ "$status" -eq 4 ]; then
        : # concurrent settings write — retried on next start, file kept until then
    else
        WARNINGS+=("Hook retirement of $name failed")
    fi
}

# The Interaction hook fired on every UserPromptSubmit and guessed at
# "waiting for approval" with keyword heuristics that never matched real
# prompts; the Notification event covers that need properly.
INTERACTION_NOTIFY_SHIPPED_SHA256=\
77d89bae948dde90e2f5f2b5ec13661c221f9842276d4941a310615e3ece0724

migrate_remove_interaction_notify() {
    retire_seeded_hook interaction_notify.sh UserPromptSubmit \
        "$INTERACTION_NOTIFY_SHIPPED_SHA256"
}

# The notify hooks (sounds + push message) were personal setup that leaked
# into the seeded defaults: without the author's notification config — and
# with no sounds shipped at all — a fresh install got hooks that only wrote
# a log line on every Stop/Notification event. Anyone who wants
# notifications brings their own hook; ADR 0025 mounts whatever config file
# it sources. Two shas per hook: the ntfy-era shipped bytes and the brief
# provider-agnostic rewrite that never reached a released image.
migrate_retire_notify_hooks() {
    retire_seeded_hook success_notify.sh Stop \
        49249fbe20e6978299999a9c323d0715383e6c794944fc37bff3d9ebdd4c94b1 \
        e07bafb3149d86c4543da34c90245b2052d5b9fd9d351ea54d8189d72124f0e6
    retire_seeded_hook question_notify.sh Notification \
        684936017125a96aa0f1c6039aa6b234d678fcb705bcf66228419ed2c98c030a \
        db0fdabcf5890be21b0b8cdb4a44f5afafa02e93b4c25af2468346fbb4e97db8
    retire_seeded_hook check_error.sh "" \
        7d3ad64eea66af9d503b9ff555bb41a9a70fd953264bb359b74ccc3fbf893be5 \
        ce31b3cddc56fa5b25d87e2a58edae99f738e057264a4cc47a53466639710f60
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
# resets it; regenerate the Container-only launch wrapper there. The wrapper
# resolves the highest mounted version on every invocation, so a host update is
# visible without restarting the Container, and injects only this Project's
# runtime-snapshot MCP profile.
repair_claude_bin() {
    local wrapper_path="/home/node/.local/bin/claude"
    local wrapper_tmp mcp_dev_dir
    wrapper_tmp=$(mktemp "/home/node/.local/bin/.claude-wrapper.XXXXXX")
    mcp_dev_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

    printf '#!/bin/bash\nreadonly _MCP_DEV_DIR=%q\n' "$mcp_dev_dir" > "$wrapper_tmp"
    cat >> "$wrapper_tmp" <<'CLAUDE_WRAPPER'
set -u

readonly _CLAUDE_VERSIONS_DIR="/home/node/.local/share/claude/versions"
readonly _EMPTY_MCP_CONFIG='{"mcpServers":{}}'
readonly _MCP_SHARE_DIR="/usr/local/share/boxa"

latest_version="$(
    find "$_CLAUDE_VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type f \
        -executable -printf '%f\n' 2>/dev/null | sort -V | tail -n 1
)"
claude_bin="$_CLAUDE_VERSIONS_DIR/$latest_version"

if [ -d "$_MCP_SHARE_DIR/mcp" ]; then
    MCP_PY_DIR="$_MCP_SHARE_DIR"
else
    # Dev/test fallback: setup-claude.sh lives beside the mcp package.
    MCP_PY_DIR="$_MCP_DEV_DIR"
fi

if mcp_config="$(
    PYTHONPATH="$MCP_PY_DIR${PYTHONPATH:+:$PYTHONPATH}" \
        python3 -m mcp.cli claude-launch-profile 2>/dev/null
)" && [ -n "$mcp_config" ]; then
    :
else
    mcp_config="$_EMPTY_MCP_CONFIG"
    printf '%s\n' \
        'boxa: warning: cannot derive MCP launch profile; starting with no MCP servers' \
        >&2
fi

exec "$claude_bin" \
    --strict-mcp-config "--mcp-config=$mcp_config" "$@"
CLAUDE_WRAPPER
    chmod 0755 "$wrapper_tmp"
    mv -f "$wrapper_tmp" "$wrapper_path"
    echo "Claude launch wrapper ready"
}

# Every-start. npm upgrades restore this canonical path as a symlink, so replace
# it with the Container-only wrapper after bootstrap on every Container start.
# The wrapper invokes the package entry point directly to avoid recursion.
repair_codex_bin() {
    local wrapper_path="/usr/local/share/npm-global/bin/codex"
    local wrapper_tmp mcp_dev_dir
    wrapper_tmp=$(mktemp "/usr/local/share/npm-global/bin/.codex-wrapper.XXXXXX")
    mcp_dev_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

    printf '#!/bin/bash\nreadonly _MCP_DEV_DIR=%q\n' "$mcp_dev_dir" > "$wrapper_tmp"
    cat >> "$wrapper_tmp" <<'CODEX_WRAPPER'
set -u

readonly _CODEX_ENTRY_POINT="/usr/local/share/npm-global/lib/node_modules/@openai/codex/bin/codex.js"
readonly _CODEX_NODE="/usr/local/bin/node"
readonly _MCP_SHARE_DIR="/usr/local/share/boxa"

if [ -d "$_MCP_SHARE_DIR/mcp" ]; then
    MCP_PY_DIR="$_MCP_SHARE_DIR"
else
    # Dev/test fallback: setup-claude.sh lives beside the mcp package.
    MCP_PY_DIR="$_MCP_DEV_DIR"
fi

codex_args=()
if mcp_overrides="$(
    PYTHONPATH="$MCP_PY_DIR${PYTHONPATH:+:$PYTHONPATH}" \
        python3 -m mcp.cli codex-launch-profile 2>/dev/null
)"; then
    while IFS= read -r override; do
        [ -z "$override" ] || codex_args+=("-c" "$override")
    done <<< "$mcp_overrides"
else
    codex_args=("-c" "mcp_servers={}")
    printf '%s\n' \
        'boxa: warning: cannot derive MCP launch profile; starting with no MCP servers' \
        >&2
fi

# Codex resolves duplicate -c keys last. Keep Boxa's complete MCP profile after
# caller options so no user/skill override can re-enable an unverified server,
# but insert it before `--` so Codex still parses the injected overrides.
launch_args=()
profile_injected=0
for arg in "$@"; do
    if [ "$profile_injected" -eq 0 ] && [ "$arg" = "--" ]; then
        launch_args+=("${codex_args[@]}")
        profile_injected=1
    fi
    launch_args+=("$arg")
done
if [ "$profile_injected" -eq 0 ]; then
    launch_args+=("${codex_args[@]}")
fi
exec "$_CODEX_NODE" "$_CODEX_ENTRY_POINT" "${launch_args[@]}"
CODEX_WRAPPER
    chmod 0755 "$wrapper_tmp"
    mv -f "$wrapper_tmp" "$wrapper_path"
    echo "Codex launch wrapper ready"
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
    migrate_remove_interaction_notify
    migrate_retire_notify_hooks
    make_workspace_symlink     # before pretrust (logical order, not strict dep)
    pretrust_workspace_paths
    ensure_npm_global_path     # must precede bootstrap_codex (shared parent dir)
    bootstrap_codex_cli
    bootstrap_agent_browser_cli
    repair_claude_bin
    repair_codex_bin
    print_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
