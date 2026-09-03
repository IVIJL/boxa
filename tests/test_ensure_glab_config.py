"""Tests for minimal glab config seeding."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO_ROOT, "scripts", "ensure-glab-config.sh")


class EnsureGlabConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self.config_dir = os.path.join(self.home, "glab-config")
        self.config_file = os.path.join(self.config_dir, "config.yml")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run(self, host: str | None = None) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        env["HOME"] = self.home
        env["GLAB_CONFIG_DIR"] = self.config_dir
        if host is None:
            env.pop("GITLAB_HOST", None)
        else:
            env["GITLAB_HOST"] = host
        return subprocess.run(
            ["bash", SCRIPT],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_fresh_config_contains_only_requested_host_with_secure_mode(self) -> None:
        host = "gitlab.example.test"

        result = self._run(host)

        self.assertEqual(result.returncode, 0, result.stderr)
        with open(self.config_file, "r", encoding="utf-8") as config:
            content = config.read()
        self.assertEqual(content, f"host: {host}\nhosts:\n  {host}:\n")
        self.assertNotIn("gitlab.com", content)
        self.assertNotIn("token:", content)
        self.assertEqual(stat.S_IMODE(os.stat(self.config_file).st_mode), 0o600)

    def test_missing_gitlab_host_creates_no_config(self) -> None:
        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(os.path.exists(self.config_file))

    def test_existing_config_is_byte_identical_after_rerun(self) -> None:
        original = b"host: existing.example\nhosts:\n  existing.example:\n    token: keep\n"
        os.makedirs(self.config_dir)
        with open(self.config_file, "wb") as config:
            config.write(original)

        result = self._run("replacement.example.test")

        self.assertEqual(result.returncode, 0, result.stderr)
        with open(self.config_file, "rb") as config:
            self.assertEqual(config.read(), original)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
