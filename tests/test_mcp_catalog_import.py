"""ADR 0021 issue 08: inherited import is definition-only."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp.activation import activation_path, runtime_path  # noqa: E402
from mcp.migration import render_state_path  # noqa: E402
from mcp.catalog import load_catalog  # noqa: E402
from mcp.catalog_import import (  # noqa: E402
    CatalogImportConflictError,
    catalog_verdicts,
    import_definitions,
)
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


def _remote_candidate(name, url, *, headers=None, secret_header_keys=None):
    return Candidate(
        provider="fixture",
        source_path="/does/not/exist",
        source_scope="global",
        name=name,
        type="http",
        url=url,
        headers=dict(headers or {}),
        secret_header_keys=list(secret_header_keys or []),
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

    def test_remote_import_round_trips_header_declarations(self):
        candidate = _remote_candidate(
            "remote",
            "https://example.test/mcp",
            headers={"X-Tenant": "engineering"},
            secret_header_keys=["Authorization"],
        )
        import_definitions(merge_candidates([candidate]))
        entry = next(iter(load_catalog()["entries"].values()))
        self.assertEqual(entry["headers"], {"X-Tenant": "engineering"})
        self.assertEqual(entry["secretHeaderKeys"], ["Authorization"])
        with open(os.path.join(os.environ["XDG_CONFIG_HOME"], "boxa", "mcp", "catalog.json"), encoding="utf-8") as fh:
            raw = fh.read()
        self.assertNotIn("Bearer ", raw)

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

    def test_http_import_writes_url_without_local_runtime_fields(self):
        import_definitions(
            merge_candidates(
                [_remote_candidate("dozzle", "https://dozzle.example.test/mcp")]
            )
        )
        entry = next(iter(load_catalog()["entries"].values()))
        self.assertEqual(entry["type"], "http")
        self.assertEqual(entry["url"], "https://dozzle.example.test/mcp")
        self.assertNotIn("command", entry)
        self.assertNotIn("executionMode", entry)

    def test_same_scope_name_conflict_is_refused_before_write(self):
        selected = merge_candidates([
            _candidate("dup", ["npx", "one"]),
            _candidate("dup", ["uvx", "two"]),
        ])
        with self.assertRaises(CatalogImportConflictError):
            import_definitions(selected)
        self.assertEqual(load_catalog()["entries"], {})

    def test_discovery_marks_identical_definition_already_cataloged(self):
        original = merge_candidates([_candidate("original", ["/bin/echo"])])
        imported = import_definitions(original).imported[0]

        rediscovered = catalog_verdicts(
            merge_candidates([_candidate("alias", ["/bin/echo"])])
        )[0]

        self.assertEqual(rediscovered.catalog_status, "already-cataloged")
        self.assertEqual(rediscovered.catalog_id, imported.catalog_id)
        self.assertTrue(rediscovered.to_dict()["alreadyCataloged"])

    def test_same_name_catalog_conflict_diff_supports_skip_and_update(self):
        original = import_definitions(
            merge_candidates([_candidate("tool", ["/bin/echo", "old"])])
        ).imported[0]
        conflicting = catalog_verdicts(
            merge_candidates([_candidate("tool", ["/bin/echo", "new"])])
        )[0]
        self.assertEqual(conflicting.catalog_status, "conflict")
        self.assertEqual(conflicting.catalog_id, original.catalog_id)
        self.assertEqual(conflicting.catalog_diff[0]["field"], "command")

        skipped = import_definitions(
            [conflicting], catalog_conflicts={conflicting.import_id: "skip"}
        )
        self.assertEqual(skipped.imported, [])
        entry = load_catalog()["entries"][original.catalog_id]
        self.assertEqual(entry["command"]["argv"], ["/bin/echo", "old"])

        updated = import_definitions(
            [conflicting], catalog_conflicts={conflicting.import_id: "update"}
        )
        self.assertEqual(updated.imported[0].catalog_id, original.catalog_id)
        entry = load_catalog()["entries"][original.catalog_id]
        self.assertEqual(entry["command"]["argv"], ["/bin/echo", "new"])

    def test_host_only_candidate_requires_explicit_force(self):
        candidate = merge_candidates([_candidate("desktop", ["npx", "desktop-mcp"])])[0]
        candidate.candidate.classification = Classification(
            placement="host-only",
            confidence="high",
            reasons=["needs host desktop"],
        )

        skipped = import_definitions([candidate])
        self.assertEqual(skipped.imported, [])
        self.assertIn("host-only", skipped.skipped[0]["reason"])

        imported = import_definitions([candidate], force_host_only=True)
        self.assertEqual(len(imported.imported), 1)


if __name__ == "__main__":
    unittest.main()
