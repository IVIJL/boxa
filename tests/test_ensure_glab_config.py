"""Tests for glab config seeding and reconciliation."""

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

    def _run(
        self, host: str | None = None, token: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        env["HOME"] = self.home
        env["GLAB_CONFIG_DIR"] = self.config_dir
        if host is None:
            env.pop("GITLAB_HOST", None)
        else:
            env["GITLAB_HOST"] = host
        if token is None:
            env.pop("GITLAB_TOKEN", None)
        else:
            env["GITLAB_TOKEN"] = token
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

    def _write_config(self, content: bytes, mode: int = 0o600) -> None:
        os.makedirs(self.config_dir)
        with open(self.config_file, "wb") as config:
            config.write(content)
        os.chmod(self.config_file, mode)

    def _read_config(self) -> bytes:
        with open(self.config_file, "rb") as config:
            return config.read()

    def test_stub_only_config_is_replaced_by_requested_host(self) -> None:
        self._write_config(b"host: gitlab.com\nhosts:\n  gitlab.com:\n")

        result = self._run("forge.example.test")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\nhosts:\n  forge.example.test:\n",
        )

    def test_environment_token_removes_stale_token_but_keeps_host(self) -> None:
        self._write_config(
            b"host: forge.example.test\nhosts:\n"
            b"  forge.example.test:\n"
            b"    token: stale\n"
            b"    api_host: forge.example.test\n"
        )

        result = self._run("forge.example.test", token="current")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\nhosts:\n"
            b"  forge.example.test:\n"
            b"    api_host: forge.example.test\n",
        )

    def test_quoted_target_host_is_recognized_without_duplication(self) -> None:
        self._write_config(
            b"host: old.example.test\nhosts:\n"
            b'  "forge.example.test":\n'
            b"    token: stale\n"
            b"    api_host: forge.example.test\n"
        )

        result = self._run("forge.example.test", token="current")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\nhosts:\n"
            b'  "forge.example.test":\n'
            b"    api_host: forge.example.test\n",
        )

    def test_single_quoted_target_host_is_recognized_without_duplication(self) -> None:
        self._write_config(
            b"host: old.example.test\nhosts:\n"
            b"  'forge.example.test':\n"
            b"    token: stale\n"
        )

        result = self._run("forge.example.test", token="current")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\nhosts:\n"
            b"  'forge.example.test':\n",
        )

    def test_target_host_with_space_before_colon_is_not_duplicated(self) -> None:
        self._write_config(
            b"host: old.example.test\nhosts:\n"
            b"  forge.example.test   :\n"
            b"    token: stale\n"
        )

        result = self._run("forge.example.test", token="current")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\nhosts:\n"
            b"  forge.example.test   :\n",
        )

    def test_config_token_is_kept_without_environment_token(self) -> None:
        original = (
            b"host: forge.example.test\nhosts:\n"
            b"  forge.example.test:\n"
            b"    token: keep\n"
        )
        self._write_config(original)

        result = self._run("forge.example.test")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._read_config(), original)

    def test_foreign_tokenized_host_is_preserved_verbatim(self) -> None:
        foreign = (
            b"  gitlab.other.test:\n"
            b"    token: keep\n"
            b"    api_host: api.gitlab.other.test\n"
            b"    git_protocol: ssh\n"
            b"    user: octo\n"
        )
        self._write_config(
            b"host: gitlab.com\nhosts:\n"
            b"  gitlab.com:\n"
            + foreign
        )

        result = self._run("forge.example.test")

        self.assertEqual(result.returncode, 0, result.stderr)
        content = self._read_config()
        self.assertIn(foreign, content)
        self.assertEqual(content.count(foreign), 1)
        self.assertNotIn(b"  gitlab.com:\n", content)
        self.assertIn(b"  forge.example.test:\n", content)

    def test_token_keys_are_normalized_for_foreign_and_target_hosts(self) -> None:
        self._write_config(
            b"host: old.example.test\nhosts:\n"
            b"  quoted.example.test:\n"
            b'    "token": keep\n'
            b"  spaced.example.test:\n"
            b"    token : keep2\n"
            b"  forge.example.test:\n"
            b"    'token': stale\n"
            b"    api_host: forge.example.test\n"
        )

        result = self._run("forge.example.test", token="current")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\nhosts:\n"
            b"  quoted.example.test:\n"
            b'    "token": keep\n'
            b"  spaced.example.test:\n"
            b"    token : keep2\n"
            b"  forge.example.test:\n"
            b"    api_host: forge.example.test\n",
        )

    def test_environment_token_removes_only_direct_child_token(self) -> None:
        self._write_config(
            b"host: somehost\nhosts:\n"
            b"  somehost:\n"
            b"    token: outer\n"
            b"    extra:\n"
            b"      token: nested\n"
        )

        result = self._run("somehost", token="current")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: somehost\nhosts:\n"
            b"  somehost:\n"
            b"    extra:\n"
            b"      token: nested\n",
        )

    def test_foreign_host_with_nonstandard_token_indent_is_preserved(self) -> None:
        foreign = b"  gitlab.other.test:\n   token: keep\n"
        self._write_config(b"host: gitlab.com\nhosts:\n" + foreign)

        result = self._run("forge.example.test")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\nhosts:\n"
            + foreign
            + b"  forge.example.test:\n",
        )

    def test_tab_indented_hosts_are_reconciled(self) -> None:
        self._write_config(
            b"host: old.example.test\nhosts:\n"
            b"\tgitlab.other.test:\n"
            b"\t\ttoken: keep\n"
            b"\tforge.example.test:\n"
            b"\t\ttoken: stale\n"
            b"\t\tapi_host: forge.example.test\n"
        )

        result = self._run("forge.example.test", token="current")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\nhosts:\n"
            b"\tgitlab.other.test:\n"
            b"\t\ttoken: keep\n"
            b"\tforge.example.test:\n"
            b"\t\tapi_host: forge.example.test\n",
        )

    def test_new_target_uses_detected_tab_entry_indent(self) -> None:
        self._write_config(
            b"host: old.example.test\nhosts:\n"
            b"\tgitlab.other.test:\n"
            b"\t\ttoken: keep\n"
        )

        result = self._run("forge.example.test")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\nhosts:\n"
            b"\tgitlab.other.test:\n"
            b"\t\ttoken: keep\n"
            b"\tforge.example.test:\n",
        )

    def test_comments_between_entries_survive_dropped_foreign_host(self) -> None:
        self._write_config(
            b"host: gitlab.com\nhosts:\n"
            b"  tokenless.example.test:\n"
            b"    api_host: tokenless.example.test\n"
            b"  # Keep context for the following login.\n"
            b"\n"
            b"  gitlab.other.test:\n"
            b"    token: keep\n"
        )

        result = self._run("forge.example.test")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\nhosts:\n"
            b"  # Keep context for the following login.\n"
            b"\n"
            b"  gitlab.other.test:\n"
            b"    token: keep\n"
            b"  forge.example.test:\n",
        )

    def test_missing_hosts_section_is_created(self) -> None:
        self._write_config(b"host: gitlab.com\n")

        result = self._run("forge.example.test")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\nhosts:\n  forge.example.test:\n",
        )

    def test_empty_hosts_section_without_final_newline_gets_valid_entry(self) -> None:
        self._write_config(b"host: gitlab.com\nhosts:")

        result = self._run("forge.example.test")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\nhosts:\n  forge.example.test:\n",
        )

    def test_empty_flow_map_hosts_section_is_reused_idempotently(self) -> None:
        self._write_config(b"host: gitlab.com\nhosts: {} # keep this\n")

        first = self._run("forge.example.test")
        first_content = self._read_config()
        first_stat = os.stat(self.config_file)
        second = self._run("forge.example.test")
        second_stat = os.stat(self.config_file)

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(
            first_content,
            b"host: forge.example.test\nhosts: # keep this\n"
            b"  forge.example.test:\n",
        )
        self.assertEqual(
            sum(line.startswith(b"hosts:") for line in first_content.splitlines()),
            1,
        )
        self.assertEqual(self._read_config(), first_content)
        self.assertEqual(second_stat.st_ino, first_stat.st_ino)
        self.assertEqual(second_stat.st_mtime_ns, first_stat.st_mtime_ns)

    def test_inline_comment_colon_does_not_hide_target_host_or_token(self) -> None:
        self._write_config(
            b"host: old.example.test\nhosts:\n"
            b"  gitlab.example.com: # note: \n"
            b"    token: stale # rotated: \n"
            b"    api_host: gitlab.example.com\n"
        )

        result = self._run("gitlab.example.com", token="current")

        self.assertEqual(result.returncode, 0, result.stderr)
        content = self._read_config()
        self.assertEqual(
            content,
            b"host: gitlab.example.com\nhosts:\n"
            b"  gitlab.example.com: # note: \n"
            b"    api_host: gitlab.example.com\n",
        )
        self.assertEqual(content.count(b"  gitlab.example.com:"), 1)
        self.assertNotIn(b"token:", content)

    def test_non_default_top_level_keys_survive_unchanged(self) -> None:
        self._write_config(
            b"host: gitlab.com\n"
            b"git_protocol: ssh\n"
            b"check_update: false\n"
            b"editor: nvim\n"
        )

        result = self._run("forge.example.test")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._read_config(),
            b"host: forge.example.test\n"
            b"git_protocol: ssh\n"
            b"check_update: false\n"
            b"editor: nvim\n"
            b"hosts:\n"
            b"  forge.example.test:\n",
        )

    def test_second_run_is_byte_identical_without_replacing_file(self) -> None:
        self._write_config(
            b"host: gitlab.com\nhosts:\n  gitlab.com:\n", mode=0o644
        )

        first = self._run("forge.example.test")
        first_content = self._read_config()
        first_stat = os.stat(self.config_file)
        second = self._run("forge.example.test")
        second_stat = os.stat(self.config_file)

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self._read_config(), first_content)
        self.assertEqual(second_stat.st_ino, first_stat.st_ino)
        self.assertEqual(second_stat.st_mtime_ns, first_stat.st_mtime_ns)
        self.assertEqual(stat.S_IMODE(second_stat.st_mode), 0o600)

    def test_missing_gitlab_host_leaves_existing_content_and_mode_unchanged(self) -> None:
        original = b"host: existing.example\nhosts:\n  existing.example:\n"
        self._write_config(original, mode=0o644)

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._read_config(), original)
        self.assertEqual(stat.S_IMODE(os.stat(self.config_file).st_mode), 0o644)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
