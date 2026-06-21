#!/usr/bin/env python3
"""Tests for `mcp-broker-namespace.sh` — the per-broker mount namespace wrapper.

ADR 0014 "Update 2026-05-31" (workspace bullet) + issue 21. The broker is
launched inside its own mount namespace where the project workspace is
re-mounted READ/WRITE for boxa-mcp via an idmapped bind. The REAL namespace /
idmap / setpriv path is CONTAINER-RUNTIME-ONLY (needs root + an idmap-capable
fs + a live container) and is validated host-side after `boxa build`. These
unit tests instead exercise the script's pure, host-runnable decision logic by
sourcing it (it runs `main` only when executed, not when sourced):

  * the idmapped-bind `mount` command is built with the correct
    X-mount.idmap mapping (host workspace UID/GID -> boxa-mcp's UID/GID) and
    targets the SAME absolute path (ADR 0004 parity);
  * on idmap success the script launches the broker with the credential drop and
    is quiet (no downgrade notice);
  * on idmap failure (non-idmap filesystem) it FALLS BACK and LOGS a read-only
    NOTICE (no silent fallback) — and still launches the broker;
  * a missing/absent workspace path does not abort the broker.

The companion structural test (`test_mcp_broker_entrypoint.py`) covers the
entrypoint wiring: the broker is wrapped in `unshare --mount` and the socket
dirs are created BEFORE the unshare.

Run with:

    python3 -m unittest tests.test_mcp_broker_namespace   # from repo root
    python3 tests/test_mcp_broker_namespace.py            # standalone
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_SCRIPT = os.path.join(_REPO_ROOT, "scripts", "mcp-broker-namespace.sh")


def _run_harness(body: str, *, env: dict | None = None) -> subprocess.CompletedProcess:
    """Source the namespace script and run `body` with `id`/`exec` stubbed.

    `id` is stubbed so boxa-mcp resolves to fixed UID/GID 1001 without
    needing the account to exist on the test host. `exec` is shadowed by a
    shell function that ECHOES its argv instead of replacing the process, so a
    test can observe the broker launch (the credential drop + broker argv)
    without actually setpriv-ing. Real `mount`/`unshare`/`setpriv` are never
    invoked here.
    """
    # Stubs are defined AFTER sourcing so the real functions under test
    # (build_idmap_mount_cmd, remount_workspace_idmapped, main) are exercised.
    script = f"""
        set -uo pipefail
        source "{_SCRIPT}"

        # Resolve boxa-mcp to a fixed UID/GID without the account existing.
        id() {{
            case "$1" in
                -u) echo 1001 ;;
                -g) echo 1001 ;;
                *) command id "$@" ;;
            esac
        }}

        {body}
    """
    full_env = dict(os.environ)
    if env is not None:
        full_env.update(env)
    return subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        cwd=_REPO_ROOT,
        env=full_env,
    )


class BuildIdmapMountCmdTests(unittest.TestCase):
    def test_mapping_uses_boxa_mcp_ids_and_same_path(self):
        # build_idmap_mount_cmd <source> <mcp_uid> <mcp_gid> <host_uid> <host_gid>
        out = _run_harness(
            'build_idmap_mount_cmd /work/proj 1001 1001 1000 1000'
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        tokens = out.stdout.split("\n")
        tokens = [t for t in tokens if t != ""]
        # The bind + idmap option, mapping host 1000 -> boxa-mcp 1001 (1 entry).
        self.assertIn("mount", tokens)
        self.assertIn("--bind", tokens)
        self.assertIn("-o", tokens)
        self.assertIn(
            "X-mount.idmap=u:1000:1001:1 g:1000:1001:1", tokens
        )
        # Source and target are the SAME absolute path (ADR 0004 parity): the
        # workspace is bound onto itself with the idmap applied to the new bind.
        self.assertEqual(
            tokens.count("/work/proj"), 2,
            f"expected source==target /work/proj twice, got: {tokens}",
        )

    def test_mapping_reflects_alternate_boxa_mcp_uid(self):
        # A different boxa-mcp UID/GID must flow into the mapping verbatim.
        out = _run_harness(
            'build_idmap_mount_cmd /p 2002 3003 1000 1000'
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("X-mount.idmap=u:1000:2002:1 g:1000:3003:1", out.stdout)


class FallbackDecisionTests(unittest.TestCase):
    """main()'s idmap-success vs read-only-fallback branch, with the remount
    stubbed to force each outcome and `exec` stubbed to observe the launch."""

    _LAUNCH_SENTINEL = "LAUNCH:"
    # Echo the broker-launch argv instead of replacing the process.
    _EXEC_STUB = (
        'exec() {{ echo "{sentinel} $*"; }}'.format(sentinel=_LAUNCH_SENTINEL)
    )

    def setUp(self):
        # main() guards on the workspace being a real directory before it reaches
        # the idmap-success/failure branches, so the success/failure tests point
        # BOXA_PROJECT_HOST_PATH at an existing temp dir.
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.workspace = self._tmp.name

    def test_idmap_success_launches_quietly(self):
        # Force the remount to succeed; the broker must still launch and there
        # must be NO downgrade notice on stderr.
        body = (
            self._EXEC_STUB
            + "\n"
            + "remount_workspace_idmapped() { return 0; }\n"
            + "main"
        )
        out = _run_harness(body, env={"BOXA_PROJECT_HOST_PATH": self.workspace})
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("setpriv --reuid=boxa-mcp", out.stdout)
        self.assertIn("boxa-mcp-broker", out.stdout)
        self.assertNotIn("NOTICE", out.stderr)
        self.assertNotIn("READ-ONLY", out.stderr)

    def test_idmap_failure_logs_readonly_and_still_launches(self):
        # Force the remount to fail (non-idmap fs); the broker must STILL launch
        # and the downgrade must be LOGGED (no silent fallback).
        body = (
            self._EXEC_STUB
            + "\n"
            + "remount_workspace_idmapped() { return 1; }\n"
            + "main"
        )
        out = _run_harness(body, env={"BOXA_PROJECT_HOST_PATH": self.workspace})
        self.assertEqual(out.returncode, 0, out.stderr)
        # Broker still launches.
        self.assertIn("setpriv --reuid=boxa-mcp", out.stdout)
        self.assertIn("boxa-mcp-broker", out.stdout)
        # Downgrade is logged (loud), and never touches host metadata.
        self.assertIn("NOTICE", out.stderr)
        self.assertIn("READ-ONLY", out.stderr)

    def test_no_workspace_path_launches_without_remount(self):
        # Non-project invocation: no BOXA_PROJECT_HOST_PATH. The broker must
        # launch with the inherited view and no remount attempt / no warning.
        body = (
            self._EXEC_STUB
            + "\n"
            # If remount were called it would fail loudly; assert it is NOT.
            + "remount_workspace_idmapped() { echo REMOUNT_CALLED >&2; return 1; }\n"
            + "main"
        )
        out = _run_harness(body, env={"BOXA_PROJECT_HOST_PATH": ""})
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("boxa-mcp-broker", out.stdout)
        self.assertNotIn("REMOUNT_CALLED", out.stderr)
        self.assertNotIn("NOTICE", out.stderr)

    def test_missing_workspace_dir_warns_and_launches(self):
        # The path is set but is not a directory in the namespace -> warn and
        # launch with the inherited view (configuration anomaly, not fatal).
        body = (
            self._EXEC_STUB
            + "\n"
            + "remount_workspace_idmapped() { echo REMOUNT_CALLED >&2; return 1; }\n"
            + "main"
        )
        out = _run_harness(
            body,
            env={"BOXA_PROJECT_HOST_PATH": "/nonexistent/path/xyzzy"},
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("boxa-mcp-broker", out.stdout)
        self.assertIn("WARNING", out.stderr)
        self.assertNotIn("REMOUNT_CALLED", out.stderr)

    def test_broker_env_matches_credential_drop(self):
        # The launch must carry the issue-15 clean boxa-mcp env: own HOME, npm
        # cache, gated profile mount, private secrets dir — plus the issue-20
        # Docker daemon pointers forwarded from the image ENV (so the broker can
        # propagate them to docker-launcher servers it spawns).
        body = (
            self._EXEC_STUB
            + "\n"
            + "remount_workspace_idmapped() { return 0; }\n"
            + "main"
        )
        out = _run_harness(
            body,
            env={
                "BOXA_PROJECT_HOST_PATH": self.workspace,
                "DOCKER_HOST": "unix:///run/user/1000/docker.sock",
                "XDG_RUNTIME_DIR": "/run/user/1000",
            },
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        for token in (
            "--regid=boxa-mcp",
            "--init-groups",
            "env -i",
            "HOME=/home/boxa-mcp",
            "npm_config_cache=/home/boxa-mcp/.npm",
            "XDG_CONFIG_HOME=/run/boxa-mcp/host",
            "BOXA_MCP_SECRETS_DIR=/run/boxa-mcp/secrets",
            "DOCKER_HOST=unix:///run/user/1000/docker.sock",
            "XDG_RUNTIME_DIR=/run/user/1000",
        ):
            self.assertIn(token, out.stdout, f"missing {token!r} in launch")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
