"""The ``boxa-mcp-run`` wrapper core (ADR 0013, issue 07; reworked ADR 0014).

Rendered agent config never calls a raw MCP command — it calls this wrapper
(``boxa-mcp-run <server>`` for a global server, or
``boxa-mcp-run --project <full-project-key> <server>`` for a Project-scoped
one). The wrapper is the stable control point ADR 0013 decision 27 asks for:
agent config keeps calling ``boxa-mcp-run`` even though ADR 0014 changed what
it does under the hood.

ADR 0013 had this wrapper EXEC the MCP server directly (as the agent user
``node``). ADR 0014 moves the server behind a UID boundary: the wrapper is now a
stdio<->socket **relay** that hands the request to the always-on broker, which
spawns the server as the unprivileged ``boxa-mcp`` account. The agent never
becomes the server process and never sees its environment. The relay logic
lives in ``mcp.relay``; ``run`` here delegates to it so ``mcp.cli run`` keeps a
single, stable entry point.

The helper functions below (profile/spec resolution, env overlay) are retained
and SHARED with the broker (``mcp.broker`` imports ``_server_argv`` /
``_resolve_env``): the broker is the side that now resolves the spec and spawns
the server, so the scope/env logic lives in one tested place.

Error states are clear and actionable (missing server, disabled server,
missing env, malformed profile, missing identity). Secret VALUES never appear
in any message — only env NAMES.
"""

from __future__ import annotations

import os
from typing import Optional

from .profile import global_profile_path, load_profile, project_profile_path
from .secrets import (
    global_secrets_path,
    project_secrets_path,
    read_server_secrets,
)


class RunnerError(RuntimeError):
    """A wrapper failure with a user-actionable, SECRET-FREE message."""


def _resolve_paths(project_key: Optional[str]) -> tuple[str, str, str]:
    """Return (profile_path, secrets_path, scope_label) for the scope.

    A non-empty ``project_key`` selects the Project profile + Project secret
    store keyed by that FULL project key (the same sanitized+hashed basename the
    render path used); an empty/None key selects the global profile + secrets.
    """
    if project_key:
        return (
            project_profile_path(project_key),
            project_secrets_path(project_key),
            f"project ({project_key})",
        )
    return (global_profile_path(), global_secrets_path(), "global")


def _load_server_spec(
    profile_path: str, server_name: str, scope_label: str
) -> dict:
    """Load and validate one server's spec from the canonical profile.

    Raises ``RunnerError`` (never a bare traceback) for the actionable failure
    modes: a malformed profile, an unknown server, or a disabled server.
    """
    try:
        profile = load_profile(profile_path)
    except (OSError, ValueError) as exc:
        raise RunnerError(
            f"cannot read MCP profile for {scope_label}: {exc}"
        ) from exc

    servers = profile.get("servers")
    if not isinstance(servers, dict):
        raise RunnerError(
            f"malformed MCP profile ('servers' missing or not an object) at "
            f"{profile_path}"
        )

    spec = servers.get(server_name)
    if not isinstance(spec, dict):
        known = sorted(n for n in servers if isinstance(servers[n], dict))
        hint = f" Known servers: {', '.join(known)}." if known else ""
        raise RunnerError(
            f"no MCP server named {server_name!r} in the {scope_label} profile "
            f"({profile_path}).{hint}"
        )

    if spec.get("enabled") is False:
        raise RunnerError(
            f"MCP server {server_name!r} is disabled in the {scope_label} "
            "profile; enable it with 'boxa mcp enable' before launching."
        )
    return spec


def _server_argv(spec: dict, server_name: str) -> list[str]:
    """Extract the launch argv from a server spec, or fail clearly."""
    command = spec.get("command")
    argv = command.get("argv") if isinstance(command, dict) else None
    if not isinstance(argv, list) or not argv:
        raise RunnerError(
            f"MCP server {server_name!r} has no launch command "
            "(command.argv) in the profile."
        )
    return [str(a) for a in argv]


def _resolve_env(
    spec: dict, secrets_path: str, server_name: str
) -> dict[str, str]:
    """Build the env overlay for the server, validating every required name.

    Resolution per declared env NAME (the profile carries names + non-secret
    values only):
      * a SECRET key resolves from the scoped 0600 secret store, then falls back
        to the inherited environment;
      * a NON-secret key resolves from the profile's recorded ``env`` map (the
        inline value carried over at import time), then the inherited
        environment, then a value copied into the store.

    Every declared name MUST resolve to a value or the launch is refused with
    a SECRET-FREE message listing the missing NAMES. Secret VALUES are read
    into memory only and never logged or returned in any error.
    """
    env_keys = spec.get("envKeys")
    secret_env_keys = spec.get("secretEnvKeys")
    env_keys = [str(k) for k in env_keys] if isinstance(env_keys, list) else []
    secret_keys = (
        {str(k) for k in secret_env_keys}
        if isinstance(secret_env_keys, list)
        else set()
    )
    # secretEnvKeys is documented as a SUBSET of envKeys; tolerate a secret key
    # that was not also listed in envKeys so a required credential is never
    # silently skipped.
    all_keys = list(dict.fromkeys([*env_keys, *sorted(secret_keys)]))

    stored = read_server_secrets(secrets_path, server_name) or {}
    # Non-secret values carried in the profile (never secrets — apply filters
    # them, and a secret key takes the store path below regardless).
    profile_env = spec.get("env")
    profile_env = profile_env if isinstance(profile_env, dict) else {}

    overlay: dict[str, str] = {}
    missing: list[str] = []
    for key in all_keys:
        if key in secret_keys and key in stored:
            overlay[key] = stored[key]
        elif key not in secret_keys and key in profile_env:
            overlay[key] = str(profile_env[key])
        elif key in os.environ:
            overlay[key] = os.environ[key]
        elif key in stored:
            # A non-secret key copied into the store is still a usable value.
            overlay[key] = stored[key]
        else:
            missing.append(key)

    if missing:
        # NAMES only — never values.
        raise RunnerError(
            f"MCP server {server_name!r} is missing required env value(s): "
            f"{', '.join(missing)}. Set them in the environment, or re-import "
            "the server so boxa copies the credential into its secret store. "
            "(Values are never printed.)"
        )
    return overlay


def run(server_name: str, project_key: Optional[str] = None) -> int:
    """Relay one MCP server's stdio through the broker (ADR 0014).

    This no longer execs the server in-process. Under ADR 0014 the server runs
    under the ``boxa-mcp`` UID behind the always-on broker, so the agent never
    becomes the server process and never sees its environment. ``run`` delegates
    to the relay (``mcp.relay``), which connects to the broker socket, names the
    requested server, and proxies stdio. The profile/spec resolution and env
    overlay live in this module's helpers and are now performed broker-side.

    Returns an exit code (0 on a clean session). Raises ``RunnerError`` with a
    SECRET-FREE message on any actionable failure (host guard, broker
    unreachable, server refused).
    """
    from .relay import RelayError
    from .relay import run as relay_run

    try:
        return relay_run(server_name, project_key=project_key)
    except RelayError as exc:
        raise RunnerError(str(exc)) from exc
