"""Wire protocol shared by the MCP broker and relay (ADR 0014, issue 15).

The relay (``boxa-mcp-run``, running as ``node``) and the broker (running as
``boxa-mcp``) talk over a unix-domain stream socket. The conversation has two
phases:

  1. **Handshake** — the relay sends exactly one newline-terminated JSON object
     naming the server it wants (and the optional Project key). The broker
     replies with one newline-terminated JSON object reporting whether it
     accepted the request. No credential is ever carried in either direction:
     the handshake names a server, the reply reports a status.
  2. **Launch/stream** — a service-isolated acceptance switches both sides to a
     raw byte proxy. An agent-trusted acceptance instead carries a secret-free,
     deterministic launch plan; the relay closes the authorization socket and
     starts that plan locally as ``node``.
  3. **Exit trailer** — once the spawned server's stdout reaches EOF (the server
     exited or closed stdout) the broker reaps the child and sends ONE final
     control frame carrying the server's exit status, then half-closes its write
     side. The relay reads the trailer and reflects the status as its OWN exit
     code, so a server that started cleanly but then exited non-zero is no longer
     reported to the agent as a clean exit (the ADR 0013 exec wrapper propagated
     the server's exit code; the broker/relay split must not regress that).

     The trailer is prefixed by a single NUL byte (``\\x00``). MCP JSON-RPC over
     stdio is newline-delimited JSON text and never emits a raw NUL byte inside a
     frame (a literal NUL in a JSON string is escaped as ``\\u0000``), so the NUL
     is an unambiguous, in-band-impossible sentinel: every byte BEFORE the first
     NUL is genuine MCP stdout (forwarded straight through); the NUL and
     everything after it is the trailer. This keeps the status out of band of the
     MCP stream without a second socket or a length framing the raw stream cannot
     carry.

Framing rationale: a single ``\\n``-terminated JSON line is enough for the
handshake because the request and the reply are each a small, flat object. The
broker reads up to a bounded number of bytes for the handshake so a hostile or
buggy client cannot make it buffer without limit before the stream phase.

SECURITY: the handshake intentionally carries names only (server name, project
key). Secret VALUES never cross this socket — they are injected by the broker
into the spawned process's environment (issue 16), out of band of this protocol.
"""

from __future__ import annotations

import json
from typing import Any, Optional

# Upper bound on the handshake line, in bytes. The handshake is a small flat
# JSON object (a server name + an absolute path); 64 KiB is far more than any
# legitimate request needs and bounds the broker's pre-stream buffering against
# a client that never sends a newline.
MAX_HANDSHAKE_BYTES = 64 * 1024


class ProtocolError(RuntimeError):
    """A malformed or oversized handshake on the broker/relay socket."""


def encode_request(
    server: str, project_key: Optional[str], cwd: Optional[str] = None,
    *, catalog_id: Optional[str] = None, consumer: Optional[str] = None,
) -> bytes:
    """Encode a relay -> broker handshake request (server name + scope + cwd).

    ``project_key`` is the absolute host path for a Project-scoped server, or
    ``None``/empty for a global one. ``cwd`` is the relay's working directory so
    the broker can spawn the server with the agent session's cwd rather than the
    broker's own startup dir (project-local MCP commands rely on relative paths).
    The cwd is NOT a secret — it is a working directory, carried so the spawned
    server resolves relative paths against the session, not the broker. Only
    names + the cwd cross the wire; never a credential value.
    """
    obj: dict[str, Any] = {"server": str(server)}
    if project_key:
        obj["project"] = str(project_key)
    if cwd:
        obj["cwd"] = str(cwd)
    if catalog_id:
        obj["catalogId"] = str(catalog_id)
    if consumer:
        obj["consumer"] = str(consumer)
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")


def decode_request(line: bytes) -> tuple[str, Optional[str], Optional[str]]:
    """Decode a relay -> broker handshake into ``(server, project_key, cwd)``.

    Raises :class:`ProtocolError` for anything that is not a JSON object with a
    non-empty string ``server`` field, so the broker rejects junk before it
    touches a profile or spawns anything. ``cwd`` is optional (older relays omit
    it); the broker validates it before use and falls back to a safe default.
    """
    server, project, cwd, _catalog_id, _consumer = decode_request_details(line)
    return server, project, cwd


def decode_request_details(
    line: bytes,
) -> tuple[str, Optional[str], Optional[str], Optional[str], Optional[str]]:
    """Decode the activation-aware request while legacy callers keep 3 fields."""
    try:
        obj = json.loads(line.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ProtocolError(f"handshake is not valid JSON: {exc}") from exc
    if not isinstance(obj, dict):
        raise ProtocolError("handshake is not a JSON object")
    server = obj.get("server")
    if not isinstance(server, str) or not server:
        raise ProtocolError("handshake missing a non-empty 'server' name")
    project = obj.get("project")
    if project is not None and not isinstance(project, str):
        raise ProtocolError("handshake 'project' must be a string when present")
    cwd = obj.get("cwd")
    if cwd is not None and not isinstance(cwd, str):
        raise ProtocolError("handshake 'cwd' must be a string when present")
    catalog_id = obj.get("catalogId")
    consumer = obj.get("consumer")
    if catalog_id is not None and (not isinstance(catalog_id, str) or not catalog_id):
        raise ProtocolError("handshake 'catalogId' must be a non-empty string")
    if consumer is not None and (not isinstance(consumer, str) or not consumer):
        raise ProtocolError("handshake 'consumer' must be a non-empty string")
    if bool(catalog_id) != bool(consumer):
        raise ProtocolError("handshake catalogId and consumer must be supplied together")
    return server, (project or None), (cwd or None), catalog_id, consumer


def encode_reply(
    ok: bool, error: Optional[str] = None, launch: Optional[dict[str, Any]] = None
) -> bytes:
    """Encode a broker -> relay status reply (accepted, or refused + reason).

    The ``error`` text is SECRET-FREE by construction (the broker only ever puts
    server/scope names and structural failures here), so it is safe to surface
    to the agent. It is never a credential value.
    """
    obj: dict[str, Any] = {"ok": bool(ok)}
    if not ok and error:
        obj["error"] = str(error)
    if ok and launch is not None:
        obj["launch"] = launch
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")


def decode_reply(line: bytes) -> tuple[bool, Optional[str]]:
    """Decode a broker -> relay reply into ``(ok, error)``."""
    ok, error, _launch = decode_reply_details(line)
    return ok, error


def decode_reply_details(
    line: bytes,
) -> tuple[bool, Optional[str], Optional[dict[str, Any]]]:
    """Decode status plus an optional secret-free agent-trusted launch plan."""
    try:
        obj = json.loads(line.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ProtocolError(f"broker reply is not valid JSON: {exc}") from exc
    if not isinstance(obj, dict):
        raise ProtocolError("broker reply is not a JSON object")
    ok = obj.get("ok")
    if not isinstance(ok, bool):
        raise ProtocolError("broker reply missing boolean 'ok'")
    error = obj.get("error")
    if error is not None and not isinstance(error, str):
        raise ProtocolError("broker reply 'error' must be a string when present")
    launch = obj.get("launch")
    if launch is not None:
        if not ok or not isinstance(launch, dict):
            raise ProtocolError("broker reply 'launch' must be an object on success")
        argv = launch.get("argv")
        env = (
            launch.get("env")
            if launch.get("executionMode") == "agent-trusted"
            else launch.get("environment")
        )
        cwd = launch.get("cwd")
        if launch.get("executionMode") not in {"agent-trusted", "service-isolated"}:
            raise ProtocolError("broker launch plan has invalid execution mode")
        if not isinstance(argv, list) or not argv or any(
            not isinstance(value, str) for value in argv
        ):
            raise ProtocolError("broker launch plan argv is invalid")
        if not isinstance(env, dict) or any(
            not isinstance(key, str) or not isinstance(value, str)
            for key, value in env.items()
        ):
            raise ProtocolError("broker launch plan env is invalid")
        if launch.get("executionMode") == "service-isolated" and launch.get("adapter") != "docker":
            raise ProtocolError("broker service-isolated launch plan has invalid adapter")
        if cwd is not None and not isinstance(cwd, str):
            raise ProtocolError("broker launch plan cwd is invalid")
    return ok, (error or None), launch


# Sentinel prefixing the exit trailer. A raw NUL byte cannot occur inside an MCP
# JSON-RPC stdio frame (a literal NUL in a JSON string is escaped as the six
# characters backslash-u-0-0-0-0, never a raw NUL byte), so it
# unambiguously separates the end of the MCP stdout stream from the broker's
# final exit-status frame: bytes before the first NUL are MCP stdout, the NUL and
# everything after it are the trailer.
EXIT_TRAILER_SENTINEL = b"\x00"

# Upper bound on the exit trailer, in bytes. The trailer is a tiny fixed-shape
# frame (sentinel + a small JSON object); this bounds the relay's post-stream
# buffering against a hostile/buggy peer that sends a NUL then floods.
MAX_EXIT_TRAILER_BYTES = 256


def encode_exit(code: int) -> bytes:
    """Encode the broker -> relay exit trailer carrying the server's status.

    Emitted ONCE, after the spawned server's stdout reaches EOF, so the relay can
    reflect the server's exit code as its own. Prefixed by the NUL sentinel
    (impossible inside an MCP JSON-RPC frame) so the relay tells it apart from raw
    MCP stdout without any framing of the stream itself. Carries a status only —
    never a credential.
    """
    obj: dict[str, Any] = {"exit": int(code)}
    return EXIT_TRAILER_SENTINEL + json.dumps(obj, separators=(",", ":")).encode(
        "utf-8"
    )


def decode_exit(frame: bytes) -> int:
    """Decode a broker -> relay exit trailer into the server's exit code.

    ``frame`` is the bytes AFTER the NUL sentinel. Raises :class:`ProtocolError`
    for anything that is not a JSON object with an integer ``exit`` field, so a
    truncated/garbled trailer is a relay error rather than a silently-wrong code.
    """
    try:
        obj = json.loads(frame.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ProtocolError(f"exit trailer is not valid JSON: {exc}") from exc
    if not isinstance(obj, dict):
        raise ProtocolError("exit trailer is not a JSON object")
    code = obj.get("exit")
    if not isinstance(code, int) or isinstance(code, bool):
        raise ProtocolError("exit trailer missing integer 'exit'")
    return code


def read_line(recv, max_bytes: int = MAX_HANDSHAKE_BYTES) -> bytes:
    """Read one ``\\n``-terminated line from a blocking byte stream.

    ``recv`` is any callable taking a byte count and returning bytes (e.g.
    ``socket.recv`` or ``file.read``); reading is one byte short of greedy so
    the bytes after the newline (the start of the raw MCP stream) stay in the
    socket buffer for the proxy phase rather than being swallowed here.

    Returns the line WITHOUT the trailing newline. Raises
    :class:`ProtocolError` if the peer closes before a newline or the line
    exceeds ``max_bytes`` (bounding pre-stream buffering).
    """
    buf = bytearray()
    while True:
        chunk = recv(1)
        if not chunk:
            raise ProtocolError("connection closed before handshake completed")
        if chunk == b"\n":
            return bytes(buf)
        buf.extend(chunk)
        if len(buf) > max_bytes:
            raise ProtocolError("handshake exceeded maximum length")
