"""The MCP relay — the reworked ``boxa-mcp-run`` (ADR 0014, issue 15).

Rendered agent config still calls ``boxa-mcp-run <server>`` (or
``boxa-mcp-run --project <key> <server>``) — the stable control point ADR
0013 established and ADR 0014 preserves. But the command no longer execs the MCP
server itself. Instead it is a thin **stdio<->socket relay** running as the
agent user ``node``:

  1. connect to the broker's unix socket (a node-connectable location, separate
     from any 0700 secret directory — connecting exposes only a pipe);
  2. send the handshake naming the requested server (and Project key), receive
     the broker's accept/refuse reply;
  3. on a service-isolated accept, proxy stdio to the broker-spawned process;
     on an agent-trusted accept, close the socket and launch the returned
     secret-free plan locally as ``node`` from its deterministic environment.

Because the server runs under a different UID behind the broker, the agent never
becomes the server process and never sees its environment (secrets, issue 16).
The relay carries only the MCP stdio stream.

The Container identity gate still applies: ``boxa-mcp-run`` is container-only,
so the relay refuses on the host before touching the socket.
"""

from __future__ import annotations

import os
import selectors
import socket
import subprocess
import sys
from typing import Optional

from .broker import socket_path
from .identity import project_key as container_project_key, require_container
from .docker_adapter import DockerAdapterError, validate_plan_shape
from .protocol import (
    EXIT_TRAILER_SENTINEL,
    MAX_EXIT_TRAILER_BYTES,
    ProtocolError,
    decode_exit,
    decode_reply_details,
    encode_request,
    read_line,
)
from .trusted import (
    TrustedAuthorizationError,
    authorize_entry,
    build_launch_plan,
    load_runtime_snapshot,
)

_PROXY_CHUNK = 64 * 1024


class RelayError(RuntimeError):
    """A relay failure with a user-actionable, SECRET-FREE message."""


def _load_authorized_snapshot_entry(
    server_name: str,
    project_key: Optional[str],
    catalog_id: Optional[str],
    consumer: Optional[str],
) -> dict:
    """Independently bind every catalog request to host-owned state."""
    own_key = container_project_key()
    if (
        not project_key
        or not own_key
        or project_key.rstrip("/") != own_key.rstrip("/")
        or not catalog_id
        or not consumer
    ):
        raise RelayError(
            "agent-trusted launch lacks an exact Container Project, catalog ID, "
            "or consumer binding"
        )
    try:
        runtime = load_runtime_snapshot()
        return authorize_entry(
            runtime, server_name, own_key, catalog_id, consumer
        )
    except TrustedAuthorizationError as exc:
        raise RelayError(
            f"host-owned MCP runtime snapshot refused catalog launch: {exc}"
        ) from exc


def _validate_agent_trusted_plan(
    plan: dict,
    server_name: str,
    project_key: Optional[str],
    catalog_id: Optional[str],
    consumer: Optional[str],
    requested_cwd: Optional[str],
) -> dict:
    """Independently authorize an untrusted broker reply, fail closed."""
    entry = _load_authorized_snapshot_entry(
        server_name, project_key, catalog_id, consumer
    )
    try:
        expected = build_launch_plan(
            entry, catalog_id or "", consumer or "", requested_cwd
        )
    except TrustedAuthorizationError as exc:
        raise RelayError(
            f"host-owned MCP runtime snapshot refused agent-trusted launch: {exc}"
        ) from exc
    if plan != expected:
        raise RelayError(
            "broker returned an agent-trusted launch plan that does not exactly "
            "match the host-owned MCP runtime snapshot"
        )
    return expected


def _launch_agent_trusted(plan: dict) -> int:
    """Launch an authorized plan locally as the existing node relay user."""
    import pwd

    try:
        username = pwd.getpwuid(os.geteuid()).pw_name
    except KeyError:
        username = ""
    if username != "node":
        raise RelayError(
            "agent-trusted MCP launch requires the Container account node"
        )
    try:
        child = subprocess.Popen(  # noqa: S603 - broker-authorized argv, no shell
            plan["argv"],
            stdin=sys.stdin,
            stdout=sys.stdout,
            stderr=sys.stderr,
            env=dict(plan["env"]),
            cwd=plan.get("cwd"),
            close_fds=True,
        )
    except OSError as exc:
        raise RelayError(f"failed to launch agent-trusted MCP: {exc}") from exc
    return child.wait()


def _validate_docker_plan(
    plan: dict, server_name: str, project_key: Optional[str],
    catalog_id: Optional[str], consumer: Optional[str], requested_cwd: Optional[str],
) -> dict:
    entry = _load_authorized_snapshot_entry(
        server_name, project_key, catalog_id, consumer
    )
    try:
        return validate_plan_shape(
            plan, entry, catalog_id or "", consumer or "", project_key or "",
            requested_cwd,
        )
    except DockerAdapterError as exc:
        raise RelayError(f"host-owned MCP runtime snapshot refused Docker launch: {exc}") from exc


def _launch_docker_adapter(plan: dict) -> int:
    """Run only the validated docker CLI as node; nested server gets no socket."""
    try:
        child = subprocess.Popen(  # noqa: S603 - independently validated argv
            plan["argv"], stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr,
            env={
                "HOME": "/home/node", "USER": "node", "LOGNAME": "node",
                "PATH": "/usr/local/bin:/usr/bin:/bin",
                "XDG_RUNTIME_DIR": "/run/user/1000",
                "DOCKER_HOST": "unix:///run/user/1000/docker.sock",
            },
            cwd=plan["cwd"], close_fds=True,
        )
    except OSError as exc:
        raise RelayError(f"failed to launch service-isolated Docker MCP: {exc}") from exc
    return child.wait()


def _connect(path: str) -> socket.socket:
    """Connect to the broker socket, or fail with an actionable message."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
    except OSError as exc:
        sock.close()
        raise RelayError(
            f"cannot reach the boxa MCP broker at {path}: {exc}. "
            "The broker starts with the Container; if this persists, restart "
            "the Container."
        ) from exc
    return sock


def _proxy(sock: socket.socket, stdin_fd: int, stdout_fd: int) -> int:
    """Bidirectionally proxy stdin/stdout <-> the broker socket until EOF.

    A single-threaded selector loop avoids spawning threads in the per-server
    relay process (one runs per MCP server the agent uses). When the agent's
    stdin closes we half-close the socket's write side so the server sees EOF;
    when the socket closes (server exited) we stop.

    Returns the spawned server's exit code, which the broker sends as a final
    NUL-prefixed trailer after the server's stdout reaches EOF (see protocol.py).
    A raw NUL never appears inside an MCP JSON-RPC frame, so the first NUL byte
    from the socket marks the boundary: bytes before it are real MCP stdout
    (written straight through), the NUL and everything after it are the trailer
    (buffered, then decoded once the socket closes). If the trailer is absent or
    unparseable (e.g. a broker that predates this protocol, or a broken pipe), we
    fall back to 0 so the change never breaks an otherwise-clean session.
    """
    sel = selectors.DefaultSelector()
    sock.setblocking(False)
    os.set_blocking(stdin_fd, False)
    sel.register(sock, selectors.EVENT_READ, "sock")
    sel.register(stdin_fd, selectors.EVENT_READ, "stdin")

    stdin_open = True
    trailer = bytearray()  # bytes from the first NUL onward (sentinel included)
    in_trailer = False
    try:
        while True:
            for key, _mask in sel.select():
                if key.data == "sock":
                    try:
                        data = sock.recv(_PROXY_CHUNK)
                    except (BlockingIOError, InterruptedError):
                        continue
                    if not data:
                        return _exit_from_trailer(trailer)  # broker closed: done
                    if in_trailer:
                        trailer.extend(data)
                        # Bound post-stream buffering against a NUL-then-flood.
                        del trailer[MAX_EXIT_TRAILER_BYTES + 1 :]
                        continue
                    nul = data.find(EXIT_TRAILER_SENTINEL)
                    if nul == -1:
                        _write_all_fd(stdout_fd, data)
                    else:
                        # Everything before the NUL is genuine MCP stdout; the
                        # NUL and the rest begin the exit trailer.
                        if nul:
                            _write_all_fd(stdout_fd, data[:nul])
                        in_trailer = True
                        trailer.extend(data[nul:])
                        del trailer[MAX_EXIT_TRAILER_BYTES + 1 :]
                elif key.data == "stdin":
                    try:
                        data = os.read(stdin_fd, _PROXY_CHUNK)
                    except (BlockingIOError, InterruptedError):
                        continue
                    if not data:
                        # Agent closed stdin: signal EOF to the server, then
                        # stop watching stdin but keep draining the socket.
                        stdin_open = False
                        sel.unregister(stdin_fd)
                        try:
                            sock.shutdown(socket.SHUT_WR)
                        except OSError:
                            pass
                        continue
                    _send_all(sock, data)
    except OSError:
        # A broken pipe in either direction ends the session. We could not read a
        # complete trailer, so fall back to whatever we buffered (0 if none).
        return _exit_from_trailer(trailer)
    finally:
        sel.close()
        if stdin_open:
            try:
                sock.shutdown(socket.SHUT_WR)
            except OSError:
                pass


def _exit_from_trailer(trailer: bytearray) -> int:
    """Decode the buffered exit trailer into an exit code (0 if none/garbled).

    ``trailer`` includes the leading NUL sentinel when present. An absent trailer
    (older broker, or a connection dropped before the server reported) is treated
    as a clean exit so the relay never invents a failure; a present-but-garbled
    trailer also degrades to 0 rather than a misleading non-zero code.
    """
    if not trailer.startswith(EXIT_TRAILER_SENTINEL):
        return 0
    try:
        return decode_exit(bytes(trailer[len(EXIT_TRAILER_SENTINEL) :]))
    except ProtocolError:
        return 0


def _write_all_fd(fd: int, data: bytes) -> None:
    """Write all of ``data`` to a (possibly non-blocking) fd."""
    view = memoryview(data)
    while view:
        try:
            written = os.write(fd, view)
            view = view[written:]
        except (BlockingIOError, InterruptedError):
            continue


def _send_all(sock: socket.socket, data: bytes) -> None:
    """Send all of ``data`` over a non-blocking socket."""
    view = memoryview(data)
    while view:
        try:
            sent = sock.send(view)
            view = view[sent:]
        except (BlockingIOError, InterruptedError):
            continue


def run(
    server_name: str, project_key: Optional[str] = None, *,
    catalog_id: Optional[str] = None, consumer: Optional[str] = None,
) -> int:
    """Relay one MCP server's stdio through the broker. Returns an exit code.

    The same signature as the ADR 0013 runner so ``mcp.cli run`` is unchanged.
    On any actionable failure raises :class:`RelayError` with a SECRET-FREE
    message; otherwise returns the spawned server's own exit code (0 on a clean
    session, non-zero when the broker-spawned server exited non-zero). The ADR
    0013 exec wrapper propagated the server's exit code as its own; the broker/
    relay split preserves that by forwarding the status the broker sends after
    the server's stdout reaches EOF.
    """
    # Container identity gate — refuse on the host before opening any socket.
    require_container()

    path = socket_path()
    # Capture the relay's working directory so the broker spawns the server with
    # the agent SESSION's cwd, not the broker's long-lived startup dir. The old
    # execvpe runner inherited the launching agent's cwd directly; the broker
    # (issue 15) does not, so project-local MCP servers that resolve relative
    # paths would otherwise break. cwd is not a secret — just a directory.
    try:
        cwd = os.getcwd()
    except OSError:
        cwd = None
    sock = _connect(path)
    try:
        sock.sendall(encode_request(
            server_name, project_key, cwd, catalog_id=catalog_id, consumer=consumer
        ))
        try:
            reply = read_line(sock.recv)
            ok, error, launch = decode_reply_details(reply)
        except ProtocolError as exc:
            raise RelayError(
                f"malformed reply from the boxa MCP broker: {exc}"
            ) from exc
        if not ok:
            raise RelayError(
                f"the boxa MCP broker refused server {server_name!r}: "
                f"{error or 'no reason given'}"
            )
        if catalog_id is not None:
            entry = _load_authorized_snapshot_entry(
                server_name, project_key, catalog_id, consumer
            )
            if entry.get("executionMode") == "agent-trusted" and launch is None:
                raise RelayError(
                    "broker omitted the required agent-trusted launch plan; "
                    "refusing to proxy through an untrusted socket peer"
                )
        if launch is not None:
            # The socket peer is not trusted: a same-UID service child may have
            # replaced it. Independently reconstruct the only authorized plan
            # from the host-owned read-only snapshot before launching as node.
            if launch.get("executionMode") == "service-isolated":
                validated = _validate_docker_plan(
                    launch, server_name, project_key, catalog_id, consumer, cwd
                )
                sock.close()
                return _launch_docker_adapter(validated)
            validated = _validate_agent_trusted_plan(
                launch, server_name, project_key, catalog_id, consumer, cwd
            )
            sock.close()
            return _launch_agent_trusted(validated)
        return _proxy(sock, sys.stdin.fileno(), sys.stdout.fileno())
    finally:
        try:
            sock.close()
        except OSError:
            pass
