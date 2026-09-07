"""Real-PTY tests for persona registration and consent-first token import."""

from __future__ import annotations

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


class ForgeChecklistPtyTest(unittest.TestCase):
    def _environment(self, home: str) -> dict[str, str]:
        env = dict(os.environ)
        env["HOME"] = home
        env["BOXA_PICKER_FZF"] = "0"
        env["BOXA_FORGE_DIR"] = os.path.join(home, ".config", "boxa", "forge")
        env["BOXA_AGENT_IDENTITY_DIR"] = os.path.join(
            home, ".config", "boxa", "agent-identity"
        )
        env["BOXA_AGENT_SOCKET_DIR"] = os.path.join(
            env["BOXA_AGENT_IDENTITY_DIR"], "ssh-agent"
        )
        env["BOXA_AGENT_SOCKET"] = os.path.join(
            env["BOXA_AGENT_SOCKET_DIR"], "agent.sock"
        )
        env["BOXA_AGENT_SSH_ENV"] = os.path.join(
            env["BOXA_AGENT_IDENTITY_DIR"], "ssh-agent.env"
        )
        env["GH_CONFIG_DIR"] = os.path.join(home, ".config", "gh")
        env["GLAB_CONFIG_DIR"] = os.path.join(home, ".config", "glab-cli")
        env.pop("GH_TOKEN", None)
        env.pop("GITLAB_TOKEN", None)
        env.pop("GITLAB_HOST", None)
        return env

    def _write_harness(self, home: str) -> str:
        harness = os.path.join(home, "forge-harness.sh")
        with open(harness, "w", encoding="utf-8") as fh:
            fh.write(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                f"source {ROOT!r}/lib/resources.sh\n"
                f"source {ROOT!r}/lib/picker.sh\n"
                f"source {ROOT!r}/lib/ssh.sh\n"
                f"source {ROOT!r}/lib/allowlist.sh\n"
                f"source {ROOT!r}/lib/forge.sh\n"
                'if [ "${BOXA_TEST_SSH_CONF_FAIL:-}" = 1 ]; then\n'
                '  _boxa::write_ssh_conf() { return 1; }\n'
                'fi\n'
                '_boxa::forge_project_targets() {\n'
                '  printf "%s\\t%s\\n%s\\t%s\\n" "Current Project" '
                '"$BOXA_TEST_CURRENT_PROJECT" "Other Project" '
                '"$BOXA_TEST_OTHER_PROJECT"\n'
                '}\n'
                'case "$1" in\n'
                '  add) _boxa::forge_add "${2:-}" ;;\n'
                '  checklist) _boxa::forge_checklist "$2" ;;\n'
                '  adopt) _boxa::forge_adopt_existing "$2" ;;\n'
                "  migrate) _boxa::forge_migrate_legacy_credentials ;;\n"
                '  set) _boxa::forge_set "$2" ;;\n'
                '  guided) _boxa::forge_guided_setup "${2:-}" '
                '"$BOXA_TEST_CURRENT_PROJECT" ;;\n'
                '  dashboard) _boxa::forge_dashboard '
                '"$BOXA_TEST_CURRENT_PROJECT" ;;\n'
                '  use) _boxa::forge_use "${2:-}" '
                '"$BOXA_TEST_CURRENT_PROJECT" ;;\n'
                '  gate-on) _boxa::forge_set_gate project '
                '"$BOXA_TEST_CURRENT_PROJECT" on ;;\n'
                '  default) _boxa::forge_default "$2" ;;\n'
                "  list) _boxa::forge_list ;;\n"
                "esac\n"
            )
        os.chmod(harness, 0o700)
        return harness

    def _write_fake_forges(self, home: str, env: dict[str, str]) -> None:
        fake_bin = os.path.join(home, "bin")
        os.makedirs(fake_bin)
        gh = os.path.join(fake_bin, "gh")
        with open(gh, "w", encoding="utf-8") as fh:
            fh.write(
                "#!/usr/bin/env bash\n"
                'if [ "${1:-}" = auth ] && [ "${2:-}" = token ]; then\n'
                '  printf "%s\\n" "$BOXA_TEST_GH_HOST_TOKEN"\n'
                "  exit 0\n"
                "fi\n"
                'count="$(cat "$BOXA_TEST_GH_COUNT" 2>/dev/null || printf 0)"\n'
                "count=$((count + 1))\n"
                'printf "%s\\n" "$count" > "$BOXA_TEST_GH_COUNT"\n'
                '[ "$count" -gt "${BOXA_TEST_GH_FAILS:-0}" ] || exit 1\n'
                '[ "${GH_TOKEN:-}" = "$BOXA_TEST_GH_EXPECTED" ] || exit 9\n'
                "printf '%s\\n' '{\"login\":\"machine-user\"}'\n"
            )
        glab = os.path.join(fake_bin, "glab")
        with open(glab, "w", encoding="utf-8") as fh:
            fh.write(
                "#!/usr/bin/env bash\n"
                'if [ "${1:-}" = config ]; then printf "%s\\n" gitlab.example; exit 0; fi\n'
                'if [ "${1:-}" = auth ]; then printf "%s\\n" "$BOXA_TEST_GLAB_HOST_TOKEN"; exit 0; fi\n'
                '[ "${GITLAB_TOKEN:-}" = "$BOXA_TEST_GLAB_EXPECTED" ] || exit 9\n'
                '[ "${GITLAB_HOST:-}" = gitlab.example ] || exit 8\n'
                "printf '%s\\n' '{\"username\":\"service-account\"}'\n"
            )
        ssh = os.path.join(fake_bin, "ssh")
        with open(ssh, "w", encoding="utf-8") as fh:
            fh.write(
                "#!/usr/bin/env bash\n"
                '[ -z "${BOXA_TEST_SSH_FAIL:-}" ] || exit 255\n'
                '[ "$SSH_AUTH_SOCK" = "$BOXA_AGENT_SOCKET" ] '
                '|| [ "$SSH_AUTH_SOCK" = none ] || exit 9\n'
                'case "$*" in\n'
                '  *github.com*) printf "%s\\n" "Hi machine-user! You have successfully authenticated." >&2; exit 1 ;;\n'
                '  *) printf "%s\\n" "Welcome to GitLab, @service-account!" >&2; exit 0 ;;\n'
                "esac\n"
            )
        fzf = os.path.join(fake_bin, "fzf")
        with open(fzf, "w", encoding="utf-8") as fh:
            fh.write(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "header=\n"
                "for arg in \"$@\"; do\n"
                "  case \"$arg\" in --header=*) header=${arg#--header=} ;; esac\n"
                "done\n"
                "[ -z \"$header\" ] || printf '%s\\n' \"$header\" >&2\n"
                "IFS= read -r selected\n"
                "# Mirror fzf --print-query: the (empty) query line comes first.\n"
                "printf '\\n%s\\n' \"$selected\"\n"
            )
        os.chmod(gh, 0o700)
        os.chmod(glab, 0o700)
        os.chmod(ssh, 0o700)
        os.chmod(fzf, 0o700)
        env["PATH"] = fake_bin + os.pathsep + env["PATH"]
        env["BOXA_TEST_GH_COUNT"] = os.path.join(home, "gh-count")

    def _write_identity(
        self,
        env: dict[str, str],
        identity_id: str,
        kind: str,
        username: str,
    ) -> None:
        store = os.path.join(env["BOXA_FORGE_DIR"], "identities")
        os.makedirs(store, mode=0o700, exist_ok=True)
        path = os.path.join(store, identity_id)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(
                "version=2\n"
                f"name={identity_id}\n"
                f"kind={kind}\n"
                f"key={os.path.join(env['BOXA_AGENT_IDENTITY_DIR'], 'id_ed25519')}\n"
                "github_created_at=123\n"
                f"github_username={username}\n"
                f"github_token={username}-secret\n"
                "gitlab_created_at=\n"
                "gitlab_host=\n"
                "gitlab_username=\n"
                "gitlab_token=\n"
            )
        os.chmod(path, 0o600)

    def _generate_agent_key(self, env: dict[str, str]) -> None:
        os.makedirs(env["BOXA_AGENT_IDENTITY_DIR"], exist_ok=True)
        subprocess.run(
            [
                "ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "forge-pty-test",
                "-f",
                os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "id_ed25519"),
            ],
            check=True,
            timeout=10,
        )

    def _assert_split_token(
        self,
        env: dict[str, str],
        identity: str,
        identity_text: str,
        forge: str,
        secret: str,
    ) -> None:
        self.assertIn("version=3", identity_text)
        self.assertNotIn(secret, identity_text)
        token_path = os.path.join(
            env["BOXA_FORGE_DIR"], "tokens", f"{identity}.{forge}"
        )
        with open(token_path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), secret + "\n")
        self.assertEqual(os.stat(token_path).st_mode & 0o777, 0o600)

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
                            and prompts[prompt_index][0] in transcript[search_start:]
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

    def test_github_registration_requires_and_retries_token_verification(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            self._generate_agent_key(env)
            secret = "github-registration-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "2"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"
            returncode, transcript = self._run_pty(
                [harness, "add"],
                env,
                [
                    (b"Persona name:", b"retry-persona\n"),
                    (b"Persona kind: (number/q)", b"2\n"),
                    (b"Forge: (number/q)", b"1\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"Token verification: (number/q)", b"1\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitHub SSH key: (number/q)", b"3\n"),
                ],
            )
            self.assertEqual(returncode, 0, transcript)
            self.assertNotIn(secret, transcript)
            self.assertIn("token verification failed", transcript)
            self.assertIn("Authenticated as: machine-user", transcript)
            self.assertIn("Registered persona: retry-persona", transcript)
            self.assertIn("Kind: mine", transcript)
            self.assertIn("SSH key: none attached", transcript)
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "retry-persona"
            )
            with open(identity, encoding="utf-8") as fh:
                identity_text = fh.read()
            self.assertIn("kind=mine", identity_text)
            self.assertNotIn("key=", identity_text)
            self._assert_split_token(
                env, "retry-persona", identity_text, "github", secret
            )

    def test_forge_add_registers_existing_machine_user_in_real_pty(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            self._generate_agent_key(env)
            secret = "github-add-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"

            returncode, transcript = self._run_pty(
                [harness, "add"],
                env,
                [
                    (b"Persona name:", b"automation\n"),
                    (b"Persona kind: (number/q)", b"1\n"),
                    (b"Forge: (number/q)", b"1\n"),
                    (b"Expected account username", b"entered-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitHub SSH key: (number/q)", b"1\n"),
                    (b"GitHub account: (number/q)", b"1\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertNotIn(secret, transcript)
            mint_url = (
                "https://github.com/settings/tokens/new?scopes=repo"
                "&description=Boxa%20Agent"
            )
            self.assertIn(mint_url, transcript)
            self.assertIn(
                "token must belong to the separate automation account: "
                "https://github.com/signup",
                transcript,
            )
            self.assertIn(
                "Import the host CLI token only when the host CLI is logged in "
                "as that account.",
                transcript,
            )
            self.assertLess(
                transcript.index(mint_url), transcript.index("Token source:")
            )
            self.assertNotIn("Create a separate automation-only GitHub", transcript)
            self.assertIn(
                "each machine should attach its own key and mint its own revocable token",
                transcript,
            )
            self.assertIn("GitHub machine-user guidance", transcript)
            self.assertIn("For private repositories, use GitHub Pro", transcript)
            self.assertIn("Authenticated via SSH as: machine-user", transcript)
            username_context = (
                "This optional hint lets Boxa warn if SSH or token verification "
                "authenticates as a different account"
            )
            self.assertIn(username_context, transcript)
            self.assertLess(
                transcript.index(username_context),
                transcript.index("Expected account username"),
            )
            self.assertIn(
                "Entered username entered-user, but verification authenticated as machine-user",
                transcript,
            )
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "automation"
            )
            with open(identity, encoding="utf-8") as fh:
                identity_text = fh.read()
            self.assertIn("kind=agent", identity_text)
            self.assertIn(
                "key=" + os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "id_ed25519"),
                identity_text,
            )
            self.assertIn(
                "Attach Boxa's generated agent key (agent-identity)", transcript
            )
            self.assertNotIn("this machine's Agent key", transcript)
            self.assertIn("github_username=machine-user", identity_text)
            self._assert_split_token(
                env, "automation", identity_text, "github", secret
            )
            self.assertEqual(os.stat(identity).st_mode & 0o777, 0o600)
            self.assertFalse(
                os.path.exists(os.path.join(env["BOXA_FORGE_DIR"], "github"))
            )

            listed = subprocess.run(
                ["bash", harness, "list"],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
                check=True,
            )
            self.assertIn("Persona: automation", listed.stdout)

    def test_forge_add_generates_missing_agent_key_on_first_persona(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            env["BOXA_SSH_CONF"] = os.path.join(home, ".config", "boxa", "ssh.conf")
            secret = "github-first-persona-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"
            agent_key = os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "id_ed25519")
            self.assertFalse(os.path.exists(agent_key))

            returncode, transcript = self._run_pty(
                [harness, "add", "github"],
                env,
                [
                    (b"Persona name:", b"first-agent\n"),
                    (b"Persona kind: (number/q)", b"1\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitHub SSH key: (number/q)", b"1\n"),
                    (b"Generate the Agent key now? [Y/n]", b"\n"),
                    (b"GitHub account: (number/q)", b"1\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertNotIn(secret, transcript)
            self.assertNotIn("The Agent key is not available", transcript)
            self.assertIn(f"No Agent key exists yet: {agent_key}", transcript)
            self.assertIn("Generated the Agent key: SHA256:", transcript)
            self.assertIn(
                "Dedicated Agent SSH forwarding enabled globally.", transcript
            )
            self.assertIn("Authenticated via SSH as: machine-user", transcript)
            self.assertTrue(os.path.isfile(agent_key))
            self.assertTrue(os.path.isfile(agent_key + ".pub"))
            self.assertEqual(os.stat(agent_key).st_mode & 0o777, 0o600)
            with open(env["BOXA_SSH_CONF"], encoding="utf-8") as fh:
                self.assertIn("gate = on", fh.read())
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "first-agent"
            )
            with open(identity, encoding="utf-8") as fh:
                identity_text = fh.read()
            self.assertIn("kind=agent", identity_text)
            self.assertIn(f"key={agent_key}\n", identity_text)
            self._assert_split_token(
                env, "first-agent", identity_text, "github", secret
            )

    def test_forge_add_keeps_token_when_agent_key_generation_is_declined(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            secret = "github-declined-key-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"
            agent_key = os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "id_ed25519")

            returncode, transcript = self._run_pty(
                [harness, "add", "github"],
                env,
                [
                    (b"Persona name:", b"token-first\n"),
                    (b"Persona kind: (number/q)", b"1\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitHub SSH key: (number/q)", b"1\n"),
                    (b"Generate the Agent key now? [Y/n]", b"n\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertNotIn(secret, transcript)
            self.assertIn("Continuing without an SSH key.", transcript)
            self.assertIn("boxa doctor --fix agent-identity", transcript)
            self.assertIn("Registered persona: token-first", transcript)
            self.assertFalse(os.path.exists(agent_key))
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "token-first"
            )
            with open(identity, encoding="utf-8") as fh:
                identity_text = fh.read()
            self.assertIn("kind=agent", identity_text)
            self.assertNotIn("key=", identity_text)
            self._assert_split_token(
                env, "token-first", identity_text, "github", secret
            )

    def test_forge_add_aborts_after_ssh_gate_write_failure_without_consent(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            env["BOXA_TEST_SSH_CONF_FAIL"] = "1"
            secret = "github-key-failure-abort-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"

            returncode, transcript = self._run_pty(
                [harness, "add", "github"],
                env,
                [
                    (b"Persona name:", b"failed-agent\n"),
                    (b"Persona kind: (number/q)", b"1\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitHub SSH key: (number/q)", b"1\n"),
                    (b"Generate the Agent key now? [Y/n]", b"\n"),
                    (b"without an SSH key anyway? [y/N]", b"N\n"),
                ],
            )

            self.assertNotEqual(returncode, 0, transcript)
            self.assertNotIn(secret, transcript)
            self.assertIn(
                "Enabling the SSH gate failed after the Agent key was generated.",
                transcript,
            )
            self.assertIn("boxa doctor --fix agent-identity", transcript)
            self.assertIn("Persona was not registered.", transcript)
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "failed-agent"
            )
            self.assertFalse(os.path.exists(identity))

    def test_forge_add_registers_token_only_after_ssh_gate_write_failure_consent(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            env["BOXA_TEST_SSH_CONF_FAIL"] = "1"
            secret = "github-key-failure-continue-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"

            returncode, transcript = self._run_pty(
                [harness, "add", "github"],
                env,
                [
                    (b"Persona name:", b"token-only-agent\n"),
                    (b"Persona kind: (number/q)", b"1\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitHub SSH key: (number/q)", b"1\n"),
                    (b"Generate the Agent key now? [Y/n]", b"\n"),
                    (b"without an SSH key anyway? [y/N]", b"y\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertNotIn(secret, transcript)
            self.assertIn(
                "Enabling the SSH gate failed after the Agent key was generated.",
                transcript,
            )
            self.assertIn("boxa doctor --fix agent-identity", transcript)
            self.assertIn("Registered persona: token-only-agent", transcript)
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "token-only-agent"
            )
            with open(identity, encoding="utf-8") as fh:
                identity_text = fh.read()
            self.assertIn("kind=agent", identity_text)
            self.assertNotIn("key=", identity_text)
            self._assert_split_token(
                env, "token-only-agent", identity_text, "github", secret
            )

    def test_forge_add_treats_eof_on_generate_prompt_as_failure_not_decline(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            secret = "github-eof-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"
            agent_key = os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "id_ed25519")

            returncode, transcript = self._run_pty(
                [harness, "add", "github"],
                env,
                [
                    (b"Persona name:", b"eof-persona\n"),
                    (b"Persona kind: (number/q)", b"1\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitHub SSH key: (number/q)", b"1\n"),
                    (b"Generate the Agent key now? [Y/n]", b"\x04"),
                    (b"Register the persona without an SSH key anyway? [y/N]", b"\x04"),
                ],
            )

            self.assertNotEqual(returncode, 0, transcript)
            self.assertNotIn(secret, transcript)
            self.assertIn("No answer was read for the Agent key prompt.", transcript)
            self.assertNotIn("Continuing without an SSH key.", transcript)
            self.assertIn("Persona was not registered.", transcript)
            self.assertFalse(os.path.exists(agent_key))
            self.assertFalse(
                os.path.exists(
                    os.path.join(env["BOXA_FORGE_DIR"], "identities", "eof-persona")
                )
            )
            self.assertFalse(
                os.path.exists(os.path.join(env["BOXA_FORGE_DIR"], "github"))
            )

    def test_forge_add_mine_default_attaches_all_host_keys_in_real_pty(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            ssh_dir = os.path.join(home, ".ssh")
            os.makedirs(ssh_dir)
            key_paths = [
                os.path.join(ssh_dir, "id_rsa"),
                os.path.join(ssh_dir, "id_rsa_gitlab"),
            ]
            before = []
            for index, key_path in enumerate(key_paths):
                subprocess.run(
                    [
                        "ssh-keygen",
                        "-q",
                        "-t",
                        "ed25519",
                        "-N",
                        "",
                        "-C",
                        f"picked-{index}@test",
                        "-f",
                        key_path,
                    ],
                    check=True,
                    timeout=10,
                )
                os.chmod(key_path, stat.S_IRUSR)
                with open(key_path, "rb") as fh:
                    before.append(fh.read())
            os.remove(key_paths[1] + ".pub")

            secret = "github-picked-keys-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"
            returncode, transcript = self._run_pty(
                [harness, "add", "github"],
                env,
                [
                    (b"Persona name:", b"picked-keys\n"),
                    (b"Persona kind: (number/q)", b"2\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitHub SSH key: (number/q)", b"1\n"),
                    (b"GitHub account: (number/q)", b"1\n"),
                    (b"SSH verification: (number/q)", b"2\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "picked-keys"
            )
            with open(identity, encoding="utf-8") as fh:
                attached = [
                    line.removeprefix("key=").strip()
                    for line in fh
                    if line.startswith("key=")
                ]
            self.assertEqual(attached, key_paths)
            self.assertNotIn(
                os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "id_ed25519"),
                attached,
            )
            self.assertIn("Attach all host SSH keys (~/.ssh)", transcript)
            self.assertIn("Choose which host keys to attach", transcript)
            self.assertNotIn("generated agent key", transcript)
            self.assertNotIn("Look into ~/.ssh and offer keys to add?", transcript)
            self.assertIn(
                f"The public key to upload is missing: {key_paths[1]}.pub",
                transcript,
            )
            self.assertIn("ssh-keygen -y -f", transcript)
            self.assertIn("Boxa will not run it", transcript)
            for key_path, expected_bytes in zip(key_paths, before):
                self.assertEqual(
                    stat.S_IMODE(os.stat(key_path).st_mode), stat.S_IRUSR
                )
                with open(key_path, "rb") as fh:
                    self.assertEqual(fh.read(), expected_bytes)

    def test_forge_add_mine_default_without_host_keys_registers_token_persona(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            secret = "github-no-host-keys-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"

            returncode, transcript = self._run_pty(
                [harness, "add", "github"],
                env,
                [
                    (b"Persona name:", b"token-only\n"),
                    (b"Persona kind: (number/q)", b"2\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitHub SSH key: (number/q)", b"1\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertIn(
                "No valid SSH key pairs found under ~/.ssh; continuing without an SSH key.",
                transcript,
            )
            self.assertIn("Registered persona: token-only", transcript)
            self.assertIn("SSH key: none attached", transcript)
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "token-only"
            )
            with open(identity, encoding="utf-8") as fh:
                identity_text = fh.read()
            self.assertIn("kind=mine", identity_text)
            self.assertIn("github_username=machine-user", identity_text)
            self.assertNotIn("key=", identity_text)
            self._assert_split_token(
                env, "token-only", identity_text, "github", secret
            )

    def test_forge_add_mine_choose_which_accepts_manual_path_in_real_pty(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            key_path = os.path.join(home, "external-keys", "id_chosen")
            os.makedirs(os.path.dirname(key_path))
            subprocess.run(
                [
                    "ssh-keygen",
                    "-q",
                    "-t",
                    "ed25519",
                    "-N",
                    "",
                    "-C",
                    "chosen@test",
                    "-f",
                    key_path,
                ],
                check=True,
                timeout=10,
            )
            os.remove(key_path + ".pub")
            secret = "github-chosen-key-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"

            returncode, transcript = self._run_pty(
                [harness, "add", "github"],
                env,
                [
                    (b"Persona name:", b"chosen-key\n"),
                    (b"Persona kind: (number/q)", b"2\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitHub SSH key: (number/q)", b"2\n"),
                    (b"Look into ~/.ssh and offer keys to add? [y/N]", b"\n"),
                    (
                        b"Adopt SSH keys: (comma-separated: numbers and a/q)",
                        b"a\n",
                    ),
                    (b"Path to private key:", key_path.encode() + b"\n"),
                    (b"GitHub account: (number/q)", b"1\n"),
                    (b"SSH verification: (number/q)", b"2\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertIn("a) Enter a key path manually", transcript)
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "chosen-key"
            )
            with open(identity, encoding="utf-8") as fh:
                self.assertIn(f"key={key_path}\n", fh.readlines())
            self.assertIn(
                f"The public key to upload is missing: {key_path}.pub",
                transcript,
            )
            self.assertIn("ssh-keygen -y -f", transcript)

    def test_skipping_verification_keeps_the_explicit_key_choice(self) -> None:
        for ssh_selection, persona_name, use_agent_key in (
            ("1", "agent-key-skip", True),
            ("3", "existing-key-skip", False),
        ):
            with self.subTest(persona=persona_name), tempfile.TemporaryDirectory() as home:
                env = self._environment(home)
                harness = self._write_harness(home)
                self._write_fake_forges(home, env)
                if use_agent_key:
                    self._generate_agent_key(env)
                    expected_key = os.path.join(
                        env["BOXA_AGENT_IDENTITY_DIR"], "id_ed25519"
                    )
                else:
                    expected_key = os.path.join(home, ".ssh", "id_existing")
                    os.makedirs(os.path.dirname(expected_key))
                    subprocess.run(
                        [
                            "ssh-keygen",
                            "-q",
                            "-t",
                            "ed25519",
                            "-N",
                            "",
                            "-C",
                            "existing-skip@test",
                            "-f",
                            expected_key,
                        ],
                        check=True,
                        timeout=10,
                    )
                secret = f"{persona_name}-secret"
                env["BOXA_TEST_GH_EXPECTED"] = secret
                env["BOXA_TEST_GH_HOST_TOKEN"] = secret
                env["BOXA_TEST_GH_FAILS"] = "0"
                env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
                env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"
                env["BOXA_TEST_SSH_FAIL"] = "1"
                prompts = [
                    (b"Persona name:", persona_name.encode() + b"\n"),
                    (b"Persona kind: (number/q)", b"1\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (
                        b"GitHub SSH key: (number/q)",
                        ssh_selection.encode() + b"\n",
                    ),
                ]
                if not use_agent_key:
                    prompts.extend(
                        [
                            (b"Look into ~/.ssh and offer keys to add? [y/N]", b"y\n"),
                            (
                                b"Adopt SSH keys: (comma-separated: numbers and a/q)",
                                b"1\n",
                            ),
                        ]
                    )
                prompts.extend(
                    [
                        (b"GitHub account: (number/q)", b"1\n"),
                        (b"SSH verification: (number/q)", b"2\n"),
                    ]
                )

                returncode, transcript = self._run_pty(
                    [harness, "add", "github"], env, prompts
                )

                self.assertEqual(returncode, 0, transcript)
                persona = os.path.join(
                    env["BOXA_FORGE_DIR"], "identities", persona_name
                )
                with open(persona, encoding="utf-8") as fh:
                    self.assertIn(f"key={expected_key}\n", fh.readlines())
                self.assertIn("SSH key: attached without verification", transcript)

    def test_token_only_registration_uses_the_same_flow_for_every_kind(self) -> None:
        for selection, kind, ssh_selection in (
            ("1", "agent", "2"),
            ("2", "mine", "3"),
            ("3", "other", "2"),
        ):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as home:
                env = self._environment(home)
                harness = self._write_harness(home)
                self._write_fake_forges(home, env)
                secret = f"{kind}-token-only-secret"
                env["BOXA_TEST_GH_EXPECTED"] = secret
                env["BOXA_TEST_GH_HOST_TOKEN"] = secret
                env["BOXA_TEST_GH_FAILS"] = "0"
                env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
                env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"

                returncode, transcript = self._run_pty(
                    [harness, "add", "github"],
                    env,
                    [
                        (b"Persona name:", f"{kind}-persona\n".encode()),
                        (b"Persona kind: (number/q)", selection.encode() + b"\n"),
                        (b"Expected account username", b"machine-user\n"),
                        (b"Token source: (number/q)", b"1\n"),
                        (b"Paste GitHub token:", secret.encode() + b"\n"),
                        (b"durable Allowlist? [y/N]", b"\n"),
                        (
                            b"GitHub SSH key: (number/q)",
                            ssh_selection.encode() + b"\n",
                        ),
                    ],
                )

                self.assertEqual(returncode, 0, transcript)
                identity = os.path.join(
                    env["BOXA_FORGE_DIR"], "identities", f"{kind}-persona"
                )
                with open(identity, encoding="utf-8") as fh:
                    identity_text = fh.read()
                self.assertIn(f"kind={kind}", identity_text)
                self._assert_split_token(
                    env, f"{kind}-persona", identity_text, "github", secret
                )
                self.assertNotIn("key=", identity_text)

    def test_registration_rejects_key_only_before_offering_ssh(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            self._generate_agent_key(env)
            env["BOXA_TEST_GH_EXPECTED"] = "unused"
            env["BOXA_TEST_GH_HOST_TOKEN"] = "unused"
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"

            returncode, transcript = self._run_pty(
                [harness, "add", "github"],
                env,
                [
                    (b"Persona name:", b"key-only\n"),
                    (b"Persona kind: (number/q)", b"1\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", b"\n"),
                ],
            )

            self.assertNotEqual(returncode, 0, transcript)
            self.assertIn("verified token is mandatory", transcript)
            self.assertNotIn("GitHub SSH key:", transcript)
            self.assertFalse(
                os.path.exists(os.path.join(env["BOXA_FORGE_DIR"], "identities"))
            )

    def test_registration_accepts_token_pasted_into_source_menu(self) -> None:
        # Regression: a token pasted into the token-source menu was silently
        # dropped and the checklist ended with "verified token is mandatory".
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            self._generate_agent_key(env)
            secret = "glpat-pasted-into-the-menu-secret"
            env["BOXA_TEST_GH_EXPECTED"] = "unused"
            env["BOXA_TEST_GH_HOST_TOKEN"] = "unused"
            env["BOXA_TEST_GLAB_EXPECTED"] = secret
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"
            env["BOXA_TEST_GLAB_FAILS"] = "0"

            returncode, transcript = self._run_pty(
                [harness, "add", "gitlab"],
                env,
                [
                    (b"Persona name:", b"menu-paste\n"),
                    (b"Persona kind: (number/q)", b"1\n"),
                    (b"GitLab host [gitlab.com]", b"gitlab.example\n"),
                    (b"Expected account username", b"service-account\n"),
                    (b"Token source: (number/q)", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitLab SSH key: (number/q)", b"1\n"),
                    (b"GitLab account: (number/q)", b"2\n"),
                ],
            )
            self.assertEqual(returncode, 0, transcript)
            self.assertIn("Token source: (typed value accepted)", transcript)
            self.assertIn("visible on screen", transcript)
            self.assertNotIn("Paste GitLab token:", transcript)
            self.assertIn("Authenticated as: service-account", transcript)
            self.assertIn("Registered persona: menu-paste", transcript)

    def test_registration_explains_cancelled_token_source_menu(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            self._generate_agent_key(env)
            env["BOXA_TEST_GH_EXPECTED"] = "unused"
            env["BOXA_TEST_GH_HOST_TOKEN"] = "unused"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"

            returncode, transcript = self._run_pty(
                [harness, "add", "github"],
                env,
                [
                    (b"Persona name:", b"menu-cancel\n"),
                    (b"Persona kind: (number/q)", b"1\n"),
                    (b"Expected account username", b"machine-user\n"),
                    # Short free text is not token-shaped: treated as a
                    # cancelled choice, never stored as a credential.
                    (b"Token source: (number/q)", b"nope-x\n"),
                ],
            )
            self.assertNotEqual(returncode, 0, transcript)
            self.assertIn("No token source was chosen", transcript)
            self.assertIn("verified token is mandatory", transcript)
            self.assertNotIn("GitHub SSH key:", transcript)
            self.assertFalse(
                os.path.exists(os.path.join(env["BOXA_FORGE_DIR"], "identities"))
            )

    def test_registration_can_adopt_the_host_token_with_consent(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            os.makedirs(env["GH_CONFIG_DIR"], exist_ok=True)
            with open(
                os.path.join(env["GH_CONFIG_DIR"], "hosts.yml"),
                "w",
                encoding="utf-8",
            ) as fh:
                fh.write("hosts:\n  github.com:\n    oauth_token: placeholder\n")
            secret = "registration-import-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"

            returncode, transcript = self._run_pty(
                [harness, "add", "github"],
                env,
                [
                    (b"Persona name:", b"imported\n"),
                    (b"Persona kind: (number/q)", b"2\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"2\n"),
                    (b"host-only forge store? [y/N]", b"y\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitHub SSH key: (number/q)", b"3\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertNotIn(secret, transcript)
            self.assertIn("token imported", transcript)
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "imported"
            )
            with open(identity, encoding="utf-8") as fh:
                identity_text = fh.read()
            self._assert_split_token(
                env, "imported", identity_text, "github", secret
            )
            self.assertNotIn("key=", identity_text)

    def test_forge_use_walks_real_identity_and_project_pickers(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            current = os.path.join(home, "Current Project")
            other = os.path.join(home, "Other Project")
            os.makedirs(current)
            os.makedirs(other)
            env["BOXA_TEST_CURRENT_PROJECT"] = current
            env["BOXA_TEST_OTHER_PROJECT"] = other
            self._write_identity(env, "alpha", "agent", "alpha")
            self._write_identity(env, "beta", "mine", "beta")
            conf = os.path.join(home, ".config", "boxa", "forge.conf")
            with open(conf, "w", encoding="utf-8") as fh:
                fh.write(f"[{current}]\nforge = on\nidentity = alpha\n")
            ssh_conf = os.path.join(home, ".config", "boxa", "ssh.conf")
            with open(ssh_conf, "w", encoding="utf-8") as fh:
                fh.write(f"[{current}]\ngate = on\n")

            returncode, transcript = self._run_pty(
                [harness, "use"],
                env,
                [
                    (b"Use persona (number/q)", b"2\n"),
                    (b"Assign 'beta' in Projects", b"a,1\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            with open(conf, encoding="utf-8") as fh:
                conf_text = fh.read()
            for project in (current, other):
                self.assertIn(f"[{project}]", conf_text)
            self.assertEqual(conf_text.count("identity = beta"), 2)
            self.assertEqual(conf_text.count("forge = on"), 2)
            self.assertIn(
                "Question: Which persona should be assigned?", transcript
            )
            self.assertIn("Question: Which Project", transcript)
            self.assertIn("Persona assignment summary:", transcript)
            self.assertEqual(transcript.count("Persona assignment summary:"), 1)
            self.assertNotIn("Persona 'beta' assigned", transcript)
            self.assertIn(
                f"{current}: alpha -> beta; its SSH keys will be forwarded "
                "into this project's ssh-agent (gate on) "
                "[container recreation needed: forge environment changed]",
                transcript,
            )
            self.assertIn(
                f"{other}: none -> beta; its SSH keys will be forwarded into "
                "this project's ssh-agent (gate on) "
                "[container recreation needed: forge environment changed; "
                "SSH forwarding off -> on]",
                transcript,
            )
            with open(ssh_conf, encoding="utf-8") as fh:
                ssh_text = fh.read()
            self.assertEqual(ssh_text.count("gate = on"), 2)
            registry = os.path.join(home, ".config", "boxa", "ssh-key-registry")
            with open(registry, encoding="utf-8") as fh:
                registry_text = fh.read()
            expected_key = os.path.join(
                env["BOXA_AGENT_IDENTITY_DIR"], "id_ed25519"
            )
            self.assertEqual(registry_text.count(f"key = {expected_key}"), 2)

            returncode, unchanged_transcript = self._run_pty(
                [harness, "use", "beta"],
                env,
                [(b"Assign 'beta' in Projects", b"a\n")],
            )

            self.assertEqual(returncode, 0, unchanged_transcript)
            self.assertIn(
                f"{current}: beta -> beta; its SSH keys will be forwarded into "
                "this project's ssh-agent (gate on)",
                unchanged_transcript,
            )
            self.assertNotIn("container recreation needed", unchanged_transcript)
            with open(conf, encoding="utf-8") as fh:
                conf_text = fh.read()
            other_section = conf_text.split(f"[{other}]", 1)[1].split("[", 1)[0]
            self.assertIn("identity = beta", other_section)
            self.assertIn("forge = on", other_section)

            returncode, clear_transcript = self._run_pty(
                [harness, "use", "none"],
                env,
                [(b"Assign 'none' in Projects", b"a\n")],
            )

            self.assertEqual(returncode, 0, clear_transcript)
            self.assertIn("Persona assignment summary:", clear_transcript)
            self.assertIn(
                f"{current}: beta -> none; no persona SSH keys will be forwarded "
                "into this project's ssh-agent (gate off) "
                "[container recreation needed: forge environment changed; "
                "SSH forwarding on -> off]",
                clear_transcript,
            )
            self.assertNotIn(f"{other}: beta -> none", clear_transcript)
            with open(conf, encoding="utf-8") as fh:
                conf_text = fh.read()
            current_section = conf_text.split(f"[{current}]", 1)[1].split("[", 1)[0]
            self.assertIn("identity = none", current_section)
            self.assertIn("forge = off", current_section)
            with open(ssh_conf, encoding="utf-8") as fh:
                ssh_text = fh.read()
            current_ssh_section = ssh_text.split(f"[{current}]", 1)[1].split(
                "[", 1
            )[0]
            self.assertIn("gate = off", current_ssh_section)
            with open(registry, encoding="utf-8") as fh:
                registry_text = fh.read()
            current_registry_section = registry_text.split(f"[{current}]", 1)[1].split(
                "[", 1
            )[0]
            self.assertNotIn("key =", current_registry_section)
            self.assertEqual(registry_text.count(f"key = {expected_key}"), 1)

    def test_forge_on_without_persona_preselects_project_and_reports_cancel(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            current = os.path.join(home, "Current Project")
            other = os.path.join(home, "Other Project")
            os.makedirs(current)
            os.makedirs(other)
            env["BOXA_TEST_CURRENT_PROJECT"] = current
            env["BOXA_TEST_OTHER_PROJECT"] = other
            self._write_identity(env, "alpha", "agent", "alpha")
            conf = os.path.join(home, ".config", "boxa", "forge.conf")
            os.makedirs(os.path.dirname(conf), exist_ok=True)
            with open(conf, "w", encoding="utf-8") as fh:
                fh.write(f"[{current}]\nidentity = none\n")

            returncode, transcript = self._run_pty(
                [harness, "gate-on"],
                env,
                [
                    (b"Use persona (number/q)", b"1\n"),
                    (b"Assign 'alpha' in Projects", b"q\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertIn("a) Current Project", transcript)
            self.assertIn("No Project chosen; nothing assigned.", transcript)
            self.assertIn(
                f"Forge access is on, but no persona is assigned to {current}, "
                "so SSH forwarding stays off.",
                transcript,
            )
            self.assertIn(
                f"Project {current} SSH forwarding: still off "
                "(no persona assigned; run 'boxa forge use').",
                transcript,
            )
            with open(conf, encoding="utf-8") as fh:
                self.assertIn("forge = on", fh.read())

    def test_forge_on_with_keyless_persona_reports_guidance_in_pty(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            current = os.path.join(home, "Current Project")
            other = os.path.join(home, "Other Project")
            os.makedirs(current)
            os.makedirs(other)
            env["BOXA_TEST_CURRENT_PROJECT"] = current
            env["BOXA_TEST_OTHER_PROJECT"] = other
            self._write_identity(env, "keyless", "mine", "keyless")
            persona = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "keyless"
            )
            with open(persona, encoding="utf-8") as fh:
                persona_lines = [
                    line for line in fh if not line.startswith("key=")
                ]
            with open(persona, "w", encoding="utf-8") as fh:
                fh.writelines(persona_lines)
            conf = os.path.join(home, ".config", "boxa", "forge.conf")
            os.makedirs(os.path.dirname(conf), exist_ok=True)
            with open(conf, "w", encoding="utf-8") as fh:
                fh.write(f"[{current}]\nidentity = keyless\n")

            returncode, transcript = self._run_pty(
                [harness, "gate-on"], env, []
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertIn(
                "persona 'keyless' has no attached SSH keys, so SSH "
                "forwarding stays off. Attach keys in 'boxa forge'",
                transcript,
            )
            self.assertIn(
                f"Project {current} SSH forwarding: still off "
                "(persona 'keyless' has no attached SSH keys; attach keys in "
                "'boxa forge').",
                transcript,
            )

    def test_forge_default_writes_catalog_identity_in_real_pty(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            env["BOXA_TEST_CURRENT_PROJECT"] = os.path.join(home, "current")
            env["BOXA_TEST_OTHER_PROJECT"] = os.path.join(home, "other")
            self._write_identity(env, "alpha", "agent", "alpha")

            returncode, transcript = self._run_pty(
                [harness, "default", "alpha"], env, []
            )

            self.assertEqual(returncode, 0, transcript)
            conf = os.path.join(home, ".config", "boxa", "forge.conf")
            with open(conf, encoding="utf-8") as fh:
                self.assertIn("identity = alpha", fh.read())

    def test_legacy_credential_migration_uses_real_picker(self) -> None:
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
                [harness, "migrate"],
                env,
                [
                    (b"GitHub legacy credential kind: (number/q)", b"1\n"),
                    (b"Persona name for github:legacy-user", b"legacy\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertNotIn("legacy-secret", transcript)
            self.assertFalse(os.path.exists(credential))
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "legacy"
            )
            with open(identity, encoding="utf-8") as fh:
                identity_text = fh.read()
            self.assertIn("kind=agent", identity_text)
            self._assert_split_token(
                env, "legacy", identity_text, "github", "legacy-secret"
            )
            self.assertIn(
                "GitHub credential migration — choose the descriptive owner label.",
                transcript,
            )
            conf = os.path.join(home, ".config", "boxa", "forge.conf")
            with open(conf, encoding="utf-8") as fh:
                self.assertIn("identity = legacy", fh.read())

    def test_interrupting_legacy_migration_prompt_keeps_credential(self) -> None:
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
                [harness, "migrate"],
                env,
                [(b"GitHub legacy credential kind: (number/q)", b"\x03")],
            )

            self.assertNotEqual(returncode, 0, transcript)
            self.assertTrue(os.path.isfile(credential))
            self.assertFalse(
                os.path.exists(os.path.join(env["BOXA_FORGE_DIR"], "identities"))
            )

    def test_forge_set_rotates_the_matching_catalog_identity(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            env["BOXA_TEST_GH_EXPECTED"] = "rotated-secret"
            env["BOXA_TEST_GH_HOST_TOKEN"] = "unused"
            env["BOXA_TEST_GH_FAILS"] = "0"
            self._write_identity(env, "machine-user", "agent", "machine-user")
            conf = os.path.join(home, ".config", "boxa", "forge.conf")
            os.makedirs(os.path.dirname(conf), exist_ok=True)
            with open(conf, "w", encoding="utf-8") as fh:
                fh.write("identity = machine-user\n")

            returncode, transcript = self._run_pty(
                [harness, "set", "github"],
                env,
                [
                    (b"Paste GitHub token:", b"rotated-secret\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "machine-user"
            )
            with open(identity, encoding="utf-8") as fh:
                identity_text = fh.read()
            self.assertIn("kind=agent", identity_text)
            self._assert_split_token(
                env, "machine-user", identity_text, "github", "rotated-secret"
            )
            self.assertFalse(os.path.exists(os.path.join(env["BOXA_FORGE_DIR"], "github")))
            with open(conf, encoding="utf-8") as fh:
                self.assertEqual(fh.read(), "identity = machine-user\n")

    def test_gitlab_registration_runs_end_to_end(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            self._generate_agent_key(env)
            secret = "gitlab-checklist-secret"
            env["BOXA_TEST_GH_EXPECTED"] = "unused"
            env["BOXA_TEST_GH_HOST_TOKEN"] = "unused"
            env["BOXA_TEST_GLAB_EXPECTED"] = secret
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = secret
            returncode, transcript = self._run_pty(
                [harness, "add", "gitlab"],
                env,
                [
                    (b"Persona name:", b"gitlab-automation\n"),
                    (b"Persona kind: (number/q)", b"1\n"),
                    (b"GitLab host [gitlab.com]", b"gitlab.example\n"),
                    (b"Expected account username", b"service-account\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitLab token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitLab SSH key: (number/q)", b"1\n"),
                    (b"GitLab account: (number/q)", b"2\n"),
                ],
            )
            self.assertEqual(returncode, 0, transcript)
            self.assertNotIn(secret, transcript)
            mint_url = (
                "https://gitlab.example/-/user_settings/personal_access_tokens"
            )
            self.assertIn(mint_url, transcript)
            self.assertIn(
                "token must belong to the separate automation account: "
                "https://docs.gitlab.com/user/profile/service_accounts/",
                transcript,
            )
            self.assertIn(
                "Import the host CLI token only when the host CLI is logged in "
                "as that account.",
                transcript,
            )
            self.assertLess(
                transcript.index(mint_url), transcript.index("Token source:")
            )
            self.assertIn("Authenticated as: service-account", transcript)
            self.assertIn("Registered persona: gitlab-automation", transcript)
            self.assertIn("Create a GitLab service account", transcript)
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "gitlab-automation"
            )
            with open(identity, encoding="utf-8") as fh:
                identity_text = fh.read()
            self.assertIn("kind=agent", identity_text)
            self.assertIn("gitlab_host=gitlab.example", identity_text)
            self._assert_split_token(
                env, "gitlab-automation", identity_text, "gitlab", secret
            )
            self.assertIn("key=", identity_text)

    def test_guided_setup_registers_defaults_and_assigns_in_one_run(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            self._generate_agent_key(env)
            current = os.path.join(home, "Current Project")
            other = os.path.join(home, "Other Project")
            os.makedirs(current)
            os.makedirs(other)
            env["BOXA_TEST_CURRENT_PROJECT"] = current
            env["BOXA_TEST_OTHER_PROJECT"] = other
            secret = "github-setup-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"

            returncode, transcript = self._run_pty(
                [harness, "guided", "github"],
                env,
                [
                    (b"Persona name:", b"machine-user\n"),
                    (b"Persona kind: (number/q)", b"1\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Token source: (number/q)", b"1\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                    (b"GitHub SSH key: (number/q)", b"1\n"),
                    (b"GitHub account: (number/q)", b"1\n"),
                    (b"Forge action: (number/q)", b"3\n"),
                    (b"Persona: (number/q)", b"1\n"),
                    (b"Forge action: (number/q)", b"2\n"),
                    (b"Use persona (number/q)", b"1\n"),
                    (b"Assign 'machine-user' in Projects", b"a\n"),
                    (b"Forge action: (number/q)", b"7\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertNotIn(secret, transcript)
            self.assertIn("Registered persona: machine-user", transcript)
            conf = os.path.join(home, ".config", "boxa", "forge.conf")
            with open(conf, encoding="utf-8") as fh:
                conf_text = fh.read()
            self.assertIn("identity = machine-user", conf_text)
            self.assertIn(f"[{current}]", conf_text)
            self.assertIn("forge = on", conf_text)
            ssh_conf = os.path.join(home, ".config", "boxa", "ssh.conf")
            with open(ssh_conf, encoding="utf-8") as fh:
                ssh_text = fh.read()
            self.assertIn(f"[{current}]", ssh_text)
            self.assertIn("gate = on", ssh_text)

    def test_dashboard_removes_an_unused_persona_in_real_pty(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            env["BOXA_TEST_CURRENT_PROJECT"] = os.path.join(home, "Current Project")
            env["BOXA_TEST_OTHER_PROJECT"] = os.path.join(home, "Other Project")
            self._write_identity(env, "removable", "mine", "removable")
            self._write_identity(env, "survivor", "agent", "survivor")

            returncode, transcript = self._run_pty(
                [harness, "dashboard"],
                env,
                [
                    (b"Forge action: (number/q)", b"6\n"),
                    (b"Persona: (number/q)", b"1\n"),
                    (b"Forge action: (number/q)", b"7\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertIn("Remove a persona", transcript)
            self.assertIn("Persona 'removable' removed.", transcript)
            self.assertFalse(
                os.path.exists(
                    os.path.join(env["BOXA_FORGE_DIR"], "identities", "removable")
                )
            )

            returncode, rerender = self._run_pty(
                [harness, "dashboard"],
                env,
                [(b"Forge action: (number/q)", b"7\n")],
            )

            self.assertEqual(returncode, 0, rerender)
            self.assertIn("  survivor |", rerender)
            self.assertNotIn("  removable |", rerender)

    def test_dashboard_refuses_to_remove_an_in_use_persona_in_real_pty(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            current = os.path.join(home, "Current Project")
            other = os.path.join(home, "Other Project")
            env["BOXA_TEST_CURRENT_PROJECT"] = current
            env["BOXA_TEST_OTHER_PROJECT"] = other
            self._write_identity(env, "in-use", "mine", "in-use")
            conf = os.path.join(home, ".config", "boxa", "forge.conf")
            os.makedirs(os.path.dirname(conf), exist_ok=True)
            with open(conf, "w", encoding="utf-8") as fh:
                fh.write(f"identity = in-use\n\n[{current}]\nidentity = in-use\n")

            returncode, transcript = self._run_pty(
                [harness, "dashboard"],
                env,
                [
                    (b"Forge action: (number/q)", b"6\n"),
                    (b"Persona: (number/q)", b"1\n"),
                ],
            )

            self.assertNotEqual(returncode, 0, transcript)
            self.assertIn("Cannot remove persona 'in-use'; it is in use:", transcript)
            self.assertIn("  Default: persona", transcript)
            self.assertIn(f"  Project: {current}", transcript)
            self.assertTrue(
                os.path.isfile(
                    os.path.join(env["BOXA_FORGE_DIR"], "identities", "in-use")
                )
            )

    def test_fzf_renders_every_registration_question_in_header(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            self._generate_agent_key(env)
            env["BOXA_PICKER_FZF"] = "1"
            secret = "github-fzf-header-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"

            returncode, transcript = self._run_pty(
                [harness, "add", "github"],
                env,
                [
                    (b"Persona name:", b"header-persona\n"),
                    (b"Expected account username", b"machine-user\n"),
                    (b"Paste GitHub token:", secret.encode() + b"\n"),
                    (b"durable Allowlist? [y/N]", b"\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertNotIn(secret, transcript)
            self.assertIn("Question: Whose account is this?", transcript)
            self.assertIn(
                "Question: How should Boxa obtain the required token?", transcript
            )
            self.assertIn("Question: Attach an SSH key now?", transcript)
            self.assertIn("Question: Use an existing account or create one?", transcript)

    def test_adopt_existing_is_default_no_and_rotation_is_consent_first(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            os.makedirs(env["GH_CONFIG_DIR"], exist_ok=True)
            with open(os.path.join(env["GH_CONFIG_DIR"], "hosts.yml"), "w", encoding="utf-8") as fh:
                fh.write("hosts:\n  github.com:\n    oauth_token: placeholder\n")
            secret = "adopted-host-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GH_FAILS"] = "0"
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"
            returncode, transcript = self._run_pty(
                [harness, "adopt", "github"],
                env,
                [(b"host-only forge store? [y/N]", b"\n")],
            )
            self.assertEqual(returncode, 1, transcript)
            self.assertNotIn(secret, transcript)
            credential = os.path.join(env["BOXA_FORGE_DIR"], "github")
            self.assertFalse(os.path.exists(credential))

            os.makedirs(env["BOXA_FORGE_DIR"], exist_ok=True)
            with open(credential, "w", encoding="utf-8") as fh:
                fh.write(
                    "version=1\ncreated_at=1\nusername=old\nhost=\n"
                    "token=stored-different-secret\n"
                )
            os.chmod(credential, 0o600)
            returncode, transcript = self._run_pty(
                [harness, "adopt", "github"],
                env,
                [
                    (b"differs", b"y\n"),
                    (b"GitHub legacy credential kind: (number/q)", b"1\n"),
                    (b"Persona name for github:machine-user", b"machine-user\n"),
                ],
            )
            self.assertEqual(returncode, 0, transcript)
            self.assertNotIn(secret, transcript)
            self.assertNotIn("stored-different-secret", transcript)
            self.assertFalse(os.path.exists(credential))
            identity = os.path.join(
                env["BOXA_FORGE_DIR"], "identities", "machine-user"
            )
            with open(identity, encoding="utf-8") as fh:
                stored = fh.read()
            self.assertIn("github_username=machine-user", stored)
            self._assert_split_token(
                env, "machine-user", stored, "github", secret
            )
            conf = os.path.join(home, ".config", "boxa", "forge.conf")
            with open(conf, encoding="utf-8") as fh:
                self.assertIn("identity = machine-user", fh.read())

    def test_adopt_existing_non_tty_reports_name_and_safe_hint(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            env = self._environment(home)
            harness = self._write_harness(home)
            self._write_fake_forges(home, env)
            os.makedirs(env["GH_CONFIG_DIR"], exist_ok=True)
            with open(os.path.join(env["GH_CONFIG_DIR"], "hosts.yml"), "w", encoding="utf-8") as fh:
                fh.write("hosts:\n  github.com:\n    oauth_token: placeholder\n")
            secret = "non-tty-host-secret"
            env["BOXA_TEST_GH_EXPECTED"] = secret
            env["BOXA_TEST_GH_HOST_TOKEN"] = secret
            env["BOXA_TEST_GLAB_EXPECTED"] = "unused"
            env["BOXA_TEST_GLAB_HOST_TOKEN"] = "unused"
            result = subprocess.run(
                ["bash", harness, "adopt", "github"],
                cwd=ROOT,
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=10,
                start_new_session=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Skipped GitHub token", result.stderr)
            self.assertIn("boxa forge set github", result.stderr)
            self.assertNotIn(secret, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
