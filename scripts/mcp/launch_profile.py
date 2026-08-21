"""Derive per-invocation agent MCP profiles from the runtime snapshot.

Launch wrappers use this module instead of shared agent configuration files.
The Project/activation join is consumer-neutral so later wrappers can reuse the
same selection while rendering their agent's native command-line shape.
"""

from __future__ import annotations

import json
import os
import re
import stat
import sys
import tomllib
from typing import Any, Optional

from . import identity, trusted
from .http_proxy import HttpProxyError, proxy_url


BOXA_PREFIX = "boxa-"
WRAPPER_COMMAND = "boxa-mcp-run"


def rendered_name(server_name: str) -> str:
    return f"{BOXA_PREFIX}{server_name}"


def _proxy_url(entry_id: str, consumer: str) -> str:
    try:
        return proxy_url(entry_id, consumer)
    except HttpProxyError as exc:
        raise LaunchProfileError(str(exc)) from exc


def claude_server_definition(
    entry_id: str,
    project: str,
    entry: dict[str, Any],
) -> dict[str, Any]:
    """Build one secret-free Claude launch-time MCP server definition."""
    if entry["type"] == "http":
        if entry.get("secretHeaderKeys"):
            return {"type": "http", "url": _proxy_url(entry_id, "claude")}
        definition = {"type": "http", "url": entry["url"]}
        if entry.get("headers"):
            definition["headers"] = dict(entry["headers"])
        return definition
    return {
        "type": "stdio",
        "command": WRAPPER_COMMAND,
        "args": [
            "--catalog-id",
            entry_id,
            "--consumer",
            "claude",
            "--project",
            project,
            entry["name"],
        ],
    }


class LaunchProfileError(RuntimeError):
    """The current Container cannot derive a launch-time MCP profile."""


def active_project_entries(
    consumer: str,
    *,
    runtime: Optional[dict[str, Any]] = None,
    project: Optional[str] = None,
) -> tuple[str, list[tuple[str, dict[str, Any]]]]:
    """Return enabled stdio/HTTP entries for one consumer in the current Project.

    Snapshot validation remains centralized in ``mcp.trusted``. Injected
    runtime/project values are test seams and let future agent renderers reuse
    the activation join without re-reading either source.
    """
    project = project if project is not None else identity.project_key()
    if not project:
        raise LaunchProfileError(
            "Container identity has no readable Project key"
        )
    runtime = runtime if runtime is not None else trusted.load_runtime_snapshot()
    records = runtime["projects"].get(project, {})
    selected: list[tuple[str, dict[str, Any]]] = []
    for entry_id, record in records.items():
        if (
            record.get("enabled", True) is False
            or consumer not in record["consumers"]
        ):
            continue
        entry = runtime["entries"].get(entry_id)
        if not isinstance(entry, dict) or entry.get("type") not in {"stdio", "http"}:
            continue
        selected.append((entry_id, entry))
    return project, selected


def claude_launch_profile(
    *,
    runtime: Optional[dict[str, Any]] = None,
    project: Optional[str] = None,
) -> dict[str, Any]:
    """Build Claude's complete strict ``--mcp-config`` JSON object."""
    project, entries = active_project_entries(
        "claude", runtime=runtime, project=project
    )
    servers: dict[str, dict[str, Any]] = {}
    for entry_id, entry in entries:
        try:
            definition = claude_server_definition(entry_id, project, entry)
        except LaunchProfileError as exc:
            if not entry.get("secretHeaderKeys"):
                raise
            _warn_skipped_proxy(entry, exc)
            continue
        servers[rendered_name(entry["name"])] = definition
    return {"mcpServers": servers}


def _warn_skipped_proxy(entry: dict[str, Any], exc: LaunchProfileError) -> None:
    sys.stderr.write(
        "boxa: warning: skipping proxied MCP entry "
        f"{entry.get('name', '<unknown>')!r}: {exc}\n"
    )


def _codex_key(name: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_-]+", name):
        return f"mcp_servers.{name}"
    return f"mcp_servers.{json.dumps(name)}"


def _toml_inline_string_map(values: dict[str, str]) -> str:
    """Render a Codex ``-c`` value as a TOML inline string table."""
    return "{ " + ", ".join(
        f"{json.dumps(str(key))} = {json.dumps(str(value))}"
        for key, value in values.items()
    ) + " }"


def _shared_codex_server_names(path: str) -> set[str]:
    fd: Optional[int] = None
    try:
        # O_NONBLOCK makes the open safe even if the path races from a regular
        # file to a FIFO; fstat then validates the object actually opened.
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            # This only keeps Boxa's profile derivation non-blocking. Codex
            # validates its own config again and may reject a non-regular path;
            # the wrapper cannot relocate or bypass Codex-owned configuration.
            return set()
        with os.fdopen(fd, "rb") as fh:
            fd = None
            config = tomllib.load(fh)
    except FileNotFoundError:
        return set()
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise LaunchProfileError(
            f"cannot read shared Codex config: {path}"
        ) from exc
    finally:
        if fd is not None:
            os.close(fd)
    servers = config.get("mcp_servers", {})
    if not isinstance(servers, dict):
        return set()
    return {name for name, value in servers.items() if isinstance(value, dict)}


def codex_launch_profile(
    *,
    runtime: Optional[dict[str, Any]] = None,
    project: Optional[str] = None,
    config_path: Optional[str] = None,
) -> list[str]:
    """Build Codex's complete sequence of root ``-c`` MCP overrides."""
    project, entries = active_project_entries(
        "codex", runtime=runtime, project=project
    )
    config_path = (
        config_path
        if config_path is not None
        else os.path.expanduser("~/.codex/config.toml")
    )
    rendered_overrides: list[str] = []
    activated_names: set[str] = set()
    for entry_id, entry in entries:
        name = rendered_name(entry["name"])
        key = _codex_key(name)
        if entry["type"] == "http":
            try:
                url = (
                    _proxy_url(entry_id, "codex")
                    if entry.get("secretHeaderKeys")
                    else entry["url"]
                )
            except LaunchProfileError as exc:
                if not entry.get("secretHeaderKeys"):
                    raise
                _warn_skipped_proxy(entry, exc)
                continue
            activated_names.add(name)
            rendered_overrides.extend([
                f"{key}.enabled=true",
                f"{key}.url={json.dumps(url)}",
            ])
            if entry.get("headers") and not entry.get("secretHeaderKeys"):
                rendered_overrides.append(
                    f"{key}.http_headers={_toml_inline_string_map(entry['headers'])}"
                )
            continue
        activated_names.add(name)
        args = [
            "--catalog-id",
            entry_id,
            "--consumer",
            "codex",
            "--project",
            project,
            entry["name"],
        ]
        rendered_overrides.extend(
            [
                f"{key}.enabled=true",
                f"{key}.command={json.dumps(WRAPPER_COMMAND)}",
                f"{key}.args={json.dumps(args, separators=(',', ':'))}",
            ]
        )
    overrides = [
        f"{_codex_key(name)}.enabled=false"
        for name in sorted(_shared_codex_server_names(config_path) - activated_names)
    ]
    return overrides + rendered_overrides
