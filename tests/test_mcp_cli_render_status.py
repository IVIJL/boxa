"""The shell MCP mutation paths no longer invoke a render command."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "scripts", "mcp-cli.sh")


def _run(call: str) -> subprocess.CompletedProcess:
    script = f'''
        set -uo pipefail
        source "{CLI}"
        _run_py_secret_write() {{ printf '%s\n' "$1" >> "$CALLS"; _LAST_SECRET_SCOPES_FILE=""; return 0; }}
        _finish_secret_write() {{ return 0; }}
        _run_py() {{ printf '%s\n' "$1" >> "$CALLS"; return 0; }}
        {call}
    '''
    descriptor, calls = tempfile.mkstemp()
    os.close(descriptor)
    env = dict(os.environ, CALLS=calls)
    proc = subprocess.run(
        ["bash", "-c", script, os.path.join(ROOT, "scripts", "_harness.sh")],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
    )
    try:
        with open(calls, encoding="utf-8") as fh:
            proc.calls = fh.read().splitlines()
    finally:
        os.unlink(calls)
    return proc


class NoRenderDispatchTest(unittest.TestCase):
    def test_definition_import_has_no_render_followup(self):
        proc = _run("scope=(--global); servers=(ctx7); imps=(); cmd_import_apply true false scope servers imps")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(any("render" in call for call in proc.calls))

    def test_yes_one_shot_routes_to_machine_import_activation(self):
        proc = _run(
            "scope=(--project /work/app); servers=(); imps=(); "
            "cmd_import_apply true true true true false claude '' /work/app "
            "scope servers imps"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.calls, ["import-activate-json"])

    def test_legacy_add_has_no_render_followup(self):
        proc = _run("cmd_add --json --global ctx7 -- npx -y @upstash/context7-mcp@latest")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(any("render" in call for call in proc.calls))

    def test_everywhere_activation_reaches_python_without_project_resolution(self):
        proc = _run("cmd_activation activate ctx7 --everywhere --for claude")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("activation-agent-trusted-text", proc.calls)
        self.assertIn("activate-text", proc.calls)

    def test_no_everywhere_reaches_python_without_activation_flags(self):
        proc = _run("cmd_activation activate ctx7 --no-everywhere")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.calls, ["activate-text"])

    def test_everywhere_and_project_are_mutually_exclusive(self):
        proc = _run(
            "cmd_activation activate ctx7 --everywhere --project /work/app --for claude"
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("cannot be combined", proc.stderr)


if __name__ == "__main__":
    unittest.main()
