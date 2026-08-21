"""ADR 0028 issue 07: catalog-aware discovery and one-shot import UX."""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import cli, lifecycle  # noqa: E402
from mcp.activation import load_activations  # noqa: E402
from mcp.candidate import Candidate, Classification  # noqa: E402
from mcp.catalog_import import catalog_verdicts, import_definitions  # noqa: E402
from mcp.merge import merge_candidates  # noqa: E402


def _remote(name: str, url: str) -> Candidate:
    return Candidate(
        provider="fixture",
        source_path="/fixture/config.json",
        source_scope="global",
        name=name,
        type="http",
        url=url,
        classification=Classification(
            placement="container", confidence="high", reasons=["fixture"]
        ),
    )


class ImportDiscoveryUxTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = {
            key: os.environ.get(key)
            for key in ("HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR")
        }
        self.addCleanup(self._restore)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
        self.project = os.path.join(self.tmp.name, "project")
        os.makedirs(self.project)

    def _restore(self):
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _write_claude(self, servers: dict) -> None:
        with open(os.path.join(self.tmp.name, ".claude.json"), "w", encoding="utf-8") as fh:
            json.dump({"mcpServers": servers, "projects": {}}, fh)

    def test_project_status_nudges_only_for_unimported_container_candidates(self):
        self._write_claude({
            "remote": {"type": "http", "url": "https://mcp.example.test/api"}
        })

        status = lifecycle.catalog_project_status(self.project)
        self.assertEqual(status["importProposalCount"], 1)
        self.assertIn("boxa mcp import", status["importNudge"])
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli._cmd_catalog_effective_list(
                ["--project", self.project], as_json=True
            )
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(stdout.getvalue())["importProposalCount"], 1)

        import_definitions(merge_candidates([
            _remote("remote", "https://mcp.example.test/api")
        ]))
        status = lifecycle.catalog_project_status(self.project)
        self.assertEqual(status["importProposalCount"], 0)
        self.assertEqual(status["importNudge"], "")
        self.assertEqual(
            status["inheritedCandidates"][0]["catalogStatus"],
            "already-cataloged",
        )

        self._write_claude({})
        clean = lifecycle.catalog_project_status(self.project)
        self.assertEqual(clean["inheritedCandidates"], [])
        self.assertEqual(clean["importNudge"], "")

    def test_discovery_and_status_never_spawn_candidate_process(self):
        self._write_claude({
            "remote": {"type": "http", "url": "https://mcp.example.test/api"}
        })
        with mock.patch.object(subprocess, "Popen") as popen, mock.patch.object(
            subprocess, "run"
        ) as run:
            lifecycle.catalog_project_status(self.project)
        popen.assert_not_called()
        run.assert_not_called()

    def test_json_yes_one_shot_import_readiness_activation(self):
        discovered = catalog_verdicts(merge_candidates([
            _remote("remote", "https://mcp.example.test/api")
        ]))
        stdout = io.StringIO()
        with mock.patch.object(cli, "_discover", return_value=discovered), \
                contextlib.redirect_stdout(stdout):
            rc = cli._cmd_import_activate(
                [
                    "--target-project", self.project,
                    "--for", "claude",
                    "--yes",
                    "--server", "remote",
                ],
                as_json=True,
            )

        self.assertEqual(rc, 0)
        payload = json.loads(stdout.getvalue())
        self.assertTrue(payload["accepted"])
        self.assertTrue(payload["flow"][0]["readiness"]["ready"])
        self.assertEqual(payload["flow"][0]["activation"]["consumers"], ["claude"])
        entry_id = payload["flow"][0]["catalogId"]
        self.assertIn(entry_id, load_activations()["projects"][self.project])

    def test_remote_import_apply_skips_install_hint(self):
        discovered = catalog_verdicts(merge_candidates([
            _remote("remote", "https://mcp.example.test/api")
        ]))
        stdout = io.StringIO()
        with mock.patch.object(cli, "_discover", return_value=discovered), \
                contextlib.redirect_stdout(stdout):
            rc = cli.main(["apply-text", "--server", "remote"])

        self.assertEqual(rc, 0)
        self.assertNotIn("mcp install remote", stdout.getvalue())
        self.assertIn(
            "Next: boxa mcp activate remote --project <path> --for claude|codex",
            stdout.getvalue(),
        )


if __name__ == "__main__":
    unittest.main()
