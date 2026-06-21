#!/usr/bin/env python3
"""Tests for MCP onboarding state + eligibility and the shell hook (issue 10).

Run with:

    python3 -m unittest tests.test_mcp_onboarding   # from repo root
    python3 tests/test_mcp_onboarding.py            # standalone

Every test points HOME / XDG_CONFIG_HOME at a fresh tempdir so the real
~/.config/boxa/mcp/state.json is never read or written. The shell-hook tests
additionally run scripts/ensure-mcp-onboarding.sh with HOME/XDG redirected and
PATH carrying a fake `python3 -m mcp.cli` route (the real interpreter) so the
hook exercises the genuine Python core but touches only the tempdir.

Covers the issue-10 acceptance criteria:
  * onboarding is offered only when no boxa MCP profile exists yet AND the
    wizard has not already been seen/dismissed;
  * the seen/dismissed marker is written to ~/.config/boxa/mcp/state.json;
  * deleting profile files does not re-trigger onboarding once seen;
  * the non-interactive hook never prompts or applies — it prints a follow-up
    command and leaves the marker untouched (a later interactive update may ask);
  * a later run (already seen, or a profile exists) prints only a reminder, and
    --quiet-if-noop silences even that.
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

from mcp import onboarding  # noqa: E402
from mcp.profile import (  # noqa: E402
    global_profile_path,
    project_profile_path,
    save_profile,
)

_HOOK = os.path.join(_REPO_ROOT, "scripts", "ensure-mcp-onboarding.sh")
_PROJECT_KEY = "/home/tester/Projekty/DemoApp"


class OnboardingEnv(unittest.TestCase):
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

    def _write_global_profile(self, servers: dict) -> str:
        path = global_profile_path()
        save_profile(path, {"version": 1, "servers": servers})
        return path

    def _write_project_profile(self, project_key: str, servers: dict) -> str:
        path = project_profile_path(project_key)
        save_profile(
            path, {"version": 1, "projectKey": project_key, "servers": servers}
        )
        return path

    @staticmethod
    def _server() -> dict:
        return {
            "name": "context7",
            "type": "stdio",
            "command": {"argv": ["npx", "-y", "@upstash/context7-mcp@latest"]},
            "envKeys": [],
            "secretEnvKeys": [],
            "source": {"provider": "claude-code", "importId": "imp-aaa"},
        }


class EligibilityTests(OnboardingEnv):
    """should_offer() / profile_exists() / onboarding_seen() rules."""

    def test_fresh_state_offers(self) -> None:
        # No profile, no marker -> eligible.
        self.assertTrue(onboarding.should_offer())
        self.assertFalse(onboarding.profile_exists())
        self.assertFalse(onboarding.onboarding_seen())

    def test_empty_global_profile_does_not_count_as_existing(self) -> None:
        # A stray empty profile.json (no servers) must not suppress the offer.
        self._write_global_profile({})
        self.assertFalse(onboarding.profile_exists())
        self.assertTrue(onboarding.should_offer())

    def test_global_profile_with_server_suppresses_offer(self) -> None:
        self._write_global_profile({"context7": self._server()})
        self.assertTrue(onboarding.profile_exists())
        self.assertFalse(onboarding.should_offer())

    def test_project_profile_with_server_suppresses_offer(self) -> None:
        self._write_project_profile(_PROJECT_KEY, {"context7": self._server()})
        self.assertTrue(onboarding.profile_exists())
        self.assertFalse(onboarding.should_offer())

    def test_secrets_file_alone_does_not_count(self) -> None:
        # A *.secrets.json in projects/ must never be treated as a profile.
        projects_dir = os.path.join(
            os.path.dirname(global_profile_path()), "projects"
        )
        os.makedirs(projects_dir, exist_ok=True)
        with open(
            os.path.join(projects_dir, "demoapp-xxxxxxxxxx.secrets.json"),
            "w",
            encoding="utf-8",
        ) as fh:
            json.dump({"version": 1, "servers": {"context7": {"X": "y"}}}, fh)
        self.assertFalse(onboarding.profile_exists())
        self.assertTrue(onboarding.should_offer())

    def test_malformed_profile_counts_as_existing(self) -> None:
        # An unreadable-but-present profile means "a profile exists"; do not
        # offer to seed a new one over it.
        path = global_profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("{ this is not valid json")
        self.assertTrue(onboarding.profile_exists())
        self.assertFalse(onboarding.should_offer())


class MarkSeenTests(OnboardingEnv):
    """mark_seen writes state.json outside the profile and suppresses offers."""

    def test_mark_seen_writes_state_file(self) -> None:
        onboarding.mark_seen(onboarding.DECISION_DISMISSED)
        state_file = onboarding.state_path()
        self.assertTrue(os.path.isfile(state_file))
        # Lives under ~/.config/boxa/mcp/, NOT in the profile.
        self.assertTrue(state_file.endswith("/boxa/mcp/state.json"))
        with open(state_file, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        self.assertTrue(data["seen"])
        self.assertEqual(data["decision"], "dismissed")
        self.assertTrue(onboarding.onboarding_seen())
        self.assertFalse(onboarding.should_offer())

    def test_unknown_decision_normalised_to_noop(self) -> None:
        onboarding.mark_seen("garbage")
        with open(onboarding.state_path(), "r", encoding="utf-8") as fh:
            data = json.load(fh)
        self.assertEqual(data["decision"], "noop")

    def test_deleting_profile_does_not_rearm_after_seen(self) -> None:
        # Import a server, mark seen, then delete every profile file. The marker
        # must still suppress the offer (it lives outside the profile).
        path = self._write_global_profile({"context7": self._server()})
        onboarding.mark_seen(onboarding.DECISION_IMPORTED)
        os.remove(path)
        self.assertFalse(onboarding.profile_exists())  # profile gone
        self.assertTrue(onboarding.onboarding_seen())  # marker remains
        self.assertFalse(onboarding.should_offer())  # still not offered

    def test_malformed_state_degrades_to_not_seen(self) -> None:
        os.makedirs(os.path.dirname(onboarding.state_path()), exist_ok=True)
        with open(onboarding.state_path(), "w", encoding="utf-8") as fh:
            fh.write("not json at all")
        # A corrupt marker must not crash; it degrades to "not seen".
        self.assertFalse(onboarding.onboarding_seen())
        self.assertTrue(onboarding.should_offer())

    def test_rearm_clears_seen_marker(self) -> None:
        # rearm() un-suppresses a dismissed offer so doctor --fix can re-offer.
        onboarding.mark_seen(onboarding.DECISION_DISMISSED)
        self.assertTrue(onboarding.onboarding_seen())
        self.assertFalse(onboarding.should_offer())
        onboarding.rearm()
        self.assertFalse(onboarding.onboarding_seen())
        self.assertTrue(onboarding.should_offer())

    def test_rearm_is_noop_when_unset(self) -> None:
        # No marker yet: rearm must not crash and leaves the offer eligible.
        onboarding.rearm()
        self.assertFalse(onboarding.onboarding_seen())
        self.assertTrue(onboarding.should_offer())

    def test_rearm_does_not_force_offer_over_profile(self) -> None:
        # A real profile still suppresses the offer even after rearm.
        self._write_global_profile({"context7": self._server()})
        onboarding.mark_seen(onboarding.DECISION_IMPORTED)
        onboarding.rearm()
        self.assertFalse(onboarding.onboarding_seen())
        self.assertTrue(onboarding.profile_exists())
        self.assertFalse(onboarding.should_offer())


class StatusDictTests(OnboardingEnv):
    """status_dict() exposes the booleans the shell hook branches on."""

    def test_status_fresh(self) -> None:
        d = onboarding.status_dict()
        self.assertTrue(d["shouldOffer"])
        self.assertFalse(d["profileExists"])
        self.assertFalse(d["seen"])
        self.assertEqual(d["decision"], "")

    def test_status_after_seen(self) -> None:
        onboarding.mark_seen(onboarding.DECISION_IMPORTED)
        d = onboarding.status_dict()
        self.assertFalse(d["shouldOffer"])
        self.assertTrue(d["seen"])
        self.assertEqual(d["decision"], "imported")

    def test_text_blocks_present_and_secret_free(self) -> None:
        for which in ("offer", "followup", "reminder"):
            text = {
                "offer": onboarding.offer_text,
                "followup": onboarding.followup_text,
                "reminder": onboarding.reminder_text,
            }[which]()
            self.assertIn("boxa mcp", text)
            # No credential-shaped content in any onboarding string.
            self.assertNotIn("sk-", text)


class HookEnv(unittest.TestCase):
    """Drive the shell hook end-to-end against the real Python core."""

    def setUp(self) -> None:
        if not os.access(_HOOK, os.X_OK):
            self.skipTest("ensure-mcp-onboarding.sh not executable")
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self.xdg = os.path.join(self.home, ".config")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, *args: str) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env["HOME"] = self.home
        env["XDG_CONFIG_HOME"] = self.xdg
        # Ensure the hook's `python3 -m mcp.cli` resolves the package even if the
        # caller's PYTHONPATH did not include scripts/.
        scripts = os.path.join(_REPO_ROOT, "scripts")
        env["PYTHONPATH"] = scripts + (
            os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else ""
        )
        return subprocess.run(
            [_HOOK, *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
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
        # Eligible (fresh) + forced non-interactive: print the follow-up command,
        # NEVER prompt, and leave the marker UNSET so a later interactive update
        # can still offer.
        res = self._run("--non-interactive")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("boxa mcp import", res.stdout)
        self.assertNotIn("[Y/n]", res.stdout)
        self.assertEqual(self._state(), {})  # marker untouched

    def test_noninteractive_quiet_eligible_still_prints_followup(self) -> None:
        # --quiet-if-noop only silences the not-eligible reminder; an eligible
        # non-interactive run still surfaces the follow-up so the user learns of
        # the feature once.
        res = self._run("--non-interactive", "--quiet-if-noop")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("boxa mcp import", res.stdout)

    def test_not_eligible_quiet_is_silent(self) -> None:
        # Mark seen first so the run is not eligible; --quiet-if-noop must then
        # produce no reminder output.
        env = dict(os.environ)
        env["HOME"] = self.home
        env["XDG_CONFIG_HOME"] = self.xdg
        scripts = os.path.join(_REPO_ROOT, "scripts")
        env["PYTHONPATH"] = scripts
        subprocess.run(
            [sys.executable, "-m", "mcp.cli", "onboarding-mark-seen", "dismissed"],
            env=env,
            check=True,
            cwd=_REPO_ROOT,
        )
        res = self._run("--non-interactive", "--quiet-if-noop")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(res.stdout.strip(), "")

    def test_not_eligible_loud_prints_reminder(self) -> None:
        # Seen + no --quiet-if-noop: a short reminder, never a prompt.
        env = dict(os.environ)
        env["HOME"] = self.home
        env["XDG_CONFIG_HOME"] = self.xdg
        scripts = os.path.join(_REPO_ROOT, "scripts")
        env["PYTHONPATH"] = scripts
        subprocess.run(
            [sys.executable, "-m", "mcp.cli", "onboarding-mark-seen", "imported"],
            env=env,
            check=True,
            cwd=_REPO_ROOT,
        )
        res = self._run("--non-interactive")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("boxa mcp import", res.stdout)
        self.assertNotIn("[Y/n]", res.stdout)


if __name__ == "__main__":
    unittest.main()
