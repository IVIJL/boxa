"""Boxa MCP scoped secret store (ADR 0013, issue 05).

Hassle-free import may COPY inherited MCP env values so a server works inside a
Container without the user re-entering credentials. Those copied VALUES never
go into the canonical profile JSON (`mcp.profile`) — they live here, in a
separate secret store, scoped exactly like the profile:

  * global  -> ``$XDG_CONFIG_HOME/boxa/mcp/secrets.json``
  * project -> ``$XDG_CONFIG_HOME/boxa/mcp/projects/<project>.secrets.json``

(local-plan-mcp.md decision 25). The store file is always created/maintained
with mode ``0600``: only the owner may read the secrets it holds.

Layout: ``{ "version": 1, "servers": { "<name>": { "<ENV_KEY>": "<value>" } } }``.
The profile references env-variable NAMES; this store maps those names to the
copied values for one scoped server. Removing a server's secrets removes only
that server's block — global secrets are never touched by a project operation
and vice versa.

CRITICAL: nothing in this module is ever logged, printed, or returned to the
text/JSON output paths. Callers report which KEYS were copied (names only); the
values stay on disk under 0600.
"""

from __future__ import annotations

import json
import os
import stat
from typing import Any, Optional

from .profile import _sanitize_project, config_root, ensure_store_dir

SECRETS_VERSION = 1

# Owner read/write only. This is the whole point of the secret store.
_SECRET_MODE = 0o600


def global_secrets_path() -> str:
    return os.path.join(config_root(), "secrets.json")


def project_secrets_path(project_key: str) -> str:
    return os.path.join(
        config_root(), "projects", _sanitize_project(project_key) + ".secrets.json"
    )


def secrets_path(scope: str, project_key: Optional[str]) -> str:
    if scope == "project":
        if not project_key:
            raise ValueError("project scope requires a project key")
        return project_secrets_path(project_key)
    return global_secrets_path()


def _empty_store() -> dict[str, Any]:
    return {"version": SECRETS_VERSION, "servers": {}}


def load_secrets(path: str) -> dict[str, Any]:
    """Load a secret store, or a fresh empty store when absent.

    A malformed existing store raises rather than silently dropping secrets the
    user already copied.
    """
    if not os.path.isfile(path):
        return _empty_store()
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"malformed secret store (not an object): {path}")
    data.setdefault("version", SECRETS_VERSION)
    servers = data.get("servers")
    if "servers" not in data:
        data["servers"] = {}
    elif not isinstance(servers, dict):
        # Do not silently reset a malformed store; the next save would clobber
        # any secrets the user already copied.
        raise ValueError(
            f"malformed secret store ('servers' is not an object): {path}"
        )
    return data


def _chmod_0600(path: str) -> None:
    """Force the store file to owner-only read/write."""
    os.chmod(path, _SECRET_MODE)


def save_secrets(path: str, store: dict[str, Any]) -> None:
    """Write the secret store with mode ``0600`` (parent dirs created).

    The temp file is created 0600 BEFORE any secret is written to it, so the
    values never momentarily exist in a world-readable file. The final file is
    chmodded again after ``os.replace`` to defend against a pre-existing target
    with looser permissions.

    The store dir is made traversable+readable (o+rx via `ensure_store_dir`)
    so the broker can always reach the NON-SECRET profile that shares this dir
    (ADR 0014), even when the secret store is written first under a restrictive
    umask. Secret VALUES stay protected by the per-FILE 0600 below, never by
    the dir mode.
    """
    ensure_store_dir(os.path.dirname(path))
    tmp = path + ".tmp"
    # Remove any stale temp file first so O_EXCL below always creates a fresh
    # one. A pre-existing temp (from a crashed run or manual creation) could
    # otherwise carry permissive permissions that O_CREAT|O_TRUNC would keep,
    # exposing secret values during the write window before the chmod.
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    # O_EXCL guarantees we created this file; fchmod the fd to 0600 BEFORE any
    # secret is written, so the values never exist in a wider-than-0600 file.
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, _SECRET_MODE)
    try:
        os.fchmod(fd, _SECRET_MODE)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(store, fh, indent=2, sort_keys=False)
            fh.write("\n")
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.replace(tmp, path)
    _chmod_0600(path)


def store_server_secrets(
    path: str, server_name: str, values: dict[str, str]
) -> None:
    """Store ``values`` (env name -> value) for one server, REPLACING its block.

    A re-import REPLACES the server's secret block rather than merging into it:
    if the user removed or renamed a secret env key in the source config, the
    obsolete value must not linger in the 0600 store while the profile no longer
    references it. Other servers' blocks are left untouched.

    When ``values`` is empty, any EXISTING block for this server is REMOVED so a
    re-import that no longer has secrets does not leave stale credentials behind
    (the store file itself is rewritten if it already existed; if it never
    existed, nothing is created).
    """
    if not values:
        # Nothing to copy. Only touch the store to PURGE a stale block; never
        # create a new store just to write an empty server entry.
        if not os.path.isfile(path):
            return
        store = load_secrets(path)
        if server_name in store["servers"]:
            del store["servers"][server_name]
            save_secrets(path, store)
        return
    store = load_secrets(path)
    # Replace, do not merge: the store must reflect exactly the current
    # candidate's secret env keys for this server.
    store["servers"][server_name] = dict(values)
    save_secrets(path, store)


def read_server_secrets(path: str, server_name: str) -> Optional[dict[str, str]]:
    """Return the stored secret block for one server, or None if absent.

    Used both to snapshot the prior block before a replace/purge (host side) and
    by the Container MCP broker to resolve a server's staged secrets (ADR 0014).
    A MISSING file degrades to None. An UNREADABLE file (``PermissionError`` — a
    file owned by a different UID, which the broker must never be able to read
    from the node-owned mount) ALSO degrades to None rather than raising, so a
    cross-UID secret store never crashes the broker; the caller then treats the
    secret as unavailable (a secret-declaring server reports missing env). NEVER
    log the result.
    """
    if not os.path.isfile(path):
        return None
    try:
        store = load_secrets(path)
    except PermissionError:
        return None
    block = store["servers"].get(server_name)
    if not isinstance(block, dict):
        return None
    return {str(k): str(v) for k, v in block.items()}


def restore_server_secrets(
    path: str, server_name: str, block: Optional[dict[str, str]]
) -> None:
    """Restore a previously-snapshotted secret block (or purge if None).

    The inverse of a replace/purge: ``block`` is the value captured before the
    mutation. ``None`` means the server had no block before, so it is removed.
    """
    if block:
        store_server_secrets(path, server_name, block)
    else:
        store_server_secrets(path, server_name, {})


def file_mode(path: str) -> int:
    """Return the file's permission bits (e.g. ``0o600``) for verification."""
    return stat.S_IMODE(os.stat(path).st_mode)
