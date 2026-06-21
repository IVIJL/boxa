"""Container identity gate for the boxa MCP runtime (ADR 0013, issue 07).

The ``boxa-mcp-run`` wrapper and the real render write path both live in the
host-bind-mounted Claude Code / Codex config trees, which are visible on the
host too. So before the wrapper launches ANY MCP server it must prove it is
running inside a boxa **Container**, never on the host.

The deterministic signal is the **Container identity** file at
``/etc/boxa/identity.json`` (ADR 0011): the entrypoint writes it inside every
Container, and its mere presence means "we are inside a boxa container". Its
absence means "we are on the host" — the wrapper then refuses to run.

This module is the single, testable place for that check. The identity path is
injectable so tests never depend on (or write) the real ``/etc/boxa`` file.
"""

from __future__ import annotations

import json
import os
from typing import Optional

# Canonical Container identity file (ADR 0011 Layer 1). Presence == "inside a
# boxa Container"; absence == "on the host". Overridable via env ONLY for
# tests (the production entrypoint always writes the canonical path).
DEFAULT_IDENTITY_PATH = "/etc/boxa/identity.json"

# Test/seam override. Never set in production; the entrypoint owns the real
# path. Lets unit tests point the gate at a fixture without touching /etc.
_IDENTITY_PATH_ENV = "BOXA_MCP_IDENTITY_PATH"


class NotInsideContainerError(RuntimeError):
    """Raised when the MCP runtime is invoked outside a boxa Container.

    The message is host-actionable: it explains that ``boxa-mcp-run`` is a
    container-only command and must not be launched directly on the host.
    """


def identity_path() -> str:
    """Resolve the Container identity file path (test-overridable)."""
    return os.environ.get(_IDENTITY_PATH_ENV) or DEFAULT_IDENTITY_PATH


def inside_container() -> bool:
    """True when the Container identity file is present (we are in a Container)."""
    return os.path.isfile(identity_path())


def project_name() -> Optional[str]:
    """The active Project name from the identity file, or None if unreadable.

    Best-effort, non-secret identity metadata only; any IO/parse error degrades
    to None rather than raising, since the presence check is the real gate.
    """
    path = identity_path()
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    name = data.get("project")
    return str(name) if isinstance(name, str) and name else None


def project_key() -> Optional[str]:
    """The active Project's FULL host-path key from the identity file, or None.

    ADR 0014 issue 15: the broker serves only THIS Container's Project. The
    Project profile/secret stores are keyed by the absolute host path (not the
    bare name), so the broker needs the full key — not just ``project`` (the
    sanitized name) — to bind a Project-scoped request to exactly this Container
    and reject another Project whose basename happens to collide. The entrypoint
    writes ``projectKey`` into the identity file when the host path is known.

    Best-effort, non-secret identity metadata only; any IO/parse error or a
    missing field degrades to None (the broker then falls back to the weaker
    sanitized-name guard rather than crashing).
    """
    path = identity_path()
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    key = data.get("projectKey")
    return str(key) if isinstance(key, str) and key else None


def require_container() -> None:
    """Gate: raise NotInsideContainerError unless we are inside a Container.

    Called by the wrapper BEFORE it resolves a profile or launches any MCP
    command, so a host-side invocation never starts an underlying process.
    """
    if not inside_container():
        raise NotInsideContainerError(
            "boxa-mcp-run must run inside a boxa Container, not on the host. "
            f"No Container identity file found at {identity_path()}. "
            "Rendered boxa-mcp-run entries are container-only; start the "
            "agent inside a boxa Container (the config trees are shared with "
            "the host, but the wrapper refuses to launch MCP servers there)."
        )
