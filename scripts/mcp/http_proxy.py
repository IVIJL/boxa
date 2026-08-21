"""Loopback-only pinned proxy for secret-bearing remote MCP entries.

The agent receives only a local URL containing an unguessable capability bound
to the selected Project activation, catalog entry and consumer. For every
request the broker re-reads the host-owned runtime snapshot and the
boxa-mcp-private staged secret store, verifies that the bound entry remains
active, and forwards only to the entry's exact catalog URL. No request field can
select an upstream host, path or consumer.
"""

from __future__ import annotations

import http.client
import json
import os
import re
import secrets
import socket
import ssl
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Optional
from urllib.parse import urlsplit

from .identity import project_key
from .secrets import global_secrets_path, read_header_secrets
from .trusted import TrustedAuthorizationError, load_runtime_snapshot


HTTP_PROXY_HOST = "127.0.0.1"
HTTP_PROXY_PREFIX = "/mcp/"
HTTP_PROXY_PORT_FILE = "/run/boxa-mcp-public/http-proxy.port"
_HTTP_PROXY_PORT_FILE_ENV = "BOXA_MCP_HTTP_PROXY_PORT_FILE"
SYSTEM_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt"

_ENTRY_ID = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z",
    re.IGNORECASE,
)
_ROUTE_TOKEN = re.compile(r"[A-Za-z0-9_-]{43}\Z")
_ROUTE_OPERATION = "issue-http-proxy-route"
_HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class HttpProxyError(RuntimeError):
    """A secret-free refusal or upstream failure safe to return to the agent."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def proxy_port_file() -> str:
    """Return the broker-published proxy port path (test-overridable)."""
    return os.environ.get(_HTTP_PROXY_PORT_FILE_ENV) or HTTP_PROXY_PORT_FILE


def publish_proxy_port(port: int) -> None:
    """Atomically publish the selected loopback port for launch wrappers."""
    path = proxy_port_file()
    parent = os.path.dirname(path)
    tmp = ""
    fd: Optional[int] = None
    try:
        if parent:
            os.makedirs(parent, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".http-proxy.port.", dir=parent or ".")
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, "w", encoding="ascii") as fh:
            fd = None
            fh.write(f"{port}\n")
        os.replace(tmp, path)
    except OSError as exc:
        if fd is not None:
            os.close(fd)
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise HttpProxyError(
            503, f"cannot publish remote MCP proxy port at {path}: {exc}"
        ) from exc


def remove_proxy_port() -> None:
    """Remove a stale/current proxy port publication."""
    try:
        os.unlink(proxy_port_file())
    except FileNotFoundError:
        pass
    except OSError:
        pass


def _published_proxy_port() -> int:
    path = proxy_port_file()
    try:
        with open(path, encoding="ascii") as fh:
            port = int(fh.read().strip())
    except (OSError, ValueError) as exc:
        raise HttpProxyError(
            503, f"remote MCP proxy port is unavailable at {path}"
        ) from exc
    if not 1 <= port <= 65535:
        raise HttpProxyError(
            503, f"remote MCP proxy port is invalid at {path}"
        )
    return port


def encode_route_request(entry_id: str, consumer: str) -> bytes:
    """Encode a capability request for the broker's existing Unix socket."""
    return (
        json.dumps(
            {
                "operation": _ROUTE_OPERATION,
                "catalogId": str(entry_id),
                "consumer": str(consumer),
            },
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def decode_route_request(line: bytes) -> Optional[tuple[str, str]]:
    """Decode a route request, or return ``None`` for a normal relay request."""
    try:
        obj = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None
    if not isinstance(obj, dict) or obj.get("operation") != _ROUTE_OPERATION:
        return None
    entry_id = obj.get("catalogId")
    consumer = obj.get("consumer")
    if not isinstance(entry_id, str) or not _ENTRY_ID.fullmatch(entry_id):
        raise HttpProxyError(404, "Remote MCP proxy catalog ID is invalid.")
    if consumer not in {"claude", "codex"}:
        raise HttpProxyError(404, "Remote MCP proxy consumer is invalid.")
    return entry_id, consumer


def encode_route_reply(token: str) -> bytes:
    return (
        json.dumps({"ok": True, "routeToken": token}, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def request_route_token(entry_id: str, consumer: str) -> str:
    """Ask the broker to mint/return this activation-consumer capability."""
    from .broker import socket_path
    from .protocol import ProtocolError, read_line

    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(10)
    try:
        conn.connect(socket_path())
        conn.sendall(encode_route_request(entry_id, consumer))
        line = read_line(conn.recv)
    except (OSError, ProtocolError) as exc:
        raise HttpProxyError(
            503, "remote MCP proxy route capability is unavailable"
        ) from exc
    finally:
        conn.close()
    try:
        reply = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise HttpProxyError(
            503, "remote MCP proxy route capability reply is invalid"
        ) from exc
    if not isinstance(reply, dict) or reply.get("ok") is not True:
        message = reply.get("error") if isinstance(reply, dict) else None
        raise HttpProxyError(
            503, str(message or "remote MCP proxy route capability was refused")
        )
    token = reply.get("routeToken")
    if not isinstance(token, str) or not _ROUTE_TOKEN.fullmatch(token):
        raise HttpProxyError(
            503, "remote MCP proxy route capability reply is invalid"
        )
    return token


def proxy_url(
    entry_id: str,
    consumer: str,
    *,
    port: Optional[int] = None,
    route_token: Optional[str] = None,
) -> str:
    """Return the capability-bearing loopback endpoint for one activation."""
    if consumer not in {"claude", "codex"}:
        raise HttpProxyError(404, "Remote MCP proxy consumer is invalid.")
    selected_port = port if port is not None else _published_proxy_port()
    token = route_token or request_route_token(entry_id, consumer)
    if not _ROUTE_TOKEN.fullmatch(token):
        raise HttpProxyError(404, "Remote MCP proxy route capability is invalid.")
    return (
        f"http://{HTTP_PROXY_HOST}:{selected_port}{HTTP_PROXY_PREFIX}"
        f"{token}/{entry_id}"
    )


def _default_ssl_context() -> ssl.SSLContext:
    """Verify upstream TLS against Boxa's combined system CA bundle."""
    if os.path.isfile(SYSTEM_CA_BUNDLE):
        return ssl.create_default_context(cafile=SYSTEM_CA_BUNDLE)
    return ssl.create_default_context()


def _staged_global_secrets_path(secrets_dir: str) -> str:
    return os.path.join(secrets_dir, os.path.basename(global_secrets_path()))


def _active_entry(
    runtime: dict[str, Any], project: str, entry_id: str, consumer: str
) -> dict[str, Any]:
    records = runtime.get("projects", {}).get(project, {})
    record = records.get(entry_id) if isinstance(records, dict) else None
    if (
        not isinstance(record, dict)
        or record.get("enabled", True) is False
        or consumer not in record.get("consumers", [])
    ):
        raise HttpProxyError(
            404, "Remote MCP proxy route is not active for this Project."
        )
    entry = runtime.get("entries", {}).get(entry_id)
    if (
        not isinstance(entry, dict)
        or entry.get("type") != "http"
        or not entry.get("secretHeaderKeys")
    ):
        raise HttpProxyError(404, "Remote MCP proxy route is unavailable.")
    return entry


def _upstream_target(entry: dict[str, Any]) -> tuple[str, int, str]:
    parsed = urlsplit(str(entry["url"]))
    if parsed.scheme.lower() != "https" or not parsed.hostname:
        raise HttpProxyError(
            502, "Remote MCP proxy requires an HTTPS catalog URL."
        )
    port = parsed.port or 443
    target = parsed.path or "/"
    if parsed.query:
        target += "?" + parsed.query
    return parsed.hostname, port, target


def _request_headers(
    incoming: Any,
    entry: dict[str, Any],
    secret_values: dict[str, str],
) -> dict[str, str]:
    proxy_controlled = _HOP_BY_HOP | {"host", "content-length"}
    declared_names = {
        str(name).casefold()
        for name in (*entry.get("headers", {}), *entry["secretHeaderKeys"])
    }
    unsupported = sorted(declared_names & proxy_controlled)
    if unsupported:
        raise HttpProxyError(
            502,
            "Remote MCP entry declares a proxy-controlled header: "
            + ", ".join(unsupported),
        )
    replaced = {
        str(name).casefold()
        for name in (*entry.get("headers", {}), *entry["secretHeaderKeys"])
    }
    result = {
        str(name): str(value)
        for name, value in incoming.items()
        if str(name).casefold() not in proxy_controlled
        and str(name).casefold() not in replaced
    }
    result.update({str(k): str(v) for k, v in entry.get("headers", {}).items()})
    result.update(secret_values)
    return result


class _ProxyServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address: tuple[str, int],
        *,
        secrets_dir: str,
        runtime_loader: Callable[[], dict[str, Any]],
        project_loader: Callable[[], Optional[str]],
        ssl_context_factory: Callable[[], ssl.SSLContext],
    ):
        self.secrets_dir = secrets_dir
        self.runtime_loader = runtime_loader
        self.project_loader = project_loader
        self.ssl_context_factory = ssl_context_factory
        self._route_lock = threading.Lock()
        self._route_tokens: dict[str, tuple[str, str, str]] = {}
        self._activation_tokens: dict[tuple[str, str, str], str] = {}
        super().__init__(address, _ProxyHandler)

    def issue_route(self, entry_id: str, consumer: str) -> str:
        """Return one unguessable token bound to Project, entry and consumer."""
        project = self.project_loader()
        if not project:
            raise HttpProxyError(503, "Container Project identity is unavailable.")
        try:
            runtime = self.runtime_loader()
        except TrustedAuthorizationError as exc:
            raise HttpProxyError(
                503, f"Host-owned MCP runtime snapshot is unavailable: {exc}"
            ) from exc
        _active_entry(runtime, project, entry_id, consumer)
        activation = (project, entry_id, consumer)
        with self._route_lock:
            token = self._activation_tokens.get(activation)
            if token is None:
                token = secrets.token_urlsafe(32)
                while token in self._route_tokens:
                    token = secrets.token_urlsafe(32)
                self._activation_tokens[activation] = token
                self._route_tokens[token] = activation
        return token

    def resolve_route(self, token: str, entry_id: str) -> tuple[str, str]:
        with self._route_lock:
            activation = self._route_tokens.get(token)
        if activation is None or activation[1] != entry_id:
            raise HttpProxyError(404, "Remote MCP proxy route was refused.")
        project, _entry_id, consumer = activation
        own_project = self.project_loader()
        if not own_project or own_project != project:
            raise HttpProxyError(404, "Remote MCP proxy route was refused.")
        return project, consumer


class _ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server: _ProxyServer

    def log_message(self, _format: str, *_args: object) -> None:
        # Request logging adds no diagnostic value here and keeping it disabled
        # ensures future header-aware log formats cannot expose credentials.
        return

    def _error(self, status: int, message: str) -> None:
        body = json.dumps({"error": message}, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _route(self) -> tuple[str, str, str]:
        # Only origin-form requests for the exact generated route are accepted.
        # Absolute-form URLs, query-based overrides, and path suffixes all fail.
        if not self.path.startswith(HTTP_PROXY_PREFIX):
            raise HttpProxyError(404, "Remote MCP proxy route was refused.")
        route = self.path[len(HTTP_PROXY_PREFIX) :].split("/", 1)
        if len(route) != 2 or not _ROUTE_TOKEN.fullmatch(route[0]):
            raise HttpProxyError(404, "Remote MCP proxy route was refused.")
        token, entry_id = route
        if not _ENTRY_ID.fullmatch(entry_id):
            raise HttpProxyError(404, "Remote MCP proxy route was refused.")
        project, consumer = self.server.resolve_route(token, entry_id)
        return project, consumer, entry_id

    def _body(self) -> bytes:
        if self.headers.get("Transfer-Encoding"):
            raise HttpProxyError(
                501, "Remote MCP proxy does not accept transfer-encoded requests."
            )
        raw_length = self.headers.get("Content-Length", "0")
        try:
            length = int(raw_length)
        except ValueError as exc:
            raise HttpProxyError(400, "Remote MCP request has invalid length.") from exc
        if length < 0:
            raise HttpProxyError(400, "Remote MCP request has invalid length.")
        return self.rfile.read(length) if length else b""

    def _proxy(self) -> None:
        upstream: Optional[http.client.HTTPSConnection] = None
        response_started = False
        try:
            own_project, consumer, entry_id = self._route()
            try:
                runtime = self.server.runtime_loader()
            except TrustedAuthorizationError as exc:
                raise HttpProxyError(
                    503, f"Host-owned MCP runtime snapshot is unavailable: {exc}"
                ) from exc
            entry = _active_entry(runtime, own_project, entry_id, consumer)
            stored = read_header_secrets(
                _staged_global_secrets_path(self.server.secrets_dir), entry_id
            ) or {}
            missing = [
                str(name)
                for name in entry["secretHeaderKeys"]
                if not stored.get(str(name).casefold())
            ]
            if missing:
                raise HttpProxyError(
                    503,
                    "Remote MCP auth header declared but secret value missing: "
                    + ", ".join(missing),
                )
            secret_values = {
                str(name): stored[str(name).casefold()]
                for name in entry["secretHeaderKeys"]
            }
            host, port, target = _upstream_target(entry)
            body = self._body()
            headers = _request_headers(self.headers, entry, secret_values)
            if body:
                headers["Content-Length"] = str(len(body))
            upstream = http.client.HTTPSConnection(
                host,
                port,
                timeout=30,
                context=self.server.ssl_context_factory(),
            )
            upstream.request(self.command, target, body=body or None, headers=headers)
            response = upstream.getresponse()
            if upstream.sock is not None:
                upstream.sock.settimeout(None)

            self.send_response(response.status, response.reason)
            for name, value in response.getheaders():
                if name.casefold() not in _HOP_BY_HOP:
                    self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()
            response_started = True
            while True:
                chunk = response.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
            self.close_connection = True
        except HttpProxyError as exc:
            if not response_started:
                self._error(exc.status, str(exc))
        except (OSError, ValueError, ssl.SSLError, http.client.HTTPException) as exc:
            if not response_started:
                self._error(502, f"Remote MCP upstream connection failed: {exc}")
        finally:
            if upstream is not None:
                upstream.close()

    do_DELETE = _proxy
    do_GET = _proxy
    do_HEAD = _proxy
    do_OPTIONS = _proxy
    do_PATCH = _proxy
    do_POST = _proxy
    do_PUT = _proxy


def create_server(
    *,
    port: int = 0,
    secrets_dir: str,
    runtime_loader: Callable[[], dict[str, Any]] = load_runtime_snapshot,
    project_loader: Callable[[], Optional[str]] = project_key,
    ssl_context_factory: Callable[[], ssl.SSLContext] = _default_ssl_context,
) -> ThreadingHTTPServer:
    """Create (but do not start) the loopback-only proxy listener."""
    try:
        return _ProxyServer(
            (HTTP_PROXY_HOST, port),
            secrets_dir=secrets_dir,
            runtime_loader=runtime_loader,
            project_loader=project_loader,
            ssl_context_factory=ssl_context_factory,
        )
    except OSError as exc:
        raise HttpProxyError(
            503, f"cannot bind remote MCP proxy to {HTTP_PROXY_HOST}:{port}: {exc}"
        ) from exc
