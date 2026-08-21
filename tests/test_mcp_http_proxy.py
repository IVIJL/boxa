"""ADR 0030 loopback-only pinned remote MCP auth proxy."""

from __future__ import annotations

import http.client
import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import http_proxy  # noqa: E402


class _AuthenticatedUpstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        return

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self.server.requests.append((self.path, dict(self.headers), body))
        if (
            self.headers.get("Authorization") != "Bearer test-token"
            or self.headers.get("X-Region") != "eu"
        ):
            response = b"unauthorized"
            self.send_response(401)
        else:
            response = b'{"jsonrpc":"2.0","result":{"ok":true}}'
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


class HttpProxyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.project = "/host/projects/example"
        self.entry_id = str(uuid.uuid4())
        self.secrets_dir = os.path.join(self.tmp.name, "secrets")
        os.makedirs(self.secrets_dir)
        self._write_secrets("Bearer test-token")

        if not shutil.which("openssl"):
            self.skipTest("openssl is required for the local HTTPS stub")
        self.cert = os.path.join(self.tmp.name, "cert.pem")
        key = os.path.join(self.tmp.name, "key.pem")
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", key, "-out", self.cert, "-days", "1", "-nodes",
                "-subj", "/CN=127.0.0.1",
                "-addext", "subjectAltName=IP:127.0.0.1",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )
        self.upstream = ThreadingHTTPServer(
            ("127.0.0.1", 0), _AuthenticatedUpstream
        )
        self.upstream.requests = []
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(self.cert, key)
        self.upstream.socket = server_context.wrap_socket(
            self.upstream.socket, server_side=True
        )
        self._start(self.upstream)

        upstream_port = self.upstream.server_address[1]
        self.entry = {
            "id": self.entry_id,
            "name": "secure-remote",
            "type": "http",
            "url": f"https://127.0.0.1:{upstream_port}/pinned/mcp?fixed=yes",
            "headers": {"X-Region": "eu"},
            "secretHeaderKeys": ["Authorization"],
            "readiness": {"summary": "no-runtime-readiness"},
        }
        self.runtime = {
            "entries": {self.entry_id: self.entry},
            "projects": {
                self.project: {
                    self.entry_id: {
                        "catalogId": self.entry_id,
                        "consumers": ["claude", "codex"],
                    }
                }
            },
        }
        client_context = ssl.create_default_context(cafile=self.cert)
        self.proxy = http_proxy.create_server(
            port=0,
            secrets_dir=self.secrets_dir,
            runtime_loader=lambda: self.runtime,
            project_loader=lambda: self.project,
            ssl_context_factory=lambda: client_context,
        )
        self.route_tokens = {
            consumer: self.proxy.issue_route(self.entry_id, consumer)
            for consumer in ("claude", "codex")
        }
        self._start(self.proxy)

    def _start(self, server):
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

    def _write_secrets(self, value, header_name="Authorization"):
        path = os.path.join(self.secrets_dir, "secrets.json")
        if os.path.exists(path):
            os.chmod(path, 0o600)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({
                "version": 1,
                "servers": {},
                "headers": {self.entry_id: {header_name: value}},
            }, fh)
        os.chmod(path, 0o400)

    def _connection(self):
        return http.client.HTTPConnection(
            "127.0.0.1", self.proxy.server_address[1], timeout=5
        )

    def _route(self, consumer="claude"):
        return f"/mcp/{self.route_tokens[consumer]}/{self.entry_id}"

    def test_proxy_route_uses_unforgeable_consumer_capability(self):
        claude_token = self.route_tokens["claude"]
        codex_token = self.route_tokens["codex"]
        self.assertNotEqual(claude_token, codex_token)
        claude_route = f"/mcp/{claude_token}/{self.entry_id}"
        self.assertNotIn("/claude/", claude_route)
        self.assertNotIn("/codex/", claude_route)

        forged = self._connection()
        forged.request(
            "POST", f"/mcp/{'A' * len(claude_token)}/{self.entry_id}", body=b"{}"
        )
        forged_response = forged.getresponse()
        forged_response.read()
        forged.close()
        self.assertEqual(forged_response.status, 404)

        allowed = self._connection()
        allowed.request("POST", claude_route, body=b"{}")
        allowed_response = allowed.getresponse()
        allowed_response.read()
        allowed.close()
        self.assertEqual(allowed_response.status, 200)

    def test_published_port_and_atomic_temp_are_not_agent_writable(self):
        path = os.path.join(self.tmp.name, "published", "http-proxy.port")
        seen = {}
        real_replace = os.replace

        def inspect_replace(source, destination):
            seen["temp_mode"] = os.stat(source).st_mode & 0o777
            real_replace(source, destination)

        with mock.patch.dict(
            os.environ, {"BOXA_MCP_HTTP_PROXY_PORT_FILE": path}
        ), mock.patch.object(os, "replace", side_effect=inspect_replace):
            http_proxy.publish_proxy_port(43123)

        self.assertEqual(seen["temp_mode"], 0o644)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o644)

    def test_forwards_to_exact_https_url_with_staged_and_catalog_headers(self):
        conn = self._connection()
        conn.request(
            "POST",
            self._route(),
            body=b'{"jsonrpc":"2.0"}',
            headers={
                "Content-Type": "application/json",
                "Authorization": "agent-override",
                "X-Region": "agent-override",
                "Host": "attacker.example",
            },
        )
        response = conn.getresponse()
        body = response.read()
        conn.close()

        self.assertEqual(response.status, 200, body)
        self.assertEqual(json.loads(body)["result"], {"ok": True})
        self.assertEqual(len(self.upstream.requests), 1)
        path, headers, forwarded_body = self.upstream.requests[0]
        self.assertEqual(path, "/pinned/mcp?fixed=yes")
        self.assertEqual(headers["Authorization"], "Bearer test-token")
        self.assertEqual(headers["X-Region"], "eu")
        self.assertNotEqual(headers["Host"], "attacker.example")
        self.assertEqual(forwarded_body, b'{"jsonrpc":"2.0"}')

    def test_refuses_absolute_url_and_path_override_without_upstream_request(self):
        for target in (
            f"http://attacker.example{self._route()}",
            self._route() + "/other",
            self._route() + "?target=https://attacker.example",
        ):
            conn = self._connection()
            conn.request("POST", target, body=b"{}")
            response = conn.getresponse()
            response.read()
            conn.close()
            self.assertEqual(response.status, 404, target)
        self.assertEqual(self.upstream.requests, [])

    def test_missing_secret_is_diagnosable_without_contacting_upstream(self):
        self._write_secrets("")
        conn = self._connection()
        conn.request("POST", self._route(), body=b"{}")
        response = conn.getresponse()
        body = response.read().decode()
        conn.close()

        self.assertEqual(response.status, 503)
        self.assertIn("auth header declared", body)
        self.assertIn("secret value missing", body)
        self.assertNotIn("test-token", body)
        self.assertEqual(self.upstream.requests, [])

    def test_route_is_refused_for_consumer_outside_activation(self):
        self.runtime["projects"][self.project][self.entry_id]["consumers"] = [
            "claude"
        ]
        allowed = self._connection()
        allowed.request("POST", self._route("claude"), body=b"{}")
        allowed_response = allowed.getresponse()
        allowed_response.read()
        allowed.close()
        self.assertEqual(allowed_response.status, 200)
        self.upstream.requests.clear()

        conn = self._connection()
        conn.request("POST", self._route("codex"), body=b"{}")
        response = conn.getresponse()
        response.read()
        conn.close()

        self.assertEqual(response.status, 404)
        self.assertEqual(self.upstream.requests, [])

    def test_secret_header_lookup_is_case_insensitive(self):
        self._write_secrets("Bearer test-token", header_name="authorization")
        conn = self._connection()
        conn.request("POST", self._route(), body=b"{}")
        response = conn.getresponse()
        response.read()
        conn.close()

        self.assertEqual(response.status, 200)
        self.assertEqual(
            self.upstream.requests[0][1]["Authorization"], "Bearer test-token"
        )

    def test_default_listener_uses_an_ephemeral_port(self):
        server = http_proxy.create_server(
            secrets_dir=self.secrets_dir,
            runtime_loader=lambda: self.runtime,
            project_loader=lambda: self.project,
        )
        self.addCleanup(server.server_close)

        self.assertGreater(server.server_address[1], 0)
        self.assertNotEqual(server.server_address[1], 8765)

    def test_listener_is_bound_only_to_ipv4_loopback(self):
        self.assertEqual(self.proxy.server_address[0], "127.0.0.1")

    def test_combined_system_ca_bundle_is_explicit_tls_trust_source(self):
        fake_context = object()
        with mock.patch.object(os.path, "isfile", return_value=True), mock.patch.object(
            ssl, "create_default_context", return_value=fake_context
        ) as create_context:
            self.assertIs(http_proxy._default_ssl_context(), fake_context)
        create_context.assert_called_once_with(
            cafile="/etc/ssl/certs/ca-certificates.crt"
        )


if __name__ == "__main__":
    unittest.main()
