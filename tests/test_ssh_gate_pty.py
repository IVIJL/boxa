"""Real-PTY coverage for SSH gate key restoration and legacy migration."""

from __future__ import annotations

import hashlib
import os
import pty
import re
import select
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "docker-run.sh")


class SshGatePtyTest(unittest.TestCase):
    def test_explicit_project_on_materializes_default_persona_once(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            project = os.path.join(home, "project")
            ssh_dir = os.path.join(home, ".ssh")
            fake_bin = os.path.join(home, "bin")
            config_dir = os.path.join(home, ".config", "boxa")
            persona_dir = os.path.join(config_dir, "forge", "identities")
            os.makedirs(project)
            os.makedirs(ssh_dir)
            os.makedirs(fake_bin)
            os.makedirs(persona_dir)

            key_path = os.path.join(ssh_dir, "id_default_persona")
            passphrase = "default-persona-passphrase"
            subprocess.run(
                [
                    "ssh-keygen",
                    "-q",
                    "-t",
                    "ed25519",
                    "-N",
                    passphrase,
                    "-f",
                    key_path,
                ],
                check=True,
                timeout=10,
            )
            ssh_conf = os.path.join(config_dir, "ssh.conf")
            forge_conf = os.path.join(config_dir, "forge.conf")
            registry = os.path.join(config_dir, "ssh-key-registry")
            with open(ssh_conf, "w", encoding="utf-8") as fh:
                fh.write(f"gate = off\n[{project}]\ngate = on\n")
            with open(forge_conf, "w", encoding="utf-8") as fh:
                fh.write("forge = on\nidentity = default-persona\n")
            with open(
                os.path.join(persona_dir, "default-persona"),
                "w",
                encoding="utf-8",
            ) as fh:
                fh.write(
                    "version=2\n"
                    "name=default-persona\n"
                    "kind=mine\n"
                    f"key={key_path}\n"
                    "github_created_at=1\n"
                    "github_username=persona-user\n"
                    "github_token=token\n"
                    "gitlab_created_at=\n"
                    "gitlab_host=\n"
                    "gitlab_username=\n"
                    "gitlab_token=\n"
                )
            self._write_fake_docker(fake_bin)

            env = dict(os.environ)
            env.update(
                HOME=home,
                PATH=f"{fake_bin}:{env['PATH']}",
                BOXA_SSH_CONF=ssh_conf,
                BOXA_FORGE_CONF=forge_conf,
                BOXA_FORGE_DIR=os.path.join(config_dir, "forge"),
                BOXA_SSH_KEY_REGISTRY=registry,
                BOXA_SSH_AGENTS_DIR=os.path.join(config_dir, "ssh-agents"),
            )
            self._clear_agent_environment(env)
            self.addCleanup(self._stop_project_agent, env)

            first = self._run_pty(
                project,
                env,
                [
                    (
                        f"Enter passphrase for {key_path}:".encode(),
                        passphrase.encode() + b"\n",
                    )
                ],
                ["bash", CLI, project],
            )
            self.assertEqual(first.count("Enter passphrase for"), 1, first)
            self.assertIn(
                "per-project ssh-agent running (persona 'default-persona' keys: SHA256:",
                first,
            )
            with open(registry, encoding="utf-8") as fh:
                self.assertIn(f"key = {key_path}", fh.read())

            second = self._run_pty(project, env, [], ["bash", CLI, project])
            self.assertNotIn("Enter passphrase for", second)
            self.assertIn(
                "per-project ssh-agent running (persona 'default-persona' keys: SHA256:",
                second,
            )

    def test_failed_startup_reapply_stops_agent_and_retries_whole_bundle(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            project = os.path.join(home, "project")
            ssh_dir = os.path.join(home, ".ssh")
            fake_bin = os.path.join(home, "bin")
            config_dir = os.path.join(home, ".config", "boxa")
            os.makedirs(project)
            os.makedirs(ssh_dir)
            os.makedirs(fake_bin)
            os.makedirs(config_dir)

            passphrase = "retry-bundle-passphrase"
            key_paths = [
                os.path.join(ssh_dir, f"id_retry_{index}") for index in range(2)
            ]
            for key_path in key_paths:
                subprocess.run(
                    [
                        "ssh-keygen",
                        "-q",
                        "-t",
                        "ed25519",
                        "-N",
                        passphrase,
                        "-f",
                        key_path,
                    ],
                    check=True,
                    timeout=10,
                )
            conf = os.path.join(config_dir, "ssh.conf")
            registry = os.path.join(config_dir, "ssh-key-registry")
            with open(conf, "w", encoding="utf-8") as fh:
                fh.write("gate = on\n")
            with open(registry, "w", encoding="utf-8") as fh:
                fh.write(
                    f"[{project}]\nkey = {key_paths[0]}\nkey = {key_paths[1]}\n"
                )
            self._write_fake_docker(fake_bin)

            agents_dir = os.path.join(config_dir, "ssh-agents")
            env = dict(os.environ)
            env.update(
                HOME=home,
                PATH=f"{fake_bin}:{env['PATH']}",
                BOXA_SSH_CONF=conf,
                BOXA_SSH_KEY_REGISTRY=registry,
                BOXA_SSH_AGENTS_DIR=agents_dir,
            )
            self._clear_agent_environment(env)
            self.addCleanup(self._stop_project_agent, env)

            failed = self._run_pty(
                project,
                env,
                [
                    (
                        f"Enter passphrase for {key_paths[0]}:".encode(),
                        passphrase.encode() + b"\n",
                    ),
                    (f"Enter passphrase for {key_paths[1]}:".encode(), b"\x03"),
                ],
                ["bash", CLI, project],
            )
            self.assertIn("WARNING: Could not restore the Project SSH key bundle", failed)
            agent_id = hashlib.sha256(project.encode()).hexdigest()[:24]
            env_file = os.path.join(agents_dir, agent_id, "agent.env")
            with open(env_file, encoding="utf-8") as fh:
                match = re.search(r"^SSH_AGENT_PID=([0-9]+);", fh.read(), re.MULTILINE)
            self.assertIsNotNone(match)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(match.group(1)), 0)

            retry = self._run_pty(
                project,
                env,
                [
                    (
                        f"Enter passphrase for {key_paths[0]}:".encode(),
                        passphrase.encode() + b"\n",
                    ),
                    (
                        f"Enter passphrase for {key_paths[1]}:".encode(),
                        passphrase.encode() + b"\n",
                    ),
                ],
                ["bash", CLI, project],
            )
            self.assertEqual(retry.count("Enter passphrase for"), 2, retry)
            self.assertEqual(retry.count("Identity added"), 2, retry)
            self.assertIn(
                "per-project ssh-agent running (persona 'unassigned' keys: SHA256:",
                retry,
            )

    def test_failed_reapply_reports_when_project_agent_cannot_be_stopped(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            project = os.path.join(home, "project")
            ssh_dir = os.path.join(home, ".ssh")
            fake_bin = os.path.join(home, "bin")
            config_dir = os.path.join(home, ".config", "boxa")
            os.makedirs(project)
            os.makedirs(ssh_dir)
            os.makedirs(fake_bin)
            os.makedirs(config_dir)

            passphrase = "stop-failure-passphrase"
            key_paths = [
                os.path.join(ssh_dir, f"id_stop_failure_{index}")
                for index in range(2)
            ]
            for key_path in key_paths:
                subprocess.run(
                    [
                        "ssh-keygen",
                        "-q",
                        "-t",
                        "ed25519",
                        "-N",
                        passphrase,
                        "-f",
                        key_path,
                    ],
                    check=True,
                    timeout=10,
                )

            conf = os.path.join(config_dir, "ssh.conf")
            registry = os.path.join(config_dir, "ssh-key-registry")
            with open(conf, "w", encoding="utf-8") as fh:
                fh.write("gate = on\n")
            with open(registry, "w", encoding="utf-8") as fh:
                fh.write(
                    f"[{project}]\nkey = {key_paths[0]}\nkey = {key_paths[1]}\n"
                )
            self._write_fake_docker(fake_bin)

            actual_pid_file = os.path.join(home, "actual-agent.pid")
            ssh_agent = os.path.join(fake_bin, "ssh-agent")
            with open(ssh_agent, "w", encoding="utf-8") as fh:
                fh.write(
                    """#!/bin/bash
agent_output="$(PATH="${PATH#*:}" ssh-agent "$@")" || exit 1
actual_pid="$(printf '%s\\n' "$agent_output" \\
    | sed -n 's/^SSH_AGENT_PID=\\([0-9][0-9]*\\);.*/\\1/p')"
printf '%s\\n' "$actual_pid" > "$BOXA_TEST_ACTUAL_AGENT_PID_FILE"
printf '%s\\n' "$agent_output" \\
    | sed 's/^SSH_AGENT_PID=[0-9][0-9]*;/SSH_AGENT_PID=99999999;/'
"""
                )
            os.chmod(ssh_agent, 0o755)

            agents_dir = os.path.join(config_dir, "ssh-agents")
            env = dict(os.environ)
            env.update(
                HOME=home,
                PATH=f"{fake_bin}:{env['PATH']}",
                BOXA_SSH_CONF=conf,
                BOXA_SSH_KEY_REGISTRY=registry,
                BOXA_SSH_AGENTS_DIR=agents_dir,
                BOXA_TEST_ACTUAL_AGENT_PID_FILE=actual_pid_file,
            )
            self._clear_agent_environment(env)

            try:
                failed = self._run_pty(
                    project,
                    env,
                    [
                        (
                            f"Enter passphrase for {key_paths[0]}:".encode(),
                            passphrase.encode() + b"\n",
                        ),
                        (
                            f"Enter passphrase for {key_paths[1]}:".encode(),
                            b"\x03",
                        ),
                    ],
                    ["bash", CLI, project],
                )
                self.assertIn(
                    "per-project ssh-agent could not be stopped", failed
                )
                self.assertIn("partial, unreliable state", failed)
                self.assertNotIn("next boxa start will retry", failed)
                self.assertIn(
                    "SSH: gate on; per-project ssh-agent key restore failed; "
                    "ssh-agent could not be stopped",
                    failed,
                )

                agent_id = hashlib.sha256(project.encode()).hexdigest()[:24]
                env_file = os.path.join(agents_dir, agent_id, "agent.env")
                with open(env_file, encoding="utf-8") as fh:
                    self.assertIsNotNone(
                        re.search(r"^SSH_AGENT_PID=99999999;", fh.read(), re.M)
                    )
                with open(actual_pid_file, encoding="utf-8") as fh:
                    actual_pid = int(fh.read().strip())
                os.kill(actual_pid, 0)
            finally:
                try:
                    with open(actual_pid_file, encoding="utf-8") as fh:
                        os.kill(int(fh.read().strip()), signal.SIGTERM)
                except (FileNotFoundError, ProcessLookupError):
                    pass

    def test_interrupted_bundle_reapply_rolls_back_and_retries_whole_bundle(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            project = os.path.join(home, "project")
            ssh_dir = os.path.join(home, ".ssh")
            os.makedirs(project)
            os.makedirs(ssh_dir)
            passphrase = "bundle-passphrase"
            key_paths = [
                os.path.join(ssh_dir, f"id_bundle_{index}") for index in range(2)
            ]
            for path in key_paths:
                subprocess.run(
                    [
                        "ssh-keygen",
                        "-q",
                        "-t",
                        "ed25519",
                        "-N",
                        passphrase,
                        "-f",
                        path,
                    ],
                    check=True,
                    timeout=10,
                )

            config_dir = os.path.join(home, ".config", "boxa")
            os.makedirs(config_dir)
            registry = os.path.join(config_dir, "ssh-key-registry")
            with open(registry, "w", encoding="utf-8") as fh:
                fh.write(f"[{project}]\n")
                for path in key_paths:
                    fh.write(f"key = {path}\n")
            harness = os.path.join(home, "reapply.sh")
            with open(harness, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    f"source {ROOT!r}/lib/resources.sh\n"
                    f"source {ROOT!r}/lib/ssh.sh\n"
                    f"_boxa::ssh_reapply_registry_keys {project!r}\n"
                    "ssh-add -l\n"
                )
            os.chmod(harness, 0o700)

            env = dict(os.environ)
            env.update(
                HOME=home,
                BOXA_SSH_KEY_REGISTRY=registry,
                BOXA_SSH_AGENTS_DIR=os.path.join(config_dir, "ssh-agents"),
            )
            for name in ("SSH_AUTH_SOCK", "SSH_AGENT_PID"):
                env.pop(name, None)
            self.addCleanup(self._stop_project_agent, env)

            interrupted = self._run_pty(
                project,
                env,
                [
                    (
                        f"Enter passphrase for {key_paths[0]}:".encode(),
                        passphrase.encode() + b"\n",
                    ),
                    (f"Enter passphrase for {key_paths[1]}:".encode(), b"\x03"),
                ],
                ["bash", harness],
                expected_returncode=None,
            )
            self.assertIn("Identity added", interrupted)

            state = subprocess.run(
                [
                    "bash",
                    "-c",
                    f"source {ROOT!r}/lib/resources.sh; source {ROOT!r}/lib/ssh.sh; "
                    f"_boxa::ssh_resolve_project_agent {project!r}; ssh-add -l",
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(state.returncode, 1, state.stdout + state.stderr)

            retry = self._run_pty(
                project,
                env,
                [
                    (
                        f"Enter passphrase for {key_paths[0]}:".encode(),
                        passphrase.encode() + b"\n",
                    ),
                    (
                        f"Enter passphrase for {key_paths[1]}:".encode(),
                        passphrase.encode() + b"\n",
                    ),
                ],
                ["bash", harness],
            )
            self.assertEqual(retry.count("Enter passphrase for"), 2, retry)
            self.assertEqual(retry.count("Identity added"), 2, retry)

    def test_container_start_lazily_prompts_for_only_its_registered_key(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            project = os.path.join(home, "project")
            untouched_project = os.path.join(home, "untouched")
            ssh_dir = os.path.join(home, ".ssh")
            fake_bin = os.path.join(home, "bin")
            os.makedirs(project)
            os.makedirs(untouched_project)
            os.makedirs(ssh_dir)
            os.makedirs(fake_bin)

            key_path = os.path.join(ssh_dir, "id_protected")
            untouched_key = os.path.join(ssh_dir, "id_untouched")
            passphrase = "project-passphrase"
            for path in (key_path, untouched_key):
                subprocess.run(
                    ["ssh-keygen", "-q", "-t", "ed25519", "-N", passphrase, "-f", path],
                    check=True,
                    timeout=10,
                )

            config_dir = os.path.join(home, ".config", "boxa")
            os.makedirs(config_dir)
            conf = os.path.join(config_dir, "ssh.conf")
            registry = os.path.join(config_dir, "ssh-key-registry")
            with open(conf, "w", encoding="utf-8") as fh:
                fh.write("gate = on\n")
            with open(registry, "w", encoding="utf-8") as fh:
                fh.write(
                    f"[{project}]\nkey = {key_path}\n"
                    f"[{untouched_project}]\nkey = {untouched_key}\n"
                )

            docker = os.path.join(fake_bin, "docker")
            with open(docker, "w", encoding="utf-8") as fh:
                fh.write(
                    """#!/bin/bash
case "${1:-}" in
    ps)
        case "$*" in
            *--filter*) ;;
            *"{{.Names}}"*) printf '%s\\n' boxa_traefik boxa_dns ;;
        esac
        ;;
    inspect)
        case "$*" in
            *"{{.State.Status}}"*) printf '%s\\n' running ;;
        esac
        ;;
    exec)
        case "$*" in
            *"stat -c %U /proc/1"*) printf '%s\\n' node ;;
        esac
        ;;
    info) printf '%s\\n' 'Docker Desktop' ;;
    network|image|run|start|restart) exit 0 ;;
    volume) exit 1 ;;
esac
exit 0
"""
                )
            os.chmod(docker, 0o755)

            agents_dir = os.path.join(config_dir, "ssh-agents")
            env = dict(os.environ)
            env.update(
                HOME=home,
                PATH=f"{fake_bin}:{env['PATH']}",
                BOXA_SSH_CONF=conf,
                BOXA_SSH_KEY_REGISTRY=registry,
                BOXA_SSH_AGENTS_DIR=agents_dir,
            )
            for name in (
                "SSH_AUTH_SOCK",
                "SSH_AGENT_PID",
                "BOXA_AGENT_SOCKET_DIR",
                "BOXA_AGENT_SOCKET",
                "BOXA_AGENT_SSH_ENV",
            ):
                env.pop(name, None)

            transcript = self._run_pty(
                project,
                env,
                [
                    (
                        f"Enter passphrase for {key_path}:".encode(),
                        passphrase.encode() + b"\n",
                    )
                ],
                ["bash", CLI, project],
            )
            self.addCleanup(self._stop_project_agent, env)
            self.assertEqual(transcript.count("Enter passphrase for"), 1, transcript)
            self.assertNotIn(untouched_key, transcript)
            self.assertIn(
                "per-project ssh-agent running (persona 'unassigned' keys: SHA256:",
                transcript,
            )

            untouched_id = hashlib.sha256(untouched_project.encode()).hexdigest()[:24]
            self.assertFalse(os.path.exists(os.path.join(agents_dir, untouched_id)))

    def test_legacy_user_repicker_is_real_and_read_is_non_mutating(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            project = os.path.join(home, "project")
            ssh_dir = os.path.join(home, ".ssh")
            os.makedirs(project)
            os.makedirs(ssh_dir)
            key_path = os.path.join(ssh_dir, "id_legacy")
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key_path],
                check=True,
                timeout=10,
            )
            conf = os.path.join(home, ".config", "boxa", "ssh.conf")
            os.makedirs(os.path.dirname(conf))
            legacy_bytes = b"agent = user\n"
            with open(conf, "wb") as fh:
                fh.write(legacy_bytes)

            env = dict(os.environ)
            env.update(
                HOME=home,
                BOXA_SSH_CONF=conf,
                BOXA_SSH_AGENTS_DIR=os.path.join(home, ".config", "boxa", "ssh-agents"),
                BOXA_PICKER_FZF="0",
            )
            for name in (
                "SSH_AUTH_SOCK",
                "SSH_AGENT_PID",
                "BOXA_AGENT_SOCKET_DIR",
                "BOXA_AGENT_SOCKET",
                "BOXA_AGENT_SSH_ENV",
            ):
                env.pop(name, None)

            transcript = self._run_pty(
                project,
                env,
                [
                    (b"Look into ~/.ssh and offer keys to add? [y/N]", b"n\n"),
                    (b"Select keys: (comma-separated", b"a\n"),
                    (b"Path to private key:", key_path.encode() + b"\n"),
                ],
            )
            self.addCleanup(self._stop_project_agent, env)
            self.assertIn(
                "Legacy user mode now uses a per-project ssh-agent", transcript
            )
            self.assertIn(
                "Per-project ssh-agent: running (persona 'unassigned' keys: SHA256:",
                transcript,
            )
            with open(conf, "rb") as fh:
                self.assertEqual(fh.read(), legacy_bytes)

            second = subprocess.run(
                ["bash", CLI, "ssh"],
                cwd=project,
                env=env,
                capture_output=True,
                text=True,
                check=True,
                timeout=10,
            )
            self.assertIn(
                "Per-project ssh-agent: running (persona 'unassigned' keys: SHA256:",
                second.stdout,
            )
            self.assertIn(
                "Legacy user mode now uses a per-project ssh-agent", second.stderr
            )
            with open(conf, "rb") as fh:
                self.assertEqual(fh.read(), legacy_bytes)

    def _run_pty(
        self,
        cwd: str,
        env: dict[str, str],
        prompts: list[tuple[bytes, bytes]],
        argv: list[str] | None = None,
        expected_returncode: int | None = 0,
    ) -> str:
        pid, master_fd = pty.fork()
        if pid == 0:
            os.chdir(cwd)
            command = argv or ["bash", CLI, "ssh"]
            os.execvpe(command[0], command, env)

        transcript = bytearray()
        prompt_index = 0
        status = None
        deadline = time.monotonic() + 20
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master_fd], [], [], 0.2)
                if ready:
                    try:
                        chunk = os.read(master_fd, 4096)
                    except OSError:
                        chunk = b""
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
                self.fail(transcript.decode(errors="replace"))
        finally:
            os.close(master_fd)
        output = transcript.decode(errors="replace")
        self.assertEqual(prompt_index, len(prompts), output)
        if expected_returncode is not None:
            self.assertEqual(
                os.waitstatus_to_exitcode(status), expected_returncode, output
            )
        return output

    @staticmethod
    def _clear_agent_environment(env: dict[str, str]) -> None:
        for name in (
            "SSH_AUTH_SOCK",
            "SSH_AGENT_PID",
            "BOXA_AGENT_SOCKET_DIR",
            "BOXA_AGENT_SOCKET",
            "BOXA_AGENT_SSH_ENV",
        ):
            env.pop(name, None)

    @staticmethod
    def _write_fake_docker(fake_bin: str) -> None:
        docker = os.path.join(fake_bin, "docker")
        with open(docker, "w", encoding="utf-8") as fh:
            fh.write(
                """#!/bin/bash
case "${1:-}" in
    ps)
        case "$*" in
            *--filter*) ;;
            *"{{.Names}}"*) printf '%s\\n' boxa_traefik boxa_dns ;;
        esac
        ;;
    inspect)
        case "$*" in
            *"{{.State.Status}}"*) printf '%s\\n' running ;;
        esac
        ;;
    exec)
        case "$*" in
            *"stat -c %U /proc/1"*) printf '%s\\n' node ;;
        esac
        ;;
    info) printf '%s\\n' 'Docker Desktop' ;;
    network|image|run|start|restart) exit 0 ;;
    volume) exit 1 ;;
esac
exit 0
"""
            )
        os.chmod(docker, 0o755)

    @staticmethod
    def _stop_project_agent(env: dict[str, str]) -> None:
        root = env["BOXA_SSH_AGENTS_DIR"]
        if not os.path.isdir(root):
            return
        for entry in os.scandir(root):
            env_file = os.path.join(entry.path, "agent.env")
            try:
                with open(env_file, encoding="utf-8") as fh:
                    match = re.search(r"^SSH_AGENT_PID=([0-9]+);", fh.read(), re.MULTILINE)
            except FileNotFoundError:
                continue
            if match is not None:
                try:
                    os.kill(int(match.group(1)), signal.SIGTERM)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    unittest.main()
