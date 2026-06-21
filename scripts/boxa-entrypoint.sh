#!/bin/bash
set -euo pipefail

# Container entrypoint with root → node privilege drop.
#
# Container starts as UID 0 via `docker run --user 0`. This script's root
# phase runs the only operations that require root (firewall, host-home
# symlink, system gitconfig), then exec's setpriv to drop to node. setpriv
# performs a clean execve after switching credentials (no fork), so PID 1
# becomes this script running as node — no residual root parent in the
# process tree. Combined with no NOPASSWD sudoers entries and no setuid
# bridges, there is no path back to root from inside the container.
# See docs/adr/0003 for the security rationale.

if [ "$(id -u)" = "0" ]; then
    # Stage host gitconfig as system-wide config. Bind-mounted gitconfig
    # files trigger "Device busy" when VS Code/Cursor credential helpers
    # rewrite them; copying to /etc/gitconfig sidesteps the bind mount.
    cp /home/node/.gitconfig-host /etc/gitconfig 2>/dev/null || true

    # Volumes for IDE servers may be created as root on first mount.
    chown node:node /home/node/.cursor-server /home/node/.vscode-server 2>/dev/null || true

    # Bridge $HOST_HOME (host user's home dir) to /home/node (container user's
    # home, where the bind mounts live). Two requirements collide:
    #
    # 1. Claude's plugin registry stores absolute paths under
    #    /home/<host-user>/.claude/... (see ADR 0002), so those paths must
    #    resolve into the bind mount.
    # 2. Phase 2 (ADR 0004) bind-mounts each project at its literal host path
    #    (e.g. /home/<host-user>/Projekty/X) so getcwd(2) inside the
    #    container returns the host path — needed for plugin/session parity.
    #    A whole-dir symlink at /home/<host-user> would make the kernel
    #    canonicalise getcwd() to /home/node/... and defeat parity.
    #
    # Solution: $HOST_HOME is a real directory whose contents mirror
    # /home/node via per-entry symlinks. Project mounts live as real subdirs
    # alongside the mirror, so their canonical paths match the host.
    if [ -n "${HOST_HOME:-}" ] && [ "$HOST_HOME" != "/home/node" ]; then
        # Heal pre-Phase-2 layout (whole-dir symlink) by replacing it.
        if [ -L "$HOST_HOME" ]; then
            rm -f "$HOST_HOME"
        fi
        mkdir -p "$HOST_HOME"
        chown node:node "$HOST_HOME"
        shopt -s dotglob nullglob
        for entry in /home/node/*; do
            name=$(basename "$entry")
            [ -e "$HOST_HOME/$name" ] || [ -L "$HOST_HOME/$name" ] || \
                ln -sfn "$entry" "$HOST_HOME/$name"
        done
        shopt -u dotglob nullglob
    fi

    /usr/local/bin/init-firewall.sh

    # Container identity file (ADR 0011 Layer 1). Single source of truth
    # for "am I inside a boxa container, and which project?" — read by
    # the agent-context hook and the boxa skill's identity check. The
    # file's presence is the signal; the project field is consumed to
    # construct host-side command examples. Root-owned, world-readable.
    # Idempotent across container restarts: the redirect truncates the
    # existing file in place, so no orphan tmp files accumulate. `jq -n`
    # guarantees valid JSON regardless of project-name content (the value
    # is LDH-sanitised upstream per ADR 0005, but defence-in-depth keeps
    # any future relaxation of the sanitiser from producing malformed JSON).
    mkdir -p /etc/boxa
    # projectKey is the FULL host-path key for this Container's Project (ADR
    # 0014 issue 15): the MCP broker uses it to bind Project-scoped requests to
    # exactly this Container, defeating a basename collision between two Projects
    # (e.g. /work/a/api vs /work/b/api). It is the same absolute host path
    # docker-run.sh mounts the project at and exports as BOXA_PROJECT_HOST_PATH
    # — non-secret identity metadata. Absent for non-project invocations; the
    # broker then falls back to the (weaker) Project-name guard. Emitted only
    # when set so existing identity-file readers ignoring it are unaffected.
    jq -n \
        --arg project "${BOXA_PROJECT_NAME:-unknown}" \
        --arg projectKey "${BOXA_PROJECT_HOST_PATH:-}" \
        '{project: $project} + (if $projectKey == "" then {} else {projectKey: $projectKey} end)' \
        > /etc/boxa/identity.json
    chmod 0644 /etc/boxa/identity.json

    # Container MCP broker (ADR 0014, issue 15). Start the always-on broker as
    # the dedicated unprivileged `boxa-mcp` account BEFORE dropping PID 1 to
    # node, so MCP servers run behind a UID boundary the agent cannot cross.
    #
    # The drop MUST reset the full credential set, not just the UID:
    #   --reuid alone would leave the broker with root's GID and supplementary
    #   groups, re-exposing group-readable root-owned files — the opposite of
    #   what a credential-isolation component needs. --regid boxa-mcp
    #   --init-groups sets the primary group to boxa-mcp and reinitialises
    #   supplementary groups from /etc/group for that account, so the broker
    #   holds ONLY boxa-mcp's own groups (ADR 0014). Owned by boxa-mcp, the
    #   broker is unsignalable / unptraceable by node.
    #
    # The broker socket lives on the NEUTRAL `boxa-bridge` runtime path (ADR
    # 0014, issue 19), created here (root) OUTSIDE any 0700 secret dir
    # (connecting exposes only a stdio pipe, no credential). The dir is owned
    # boxa-mcp:boxa-bridge mode 2770 (setgid): the broker (boxa-mcp) owns
    # it and creates the socket there, while node — a member of `boxa-bridge`,
    # NOT of boxa-mcp's primary group — traverses+connects via the bridge. The
    # setgid bit forces the socket the broker creates to inherit group
    # `boxa-bridge` (otherwise it would take boxa-mcp's primary group and
    # node could not reach it). The broker always runs, even with no profile, so
    # a server imported into a running Container works next session.
    #
    # The boxa-mcp runtime root /run/boxa-mcp stays 0700 boxa-mcp-OWNER-only
    # (no bridge group here): it holds the PRIVATE staged secret dir and the gated
    # profile mount, none of which node may ever traverse. The bridge is for
    # SOCKETS ONLY — never for secrets. The staged secret dir is 0700
    # boxa-mcp:boxa-mcp; the root phase below stages the in-scope secret files
    # (global + THIS Container's Project) into it as 0400 boxa-mcp files (issue
    # 16, scripts/stage-mcp-secrets.sh); the broker reads secret VALUES only from
    # here, never from the node-owned profile mount.
    if id boxa-mcp >/dev/null 2>&1; then
        install -d -o boxa-mcp -g boxa-bridge -m 2770 /run/boxa-bridge
        install -d -o boxa-mcp -g boxa-mcp -m 0700 /run/boxa-mcp
        install -d -o boxa-mcp -g boxa-mcp -m 0700 /run/boxa-mcp/secrets

        # Gate the host MCP store mount (ADR 0014, issue 16). docker-run.sh
        # bind-mounts host ~/.config/boxa/mcp read-only at
        # /run/boxa-mcp/host/boxa/mcp. Docker creates the mount-point PARENTS
        # (/run/boxa-mcp/host, .../host/boxa) as root:root 0755 before this
        # script runs, so node could otherwise traverse to the (node-UID-readable)
        # 0600 secret files. Re-own the parent chain to boxa-mcp 0700 so ONLY
        # boxa-mcp can traverse it: node — even as a member of the boxa-mcp
        # group — gets nothing from 0700, and the broker (running as boxa-mcp)
        # reads the live secret-free profile through it. The :ro mount itself is
        # left untouched (its perms come from the host file). Done only when the
        # mount is present (no host store -> nothing imported -> nothing to gate).
        if [ -d /run/boxa-mcp/host ]; then
            chown boxa-mcp:boxa-mcp /run/boxa-mcp/host
            chmod 0700 /run/boxa-mcp/host
            if [ -d /run/boxa-mcp/host/boxa ]; then
                chown boxa-mcp:boxa-mcp /run/boxa-mcp/host/boxa
                chmod 0700 /run/boxa-mcp/host/boxa
            fi
            # Stage the in-scope secrets root-side (root reads the host 0600
            # files through the gated mount; node never can). The reusable
            # staging step also serves issue 17's `boxa mcp reload`. It copies
            # only global + THIS Project's store into the private 0400 dir; a
            # secret value is never logged (scope labels/basenames only).
            /usr/local/bin/stage-mcp-secrets || \
                echo "boxa: WARNING: MCP secret staging failed; secret-bearing servers may report missing env." >&2
        fi
        # Launch the broker inside its OWN mount namespace so the project
        # workspace can be re-mounted READ/WRITE for boxa-mcp without touching
        # the host or node's view (ADR 0014 "Update 2026-05-31", issue 21).
        #
        # `unshare --mount --propagation private` gives the broker a private copy
        # of the mount tree; mcp-broker-namespace then idmap-remounts the SAME
        # absolute $BOXA_PROJECT_HOST_PATH there (host 1000:1000 -> boxa-mcp)
        # and execs the credential-drop + broker. Because the remount is private,
        # node's main-namespace workspace stays a plain direct bind (no overhead,
        # host untouched); the servers the broker spawns INHERIT the namespace and
        # see the workspace writable. On a non-idmap filesystem (Windows-mounted
        # 9p/drvfs) the remount fails and the script falls back to the inherited
        # read-only-effective bind, logging the downgrade (no silent fallback).
        #
        # ORDERING IS LOAD-BEARING: the /run/boxa-bridge socket dir + the
        # /run/boxa-mcp secret/profile dirs are created ABOVE, BEFORE this
        # unshare. They live on /run tmpfs inherited into the private namespace,
        # so the broker socket the broker creates there stays visible/connectable
        # from node's main namespace (the relay still reaches the broker) and the
        # setgid /run/boxa-bridge dir still forces the socket's boxa-bridge
        # group + 0660 mode. This script NEVER remounts /run.
        #
        # The credential reset + clean boxa-mcp env (issue 15) and the broker
        # launch live in mcp-broker-namespace so they run INSIDE the namespace as
        # boxa-mcp (ADR 0003: remount as root first, then exec setpriv — no
        # setuid, no residual root; the namespace is kept alive by the broker
        # running as boxa-mcp, which node cannot enter).
        unshare --mount --propagation private \
            -- /usr/local/bin/mcp-broker-namespace &
    else
        echo "boxa: WARNING: boxa-mcp account missing; MCP broker not started." >&2
    fi

    exec setpriv --reuid=node --regid=node --init-groups -- "$0" "$@"
fi

# Node phase: keep PID 1 alive with graceful shutdown for inner DinD.
shutdown_handler() {
    echo "boxa: SIGTERM received, stopping inner containers..."
    if [ -S "$XDG_RUNTIME_DIR/docker.sock" ] && docker info >/dev/null 2>&1; then
        inner=$(docker ps --format "{{.ID}} {{.Names}}" 2>/dev/null)
        if [ -n "$inner" ]; then
            while read -r cid cname; do
                echo "  Stopping: $cname ($cid)"
                docker stop -t 30 "$cid" >/dev/null 2>&1 || true
            done <<< "$inner"
        fi
        echo "boxa: Inner containers stopped."
    fi
    exit 0
}

trap shutdown_handler SIGTERM SIGINT

# bash ignores signals during foreground sleep; run sleep in background and wait.
while true; do
    sleep 60 &
    wait $! || true
done
