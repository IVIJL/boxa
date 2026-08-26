"""Real-PTY coverage for the eager pre-persona catalog migration."""

from __future__ import annotations

import os
import pty
import select
import signal
import tempfile
import time
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class PersonaMigrationPtyTest(unittest.TestCase):
    def _environment(self, home: str) -> dict[str, str]:
        env = dict(os.environ)
        env["HOME"] = home
        env["BOXA_PICKER_FZF"] = "0"
        env["BOXA_FORGE_DIR"] = os.path.join(home, ".config", "boxa", "forge")
        env["BOXA_FORGE_CONF"] = os.path.join(home, ".config", "boxa", "forge.conf")
        env["BOXA_AGENT_IDENTITY_DIR"] = os.path.join(
            home, ".config", "boxa", "agent-identity"
        )
        return env

    def _write_harness(self, home: str) -> str:
        harness = os.path.join(home, "persona-migration-harness.sh")
        with open(harness, "w", encoding="utf-8") as fh:
            fh.write(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                f"source {ROOT!r}/lib/resources.sh\n"
                f"source {ROOT!r}/lib/picker.sh\n"
                f"source {ROOT!r}/lib/ssh.sh\n"
                f"source {ROOT!r}/lib/forge.sh\n"
                "_boxa::forge_migrate_legacy_credentials\n"
            )
        os.chmod(harness, 0o700)
        return harness

    def _write_legacy_identity(
        self,
        env: dict[str, str],
        identity_id: str,
        kind: str,
        auth: str,
        username: str,
        host: str,
        token: str,
        created_at: int,
    ) -> None:
        store = os.path.join(env["BOXA_FORGE_DIR"], "identities")
        os.makedirs(store, mode=0o700, exist_ok=True)
        path = os.path.join(store, identity_id)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(
                "version=1\n"
                f"kind={kind}\n"
                f"auth={auth}\n"
                f"created_at={created_at}\n"
                f"username={username}\n"
                f"host={host}\n"
                f"token={token}\n"
            )
        os.chmod(path, 0o600)

    def _run_pty(
        self,
        argv: list[str],
        env: dict[str, str],
        prompts: list[tuple[bytes, bytes]],
    ) -> tuple[int, str]:
        pid, master_fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(ROOT)
                os.execvpe("bash", ["bash", *argv], env)
            except BaseException:
                os._exit(127)

        transcript = bytearray()
        prompt_index = 0
        search_start = 0
        status = None
        deadline = time.monotonic() + 30
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master_fd], [], [], 0.2)
                if ready:
                    try:
                        chunk = os.read(master_fd, 4096)
                    except OSError:
                        chunk = b""
                    if chunk:
                        transcript.extend(chunk)
                        if (
                            prompt_index < len(prompts)
                            and prompts[prompt_index][0]
                            in transcript[search_start:]
                        ):
                            os.write(master_fd, prompts[prompt_index][1])
                            prompt_index += 1
                            search_start = len(transcript)
                child, child_status = os.waitpid(pid, os.WNOHANG)
                if child == pid:
                    status = child_status
                    break
            if status is None:
                os.kill(pid, signal.SIGKILL)
                _child, status = os.waitpid(pid, 0)
                self.fail(
                    f"PTY child timed out after prompts {prompt_index}/{len(prompts)}:\n"
                    + transcript.decode(errors="replace")
                )
        finally:
            if status is None:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)
            os.close(master_fd)
        output = transcript.decode(errors="replace")
        self.assertEqual(prompt_index, len(prompts), output)
        return os.waitstatus_to_exitcode(status), output

    def test_mixed_catalog_merge_conversion_and_assignment_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            agent_key = os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "id_ed25519")
            os.makedirs(os.path.dirname(agent_key), exist_ok=True)
            self._write_legacy_identity(
                env, "github:bot", "agent", "ssh", "bot", "", "gh-agent", 100
            )
            self._write_legacy_identity(
                env,
                "gitlab:gitlab.example:bot",
                "agent",
                "ssh",
                "bot",
                "gitlab.example",
                "gl-agent",
                101,
            )
            self._write_legacy_identity(
                env, "github:mine", "mine", "token", "mine", "", "gh-mine", 102
            )
            self._write_legacy_identity(
                env,
                "gitlab:gitlab.example:corp",
                "other",
                "token",
                "corp",
                "gitlab.example",
                "gl-corp",
                103,
            )
            os.makedirs(os.path.dirname(env["BOXA_FORGE_CONF"]), exist_ok=True)
            with open(env["BOXA_FORGE_CONF"], "w", encoding="utf-8") as fh:
                fh.write(
                    "forge = on\n"
                    "github = github:bot\n"
                    "gitlab = gitlab:gitlab.example:bot\n"
                    "[/work/merged]\n"
                    "github = github:bot\n"
                    "gitlab = gitlab:gitlab.example:bot\n"
                    "[/work/conflict]\n"
                    "forge = on\n"
                    "github = github:mine\n"
                    "gitlab = gitlab:gitlab.example:corp\n"
                )

            returncode, transcript = self._run_pty(
                [harness],
                env,
                [
                    (b"Merge legacy identities 'github:bot'", b"y\n"),
                    (b"Persona name for github:bot", b"agent\n"),
                    (b"Persona name for github:mine", b"me\n"),
                    (b"Persona name for gitlab:gitlab.example:corp", b"corp\n"),
                    (b"Choose persona: (number/q)", b"2\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertNotIn("gh-agent", transcript)
            self.assertNotIn("gl-agent", transcript)
            store = os.path.join(env["BOXA_FORGE_DIR"], "identities")
            self.assertEqual(sorted(os.listdir(store)), ["agent", "corp", "me"])
            with open(os.path.join(store, "agent"), encoding="utf-8") as fh:
                merged = fh.read()
            self.assertIn("version=3", merged)
            self.assertIn("name=agent", merged)
            self.assertIn(f"key={agent_key}", merged)
            self.assertNotIn("gh-agent", merged)
            self.assertNotIn("gl-agent", merged)
            self.assertEqual(os.stat(os.path.join(store, "agent")).st_mode & 0o777, 0o600)
            token_store = os.path.join(env["BOXA_FORGE_DIR"], "tokens")
            with open(
                os.path.join(token_store, "agent.github"), encoding="utf-8"
            ) as fh:
                self.assertEqual(fh.read(), "gh-agent\n")
            with open(
                os.path.join(token_store, "agent.gitlab"), encoding="utf-8"
            ) as fh:
                self.assertEqual(fh.read(), "gl-agent\n")
            self.assertEqual(
                os.stat(os.path.join(token_store, "agent.github")).st_mode & 0o777,
                0o600,
            )
            with open(env["BOXA_FORGE_CONF"], encoding="utf-8") as fh:
                conf = fh.read()
            self.assertIn("identity = agent", conf)
            self.assertIn("[/work/merged]\nidentity = agent", conf)
            self.assertIn("[/work/conflict]\nforge = on\nidentity = corp", conf)
            self.assertNotIn("github =", conf)
            self.assertNotIn("gitlab =", conf)

    def test_interrupted_name_prompt_preserves_legacy_store(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_legacy_identity(
                env, "github:mine", "mine", "token", "mine", "", "secret", 100
            )
            returncode, transcript = self._run_pty(
                [harness],
                env,
                [(b"Persona name for github:mine", b"\x03")],
            )
            self.assertNotEqual(returncode, 0, transcript)
            self.assertTrue(
                os.path.isfile(
                    os.path.join(env["BOXA_FORGE_DIR"], "identities", "github:mine")
                )
            )
            self.assertFalse(os.path.exists(env["BOXA_FORGE_CONF"]))

    def test_explicit_none_wins_when_legacy_forge_slots_collapse(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_legacy_identity(
                env, "github:bot", "agent", "token", "bot", "", "secret", 100
            )
            os.makedirs(os.path.dirname(env["BOXA_FORGE_CONF"]), exist_ok=True)
            with open(env["BOXA_FORGE_CONF"], "w", encoding="utf-8") as fh:
                fh.write(
                    "forge = on\n"
                    "github = github:bot\n"
                    "gitlab = none\n"
                )

            returncode, transcript = self._run_pty(
                [harness],
                env,
                [(b"Persona name for github:bot", b"agent\n")],
            )

            self.assertEqual(returncode, 0, transcript)
            with open(env["BOXA_FORGE_CONF"], encoding="utf-8") as fh:
                conf = fh.read()
            self.assertIn("forge = on", conf)
            self.assertIn("identity = none", conf)
            self.assertNotIn("identity = agent", conf)

    def test_catalog_without_legacy_default_does_not_create_one(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_legacy_identity(
                env, "github:mine", "mine", "token", "mine", "", "secret", 100
            )

            returncode, transcript = self._run_pty(
                [harness],
                env,
                [(b"Persona name for github:mine", b"me\n")],
            )

            self.assertEqual(returncode, 0, transcript)
            with open(env["BOXA_FORGE_CONF"], encoding="utf-8") as fh:
                conf = fh.read()
            self.assertNotIn("identity =", conf)

    def test_legacy_root_credential_becomes_the_global_default(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            os.makedirs(env["BOXA_FORGE_DIR"], mode=0o700)
            credential = os.path.join(env["BOXA_FORGE_DIR"], "github")
            with open(credential, "w", encoding="utf-8") as fh:
                fh.write(
                    "version=1\ncreated_at=123\nusername=legacy-user\n"
                    "host=\ntoken=legacy-secret\n"
                )
            os.chmod(credential, 0o600)

            returncode, transcript = self._run_pty(
                [harness],
                env,
                [
                    (b"GitHub legacy credential kind: (number/q)", b"1\n"),
                    (b"Persona name for github:legacy-user", b"legacy\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            with open(env["BOXA_FORGE_CONF"], encoding="utf-8") as fh:
                conf = fh.read()
            self.assertIn("identity = legacy", conf)


if __name__ == "__main__":
    unittest.main()
