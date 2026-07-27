"""ADR 0021 issue 08: inherited import is definition-only."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp.activation import activation_path, render_state_path, runtime_path  # noqa: E402
from mcp.catalog import load_catalog  # noqa: E402
from mcp.catalog_import import CatalogImportConflictError, import_definitions  # noqa: E402
from mcp.candidate import Candidate, Classification, Command  # noqa: E402
from mcp.merge import merge_candidates  # noqa: E402
from mcp.providers.claude import render_target_path  # noqa: E402


def _candidate(name, argv, *, scope="global", project=None):
    return Candidate(
        provider="fixture",
        source_path="/does/not/exist",
        source_scope=scope,
        source_project=project,
        name=name,
        type="stdio",
        command=Command(argv=list(argv)),
        classification=Classification(placement="container", confidence="high"),
    )


class CatalogImportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = {key: os.environ.get(key) for key in ("HOME", "XDG_CONFIG_HOME")}
        self.addCleanup(self._restore)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")

    def _restore(self):
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_import_writes_catalog_only_and_never_infers_trust(self):
        claude = render_target_path()
        os.makedirs(os.path.dirname(claude), exist_ok=True)
        manual = {"projects": {"/p": {"mcpServers": {"manual": {"command": "keep"}}}}}
        with open(claude, "w", encoding="utf-8") as fh:
            json.dump(manual, fh)

        result = import_definitions(merge_candidates([_candidate("echo", ["/bin/echo"])]))

        self.assertTrue(result.to_dict()["definitionOnly"])
        entry = next(iter(load_catalog()["entries"].values()))
        self.assertEqual(entry["executionMode"], "service-isolated")
        for path in (activation_path(), runtime_path(), render_state_path()):
            self.assertFalse(os.path.exists(path))
        with open(claude, encoding="utf-8") as fh:
            self.assertEqual(json.load(fh), manual)

    def test_repeat_is_idempotent_and_deduplicates_across_source_scope(self):
        candidates = merge_candidates([
            _candidate("echo", ["/bin/echo"]),
            _candidate("echo", ["/bin/echo"], scope="project", project="/p"),
        ])
        first = import_definitions(candidates)
        second = import_definitions(candidates)
        self.assertEqual(len(load_catalog()["entries"]), 1)
        self.assertTrue(any(item.changed for item in first.imported))
        self.assertTrue(all(not item.changed for item in second.imported))

    def test_same_scope_name_conflict_is_refused_before_write(self):
        selected = merge_candidates([
            _candidate("dup", ["npx", "one"]),
            _candidate("dup", ["uvx", "two"]),
        ])
        with self.assertRaises(CatalogImportConflictError):
            import_definitions(selected)
        self.assertEqual(load_catalog()["entries"], {})


if __name__ == "__main__":
    unittest.main()
