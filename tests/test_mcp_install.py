#!/usr/bin/env python3
"""Tests for the MCP install/materialize core (issue 09).

Run with:

    python3 -m unittest tests.test_mcp_install   # from repo root
    PYTHONPATH=scripts python3 -m unittest tests.test_mcp_install

Every test points HOME / XDG_CONFIG_HOME at a fresh tempdir so the real
~/.config/boxa profile is never read or written, and injects a stub subprocess
runner so NO real npm/docker command ever runs and the live network is never
touched. The Allow-for window orchestration / container targeting is HOST-side
(scripts/mcp-cli.sh) and cannot run inside this Container, so it is covered by
shellcheck + the issue report rather than by these unit tests.

Covers the issue-09 acceptance criteria the Python core owns:
  * install refuses unknown, disabled, host-only-classified, and command-less
    (override) servers with clear messages;
  * npm/npx materialization installs into npm-global and rewrites the profile
    command to the resolved binary, marking the entry materialized;
  * a bare-node launcher needs no materialization (already local);
  * Docker-backed servers pull the image and stay Project-scoped without
    rewriting the launch command;
  * Python/uv reports that a dedicated MCP runtime volume is needed;
  * a blocked-network failure raises a BlockedNetworkError carrying the exact
    rerun command and pointing at 'boxa blocked';
  * a project install writes the Project profile; a global install the global.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp import install as inst  # noqa: E402
from mcp.install import (  # noqa: E402
    BlockedNetworkError,
    Executor,
    InstallError,
    RunResult,
    UnsupportedRuntimeError,
    install_server,
)
from mcp.profile import (  # noqa: E402
    global_profile_path,
    load_profile,
    project_profile_path,
)

_PROJECT_KEY = "/home/tester/Projekty/DemoApp"


def _server(argv, *, enabled=True, placement=None, command=True,
            env_keys=None, secret_env_keys=None):
    spec = {
        "name": "x",
        "type": "stdio",
        "envKeys": list(env_keys or []),
        "secretEnvKeys": list(secret_env_keys or []),
        "source": {"provider": "claude-code", "importId": "imp-aaa"},
    }
    if command:
        spec["command"] = {"argv": list(argv)}
    if not enabled:
        spec["enabled"] = False
    if placement is not None:
        spec["placement"] = placement
    return spec


class _StubExecutor(Executor):
    """Records run commands and resolves binaries from a map (no real subprocess).

    Subclasses ``Executor`` so the real ``run``/``which`` (which would shell out
    and depend on a live npm/docker + network) are never reached. ``script`` maps
    a matched substring of the joined argv to a RunResult; the first matching key
    wins, else a default success is returned. ``which_map`` maps a binary NAME to
    its resolved path (or absent => not on PATH). ``calls`` keeps every run argv.
    """

    def __init__(self, script=None, which_map=None, default_rc=0,
                 default_output=""):
        super().__init__([])
        self.script = script or {}
        self.which_map = which_map if which_map is not None else {
            "npm": "/usr/local/bin/npm",
            "docker": "/usr/local/bin/docker",
        }
        self.default_rc = default_rc
        self.default_output = default_output
        self.calls: list[list[str]] = []

    def run(self, argv: list[str]) -> RunResult:
        self.calls.append(list(argv))
        joined = " ".join(argv)
        for needle, result in self.script.items():
            if needle in joined:
                return result
        return RunResult(self.default_rc, self.default_output)

    def which(self, name: str):
        return self.which_map.get(name)


class InstallEnv(unittest.TestCase):
    """Base class isolating HOME / XDG_CONFIG_HOME."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self._saved = {}
        for var in ("HOME", "XDG_CONFIG_HOME"):
            self._saved[var] = os.environ.get(var)
        os.environ["HOME"] = self.home
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.home, ".config")
        # Default which map for executors built fresh in a test.
        self._which_map = {
            "npm": "/usr/local/bin/npm",
            "docker": "/usr/local/bin/docker",
        }

    def _executor(self, script=None):
        """A stub executor seeded with this test's which_map (mutable per test)."""
        return _StubExecutor(script=script, which_map=self._which_map)

    def tearDown(self) -> None:
        for var, val in self._saved.items():
            if val is None:
                os.environ.pop(var, None)
            else:
                os.environ[var] = val
        self._tmp.cleanup()

    # -- fixtures -----------------------------------------------------------

    def _write_global(self, servers: dict) -> str:
        path = global_profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "servers": servers}, fh)
        return path

    def _write_project(self, project_key: str, servers: dict) -> str:
        path = project_profile_path(project_key)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(
                {"version": 1, "projectKey": project_key, "servers": servers},
                fh,
            )
        return path


# -- refusals -----------------------------------------------------------------


class RefusalTests(InstallEnv):
    def test_unknown_server(self) -> None:
        self._write_global({"context7": _server(["npx", "-y", "ctx"])})
        with self.assertRaises(InstallError) as cm:
            install_server("nope", "global", None, executor=self._executor())
        self.assertIn("no boxa MCP server named 'nope'", str(cm.exception))

    def test_disabled_server(self) -> None:
        self._write_global(
            {"context7": _server(["npx", "-y", "ctx"], enabled=False)}
        )
        with self.assertRaises(InstallError) as cm:
            install_server("context7", "global", None, executor=self._executor())
        self.assertIn("disabled", str(cm.exception))

    def test_host_only_placement_refused(self) -> None:
        self._write_global(
            {"hostly": _server(["npx", "-y", "h"], placement="host-only")}
        )
        with self.assertRaises(InstallError) as cm:
            install_server("hostly", "global", None, executor=self._executor())
        self.assertIn("host-only", str(cm.exception))

    def test_command_less_override_refused(self) -> None:
        # A project disable-override has no command of its own.
        self._write_project(
            _PROJECT_KEY, {"context7": _server([], command=False, enabled=False)}
        )
        with self.assertRaises(InstallError) as cm:
            install_server("context7", "project", _PROJECT_KEY,
                           executor=self._executor())
        self.assertIn("disabled", str(cm.exception))

    def test_project_scope_requires_key(self) -> None:
        with self.assertRaises(InstallError):
            install_server("x", "project", None, executor=self._executor())


# -- npm / npx ----------------------------------------------------------------


class NpmInstallTests(InstallEnv):
    def test_npx_materializes_to_resolved_binary(self) -> None:
        self._write_global(
            {"context7": _server(["npx", "-y", "@upstash/context7-mcp@latest"])}
        )
        # The package's binary resolves on PATH after install.
        self._which_map["context7-mcp"] = "/npm-global/bin/context7-mcp"
        executor = self._executor()
        result = install_server("context7", "global", None, executor=executor)

        self.assertTrue(result.materialized)
        self.assertFalse(result.already_materialized)
        self.assertEqual(result.runtime, "node")
        # npm install -g was run with the full package spec.
        self.assertIn(
            ["npm", "install", "-g", "@upstash/context7-mcp@latest"],
            executor.calls,
        )
        # The profile command was rewritten to the resolved binary.
        profile = load_profile(global_profile_path())
        argv = profile["servers"]["context7"]["command"]["argv"]
        self.assertEqual(argv, ["/npm-global/bin/context7-mcp"])
        self.assertTrue(profile["servers"]["context7"]["materialized"])

    def test_npx_preserves_trailing_args(self) -> None:
        self._write_global(
            {"srv": _server(["npx", "-y", "some-mcp@1.2.3", "--port", "9000"])}
        )
        self._which_map["some-mcp"] = "/npm-global/bin/some-mcp"
        result = install_server("srv", "global", None, executor=self._executor())
        self.assertTrue(result.materialized)
        argv = load_profile(global_profile_path())["servers"]["srv"]["command"]["argv"]
        self.assertEqual(argv, ["/npm-global/bin/some-mcp", "--port", "9000"])

    def test_npx_binary_not_found_keeps_command(self) -> None:
        self._write_global({"srv": _server(["npx", "-y", "weird-pkg@1"])})
        # weird-pkg installs but its binary is not weird-pkg; not on PATH.
        with self.assertRaises(InstallError) as cm:
            install_server("srv", "global", None, executor=self._executor())
        self.assertIn("could not find its executable", str(cm.exception))
        # Profile command left UNCHANGED (still launchable via npx).
        argv = load_profile(global_profile_path())["servers"]["srv"]["command"]["argv"]
        self.assertEqual(argv, ["npx", "-y", "weird-pkg@1"])

    def test_npx_explicit_package_uses_named_binary(self) -> None:
        # ``npx -p pkg server-bin``: install pkg, launch server-bin (not pkg).
        self._write_global(
            {"srv": _server(["npx", "-y", "-p", "tool-pkg@1", "server-bin", "--x"])}
        )
        self._which_map["server-bin"] = "/npm-global/bin/server-bin"
        result = install_server("srv", "global", None, executor=self._executor())
        self.assertTrue(result.materialized)
        argv = load_profile(global_profile_path())["servers"]["srv"]["command"]["argv"]
        self.assertEqual(argv, ["/npm-global/bin/server-bin", "--x"])

    def test_bare_node_already_materialized(self) -> None:
        self._write_global({"local": _server(["node", "/opt/server.js"])})
        result = install_server("local", "global", None, executor=self._executor())
        self.assertTrue(result.already_materialized)
        self.assertTrue(result.materialized)
        # No install command was run; command unchanged.
        argv = load_profile(global_profile_path())["servers"]["local"]["command"]["argv"]
        self.assertEqual(argv, ["node", "/opt/server.js"])

    def test_pnpm_dlx_not_falsely_materialized(self) -> None:
        # A fetch-on-launch dlx form must be refused, not marked materialized.
        self._write_global({"srv": _server(["pnpm", "dlx", "some-mcp"])})
        with self.assertRaises(UnsupportedRuntimeError) as cm:
            install_server("srv", "global", None, executor=self._executor())
        self.assertIn("fetch-on-launch", str(cm.exception))
        spec = load_profile(global_profile_path())["servers"]["srv"]
        self.assertNotIn("materialized", spec)

    def test_npm_exec_not_falsely_materialized(self) -> None:
        self._write_global({"srv": _server(["npm", "exec", "some-mcp"])})
        with self.assertRaises(UnsupportedRuntimeError):
            install_server("srv", "global", None, executor=self._executor())

    def test_npm_missing_is_unsupported(self) -> None:
        self._write_global({"srv": _server(["npx", "-y", "pkg"])})
        self._which_map.pop("npm", None)
        with self.assertRaises(UnsupportedRuntimeError) as cm:
            install_server("srv", "global", None, executor=self._executor())
        self.assertIn("npm is not available", str(cm.exception))

    def test_project_scope_writes_project_profile(self) -> None:
        self._write_project(
            _PROJECT_KEY, {"context7": _server(["npx", "-y", "context7-mcp"])}
        )
        self._which_map["context7-mcp"] = "/npm-global/bin/context7-mcp"
        result = install_server("context7", "project", _PROJECT_KEY,
                                executor=self._executor())
        self.assertEqual(result.scope, "project")
        self.assertEqual(result.project_key, _PROJECT_KEY)
        argv = load_profile(
            project_profile_path(_PROJECT_KEY)
        )["servers"]["context7"]["command"]["argv"]
        self.assertEqual(argv, ["/npm-global/bin/context7-mcp"])
        # Global profile untouched.
        self.assertFalse(os.path.isfile(global_profile_path()))


# -- docker -------------------------------------------------------------------


class DockerInstallTests(InstallEnv):
    def test_docker_pulls_and_keeps_command(self) -> None:
        argv = ["docker", "run", "-i", "--rm", "-e", "FOO",
                "ghcr.io/org/img:tag", "mcp"]
        self._write_project(_PROJECT_KEY, {"img": _server(argv)})
        executor = self._executor()
        result = install_server("img", "project", _PROJECT_KEY, executor=executor)
        self.assertTrue(result.materialized)
        self.assertEqual(result.runtime, "docker")
        self.assertIn(["docker", "pull", "ghcr.io/org/img:tag"], executor.calls)
        # Launch command unchanged (docker run already references local image).
        stored = load_profile(
            project_profile_path(_PROJECT_KEY)
        )["servers"]["img"]["command"]["argv"]
        self.assertEqual(stored, argv)
        self.assertTrue(
            load_profile(project_profile_path(_PROJECT_KEY))["servers"]["img"][
                "materialized"
            ]
        )

    def test_docker_no_image_errors(self) -> None:
        # Use a PROJECT install: a global Docker install is refused earlier (image
        # state is Project-scoped), so image parsing is only reached per project.
        self._write_project(_PROJECT_KEY, {"bad": _server(["docker", "run", "-i", "--rm"])})
        with self.assertRaises(InstallError) as cm:
            install_server("bad", "project", _PROJECT_KEY,
                           executor=self._executor())
        self.assertIn("could not determine the container image", str(cm.exception))

    def test_podman_pulls_with_podman(self) -> None:
        argv = ["podman", "run", "--rm", "quay.io/org/img:tag"]
        self._write_project(_PROJECT_KEY, {"img": _server(argv)})
        self._which_map["podman"] = "/usr/bin/podman"
        executor = self._executor()
        result = install_server("img", "project", _PROJECT_KEY, executor=executor)
        self.assertTrue(result.materialized)
        # Pulled with PODMAN, not docker.
        self.assertIn(["podman", "pull", "quay.io/org/img:tag"], executor.calls)

    def test_docker_global_refused(self) -> None:
        self._write_global(
            {"img": _server(["docker", "run", "--rm", "ghcr.io/o/i:tag"])}
        )
        with self.assertRaises(UnsupportedRuntimeError) as cm:
            install_server("img", "global", None, executor=self._executor())
        self.assertIn("Project-scoped", str(cm.exception))


# -- python / uv --------------------------------------------------------------


class PythonRuntimeTests(InstallEnv):
    def test_uvx_reports_dedicated_volume_needed(self) -> None:
        self._write_global({"fetch": _server(["uvx", "mcp-server-fetch"])})
        with self.assertRaises(UnsupportedRuntimeError) as cm:
            install_server("fetch", "global", None, executor=self._executor())
        msg = str(cm.exception)
        self.assertIn("dedicated MCP runtime volume", msg)
        # Profile NOT marked materialized — nothing changed.
        spec = load_profile(global_profile_path())["servers"]["fetch"]
        self.assertNotIn("materialized", spec)

    def test_unknown_runtime_unsupported(self) -> None:
        self._write_global({"weird": _server(["/usr/bin/weird-launcher", "go"])})
        with self.assertRaises(UnsupportedRuntimeError):
            install_server("weird", "global", None, executor=self._executor())


# -- blocked network ----------------------------------------------------------


class BlockedNetworkTests(InstallEnv):
    def test_npm_blocked_points_at_boxa_blocked(self) -> None:
        self._write_global({"srv": _server(["npx", "-y", "pkg"])})
        executor = self._executor(
            script={
                "npm install": RunResult(
                    1,
                    "npm error code ENOTFOUND\n"
                    "npm error request to https://registry.npmjs.org/pkg failed, "
                    "reason: getaddrinfo ENOTFOUND registry.npmjs.org",
                )
            }
        )
        with self.assertRaises(BlockedNetworkError) as cm:
            install_server("srv", "global", None, executor=executor)
        exc = cm.exception
        self.assertIn("boxa blocked", str(exc))
        self.assertEqual(exc.rerun_command, "boxa mcp install srv --global")
        self.assertIn("--allow-for 15", str(exc))
        # The profile was NOT rewritten / marked materialized on failure.
        spec = load_profile(global_profile_path())["servers"]["srv"]
        self.assertNotIn("materialized", spec)
        self.assertEqual(spec["command"]["argv"], ["npx", "-y", "pkg"])

    def test_project_blocked_rerun_carries_project(self) -> None:
        self._write_project(_PROJECT_KEY, {"srv": _server(["npx", "-y", "pkg"])})
        executor = self._executor(
            script={"npm install": RunResult(1, "fetch failed: ETIMEDOUT")}
        )
        with self.assertRaises(BlockedNetworkError) as cm:
            install_server("srv", "project", _PROJECT_KEY, executor=executor)
        self.assertEqual(
            cm.exception.rerun_command,
            f"boxa mcp install srv --project {_PROJECT_KEY}",
        )

    def test_generic_failure_is_install_error_not_blocked(self) -> None:
        self._write_global({"srv": _server(["npx", "-y", "pkg"])})
        executor = self._executor(
            script={"npm install": RunResult(1, "EACCES: permission denied")}
        )
        with self.assertRaises(InstallError) as cm:
            install_server("srv", "global", None, executor=executor)
        self.assertNotIsInstance(cm.exception, BlockedNetworkError)
        self.assertIn("permission denied", str(cm.exception))

    def test_docker_blocked_detected(self) -> None:
        argv = ["docker", "run", "--rm", "ghcr.io/org/img:tag"]
        self._write_project(_PROJECT_KEY, {"img": _server(argv)})
        executor = self._executor(
            script={
                "docker pull": RunResult(
                    1, "Error response from daemon: ... dial tcp: i/o timeout"
                )
            }
        )
        with self.assertRaises(BlockedNetworkError):
            install_server("img", "project", _PROJECT_KEY, executor=executor)


# -- argv parsing helpers ------------------------------------------------------


class ArgvParsingTests(InstallEnv):
    def test_parse_npx_implicit_form(self) -> None:
        spec = inst._parse_npx(["npx", "-y", "@a/b@1", "x"])
        self.assertIsNotNone(spec)
        self.assertEqual(spec.package, "@a/b@1")
        self.assertEqual(spec.binary, "b")  # scope+version stripped
        self.assertEqual(spec.binary_args, ["x"])
        self.assertFalse(spec.explicit_binary)

    def test_parse_npx_explicit_package_form(self) -> None:
        # ``npx -p pkg some-bin --flag``: the executable differs from the package.
        spec = inst._parse_npx(["npx", "-p", "my-pkg", "some-bin", "--flag"])
        self.assertEqual(spec.package, "my-pkg")
        self.assertEqual(spec.binary, "some-bin")
        self.assertEqual(spec.binary_args, ["--flag"])
        self.assertTrue(spec.explicit_binary)

    def test_parse_npx_no_package(self) -> None:
        self.assertIsNone(inst._parse_npx(["npx", "-y"]))

    def test_npm_binary_name_strips_scope_and_version(self) -> None:
        self.assertEqual(
            inst._npm_binary_name("@upstash/context7-mcp@latest"), "context7-mcp"
        )
        self.assertEqual(inst._npm_binary_name("plain-pkg@2.0.0"), "plain-pkg")
        self.assertEqual(inst._npm_binary_name("plain-pkg"), "plain-pkg")

    def test_docker_image_skips_value_flags(self) -> None:
        self.assertEqual(
            inst._docker_image_from_argv(
                ["docker", "run", "-i", "--rm", "-e", "FOO=bar",
                 "-v", "/a:/b", "img:tag", "cmd"]
            ),
            "img:tag",
        )
        self.assertIsNone(
            inst._docker_image_from_argv(["docker", "ps"])
        )

    def test_docker_image_skips_platform_and_entrypoint(self) -> None:
        # Value-taking long flags must not be mistaken for the image.
        self.assertEqual(
            inst._docker_image_from_argv(
                ["docker", "run", "--platform", "linux/amd64",
                 "--entrypoint", "mcp", "ghcr.io/org/img:tag"]
            ),
            "ghcr.io/org/img:tag",
        )
        self.assertEqual(
            inst._docker_image_from_argv(
                ["docker", "run", "--platform=linux/arm64", "img:tag"]
            ),
            "img:tag",
        )


# -- CLI exit codes ------------------------------------------------------------


class CliExitCodeTests(InstallEnv):
    """The cli.py install-* commands map error classes to distinct exit codes."""

    def setUp(self) -> None:
        super().setUp()
        from mcp import cli as cli_mod
        self.cli = cli_mod
        # Route install through our stub runner by patching install_server's
        # default runner indirectly: cli calls install_server without a runner,
        # so patch the module-level function the cli imported.
        self._real_install = cli_mod.install_server

    def tearDown(self) -> None:
        self.cli.install_server = self._real_install
        super().tearDown()

    def test_blocked_exit_code_4(self) -> None:
        def fake(name, scope, project_key=None, executor=None):
            from mcp.install import BlockedNetworkError as BNE
            raise BNE("blocked", "boxa mcp install x --global")

        self.cli.install_server = fake
        rc = self.cli.main(["install-text", "--global", "x"])
        self.assertEqual(rc, 4)

    def test_unsupported_exit_code_5(self) -> None:
        def fake(name, scope, project_key=None, executor=None):
            raise UnsupportedRuntimeError("needs a volume")

        self.cli.install_server = fake
        rc = self.cli.main(["install-text", "--global", "x"])
        self.assertEqual(rc, 5)

    def test_success_text(self) -> None:
        self._write_global({"local": _server(["node", "/opt/s.js"])})
        rc = self.cli.main(["install-text", "--global", "local"])
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
