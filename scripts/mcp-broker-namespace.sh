#!/bin/bash
set -euo pipefail

# =============================================================================
# mcp-broker-namespace — per-broker mount namespace + idmapped workspace remount
# =============================================================================
# ADR 0014 ("Update 2026-05-31", workspace bullet) + issue 21.
#
# Runs as ROOT inside a PRIVATE mount namespace created by the entrypoint:
#
#     unshare --mount --propagation private -- mcp-broker-namespace
#
# Purpose: give the MCP servers the broker spawns READ/WRITE access to the
# project workspace as a peer-equal citizen of `node`, WITHOUT touching host
# file ownership/permissions and WITHOUT FUSE/setuid/residual-root.
#
# How: inside this namespace ONLY, the SAME absolute $BOXA_PROJECT_HOST_PATH
# is re-mounted as an IDMAPPED bind via util-linux `mount -o X-mount.idmap=…`,
# mapping host UID/GID 1000 -> boxa-mcp's UID/GID. The MCP servers the broker
# spawns INHERIT this namespace, so they see the workspace with files appearing
# owned by boxa-mcp (rw). Because --propagation private keeps the remount
# inside this namespace, `node`'s main-namespace view stays a plain direct bind
# (host 1000:1000) — no overhead, no change for node, host untouched.
#
# The remount happens HERE, as root, BEFORE `exec setpriv … boxa-mcp-broker`
# drops to boxa-mcp (ADR 0003: no setuid, no residual root — the namespace is
# kept alive by the broker running as boxa-mcp; node, with no root and no
# CAP_SYS_ADMIN, cannot enter it).
#
# Detection + fallback: idmapped mounts need an idmap-capable filesystem for the
# source bind. ext4 (the WSL2-native project store) works; a Windows-mounted
# 9p/drvfs project does NOT. We probe by attempting the idmapped remount; if it
# fails we FALL BACK to leaving the workspace as the inherited plain bind (the
# servers then have READ-ONLY-effective access — project files are world-readable
# 0644, so reads are free; writes by boxa-mcp fail at the host-UID boundary).
# The downgrade is LOGGED (never silent) per the no-silent-failures convention.
#
# The runtime sockets in /run (broker socket on the boxa-bridge path, Docker
# socket, secret store) live on tmpfs mounts INHERITED before the unshare, so
# they stay visible/connectable across the boundary — this script NEVER remounts
# /run. The broker socket keeps its boxa-bridge group + 0660 mode (the setgid
# /run/boxa-bridge dir, created in the entrypoint root phase before the
# unshare, forces it).
# =============================================================================

# Workspace path to idmap-remount. Provided by the entrypoint
# (BOXA_PROJECT_HOST_PATH = the literal host project path docker-run.sh mounts
# the project at and exports). Absent for non-project invocations -> no remount,
# broker just launches with the inherited workspace view.
WORKSPACE="${BOXA_PROJECT_HOST_PATH:-}"

# Host-side numeric IDs the workspace files carry. docker-run.sh bind-mounts the
# host project (host user UID/GID 1000) at $BOXA_PROJECT_HOST_PATH, so inside
# the Container the files appear owned by 1000:1000. The idmap maps that single
# source ID to boxa-mcp's ID (a 1-entry range per ADR 0014).
HOST_WS_UID=1000
HOST_WS_GID=1000

# Emit the idmapped-bind mount argv on stdout (one token per line, NUL-safe is
# unnecessary — these are fixed shapes). Kept as a pure function so it is unit-
# testable in isolation: given a source dir, the boxa-mcp UID/GID, and the host
# workspace UID/GID, it produces the exact `mount` command the namespace runs.
#
# The remount targets the SAME absolute path as the source (ADR 0004 parity): we
# bind the existing workspace onto itself with the idmap option. util-linux
# applies X-mount.idmap to the new bind only, so the source view is untouched.
#
# Mapping DIRECTION (do not flip — verified empirically on the host, util-linux
# 2.39.3, ext4): `X-mount.idmap=u:<from>:<to>` maps the backing/filesystem id
# <from> to the id <to> seen inside the mount. The workspace files are backed by
# host UID/GID 1000, and we want them to appear owned by boxa-mcp inside the
# broker namespace, so <from>=host id, <to>=boxa-mcp id:
#   u:1000:1001:1  -> view owner 1001:1001 (boxa-mcp, writable)  ✓
#   u:1001:1000:1  -> view owner 65534    (overflow/nobody)        ✗
# Requires util-linux >= 2.39 (the X-mount.idmap option); older `mount` (e.g.
# 2.38.1) rejects it and remount_workspace_idmapped() falls back to read-only.
build_idmap_mount_cmd() {
    local source="$1" mcp_uid="$2" mcp_gid="$3" host_uid="$4" host_gid="$5"
    printf '%s\n' \
        mount --bind \
        -o "X-mount.idmap=u:${host_uid}:${mcp_uid}:1 g:${host_gid}:${mcp_gid}:1" \
        "$source" "$source"
}

# Attempt the idmapped remount of $WORKSPACE in place. Returns 0 on success
# (workspace is now boxa-mcp-writable inside this namespace), 1 on failure
# (caller falls back to the inherited read-only-effective bind and logs it).
#
# Idempotent-safe: a private mount namespace starts as a copy of the parent, so
# the bind+idmap here only affects this namespace. We do not pre-clean — a fresh
# namespace per broker means there is never a stale idmap mount to remove.
remount_workspace_idmapped() {
    local source="$1"
    # Resolve boxa-mcp's numeric UID/GID for the idmap target. These come from
    # the image's /etc/passwd (system account), not from any host metadata.
    # Resolved here (not at source time) so the function is the single place the
    # account lookup happens — keeping the top-level sourcing side-effect-free.
    local mcp_uid mcp_gid
    mcp_uid="$(id -u boxa-mcp)"
    mcp_gid="$(id -g boxa-mcp)"
    local -a cmd
    mapfile -t cmd < <(
        build_idmap_mount_cmd \
            "$source" "$mcp_uid" "$mcp_gid" "$HOST_WS_UID" "$HOST_WS_GID"
    )
    # The kernel rejects X-mount.idmap on a filesystem that does not support
    # idmapped mounts (9p/drvfs) with EINVAL; ext4 succeeds. Treat any failure
    # as "unsupported here" and let the caller fall back — we never touch host
    # metadata as an alternative.
    "${cmd[@]}" 2>/dev/null
}

main() {
    if [ -z "$WORKSPACE" ]; then
        # No project workspace (non-project invocation). Nothing to remap; the
        # broker launches with the inherited mount view. Not an error.
        :
    elif [ ! -d "$WORKSPACE" ]; then
        # The path was exported but is not a directory in this namespace — the
        # workspace bind is missing. Log and continue with the inherited view;
        # this is a configuration anomaly, not a fatal broker condition.
        echo "boxa: WARNING: MCP workspace path '$WORKSPACE' is not a directory in the broker namespace; servers get the inherited (read-only-effective) view." >&2
    elif remount_workspace_idmapped "$WORKSPACE"; then
        # Success: workspace is now writable by boxa-mcp inside this namespace.
        # Quiet on success (the common, healthy path).
        :
    else
        # Fallback: idmap unsupported on this filesystem (e.g. a Windows-mounted
        # 9p/drvfs project). The broker still runs; its servers see the inherited
        # plain bind, which is READ-ONLY-effective for boxa-mcp (host files are
        # world-readable 0644, so reads work; writes hit the host-UID boundary).
        # We do NOT chmod/chgrp the host as an alternative (host stays untouched).
        echo "boxa: NOTICE: workspace idmapped remount unavailable (non-idmap filesystem, e.g. a Windows-mounted project); MCP servers get READ-ONLY workspace access. Move the project to the WSL2-native (ext4) filesystem for read/write." >&2
    fi

    # Drop to boxa-mcp and launch the always-on broker, INSIDE this mount
    # namespace, so every server the broker spawns inherits the (idmapped or
    # plain) workspace view. This is the credential-reset drop (ADR 0014): --reuid
    # + --regid + --init-groups resets UID, GID, and supplementary groups to
    # boxa-mcp's own. env -i then starts from a clean slate (setpriv preserves
    # the environment) and sets exactly boxa-mcp's runtime env — mirroring the
    # entrypoint's prior inline launch (issue 15 hardening + issue 20 Docker
    # propagation), now hoisted here so the broker runs in the namespace.
    #
    #   * HOME + npm/npx cache under boxa-mcp's own writable HOME (npx servers);
    #   * XDG_CONFIG_HOME -> the GATED host MCP store mount so the broker reads the
    #     live secret-free profile (node-unreadable 0700 parent);
    #   * BOXA_MCP_SECRETS_DIR -> the private staged secret dir (issue 16);
    #   * DOCKER_HOST + XDG_RUNTIME_DIR -> the rootless Docker daemon, so the broker
    #     can forward them to docker-launcher servers it spawns (issue 20). Passed
    #     from the (image-ENV) environment so they are not duplicated here; empty if
    #     this image has no rootless Docker, in which case the broker forwards
    #     nothing (broker.py only propagates non-empty values).
    #   * a minimal PATH including npm-global bin (npx/node) + system dirs.
    exec setpriv --reuid=boxa-mcp --regid=boxa-mcp --init-groups \
        -- env -i \
            HOME=/home/boxa-mcp \
            USER=boxa-mcp \
            LOGNAME=boxa-mcp \
            XDG_CONFIG_HOME=/run/boxa-mcp/host \
            BOXA_MCP_SECRETS_DIR=/run/boxa-mcp/secrets \
            DOCKER_HOST="$DOCKER_HOST" \
            XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
            npm_config_cache=/home/boxa-mcp/.npm \
            XDG_CACHE_HOME=/home/boxa-mcp/.cache \
            PATH=/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin \
            /usr/local/bin/boxa-mcp-broker
}

# Allow sourcing for unit tests (build_idmap_mount_cmd) without running main.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
