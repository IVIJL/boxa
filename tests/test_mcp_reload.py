"""Unit tests for host-initiated MCP secret reload targeting (ADR 0014, issue 17).

These cover the UNIT-TESTABLE part: the targeting decision (which running
Containers a reload re-stages, and that each re-stage is a momentary root exec of
the reusable staging step). The real ``docker`` is never invoked — a stub
:class:`DockerExec` records calls and returns a scripted set of running
Containers. The actual cross-UID re-stage (root reads the host 0600 files, chowns
to boxa-mcp) is CONTAINER-RUNTIME-ONLY and validated host-side after a rebuild,
not here.
"""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(__file__)), "scripts"))

from mcp.cli import _emit_secret_scopes  # noqa: E402
from mcp.reload import (  # noqa: E402
    ContainerReload,
    DockerExec,
    ReloadError,
    reload_secrets,
)


class _StubDocker(DockerExec):
    """Records re-stage targets; returns a scripted running-Container set."""

    def __init__(self, running, fail=()):
        super().__init__()
        self._running = list(running)
        self._fail = set(fail)
        self.restaged: list[str] = []

    def running_boxa_containers(self):
        return list(self._running)

    def restage(self, container):
        self.restaged.append(container)
        ok = container not in self._fail
        return ContainerReload(
            container=container, ok=ok, output="" if ok else "boom"
        )


class GlobalReloadTargetingTests(unittest.TestCase):
    def test_global_reaches_every_running_container(self):
        # A global secret change re-stages ALL running boxa Containers; each
        # one stages only its own scope (enforced by the staging step's own env,
        # not by this targeting layer).
        docker = _StubDocker(["boxa-alpha", "boxa-beta", "boxa-gamma"])
        result = reload_secrets("global", docker=docker)
        self.assertEqual(
            sorted(docker.restaged),
            ["boxa-alpha", "boxa-beta", "boxa-gamma"],
        )
        self.assertEqual(len(result.reloaded), 3)
        self.assertFalse(result.any_failed)
        self.assertEqual(result.not_running, [])

    def test_global_with_no_running_containers_is_quiet_noop(self):
        docker = _StubDocker([])
        result = reload_secrets("global", docker=docker)
        self.assertEqual(docker.restaged, [])
        self.assertEqual(result.reloaded, [])

    def test_global_reports_failure(self):
        docker = _StubDocker(["boxa-alpha"], fail=["boxa-alpha"])
        result = reload_secrets("global", docker=docker)
        self.assertTrue(result.any_failed)


class ProjectReloadTargetingTests(unittest.TestCase):
    def test_project_reaches_only_that_container(self):
        # A Project secret change re-stages ONLY that Project's Container, never a
        # peer Project's, even though others are running.
        docker = _StubDocker(["boxa-alpha", "boxa-beta"])
        result = reload_secrets(
            "project", container_name="boxa-beta", docker=docker
        )
        self.assertEqual(docker.restaged, ["boxa-beta"])
        self.assertEqual(len(result.reloaded), 1)
        self.assertNotIn("boxa-alpha", docker.restaged)

    def test_project_not_running_is_noop_not_error(self):
        # The target Project's Container is not running: a no-op recorded in
        # not_running (secrets stage at its next start), never an error or a
        # re-stage of an unrelated Container.
        docker = _StubDocker(["boxa-alpha"])
        result = reload_secrets(
            "project", container_name="boxa-beta", docker=docker
        )
        self.assertEqual(docker.restaged, [])
        self.assertEqual(result.not_running, ["boxa-beta"])
        self.assertFalse(result.any_failed)

    def test_project_requires_container_name(self):
        with self.assertRaises(ReloadError):
            reload_secrets("project", container_name=None)

    def test_unknown_scope_raises(self):
        with self.assertRaises(ReloadError):
            reload_secrets("bogus")


class SecretScopesEmissionTests(unittest.TestCase):
    """The detection-prompt side channel a secret-writing command feeds the
    host front-end so it can decide whether to prompt for `boxa mcp reload`.
    SECRET-FREE: scope labels + project KEYS only, never an env name / value."""

    def _emit_to_file(self, scopes):
        tmp = tempfile.mkdtemp()
        out = os.path.join(tmp, "scopes")
        with mock.patch.dict(os.environ, {"BOXA_MCP_SCOPES_OUT": out}):
            _emit_secret_scopes(scopes)
        with open(out, encoding="utf-8") as fh:
            return fh.read().splitlines()

    def test_no_env_var_writes_nothing(self):
        # Direct invocation (no side-channel requested): writes no file, raises
        # nothing — the prompt is purely a host-front-end opt-in.
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("BOXA_MCP_SCOPES_OUT", None)
            _emit_secret_scopes([("global", "")])  # must not raise

    def test_global_scope_line(self):
        self.assertEqual(self._emit_to_file([("global", "")]), ["global"])

    def test_project_scope_carries_absolute_key(self):
        self.assertEqual(
            self._emit_to_file([("project", "/work/app")]),
            ["project\t/work/app"],
        )

    def test_dedups_repeated_scopes(self):
        # Two applied servers in the same scope must yield one prompt line.
        lines = self._emit_to_file(
            [("global", ""), ("global", ""), ("project", "/a"), ("project", "/a")]
        )
        self.assertEqual(lines, ["global", "project\t/a"])

    def test_mixed_scopes_preserved(self):
        lines = self._emit_to_file([("project", "/a"), ("global", "")])
        self.assertEqual(lines, ["project\t/a", "global"])

    def test_write_failure_is_swallowed(self):
        # An unwritable target must never fail the user's apply/add (advisory).
        with mock.patch.dict(
            os.environ, {"BOXA_MCP_SCOPES_OUT": "/nonexistent-dir/scopes"}
        ):
            _emit_secret_scopes([("global", "")])  # must not raise


if __name__ == "__main__":
    unittest.main()
