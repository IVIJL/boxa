"""MCP lifecycle diagnostics after shared render retirement."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import activation, lifecycle  # noqa: E402
from mcp.catalog import add_entry, update_entry  # noqa: E402


class LifecycleDiagnosisTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = {key: os.environ.get(key) for key in ("HOME", "XDG_CONFIG_HOME", "PATH")}
        self.addCleanup(self._restore)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")
        os.environ["PATH"] = ""
        added = add_entry("echo", ["npx", "placeholder"])
        self.entry = update_entry(added["id"], argv=["/bin/cat"])

    def _restore(self):
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_doctor_reports_runtime_snapshot_not_project_render_drift(self):
        os.unlink(activation.runtime_path())
        report = lifecycle.run_doctor()
        codes = {finding.code for finding in report.findings}
        self.assertIn("catalog-runtime-drift", codes)
        self.assertNotIn("render-drift", codes)
        self.assertFalse(any("render" in code for code in codes))

    def test_doctor_fix_refreshes_runtime_snapshot(self):
        os.unlink(activation.runtime_path())
        report = lifecycle.run_doctor()
        result = lifecycle.apply_doctor_fixes(report)
        self.assertTrue(os.path.isfile(activation.runtime_path()))
        self.assertIn("refreshed the secret-free MCP runtime snapshot", result.actions)


if __name__ == "__main__":
    unittest.main()
