"""ADR 0021 issue 02: Project activation, Claude rendering, broker gate."""

from __future__ import annotations

import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import tomllib
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import activation, broker, cli as mcp_cli, lifecycle, protocol, trusted  # noqa: E402
from mcp.catalog import add_entry, update_entry  # noqa: E402


class ReadyProbe(activation.DockerProbe):
    def __init__(self, project: str, ready: bool = True):
        self.project = project
        self.is_ready = ready

    def find_running(self, project_key: str):
        return "boxa-app" if project_key == self.project else None

    def ready(self, container, entry):
        return self.is_ready and container == "boxa-app"


class ActivationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = {k: os.environ.get(k) for k in ("HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR")}
        self.addCleanup(self.restore)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(self.tmp.name, ".claude")
        os.makedirs(os.environ["CLAUDE_CONFIG_DIR"], exist_ok=True)
        runtime_patch = mock.patch.object(
            trusted, "RUNTIME_SNAPSHOT_PATH", activation.runtime_path()
        )
        runtime_patch.start()
        self.addCleanup(runtime_patch.stop)
        self.project = activation.canonical_project(os.path.join(self.tmp.name, "project"))
        os.makedirs(self.project)
        added = add_entry("echo", ["npx", "placeholder"])
        self.entry = update_entry(added["id"], argv=["/bin/cat"])
        inactive = add_entry("inactive", ["npx", "placeholder"])
        self.inactive = update_entry(inactive["id"], argv=["/bin/cat"])

    def restore(self):
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _transaction_paths(self):
        return (
            activation.activation_path(),
            activation.runtime_path(),
            os.path.join(os.environ["CLAUDE_CONFIG_DIR"], ".claude.json"),
            activation.render_state_path(),
            activation.claude_config_path(self.project),
            activation.claude_settings_path(self.project),
        )

    def _file_states(self):
        states = {}
        for path in self._transaction_paths():
            if os.path.exists(path):
                with open(path, "rb") as fh:
                    states[path] = (
                        True,
                        fh.read(),
                        stat.S_IMODE(os.stat(path).st_mode),
                    )
            else:
                states[path] = (False, b"", 0)
        return states

    def _git(self, *args, cwd=None):
        return subprocess.run(
            ["git", *("-C", cwd or self.project), *args],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        ).stdout.strip()

    def _init_git(self):
        self._git("init", "-q")
        self._git("config", "user.email", "boxa-tests@example.invalid")
        self._git("config", "user.name", "Boxa Tests")

    def _codex_text(self, project=None):
        with open(activation.codex_config_path(project or self.project), encoding="utf-8") as fh:
            return fh.read()

    def _claude_data(self, project=None):
        with open(
            activation.claude_config_path(project or self.project),
            encoding="utf-8",
        ) as fh:
            return json.load(fh)

    def _claude_settings_data(self, project=None):
        with open(
            activation.claude_settings_path(project or self.project),
            encoding="utf-8",
        ) as fh:
            return json.load(fh)

    def _write_claude_decisions(self, enabled=None, disabled=None, **record):
        record["enabledMcpjsonServers"] = enabled or []
        record["disabledMcpjsonServers"] = disabled or []
        data = {
            "theme": "keep",
            "projects": {
                self.project: record,
                "/unrelated/project": {"setting": "keep"},
            },
        }
        path = activation.render_target_path()
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        return path

    def test_activate_records_identity_project_and_consumer_only(self):
        result = activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        self.assertTrue(result.changed)
        stored = activation.load_activations()
        record = stored["projects"][self.project][self.entry["id"]]
        self.assertEqual(record, {"catalogId": self.entry["id"], "consumers": ["claude"], "enabled": True})
        self.assertNotIn("command", record)
        self.assertEqual(stat.S_IMODE(os.stat(activation.activation_path()).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(activation.runtime_path()).st_mode), 0o644)
        self.assertEqual(
            stat.S_IMODE(os.stat(os.path.dirname(activation.runtime_path())).st_mode),
            0o755,
        )

    def test_activate_requires_running_ready_target_and_explicit_consumer(self):
        with self.assertRaisesRegex(activation.ActivationError, "explicit supported consumer"):
            activation.activate("echo", self.project, [], ReadyProbe(self.project))
        with self.assertRaisesRegex(activation.ActivationError, "not running"):
            activation.activate("echo", self.project, ["claude"], ReadyProbe("/other"))
        with self.assertRaisesRegex(activation.ActivationError, "not ready"):
            activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project, False))

    def test_docker_secret_activation_requires_one_atomic_acknowledgement(self):
        docker = add_entry(
            "docker-secret", ["docker", "run", "-e", "API_TOKEN", "image:1"]
        )
        before = self._file_states()
        with self.assertRaisesRegex(activation.ActivationError, "degraded-secret-isolation"):
            activation.activate(
                docker["id"], self.project, ["claude"], ReadyProbe(self.project)
            )
        self.assertEqual(self._file_states(), before)
        self.assertEqual(activation.load_activations().get("acknowledgements", {}), {})

        result = activation.activate(
            docker["id"], self.project, ["claude"], ReadyProbe(self.project),
            accept_degraded_secret_isolation=True,
        )
        self.assertTrue(result.changed)
        stored = activation.load_activations()
        self.assertTrue(stored["acknowledgements"][self.project][docker["id"]])
        row = next(e for e in activation.effective_catalog(self.project) if e["id"] == docker["id"])
        self.assertEqual(row["isolationStatus"], "degraded-secret-isolation")
        self.assertNotIn("API_TOKEN", json.dumps(row))
        report = lifecycle.run_doctor().to_dict()
        degraded = [
            finding for finding in report["findings"]
            if finding["code"] == "degraded-secret-isolation"
        ]
        self.assertEqual(len(degraded), 1)
        self.assertNotIn("API_TOKEN", json.dumps(degraded))

        activation.deactivate(docker["id"], self.project)
        # Acknowledgement attaches to stable identity + Project and survives a
        # deactivation; subsequent activation needs no repeated prompt.
        activation.activate(
            docker["id"], self.project, ["claude"], ReadyProbe(self.project)
        )

    def test_render_is_project_only_and_preserves_manual_configuration(self):
        config = activation.claude_config_path(self.project)
        with open(config, "w", encoding="utf-8") as fh:
            json.dump({
                "theme": "dark",
                "mcpServers": {"manual": {"command": "y"}},
            }, fh)
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        rendered = self._claude_data()
        self.assertEqual(rendered["theme"], "dark")
        block = rendered["mcpServers"]
        self.assertIn("manual", block)
        managed = block["boxa-echo"]
        self.assertEqual(managed["command"], "boxa-mcp-run")
        self.assertEqual(managed["args"][0:4], ["--catalog-id", self.entry["id"], "--consumer", "claude"])
        legacy = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], ".claude.json")
        self.assertFalse(os.path.exists(legacy))

    def test_claude_activation_seeds_project_approval(self):
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))

        settings = self._claude_settings_data()
        self.assertEqual(settings["enabledMcpjsonServers"], ["boxa-echo"])
        self.assertNotIn("enableAllProjectMcpServers", settings)

    def test_claude_approval_seed_preserves_unrelated_settings(self):
        path = activation.claude_settings_path(self.project)
        os.makedirs(os.path.dirname(path))
        original = {
            "permissions": {
                "allow": ["Bash(git status:*)"],
                "deny": ["Read(./.env)"],
            },
            "hooks": {"Stop": [{"command": "notify"}]},
            "userSetting": {"nested": True},
            "enabledMcpjsonServers": ["manual"],
            "disabledMcpjsonServers": ["manual-disabled", "boxa-echo"],
        }
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(original, fh, indent=2)
            fh.write("\n")

        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))

        settings = self._claude_settings_data()
        self.assertEqual(settings["permissions"], original["permissions"])
        self.assertEqual(settings["hooks"], original["hooks"])
        self.assertEqual(settings["userSetting"], original["userSetting"])
        self.assertEqual(settings["enabledMcpjsonServers"], ["manual", "boxa-echo"])
        self.assertEqual(settings["disabledMcpjsonServers"], ["manual-disabled"])

    def test_claude_approval_is_seeded_only_once(self):
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        path = activation.claude_settings_path(self.project)
        settings = self._claude_settings_data()
        settings["enabledMcpjsonServers"].remove("boxa-echo")
        settings["disabledMcpjsonServers"] = ["manual", "boxa-echo"]
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(settings, fh, indent=2)
            fh.write("\n")
        before = os.stat(path).st_mtime_ns

        activation.render_claude_activations()

        self.assertEqual(os.stat(path).st_mtime_ns, before)
        self.assertEqual(
            self._claude_settings_data()["disabledMcpjsonServers"],
            ["manual", "boxa-echo"],
        )
        self.assertNotIn(
            "boxa-echo",
            self._claude_settings_data()["enabledMcpjsonServers"],
        )

    def test_claude_approval_does_not_seed_foreign_shaped_server(self):
        path = activation.claude_config_path(self.project)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({
                "mcpServers": {
                    "boxa-foreign": {"command": "foreign"},
                },
            }, fh)

        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))

        self.assertIn("boxa-foreign", self._claude_data()["mcpServers"])
        self.assertEqual(
            self._claude_settings_data()["enabledMcpjsonServers"],
            ["boxa-echo"],
        )

    def test_unanswered_foreign_claude_server_is_not_mirrored(self):
        path = activation.claude_config_path(self.project)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(
                {"mcpServers": {"foreign": {"command": "foreign"}}},
                fh,
            )
        self._write_claude_decisions()

        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))

        settings = self._claude_settings_data()
        self.assertNotIn("foreign", settings["enabledMcpjsonServers"])
        self.assertNotIn("foreign", settings.get("disabledMcpjsonServers", []))

    def test_approved_foreign_claude_server_is_mirrored(self):
        self._write_claude_decisions(enabled=["foreign"])

        self.assertTrue(activation.mirror_claude_decisions(self.project))

        settings = self._claude_settings_data()
        self.assertEqual(settings["enabledMcpjsonServers"], ["foreign"])
        self.assertNotIn("disabledMcpjsonServers", settings)

    def test_render_mirrors_decisions_without_boxa_rendered_claude_names(self):
        data = activation.empty_activations()
        data["projects"][self.project] = {
            self.entry["id"]: {
                "catalogId": self.entry["id"],
                "consumers": ["codex"],
                "enabled": True,
            },
        }
        self._write_claude_decisions(enabled=["foreign"])

        activation.render_claude_activations(data)

        self.assertEqual(
            self._claude_settings_data()["enabledMcpjsonServers"],
            ["foreign"],
        )

    def test_rejected_foreign_claude_server_is_mirrored_only_as_disabled(self):
        self._write_claude_decisions(disabled=["foreign"])

        self.assertTrue(activation.mirror_claude_decisions(self.project))

        settings = self._claude_settings_data()
        self.assertEqual(settings["disabledMcpjsonServers"], ["foreign"])
        self.assertNotIn("foreign", settings["enabledMcpjsonServers"])

    def test_contradictory_claude_decision_is_mirrored_as_disabled(self):
        self._write_claude_decisions(
            enabled=["foreign"],
            disabled=["foreign"],
        )

        activation.mirror_claude_decisions(self.project)

        settings = self._claude_settings_data()
        self.assertEqual(settings["disabledMcpjsonServers"], ["foreign"])
        self.assertNotIn("foreign", settings["enabledMcpjsonServers"])

    def test_recorded_rejection_wins_over_seed_on_every_render(self):
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        self._write_claude_decisions(disabled=["boxa-echo"])

        activation.render_claude_activations()
        first = self._claude_settings_data()
        activation.render_claude_activations()

        self.assertEqual(self._claude_settings_data(), first)
        self.assertEqual(first["disabledMcpjsonServers"], ["boxa-echo"])
        self.assertNotIn("boxa-echo", first["enabledMcpjsonServers"])

    def test_mirrored_claude_decisions_survive_source_loss(self):
        data = activation.empty_activations()
        data["projects"][self.project] = {
            self.entry["id"]: {
                "catalogId": self.entry["id"],
                "consumers": ["codex"],
                "enabled": True,
            },
        }
        self._write_claude_decisions(
            enabled=["approved"],
            disabled=["rejected"],
        )
        activation.render_claude_activations(data)
        expected = self._claude_settings_data()
        os.unlink(activation.render_target_path())

        activation.render_claude_activations(data)

        self.assertEqual(self._claude_settings_data(), expected)

    def test_claude_decision_mirror_preserves_unrelated_content_and_source(self):
        settings_path = activation.claude_settings_path(self.project)
        os.makedirs(os.path.dirname(settings_path))
        original = {
            "permissions": {"allow": ["Bash(git status:*)"]},
            "enabledMcpjsonServers": ["manual-enabled"],
            "disabledMcpjsonServers": ["manual-disabled"],
        }
        with open(settings_path, "w", encoding="utf-8") as fh:
            json.dump(original, fh, indent=2)
            fh.write("\n")
        source_path = self._write_claude_decisions(
            enabled=["foreign-approved"],
            disabled=["foreign-rejected"],
        )
        with open(source_path, "rb") as fh:
            source_before = fh.read()

        activation.mirror_claude_decisions(self.project)

        settings = self._claude_settings_data()
        self.assertEqual(settings["permissions"], original["permissions"])
        self.assertEqual(
            settings["enabledMcpjsonServers"],
            ["manual-enabled", "foreign-approved"],
        )
        self.assertEqual(
            settings["disabledMcpjsonServers"],
            ["manual-disabled", "foreign-rejected"],
        )
        with open(source_path, "rb") as fh:
            self.assertEqual(fh.read(), source_before)

    def test_broken_claude_decision_source_is_ignored(self):
        data = activation.empty_activations()
        data["projects"][self.project] = {
            self.entry["id"]: {
                "catalogId": self.entry["id"],
                "consumers": ["codex"],
                "enabled": True,
            },
        }
        path = activation.render_target_path()
        malformed_sources = (
            "{broken",
            "[]",
            '{"projects":[]}',
            json.dumps({"projects": {self.project: {"enabledMcpjsonServers": "foreign"}}}),
        )
        for source in malformed_sources:
            with self.subTest(source=source):
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(source)

                activation.render_claude_activations(data)

                self.assertFalse(
                    os.path.exists(activation.claude_settings_path(self.project))
                )

    def test_deactivate_retires_seed_and_reactivation_seeds_again(self):
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        path = activation.claude_settings_path(self.project)
        settings = self._claude_settings_data()
        settings["enabledMcpjsonServers"].append("user-enabled")
        settings["unrelated"] = {"keep": True}
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(settings, fh, indent=2)
            fh.write("\n")

        activation.deactivate("echo", self.project)
        with open(activation.render_state_path(), encoding="utf-8") as fh:
            state = json.load(fh)
        self.assertNotIn(self.project, state["seeded"])
        settings = self._claude_settings_data()
        self.assertEqual(settings["enabledMcpjsonServers"], ["user-enabled"])
        self.assertEqual(settings["unrelated"], {"keep": True})
        self.assertNotIn(
            "boxa-echo", settings.get("disabledMcpjsonServers", [])
        )

        settings["disabledMcpjsonServers"] = ["manual", "boxa-echo"]
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(settings, fh, indent=2)
            fh.write("\n")

        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))

        settings = self._claude_settings_data()
        self.assertEqual(
            settings["enabledMcpjsonServers"], ["user-enabled", "boxa-echo"]
        )
        self.assertEqual(settings["disabledMcpjsonServers"], ["manual"])
        self.assertEqual(settings["unrelated"], {"keep": True})
        with open(activation.render_state_path(), encoding="utf-8") as fh:
            state = json.load(fh)
        self.assertEqual(state["seeded"][self.project], ["boxa-echo"])

    def test_recorded_approval_wins_when_boxa_seed_is_withdrawn(self):
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        self._write_claude_decisions(enabled=["boxa-echo"])

        activation.deactivate("echo", self.project)

        settings = self._claude_settings_data()
        self.assertIn("boxa-echo", settings["enabledMcpjsonServers"])
        self.assertNotIn(
            "boxa-echo", settings.get("disabledMcpjsonServers", [])
        )

    def test_recorded_rejection_survives_seed_withdrawal_as_rejection(self):
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        self._write_claude_decisions(disabled=["boxa-echo"])

        activation.deactivate("echo", self.project)

        settings = self._claude_settings_data()
        self.assertNotIn(
            "boxa-echo", settings.get("enabledMcpjsonServers", [])
        )
        self.assertEqual(settings["disabledMcpjsonServers"], ["boxa-echo"])

    def test_activation_store_rejects_malformed_tracked_mcp_json_consent(self):
        os.makedirs(os.path.dirname(activation.activation_path()), exist_ok=True)
        malformed = (
            [],
            {self.project: False},
            {os.path.join(self.project, "..", "project"): True},
            {1: True},
        )
        for tracked_mcp_json in malformed:
            with self.subTest(tracked_mcp_json=tracked_mcp_json):
                with open(activation.activation_path(), "w", encoding="utf-8") as fh:
                    json.dump(
                        {
                            "version": activation.ACTIVATION_VERSION,
                            "projects": {},
                            "acknowledgements": {},
                            "trackedMcpJson": tracked_mcp_json,
                        },
                        fh,
                    )
                with self.assertRaisesRegex(
                    activation.ActivationError, r"tracked \.mcp\.json consent"
                ):
                    activation.load_activations()

    def test_malformed_claude_project_approval_refuses_activation(self):
        path = activation.claude_settings_path(self.project)
        os.makedirs(os.path.dirname(path))
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"enabledMcpjsonServers": "boxa-echo"}, fh)
        before = self._file_states()

        with self.assertRaisesRegex(
            activation.ActivationError, "enabledMcpjsonServers.*list of strings"
        ):
            activation.activate(
                "echo", self.project, ["claude"], ReadyProbe(self.project)
            )

        self.assertEqual(self._file_states(), before)

    def test_shipped_claude_settings_do_not_enable_all_project_servers(self):
        with open(
            os.path.join(ROOT, "config", "claude", "settings.json"),
            encoding="utf-8",
        ) as fh:
            settings = json.load(fh)
        self.assertNotIn("enableAllProjectMcpServers", settings)

    def test_codex_activation_renders_project_config_and_local_exclude(self):
        self._init_git()
        path = activation.codex_config_path(self.project)
        os.makedirs(os.path.dirname(path))
        original = '# exact comment\nmodel = "gpt-5"\n\n[mcp_servers.manual]\ncommand = "manual"\n'
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(original)

        result = activation.activate(
            "echo", self.project, ["codex"], ReadyProbe(self.project)
        )
        self.assertEqual(result.consumers, ["codex"])
        text = self._codex_text()
        self.assertTrue(text.startswith(original))
        self.assertIn(activation._CODEX_BEGIN, text)
        self.assertIn('[mcp_servers.boxa-echo]', text)
        self.assertIn(f'"--catalog-id", "{self.entry["id"]}"', text)
        self.assertIn('"--consumer", "codex"', text)
        self.assertIn(f'"--project", "{self.project}"', text)
        with open(path, "rb") as fh:
            parsed = tomllib.load(fh)
        self.assertEqual(parsed["mcp_servers"]["manual"]["command"], "manual")
        self.assertEqual(parsed["mcp_servers"]["boxa-echo"]["command"], "boxa-mcp-run")
        with mock.patch.object(broker, "project_key", return_value=self.project):
            argv, _env, _cwd = broker._build_catalog_spawn(
                "echo", self.project, None, self.entry["id"], "codex"
            )
        self.assertEqual(argv, ["/bin/cat"])
        exclude = self._git("rev-parse", "--path-format=absolute", "--git-path", "info/exclude")
        with open(exclude, encoding="utf-8") as fh:
            self.assertIn("/.codex/config.toml", fh.read().splitlines())
        self.assertFalse(os.path.exists(os.path.join(self.project, ".gitignore")))

        activation.activate("echo", self.project, ["codex"], ReadyProbe(self.project))
        self.assertEqual(self._codex_text(), text)
        activation.deactivate("echo", self.project)
        self.assertEqual(self._codex_text(), original)

    def test_consumer_selection_renders_only_selected_consumers(self):
        self._init_git()
        claude = activation.claude_config_path(self.project)
        activation.activate("echo", self.project, ["codex"], ReadyProbe(self.project))
        self.assertFalse(os.path.exists(claude))
        activation.activate(
            "echo", self.project, ["claude", "codex"], ReadyProbe(self.project)
        )
        stored = activation.load_activations()["projects"][self.project][self.entry["id"]]
        self.assertEqual(stored["consumers"], ["claude", "codex"])
        with open(claude, encoding="utf-8") as fh:
            self.assertIn("boxa-echo", json.dumps(json.load(fh)))
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        self.assertNotIn(activation._CODEX_BEGIN, self._codex_text())

    def test_cli_parses_codex_consumer_lists_and_tracked_opt_in(self):
        self.assertEqual(
            mcp_cli._parse_activation(
                [
                    "echo", "--project", self.project, "--for", "claude,codex",
                    "--allow-tracked-codex-config",
                    "--allow-tracked-mcp-json",
                ],
                "activate",
            ),
            ("echo", self.project, ["claude", "codex"], True, True, False),
        )

    def test_tracked_codex_config_requires_explicit_opt_in(self):
        self._init_git()
        path = activation.codex_config_path(self.project)
        os.makedirs(os.path.dirname(path))
        original = 'model = "tracked"\n'
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(original)
        self._git("add", ".codex/config.toml")
        self._git("commit", "-qm", "tracked config")
        before = self._file_states()
        with self.assertRaisesRegex(activation.ActivationError, "allow-tracked"):
            activation.activate("echo", self.project, ["codex"], ReadyProbe(self.project))
        self.assertEqual(self._codex_text(), original)
        self.assertEqual(self._file_states(), before)
        activation.activate(
            "echo", self.project, ["codex"], ReadyProbe(self.project),
            allow_tracked_codex_config=True,
        )
        self.assertIn(activation._CODEX_BEGIN, self._codex_text())
        self.assertTrue(self._git("status", "--short", "--", ".codex/config.toml"))

    def test_untracked_mcp_json_uses_local_exclude_not_gitignore(self):
        self._init_git()
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))

        exclude = self._git(
            "rev-parse", "--path-format=absolute", "--git-path", "info/exclude"
        )
        with open(exclude, encoding="utf-8") as fh:
            self.assertIn("/.mcp.json", fh.read().splitlines())
        self.assertFalse(os.path.exists(os.path.join(self.project, ".gitignore")))

    def test_nested_project_mcp_exclude_is_repo_relative(self):
        repo = activation.canonical_project(os.path.join(self.tmp.name, "repo"))
        nested = activation.canonical_project(os.path.join(repo, "nested"))
        os.makedirs(nested)
        self._git("init", "-q", cwd=repo)

        activation.activate("echo", nested, ["claude"], ReadyProbe(nested))

        exclude = self._git(
            "rev-parse", "--path-format=absolute", "--git-path", "info/exclude",
            cwd=repo,
        )
        with open(exclude, encoding="utf-8") as fh:
            self.assertIn("/nested/.mcp.json", fh.read().splitlines())

    def test_tracked_mcp_json_requires_explicit_opt_in(self):
        self._init_git()
        path = activation.claude_config_path(self.project)
        original = '{"theme":"tracked"}\n'
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(original)
        self._git("add", ".mcp.json")
        self._git("commit", "-qm", "tracked mcp config")

        before = self._file_states()
        with self.assertRaisesRegex(
            activation.ActivationError, "allow-tracked-mcp-json"
        ):
            activation.activate(
                "echo", self.project, ["claude"], ReadyProbe(self.project),
                allow_tracked_mcp_json=False,
            )
        self.assertEqual(self._file_states(), before)
        activation.activate(
            "echo", self.project, ["claude"], ReadyProbe(self.project),
            allow_tracked_mcp_json=True,
        )
        self.assertIn("boxa-echo", self._claude_data()["mcpServers"])
        self.assertTrue(
            activation.load_activations()["trackedMcpJson"][self.project]
        )
        with open(activation.runtime_path(), encoding="utf-8") as fh:
            self.assertTrue(json.load(fh)["trackedMcpJson"][self.project])

        activation.deactivate(
            "echo",
            self.project,
            allow_tracked_mcp_json=True,
        )
        self.assertNotIn(
            self.project, activation.load_activations()["trackedMcpJson"]
        )
        with open(activation.runtime_path(), encoding="utf-8") as fh:
            self.assertNotIn(self.project, json.load(fh)["trackedMcpJson"])

    def test_tracked_mcp_consent_flag_does_not_authorize_another_project(self):
        self._init_git()
        other = activation.canonical_project(
            os.path.join(self.tmp.name, "other")
        )
        os.makedirs(other)
        self._git("init", "-q", cwd=other)
        self._git(
            "config", "user.email", "boxa-tests@example.invalid", cwd=other
        )
        self._git("config", "user.name", "Boxa Tests", cwd=other)
        activation.activate("echo", other, ["claude"], ReadyProbe(other))
        self._git("add", "-f", ".mcp.json", cwd=other)
        self._git("commit", "-qm", "track rendered config", cwd=other)
        other_path = activation.claude_config_path(other)
        with open(other_path, "w", encoding="utf-8") as fh:
            fh.write('{"mcpServers":{}}\n')

        own_path = activation.claude_config_path(self.project)
        with open(own_path, "w", encoding="utf-8") as fh:
            fh.write('{"theme":"tracked"}\n')
        self._git("add", ".mcp.json")
        self._git("commit", "-qm", "track config")
        paths = (
            activation.activation_path(),
            activation.runtime_path(),
            activation.render_state_path(),
            own_path,
            other_path,
            activation.claude_settings_path(other),
        )
        before = {}
        for path in paths:
            with open(path, "rb") as fh:
                before[path] = fh.read()

        with self.assertRaisesRegex(
            activation.ActivationError, "allow-tracked-mcp-json"
        ) as refused:
            activation.activate(
                "echo",
                self.project,
                ["claude"],
                ReadyProbe(self.project),
                allow_tracked_mcp_json=True,
            )

        self.assertIn(other_path, str(refused.exception))
        for path in paths:
            with open(path, "rb") as fh:
                self.assertEqual(fh.read(), before[path])
        self.assertNotIn(
            other, activation.load_activations()["trackedMcpJson"]
        )

    def test_tracked_mcp_consent_is_recorded_only_for_mutated_project(self):
        other = activation.canonical_project(
            os.path.join(self.tmp.name, "other")
        )
        os.makedirs(other)
        self._git("init", "-q", cwd=other)
        self._git(
            "config", "user.email", "boxa-tests@example.invalid", cwd=other
        )
        self._git("config", "user.name", "Boxa Tests", cwd=other)
        activation.activate("echo", other, ["claude"], ReadyProbe(other))
        self._git("add", "-f", ".mcp.json", cwd=other)
        self._git("commit", "-qm", "track rendered config", cwd=other)

        self._init_git()
        own_path = activation.claude_config_path(self.project)
        with open(own_path, "w", encoding="utf-8") as fh:
            fh.write('{"theme":"tracked"}\n')
        self._git("add", ".mcp.json")
        self._git("commit", "-qm", "track config")

        activation.activate(
            "echo",
            self.project,
            ["claude"],
            ReadyProbe(self.project),
            allow_tracked_mcp_json=True,
        )

        self.assertEqual(
            activation.load_activations()["trackedMcpJson"],
            {self.project: True},
        )

    def test_durable_consent_authorizes_incidental_project_rerender(self):
        other = activation.canonical_project(
            os.path.join(self.tmp.name, "other")
        )
        os.makedirs(other)
        self._git("init", "-q", cwd=other)
        self._git(
            "config", "user.email", "boxa-tests@example.invalid", cwd=other
        )
        self._git("config", "user.name", "Boxa Tests", cwd=other)
        other_path = activation.claude_config_path(other)
        with open(other_path, "w", encoding="utf-8") as fh:
            fh.write('{"theme":"tracked"}\n')
        self._git("add", ".mcp.json", cwd=other)
        self._git("commit", "-qm", "track config", cwd=other)
        activation.activate(
            "echo",
            other,
            ["claude"],
            ReadyProbe(other),
            allow_tracked_mcp_json=True,
        )
        with open(other_path, "w", encoding="utf-8") as fh:
            fh.write('{"theme":"drifted"}\n')

        activation.activate(
            "echo", self.project, ["claude"], ReadyProbe(self.project)
        )

        self.assertIn("boxa-echo", self._claude_data(other)["mcpServers"])
        self.assertEqual(
            activation.load_activations()["trackedMcpJson"], {other: True}
        )

    def test_claude_git_inspection_distinguishes_failures_from_non_repo(self):
        dubious = subprocess.CompletedProcess(
            [], 128, stdout="", stderr="fatal: detected dubious ownership"
        )
        with mock.patch.object(activation.subprocess, "run", return_value=dubious):
            with self.assertRaisesRegex(
                activation.ActivationError,
                "cannot determine whether .* is inside a Git repository",
            ) as refused:
                activation.activate(
                    "echo",
                    self.project,
                    ["claude"],
                    ReadyProbe(self.project),
                )
        self.assertIn("dubious ownership", str(refused.exception))
        self.assertFalse(os.path.exists(activation.activation_path()))

        non_repo = subprocess.CompletedProcess(
            [],
            128,
            stdout="",
            stderr="fatal: not a git repository (or any parent directories)",
        )
        with mock.patch.object(
            activation.subprocess, "run", return_value=non_repo
        ):
            self.assertIsNone(activation._claude_git_paths(self.project))

        with mock.patch.object(
            activation.subprocess, "run", side_effect=OSError("git unavailable")
        ):
            with self.assertRaisesRegex(
                activation.ActivationError,
                "cannot determine whether .* is inside a Git repository",
            ):
                activation._claude_git_paths(self.project)

    def test_codex_tracked_check_raises_on_git_inspection_failure(self):
        failed = subprocess.CompletedProcess(
            [], 128, stdout="", stderr="fatal: damaged repository metadata"
        )
        with mock.patch.object(activation.subprocess, "run", return_value=failed):
            with self.assertRaisesRegex(
                activation.ActivationError, "cannot determine whether"
            ) as refused:
                activation._codex_is_tracked(self.project, ".mcp.json")
        self.assertIn("damaged repository metadata", str(refused.exception))

    def test_identical_tracked_mcp_rerender_is_noop_without_consent(self):
        self._init_git()
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        path = activation.claude_config_path(self.project)
        definition = activation.claude_server_definition(
            self.entry["id"], self.project, self.entry
        )
        original = (
            '{"label":"caf\\u00e9","mcpServers":{"foreign":'
            '{"command":"keep","ratio":1.0},"boxa-echo":'
            f'{json.dumps(definition, separators=(",", ":"))}'
            '},"numeric":1e3}\t'
        )
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(original)
        self._git("add", "-f", ".mcp.json")
        self._git("commit", "-qm", "track rendered mcp config")
        before = os.stat(path).st_mtime_ns

        activation.render_claude_activations()

        self.assertEqual(os.stat(path).st_mtime_ns, before)
        with open(path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), original)

    def test_runtime_doctor_accepts_tracked_mcp_json_and_fix_clears_drift(self):
        activations = activation.empty_activations()
        activations["trackedMcpJson"][self.project] = True
        activation.save_activation_store(activations)
        activation.refresh_runtime()

        findings = lifecycle._catalog_doctor_findings()
        self.assertNotIn(
            "catalog-runtime-drift", {finding.code for finding in findings}
        )

        with open(activation.runtime_path(), "w", encoding="utf-8") as fh:
            fh.write("{}\n")
        findings = lifecycle._catalog_doctor_findings()
        self.assertIn(
            "catalog-runtime-drift", {finding.code for finding in findings}
        )
        fixed = lifecycle.apply_doctor_fixes(
            lifecycle.DoctorReport(False, findings)
        )
        self.assertNotIn(
            "catalog-runtime-drift", {finding.code for finding in fixed.remaining}
        )

    def test_tracked_mcp_drift_is_reported_and_not_doctor_fixable(self):
        self._init_git()
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        path = activation.claude_config_path(self.project)
        self._git("add", "-f", ".mcp.json")
        self._git("commit", "-qm", "track rendered mcp config")
        data = self._claude_data()
        del data["mcpServers"]["boxa-echo"]
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")

        probe = mock.Mock()
        probe.find_running.return_value = "boxa-project"
        probe.command_path.return_value = "/bin/cat"
        status = lifecycle.catalog_project_status(self.project, probe)
        row = next(item for item in status["entries"] if item["id"] == self.entry["id"])
        self.assertTrue(row["trackedMcpJson"])
        self.assertFalse(row["trackedCodexConfig"])
        findings = lifecycle._catalog_doctor_findings(probe)
        finding = next(
            item for item in findings
            if item.code == "catalog-claude-render-drift"
        )
        self.assertFalse(finding.fixable)
        self.assertIn("--allow-tracked-mcp-json", finding.repair)
        before = os.stat(path).st_mtime_ns
        lifecycle.apply_doctor_fixes(
            lifecycle.DoctorReport(False, findings)
        )
        self.assertEqual(os.stat(path).st_mtime_ns, before)

    def test_multi_project_claude_preflight_refuses_all_before_write(self):
        self._init_git()
        other = activation.canonical_project(os.path.join(self.tmp.name, "other"))
        os.makedirs(other)
        self._git("init", "-q", cwd=other)
        self._git("config", "user.email", "boxa-tests@example.invalid", cwd=other)
        self._git("config", "user.name", "Boxa Tests", cwd=other)
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        activation.activate("echo", other, ["claude"], ReadyProbe(other))
        tracked = activation.claude_config_path(other)
        self._git("add", "-f", ".mcp.json", cwd=other)
        self._git("commit", "-qm", "track mcp config", cwd=other)
        paths = [
            activation.claude_config_path(self.project),
            tracked,
            activation.catalog_path(),
            activation.render_state_path(),
        ]
        before = {}
        for path in paths:
            with open(path, "rb") as fh:
                before[path] = fh.read()

        with self.assertRaisesRegex(
            activation.ActivationError, "allow-tracked-mcp-json"
        ) as refused:
            update_entry(self.entry["id"], name="renamed")

        self.assertIn(tracked, str(refused.exception))
        for path in paths:
            with open(path, "rb") as fh:
                self.assertEqual(fh.read(), before[path])

    def test_deactivate_preserves_unrelated_mcp_json_content(self):
        path = activation.claude_config_path(self.project)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({
                "theme": "keep",
                "mcpServers": {"manual": {"command": "manual"}},
            }, fh)
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        activation.deactivate("echo", self.project)

        self.assertEqual(
            self._claude_data(),
            {
                "theme": "keep",
                "mcpServers": {"manual": {"command": "manual"}},
            },
        )

    def test_claude_render_preserves_unmanaged_mcp_json_bytes(self):
        path = activation.claude_config_path(self.project)
        original = (
            '{"label":"caf\\u00e9","mcpServers":{'
            '"foreign":{"command":"keep","ratio":1.0},'
            '"boxa-echo":{"command":"old"},'
            '"boxa-stale":{"command":"old"}},'
            '"numeric":1e3}\t'
        )
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(original)
        activations = activation.empty_activations()
        activations["projects"][self.project] = {
            self.entry["id"]: {
                "catalogId": self.entry["id"],
                "consumers": ["claude"],
            },
            self.inactive["id"]: {
                "catalogId": self.inactive["id"],
                "consumers": ["claude"],
            },
        }
        state = {
            "projects": {
                self.project: ["boxa-echo", "boxa-stale"],
            }
        }

        plan = activation._claude_render_plan(
            activations, self.project, activation.load_catalog(), state
        )

        echo = json.dumps(
            activation.claude_server_definition(
                self.entry["id"], self.project, self.entry
            ),
            separators=(",", ":"),
        )
        inactive = json.dumps(
            activation.claude_server_definition(
                self.inactive["id"], self.project, self.inactive
            ),
            separators=(",", ":"),
        )
        expected = (
            '{"label":"caf\\u00e9","mcpServers":{'
            f'"foreign":{{"command":"keep","ratio":1.0}},'
            f'"boxa-echo":{echo},"boxa-inactive":{inactive}'
            '},"numeric":1e3}\t'
        )
        self.assertEqual(plan[5], expected)
        self.assertEqual(json.loads(plan[5])["numeric"], 1000)

    def test_existing_activation_store_renders_new_target_and_retires_old(self):
        record = {
            "catalogId": self.entry["id"],
            "consumers": ["claude"],
            "enabled": True,
        }
        data = activation.empty_activations()
        data["projects"][self.project] = {self.entry["id"]: record}
        activation.save_activation_store(data)
        os.makedirs(os.path.dirname(activation.render_state_path()), exist_ok=True)
        with open(activation.render_state_path(), "w", encoding="utf-8") as fh:
            json.dump({"projects": {self.project: ["boxa-echo"]}}, fh)
        legacy = activation.render_target_path()
        with open(legacy, "w", encoding="utf-8") as fh:
            json.dump({
                "theme": "keep",
                "mcpServers": {"global": {"command": "keep"}},
                "projects": {
                    self.project: {
                        "mcpServers": {
                            "boxa-echo": {"command": "old"},
                            "manual": {"command": "keep"},
                        },
                        "disabledMcpServers": ["boxa-echo", "manual"],
                    }
                },
            }, fh)

        activation.render_claude_activations()

        self.assertIn("boxa-echo", self._claude_data()["mcpServers"])
        with open(legacy, encoding="utf-8") as fh:
            retired = json.load(fh)
        self.assertEqual(retired["theme"], "keep")
        self.assertIn("global", retired["mcpServers"])
        project = retired["projects"][self.project]
        self.assertEqual(project["mcpServers"], {"manual": {"command": "keep"}})
        self.assertEqual(project["disabledMcpServers"], ["manual"])

    def test_non_git_project_renders_mcp_json(self):
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        self.assertIn("boxa-echo", self._claude_data()["mcpServers"])

    def test_malformed_managed_region_refuses_without_partial_state(self):
        self._init_git()
        path = activation.codex_config_path(self.project)
        os.makedirs(os.path.dirname(path))
        malformed = f'model = "keep"\n{activation._CODEX_BEGIN}\n'
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(malformed)
        before = self._file_states()
        with self.assertRaisesRegex(activation.ActivationError, "malformed"):
            activation.activate("echo", self.project, ["codex"], ReadyProbe(self.project))
        self.assertEqual(self._codex_text(), malformed)
        self.assertEqual(self._file_states(), before)

    def test_linked_worktree_uses_git_resolved_local_exclude(self):
        self._init_git()
        seed = os.path.join(self.project, "seed")
        with open(seed, "w", encoding="utf-8") as fh:
            fh.write("seed\n")
        self._git("add", "seed")
        self._git("commit", "-qm", "seed")
        linked = activation.canonical_project(os.path.join(self.tmp.name, "linked"))
        self._git("worktree", "add", "-q", "-b", "linked-test", linked)
        activation.activate("echo", linked, ["codex"], ReadyProbe(linked))
        exclude = self._git(
            "rev-parse", "--path-format=absolute", "--git-path", "info/exclude",
            cwd=linked,
        )
        self.assertTrue(os.path.isfile(activation.codex_config_path(linked)))
        with open(exclude, encoding="utf-8") as fh:
            self.assertIn("/.codex/config.toml", fh.read().splitlines())

    def test_fresh_other_project_is_empty_and_deactivation_removes_only_managed(self):
        other = activation.canonical_project(os.path.join(self.tmp.name, "clone"))
        os.makedirs(other)
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        self.assertFalse(any(row["activated"] for row in activation.effective_catalog(other)))
        result = activation.deactivate("echo", self.project)
        self.assertTrue(result.changed)
        self.assertFalse(os.path.exists(activation.claude_config_path(self.project)))

    def test_broker_authorizes_activation_and_rejects_absent_wrong_disabled_deleted_consumer(self):
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        with mock.patch.object(broker, "project_key", return_value=self.project):
            argv, _env, cwd = broker._build_catalog_spawn("echo", self.project, self.project, self.entry["id"], "claude")
            self.assertEqual(argv, ["/bin/cat"])
            self.assertEqual(cwd, self.project)
            with self.assertRaisesRegex(broker.BrokerError, "no activation"):
                broker._build_catalog_spawn("inactive", self.project, None, self.inactive["id"], "claude")
            with self.assertRaisesRegex(broker.BrokerError, "not this Container"):
                broker._build_catalog_spawn("echo", "/wrong", None, self.entry["id"], "claude")
            with self.assertRaisesRegex(broker.BrokerError, "consumer"):
                broker._build_catalog_spawn("echo", self.project, None, self.entry["id"], "codex")
            runtime = activation.runtime_path()
            with open(runtime, encoding="utf-8") as fh:
                data = json.load(fh)
            data["projects"][self.project][self.entry["id"]]["enabled"] = False
            with open(runtime, "w", encoding="utf-8") as fh:
                json.dump(data, fh)
            with self.assertRaisesRegex(broker.BrokerError, "disabled"):
                broker._build_catalog_spawn("echo", self.project, None, self.entry["id"], "claude")
            data["projects"][self.project][self.entry["id"]]["enabled"] = True
            del data["entries"][self.entry["id"]]
            with open(runtime, "w", encoding="utf-8") as fh:
                json.dump(data, fh)
            with self.assertRaisesRegex(broker.BrokerError, "deleted"):
                broker._build_catalog_spawn("echo", self.project, None, self.entry["id"], "claude")

    def test_protocol_activation_fields_are_validated_without_breaking_legacy_decode(self):
        line = protocol.encode_request("echo", self.project, catalog_id=self.entry["id"], consumer="claude")
        self.assertEqual(protocol.decode_request(line.rstrip()), ("echo", self.project, None))
        details = protocol.decode_request_details(line.rstrip())
        self.assertEqual(details[3:], (self.entry["id"], "claude"))
        with self.assertRaises(protocol.ProtocolError):
            protocol.decode_request_details(b'{"server":"echo","catalogId":"x"}')

    def test_activation_handshake_relays_stdio_end_to_end(self):
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        client, server = socket.socketpair()
        with mock.patch.object(broker, "project_key", return_value=self.project):
            thread = threading.Thread(target=broker._handle, args=(server,))
            thread.start()
            client.sendall(protocol.encode_request(
                "echo", self.project, self.project,
                catalog_id=self.entry["id"], consumer="claude",
            ))
            ok, error = protocol.decode_reply(protocol.read_line(client.recv))
            self.assertTrue(ok, error)
            client.sendall(b"activation tracer bullet\n")
            client.shutdown(socket.SHUT_WR)
            received = bytearray()
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                received.extend(chunk)
            thread.join(timeout=5)
        client.close()
        self.assertFalse(thread.is_alive())
        self.assertTrue(bytes(received).startswith(b"activation tracer bullet\n"))
        sentinel = received.index(protocol.EXIT_TRAILER_SENTINEL)
        self.assertEqual(protocol.decode_exit(bytes(received[sentinel + 1:])), 0)

    def test_activate_render_failure_rolls_back_every_file_and_effective_state(self):
        activation.refresh_runtime()
        claude = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], ".claude.json")
        with open(claude, "wb") as fh:
            fh.write(b'{"theme":"exact-before"}\n')
        os.chmod(claude, 0o640)
        os.makedirs(os.path.dirname(activation.render_state_path()), exist_ok=True)
        with open(activation.render_state_path(), "wb") as fh:
            fh.write(b'{"projects":{},"sentinel":true}\n')
        os.chmod(activation.render_state_path(), 0o620)
        settings = activation.claude_settings_path(self.project)
        os.makedirs(os.path.dirname(settings))
        with open(settings, "wb") as fh:
            fh.write(
                b'{"enabledMcpjsonServers":["manual"],'
                b'"disabledMcpjsonServers":["boxa-echo"],'
                b'"permissions":{"allow":["Bash(git status:*)"]}}\n'
            )
        os.chmod(settings, 0o640)
        before = self._file_states()
        real_atomic = activation._atomic_json

        def fail_render_state(path, data, mode):
            if path == activation.render_state_path():
                raise OSError("forced render-state write failure")
            return real_atomic(path, data, mode)

        with mock.patch.object(activation, "_atomic_json", side_effect=fail_render_state):
            with self.assertRaisesRegex(OSError, "forced render-state"):
                activation.activate(
                    "echo", self.project, ["claude"], ReadyProbe(self.project)
                )

        self.assertEqual(self._file_states(), before)
        self.assertFalse(
            next(row for row in activation.effective_catalog(self.project) if row["id"] == self.entry["id"])["activated"]
        )
        with mock.patch.object(broker, "project_key", return_value=self.project):
            with self.assertRaisesRegex(broker.BrokerError, "no activation"):
                broker._build_catalog_spawn(
                    "echo", self.project, None, self.entry["id"], "claude"
                )

    def test_deactivate_render_failure_rolls_back_every_file_and_broker_state(self):
        activation.activate("echo", self.project, ["claude"], ReadyProbe(self.project))
        before = self._file_states()
        real_atomic = activation._atomic_json

        def fail_render_state(path, data, mode):
            if path == activation.render_state_path():
                raise OSError("forced render-state write failure")
            return real_atomic(path, data, mode)

        with mock.patch.object(activation, "_atomic_json", side_effect=fail_render_state):
            with self.assertRaisesRegex(OSError, "forced render-state"):
                activation.deactivate("echo", self.project)

        self.assertEqual(self._file_states(), before)
        self.assertTrue(
            next(row for row in activation.effective_catalog(self.project) if row["id"] == self.entry["id"])["activated"]
        )
        with mock.patch.object(broker, "project_key", return_value=self.project):
            argv, _env, _cwd = broker._build_catalog_spawn(
                "echo", self.project, None, self.entry["id"], "claude"
            )
        self.assertEqual(argv, ["/bin/cat"])


if __name__ == "__main__":
    unittest.main()
