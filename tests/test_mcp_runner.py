#!/usr/bin/env python3
"""Tests for the boxa-mcp-run runner core (issue 07; reworked ADR 0014).

Run with:

    python3 -m unittest tests.test_mcp_runner   # from repo root
    python3 tests/test_mcp_runner.py            # standalone

ADR 0014 changed ``runner.run`` from "exec the MCP server in-process (as node)"
to "relay stdio to the broker, which spawns the server as boxa-mcp". So:

  * ``run`` no longer execs anything; it delegates to ``mcp.relay.run`` and
    wraps a RelayError as a RunnerError. The host gate still applies (via the
    relay) and the broker-unreachable path yields a clean RunnerError.
  * the profile/spec/env RESOLUTION helpers (``_load_server_spec``,
    ``_server_argv``, ``_resolve_env``, ``_resolve_paths``) remain in
    ``mcp.runner`` and are now invoked BROKER-side; they are still unit-tested
    here directly (resolution correctness, missing-env names-only, secret value
    resolved-but-never-logged), since the credential-isolation guarantees about
    these messages are load-bearing.

Every test points HOME / XDG_CONFIG_HOME at a fresh tempdir so the real
~/.config/boxa profile and secret store are never read, and injects a fake
Container identity file via BOXA_MCP_IDENTITY_PATH so /etc/boxa is never
touched.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from unittest import mock

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp import identity as identity_mod  # noqa: E402
from mcp.identity import NotInsideContainerError, require_container  # noqa: E402
from mcp.profile import (  # noqa: E402
    global_profile_path,
    project_profile_path,
)
from mcp.runner import (  # noqa: E402
    RunnerError,
    _load_server_spec,
    _resolve_env,
    _resolve_paths,
    _server_argv,
    run as runner_run,
)
from mcp.secrets import (  # noqa: E402
    global_secrets_path,
    project_secrets_path,
    store_server_secrets,
)

# A realistic-looking secret VALUE that must NEVER appear in any output.
_SECRET_VALUE = "sk-ant-super-secret-do-not-leak-0123456789"
_PROJECT_KEY = "/home/tester/Projekty/DemoApp"


class RunnerEnv(unittest.TestCase):
    """Base class isolating HOME / XDG_CONFIG_HOME and the identity path."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self._saved = {}
        for var in (
            "HOME",
            "XDG_CONFIG_HOME",
            "BOXA_MCP_BROKER_SOCKET",
            identity_mod._IDENTITY_PATH_ENV,  # noqa: SLF001
        ):
            self._saved[var] = os.environ.get(var)
        os.environ["HOME"] = self.home
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.home, ".config")
        # Default: behave as if we ARE inside a Container (identity file present)
        # so tests of resolution/env do not trip the host gate. Tests of the gate
        # itself drop or repoint this.
        self.identity_file = os.path.join(self.home, "identity.json")
        with open(self.identity_file, "w", encoding="utf-8") as fh:
            json.dump({"project": "DemoApp"}, fh)
        os.environ[identity_mod._IDENTITY_PATH_ENV] = self.identity_file  # noqa: SLF001
        # Point the relay at a socket that does not exist, so any accidental
        # broker connection fails fast and visibly rather than hanging.
        os.environ["BOXA_MCP_BROKER_SOCKET"] = os.path.join(
            self.home, "no-broker.sock"
        )

    def tearDown(self) -> None:
        for var, val in self._saved.items():
            if val is None:
                os.environ.pop(var, None)
            else:
                os.environ[var] = val
        self._tmp.cleanup()

    # -- fixtures -----------------------------------------------------------

    def _server_spec(self, name: str, *, argv=None, env_keys=None,
                     secret_keys=None, enabled=None) -> dict:
        spec: dict = {
            "name": name,
            "type": "stdio",
            "command": {"argv": argv or ["npx", "-y", f"@example/{name}@latest"]},
            "envKeys": list(env_keys or []),
            "secretEnvKeys": list(secret_keys or []),
            "source": {"provider": "claude-code", "importId": f"imp-{name}"},
        }
        if enabled is not None:
            spec["enabled"] = enabled
        return spec

    def _write_global_profile(self, servers: dict) -> None:
        path = global_profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "servers": servers}, fh)

    def _write_project_profile(self, project_key: str, servers: dict) -> None:
        path = project_profile_path(project_key)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "servers": servers}, fh)


class IdentityGateTest(RunnerEnv):
    def test_inside_container_when_identity_present(self) -> None:
        require_container()  # must not raise

    def test_missing_identity_refuses(self) -> None:
        os.remove(self.identity_file)
        with self.assertRaises(NotInsideContainerError) as ctx:
            require_container()
        msg = str(ctx.exception)
        self.assertIn("Container", msg)
        self.assertIn(self.identity_file, msg)

    def test_run_refuses_on_host_before_touching_broker(self) -> None:
        # No identity file => host. run() must fail at the relay's gate and never
        # attempt a broker connection.
        os.remove(self.identity_file)
        self._write_global_profile({"context7": self._server_spec("context7")})
        import mcp.relay as relay_mod

        with mock.patch.object(relay_mod, "_connect") as connect_mock:
            with self.assertRaises(Exception):
                runner_run("context7")
        connect_mock.assert_not_called()


class DelegationTest(RunnerEnv):
    """run() delegates to the relay and wraps RelayError as RunnerError."""

    def test_delegates_to_relay(self) -> None:
        import mcp.relay as relay_mod

        with mock.patch.object(relay_mod, "run", return_value=0) as relay_run:
            rc = runner_run("context7", project_key=_PROJECT_KEY)
        self.assertEqual(rc, 0)
        relay_run.assert_called_once_with("context7", project_key=_PROJECT_KEY)

    def test_relay_error_wrapped_as_runner_error(self) -> None:
        import mcp.relay as relay_mod

        with mock.patch.object(
            relay_mod, "run", side_effect=relay_mod.RelayError("broker refused x")
        ):
            with self.assertRaises(RunnerError) as ctx:
                runner_run("context7")
        self.assertIn("broker refused x", str(ctx.exception))

    def test_broker_unreachable_is_clean_runner_error(self) -> None:
        # No broker socket exists (setUp points at a missing path); the real
        # relay must surface a clean, actionable RunnerError, not a traceback.
        with self.assertRaises(RunnerError) as ctx:
            runner_run("context7")
        self.assertIn("broker", str(ctx.exception).lower())


class ResolveHelperTest(RunnerEnv):
    """The retained resolution helpers (now invoked broker-side)."""

    def test_resolve_paths_global_vs_project(self) -> None:
        gp, gs, gl = _resolve_paths(None)
        self.assertEqual(gl, "global")
        self.assertEqual(gp, global_profile_path())
        self.assertEqual(gs, global_secrets_path())
        pp, ps, pl = _resolve_paths(_PROJECT_KEY)
        self.assertIn("project", pl)
        self.assertEqual(pp, project_profile_path(_PROJECT_KEY))
        self.assertEqual(ps, project_secrets_path(_PROJECT_KEY))

    def test_load_server_spec_global(self) -> None:
        self._write_global_profile(
            {"context7": self._server_spec(
                "context7", argv=["npx", "-y", "@upstash/context7-mcp@latest"]
            )}
        )
        spec = _load_server_spec(global_profile_path(), "context7", "global")
        self.assertEqual(
            _server_argv(spec, "context7"),
            ["npx", "-y", "@upstash/context7-mcp@latest"],
        )

    def test_missing_server_is_clear(self) -> None:
        self._write_global_profile({"context7": self._server_spec("context7")})
        with self.assertRaises(RunnerError) as ctx:
            _load_server_spec(global_profile_path(), "nope", "global")
        msg = str(ctx.exception)
        self.assertIn("nope", msg)
        self.assertIn("context7", msg)  # known servers hinted

    def test_disabled_server_is_clear(self) -> None:
        self._write_global_profile(
            {"context7": self._server_spec("context7", enabled=False)}
        )
        with self.assertRaises(RunnerError) as ctx:
            _load_server_spec(global_profile_path(), "context7", "global")
        self.assertIn("disabled", str(ctx.exception))

    def test_malformed_profile_is_clear(self) -> None:
        path = global_profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("{ this is not valid json")
        with self.assertRaises(RunnerError) as ctx:
            _load_server_spec(path, "context7", "global")
        self.assertIn("profile", str(ctx.exception).lower())

    def test_missing_command_argv_is_clear(self) -> None:
        spec = self._server_spec("context7")
        spec["command"] = {}  # no argv
        with self.assertRaises(RunnerError) as ctx:
            _server_argv(spec, "context7")
        self.assertIn("command", str(ctx.exception).lower())


class EnvResolveTest(RunnerEnv):
    """_resolve_env: every name resolves, secrets resolved-but-never-logged."""

    def test_missing_required_env_lists_names_only(self) -> None:
        spec = self._server_spec(
            "context7", env_keys=["CONTEXT7_API_KEY"],
            secret_keys=["CONTEXT7_API_KEY"],
        )
        with self.assertRaises(RunnerError) as ctx:
            _resolve_env(spec, global_secrets_path(), "context7")
        msg = str(ctx.exception)
        self.assertIn("CONTEXT7_API_KEY", msg)
        self.assertNotIn(_SECRET_VALUE, msg)

    def test_secret_value_resolved_from_store_never_logged(self) -> None:
        spec = self._server_spec(
            "context7", env_keys=["CONTEXT7_API_KEY"],
            secret_keys=["CONTEXT7_API_KEY"],
        )
        store_server_secrets(
            global_secrets_path(), "context7",
            {"CONTEXT7_API_KEY": _SECRET_VALUE},
        )
        overlay = _resolve_env(spec, global_secrets_path(), "context7")
        # The value IS resolved into the overlay (it goes to the spawned server),
        # but it is never part of any RunnerError message.
        self.assertEqual(overlay["CONTEXT7_API_KEY"], _SECRET_VALUE)

    def test_non_secret_env_resolved_from_profile_env(self) -> None:
        spec = self._server_spec("context7", env_keys=["BASE_URL"])
        spec["env"] = {"BASE_URL": "https://example.test"}
        overlay = _resolve_env(spec, global_secrets_path(), "context7")
        self.assertEqual(overlay["BASE_URL"], "https://example.test")

    def test_project_secret_resolved_from_project_store(self) -> None:
        spec = self._server_spec(
            "local-tool", env_keys=["TOOL_TOKEN"], secret_keys=["TOOL_TOKEN"],
        )
        store_server_secrets(
            project_secrets_path(_PROJECT_KEY), "local-tool",
            {"TOOL_TOKEN": _SECRET_VALUE},
        )
        overlay = _resolve_env(
            spec, project_secrets_path(_PROJECT_KEY), "local-tool"
        )
        self.assertEqual(overlay["TOOL_TOKEN"], _SECRET_VALUE)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
