"""Tests for the Container MCP broker (mcp.broker) — ADR 0014, issue 15.

Covers the unit-testable security surface of the broker:

  * the wire protocol (handshake/reply encode/decode, bounded line read);
  * scope resolution + name validation (in-scope accept / out-of-scope reject);
  * cross-Project refusal (a Container for Project A must not serve B);
  * the spawn-build path (argv + non-secret env overlay) without launching;
  * an end-to-end socket round-trip: a real broker serving a stub "MCP server"
    (`cat`) over the unix socket, with the relay proxying stdio.

Container-runtime-only checks (documented, validated by construction here):
  * /proc/<pid>/environ unreadable by node — relies on the kernel's 0400 owner
    rule once the broker runs as boxa-mcp; verified by the entrypoint's
    setpriv --reuid/--regid/--init-groups (covered by test_entrypoint below).
  * node cannot signal/ptrace the broker — same UID-boundary property.
"""

from __future__ import annotations

import json
import os
import socket
import stat
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

from mcp import broker  # noqa: E402
from mcp import protocol  # noqa: E402
from mcp.broker import BrokerError  # noqa: E402


def _is_socket(path: str) -> bool:
    """True iff ``path`` is a bound unix socket (not a stale regular file)."""
    try:
        return stat.S_ISSOCK(os.stat(path).st_mode)
    except OSError:
        return False


class _EnvIsolation:
    """Save/restore specific env vars without ``mock.patch.dict(os.environ)``.

    ``mock.patch.dict`` on ``os.environ`` is fragile under full-suite ordering
    (it can raise inside ``__enter__`` if another test mutated the mapping), so
    these tests set env vars directly and restore them in ``addCleanup``.
    """

    def _set_env(self, **values):
        saved = {k: os.environ.get(k) for k in values}

        def restore():
            for k, old in saved.items():
                if old is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = old

        self.addCleanup(restore)
        for k, v in values.items():
            os.environ[k] = v

    def _unset_env(self, *names):
        """Clear env vars for the test, restoring originals in cleanup.

        Use instead of a bare ``os.environ.pop`` so a var that exists in the
        developer/CI environment (e.g. ``API_KEY``) is restored afterwards and
        never leaks into later tests or spawned subprocesses.
        """
        saved = {k: os.environ.get(k) for k in names}

        def restore():
            for k, old in saved.items():
                if old is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = old

        self.addCleanup(restore)
        for k in names:
            os.environ.pop(k, None)


class ProtocolTests(unittest.TestCase):
    def test_request_round_trip_global(self):
        line = protocol.encode_request("context7", None)
        self.assertTrue(line.endswith(b"\n"))
        server, project, cwd = protocol.decode_request(line.rstrip(b"\n"))
        self.assertEqual(server, "context7")
        self.assertIsNone(project)
        self.assertIsNone(cwd)

    def test_request_round_trip_project(self):
        line = protocol.encode_request("ctx", "/work/app")
        server, project, cwd = protocol.decode_request(line.rstrip(b"\n"))
        self.assertEqual(server, "ctx")
        self.assertEqual(project, "/work/app")
        self.assertIsNone(cwd)

    def test_request_round_trip_carries_cwd(self):
        line = protocol.encode_request("ctx", "/work/app", "/work/app/sub")
        server, project, cwd = protocol.decode_request(line.rstrip(b"\n"))
        self.assertEqual(server, "ctx")
        self.assertEqual(project, "/work/app")
        self.assertEqual(cwd, "/work/app/sub")

    def test_decode_request_omitted_cwd_is_none(self):
        # Backward compatible: an older relay omits 'cwd' entirely.
        _server, _project, cwd = protocol.decode_request(b'{"server":"ctx"}')
        self.assertIsNone(cwd)

    def test_decode_request_rejects_non_string_cwd(self):
        with self.assertRaises(protocol.ProtocolError):
            protocol.decode_request(b'{"server":"ctx","cwd":123}')

    def test_reply_round_trip(self):
        ok, err = protocol.decode_reply(
            protocol.encode_reply(False, "refused").rstrip(b"\n")
        )
        self.assertFalse(ok)
        self.assertEqual(err, "refused")
        ok, err = protocol.decode_reply(protocol.encode_reply(True).rstrip(b"\n"))
        self.assertTrue(ok)
        self.assertIsNone(err)

    def test_decode_request_rejects_non_object(self):
        with self.assertRaises(protocol.ProtocolError):
            protocol.decode_request(b'["not","an","object"]')

    def test_decode_request_rejects_missing_server(self):
        with self.assertRaises(protocol.ProtocolError):
            protocol.decode_request(b'{"project":"/x"}')

    def test_decode_request_rejects_garbage(self):
        with self.assertRaises(protocol.ProtocolError):
            protocol.decode_request(b"not json at all")

    def test_exit_trailer_round_trip(self):
        frame = protocol.encode_exit(3)
        self.assertTrue(frame.startswith(protocol.EXIT_TRAILER_SENTINEL))
        self.assertEqual(protocol.decode_exit(frame[1:]), 3)
        self.assertEqual(
            protocol.decode_exit(protocol.encode_exit(0)[1:]), 0
        )

    def test_decode_exit_rejects_non_object(self):
        with self.assertRaises(protocol.ProtocolError):
            protocol.decode_exit(b"[1]")

    def test_decode_exit_rejects_missing_int(self):
        with self.assertRaises(protocol.ProtocolError):
            protocol.decode_exit(b'{"exit":"3"}')

    def test_decode_exit_rejects_bool(self):
        # bool is an int subclass; an exit field of true/false is malformed.
        with self.assertRaises(protocol.ProtocolError):
            protocol.decode_exit(b'{"exit":true}')

    def test_exit_sentinel_is_nul(self):
        # The sentinel must be the NUL byte: impossible inside an MCP JSON-RPC
        # frame, so it unambiguously separates stdout from the trailer.
        self.assertEqual(protocol.EXIT_TRAILER_SENTINEL, b"\x00")

    def test_read_line_bounded(self):
        # A stream that never sends a newline must raise once the cap is hit,
        # not buffer forever.
        data = iter([b"a"] * (protocol.MAX_HANDSHAKE_BYTES + 10))

        def recv(_n):
            return next(data, b"")

        with self.assertRaises(protocol.ProtocolError):
            protocol.read_line(recv, max_bytes=16)

    def test_read_line_stops_at_newline(self):
        payload = b'{"server":"x"}\nEXTRA-STREAM-BYTES'
        pos = {"i": 0}

        def recv(n):
            i = pos["i"]
            chunk = payload[i : i + n]
            pos["i"] += len(chunk)
            return chunk

        line = protocol.read_line(recv)
        self.assertEqual(line, b'{"server":"x"}')
        # The bytes after the newline are left in the stream for the proxy.
        self.assertEqual(payload[pos["i"] :], b"EXTRA-STREAM-BYTES")


class SocketPathBridgeTests(unittest.TestCase):
    """The broker socket path is on the neutral boxa-bridge runtime path and is
    the single source of truth shared by the broker (bind) and the relay (connect).
    """

    def test_default_socket_on_neutral_bridge_not_secret_dir(self):
        # ADR 0014 issue 19: the socket lives on /run/boxa-bridge (node reaches
        # it via the boxa-bridge group), NOT inside the 0700 boxa-mcp secret
        # runtime root — connecting must never require traversing the secret dir.
        self.assertEqual(broker.DEFAULT_SOCKET_PATH, "/run/boxa-bridge/broker.sock")
        self.assertFalse(
            broker.DEFAULT_SOCKET_PATH.startswith("/run/boxa-mcp/"),
            "socket must not live under the boxa-mcp secret runtime root",
        )

    def test_relay_uses_the_same_socket_path_source(self):
        # The relay imports socket_path() FROM broker (single source of truth), so
        # broker.bind and relay.connect can never drift to different paths.
        from mcp import relay

        self.assertIs(relay.socket_path, broker.socket_path)


class BrokerScopeTests(_EnvIsolation, unittest.TestCase):
    """_load_in_scope_spec accepts in-scope names and refuses the rest."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        # Point config_root at the temp dir and stub the Container identity.
        # config_root uses XDG_CONFIG_HOME/boxa/mcp; mirror that layout.
        self.cfg_root = os.path.join(self._tmp.name + "/xdg", "boxa", "mcp")
        os.makedirs(os.path.join(self.cfg_root, "projects"), exist_ok=True)
        self._set_env(XDG_CONFIG_HOME=self._tmp.name + "/xdg")

    def _write_global(self, servers):
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump({"version": 1, "servers": servers}, fh)

    def _write_project(self, project_key, servers):
        from mcp.profile import _sanitize_project

        name = _sanitize_project(project_key)
        with open(os.path.join(self.cfg_root, "projects", name + ".json"), "w") as fh:
            json.dump({"version": 1, "servers": servers}, fh)

    def test_global_in_scope_accepted(self):
        self._write_global({"context7": {"command": {"argv": ["echo", "hi"]}}})
        spec, _secrets_path = broker._load_in_scope_spec("context7", None)
        self.assertEqual(spec["command"]["argv"], ["echo", "hi"])

    def test_global_out_of_scope_refused(self):
        self._write_global({"context7": {"command": {"argv": ["echo"]}}})
        with self.assertRaises(BrokerError) as ctx:
            broker._load_in_scope_spec("evil", None)
        self.assertIn("evil", str(ctx.exception))
        self.assertIn("refused", str(ctx.exception).lower())

    def test_disabled_global_refused(self):
        self._write_global(
            {"s": {"command": {"argv": ["echo"]}, "enabled": False}}
        )
        with self.assertRaises(BrokerError) as ctx:
            broker._load_in_scope_spec("s", None)
        self.assertIn("disabled", str(ctx.exception))

    # -- authoritative full-key path (identity records projectKey) -----------

    def test_project_accepted_when_full_key_matches_container(self):
        key = "/work/myapp"
        self._write_project(key, {"ctx": {"command": {"argv": ["echo"]}}})
        with mock.patch("mcp.broker.project_key", return_value=key):
            spec, _secrets_path = broker._load_in_scope_spec("ctx", key)
        self.assertEqual(spec["command"]["argv"], ["echo"])

    def test_project_refused_when_full_key_differs(self):
        own = "/work/myapp"
        other = "/work/otherproject"
        self._write_project(other, {"ctx": {"command": {"argv": ["echo"]}}})
        with mock.patch("mcp.broker.project_key", return_value=own):
            with self.assertRaises(BrokerError) as ctx:
                broker._load_in_scope_spec("ctx", other)
        self.assertIn("not this container", str(ctx.exception).lower())

    def test_basename_collision_refused_with_full_key(self):
        # Two projects share the basename "api"; the Container is /work/a/api.
        # A relay naming /work/b/api must be refused even though basenames match,
        # because the full keys differ (the P1 finding this guards against).
        own = "/work/a/api"
        other = "/work/b/api"
        self._write_project(other, {"ctx": {"command": {"argv": ["echo"]}}})
        # Also write the OWN project's profile (empty) so the only way to reach
        # other's server is via the (refused) cross-key request.
        self._write_project(own, {})
        with mock.patch("mcp.broker.project_key", return_value=own):
            with self.assertRaises(BrokerError) as ctx:
                broker._load_in_scope_spec("ctx", other)
        self.assertIn("not this container", str(ctx.exception).lower())

    # -- fallback name path (older Container, no projectKey recorded) ---------

    def test_fallback_accepts_when_name_matches(self):
        key = "/work/myapp"
        self._write_project(key, {"ctx": {"command": {"argv": ["echo"]}}})
        with mock.patch("mcp.broker.project_key", return_value=None), \
             mock.patch("mcp.broker.project_name", return_value="myapp"):
            spec, _secrets_path = broker._load_in_scope_spec("ctx", key)
        self.assertEqual(spec["command"]["argv"], ["echo"])

    def test_fallback_refused_when_name_differs(self):
        other = "/work/otherproject"
        self._write_project(other, {"ctx": {"command": {"argv": ["echo"]}}})
        with mock.patch("mcp.broker.project_key", return_value=None), \
             mock.patch("mcp.broker.project_name", return_value="myapp"):
            with self.assertRaises(BrokerError) as ctx:
                broker._load_in_scope_spec("ctx", other)
        self.assertIn("not this container", str(ctx.exception).lower())

    def test_refused_when_container_identity_unknown(self):
        key = "/work/myapp"
        self._write_project(key, {"ctx": {"command": {"argv": ["echo"]}}})
        with mock.patch("mcp.broker.project_key", return_value=None), \
             mock.patch("mcp.broker.project_name", return_value=None):
            with self.assertRaises(BrokerError):
                broker._load_in_scope_spec("ctx", key)


class BrokerSpawnBuildTests(_EnvIsolation, unittest.TestCase):
    """_build_spawn produces (argv, env) without launching, and no secrets."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.cfg_root = os.path.join(self._tmp.name, "boxa", "mcp")
        os.makedirs(self.cfg_root, exist_ok=True)
        # The broker reads secret VALUES from the boxa-mcp-private staged dir,
        # NOT the (node-owned) profile mount. Point it at a separate temp dir.
        self.secrets_dir = os.path.join(self._tmp.name, "staged-secrets")
        os.makedirs(self.secrets_dir, exist_ok=True)
        # API_KEY must not leak in from the test runner's own environment.
        self._set_env(
            XDG_CONFIG_HOME=self._tmp.name,
            BOXA_MCP_SECRETS_DIR=self.secrets_dir,
        )
        self._unset_env("API_KEY")

    def test_build_spawn_global_no_secrets(self):
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {
                    "version": 1,
                    "servers": {
                        "ctx": {
                            "command": {"argv": ["mycmd", "--flag"]},
                            "env": {"BASE_URL": "https://example.test"},
                            "envKeys": ["BASE_URL"],
                            "secretEnvKeys": [],
                        }
                    },
                },
                fh,
            )
        argv, env, _cwd = broker._build_spawn("ctx", None)
        self.assertEqual(argv, ["mycmd", "--flag"])
        self.assertEqual(env["BASE_URL"], "https://example.test")

    def test_build_spawn_redirects_xdg_config_home_off_profile_mount(self):
        # The broker reads the profile via its own XDG_CONFIG_HOME (the node-owned
        # mount). A spawned server, running as boxa-mcp, must NOT inherit that
        # pointer: it cannot write the node-owned mount and must not be aimed at
        # node's config tree. The child env's XDG_CONFIG_HOME must be boxa-mcp's
        # own writable config home (HOME/.config), not the profile mount.
        home = os.path.join(self._tmp.name, "mcp-home")
        os.makedirs(home, exist_ok=True)
        self._set_env(HOME=home)
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {"version": 1, "servers": {"ctx": {"command": {"argv": ["mycmd"]}}}},
                fh,
            )
        _argv, env, _cwd = broker._build_spawn("ctx", None)
        self.assertEqual(env["XDG_CONFIG_HOME"], os.path.join(home, ".config"))
        # And specifically NOT the broker's profile-mount XDG_CONFIG_HOME.
        self.assertNotEqual(env["XDG_CONFIG_HOME"], self._tmp.name)

    def test_build_spawn_strips_broker_control_vars_from_child(self):
        # The child server must not inherit the broker's control-plane pointers:
        # BOXA_MCP_SECRETS_DIR (where the broker reads secret VALUES) and the
        # broker socket path. Broker and spawned servers share the boxa-mcp UID,
        # so a compromised in-scope server that inherited BOXA_MCP_SECRETS_DIR
        # could follow it straight to the staged store and read another scope's
        # secret file. The broker must never volunteer the path.
        self._set_env(**{broker._SOCKET_PATH_ENV: "/run/boxa-bridge/broker.sock"})
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {"version": 1, "servers": {"ctx": {"command": {"argv": ["mycmd"]}}}},
                fh,
            )
        _argv, env, _cwd = broker._build_spawn("ctx", None)
        self.assertNotIn(broker._SECRETS_DIR_ENV, env)
        self.assertNotIn(broker._SOCKET_PATH_ENV, env)

    def test_build_spawn_propagates_docker_env(self):
        # ADR 0014 "Update 2026-05-31": a docker-launcher server must point at the
        # Container's rootless daemon, so DOCKER_HOST + XDG_RUNTIME_DIR (the image
        # ENV the broker inherits) are propagated into the child.
        self._set_env(
            DOCKER_HOST="unix:///run/user/1000/docker.sock",
            XDG_RUNTIME_DIR="/run/user/1000",
        )
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {"version": 1, "servers": {"ctx": {"command": {"argv": ["mycmd"]}}}},
                fh,
            )
        _argv, env, _cwd = broker._build_spawn("ctx", None)
        self.assertEqual(env["DOCKER_HOST"], "unix:///run/user/1000/docker.sock")
        self.assertEqual(env["XDG_RUNTIME_DIR"], "/run/user/1000")

    def test_build_spawn_docker_env_propagation_keeps_issue15_stripping(self):
        # The Docker vars are the ONLY additions: the issue-15 hardening that
        # strips BOXA_MCP_SECRETS_DIR and the broker socket pointer must still
        # hold even with DOCKER_HOST/XDG_RUNTIME_DIR present in the broker env.
        self._set_env(
            DOCKER_HOST="unix:///run/user/1000/docker.sock",
            XDG_RUNTIME_DIR="/run/user/1000",
            **{broker._SOCKET_PATH_ENV: "/run/boxa-bridge/broker.sock"},
        )
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {"version": 1, "servers": {"ctx": {"command": {"argv": ["mycmd"]}}}},
                fh,
            )
        _argv, env, _cwd = broker._build_spawn("ctx", None)
        self.assertNotIn(broker._SECRETS_DIR_ENV, env)
        self.assertNotIn(broker._SOCKET_PATH_ENV, env)
        self.assertEqual(env["DOCKER_HOST"], "unix:///run/user/1000/docker.sock")

    def test_build_spawn_omits_docker_env_when_broker_lacks_it(self):
        # On an image without rootless Docker the broker has no DOCKER_HOST, so a
        # (non-Docker) server is spawned without it rather than with an empty value.
        self._unset_env("DOCKER_HOST", "XDG_RUNTIME_DIR")
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {"version": 1, "servers": {"ctx": {"command": {"argv": ["mycmd"]}}}},
                fh,
            )
        _argv, env, _cwd = broker._build_spawn("ctx", None)
        self.assertNotIn("DOCKER_HOST", env)
        self.assertNotIn("XDG_RUNTIME_DIR", env)

    def test_build_spawn_profile_override_wins_over_redirect(self):
        # An explicit per-server XDG_CONFIG_HOME in the profile must still win
        # over the broker's boxa-mcp default redirect.
        self._set_env(HOME=os.path.join(self._tmp.name, "mcp-home"))
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {
                    "version": 1,
                    "servers": {
                        "ctx": {
                            "command": {"argv": ["mycmd"]},
                            "env": {"XDG_CONFIG_HOME": "/explicit/cfg"},
                            "envKeys": ["XDG_CONFIG_HOME"],
                            "secretEnvKeys": [],
                        }
                    },
                },
                fh,
            )
        _argv, env, _cwd = broker._build_spawn("ctx", None)
        self.assertEqual(env["XDG_CONFIG_HOME"], "/explicit/cfg")

    def test_build_spawn_resolves_secret_from_staged_store(self):
        # A credential-backed server: the broker reads the secret VALUE from the
        # boxa-mcp-PRIVATE staged store (issue 16 stages it there) and overlays
        # it into the spawn env. The value reaches the child env (so the server
        # works) but is never part of any message. We simulate issue-16 staging
        # by writing the secret file into the staged dir under the same basename
        # mcp.secrets uses for the scope.
        from mcp.secrets import (
            global_secrets_path,
            store_server_secrets,
        )

        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {
                    "version": 1,
                    "servers": {
                        "ctx": {
                            "command": {"argv": ["mycmd"]},
                            "envKeys": ["API_KEY"],
                            "secretEnvKeys": ["API_KEY"],
                        }
                    },
                },
                fh,
            )
        secret = "sk-broker-secret-never-logged-987"
        staged = os.path.join(
            self.secrets_dir, os.path.basename(global_secrets_path())
        )
        store_server_secrets(staged, "ctx", {"API_KEY": secret})
        _argv, env, _cwd = broker._build_spawn("ctx", None)
        self.assertEqual(env["API_KEY"], secret)

    def test_build_spawn_ignores_secret_in_profile_mount(self):
        # Defense-in-depth: a secret file present in the (node-owned) PROFILE
        # mount must NOT be read by the broker — only the staged private dir is.
        # A profile-mount secret with the value present should be IGNORED, so the
        # server still reports missing env.
        from mcp.secrets import global_secrets_path, store_server_secrets

        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {
                    "version": 1,
                    "servers": {
                        "ctx": {
                            "command": {"argv": ["mycmd"]},
                            "envKeys": ["API_KEY"],
                            "secretEnvKeys": ["API_KEY"],
                        }
                    },
                },
                fh,
            )
        # Write a secret into the PROFILE-mount store (the path the broker must
        # NOT read). The staged private dir stays empty.
        store_server_secrets(
            global_secrets_path(), "ctx", {"API_KEY": "leaked-from-mount"}
        )
        self._unset_env("API_KEY")
        with self.assertRaises(BrokerError) as ctx:
            broker._build_spawn("ctx", None)
        self.assertIn("API_KEY", str(ctx.exception))
        self.assertNotIn("leaked-from-mount", str(ctx.exception))

    def test_build_spawn_missing_secret_refused_names_only(self):
        # No stored secret: the broker refuses with a NAMES-only message (the
        # in-scope behavior for a secret-declaring server before issue 16).
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {
                    "version": 1,
                    "servers": {
                        "ctx": {
                            "command": {"argv": ["mycmd"]},
                            "envKeys": ["API_KEY"],
                            "secretEnvKeys": ["API_KEY"],
                        }
                    },
                },
                fh,
            )
        self._unset_env("API_KEY")
        with self.assertRaises(BrokerError) as ctx:
            broker._build_spawn("ctx", None)
        self.assertIn("API_KEY", str(ctx.exception))

    def test_absent_staged_secrets_dir_degrades_cleanly(self):
        # The staged-secrets dir may not exist yet (issue 16 creates/populates
        # it). The broker must degrade to "no secret" (a NAMES-only missing-env
        # refusal for a secret-declaring server; a clean spawn for a secret-free
        # one), NEVER raise on the absent directory. Point the broker at a dir
        # that does not exist.
        self._set_env(BOXA_MCP_SECRETS_DIR=os.path.join(self._tmp.name, "absent"))
        # Secret-free server: builds fine despite the absent staged dir.
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {"version": 1, "servers": {"free": {"command": {"argv": ["ok"]}}}},
                fh,
            )
        argv, _env, _cwd = broker._build_spawn("free", None)
        self.assertEqual(argv, ["ok"])
        # Secret-declaring server: clean missing-env refusal, not a crash.
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {
                    "version": 1,
                    "servers": {
                        "needs": {
                            "command": {"argv": ["ok"]},
                            "envKeys": ["TOK"],
                            "secretEnvKeys": ["TOK"],
                        }
                    },
                },
                fh,
            )
        self._unset_env("TOK")
        with self.assertRaises(BrokerError) as ctx:
            broker._build_spawn("needs", None)
        self.assertIn("TOK", str(ctx.exception))

    def test_unreadable_staged_secret_degrades_not_crash(self):
        # A staged secret file the broker cannot read (cross-UID / PermissionError)
        # must degrade to "no secret" (-> missing-env refusal), NEVER an uncaught
        # crash that drops the connection. We simulate by making read_secrets
        # raise PermissionError for the staged file.
        from mcp import secrets as secrets_mod

        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {
                    "version": 1,
                    "servers": {
                        "ctx": {
                            "command": {"argv": ["mycmd"]},
                            "envKeys": ["API_KEY"],
                            "secretEnvKeys": ["API_KEY"],
                        }
                    },
                },
                fh,
            )
        from mcp.secrets import global_secrets_path
        staged = os.path.join(
            self.secrets_dir, os.path.basename(global_secrets_path())
        )
        # Create the file so isfile() is True, then force a PermissionError on
        # the actual read.
        with open(staged, "w") as fh:
            fh.write("{}")

        real_load = secrets_mod.load_secrets

        def boom(path):
            if path == staged:
                raise PermissionError(13, "Permission denied")
            return real_load(path)

        self._unset_env("API_KEY")
        with mock.patch.object(secrets_mod, "load_secrets", side_effect=boom):
            with self.assertRaises(BrokerError) as ctx:
                broker._build_spawn("ctx", None)
        # A clean missing-env refusal, not a traceback.
        self.assertIn("API_KEY", str(ctx.exception))

    def test_build_spawn_uses_relay_supplied_cwd(self):
        # The relay forwards the agent session's cwd; _build_spawn returns it as
        # the spawn cwd so a project-local server resolves relative paths there
        # (not the broker's startup dir).
        sess = os.path.join(self._tmp.name, "session-dir")
        os.makedirs(sess, exist_ok=True)
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {"version": 1, "servers": {"ctx": {"command": {"argv": ["mycmd"]}}}},
                fh,
            )
        _argv, _env, cwd = broker._build_spawn("ctx", None, sess)
        self.assertEqual(cwd, sess)

    def test_build_spawn_falls_back_when_cwd_missing(self):
        # A relay that omits the cwd (older relay) -> None, so Popen keeps the
        # broker's own cwd rather than failing the spawn.
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {"version": 1, "servers": {"ctx": {"command": {"argv": ["mycmd"]}}}},
                fh,
            )
        _argv, _env, cwd = broker._build_spawn("ctx", None, None)
        self.assertIsNone(cwd)

    def test_build_spawn_falls_back_when_cwd_not_a_directory(self):
        # A relay-supplied cwd that does not name a usable directory must NOT
        # fail the spawn — it falls back to None (the broker's own cwd).
        missing = os.path.join(self._tmp.name, "does-not-exist")
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {"version": 1, "servers": {"ctx": {"command": {"argv": ["mycmd"]}}}},
                fh,
            )
        _argv, _env, cwd = broker._build_spawn("ctx", None, missing)
        self.assertIsNone(cwd)

    def test_resolve_spawn_cwd_rejects_file_path(self):
        # A path that exists but is a file, not a directory -> None.
        f = os.path.join(self._tmp.name, "afile")
        with open(f, "w") as fh:
            fh.write("x")
        self.assertIsNone(broker._resolve_spawn_cwd(f))

    def test_resolve_spawn_cwd_accepts_usable_dir(self):
        self.assertEqual(
            broker._resolve_spawn_cwd(self._tmp.name), self._tmp.name
        )


class BrokerSocketRoundTripTests(_EnvIsolation, unittest.TestCase):
    """A real broker over a unix socket, serving a stub server, via the relay."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.cfg_root = os.path.join(self._tmp.name, "boxa", "mcp")
        os.makedirs(self.cfg_root, exist_ok=True)
        # `cat` is a perfect stub MCP server: whatever the agent writes to its
        # stdin comes back on its stdout, exercising the full bidirectional
        # proxy through the socket.
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {
                    "version": 1,
                    "servers": {
                        "echo": {"command": {"argv": ["cat"]}},
                        # `pwd` reports the spawn cwd, so a round trip proves the
                        # broker honored the relay-supplied working directory.
                        "pwd": {"command": {"argv": ["pwd"]}},
                        # A server that starts fine but exits non-zero, so a round
                        # trip proves the broker forwards the real exit status.
                        "fail3": {
                            "command": {"argv": ["sh", "-c", "exit 3"]}
                        },
                        # A server that exits cleanly (0) after closing stdout.
                        "ok0": {"command": {"argv": ["sh", "-c", "exit 0"]}},
                    },
                },
                fh,
            )
        self.sock_path = os.path.join(self._tmp.name, "broker.sock")
        self._set_env(
            XDG_CONFIG_HOME=self._tmp.name,
            BOXA_MCP_BROKER_SOCKET=self.sock_path,
        )

    def _start_broker(self):
        # A stop Event is the only off-main-thread way to halt serve(): the loop
        # checks it each ~1s select cycle. Unlinking the socket file does NOT
        # close the open listening fd, so it cannot stop the loop (an earlier
        # version relied on that and left a spinning daemon thread per test,
        # whose 5s teardown joins compounded into a full-suite timeout).
        self._broker_stop = threading.Event()
        t = threading.Thread(
            target=broker.serve,
            args=(self.sock_path,),
            kwargs={"stop_event": self._broker_stop},
            daemon=True,
        )
        t.start()
        self.addCleanup(self._stop_broker, t)
        # Wait for the bound SOCKET to appear — not merely any file at the path.
        # test_restart_recreates_socket pre-creates a stale REGULAR file here, so
        # a bare os.path.exists() is satisfied immediately by the stale file and
        # returns before the broker has unlinked it and bound the real socket;
        # the caller would then race the unlink->bind window. Polling for
        # S_ISSOCK guarantees the broker is actually listening on return.
        for _ in range(200):
            if _is_socket(self.sock_path):
                break
            time.sleep(0.01)
        self.assertTrue(_is_socket(self.sock_path), "broker socket never appeared")
        return t

    def _stop_broker(self, thread):
        # Signal the accept loop to exit, then join so the daemon thread is fully
        # down before the next test (deterministic teardown, no fd leak, no
        # spinning zombie listener). serve()'s finally-clause unlinks the socket.
        self._broker_stop.set()
        thread.join(timeout=5)

    def test_socket_perms_not_world_accessible(self):
        self._start_broker()
        mode = os.stat(self.sock_path).st_mode & 0o777
        # 0660: owner+group rw, no world access.
        self.assertEqual(mode, 0o660, oct(mode))

    def test_accept_and_proxy_echo(self):
        self._start_broker()
        # Talk to the broker directly with the protocol the relay uses.
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(self.sock_path)
        client.sendall(protocol.encode_request("echo", None))
        ok, err = protocol.decode_reply(protocol.read_line(client.recv))
        self.assertTrue(ok, err)
        payload = b"hello mcp stream\n"
        client.sendall(payload)
        client.shutdown(socket.SHUT_WR)
        got = self._drain(client)
        client.close()
        # The stream is now followed by the NUL-prefixed exit trailer; the
        # genuine MCP stdout is everything before the first NUL.
        self.assertEqual(got[: got.find(protocol.EXIT_TRAILER_SENTINEL)], payload)

    def test_spawn_uses_relay_supplied_cwd_over_socket(self):
        # End-to-end: a server spawned by the broker must run in the cwd the
        # relay forwarded in the handshake (issue 15 spawn-cwd fix), not the
        # broker's own startup dir.
        sess = os.path.join(self._tmp.name, "session-dir")
        os.makedirs(sess, exist_ok=True)
        # realpath: macOS/temp dirs may be symlinked; pwd reports the real path.
        expected = os.path.realpath(sess)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._start_broker()
        client.connect(self.sock_path)
        client.sendall(protocol.encode_request("pwd", None, sess))
        ok, err = protocol.decode_reply(protocol.read_line(client.recv))
        self.assertTrue(ok, err)
        client.shutdown(socket.SHUT_WR)
        got = self._drain(client)
        client.close()
        # Strip the trailing NUL-prefixed exit trailer; the pwd output is before.
        stdout = got[: got.find(protocol.EXIT_TRAILER_SENTINEL)]
        self.assertEqual(stdout.decode().strip(), expected)

    def _drain(self, client):
        """Read everything the broker sends until EOF (its SHUT_WR)."""
        client.settimeout(5)
        got = b""
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            got += chunk
        return got

    def test_exit_trailer_carries_nonzero_status_over_socket(self):
        # A server that starts then exits non-zero must reach the relay as a
        # NUL-prefixed exit trailer carrying that status (the P2 regression: the
        # old broker/relay split reported every exit as clean).
        self._start_broker()
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(self.sock_path)
        client.sendall(protocol.encode_request("fail3", None))
        ok, err = protocol.decode_reply(protocol.read_line(client.recv))
        self.assertTrue(ok, err)
        client.shutdown(socket.SHUT_WR)
        got = self._drain(client)
        client.close()
        # No raw MCP stdout from this server, so the whole stream is the trailer.
        nul = got.find(protocol.EXIT_TRAILER_SENTINEL)
        self.assertNotEqual(nul, -1, "no exit trailer sentinel sent")
        self.assertEqual(protocol.decode_exit(got[nul + 1 :]), 3)

    def test_exit_trailer_carries_zero_status_over_socket(self):
        self._start_broker()
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(self.sock_path)
        client.sendall(protocol.encode_request("ok0", None))
        ok, err = protocol.decode_reply(protocol.read_line(client.recv))
        self.assertTrue(ok, err)
        client.shutdown(socket.SHUT_WR)
        got = self._drain(client)
        client.close()
        nul = got.find(protocol.EXIT_TRAILER_SENTINEL)
        self.assertNotEqual(nul, -1, "no exit trailer sentinel sent")
        self.assertEqual(protocol.decode_exit(got[nul + 1 :]), 0)

    def test_exit_trailer_follows_echoed_stream(self):
        # The trailer must come AFTER all genuine MCP stdout, separated by the
        # NUL sentinel: bytes before the NUL are the echoed payload, the rest is
        # the trailer. Proves the trailer never interleaves with raw output.
        self._start_broker()
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(self.sock_path)
        client.sendall(protocol.encode_request("echo", None))
        ok, err = protocol.decode_reply(protocol.read_line(client.recv))
        self.assertTrue(ok, err)
        payload = b"hello mcp stream\n"
        client.sendall(payload)
        client.shutdown(socket.SHUT_WR)
        got = self._drain(client)
        client.close()
        nul = got.find(protocol.EXIT_TRAILER_SENTINEL)
        self.assertNotEqual(nul, -1, "no exit trailer sentinel sent")
        self.assertEqual(got[:nul], payload)
        self.assertEqual(protocol.decode_exit(got[nul + 1 :]), 0)

    def test_refuse_out_of_scope_over_socket(self):
        self._start_broker()
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(self.sock_path)
        client.sendall(protocol.encode_request("nope", None))
        ok, err = protocol.decode_reply(protocol.read_line(client.recv))
        self.assertFalse(ok)
        self.assertIn("nope", err)
        client.close()

    def test_bad_handshake_refused_over_socket(self):
        self._start_broker()
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(self.sock_path)
        client.sendall(b"garbage-not-json\n")
        ok, err = protocol.decode_reply(protocol.read_line(client.recv))
        self.assertFalse(ok)
        self.assertIn("handshake", err.lower())
        client.close()

    def test_silent_client_dropped_after_handshake_deadline(self):
        # Slowloris guard: a client that connects but never sends a handshake must
        # be dropped after the deadline, not pin the handler thread + fd forever.
        with mock.patch.object(broker, "_HANDSHAKE_TIMEOUT_SECONDS", 0.3):
            self._start_broker()
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.addCleanup(client.close)
            client.connect(self.sock_path)
            # Send nothing. The broker must close its end (EOF) within ~deadline.
            client.settimeout(5)
            self.assertEqual(
                client.recv(64), b"", "broker did not drop the silent client"
            )

    def test_restart_recreates_socket(self):
        # A stale socket file from a prior run must not block a restart.
        with open(self.sock_path, "w") as fh:
            fh.write("")  # stale non-socket file at the path
        self._start_broker()  # must remove the stale file and bind cleanly
        self.assertTrue(os.path.exists(self.sock_path))


class RelayExitStatusOverBrokerTests(_EnvIsolation, unittest.TestCase):
    """End-to-end: relay.run() against a REAL broker reflects the server's exit.

    This exercises the full chain over the socket — broker spawns the server,
    server exits, broker sends the NUL-prefixed exit trailer, relay decodes it
    and returns it as its own exit code — rather than mocking any leg, so it
    proves the actual status propagation the P2 finding asked for.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.cfg_root = os.path.join(self._tmp.name, "boxa", "mcp")
        os.makedirs(self.cfg_root, exist_ok=True)
        with open(os.path.join(self.cfg_root, "profile.json"), "w") as fh:
            json.dump(
                {
                    "version": 1,
                    "servers": {
                        "fail3": {"command": {"argv": ["sh", "-c", "exit 3"]}},
                        "ok0": {"command": {"argv": ["sh", "-c", "exit 0"]}},
                        "echo": {"command": {"argv": ["cat"]}},
                    },
                },
                fh,
            )
        self.sock_path = os.path.join(self._tmp.name, "broker.sock")
        # A Container identity file so the relay's require_container() passes.
        ident = os.path.join(self._tmp.name, "identity.json")
        with open(ident, "w", encoding="utf-8") as fh:
            fh.write('{"project":"p"}')
        self._set_env(
            XDG_CONFIG_HOME=self._tmp.name,
            BOXA_MCP_BROKER_SOCKET=self.sock_path,
            BOXA_MCP_IDENTITY_PATH=ident,
        )

    def _start_broker(self):
        self._broker_stop = threading.Event()
        t = threading.Thread(
            target=broker.serve,
            args=(self.sock_path,),
            kwargs={"stop_event": self._broker_stop},
            daemon=True,
        )
        t.start()
        self.addCleanup(self._stop_broker, t)
        for _ in range(200):
            if _is_socket(self.sock_path):
                break
            time.sleep(0.01)
        self.assertTrue(_is_socket(self.sock_path), "broker socket never appeared")

    def _stop_broker(self, thread):
        self._broker_stop.set()
        thread.join(timeout=5)

    def _run_relay(self, server, stdin_payload=b""):
        """Run relay.run(server) with a controlled stdin/stdout, return rc."""
        from mcp import relay

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
        os.write(stdin_w, stdin_payload)
        os.close(stdin_w)  # EOF: relay half-closes, server sees EOF and exits
        open_fds.discard(stdin_w)

        with mock.patch.object(sys, "stdin") as fake_in, mock.patch.object(
            sys, "stdout"
        ) as fake_out:
            fake_in.fileno.return_value = stdin_r
            fake_out.fileno.return_value = stdout_w
            rc = relay.run(server)
        return rc

    def test_relay_returns_nonzero_server_exit(self):
        self._start_broker()
        rc = self._run_relay("fail3")
        self.assertEqual(rc, 3)

    def test_relay_returns_zero_on_clean_server_exit(self):
        self._start_broker()
        rc = self._run_relay("ok0")
        self.assertEqual(rc, 0)

    def test_relay_returns_zero_on_clean_echo_session(self):
        # A normal session with real MCP-like stdout still ends at 0; the trailer
        # is separated from the echoed bytes by the NUL sentinel.
        self._start_broker()
        rc = self._run_relay("echo", stdin_payload=b"frame-1\nframe-2\n")
        self.assertEqual(rc, 0)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
