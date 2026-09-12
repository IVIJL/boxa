#!/usr/bin/env python3
"""ADR 0037: the retired `codex mcp-server` catalog entry is explained, never removed.

Run with:

    PYTHONPATH=scripts python3 -m unittest tests.test_mcp_retired_codex_delegate

Replaces the former `tests/test_mcp_seed.py`: the one-time `codex-delegate`
seed (`scripts/ensure-codex-delegate-seed.sh`, `mcp.seed`) is gone, and what
remains is a check-only report. Every test points HOME / XDG_CONFIG_HOME at a
fresh tempdir so the real ~/.config/boxa/mcp/catalog.json is never touched.

Covers:
  * the leftover entry is matched by command, not by name, and an unrelated
    `codex` entry is not matched;
  * the notice explains that `codex mcp-server` no longer exists, points to
    `boxa-job` / docs/jobs.md, and prints `boxa mcp remove <real name>`;
  * a clean catalog renders nothing at all (so `boxa doctor` stays silent);
  * `boxa mcp status` shows it in both the Project view and the profile view,
    and names it in the JSON of both;
  * the seed script and module are really gone.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp import catalog  # noqa: E402


class RetiredEntryEnv(unittest.TestCase):
    """Base class isolating HOME / XDG_CONFIG_HOME."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.home = self._tmp.name
        self.project = os.path.join(self.home, "project")
        os.makedirs(self.project)
        self._saved = {
            var: os.environ.get(var) for var in ("HOME", "XDG_CONFIG_HOME")
        }
        self.addCleanup(self._restore)
        os.environ["HOME"] = self.home
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.home, ".config")

    def _restore(self) -> None:
        for var, value in self._saved.items():
            if value is None:
                os.environ.pop(var, None)
            else:
                os.environ[var] = value

    @staticmethod
    def _add_delegate_entry(name: str = "codex-delegate") -> dict:
        return catalog.add_entry(name, ["codex", "mcp-server"])

    def _cli(self, *args: str) -> subprocess.CompletedProcess:
        env = dict(
            os.environ,
            PYTHONPATH=os.path.join(_REPO_ROOT, "scripts"),
            HOME=self.home,
            XDG_CONFIG_HOME=os.path.join(self.home, ".config"),
        )
        return subprocess.run(
            [sys.executable, "-m", "mcp.cli", *args],
            cwd=_REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )


class DetectionTests(RetiredEntryEnv):
    def test_clean_catalog_reports_nothing(self) -> None:
        self.assertEqual(catalog.retired_codex_delegate_entries(), [])
        self.assertEqual(catalog.retired_codex_delegate_notice(), "")

    def test_entry_is_matched_by_command_not_name(self) -> None:
        self._add_delegate_entry(name="my-codex")
        found = catalog.retired_codex_delegate_entries()
        self.assertEqual([e["name"] for e in found], ["my-codex"])
        self.assertIn("boxa mcp remove my-codex", catalog.retired_codex_delegate_notice())

    def test_a_name_needing_quoting_is_quoted_in_the_suggestion(self) -> None:
        """The printed line is meant to be pasted into a shell as it stands."""
        notice = catalog.retired_codex_delegate_notice(
            entries=[{"name": "my codex; rm -rf ~"}]
        )
        self.assertIn("boxa mcp remove 'my codex; rm -rf ~'", notice)

    def test_unrelated_codex_entry_is_not_matched(self) -> None:
        # `codex` without the mcp-server argv is not the retired server.
        # (A direct add of that shape is refused as not applicable, so write
        # the entry through the catalog file, as the seed tests did.)
        cat = catalog.load_catalog()
        cat["entries"]["11111111-1111-1111-1111-111111111111"] = {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "codex-other",
            "type": "stdio",
            "executionMode": "service-isolated",
            "runtimeKind": "direct",
            "readiness": {"summary": "requires-project"},
            "command": {"argv": ["codex", "exec"]},
            "envKeys": [],
            "secretEnvKeys": [],
        }
        catalog.save_catalog(cat)
        self.assertEqual(catalog.retired_codex_delegate_entries(), [])

    def test_notice_explains_the_removal_and_the_replacement(self) -> None:
        self._add_delegate_entry()
        text = catalog.retired_codex_delegate_notice()
        self.assertIn("codex mcp-server", text)
        self.assertIn("no longer provide", text)
        self.assertIn("boxa-job", text)
        self.assertIn("docs/jobs.md", text)
        self.assertIn("ADR 0037", text)
        self.assertIn("boxa mcp remove codex-delegate", text)
        self.assertNotIn("boxa mcp add", text)


class DoctorCommandTests(RetiredEntryEnv):
    """`mcp.cli retired-codex-delegate-text`, what `boxa doctor` calls."""

    def test_silent_and_ok_on_a_clean_catalog(self) -> None:
        res = self._cli("retired-codex-delegate-text")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(res.stdout, "")

    def test_prints_the_explanation_and_removal_command(self) -> None:
        self._add_delegate_entry()
        res = self._cli("retired-codex-delegate-text")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("can never start", res.stdout)
        self.assertIn("boxa-job start --codex", res.stdout)
        self.assertIn("boxa mcp remove codex-delegate", res.stdout)

    def test_takes_no_arguments(self) -> None:
        res = self._cli("retired-codex-delegate-text", "--fix")
        self.assertEqual(res.returncode, 2)
        self.assertIn("takes no arguments", res.stderr)

    def test_never_removes_the_entry(self) -> None:
        entry = self._add_delegate_entry()
        self._cli("retired-codex-delegate-text")
        names = [e["name"] for e in catalog.entries_sorted(catalog.load_catalog())]
        self.assertEqual(names, [entry["name"]])


class StatusRenderTests(RetiredEntryEnv):
    """`boxa mcp status` (both scopes) explains the leftover entry."""

    def test_project_view_text_and_json(self) -> None:
        self._add_delegate_entry()
        text = self._cli("catalog-effective-list-text", "--project", self.project)
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertIn("boxa mcp remove codex-delegate", text.stdout)
        as_json = self._cli("catalog-effective-list-json", "--project", self.project)
        self.assertEqual(as_json.returncode, 0, as_json.stderr)
        self.assertEqual(
            json.loads(as_json.stdout)["retiredCodexDelegate"], ["codex-delegate"]
        )

    def test_profile_view_text_and_json(self) -> None:
        self._add_delegate_entry()
        text = self._cli("list-text")
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertIn("boxa mcp remove codex-delegate", text.stdout)
        as_json = self._cli("list-json")
        self.assertEqual(as_json.returncode, 0, as_json.stderr)
        self.assertEqual(
            json.loads(as_json.stdout)["retiredCodexDelegate"], ["codex-delegate"]
        )

    def test_clean_catalog_adds_no_warning(self) -> None:
        text = self._cli("catalog-effective-list-text", "--project", self.project)
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertNotIn("codex mcp-server", text.stdout)


class SeedIsGoneTests(unittest.TestCase):
    def test_seed_module_and_hook_are_removed(self) -> None:
        self.assertFalse(
            os.path.exists(os.path.join(_REPO_ROOT, "scripts", "mcp", "seed.py"))
        )
        self.assertFalse(
            os.path.exists(
                os.path.join(_REPO_ROOT, "scripts", "ensure-codex-delegate-seed.sh")
            )
        )
        with self.assertRaises(ImportError):
            __import__("mcp.seed")

    def test_no_seed_subcommand_survives_in_the_cli(self) -> None:
        res = subprocess.run(
            [sys.executable, "-m", "mcp.cli", "seed-codex-delegate-status"],
            cwd=_REPO_ROOT,
            env=dict(os.environ, PYTHONPATH=os.path.join(_REPO_ROOT, "scripts")),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(res.returncode, 2)
        self.assertIn("unknown command", res.stderr)


if __name__ == "__main__":
    unittest.main()
