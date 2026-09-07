"""Real-PTY tests for Agent identity onboarding choices."""

from __future__ import annotations

import hashlib
import os
import pty
import re
import select
import signal
import stat
import subprocess
import tempfile
import time
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(ROOT, "scripts", "ensure-agent-identity.sh")


class AgentIdentityPtyTest(unittest.TestCase):
    def _register_agent_identity_cleanup(self, env: dict[str, str]) -> None:
        env_file = os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "ssh-agent.env")
        try:
            with open(env_file, encoding="utf-8") as fh:
                match = re.search(r"^SSH_AGENT_PID=([0-9]+);", fh.read(), re.MULTILINE)
        except FileNotFoundError:
            return
        if match is not None:
            self.addCleanup(self._stop_pid, int(match.group(1)))

    @staticmethod
    def _stop_pid(pid: int) -> None:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    def _environment(self, home: str) -> dict[str, str]:
        env = dict(os.environ)
        env["HOME"] = home
        env["BOXA_PICKER_FZF"] = "0"
        env["BOXA_AGENT_IDENTITY_DIR"] = os.path.join(
            home, ".config", "boxa", "agent-identity"
        )
        env["BOXA_AGENT_IDENTITY_MARKER"] = os.path.join(
            home, ".config", "boxa", "agent-identity-seen"
        )
        env["BOXA_SSH_CONF"] = os.path.join(home, ".config", "boxa", "ssh.conf")
        env["BOXA_FORGE_CONF"] = os.path.join(
            home, ".config", "boxa", "forge.conf"
        )
        env.pop("BOXA_AGENT_KEY", None)
        env.pop("BOXA_AGENT_KEY_POINTER", None)
        env.pop("XDG_CONFIG_HOME", None)
        return env

    def _run_pty(
        self, env: dict[str, str], prompts: list[tuple[bytes, bytes]]
    ) -> tuple[int, str]:
        pid, master_fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(ROOT)
                os.execvpe("bash", ["bash", HOOK, "offer", "--interactive"], env)
            except BaseException:
                os._exit(127)

        transcript = bytearray()
        prompt_index = 0
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
                            and prompts[prompt_index][0] in transcript
                        ):
                            os.write(master_fd, prompts[prompt_index][1])
                            prompt_index += 1

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

            while select.select([master_fd], [], [], 0)[0]:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                transcript.extend(chunk)
        finally:
            if status is None:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)
            os.close(master_fd)

        output = transcript.decode(errors="replace")
        self._register_agent_identity_cleanup(env)
        self.assertEqual(prompt_index, len(prompts), output)
        return os.waitstatus_to_exitcode(status), output

    def _probe(self, env: dict[str, str]) -> str:
        result = subprocess.run(
            ["bash", HOOK, "probe"],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        )
        return result.stdout.strip()

    def test_hook_defines_allowlist_constants_for_the_forge_dashboard(self) -> None:
        # The wizard hands over to the forge dashboard, whose Allowlist offer
        # reads ALLOWLIST_HOST_FILE; a hook that omits lib/allowlist.sh dies
        # under set -u right after the token is verified.
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$0" -h >/dev/null; '
                    'printf "%s\\n" "${ALLOWLIST_HOST_FILE:?unbound}"',
                    HOOK,
                ],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(
                result.stdout.strip().endswith("allowed-domains.conf"),
                result.stdout,
            )

    def test_default_no_dismisses_with_real_tty(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            returncode, transcript = self._run_pty(
                env, [(b"signing authority through its dedicated socket? [y/N]", b"\n")]
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertEqual(self._probe(env), "declined")
            self.assertIn("boxa doctor --fix agent-identity", transcript)

    def test_generate_new_configures_agent_usage_with_real_picker(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            returncode, transcript = self._run_pty(
                env,
                [
                    (b"signing authority through its dedicated socket? [y/N]", b"y\n"),
                    (b"Agent key setup: (number/q)", b"1\n"),
                    (b"Persona name:", b"\x04"),
                ],
            )

            self.assertEqual(returncode, 1, transcript)
            key_path = os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "id_ed25519")
            self.assertTrue(os.path.isfile(key_path), transcript)
            self.assertTrue(os.path.isfile(key_path + ".pub"), transcript)
            self.assertIn(
                "Agent key setup: Generate a new Agent key (recommended)",
                transcript,
            )
            self.assertEqual(self._probe(env), "ok")
            with open(env["BOXA_SSH_CONF"], encoding="utf-8") as fh:
                self.assertIn("gate = on", fh.read())

    def test_adopt_existing_registers_path_without_touching_private_key(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            ssh_dir = os.path.join(home, ".ssh")
            os.makedirs(ssh_dir)
            key_path = os.path.join(ssh_dir, "id_existing")
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "existing@test", "-f", key_path],
                check=True,
                timeout=10,
            )
            with open(key_path, "rb") as fh:
                before_hash = hashlib.sha256(fh.read()).hexdigest()
            os.chmod(key_path, stat.S_IRUSR)

            returncode, transcript = self._run_pty(
                env,
                [
                    (b"signing authority through its dedicated socket? [y/N]", b"y\n"),
                    (b"Agent key setup: (number/q)", b"2\n"),
                    (b"Select the Agent key: (number/q)", b"1\n"),
                    (b"Persona name:", b"\x04"),
                ],
            )

            self.assertEqual(returncode, 1, transcript)
            pointer = os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "key-path")
            with open(pointer, encoding="utf-8") as fh:
                self.assertEqual(fh.read(), key_path + "\n")
            self.assertFalse(
                os.path.exists(os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "id_ed25519"))
            )
            self.assertEqual(
                stat.S_IMODE(os.stat(key_path).st_mode), stat.S_IRUSR
            )
            with open(key_path, "rb") as fh:
                after_hash = hashlib.sha256(fh.read()).hexdigest()
            self.assertEqual(after_hash, before_hash)
            self.assertEqual(self._probe(env), "ok")
            self.assertIn("existing@test", transcript)

    def test_adopt_existing_rejects_mismatched_public_half_with_real_picker(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            ssh_dir = os.path.join(home, ".ssh")
            os.makedirs(ssh_dir)
            key_path = os.path.join(ssh_dir, "id_existing")
            other_path = os.path.join(home, "other")
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key_path],
                check=True,
                timeout=10,
            )
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", other_path],
                check=True,
                timeout=10,
            )
            with open(other_path + ".pub", "rb") as source:
                mismatched_public = source.read()
            with open(key_path + ".pub", "wb") as target:
                target.write(mismatched_public)

            returncode, transcript = self._run_pty(
                env,
                [
                    (b"signing authority through its dedicated socket? [y/N]", b"y\n"),
                    (b"Agent key setup: (number/q)", b"2\n"),
                    (b"Select the Agent key: (number/q)", b"1\n"),
                ],
            )

            self.assertEqual(returncode, 1, transcript)
            self.assertIn("private and public halves do not match", transcript)
            pointer = os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "key-path")
            self.assertFalse(os.path.exists(pointer))

    def test_skip_marks_seen_without_creating_key_or_usage(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            returncode, transcript = self._run_pty(
                env,
                [
                    (b"signing authority through its dedicated socket? [y/N]", b"y\n"),
                    (b"Agent key setup: (number/q)", b"3\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertEqual(self._probe(env), "declined")
            self.assertFalse(os.path.exists(env["BOXA_SSH_CONF"]))
            self.assertFalse(os.path.exists(env["BOXA_AGENT_IDENTITY_DIR"]))


if __name__ == "__main__":
    unittest.main()
