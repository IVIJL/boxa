"""Real-PTY regression tests for inherited MCP secret consent."""

from __future__ import annotations

import json
import os
import pty
import select
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "scripts", "mcp-cli.sh")
SECRET_VALUE = "Bearer test123"


class McpConsentPtyTest(unittest.TestCase):
    def _environment(self, home: str) -> dict[str, str]:
        env = dict(os.environ)
        env["HOME"] = home
        env["BOXA_PICKER_FZF"] = "0"
        env.pop("CLAUDE_CONFIG_DIR", None)
        env.pop("XDG_CONFIG_HOME", None)
        return env

    def _write_source(self, home: str) -> None:
        with open(os.path.join(home, ".claude.json"), "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "mcpServers": {
                        "dozzle": {
                            "type": "http",
                            "url": "https://dozzle.example.com/mcp",
                            "headers": {"Authorization": SECRET_VALUE},
                        }
                    },
                    "projects": {},
                },
                fh,
            )

    def _secret_files_containing_value(self, home: str) -> list[str]:
        root = os.path.join(home, ".config", "boxa", "mcp")
        matches = []
        for directory, _subdirs, files in os.walk(root):
            for filename in files:
                path = os.path.join(directory, filename)
                try:
                    with open(path, encoding="utf-8") as fh:
                        content = fh.read()
                except (OSError, UnicodeError):
                    continue
                if "test123" in content:
                    matches.append(path)
        return matches

    def _run_pty(self, env: dict[str, str], consent: str) -> tuple[int, str]:
        prompts = [
            (b"Select MCP servers to import", b"1\n"),
            (b"Reimport with host values?", b"y\n"),
            (b"Switch to project?", b"n\n"),
            (
                b"Take over the value of secret header 'Authorization'",
                consent.encode() + b"\n",
            ),
        ]
        pid, master_fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(ROOT)
                os.execvpe("bash", ["bash", CLI, "import", "--apply"], env)
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
                    "PTY child timed out after prompts "
                    f"{prompt_index}/{len(prompts)}:\n"
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
        self.assertEqual(prompt_index, len(prompts), output)
        return os.waitstatus_to_exitcode(status), output

    def _run_consent_case(self, consent: str) -> tuple[str, list[str]]:
        with tempfile.TemporaryDirectory() as home:
            self._write_source(home)
            env = self._environment(home)
            stage_one = subprocess.run(
                ["bash", CLI, "import", "--apply", "--server", "dozzle"],
                cwd=ROOT,
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=30,
            )
            stage_one_output = stage_one.stdout + stage_one.stderr
            self.assertEqual(stage_one.returncode, 0, stage_one_output)
            self.assertIn("Skipped credential values", stage_one_output)
            self.assertNotIn("test123", stage_one_output)
            self.assertEqual(self._secret_files_containing_value(home), [])

            returncode, transcript = self._run_pty(env, consent)
            self.assertEqual(returncode, 0, transcript)
            self.assertIn(
                "Take over the value of secret header 'Authorization'", transcript
            )
            self.assertNotIn("test123", transcript)
            return transcript, self._secret_files_containing_value(home)

    def test_accepting_consent_stores_value_without_skip_message(self) -> None:
        transcript, stored_in = self._run_consent_case("y")

        self.assertTrue(stored_in, transcript)
        self.assertNotIn("Skipped credential values", transcript)

    def test_declining_consent_keeps_value_unstored_and_reports_skip(self) -> None:
        transcript, stored_in = self._run_consent_case("n")

        self.assertEqual(stored_in, [])
        self.assertIn("Skipped credential values", transcript)


if __name__ == "__main__":
    unittest.main()
