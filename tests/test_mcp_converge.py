"""ADR 0028: render convergence has no remaining duty."""

from __future__ import annotations

import importlib.util
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import cli  # noqa: E402


class ConvergenceRetirementTest(unittest.TestCase):
    def test_converge_module_is_not_shipped(self):
        self.assertIsNone(importlib.util.find_spec("mcp.converge"))

    def test_converge_command_is_not_dispatched(self):
        self.assertEqual(cli.main(["converge"]), 2)


if __name__ == "__main__":
    unittest.main()
