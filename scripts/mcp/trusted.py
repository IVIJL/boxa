"""Independent agent-trusted authorization from the host runtime snapshot.

The broker reply is untrusted input: service-isolated children share its UID
and may replace the bridge socket.  Both broker and node relay therefore derive
the only acceptable launch plan from the same secret-free, host-owned snapshot.
The relay reads it through a dedicated read-only directory mount whose fixed
path is not affected by ambient agent environment.
"""

from __future__ import annotations

import json
import os
import stat
from typing import Any, Callable, Optional

from .catalog import (
    AGENT_TRUSTED_FIXED_ENV_KEYS,
    CATALOG_VERSION,
    CatalogError,
    _validate_entry,
)

RUNTIME_VERSION = 1
RUNTIME_SNAPSHOT_PATH = "/run/boxa-mcp-runtime/catalog-runtime.json"

AGENT_HOME = "/home/node"
AGENT_RUNTIME = "/run/user/1000"
AGENT_PATH = (
    "/home/node/.claude/local/bin:/home/node/.local/bin:"
    "/home/node/.cargo/bin:/home/node/.atuin/bin:"
    "/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin"
)
DOCKER_SOCKET = "/run/user/1000/docker.sock"
SSH_SOCKET = "/tmp/ssh-agent.sock"


class TrustedAuthorizationError(RuntimeError):
    """Malformed snapshot, refused activation, or mismatched launch plan."""


def runtime_snapshot_path() -> str:
    """Fixed node-readable Container path; intentionally no env override."""
    return RUNTIME_SNAPSHOT_PATH


def load_runtime_snapshot(path: Optional[str] = None) -> dict[str, Any]:
    path = path or runtime_snapshot_path()
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode):
            raise TrustedAuthorizationError(
                f"MCP runtime snapshot is not a regular file: {path}"
            )
        with open(path, "rb") as fh:
            raw = fh.read()
    except TrustedAuthorizationError:
        raise
    except OSError as exc:
        raise TrustedAuthorizationError(
            f"cannot read host-owned MCP runtime snapshot: {exc}"
        ) from exc
    return parse_runtime_snapshot(raw)


def parse_runtime_snapshot(raw: bytes) -> dict[str, Any]:
    """Validate the exact runtime snapshot bytes used by a consumer."""
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeError, ValueError) as exc:
        raise TrustedAuthorizationError(
            f"cannot read host-owned MCP runtime snapshot: {exc}"
        ) from exc
    if not isinstance(data, dict) or data.get("version") != RUNTIME_VERSION:
        raise TrustedAuthorizationError(
            "MCP runtime snapshot is malformed or unsupported"
        )
    if data.get("catalogVersion") != CATALOG_VERSION:
        raise TrustedAuthorizationError(
            "MCP runtime snapshot has unsupported catalog version"
        )
    entries = data.get("entries")
    projects = data.get("projects")
    if not isinstance(entries, dict) or not isinstance(projects, dict):
        raise TrustedAuthorizationError("MCP runtime snapshot has invalid maps")
    tracked_mcp_json = data.get("trackedMcpJson", {})
    if not isinstance(tracked_mcp_json, dict) or any(
        not isinstance(project, str)
        or not project
        or not isinstance(value, bool)
        for project, value in tracked_mcp_json.items()
    ):
        raise TrustedAuthorizationError(
            "MCP runtime snapshot has malformed tracked .mcp.json consent"
        )
    seeded_approvals = data.get("seededApprovals", {})
    if not isinstance(seeded_approvals, dict) or any(
        not isinstance(project, str)
        or not project
        or not isinstance(names, list)
        or any(not isinstance(name, str) for name in names)
        for project, names in seeded_approvals.items()
    ):
        raise TrustedAuthorizationError(
            "MCP runtime snapshot has malformed seeded approvals"
        )
    data.setdefault("seededApprovals", seeded_approvals)
    try:
        for entry_id, entry in entries.items():
            _validate_entry(entry_id, entry)
    except CatalogError as exc:
        raise TrustedAuthorizationError(str(exc)) from exc
    for project, records in projects.items():
        if not isinstance(project, str) or not project or not isinstance(records, dict):
            raise TrustedAuthorizationError(
                "MCP runtime snapshot has malformed Project records"
            )
        for entry_id, record in records.items():
            if not isinstance(record, dict) or record.get("catalogId") != entry_id:
                raise TrustedAuthorizationError(
                    "MCP runtime snapshot has malformed activation"
                )
            consumers = record.get("consumers")
            if not isinstance(consumers, list) or not consumers or any(
                consumer not in {"claude", "codex"} for consumer in consumers
            ):
                raise TrustedAuthorizationError(
                    "MCP runtime snapshot has malformed activation consumers"
                )
            if "enabled" in record and not isinstance(record["enabled"], bool):
                raise TrustedAuthorizationError(
                    "MCP runtime snapshot has malformed activation enabled flag"
                )
    return data


def authorize_entry(
    runtime: dict[str, Any],
    server: str,
    project_key: str,
    catalog_id: str,
    consumer: str,
) -> dict[str, Any]:
    """Bind stable ID/name, exact Project activation, consumer, and mode."""
    entry = runtime["entries"].get(catalog_id)
    if not isinstance(entry, dict):
        raise TrustedAuthorizationError(
            f"catalog entry {catalog_id!r} is deleted or unavailable (refused)"
        )
    if entry.get("name") != server:
        raise TrustedAuthorizationError(
            f"catalog entry {catalog_id!r} does not match server {server!r} (refused)"
        )
    records = runtime["projects"].get(project_key)
    activation = records.get(catalog_id) if isinstance(records, dict) else None
    if not isinstance(activation, dict):
        raise TrustedAuthorizationError(
            f"server {server!r} has no activation for this Project (refused)"
        )
    if activation.get("enabled", True) is False:
        raise TrustedAuthorizationError(
            f"server {server!r} activation is disabled for this Project"
        )
    consumers = activation.get("consumers")
    if not isinstance(consumers, list) or consumer not in consumers:
        raise TrustedAuthorizationError(
            f"server {server!r} is not activated for consumer {consumer!r} (refused)"
        )
    return entry


def resolve_launch_cwd(requested_cwd: Optional[str]) -> Optional[str]:
    if not requested_cwd or not os.path.isdir(requested_cwd):
        return None
    if not os.access(requested_cwd, os.R_OK | os.X_OK):
        return None
    return requested_cwd


def path_is_socket(path: str) -> bool:
    try:
        return stat.S_ISSOCK(os.stat(path).st_mode)
    except OSError:
        return False


def build_launch_plan(
    entry: dict[str, Any],
    catalog_id: str,
    consumer: str,
    requested_cwd: Optional[str],
    *,
    socket_probe: Callable[[str], bool] = path_is_socket,
) -> dict[str, Any]:
    """Reconstruct the sole valid deterministic clean node launch plan."""
    if entry.get("executionMode") != "agent-trusted":
        raise TrustedAuthorizationError(
            f"server {entry.get('name')!r} is not agent-trusted (refused)"
        )
    secret_keys = entry.get("secretEnvKeys", [])
    if secret_keys:
        raise TrustedAuthorizationError(
            "agent-trusted entry declares incompatible secret keys: "
            + ", ".join(sorted(str(key) for key in secret_keys))
        )
    declared_env = entry.get("env", {})
    if not isinstance(declared_env, dict):
        raise TrustedAuthorizationError("agent-trusted entry env is malformed")
    fixed_overrides = set(declared_env) & AGENT_TRUSTED_FIXED_ENV_KEYS
    if fixed_overrides:
        raise TrustedAuthorizationError(
            "agent-trusted entry overrides fixed environment: "
            + ", ".join(sorted(fixed_overrides))
        )
    argv = entry.get("command", {}).get("argv")
    if not isinstance(argv, list) or not argv or any(
        not isinstance(value, str) for value in argv
    ):
        raise TrustedAuthorizationError("agent-trusted entry argv is malformed")
    env = {
        "HOME": AGENT_HOME,
        "USER": "node",
        "LOGNAME": "node",
        "PATH": AGENT_PATH,
        "XDG_CONFIG_HOME": f"{AGENT_HOME}/.config",
        "XDG_CACHE_HOME": f"{AGENT_HOME}/.cache",
        "XDG_DATA_HOME": f"{AGENT_HOME}/.local/share",
        "XDG_STATE_HOME": f"{AGENT_HOME}/.local/state",
        "XDG_RUNTIME_DIR": AGENT_RUNTIME,
        "NPM_CONFIG_PREFIX": "/usr/local/share/npm-global",
    }
    if socket_probe(DOCKER_SOCKET):
        env["DOCKER_HOST"] = f"unix://{DOCKER_SOCKET}"
    if socket_probe(SSH_SOCKET):
        env["SSH_AUTH_SOCK"] = SSH_SOCKET
    env.update({str(key): str(value) for key, value in declared_env.items()})
    return {
        "executionMode": "agent-trusted",
        "catalogId": catalog_id,
        "consumer": consumer,
        "argv": list(argv),
        "env": env,
        "cwd": resolve_launch_cwd(requested_cwd),
    }
