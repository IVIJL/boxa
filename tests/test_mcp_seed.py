#!/usr/bin/env python3
"""Tests for the codex-delegate catalog seed core + shell hook.

Run with:

    python3 -m unittest tests.test_mcp_seed   # from repo root
    python3 tests/test_mcp_seed.py            # standalone

Every test points HOME / XDG_CONFIG_HOME at a fresh tempdir so the real
~/.config/boxa/mcp/{catalog.json,state.json} is never read or written. The
shell-hook tests run scripts/ensure-codex-delegate-seed.sh with HOME/XDG
redirected so the hook exercises the genuine Python core but touches only the
tempdir.

Covers:
  * the seed is offered only when no catalog entry running `codex mcp-server`
    exists (matched by command, not name) AND the offer was not already
    applied/dismissed;
  * the marker shares state.json with the onboarding wizard under its own key
    and neither marker suppresses the other;
  * apply() is host-only: it refuses inside a Container BEFORE touching the
    catalog (no half-seeded entry), and on the host records the entry with
    the agent-trusted grant, the codex-login prerequisite probe, and the
    applied marker;
  * the non-interactive hook never prompts or applies — it prints the manual
    commands and leaves the marker untouched;
  * a present entry keeps later updates silent even without --quiet-if-noop.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp import catalog, onboarding, seed  # noqa: E402
from mcp.catalog import CatalogError  # noqa: E402

_HOOK = os.path.join(_REPO_ROOT, "scripts", "ensure-codex-delegate-seed.sh")


class SeedEnv(unittest.TestCase):
    """Base class isolating HOME / XDG_CONFIG_HOME."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self._saved = {}
        for var in ("HOME", "XDG_CONFIG_HOME"):
            self._saved[var] = os.environ.get(var)
        os.environ["HOME"] = self.home
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.home, ".config")

    def tearDown(self) -> None:
        for var, val in self._saved.items():
            if val is None:
                os.environ.pop(var, None)
            else:
                os.environ[var] = val
        self._tmp.cleanup()

    # -- fixtures -----------------------------------------------------------

    @staticmethod
    def _add_delegate_entry(name: str = "codex-delegate") -> dict:
        return catalog.add_entry(name, ["codex", "mcp-server"])


class EligibilityTests(SeedEnv):
    """should_offer() / entry_present() / seed_seen() rules."""

    def test_fresh_state_offers(self) -> None:
        self.assertTrue(seed.should_offer())
        self.assertFalse(seed.entry_present())
        self.assertFalse(seed.seed_seen())

    def test_existing_entry_suppresses_offer(self) -> None:
        self._add_delegate_entry()
        self.assertTrue(seed.entry_present())
        self.assertFalse(seed.should_offer())

    def test_entry_matched_by_command_not_name(self) -> None:
        # A user who added the delegation under another name is still covered.
        self._add_delegate_entry(name="my-codex")
        self.assertTrue(seed.entry_present())
        self.assertFalse(seed.should_offer())

    def test_unrelated_codex_entry_does_not_count(self) -> None:
        # `codex` without the mcp-server argv is not the delegation server.
        # (Direct add of such an entry is refused as not applicable, so write
        # the shape through the low-level catalog file instead.)
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
        self.assertFalse(seed.entry_present())
        self.assertTrue(seed.should_offer())

    def test_mark_seen_suppresses_and_rearm_restores(self) -> None:
        seed.mark_seen(seed.DECISION_DISMISSED)
        self.assertTrue(seed.seed_seen())
        self.assertFalse(seed.should_offer())
        seed.rearm()
        self.assertFalse(seed.seed_seen())
        self.assertTrue(seed.should_offer())

    def test_rearm_does_not_force_offer_over_entry(self) -> None:
        self._add_delegate_entry()
        seed.mark_seen(seed.DECISION_APPLIED)
        seed.rearm()
        self.assertFalse(seed.should_offer())

    def test_markers_are_independent_of_onboarding(self) -> None:
        # Dismissing the onboarding wizard must not suppress the seed offer,
        # and vice versa; both live in the same state.json under own keys.
        onboarding.mark_seen(onboarding.DECISION_DISMISSED)
        self.assertTrue(seed.should_offer())
        seed.mark_seen(seed.DECISION_DISMISSED)
        self.assertTrue(onboarding.onboarding_seen())
        self.assertTrue(seed.seed_seen())
        state = onboarding.load_state()
        self.assertIn("seen", state)
        self.assertIn(seed.STATE_KEY, state)

    def test_unknown_decision_normalised_to_noop(self) -> None:
        seed.mark_seen("garbage")
        with open(onboarding.state_path(), "r", encoding="utf-8") as fh:
            data = json.load(fh)
        self.assertEqual(data[seed.STATE_KEY]["decision"], "noop")


class ApplyTests(SeedEnv):
    """apply() host guard, grant shape, idempotence."""

    def test_add_entry_trusted_refuses_in_container_without_persisting(self) -> None:
        with mock.patch("mcp.catalog._host_mode_command", return_value=False):
            with self.assertRaises(CatalogError):
                catalog.add_entry_trusted(seed.SEED_NAME, list(seed.SEED_ARGV))
        self.assertFalse(seed.entry_present())

    def test_apply_refuses_in_container_without_touching_catalog(self) -> None:
        with mock.patch("mcp.catalog._host_mode_command", return_value=False):
            with self.assertRaises(CatalogError):
                seed.apply()
        # No half-seeded entry and no marker: the offer stays retryable.
        self.assertFalse(seed.entry_present())
        self.assertFalse(seed.seed_seen())

    def test_apply_records_trusted_entry_and_marker(self) -> None:
        with mock.patch("mcp.catalog._host_mode_command", return_value=True):
            entry = seed.apply()
        self.assertEqual(entry["name"], seed.SEED_NAME)
        self.assertEqual(entry["command"]["argv"], list(seed.SEED_ARGV))
        self.assertEqual(entry["executionMode"], "agent-trusted")
        self.assertEqual(
            entry["prerequisites"], {"probes": ["codex-login-status"]}
        )
        # Durable in the catalog, not just the returned dict.
        stored = seed.find_entry()
        self.assertIsNotNone(stored)
        self.assertEqual(stored["executionMode"], "agent-trusted")
        self.assertTrue(seed.seed_seen())
        self.assertFalse(seed.should_offer())

    def test_apply_is_idempotent_over_existing_entry(self) -> None:
        # A manually added delegation entry is adopted as-is (mode untouched).
        existing = self._add_delegate_entry(name="my-codex")
        with mock.patch("mcp.catalog._host_mode_command", return_value=True):
            entry = seed.apply()
        self.assertEqual(entry["id"], existing["id"])
        self.assertEqual(entry["executionMode"], "service-isolated")
        self.assertTrue(seed.seed_seen())


class StatusAndTextTests(SeedEnv):
    """status_dict() booleans and the secret-free text blocks."""

    def test_status_fresh(self) -> None:
        d = seed.status_dict()
        self.assertTrue(d["shouldOffer"])
        self.assertFalse(d["entryPresent"])
        self.assertFalse(d["seen"])
        self.assertEqual(d["decision"], "")

    def test_status_after_apply(self) -> None:
        with mock.patch("mcp.catalog._host_mode_command", return_value=True):
            seed.apply()
        d = seed.status_dict()
        self.assertFalse(d["shouldOffer"])
        self.assertTrue(d["entryPresent"])
        self.assertTrue(d["seen"])
        self.assertEqual(d["decision"], "applied")

    def test_offer_text_includes_access_boundary(self) -> None:
        # The offer must show the exact `boxa mcp mode` preview wording; the
        # interactive confirmation stands in for that host flow.
        text = seed.offer_text()
        for item in catalog.AGENT_TRUSTED_ACCESS:
            self.assertIn(item, text)
        self.assertIn("boxa mcp activate codex-delegate", text)

    def test_text_blocks_present_and_secret_free(self) -> None:
        for fn in (seed.offer_text, seed.followup_text, seed.reminder_text):
            text = fn()
            self.assertIn("boxa mcp", text)
            self.assertNotIn("sk-", text)


class HookEnv(unittest.TestCase):
    """Drive the shell hook end-to-end against the real Python core."""

    def setUp(self) -> None:
        if not os.access(_HOOK, os.X_OK):
            self.skipTest("ensure-codex-delegate-seed.sh not executable")
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self.xdg = os.path.join(self.home, ".config")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _env(self) -> dict:
        env = dict(os.environ)
        env["HOME"] = self.home
        env["XDG_CONFIG_HOME"] = self.xdg
        scripts = os.path.join(_REPO_ROOT, "scripts")
        env["PYTHONPATH"] = scripts + (
            os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else ""
        )
        return env

    def _run(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [_HOOK, *args],
            env=self._env(),
            capture_output=True,
            text=True,
            timeout=60,
        )

    def _py(self, *args: str) -> None:
        subprocess.run(
            [sys.executable, "-m", "mcp.cli", *args],
            env=self._env(),
            check=True,
            cwd=_REPO_ROOT,
            stdout=subprocess.DEVNULL,
        )

    def _state(self) -> dict:
        path = os.path.join(self.xdg, "boxa", "mcp", "state.json")
        if not os.path.isfile(path):
            return {}
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)

    def test_noninteractive_eligible_prints_followup_and_does_not_mark(
        self,
    ) -> None:
        # Eligible (fresh) + forced non-interactive: print the manual commands,
        # NEVER prompt or apply, and leave the marker UNSET so a later
        # interactive update can still offer.
        res = self._run("--non-interactive")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("boxa mcp add codex-delegate", res.stdout)
        self.assertNotIn("[Y/n]", res.stdout)
        self.assertEqual(self._state(), {})  # marker untouched
        catalog_file = os.path.join(self.xdg, "boxa", "mcp", "catalog.json")
        self.assertFalse(os.path.isfile(catalog_file))  # nothing applied

    def test_dismissed_quiet_is_silent(self) -> None:
        self._py("seed-codex-delegate-mark-seen", "dismissed")
        res = self._run("--non-interactive", "--quiet-if-noop")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(res.stdout.strip(), "")

    def test_dismissed_loud_prints_reminder(self) -> None:
        self._py("seed-codex-delegate-mark-seen", "dismissed")
        res = self._run("--non-interactive")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("boxa mcp add codex-delegate", res.stdout)
        self.assertNotIn("[Y/n]", res.stdout)

    def test_present_entry_is_silent_even_loud(self) -> None:
        # Steady state (entry exists, e.g. manually added): no reminder at all,
        # with or without --quiet-if-noop.
        self._py(
            "catalog-add-text", "codex-delegate", "--", "codex", "mcp-server"
        )
        res = self._run("--non-interactive")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(res.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
