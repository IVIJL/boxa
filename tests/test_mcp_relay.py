"""Tests for the MCP relay (mcp.relay) — ADR 0014, issue 15.

The relay is the reworked ``boxa-mcp-run``: it runs as ``node``, connects to
the broker socket, names the requested server, and proxies stdio. These tests
run the relay against a STUB broker (a plain unix socket the test controls), so
no real broker / boxa-mcp account is needed:

  * accept path: handshake exchanged, then stdin<->socket proxy round-trips;
  * refuse path: a broker refusal becomes a clean RelayError (SECRET-FREE);
  * host guard: the relay refuses outside a Container before touching a socket;
  * unreachable broker: a clean, actionable RelayError (no traceback).

These tests are written to be DETERMINISTIC under full-suite load: the proxy
round-trip reads in a poll-until-deadline loop (never a fixed sleep + single
read that could race the relay's proxy thread), and every fd / socket / thread
is torn down via ``addCleanup`` so a failed assertion never leaks an open
descriptor (which would surface as a ``ResourceWarning``).
"""

from __future__ import annotations

import os
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(REPO_ROOT, "scripts")
if SCRIPTS not in sys.path:
    sys.path.insert(0, SCRIPTS)

from mcp import protocol  # noqa: E402
from mcp import relay  # noqa: E402
from mcp.relay import RelayError  # noqa: E402

# Generous upper bound for any in-test round-trip. The proxy is local (a unix
# socket + a thread), so it completes in milliseconds; 5s only bounds a genuine
# hang so the test fails fast with a clear message instead of blocking the suite.
_DEADLINE_SECONDS = 5.0


def _make_identity(tmp):
    """Create a Container identity file so require_container() passes."""
    path = os.path.join(tmp, "identity.json")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write('{"project":"p"}')
    return path


class _StubBroker:
    """A minimal stub broker on a unix socket the relay connects to.

    ``reply_ok`` controls the handshake outcome; on accept it echoes everything
    the relay forwards (so the proxy can be checked round-trip).

    The accept thread, the listening socket, and the accepted connection are all
    closed deterministically by :meth:`stop`, which the test registers via
    ``addCleanup`` so nothing leaks even when an assertion fails mid-test.
    """

    def __init__(self, path, reply_ok=True, error=None, exit_code=0):
        self.path = path
        self.reply_ok = reply_ok
        self.error = error
        self.exit_code = exit_code
        self.received_request = None
        self._conn = None
        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.bind(path)
        self._srv.listen(1)
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def start(self):
        self._thread.start()

    def _serve(self):
        try:
            conn, _ = self._srv.accept()
        except OSError:
            return
        self._conn = conn
        try:
            line = protocol.read_line(conn.recv)
            self.received_request = protocol.decode_request(line)
            conn.sendall(protocol.encode_reply(self.reply_ok, self.error))
            if not self.reply_ok:
                return
            # Echo loop: relay stdin -> here -> relay stdout. Ends when the relay
            # half-closes its write side (SHUT_WR) after draining stdin.
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                conn.sendall(data)
        except OSError:
            pass
        finally:
            # Mirror the real broker: after the (echoed) MCP stream ends, send the
            # NUL-prefixed exit trailer carrying the spawned server's status, THEN
            # half-close OUR write side so the relay's proxy loop sees EOF and
            # relay.run() returns that status. Without the SHUT_WR the relay would
            # block forever in select() on a socket the stub never closes (the
            # round trip would hang the whole suite). stop() still does the final
            # close.
            try:
                conn.sendall(protocol.encode_exit(self.exit_code))
            except OSError:
                pass
            try:
                conn.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def stop(self):
        """Close the server + any accepted connection and join the thread.

        Idempotent and exception-safe so it is always usable as an ``addCleanup``
        without ordering assumptions. Closing the listening socket unblocks a
        pending ``accept``; closing the connection unblocks a pending ``recv``.
        """
        try:
            self._srv.close()
        except OSError:
            pass
        if self._conn is not None:
            try:
                self._conn.close()
            except OSError:
                pass
        self._thread.join(timeout=_DEADLINE_SECONDS)


def _read_until(fd, expected_len, deadline_seconds=_DEADLINE_SECONDS):
    """Read from ``fd`` until ``expected_len`` bytes arrive or EOF or deadline.

    Replaces a fixed ``sleep`` + single ``os.read`` (which races the relay's
    proxy thread under load): we poll the fd with a short ``select`` timeout and
    accumulate until we have what we expect, the peer closes (EOF), or the
    deadline elapses — so a never-arriving byte fails fast with a clear message
    rather than hanging the suite or flaking.
    """
    import selectors

    sel = selectors.DefaultSelector()
    sel.register(fd, selectors.EVENT_READ)
    got = b""
    end = time.monotonic() + deadline_seconds
    try:
        while len(got) < expected_len:
            remaining = end - time.monotonic()
            if remaining <= 0:
                break
            if not sel.select(timeout=min(0.05, remaining)):
                continue
            chunk = os.read(fd, 4096)
            if not chunk:
                break  # EOF
            got += chunk
    finally:
        sel.close()
    return got


class RelayHostGuardTests(unittest.TestCase):
    def test_refuses_on_host(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = os.path.join(tmp, "no-identity.json")
            with mock.patch.dict(os.environ, {"BOXA_MCP_IDENTITY_PATH": missing}):
                with self.assertRaises(Exception):
                    relay.run("anything")


class RelayUnreachableTests(unittest.TestCase):
    def test_unreachable_broker_clean_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            ident = _make_identity(tmp)
            sock_path = os.path.join(tmp, "absent.sock")
            with mock.patch.dict(
                os.environ,
                {
                    "BOXA_MCP_IDENTITY_PATH": ident,
                    "BOXA_MCP_BROKER_SOCKET": sock_path,
                },
            ):
                with self.assertRaises(RelayError) as ctx:
                    relay.run("ctx")
            self.assertIn("broker", str(ctx.exception).lower())


class RelayRefusalTests(unittest.TestCase):
    def test_broker_refusal_becomes_relay_error(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(tmp, ignore_errors=True))
        ident = _make_identity(tmp)
        sock_path = os.path.join(tmp, "broker.sock")
        stub = _StubBroker(sock_path, reply_ok=False, error="out of scope")
        self.addCleanup(stub.stop)
        stub.start()
        with mock.patch.dict(
            os.environ,
            {
                "BOXA_MCP_IDENTITY_PATH": ident,
                "BOXA_MCP_BROKER_SOCKET": sock_path,
            },
        ):
            with self.assertRaises(RelayError) as ctx:
                relay.run("evil")
        msg = str(ctx.exception)
        self.assertIn("refused", msg.lower())
        self.assertIn("out of scope", msg)
        # The relay also forwards its cwd (3rd element) so the broker can spawn
        # the server in the agent session's dir; assert only the names here.
        self.assertEqual(stub.received_request[:2], ("evil", None))


class RelayProxyTests(unittest.TestCase):
    def test_accept_and_proxy_round_trip(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(tmp, ignore_errors=True))
        ident = _make_identity(tmp)
        sock_path = os.path.join(tmp, "broker.sock")
        stub = _StubBroker(sock_path, reply_ok=True)
        self.addCleanup(stub.stop)
        stub.start()

        # Wire fake stdin (pre-filled) and stdout (a pipe we read back). Register
        # every fd for deterministic teardown first; closing an already-closed fd
        # is tolerated below, so an assertion failure never leaks a descriptor.
        stdin_r, stdin_w = os.pipe()
        stdout_r, stdout_w = os.pipe()
        open_fds = {stdin_r, stdin_w, stdout_r, stdout_w}

        def _close_fds():
            for fd in open_fds:
                try:
                    os.close(fd)
                except OSError:
                    pass

        self.addCleanup(_close_fds)

        payload = b"jsonrpc-frame-1\njsonrpc-frame-2\n"
        os.write(stdin_w, payload)
        os.close(stdin_w)  # EOF so the relay half-closes and the stub ends
        open_fds.discard(stdin_w)

        with mock.patch.dict(
            os.environ,
            {
                "BOXA_MCP_IDENTITY_PATH": ident,
                "BOXA_MCP_BROKER_SOCKET": sock_path,
            },
        ):
            with mock.patch.object(sys, "stdin") as fake_in, mock.patch.object(
                sys, "stdout"
            ) as fake_out:
                fake_in.fileno.return_value = stdin_r
                fake_out.fileno.return_value = stdout_w
                rc = relay.run("echo")

        # The relay has returned, so its proxy thread has drained stdin to the
        # stub and written the echo back to stdout_w. Close our write end so the
        # read side sees EOF, then poll-read until we have the full payload (or
        # the deadline trips, which fails fast rather than racing/handing).
        os.close(stdout_w)
        open_fds.discard(stdout_w)
        got = _read_until(stdout_r, len(payload))

        self.assertEqual(rc, 0)
        self.assertEqual(got, payload)
        self.assertEqual(stub.received_request[:2], ("echo", None))
        # The relay forwards its working directory as the 3rd handshake element.
        self.assertEqual(stub.received_request[2], os.getcwd())


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
