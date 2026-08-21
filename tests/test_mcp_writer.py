"""ADR 0028: the shared-file writer module is retired."""

from __future__ import annotations

import importlib.util
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))


class WriterRetirementTest(unittest.TestCase):
    def test_writer_module_is_not_shipped(self):
        self.assertIsNone(importlib.util.find_spec("mcp.writer"))


if __name__ == "__main__":
    unittest.main()
