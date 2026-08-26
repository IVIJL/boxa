"""Real-PTY proof that the forge dashboard renders once around an action."""

from __future__ import annotations

from glob import glob
import os
import pty
import select
import signal
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class ForgeDashboardPtyTest(unittest.TestCase):
    def _run_pty(
        self,
        argv: list[str],
        env: dict[str, str],
        interactions: list[tuple[bytes, bytes]],
    ) -> tuple[int, str]:
        master, slave = pty.openpty()
        process = subprocess.Popen(
            argv,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env=env,
            close_fds=True,
            start_new_session=True,
        )
        os.close(slave)
        transcript = bytearray()
        deadline = time.monotonic() + 20
        pending = list(interactions)
        search_from = 0
        try:
            while process.poll() is None and time.monotonic() < deadline:
                readable, _, _ = select.select([master], [], [], 0.1)
                if readable:
                    try:
                        transcript.extend(os.read(master, 4096))
                    except OSError:
                        break
                if pending and transcript.find(pending[0][0], search_from) >= 0:
                    prompt, reply = pending.pop(0)
                    search_from = transcript.find(prompt, search_from) + len(prompt)
                    os.write(master, reply)
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=2)
            while True:
                readable, _, _ = select.select([master], [], [], 0)
                if not readable:
                    break
                try:
                    transcript.extend(os.read(master, 4096))
                except OSError:
                    break
        finally:
            os.close(master)
        text = transcript.decode("utf-8", errors="replace")
        self.assertFalse(pending, text)
        return process.returncode, text

    def test_missing_probe_cli_aborts_token_change_before_paste_prompt(self) -> None:
        cases = (
            (
                "github",
                "Token verification needs the gh CLI on this host.",
                "https://cli.github.com/",
            ),
            (
                "gitlab",
                "Token verification needs the glab CLI on this host.",
                "https://gitlab.com/gitlab-org/cli/-/releases",
            ),
        )
        for forge, message, install_url in cases:
            with self.subTest(forge=forge), tempfile.TemporaryDirectory() as home:
                store = os.path.join(home, ".config", "boxa", "forge", "identities")
                missing_cli_path = os.path.join(home, "missing-cli-bin")
                os.makedirs(store)
                os.makedirs(missing_cli_path)
                persona = os.path.join(store, "agent")
                persona_text = (
                    "version=2\n"
                    "name=agent\n"
                    "kind=agent\n"
                    "github_created_at=1\n"
                    "github_username=machine-user\n"
                    "github_token=github-secret\n"
                    "gitlab_created_at=1\n"
                    "gitlab_host=gitlab.example\n"
                    "gitlab_username=service-account\n"
                    "gitlab_token=gitlab-secret\n"
                )
                with open(persona, "w", encoding="utf-8") as fh:
                    fh.write(persona_text)
                os.chmod(persona, 0o600)
                harness = os.path.join(home, "missing-cli-harness.sh")
                with open(harness, "w", encoding="utf-8") as fh:
                    fh.write(
                        "#!/usr/bin/bash\n"
                        "set -euo pipefail\n"
                        f"source {ROOT!r}/lib/resources.sh\n"
                        f"source {ROOT!r}/lib/ssh.sh\n"
                        f"source {ROOT!r}/lib/forge.sh\n"
                        'PATH="$BOXA_TEST_MISSING_CLI_PATH"\n'
                        "_BOXA_FORGE_CATALOG_LOCK_HELD=1\n"
                        '_boxa::forge_dashboard_rotate_token_locked agent "$BOXA_TEST_FORGE"\n'
                    )
                os.chmod(harness, 0o700)
                env = dict(os.environ)
                env.update(
                    {
                        "HOME": home,
                        "BOXA_FORGE_DIR": os.path.join(
                            home, ".config", "boxa", "forge"
                        ),
                        "BOXA_TEST_FORGE": forge,
                        "BOXA_TEST_MISSING_CLI_PATH": missing_cli_path,
                    }
                )

                returncode, transcript = self._run_pty([harness], env, [])

                self.assertNotEqual(returncode, 0, transcript)
                self.assertIn(message, transcript)
                self.assertIn(install_url, transcript)
                self.assertNotIn(f"Paste {forge} token:", transcript)
                self.assertNotIn("github-secret", transcript)
                self.assertNotIn("gitlab-secret", transcript)
                with open(persona, encoding="utf-8") as fh:
                    self.assertEqual(fh.read(), persona_text)

    def test_failed_add_reports_that_no_token_was_added(self) -> None:
        cases = (
            (
                "github",
                "github_created_at=\n"
                "github_username=\n"
                "github_token=\n"
                "gitlab_created_at=1\n"
                "gitlab_host=gitlab.example\n"
                "gitlab_username=service-account\n"
                "gitlab_token=gitlab-secret\n",
                [],
            ),
            (
                "gitlab",
                "github_created_at=1\n"
                "github_username=machine-user\n"
                "github_token=github-secret\n"
                "gitlab_created_at=\n"
                "gitlab_host=\n"
                "gitlab_username=\n"
                "gitlab_token=\n",
                [(b"GitLab host [gitlab.com]", b"gitlab.example\n")],
            ),
        )
        for forge, forge_fields, host_interactions in cases:
            with self.subTest(forge=forge), tempfile.TemporaryDirectory() as home:
                store = os.path.join(home, ".config", "boxa", "forge", "identities")
                fake_bin = os.path.join(home, "bin")
                os.makedirs(store)
                os.makedirs(fake_bin)
                persona = os.path.join(store, "agent")
                persona_text = "version=2\nname=agent\nkind=agent\n" + forge_fields
                with open(persona, "w", encoding="utf-8") as fh:
                    fh.write(persona_text)
                os.chmod(persona, 0o600)
                cli = os.path.join(fake_bin, "gh" if forge == "github" else "glab")
                with open(cli, "w", encoding="utf-8") as fh:
                    fh.write("#!/usr/bin/env bash\nexit 9\n")
                os.chmod(cli, 0o700)
                harness = os.path.join(home, "failed-add-harness.sh")
                with open(harness, "w", encoding="utf-8") as fh:
                    fh.write(
                        "#!/usr/bin/env bash\n"
                        "set -euo pipefail\n"
                        f"source {ROOT!r}/lib/resources.sh\n"
                        f"source {ROOT!r}/lib/ssh.sh\n"
                        f"source {ROOT!r}/lib/forge.sh\n"
                        "_BOXA_FORGE_CATALOG_LOCK_HELD=1\n"
                        '_boxa::forge_dashboard_rotate_token_locked agent "$BOXA_TEST_FORGE"\n'
                    )
                os.chmod(harness, 0o700)
                env = dict(os.environ)
                env.update(
                    {
                        "HOME": home,
                        "PATH": fake_bin + os.pathsep + env["PATH"],
                        "BOXA_FORGE_DIR": os.path.join(
                            home, ".config", "boxa", "forge"
                        ),
                        "BOXA_TEST_FORGE": forge,
                    }
                )

                returncode, transcript = self._run_pty(
                    [harness],
                    env,
                    host_interactions
                    + [(f"Paste {forge} token:".encode(), b"invalid-token\n")],
                )

                self.assertNotEqual(returncode, 0, transcript)
                self.assertIn(
                    f"{forge} token verification failed; no token was added "
                    "to persona agent.",
                    transcript,
                )
                self.assertNotIn("the existing token is unchanged", transcript)
                self.assertNotIn("invalid-token", transcript)
                with open(persona, encoding="utf-8") as fh:
                    self.assertEqual(fh.read(), persona_text)

    def test_rotate_token_reports_delta_after_single_dashboard_render(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            config = os.path.join(home, ".config", "boxa")
            store = os.path.join(config, "forge", "identities")
            project = os.path.join(home, "project")
            fake_bin = os.path.join(home, "bin")
            os.makedirs(store)
            os.makedirs(project)
            os.makedirs(fake_bin)
            persona = os.path.join(store, "agent")
            replacement = os.path.join(store, "replacement")
            with open(persona, "w", encoding="utf-8") as fh:
                fh.write(
                    "version=2\n"
                    "name=agent\n"
                    "kind=agent\n"
                    "github_created_at=1\n"
                    "github_username=machine-user\n"
                    "github_token=old-token\n"
                    "gitlab_created_at=\n"
                    "gitlab_host=\n"
                    "gitlab_username=\n"
                    "gitlab_token=\n"
                )
            os.chmod(persona, 0o600)
            with open(replacement, "w", encoding="utf-8") as fh:
                fh.write(
                    "version=2\n"
                    "name=replacement\n"
                    "kind=mine\n"
                    "github_created_at=1\n"
                    "github_username=replacement-user\n"
                    "github_token=replacement-token\n"
                    "gitlab_created_at=\n"
                    "gitlab_host=\n"
                    "gitlab_username=\n"
                    "gitlab_token=\n"
                )
            os.chmod(replacement, 0o600)
            gh = os.path.join(fake_bin, "gh")
            with open(gh, "w", encoding="utf-8") as fh:
                fh.write("#!/usr/bin/env bash\nprintf '%s\\n' '{\"login\":\"machine-user\"}'\n")
            os.chmod(gh, 0o700)
            harness = os.path.join(home, "dashboard-harness.sh")
            with open(harness, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    "set -euo pipefail\n"
                    f"source {ROOT!r}/lib/resources.sh\n"
                    f"source {ROOT!r}/lib/picker.sh\n"
                    f"source {ROOT!r}/lib/ssh.sh\n"
                    f"source {ROOT!r}/lib/allowlist.sh\n"
                    f"source {ROOT!r}/lib/forge.sh\n"
                    "if [ -n \"${BOXA_TEST_PAUSE_MIGRATION:-}\" ]; then\n"
                    "  eval \"$(declare -f _boxa::write_ssh_conf "
                    "| sed '1s/_boxa::write_ssh_conf/_boxa::write_ssh_conf_real/')\"\n"
                    "  _boxa::write_ssh_conf() {\n"
                    "    if [ \"$1\" = project ] "
                    "&& [ \"$2\" = \"$BOXA_TEST_PROJECT_A\" ] "
                    "&& [ ! -e \"$BOXA_TEST_MIGRATION_MARKER\" ]; then\n"
                    "      : > \"$BOXA_TEST_MIGRATION_MARKER\"\n"
                    "      while [ ! -e \"$BOXA_TEST_MIGRATION_RELEASE\" ]; do "
                    "sleep 0.01; done\n"
                    "    fi\n"
                    "    _boxa::write_ssh_conf_real \"$@\"\n"
                    "  }\n"
                    "fi\n"
                    "_boxa::forge_project_targets() {\n"
                    '  printf "Current Project\\t%s\\n" "$BOXA_TEST_PROJECT"\n'
                    "}\n"
                    '_boxa::forge_dashboard "$BOXA_TEST_PROJECT"\n'
                )
            os.chmod(harness, 0o700)
            env = dict(os.environ)
            env.update(
                {
                    "HOME": home,
                    "PATH": fake_bin + os.pathsep + env["PATH"],
                    "BOXA_PICKER_FZF": "0",
                    "BOXA_FORGE_DIR": os.path.join(config, "forge"),
                    "BOXA_FORGE_CONF": os.path.join(config, "forge.conf"),
                    "BOXA_SSH_CONF": os.path.join(config, "ssh.conf"),
                    "BOXA_TEST_PROJECT": project,
                }
            )
            with open(env["BOXA_FORGE_CONF"], "w", encoding="utf-8") as fh:
                fh.write(f"[{project}]\nforge = on\nidentity = agent\n")
            with open(env["BOXA_SSH_CONF"], "w", encoding="utf-8") as fh:
                fh.write(f"[{project}]\ngate = on\n")

            returncode, transcript = self._run_pty(
                [harness],
                env,
                [
                    (b"Forge action: (number/q)", b"2\n"),
                    (b"Use persona (number/q)", b"2\n"),
                    (b"Assign 'replacement' in Projects", b"a\n"),
                    (b"Forge action: (number/q)", b"5\n"),
                    (b"Persona: (number/q)", b"1\n"),
                    (b"Add or rotate token: (number/q)", b"1\n"),
                    (b"Paste github token:", b"new-token\n"),
                    (b"Forge action: (number/q)", b"7\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertEqual(transcript.count("=== Forge dashboard ==="), 1)
            self.assertIn("Add or rotate a token", transcript)
            self.assertIn("GitHub — rotate the existing token", transcript)
            self.assertIn("GitLab — add a token", transcript)
            self.assertIn("configured forges: GitHub", transcript)
            self.assertIn("token: ol…en", transcript)
            self.assertNotIn("old-token", transcript)
            self.assertNotIn("replacement-token", transcript)
            self.assertIn("forge gate: on | SSH gate: on", transcript)
            self.assertIn(
                "MISSING: SSH gate is on but the assigned persona has no keys.",
                transcript,
            )
            self.assertEqual(transcript.count("Persona assignment summary:"), 1)
            self.assertIn(
                f"{project}: agent -> replacement; its SSH keys will not be "
                "forwarded into this project's ssh-agent (gate off) "
                "[container recreation needed: forge environment changed; "
                "SSH forwarding on -> off]",
                transcript,
            )
            self.assertIn("github token rotated for persona agent", transcript)
            self.assertIn("Forge dashboard complete. Assigned personas", transcript)
            self.assertNotIn("new-token", transcript)
            with open(persona, encoding="utf-8") as fh:
                persona_text = fh.read()
            self.assertIn("version=3", persona_text)
            self.assertNotIn("new-token", persona_text)
            self.assertNotIn("old-token", persona_text)
            token_path = os.path.join(config, "forge", "tokens", "agent.github")
            with open(token_path, encoding="utf-8") as fh:
                self.assertEqual(fh.read(), "new-token\n")
            self.assertEqual(os.stat(token_path).st_mode & 0o777, 0o600)

    def test_adds_missing_gitlab_token_to_existing_persona(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            config = os.path.join(home, ".config", "boxa")
            store = os.path.join(config, "forge", "identities")
            project = os.path.join(home, "project")
            fake_bin = os.path.join(home, "bin")
            os.makedirs(store)
            os.makedirs(project)
            os.makedirs(fake_bin)
            persona = os.path.join(store, "agent")
            with open(persona, "w", encoding="utf-8") as fh:
                fh.write(
                    "version=2\n"
                    "name=agent\n"
                    "kind=agent\n"
                    "github_created_at=1\n"
                    "github_username=machine-user\n"
                    "github_token=github-secret\n"
                    "gitlab_created_at=\n"
                    "gitlab_host=\n"
                    "gitlab_username=\n"
                    "gitlab_token=\n"
                )
            os.chmod(persona, 0o600)
            gh = os.path.join(fake_bin, "gh")
            with open(gh, "w", encoding="utf-8") as fh:
                fh.write("#!/usr/bin/env bash\nprintf '%s\\n' '{\"login\":\"machine-user\"}'\n")
            os.chmod(gh, 0o700)
            glab = os.path.join(fake_bin, "glab")
            with open(glab, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    '[ "${GITLAB_TOKEN:-}" = gitlab-secret ] || exit 9\n'
                    '[ "${GITLAB_HOST:-}" = gitlab.example ] || exit 8\n'
                    "printf '%s\\n' '{\"username\":\"service-account\"}'\n"
                )
            os.chmod(glab, 0o700)
            harness = os.path.join(home, "dashboard-harness.sh")
            with open(harness, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    "set -euo pipefail\n"
                    f"source {ROOT!r}/lib/resources.sh\n"
                    f"source {ROOT!r}/lib/picker.sh\n"
                    f"source {ROOT!r}/lib/ssh.sh\n"
                    f"source {ROOT!r}/lib/allowlist.sh\n"
                    f"source {ROOT!r}/lib/forge.sh\n"
                    "_boxa::forge_project_targets() {\n"
                    '  printf "Current Project\\t%s\\n" "$BOXA_TEST_PROJECT"\n'
                    "}\n"
                    '_boxa::forge_dashboard "$BOXA_TEST_PROJECT"\n'
                )
            os.chmod(harness, 0o700)
            env = dict(os.environ)
            env.update(
                {
                    "HOME": home,
                    "PATH": fake_bin + os.pathsep + env["PATH"],
                    "BOXA_PICKER_FZF": "0",
                    "BOXA_FORGE_DIR": os.path.join(config, "forge"),
                    "BOXA_FORGE_CONF": os.path.join(config, "forge.conf"),
                    "BOXA_SSH_CONF": os.path.join(config, "ssh.conf"),
                    "BOXA_TEST_PROJECT": project,
                }
            )
            with open(env["BOXA_FORGE_CONF"], "w", encoding="utf-8") as fh:
                fh.write(f"[{project}]\nforge = on\nidentity = agent\n")

            returncode, transcript = self._run_pty(
                [harness],
                env,
                [
                    (b"Forge action: (number/q)", b"5\n"),
                    (b"Persona: (number/q)", b"1\n"),
                    (b"Add or rotate token: (number/q)", b"2\n"),
                    (b"GitLab host [gitlab.com]", b"gitlab.example\n"),
                    (b"Paste gitlab token:", b"gitlab-secret\n"),
                    (b"Forge action: (number/q)", b"7\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertIn("Add or rotate a token", transcript)
            self.assertIn("GitHub — rotate the existing token", transcript)
            self.assertIn("GitLab — add a token", transcript)
            mint_url = (
                "https://gitlab.example/-/user_settings/personal_access_tokens"
            )
            self.assertIn(mint_url, transcript)
            self.assertLess(
                transcript.index(mint_url), transcript.index("Paste gitlab token:")
            )
            self.assertIn(
                "token must belong to the separate automation account", transcript
            )
            self.assertIn(
                "gitlab token configured for persona agent; authenticated as "
                "service-account.",
                transcript,
            )
            self.assertNotIn("github-secret", transcript)
            self.assertNotIn("gitlab-secret", transcript)
            with open(persona, encoding="utf-8") as fh:
                persona_text = fh.read()
            self.assertIn("github_username=machine-user", persona_text)
            self.assertIn("gitlab_host=gitlab.example", persona_text)
            self.assertIn("gitlab_username=service-account", persona_text)
            github_token = os.path.join(config, "forge", "tokens", "agent.github")
            gitlab_token = os.path.join(config, "forge", "tokens", "agent.gitlab")
            with open(github_token, encoding="utf-8") as fh:
                self.assertEqual(fh.read(), "github-secret\n")
            with open(gitlab_token, encoding="utf-8") as fh:
                self.assertEqual(fh.read(), "gitlab-secret\n")

    def test_adds_missing_github_token_to_existing_persona(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            config = os.path.join(home, ".config", "boxa")
            store = os.path.join(config, "forge", "identities")
            project = os.path.join(home, "project")
            fake_bin = os.path.join(home, "bin")
            os.makedirs(store)
            os.makedirs(project)
            os.makedirs(fake_bin)
            persona = os.path.join(store, "agent")
            with open(persona, "w", encoding="utf-8") as fh:
                fh.write(
                    "version=2\n"
                    "name=agent\n"
                    "kind=agent\n"
                    "github_created_at=\n"
                    "github_username=\n"
                    "github_token=\n"
                    "gitlab_created_at=1\n"
                    "gitlab_host=gitlab.example.com\n"
                    "gitlab_username=service-account\n"
                    "gitlab_token=gitlab-secret\n"
                )
            os.chmod(persona, 0o600)
            gh = os.path.join(fake_bin, "gh")
            with open(gh, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    '[ "${GH_TOKEN:-}" = github-secret ] || exit 9\n'
                    "printf '%s\\n' '{\"login\":\"machine-user\"}'\n"
                )
            os.chmod(gh, 0o700)
            glab = os.path.join(fake_bin, "glab")
            with open(glab, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    '[ "${GITLAB_TOKEN:-}" = gitlab-secret ] || exit 9\n'
                    '[ "${GITLAB_HOST:-}" = gitlab.example.com ] || exit 8\n'
                    "printf '%s\\n' '{\"username\":\"service-account\"}'\n"
                )
            os.chmod(glab, 0o700)
            harness = os.path.join(home, "dashboard-harness.sh")
            with open(harness, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    "set -euo pipefail\n"
                    f"source {ROOT!r}/lib/resources.sh\n"
                    f"source {ROOT!r}/lib/picker.sh\n"
                    f"source {ROOT!r}/lib/ssh.sh\n"
                    f"source {ROOT!r}/lib/allowlist.sh\n"
                    f"source {ROOT!r}/lib/forge.sh\n"
                    "_boxa::forge_project_targets() {\n"
                    '  printf "Current Project\\t%s\\n" "$BOXA_TEST_PROJECT"\n'
                    "}\n"
                    '_boxa::forge_dashboard "$BOXA_TEST_PROJECT"\n'
                )
            os.chmod(harness, 0o700)
            env = dict(os.environ)
            env.update(
                {
                    "HOME": home,
                    "PATH": fake_bin + os.pathsep + env["PATH"],
                    "BOXA_PICKER_FZF": "0",
                    "BOXA_FORGE_DIR": os.path.join(config, "forge"),
                    "BOXA_FORGE_CONF": os.path.join(config, "forge.conf"),
                    "BOXA_SSH_CONF": os.path.join(config, "ssh.conf"),
                    "BOXA_TEST_PROJECT": project,
                }
            )
            with open(env["BOXA_FORGE_CONF"], "w", encoding="utf-8") as fh:
                fh.write(f"[{project}]\nforge = on\nidentity = agent\n")

            returncode, transcript = self._run_pty(
                [harness],
                env,
                [
                    (b"Forge action: (number/q)", b"5\n"),
                    (b"Persona: (number/q)", b"1\n"),
                    (b"Add or rotate token: (number/q)", b"1\n"),
                    (b"Paste github token:", b"github-secret\n"),
                    (b"Forge action: (number/q)", b"7\n"),
                ],
            )

            self.assertEqual(returncode, 0, transcript)
            self.assertIn("Add or rotate a token", transcript)
            self.assertIn("GitHub — add a token", transcript)
            self.assertIn("GitLab — rotate the existing token", transcript)
            self.assertIn(
                "github token configured for persona agent; authenticated as "
                "machine-user.",
                transcript,
            )
            self.assertNotIn("github-secret", transcript)
            self.assertNotIn("gitlab-secret", transcript)
            with open(persona, encoding="utf-8") as fh:
                persona_text = fh.read()
            self.assertIn("version=3", persona_text)
            self.assertIn("github_username=machine-user", persona_text)
            self.assertIn("gitlab_host=gitlab.example.com", persona_text)
            self.assertIn("gitlab_username=service-account", persona_text)
            github_token = os.path.join(config, "forge", "tokens", "agent.github")
            gitlab_token = os.path.join(config, "forge", "tokens", "agent.gitlab")
            with open(github_token, encoding="utf-8") as fh:
                self.assertEqual(fh.read(), "github-secret\n")
            with open(gitlab_token, encoding="utf-8") as fh:
                self.assertEqual(fh.read(), "gitlab-secret\n")

    def test_signal_after_persona_metadata_rename_keeps_new_tokens(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            config = os.path.join(home, ".config", "boxa")
            store = os.path.join(config, "forge", "identities")
            token_store = os.path.join(config, "forge", "tokens")
            fake_bin = os.path.join(home, "bin")
            os.makedirs(store)
            os.makedirs(token_store)
            os.makedirs(fake_bin)
            persona = os.path.join(store, "agent")
            github_token = os.path.join(token_store, "agent.github")
            gitlab_token = os.path.join(token_store, "agent.gitlab")
            with open(persona, "w", encoding="utf-8") as fh:
                fh.write(
                    "version=3\n"
                    "name=agent\n"
                    "kind=agent\n"
                    "github_created_at=1\n"
                    "github_username=old-user\n"
                    "gitlab_created_at=1\n"
                    "gitlab_host=gitlab.example\n"
                    "gitlab_username=old-gitlab-user\n"
                )
            with open(github_token, "w", encoding="utf-8") as fh:
                fh.write("old-github\n")
            with open(gitlab_token, "w", encoding="utf-8") as fh:
                fh.write("old-gitlab\n")
            os.chmod(persona, 0o600)
            os.chmod(github_token, 0o600)
            os.chmod(gitlab_token, 0o600)

            mv = os.path.join(fake_bin, "mv")
            with open(mv, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    "set -u\n"
                    "/usr/bin/mv \"$@\" || exit\n"
                    "if [[ \"$1\" == \"$BOXA_TEST_PERSONA.tmp.\"* "
                    "&& \"$2\" = \"$BOXA_TEST_PERSONA\" ]]; then\n"
                    "  kill -TERM \"$PPID\"\n"
                    "fi\n"
                )
            os.chmod(mv, 0o700)
            harness = os.path.join(home, "persona-publication-harness.sh")
            with open(harness, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    "set -u\n"
                    f"source {ROOT!r}/lib/resources.sh\n"
                    f"source {ROOT!r}/lib/ssh.sh\n"
                    f"source {ROOT!r}/lib/forge.sh\n"
                    "_boxa::forge_write_persona agent mine '' "
                    "new-github new-user 2 new-gitlab new-gitlab-user "
                    "gitlab.example 2 true\n"
                )
            os.chmod(harness, 0o700)
            env = dict(os.environ)
            env.update(
                {
                    "HOME": home,
                    "PATH": fake_bin + os.pathsep + env["PATH"],
                    "BOXA_FORGE_DIR": os.path.join(config, "forge"),
                    "BOXA_TEST_PERSONA": persona,
                }
            )

            returncode, transcript = self._run_pty([harness], env, [])

            self.assertEqual(returncode, 143, transcript)
            with open(persona, encoding="utf-8") as fh:
                persona_text = fh.read()
            self.assertIn("kind=mine", persona_text)
            self.assertIn("github_username=new-user", persona_text)
            with open(github_token, encoding="utf-8") as fh:
                self.assertEqual(fh.read(), "new-github\n")
            with open(gitlab_token, encoding="utf-8") as fh:
                self.assertEqual(fh.read(), "new-gitlab\n")
            self.assertEqual(glob(os.path.join(token_store, "*.backup.*")), [])

    def test_legacy_gate_migration_requires_consent_and_clears_dashboard_noise(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as home:
            config = os.path.join(home, ".config", "boxa")
            store = os.path.join(config, "forge", "identities")
            project_a = os.path.join(home, "project-a")
            project_b = os.path.join(home, "project-b")
            project_c = os.path.join(home, "project-c")
            fake_bin = os.path.join(home, "bin")
            os.makedirs(store)
            os.makedirs(project_a)
            os.makedirs(project_b)
            os.makedirs(project_c)
            os.makedirs(fake_bin)
            persona = os.path.join(store, "available")
            with open(persona, "w", encoding="utf-8") as fh:
                fh.write(
                    "version=2\n"
                    "name=available\n"
                    "kind=mine\n"
                    "github_created_at=1\n"
                    "github_username=available-user\n"
                    "github_token=available-token\n"
                    "gitlab_created_at=\n"
                    "gitlab_host=\n"
                    "gitlab_username=\n"
                    "gitlab_token=\n"
            )
            os.chmod(persona, 0o600)
            gh = os.path.join(fake_bin, "gh")
            with open(gh, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    "printf '%s\\n' '{\"login\":\"available-user\"}'\n"
                )
            os.chmod(gh, 0o700)
            harness = os.path.join(home, "legacy-dashboard-harness.sh")
            with open(harness, "w", encoding="utf-8") as fh:
                fh.write(
                    "#!/usr/bin/env bash\n"
                    "set -euo pipefail\n"
                    f"source {ROOT!r}/lib/resources.sh\n"
                    f"source {ROOT!r}/lib/picker.sh\n"
                    f"source {ROOT!r}/lib/ssh.sh\n"
                    f"source {ROOT!r}/lib/allowlist.sh\n"
                    f"source {ROOT!r}/lib/forge.sh\n"
                    "_boxa::forge_project_targets() {\n"
                    '  printf "Project A\\t%s\\n" "$BOXA_TEST_PROJECT_A"\n'
                    '  printf "Project B\\t%s\\n" "$BOXA_TEST_PROJECT_B"\n'
                    '  printf "Project C\\t%s\\n" "$BOXA_TEST_PROJECT_C"\n'
                    "}\n"
                    '_boxa::forge_dashboard "$BOXA_TEST_PROJECT_A" "" '
                    '"${BOXA_TEST_MODE:-interactive}"\n'
                )
            os.chmod(harness, 0o700)
            env = dict(os.environ)
            env.update(
                {
                    "HOME": home,
                    "PATH": fake_bin + os.pathsep + env["PATH"],
                    "BOXA_PICKER_FZF": "0",
                    "BOXA_FORGE_DIR": os.path.join(config, "forge"),
                    "BOXA_FORGE_CONF": os.path.join(config, "forge.conf"),
                    "BOXA_SSH_CONF": os.path.join(config, "ssh.conf"),
                    "BOXA_TEST_PROJECT_A": project_a,
                    "BOXA_TEST_PROJECT_B": project_b,
                    "BOXA_TEST_PROJECT_C": project_c,
                    "BOXA_AGENT_IDENTITY_DIR": os.path.join(
                        config, "agent-identity"
                    ),
                }
            )
            agent_key = os.path.join(env["BOXA_AGENT_IDENTITY_DIR"], "id_ed25519")
            os.makedirs(os.path.dirname(agent_key))
            subprocess.run(
                [
                    "ssh-keygen",
                    "-q",
                    "-t",
                    "ed25519",
                    "-N",
                    "",
                    "-C",
                    "legacy-agent@test",
                    "-f",
                    agent_key,
                ],
                check=True,
                timeout=10,
            )
            with open(env["BOXA_SSH_CONF"], "w", encoding="utf-8") as fh:
                fh.write(
                    f"gate = on\n[{project_a}]\nagent = agent\n"
                    f"[{project_c}]\nagent = agent\ngate = off\n"
                )
            existing_project_c_key = os.path.join(home, "project-c-existing-key")
            with open(existing_project_c_key, "w", encoding="utf-8") as fh:
                fh.write("existing\n")
            registry = os.path.join(config, "ssh-key-registry")
            with open(registry, "w", encoding="utf-8") as fh:
                fh.write(f"[{project_c}]\nkey = {existing_project_c_key}\n")
            with open(env["BOXA_SSH_CONF"], "rb") as fh:
                legacy_bytes = fh.read()

            returncode, declined = self._run_pty(
                [harness],
                env,
                [
                    (b"Migrate legacy SSH gates now? [y/N]", b"n\n"),
                    (b"Forge action: (number/q)", b"8\n"),
                ],
            )
            self.assertEqual(returncode, 0, declined)
            self.assertEqual(
                declined.count("Migrate legacy SSH gates now? [y/N]"), 1
            )
            self.assertIn(
                "Legacy SSH gate migration declined; config unchanged.", declined
            )
            with open(env["BOXA_SSH_CONF"], "rb") as fh:
                self.assertEqual(fh.read(), legacy_bytes)
            decline_marker = os.path.join(
                env["BOXA_FORGE_DIR"], "legacy-ssh-gate-migration-declined"
            )
            self.assertTrue(os.path.isfile(decline_marker))
            self.assertEqual(os.stat(decline_marker).st_mode & 0o777, 0o600)
            self.assertEqual(declined.count("SSH gate: on (legacy)"), 1)
            self.assertIn(f"{project_c} | persona: none | forge gate: off | SSH gate: off", declined)
            self.assertEqual(
                declined.count(
                    "MISSING: SSH gate is on without an assigned persona or keys "
                    "for Projects:"
                ),
                1,
            )
            self.assertIn(
                "MISSING: SSH gate is on without an assigned persona or keys "
                f"for Projects: {project_a}, {project_b}.",
                declined,
            )

            returncode, declined_again = self._run_pty(
                [harness],
                env,
                [(b"Forge action: (number/q)", b"8\n")],
            )
            self.assertEqual(returncode, 0, declined_again)
            self.assertNotIn(
                "Migrate legacy SSH gates now? [y/N]", declined_again
            )
            self.assertIn("Migrate legacy SSH gates", declined_again)
            with open(env["BOXA_SSH_CONF"], "rb") as fh:
                self.assertEqual(fh.read(), legacy_bytes)

            marker = os.path.join(home, "migration-paused")
            release = os.path.join(home, "migration-release")
            env["BOXA_TEST_PAUSE_MIGRATION"] = "1"
            env["BOXA_TEST_MIGRATION_MARKER"] = marker
            env["BOXA_TEST_MIGRATION_RELEASE"] = release
            writer_result: list[subprocess.CompletedProcess[str]] = []

            def run_concurrent_gate_off() -> None:
                deadline = time.monotonic() + 10
                while not os.path.exists(marker) and time.monotonic() < deadline:
                    time.sleep(0.01)
                writer = subprocess.Popen(
                    [
                        "bash",
                        "-c",
                        f"source {ROOT!r}/lib/resources.sh; "
                        f"source {ROOT!r}/lib/ssh.sh; "
                        '_boxa::write_ssh_conf project "$BOXA_TEST_PROJECT_A" off',
                    ],
                    env=env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                time.sleep(0.2)
                with open(release, "w", encoding="utf-8"):
                    pass
                stdout, stderr = writer.communicate(timeout=10)
                writer_result.append(
                    subprocess.CompletedProcess(
                        writer.args, writer.returncode, stdout, stderr
                    )
                )

            writer_thread = threading.Thread(target=run_concurrent_gate_off)
            writer_thread.start()
            returncode, accepted = self._run_pty(
                [harness],
                env,
                [
                    (b"Forge action: (number/q)", b"7\n"),
                    (b"Migrate legacy SSH gates now? [y/N]", b"y\n"),
                    (b"Forge action: (number/q)", b"7\n"),
                ],
            )
            writer_thread.join(timeout=12)
            self.assertEqual(returncode, 0, accepted)
            self.assertFalse(writer_thread.is_alive(), accepted)
            self.assertEqual(len(writer_result), 1, accepted)
            self.assertEqual(writer_result[0].returncode, 0, writer_result[0].stderr)
            self.assertIn(
                "Migrated legacy SSH gate config to explicit values for 2 Project(s).",
                accepted,
            )
            self.assertIn(f"{project_c}: off", accepted)
            with open(env["BOXA_SSH_CONF"], encoding="utf-8") as fh:
                migrated = fh.read()
            self.assertNotIn("agent", migrated)
            self.assertTrue(migrated.startswith("gate = on\n"), migrated)
            self.assertIn(f"[{project_a}]\ngate = off", migrated)
            self.assertNotIn(f"[{project_b}]", migrated)
            self.assertIn(f"[{project_c}]\ngate = off", migrated)
            with open(registry, encoding="utf-8") as fh:
                registry_text = fh.read()
            self.assertIn(f"[{project_a}]\nkey = {agent_key}", registry_text)
            self.assertIn(
                f"[{project_c}]\nkey = {existing_project_c_key}", registry_text
            )
            self.assertFalse(os.path.exists(decline_marker))

            render_env = dict(env)
            render_env["BOXA_TEST_MODE"] = "noninteractive"
            rendered = subprocess.run(
                [harness],
                env=render_env,
                text=True,
                capture_output=True,
                check=False,
            )
            post_migration = rendered.stdout + rendered.stderr
            self.assertEqual(rendered.returncode, 0, post_migration)
            self.assertNotIn("(legacy)", post_migration)
            self.assertNotIn("NOTE: Legacy SSH gate values", post_migration)
            self.assertNotIn("Migrate legacy SSH gates", post_migration)

            with open(env["BOXA_SSH_CONF"], "wb") as fh:
                fh.write(legacy_bytes)
            returncode, proactively_accepted = self._run_pty(
                [harness],
                env,
                [
                    (b"Migrate legacy SSH gates now? [y/N]", b"y\n"),
                    (b"Forge action: (number/q)", b"7\n"),
                ],
            )
            self.assertEqual(returncode, 0, proactively_accepted)
            self.assertEqual(
                proactively_accepted.count(
                    "Migrate legacy SSH gates now? [y/N]"
                ),
                1,
            )
            self.assertIn(
                "Migrated legacy SSH gate config to explicit values for "
                "2 Project(s).",
                proactively_accepted,
            )
            with open(env["BOXA_SSH_CONF"], encoding="utf-8") as fh:
                self.assertNotIn("agent", fh.read())


if __name__ == "__main__":
    unittest.main()
