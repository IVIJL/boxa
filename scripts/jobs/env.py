"""Job worker / Job command environment (ADR 0037 "Worker environment").

A Job never inherits the caller's environment.  It gets the fixed baseline the
agent-trusted MCP launcher builds (``HOME``, ``PATH``, the XDG dirs,
``DOCKER_HOST`` and ``SSH_AUTH_SOCK`` when their sockets exist) plus exactly
the variables the caller named with ``--env KEY``.  The *values* of those
named variables are read from the caller's environment and handed to the
child process; only their *names* are ever written to the Job record.
"""

from __future__ import annotations

import os
from typing import Callable, Iterable, Mapping, Optional

from mcp.trusted import agent_baseline_env, path_is_socket

__all__ = ["baseline_env", "child_env", "passthrough_values"]


def baseline_env(
    *, socket_probe: Callable[[str], bool] = path_is_socket
) -> dict[str, str]:
    """The fixed baseline, shared verbatim with the MCP agent-trusted launcher."""
    return agent_baseline_env(socket_probe=socket_probe)


def passthrough_values(
    env_names: Iterable[str], source: Optional[Mapping[str, str]] = None
) -> dict[str, str]:
    """Values for the caller-named variables, skipping the ones not set.

    Used by ``start`` to hand the values to the worker through its own
    environment; they are deliberately never serialized.
    """
    source = os.environ if source is None else source
    return {name: source[name] for name in env_names if name in source}


def child_env(
    env_names: Iterable[str],
    job_id: str,
    *,
    source: Optional[Mapping[str, str]] = None,
    socket_probe: Callable[[str], bool] = path_is_socket,
) -> dict[str, str]:
    """Full environment for a Job's command: baseline + named + ``BOXA_JOB_ID``.

    ``BOXA_JOB_ID`` is the marker ADR 0037 relies on to find a Job's
    descendants through ``/proc/*/environ`` even after its worker died, so it
    is set unconditionally and cannot be overridden by a named passthrough.
    """
    env = baseline_env(socket_probe=socket_probe)
    env.update(passthrough_values(env_names, source))
    env["BOXA_JOB_ID"] = job_id
    return env
