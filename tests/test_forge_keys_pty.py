"""Real-PTY coverage for managing several SSH keys on one persona."""

from __future__ import annotations

import hashlib
import os
import pty
import select
import signal
import stat
import subprocess
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class ForgeKeysPtyTest(unittest.TestCase):
    def _environment(self, home: str) -> dict[str, str]:
        env = dict(os.environ)
        env["HOME"] = home
        env["BOXA_PICKER_FZF"] = "0"
        env["BOXA_FORGE_DIR"] = os.path.join(home, ".config", "boxa", "forge")
        env["BOXA_FORGE_CONF"] = os.path.join(home, ".config", "boxa", "forge.conf")
        env["BOXA_SSH_CONF"] = os.path.join(home, ".config", "boxa", "ssh.conf")
        env["BOXA_SSH_KEY_REGISTRY"] = os.path.join(
            home, ".config", "boxa", "ssh-key-registry"
        )
        env["BOXA_SSH_AGENTS_DIR"] = os.path.join(
            home, ".config", "boxa", "ssh-agents"
        )
        env["BOXA_AGENT_IDENTITY_DIR"] = os.path.join(
            home, ".config", "boxa", "agent-identity"
        )
        env["BOXA_TEST_PROJECT_A"] = os.path.join(home, "project-a")
        env["BOXA_TEST_PROJECT_B"] = os.path.join(home, "project-b")
        env.pop("BOXA_AGENT_KEY", None)
        env.pop("BOXA_AGENT_KEY_POINTER", None)
        return env

    def _write_harness(self, home: str) -> str:
        harness = os.path.join(home, "forge-keys-harness.sh")
        with open(harness, "w", encoding="utf-8") as fh:
            fh.write(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                f"source {ROOT!r}/lib/resources.sh\n"
                f"source {ROOT!r}/lib/picker.sh\n"
                f"source {ROOT!r}/lib/ssh.sh\n"
                f"source {ROOT!r}/lib/forge.sh\n"
                "cleanup() {\n"
                "  local env_file=\"$BOXA_AGENT_IDENTITY_DIR/ssh-agent.env\"\n"
                "  [ ! -f \"$env_file\" ] || source \"$env_file\"\n"
                "  [ -z \"${SSH_AGENT_PID:-}\" ] || kill \"$SSH_AGENT_PID\" "
                "2>/dev/null || true\n"
                "}\n"
                "trap cleanup EXIT\n"
                "_boxa::forge_project_targets() {\n"
                "  printf '%s\\t%s\\n%s\\t%s\\n' A \"$BOXA_TEST_PROJECT_A\" "
                "B \"$BOXA_TEST_PROJECT_B\"\n"
                "}\n"
                "case \"$1\" in\n"
                "  keys) _boxa::forge_keys \"$2\" ;;\n"
                "  repopulate)\n"
                "    _boxa::ssh_reapply_registry_keys \"$2\" >/dev/null\n"
                "    ssh-add -l\n"
                "    kill \"$SSH_AGENT_PID\"\n"
                "    ;;\n"
                "esac\n"
            )
        os.chmod(harness, 0o700)
        return harness

    def _write_persona(
        self,
        env: dict[str, str],
        name: str,
        keys: list[str],
        kind: str = "agent",
    ) -> None:
        store = os.path.join(env["BOXA_FORGE_DIR"], "identities")
        os.makedirs(store, mode=0o700, exist_ok=True)
        persona = os.path.join(store, name)
        with open(persona, "w", encoding="utf-8") as fh:
            fh.write("version=2\n")
            fh.write(f"name={name}\nkind={kind}\n")
            fh.writelines(f"key={key}\n" for key in keys)
            fh.write(
                "github_created_at=1\n"
                "github_username=machine-user\n"
                "github_token=token\n"
                "gitlab_created_at=\n"
                "gitlab_host=\n"
                "gitlab_username=\n"
                "gitlab_token=\n"
            )
        os.chmod(persona, 0o600)

    def _generate_key(self, path: str, comment: str) -> None:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        subprocess.run(
            [
                "ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                comment,
                "-f",
                path,
            ],
            check=True,
            timeout=10,
        )

    def _assign_projects(self, env: dict[str, str], persona: str) -> None:
        os.makedirs(os.path.dirname(env["BOXA_FORGE_CONF"]), exist_ok=True)
        with open(env["BOXA_FORGE_CONF"], "w", encoding="utf-8") as fh:
            fh.writelines(f"[{project}]\nforge = on\nidentity = {persona}\n" for project in (env["BOXA_TEST_PROJECT_A"], env["BOXA_TEST_PROJECT_B"]))

    def _write_fake_ssh(self, home: str, env: dict[str, str]) -> None:
        fake_bin = os.path.join(home, "bin")
        os.makedirs(fake_bin, exist_ok=True)
        ssh = os.path.join(fake_bin, "ssh")
        with open(ssh, "w", encoding="utf-8") as fh:
            fh.write(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" >> \"$BOXA_TEST_SSH_LOG\"\n"
                "printf '%s\\n' 'Hi verified-user! You have successfully authenticated.' >&2\n"
                "exit 1\n"
            )
        os.chmod(ssh, 0o700)
        env["PATH"] = fake_bin + os.pathsep + env["PATH"]
        env["BOXA_TEST_SSH_LOG"] = os.path.join(home, "ssh.log")

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
            except OSError:
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
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.close(master_fd)
        output = transcript.decode(errors="replace")
        self.assertEqual(prompt_index, len(prompts), output)
        return os.waitstatus_to_exitcode(status), output

    def test_generate_adds_second_key_and_updates_every_assigned_project(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            existing = os.path.join(home, "existing")
            self._generate_key(existing, "existing@test")
            self._write_persona(env, "agent", [existing])
            self._assign_projects(env, "agent")

            returncode, transcript = self._run_pty(
                [harness, "keys", "agent"],
                env,
                [
                    (b"Persona key action: (number/q)", b"1\n"),
                    (b"Key verification: (number/q)", b"2\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertIn("one SSH key authenticates exactly one GitHub account", transcript)
            self.assertIn(
                "Generate a new SSH key for this agent persona", transcript
            )
            self.assertIn(
                "Generated and attached SSH key for persona agent:", transcript
            )
            self.assertNotIn("Agent key", transcript)
            persona = os.path.join(env["BOXA_FORGE_DIR"], "identities", "agent")
            with open(persona, encoding="utf-8") as fh:
                attached = [
                    line.removeprefix("key=").strip()
                    for line in fh
                    if line.startswith("key=")
                ]
            self.assertEqual(len(attached), 2)
            generated = attached[1]
            self.assertTrue(os.path.isfile(generated))
            self.assertTrue(os.path.isfile(generated + ".pub"))
            with open(env["BOXA_SSH_KEY_REGISTRY"], encoding="utf-8") as fh:
                registry = fh.read()
            for project in (env["BOXA_TEST_PROJECT_A"], env["BOXA_TEST_PROJECT_B"]):
                section = registry.split(f"[{project}]\n", 1)[1].split("\n[", 1)[0]
                self.assertIn(f"key = {existing}", section)
                self.assertIn(f"key = {generated}", section)

    def test_generate_uses_persona_label_for_mine_kind(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_persona(env, "mine", [], kind="mine")

            returncode, transcript = self._run_pty(
                [harness, "keys", "mine"],
                env,
                [
                    (b"Persona key action: (number/q)", b"1\n"),
                    (b"Key verification: (number/q)", b"2\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertIn("Generate a new SSH key for this persona", transcript)
            self.assertNotIn(
                "Generate a new SSH key for this agent persona", transcript
            )
            self.assertIn(
                "Generated and attached SSH key for persona mine:", transcript
            )
            self.assertNotIn("Agent key", transcript)

    def test_adopt_uses_consent_picker_without_reading_private_material(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_persona(env, "agent", [])
            adopted = os.path.join(home, ".ssh", "id_adopted")
            self._generate_key(adopted, "adopted@test")
            os.remove(adopted + ".pub")
            with open(adopted, "rb") as fh:
                before = hashlib.sha256(fh.read()).hexdigest()
            os.chmod(adopted, stat.S_IRUSR)

            returncode, transcript = self._run_pty(
                [harness, "keys", "agent"],
                env,
                [
                    (b"Persona key action: (number/q)", b"2\n"),
                    (b"Look into ~/.ssh and offer keys to add? [y/N]", b"y\n"),
                    (b"Adopt SSH keys: (comma-separated: numbers and a/q)", b"1\n"),
                    (b"Key verification: (number/q)", b"2\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertIn(
                f"{adopted} (no .pub — fingerprint unavailable)", transcript
            )
            with open(adopted, "rb") as fh:
                self.assertEqual(hashlib.sha256(fh.read()).hexdigest(), before)
            self.assertEqual(stat.S_IMODE(os.stat(adopted).st_mode), stat.S_IRUSR)
            persona = os.path.join(env["BOXA_FORGE_DIR"], "identities", "agent")
            with open(persona, encoding="utf-8") as fh:
                self.assertIn(f"key={adopted}\n", fh.readlines())
            with open(env["BOXA_SSH_KEY_REGISTRY"], encoding="utf-8") as fh:
                self.assertIn(f"key = {adopted}\n", fh.readlines())
            self.assertFalse(
                os.path.exists(os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "key-path"))
            )

    def test_detach_keeps_file_and_registry_history_but_repopulates_without_key(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            first = os.path.join(home, "first")
            second = os.path.join(home, "second")
            self._generate_key(first, "first@test")
            self._generate_key(second, "second@test")
            self._write_persona(env, "agent", [first, second])
            self._assign_projects(env, "agent")
            os.makedirs(os.path.dirname(env["BOXA_SSH_KEY_REGISTRY"]), exist_ok=True)
            with open(env["BOXA_SSH_KEY_REGISTRY"], "w", encoding="utf-8") as fh:
                fh.write(f"[/.boxa-key-history]\nkey = {first}\nkey = {second}\n")

            returncode, transcript = self._run_pty(
                [harness, "keys", "agent"],
                env,
                [
                    (b"Persona key action: (number/q)", b"3\n"),
                    (b"Detach an SSH key: (number/q)", b"1\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertTrue(os.path.isfile(first))
            with open(env["BOXA_SSH_KEY_REGISTRY"], encoding="utf-8") as fh:
                registry = fh.read()
            history = registry.split("[/.boxa-key-history]\n", 1)[1].split("\n[", 1)[0]
            self.assertIn(f"key = {first}", history)
            for project in (env["BOXA_TEST_PROJECT_A"], env["BOXA_TEST_PROJECT_B"]):
                section = registry.split(f"[{project}]\n", 1)[1].split("\n[", 1)[0]
                self.assertNotIn(f"key = {first}", section)
                self.assertIn(f"key = {second}", section)
            expected_fingerprint = subprocess.run(
                ["ssh-keygen", "-lf", second + ".pub"],
                capture_output=True,
                text=True,
                check=True,
                timeout=10,
            ).stdout.split()[1]
            for project in (env["BOXA_TEST_PROJECT_A"], env["BOXA_TEST_PROJECT_B"]):
                repopulated = subprocess.run(
                    ["bash", harness, "repopulate", project],
                    cwd=ROOT,
                    env=env,
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=10,
                )
                self.assertIn(expected_fingerprint, repopulated.stdout)
                self.assertEqual(
                    len([line for line in repopulated.stdout.splitlines() if line]),
                    1,
                )

    def test_verify_pins_the_selected_key_and_reports_github_account(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            first = os.path.join(home, "first")
            second = os.path.join(home, "second")
            self._generate_key(first, "first@test")
            self._generate_key(second, "second@test")
            self._write_persona(env, "agent", [first, second])
            self._write_fake_ssh(home, env)

            returncode, transcript = self._run_pty(
                [harness, "keys", "agent"],
                env,
                [
                    (b"Persona key action: (number/q)", b"4\n"),
                    (b"Verify an SSH key: (number/q)", b"2\n"),
                    (b"Key verification host: (number/q)", b"1\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertIn("authenticates as: verified-user", transcript)
            with open(env["BOXA_TEST_SSH_LOG"], encoding="utf-8") as fh:
                args = fh.read()
            self.assertIn(f"-i {second}", args)
            self.assertNotIn(f"-i {first}", args)


if __name__ == "__main__":
    unittest.main()
