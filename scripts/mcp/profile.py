"""Boxa canonical MCP profile state (ADR 0013, issue 05).

This is the first WRITE path. The canonical profile is the boxa-owned source
of truth for Container MCP servers; agent-specific config (Claude Code, Codex)
is *rendered* from it in a later slice (issue 06). The profile is:

  * agent-neutral JSON with a schema ``version`` (local-plan-mcp.md decision 24);
  * commands stored as ``argv`` ARRAYS, never shell strings;
  * SECRET-FREE — env-variable NAMES only, never values. Copied secret VALUES
    live in the separate scoped secret store (`mcp.secrets`), never here.

Scope-aware paths (local-plan-mcp.md decision 24):

  * global  -> ``$XDG_CONFIG_HOME/boxa/mcp/profile.json``
               (``~/.config`` when XDG_CONFIG_HOME is unset)
  * project -> ``$XDG_CONFIG_HOME/boxa/mcp/projects/<project>.json``

The ``<project>`` filename is derived from the project key with the shared ADR
0005 sanitizer so it is a safe, stable basename (no path separators) regardless
of the absolute project path the source agent used as its record key.
"""

from __future__ import annotations

import hashlib
import json
import os
from typing import Any, Optional

# Schema version for the profile JSON. Independent of the candidate-envelope
# SCHEMA_VERSION in `mcp.candidate`: this versions the stored profile shape so
# future migrations can branch on it.
PROFILE_VERSION = 1

# The profile store dir (and its ``projects/`` subdir) hold NON-SECRET profile
# JSON that the Container MCP broker, running as ``boxa-mcp`` (a different UID
# than the host writer), must always be able to traverse and read over the
# read-only bind-mount (ADR 0014). The dir is force-set traversable+readable
# (o+rx) and non-secret profile files force-set readable (o+r), independent of
# the host umask, so a restrictive host umask never makes the secret-free
# profile unreadable to the broker. Secret VALUES are protected per-file: the
# secret store force-chmods its own files 0600 (mcp.secrets), so a traversable
# shared dir does not expose them.
_STORE_DIR_MODE = 0o755
_PROFILE_FILE_MODE = 0o644


def ensure_store_dir(path: str) -> None:
    """Create ``path`` and force it traversable+readable (o+rx), umask-proof.

    Used for the MCP store dir and its ``projects/`` subdir so the broker
    (a distinct UID) can always reach the bind-mounted NON-SECRET profile.
    Secret files inside are still protected per-file (mcp.secrets force-chmods
    them 0600), so a traversable dir does not leak any credential.

    Both ``path`` and the store root (``config_root()``) are force-chmodded.
    When writing a project file, ``path`` is the ``projects/`` subdir and its
    parent ``config_root()`` is only an implicit ``makedirs`` parent — it would
    otherwise keep the host umask and block the broker from traversing down to
    the profile mounted at the store root.
    """
    os.makedirs(path, exist_ok=True)
    os.chmod(path, _STORE_DIR_MODE)
    root = config_root()
    if os.path.isdir(root):
        os.chmod(root, _STORE_DIR_MODE)


def config_root() -> str:
    """Root of boxa's MCP state, honoring ``XDG_CONFIG_HOME``.

    Tests inject a temp HOME / XDG_CONFIG_HOME so the real ``~/.config/boxa``
    is never touched.
    """
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = xdg if xdg else os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "boxa", "mcp")


def _sanitize_project(project_key: str) -> str:
    """Map a project record key to a safe, stable, COLLISION-RESISTANT basename.

    The readable part mirrors the ADR 0005 sanitizer used by the shell
    dispatcher: lower-case the basename and replace any run of non-alphanumeric
    characters with a single ``-``. But the basename alone is not unique — two
    distinct project records can share it (``/work/a/api`` and ``/work/b/api``),
    and a basename-only filename would let one project's profile/secrets
    overwrite the other's. So a short hash of the FULL, normalized project key is
    appended: same project key -> same filename (stable), different key ->
    different filename (no cross-project clobber).

    The hash is over identity only (an absolute path), never a secret, so it is
    safe to derive and emit.
    """
    normalized = project_key.rstrip("/") or project_key
    base = os.path.basename(normalized) or normalized
    out: list[str] = []
    prev_dash = False
    for ch in base.lower():
        if ch.isalnum():
            out.append(ch)
            prev_dash = False
        elif not prev_dash:
            out.append("-")
            prev_dash = True
    readable = "".join(out).strip("-") or "project"
    digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:10]
    return f"{readable}-{digest}"


def global_profile_path() -> str:
    return os.path.join(config_root(), "profile.json")


def project_profile_path(project_key: str) -> str:
    return os.path.join(
        config_root(), "projects", _sanitize_project(project_key) + ".json"
    )


def profile_path(scope: str, project_key: Optional[str]) -> str:
    """Profile file path for a scope.

    ``scope`` is ``"global"`` or ``"project"``; ``project_key`` is required for
    project scope (the source project record key).
    """
    if scope == "project":
        if not project_key:
            raise ValueError("project scope requires a project key")
        return project_profile_path(project_key)
    return global_profile_path()


def _empty_profile() -> dict[str, Any]:
    return {"version": PROFILE_VERSION, "servers": {}}


def load_profile(path: str) -> dict[str, Any]:
    """Load a profile file, or a fresh empty profile when absent/unreadable.

    A malformed existing file raises rather than silently discarding user
    state — apply must not clobber a profile it cannot understand.
    """
    if not os.path.isfile(path):
        return _empty_profile()
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"malformed profile (not an object): {path}")
    data.setdefault("version", PROFILE_VERSION)
    servers = data.get("servers")
    if "servers" not in data:
        # A fresh-but-versioned file with no servers map yet: start one. This is
        # not corruption — it is an empty profile.
        data["servers"] = {}
    elif not isinstance(servers, dict):
        # A present-but-malformed servers field must NOT be silently reset, or
        # the next save would overwrite the file and drop existing state.
        raise ValueError(f"malformed profile ('servers' is not an object): {path}")
    return data


def save_profile(path: str, profile: dict[str, Any]) -> None:
    """Write a profile file atomically (parent dirs created as needed).

    The profile is NON-SECRET, but the Container MCP broker (a different UID
    than the host writer) must always be able to read it over the read-only
    bind-mount (ADR 0014). So both the store dir and the file are force-set
    broker-readable independent of the host umask: the dir is made traversable
    (o+rx via `ensure_store_dir`) and the file readable (o+r). Unlike the
    secret store — force-chmodded 0600 in `mcp.secrets` — these carry no
    credential, and secrets in the same dir stay protected per-file.
    """
    ensure_store_dir(os.path.dirname(path))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(profile, fh, indent=2, sort_keys=False)
        fh.write("\n")
    os.replace(tmp, path)
    # Force the final file broker-readable regardless of the host umask (it is
    # non-secret). chmod the post-replace path so a pre-existing stricter file
    # is loosened too.
    os.chmod(path, _PROFILE_FILE_MODE)


def build_server_entry(
    *,
    name: str,
    argv: list[str],
    env_keys: list[str],
    secret_env_keys: list[str],
    type_: Optional[str],
    source_provider: str,
    import_id: str,
    env: Optional[dict[str, str]] = None,
) -> dict[str, Any]:
    """Build one agent-neutral, SECRET-FREE profile server entry.

    Stores the command as an argv array and the env-variable NAMES only. The
    ``secretEnvKeys`` subset records which names boxa treats as credentials;
    their VALUES (when the user opted to copy them) live exclusively in the
    scoped secret store. ``importId`` ties the entry back to its inherited
    source for traceability without embedding any secret.

    ``env`` is an optional map of NON-secret env name -> value carried over from
    the source config (e.g. ``BASE_URL``). These are not credentials, so they are
    safe to record here; the wrapper reads them at launch so an imported server
    whose config supplied non-secret values inline still starts without the user
    re-exporting them. A SECRET name must never appear in this map.
    """
    entry: dict[str, Any] = {
        "name": name,
        "type": type_ or "stdio",
        "command": {"argv": list(argv)},
        "envKeys": list(env_keys),
        "secretEnvKeys": list(secret_env_keys),
        "source": {"provider": source_provider, "importId": import_id},
    }
    # Only record non-secret values, and never a name flagged secret (defense in
    # depth against a caller passing a secret through the wrong channel).
    if env:
        secret = set(secret_env_keys)
        nonsecret = {k: v for k, v in env.items() if k not in secret}
        if nonsecret:
            entry["env"] = nonsecret
    return entry
