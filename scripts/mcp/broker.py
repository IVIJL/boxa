"""The always-on Container MCP broker (ADR 0014, issue 15).

The broker is the credential-isolation core of ADR 0014. It runs as the
dedicated unprivileged ``boxa-mcp`` account — distinct from the agent user
``node`` — so the MCP server processes it spawns live behind a UID boundary the
agent cannot cross:

  * the agent (``node``) cannot read ``/proc/<pid>/environ`` of a process owned
    by ``boxa-mcp`` (that file is ``0400`` owned by the process UID), so a
    server's injected secrets (issue 16) stay invisible to the agent;
  * the agent cannot signal or ptrace a ``boxa-mcp``-owned process.

Lifecycle (started from the entrypoint ROOT phase, BEFORE the ``setpriv`` drop
to ``node``):

    setpriv --reuid boxa-mcp --regid boxa-mcp --init-groups -- \\
        boxa-mcp-broker

``--regid`` + ``--init-groups`` are REQUIRED (not just ``--reuid``): they reset
the GID and supplementary groups to ``boxa-mcp``'s own, so the broker keeps no
root-group membership that could re-expose group-readable root-owned files.

For each relay connection the broker:

  1. reads the handshake (a server name + optional Project key — names only, see
     ``mcp.protocol``);
  2. resolves the IN-SCOPE effective profile (global + THIS Container's Project,
     keyed from the Container identity file) and refuses any server not in it;
  3. spawns a FRESH server process per connection as ``boxa-mcp``, bridging
     its stdio to the socket so the agent talks MCP straight through.

The broker ALWAYS runs, even with an empty or missing profile, so a server
imported into a running Container is serviceable on the next session without a
restart (the profile is a live read-only bind-mount). It is stateless between
connections: it re-reads the profile (and, in issue 16, the staged secrets) on
every spawn.

This issue handles SECRET-FREE servers; the spawn path is built so per-server
secret injection (issue 16) drops in at one clearly marked point without
changing the protocol or the UID boundary.
"""

from __future__ import annotations

import argparse
import os
import selectors
import signal
import socket
import sys
import threading
from typing import Optional

from .identity import inside_container, project_key, project_name
from .profile import global_profile_path, load_profile, project_profile_path
from .protocol import (
    ProtocolError,
    decode_request,
    encode_exit,
    encode_reply,
    read_line,
)
from .projects import sanitize_basename
from .runner import RunnerError, _resolve_env, _server_argv
from .secrets import global_secrets_path, project_secrets_path

# Default broker socket. It lives on the NEUTRAL `boxa-bridge` runtime path
# (ADR 0014, issue 19), NOT inside the 0700 boxa-mcp secret dir: connecting
# exposes only a stdio pipe, never a credential. The parent dir is owned
# boxa-mcp:boxa-bridge 0770 and the socket itself is 0660 group-owned
# boxa-bridge, so the broker (boxa-mcp) owns/serves it and the relay (node)
# reaches it via membership in `boxa-bridge` — WITHOUT node being in
# boxa-mcp's primary group (the cross-membership was removed; see the
# Dockerfile bridge group and the entrypoint root phase that creates this dir).
# This is the SINGLE SOURCE OF TRUTH for the socket path: relay.py imports
# socket_path() from here, the entrypoint creates this exact dir, and the
# Dockerfile/launcher never hard-code the path. Overridable via env ONLY for tests.
DEFAULT_SOCKET_PATH = "/run/boxa-bridge/broker.sock"
_SOCKET_PATH_ENV = "BOXA_MCP_BROKER_SOCKET"

# Socket mode: owner + group read/write, no world access. `node` connects via
# its membership in the `boxa-bridge` group; no other account can reach it.
_SOCKET_MODE = 0o660

# Root of the boxa-mcp-PRIVATE staged secret store the broker reads secret
# VALUES from (ADR 0014). The profile (references only) is read from the live
# node-readable mount, but secret values must come from a path the AGENT cannot
# read and the broker CAN: a boxa-mcp-owned dir under /run. In THIS issue
# nothing is staged there yet (issue 16 does the root-side staging), so the dir
# is empty/absent and a secret-declaring server cleanly reports missing env
# rather than launching without its credential. The broker NEVER reads the
# node-owned 0600 secret files in the profile mount — those are not readable by
# boxa-mcp and carry the agent's UID, so reading them would both fail and
# defeat the isolation. Overridable via env ONLY for tests.
DEFAULT_SECRETS_DIR = "/run/boxa-mcp/secrets"
_SECRETS_DIR_ENV = "BOXA_MCP_SECRETS_DIR"

# Bounded proxy chunk size. Plain stdio relaying; 64 KiB balances syscall count
# against memory per in-flight chunk.
_PROXY_CHUNK = 64 * 1024

# Handshake deadline. Each accepted connection runs on its own thread that blocks
# in read_line() until the relay names a server. Without a deadline a client that
# connects and sends nothing (slowloris) pins that thread + fd forever, and
# repeating it exhausts the broker — an availability attack on the credential
# control plane (reachable by node via the boxa-bridge group). 10s is ample for a
# local relay to send one short handshake line; the deadline is CLEARED once the
# handshake completes, since the subsequent stdio proxy is legitimately idle for
# long stretches between MCP messages.
_HANDSHAKE_TIMEOUT_SECONDS = 10.0


class BrokerError(RuntimeError):
    """A broker startup/wiring failure with a SECRET-FREE message."""


def socket_path() -> str:
    """Resolve the broker socket path (test-overridable)."""
    return os.environ.get(_SOCKET_PATH_ENV) or DEFAULT_SOCKET_PATH


def _secrets_dir() -> str:
    """Root of the boxa-mcp-private staged secret store (test-overridable)."""
    return os.environ.get(_SECRETS_DIR_ENV) or DEFAULT_SECRETS_DIR


def _staged_secrets_path(scope_filename: str) -> str:
    """Path of a scope's staged secret file under the boxa-mcp-private dir.

    ``scope_filename`` is the basename ``mcp.secrets`` uses for the scope
    ("secrets.json" for global, "<sanitized-key>.secrets.json" for a Project) so
    the staged layout mirrors the canonical store; issue 16's root-side staging
    writes exactly these names. In this issue the dir is empty, so the file is
    absent and ``read_server_secrets`` returns no secrets (a secret-declaring
    server then cleanly reports missing env).
    """
    return os.path.join(_secrets_dir(), scope_filename)


def _resolve_request_paths(
    server: str, requested_key: Optional[str]
) -> tuple[str, str, str]:
    """Resolve (profile_path, secrets_path, scope_label) for an IN-SCOPE request.

    Enforces SCOPE (ADR 0014 "global + this Container's Project"):

      * No project key -> the GLOBAL profile + GLOBAL staged secret store.
      * A project key -> the Project profile + Project staged secret store, but
        ONLY if it is THIS Container's Project. A Container for Project A must
        never serve Project B's servers, even if a compromised/buggy relay names
        B's key.

    The relay supplies the requested key, but the broker NEVER trusts it for
    authorization. It binds Project scope to the Container's OWN identity:

      * Preferred: the identity file's ``projectKey`` (the FULL host path the
        Container was started for). The relay's key must match it EXACTLY. This
        defeats a basename collision (``/work/a/api`` vs ``/work/b/api``):
        different full paths never match, and they also hash to different
        profile/secret files, so neither the authorization nor the paths can
        cross over.
      * Fallback (older Containers with no ``projectKey`` recorded): compare the
        ADR 0005 sanitized basename against the identity's Project NAME. This is
        weaker (a basename collision could pass) but never worse than the prior
        behavior, and is only reached when the full key is unavailable.

    The PROFILE path resolves under ``mcp.profile.config_root()`` — the broker is
    launched with ``XDG_CONFIG_HOME`` pointed at the live node-readable profile
    mount (references only; world-readable). The SECRET path resolves under the
    boxa-mcp-PRIVATE staged dir (``_secrets_dir()``), NOT the node-owned mount:
    reading node's 0600 secret files would both fail (wrong UID) and defeat the
    isolation. On a match the paths are derived from the CONTAINER's own key when
    we have it (so they can never be steered by the relay), else from the
    (validated) requested key. Raises :class:`BrokerError` (refusal) otherwise.
    """
    if not requested_key:
        return (
            global_profile_path(),
            _staged_secrets_path(os.path.basename(global_secrets_path())),
            "global",
        )

    own_key = project_key()
    if own_key:
        # Authoritative: the Container's own full host-path key. The relay must
        # name exactly this; the paths are derived from OUR key, never the
        # relay's, so a mismatched/hostile key cannot select another store.
        if requested_key.rstrip("/") != own_key.rstrip("/"):
            raise BrokerError(
                f"refusing Project-scoped server {server!r}: the requested "
                "Project is not this Container's Project."
            )
        return (
            project_profile_path(own_key),
            _staged_secrets_path(os.path.basename(project_secrets_path(own_key))),
            "project (this container)",
        )

    # Fallback: no full key recorded (older Container). Bind by sanitized name.
    requested_name = sanitize_basename(os.path.basename(requested_key.rstrip("/")))
    container_name = sanitize_basename(project_name() or "")
    if not container_name or requested_name != container_name:
        raise BrokerError(
            f"refusing Project-scoped server {server!r}: requested Project "
            f"{requested_name!r} is not this Container's Project "
            f"({container_name or 'unknown'!r})."
        )
    return (
        project_profile_path(requested_key),
        _staged_secrets_path(
            os.path.basename(project_secrets_path(requested_key))
        ),
        f"project ({requested_name})",
    )


def _load_in_scope_spec(
    server: str, requested_key: Optional[str]
) -> tuple[dict, str]:
    """Validate a request against the in-scope profile.

    Returns ``(spec, secrets_path)``: the server's profile spec and the scoped
    secret-store path to resolve its env from. Refuses (``BrokerError``) any
    server name not present-and-enabled in the resolved in-scope profile. This is
    the broker's authorization gate: the agent can only ever start a server
    boxa has imported into the scope this Container serves.
    """
    profile_path, secrets_path, scope_label = _resolve_request_paths(
        server, requested_key
    )
    try:
        profile = load_profile(profile_path)
    except (OSError, ValueError) as exc:
        raise BrokerError(
            f"cannot read MCP profile for {scope_label}: {exc}"
        ) from exc

    servers = profile.get("servers")
    if not isinstance(servers, dict):
        raise BrokerError(
            f"no MCP servers available in the {scope_label} profile."
        )
    spec = servers.get(server)
    if not isinstance(spec, dict):
        raise BrokerError(
            f"server {server!r} is not in the {scope_label} profile (refused)."
        )
    if spec.get("enabled") is False:
        raise BrokerError(
            f"server {server!r} is disabled in the {scope_label} profile."
        )
    return spec, secrets_path


def _resolve_spawn_cwd(requested_cwd: Optional[str]) -> Optional[str]:
    """Validate the relay-supplied cwd, falling back to a safe default.

    The relay sends the agent session's working directory so a project-local
    server resolves relative paths against the session, not the broker's startup
    dir. The cwd is not a secret, but it IS untrusted input from the relay, so we
    only honor it when it names a directory the broker can actually enter
    (``os.chdir`` would otherwise make the spawn fail). If the relay omits it or
    it is not a usable directory, return ``None`` so ``Popen`` keeps the broker's
    own cwd rather than failing the spawn — a safe, available default.
    """
    if not requested_cwd:
        return None
    if not os.path.isdir(requested_cwd):
        return None
    if not os.access(requested_cwd, os.R_OK | os.X_OK):
        return None
    return requested_cwd


def _build_spawn(
    server: str, requested_key: Optional[str], requested_cwd: Optional[str] = None
) -> tuple[list[str], dict, Optional[str]]:
    """Build the (argv, env, cwd) for a fresh, in-scope server spawn as boxa-mcp.

    The argv comes from the profile; the env is the broker's own environment
    plus the server's resolved env overlay. The overlay reads non-secret values
    from the profile/environment and SECRET values from the scoped secret store
    that ``_resolve_request_paths`` selected — the same store the host wrote, so
    a credential-backed server resolves correctly (the broker reads it under the
    boxa-mcp UID, never the agent). In this issue the secret store reaches the
    Container as an empty-shadowed file (real per-server secret delivery to the
    boxa-mcp UID is issue 16), so a secret-declaring server cleanly reports
    missing env rather than launching without its credential.

    Secret VALUES are never logged here (``_resolve_env`` only ever raises with
    NAMES).
    """
    spec, secrets_path = _load_in_scope_spec(server, requested_key)
    # _server_argv / _resolve_env raise RunnerError (malformed command, missing
    # required env). Convert to BrokerError so _handle reports an actionable,
    # SECRET-FREE refusal to the relay instead of dropping the connection. The
    # RunnerError message is names-only by construction (never a secret value).
    try:
        argv = _server_argv(spec, server)
        overlay = _resolve_env(spec, secrets_path, server)
    except RunnerError as exc:
        raise BrokerError(str(exc)) from exc

    child_env = dict(os.environ)
    # Strip the broker's OWN control-plane variables from the child environment.
    # A spawned MCP server has no business knowing where the broker reads secret
    # VALUES from (BOXA_MCP_SECRETS_DIR) or where the broker socket lives: the
    # broker resolves the server's env itself and hands it over via this overlay.
    # This is defense-in-depth — the broker and its spawned servers share the
    # boxa-mcp UID, so a compromised in-scope server could otherwise follow the
    # inherited BOXA_MCP_SECRETS_DIR straight to the staged store and read
    # ANOTHER scope's secret file (issue 16 populates that store). Removing the
    # pointer does not by itself defeat a child that hard-codes the default path
    # (broker and server are the same UID); per-server secret isolation is part
    # of issue 16's staging design. But the broker must never volunteer the path.
    for _control_var in (_SECRETS_DIR_ENV, _SOCKET_PATH_ENV):
        child_env.pop(_control_var, None)
    # The broker's own XDG_CONFIG_HOME points at the (node-owned) profile mount
    # so mcp.profile can READ the in-scope profile. A spawned server must NOT
    # inherit that pointer: running as boxa-mcp it cannot write the node-owned
    # mount, so a server that creates config under XDG_CONFIG_HOME at startup
    # would fail (and pointing it into node's config tree is the wrong isolation
    # boundary anyway). Redirect the child to boxa-mcp's OWN writable config
    # home before applying the overlay, so an explicit per-server override in the
    # profile still wins.
    home = child_env.get("HOME") or os.path.expanduser("~")
    child_env["XDG_CONFIG_HOME"] = os.path.join(home, ".config")
    # Point a docker/podman-launcher server at the Container's rootless Docker
    # daemon (ADR 0014 "Update 2026-05-31"). DOCKER_HOST + XDG_RUNTIME_DIR are
    # the image ENV the broker inherits; they are NOT secrets and are the ONLY
    # variables added back here (issue 15 strips the broker's control-plane vars
    # above — that hardening stays intact). XDG_RUNTIME_DIR is the docker socket's
    # RUNTIME dir, distinct from XDG_CONFIG_HOME (config) set just above. We only
    # propagate a value the broker actually has, so an image without rootless
    # Docker simply leaves the child without these (a non-Docker server is
    # unaffected). The socket itself is reachable because start-rootless-docker.sh
    # re-groups it to boxa-bridge, of which boxa-mcp is a member.
    for _docker_var in ("DOCKER_HOST", "XDG_RUNTIME_DIR"):
        _docker_val = os.environ.get(_docker_var)
        if _docker_val:
            child_env[_docker_var] = _docker_val
    child_env.update(overlay)
    # Spawn the server in the agent session's cwd (relay-supplied) so project-
    # local servers resolve relative paths against the session, not the broker's
    # startup dir. _resolve_spawn_cwd validates it and falls back to None (keep
    # the broker's own cwd) when it is missing or unusable.
    spawn_cwd = _resolve_spawn_cwd(requested_cwd)
    return argv, child_env, spawn_cwd


def _pump(src_fd: int, dst_fd: int, on_eof=None) -> None:
    """Copy bytes from one fd to another until EOF, then run ``on_eof``.

    Used for one direction of the stdio proxy. On source EOF (or any OSError —
    e.g. EPIPE/EBADF once the peer is gone) the loop ends and ``on_eof`` runs, so
    the caller can propagate EOF to the other side (e.g. close the server's stdin
    when the agent disconnects). A failure here never crashes the broker.
    """
    try:
        while True:
            chunk = os.read(src_fd, _PROXY_CHUNK)
            if not chunk:
                break
            offset = 0
            while offset < len(chunk):
                offset += os.write(dst_fd, chunk[offset:])
    except OSError:
        pass
    finally:
        if on_eof is not None:
            try:
                on_eof()
            except OSError:
                pass


def _proxy(conn: socket.socket, child) -> None:
    """Bidirectionally proxy the socket <-> spawned server stdio, then reap.

    Two threads pump the directions concurrently:

      * socket -> child stdin: when the agent disconnects (socket EOF), this
        pump's ``on_eof`` CLOSES the child's stdin immediately, so an
        EOF-driven stdio server (the common MCP shutdown signal) sees EOF and
        exits — without this, the server would block forever and the session
        would hang.
      * child stdout -> socket: ends when the server exits or closes stdout.

    We wait on the stdout->socket pump (the session is over once the server
    stops producing output), then reap the child so no zombie ``boxa-mcp``
    process lingers. Finally we send the server's exit status as a NUL-prefixed
    trailer and half-close our write side, so the relay can reflect a non-zero
    server exit as its own exit code (a clean session still ends at 0). The
    trailer is sent AFTER the from_child pump has drained the child's stdout to
    EOF, so it can never interleave with raw MCP output, and the NUL prefix is a
    sentinel impossible inside an MCP JSON-RPC frame.
    """
    conn_fd = conn.fileno()
    child_stdin = child.stdin

    def _close_child_stdin():
        try:
            child_stdin.close()
        except OSError:
            pass

    to_child = threading.Thread(
        target=_pump,
        args=(conn_fd, child_stdin.fileno()),
        kwargs={"on_eof": _close_child_stdin},
        daemon=True,
    )
    from_child = threading.Thread(
        target=_pump, args=(child.stdout.fileno(), conn_fd), daemon=True
    )
    to_child.start()
    from_child.start()

    # The session is over when the server stops producing output. (The agent's
    # disconnect is handled by to_child's on_eof closing the server's stdin, so
    # an EOF-driven server exits and from_child then returns.)
    from_child.join()
    _close_child_stdin()
    # Reap the child so no zombie boxa-mcp process lingers, and capture its
    # exit status to forward to the relay. A server that started fine but then
    # exited non-zero (e.g. bad runtime config) must NOT look like a clean exit.
    try:
        returncode = child.wait(timeout=10)
    except Exception:  # noqa: BLE001 - best-effort reap; never crash the broker
        try:
            child.kill()
        except OSError:
            pass
        # We terminated it ourselves; report a non-zero status so the relay does
        # not mistake a killed-after-hang server for a clean exit.
        try:
            returncode = child.wait(timeout=5)
        except Exception:  # noqa: BLE001
            returncode = None
    # Send the exit trailer, then half-close so the relay sees EOF after it.
    # Wrapped because the relay may already be gone (broken pipe is harmless: the
    # broker stays up and the next session is unaffected).
    if returncode is None:
        # Could not determine the child's status; surface a generic failure so a
        # hung/unreapable server is never reported to the agent as clean.
        returncode = 1
    try:
        conn.sendall(encode_exit(returncode))
    except OSError:
        pass
    try:
        conn.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    to_child.join(timeout=1)
    # Close the child's stdio pipe objects so their fds are released. The broker
    # is long-lived and services many connections; leaking the Popen-owned
    # BufferedReader/Writer per session would slowly exhaust the broker's fd
    # table (and surfaces as a ResourceWarning under -W error). Closing is
    # best-effort: the fds may already be gone once the child exited.
    for stream in (child.stdout, child.stdin):
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass


def _handle(conn: socket.socket) -> None:
    """Service one relay connection: handshake -> spawn -> proxy.

    Every failure before the proxy phase is reported back to the relay as a
    SECRET-FREE refusal reply, then the connection is closed. No partial server
    is ever left running on a refused request.
    """
    import subprocess  # noqa: S404 - argv list, no shell; spawns the MCP server

    child = None
    # Bound the handshake read so a silent client cannot pin this thread forever.
    conn.settimeout(_HANDSHAKE_TIMEOUT_SECONDS)
    try:
        try:
            line = read_line(conn.recv)
            server, project_key, requested_cwd = decode_request(line)
        except ProtocolError as exc:
            conn.sendall(encode_reply(False, f"bad handshake: {exc}"))
            return
        except (TimeoutError, OSError):
            # Slowloris / dead connection: the client connected but never sent a
            # complete handshake within the deadline. Drop it silently (sending a
            # reply could block on the same stuck peer) so the thread + fd free.
            return
        # Handshake complete: the stdio proxy that follows is legitimately
        # long-lived and idle between MCP messages, so clear the deadline (restore
        # blocking mode) before proxying — the proxy reads the socket fd directly.
        conn.settimeout(None)

        try:
            argv, child_env, spawn_cwd = _build_spawn(
                server, project_key, requested_cwd
            )
        except BrokerError as exc:
            conn.sendall(encode_reply(False, str(exc)))
            return

        try:
            child = subprocess.Popen(  # noqa: S603 - argv list, no shell
                argv,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=sys.stderr,
                env=child_env,
                cwd=spawn_cwd,
                close_fds=True,
            )
        except OSError as exc:
            # Command name is non-secret (it is the profile's argv[0]).
            conn.sendall(
                encode_reply(False, f"failed to launch {server!r}: {exc}")
            )
            return

        conn.sendall(encode_reply(True))
        _proxy(conn, child)
    finally:
        try:
            conn.close()
        except OSError:
            pass


def _bind_socket(path: str) -> socket.socket:
    """Create and bind the broker's unix socket cleanly (idempotent on restart).

    A stale socket file from a previous run is removed first so a restart never
    fails with ``EADDRINUSE``. The socket file is then chmodded to ``0660``; the
    containing dir is group-owned ``boxa-bridge`` 0770 (created by the
    entrypoint root phase before the drop), so the relay (``node``, a member of
    ``boxa-bridge``) connects and the broker (``boxa-mcp``) serves — without
    either being in the other's primary group, and with no world access.
    """
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise BrokerError(f"cannot remove stale broker socket {path}: {exc}") from exc

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(path)
    os.chmod(path, _SOCKET_MODE)
    sock.listen(64)
    return sock


def serve(path: Optional[str] = None, stop_event: Optional[threading.Event] = None) -> int:
    """Run the broker accept loop until terminated. Returns an exit code.

    Always serves, even with no profile present: the accept loop is up so a
    server added to a running Container works on the next session. Each accepted
    connection is handled on its own thread so one slow server never blocks
    another agent session.

    In production the broker IS the main thread and stops on SIGTERM/SIGINT.
    When run off-main-thread (a test harness, where signals cannot be used and
    the caller does not hold the listening socket), pass ``stop_event``: setting
    it makes the loop exit within one ``select`` timeout (~1s), so the thread is
    cleanly joinable without relying on a signal or on unlinking the socket file
    (unlinking the path does NOT close the open listening fd, so it cannot stop
    the loop on its own).
    """
    path = path or socket_path()
    sock = _bind_socket(path)

    stopping = stop_event or threading.Event()

    def _stop(_signum, _frame):
        stopping.set()
        # Unblock the accept() by poking the selector via a self-close.
        try:
            sock.close()
        except OSError:
            pass

    # Signal handlers can only be installed from the main thread; in production
    # the broker IS the main thread (launched directly by the entrypoint), so we
    # get clean SIGTERM/SIGINT shutdown. When serve() runs off-main-thread (e.g.
    # a test harness), skip handler installation rather than crash — the loop
    # still exits via the 1s select timeout when the listening socket is closed.
    if threading.current_thread() is threading.main_thread():
        signal.signal(signal.SIGTERM, _stop)
        signal.signal(signal.SIGINT, _stop)

    sel = selectors.DefaultSelector()
    sel.register(sock, selectors.EVENT_READ)
    try:
        while not stopping.is_set():
            try:
                events = sel.select(timeout=1.0)
            except OSError:
                break  # socket closed by the signal handler
            for _key, _mask in events:
                try:
                    conn, _addr = sock.accept()
                except OSError:
                    stopping.set()
                    break
                threading.Thread(
                    target=_handle, args=(conn,), daemon=True
                ).start()
    finally:
        try:
            sel.close()
        except OSError:
            pass
        # Close the listening socket on every shutdown path. The signal handler
        # closes it on SIGTERM/SIGINT, but the event-driven stop (off-main-thread)
        # does not, so without this the listener fd would leak (surfacing as a
        # ResourceWarning under -W error and slowly exhausting the broker's fd
        # table across restarts). close() is idempotent, so the signal path that
        # already closed it is unharmed.
        try:
            sock.close()
        except OSError:
            pass
        try:
            os.unlink(path)
        except OSError:
            pass
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    """CLI entry point for the broker (run as boxa-mcp by the entrypoint)."""
    parser = argparse.ArgumentParser(
        prog="boxa-mcp-broker",
        description="Always-on Container MCP broker (ADR 0014).",
    )
    parser.add_argument(
        "--socket",
        dest="socket",
        default=None,
        help="Unix socket path to listen on (default: %s)." % DEFAULT_SOCKET_PATH,
    )
    args = parser.parse_args(argv)

    # Defensive: the broker is a Container-only runtime component. Refuse on the
    # host so a stray invocation never opens a socket outside a Container.
    if not inside_container():
        print(
            "boxa-mcp-broker: refusing to run outside a boxa Container.",
            file=sys.stderr,
        )
        return 1

    try:
        return serve(args.socket)
    except BrokerError as exc:
        print(f"boxa-mcp-broker: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":  # pragma: no cover - module exec entry
    raise SystemExit(main())
