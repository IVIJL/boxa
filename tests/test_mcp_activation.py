"""ADR 0028: activation publishes host state without Project-file writes."""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import (  # noqa: E402
    activation,
    cli,
    launch_profile,
    lifecycle,
)
from mcp.catalog import (  # noqa: E402
    add_entry,
    add_remote_entry,
    load_catalog,
    save_catalog,
    update_entry,
)
from mcp.projects import VolumeProbe, project_volume_name  # noqa: E402
from mcp.readiness import ProjectProbe  # noqa: E402


class ReadyProbe(activation.DockerProbe):
    def __init__(self, project: str):
        self.project = project

    def find_running(self, project_key: str):
        return "boxa-project" if project_key == self.project else None

    def ready(self, container, entry):
        return container == "boxa-project"


class StoppedProbe(ReadyProbe):
    def find_running(self, project_key: str):
        return None


class RecheckProbe(ProjectProbe):
    def __init__(self, project: str, *, command_ready: bool):
        self.project = project
        self.command_ready = command_ready

    def find_running(self, project_key: str):
        return "boxa-project" if project_key == self.project else None

    def command_path(self, container, command, user):
        return command if self.command_ready else None


class MixedProbe(activation.DockerProbe):
    def __init__(self, running):
        self.running = set(running)

    def find_running(self, project_key: str):
        return f"boxa-{os.path.basename(project_key)}" if project_key in self.running else None

    def ready(self, container, entry):
        return bool(container)


class StubClaude:
    def __init__(self, projects):
        self.projects = list(projects)

    def project_keys(self):
        return list(self.projects)


class StubVolumeProbe(VolumeProbe):
    def __init__(self, projects):
        super().__init__()
        self.volumes = {
            project_volume_name(os.path.basename(project)) for project in projects
        }

    def exists(self, volume_name: str) -> bool:
        return volume_name in self.volumes


class ActivationIsolationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = {key: os.environ.get(key) for key in ("HOME", "XDG_CONFIG_HOME")}
        self.addCleanup(self._restore)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")
        self.project = activation.canonical_project(os.path.join(self.tmp.name, "project"))
        os.makedirs(os.path.join(self.project, ".claude"))
        os.makedirs(os.path.join(self.project, ".codex"))
        self._write(".mcp.json", b'{"mcpServers":{"manual":{"command":"keep"}}}\n')
        self._write(".claude/settings.local.json", b'{"theme":"keep"}\n')
        self._write(".codex/config.toml", b'[mcp_servers.manual]\ncommand = "keep"\n')
        os.makedirs(os.path.join(self.project, ".git", "info"))
        self._write(".git/info/exclude", b"# keep\n")
        added = add_entry("echo", ["npx", "placeholder"])
        self.entry = update_entry(added["id"], argv=["/bin/cat"])
        self.probe = ReadyProbe(self.project)

    def _restore(self):
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _write(self, relative: str, content: bytes):
        path = os.path.join(self.project, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(content)

    def _project_state(self):
        state = {}
        for base, _dirs, files in os.walk(self.project):
            for name in files:
                path = os.path.join(base, name)
                with open(path, "rb") as fh:
                    state[os.path.relpath(path, self.project)] = fh.read()
        return state

    def test_activation_picker_includes_codex_only_registered_project(self):
        codex_only = os.path.join(self.tmp.name, "codex-only")

        def docker_run(argv, **_kwargs):
            if argv[:3] == ["docker", "ps", "-a"]:
                return subprocess.CompletedProcess(argv, 0, "boxa-codex-only\n", "")
            if argv[:3] == ["docker", "inspect", "-f"]:
                return subprocess.CompletedProcess(
                    argv, 0, f"BOXA_PROJECT_HOST_PATH={codex_only}\n", ""
                )
            if argv[:3] == ["docker", "volume", "inspect"]:
                return subprocess.CompletedProcess(argv, 0, "", "")
            self.fail(f"unexpected Docker call: {argv}")

        stdout = io.StringIO()
        with mock.patch("mcp.cli.subprocess.run", side_effect=docker_run), \
                contextlib.redirect_stdout(stdout):
            rc = cli._cmd_activation_project_targets([], as_json=False)

        self.assertEqual(rc, 0)
        self.assertEqual(stdout.getvalue(), f"codex-only\t{codex_only}\n")

    def test_activation_picker_current_wins_basename_collision(self):
        current = os.path.join(self.tmp.name, "new", "app")
        old = os.path.join(self.tmp.name, "old", "app")

        def docker_run(argv, **_kwargs):
            if argv[:3] == ["docker", "ps", "-a"]:
                return subprocess.CompletedProcess(argv, 0, "boxa-app\n", "")
            if argv[:3] == ["docker", "inspect", "-f"]:
                return subprocess.CompletedProcess(
                    argv, 0, f"BOXA_PROJECT_HOST_PATH={old}\n", ""
                )
            if argv[:3] == ["docker", "volume", "inspect"]:
                return subprocess.CompletedProcess(argv, 0, "", "")
            self.fail(f"unexpected Docker call: {argv}")

        stdout = io.StringIO()
        with mock.patch("mcp.cli.subprocess.run", side_effect=docker_run), \
                contextlib.redirect_stdout(stdout):
            rc = cli._cmd_activation_project_targets(
                ["--current", current], as_json=False
            )

        self.assertEqual(rc, 0)
        self.assertEqual(stdout.getvalue(), f"app\t{os.path.realpath(current)}\n")

    def test_activation_picker_includes_removed_container_from_registry(self):
        stopped = os.path.realpath(os.path.join(self.tmp.name, "stopped"))
        registry_path = os.path.join(
            os.environ["XDG_CONFIG_HOME"], "boxa", "projects.json"
        )
        os.makedirs(os.path.dirname(registry_path), exist_ok=True)
        with open(registry_path, "w", encoding="utf-8") as fh:
            json.dump({
                "version": 1,
                "projects": {
                    stopped: {"name": "stopped", "lastSeen": "2026-08-21T00:00:00Z"}
                },
            }, fh)

        def docker_run(argv, **_kwargs):
            if argv[:3] == ["docker", "ps", "-a"]:
                return subprocess.CompletedProcess(argv, 0, "", "")
            if argv[:3] == ["docker", "volume", "inspect"]:
                return subprocess.CompletedProcess(argv, 0, "", "")
            self.fail(f"unexpected Docker call: {argv}")

        stdout = io.StringIO()
        with mock.patch("mcp.cli.subprocess.run", side_effect=docker_run), \
                contextlib.redirect_stdout(stdout):
            rc = cli._cmd_activation_project_targets([], as_json=False)

        self.assertEqual(rc, 0)
        self.assertEqual(stdout.getvalue(), f"stopped\t{stopped}\n")

    def test_docker_run_project_registry_write_is_idempotent(self):
        docker_run_path = os.path.join(ROOT, "docker-run.sh")
        with open(docker_run_path, encoding="utf-8") as fh:
            docker_run = fh.read()
        match = re.search(
            r"(?ms)^_boxa::record_project\(\) \{\n.*?^\}\n", docker_run
        )
        self.assertIsNotNone(match)
        project = os.path.join(self.tmp.name, "registered")
        os.makedirs(project)
        subprocess.run(
            [
                "bash",
                "-c",
                f"{match.group(0)}\n"
                '_boxa::record_project "$1" registered\n'
                '_boxa::record_project "$1" registered\n',
                "bash",
                project,
            ],
            check=True,
            env=os.environ.copy(),
        )
        registry_path = os.path.join(
            os.environ["XDG_CONFIG_HOME"], "boxa", "projects.json"
        )
        with open(registry_path, encoding="utf-8") as fh:
            registry = json.load(fh)

        self.assertEqual(registry["version"], 1)
        self.assertEqual(
            registry["projects"],
            {
                os.path.realpath(project): {
                    "name": "registered",
                    "lastSeen": mock.ANY,
                }
            },
        )

    def test_docker_run_project_registry_parallel_writes_preserve_all_projects(self):
        docker_run_path = os.path.join(ROOT, "docker-run.sh")
        with open(docker_run_path, encoding="utf-8") as fh:
            docker_run = fh.read()
        match = re.search(
            r"(?ms)^_boxa::record_project\(\) \{\n.*?^\}\n", docker_run
        )
        self.assertIsNotNone(match)
        projects = [
            os.path.join(self.tmp.name, f"parallel-{index}")
            for index in range(24)
        ]
        for project in projects:
            os.makedirs(project)
        subprocess.run(
            [
                "bash",
                "-c",
                f"{match.group(0)}\n"
                'for project in "$1"/parallel-*; do\n'
                '    _boxa::record_project "$project" "${project##*/}" &\n'
                "done\n"
                "wait\n",
                "bash",
                self.tmp.name,
            ],
            check=True,
            env=os.environ.copy(),
        )
        registry_path = os.path.join(
            os.environ["XDG_CONFIG_HOME"], "boxa", "projects.json"
        )
        with open(registry_path, encoding="utf-8") as fh:
            registry = json.load(fh)

        self.assertEqual(
            set(registry["projects"]), set(map(os.path.realpath, projects))
        )

    def test_activate_and_deactivate_touch_no_project_file(self):
        before = self._project_state()
        activated = activation.activate(
            self.entry["id"], self.project, ["claude", "codex"], self.probe
        )
        self.assertTrue(activated.changed)
        self.assertEqual(self._project_state(), before)
        with open(activation.runtime_path(), encoding="utf-8") as fh:
            runtime = json.load(fh)
        self.assertEqual(
            runtime["projects"][self.project][self.entry["id"]]["consumers"],
            ["claude", "codex"],
        )
        self.assertNotIn("trackedMcpJson", runtime)
        self.assertNotIn("seededApprovals", runtime)

        deactivated = activation.deactivate(self.entry["id"], self.project)
        self.assertTrue(deactivated.changed)
        self.assertEqual(self._project_state(), before)
        self.assertTrue(
            activation.load_activations()["projects"][self.project][self.entry["id"]][
                "optedOut"
            ]
        )
        with open(activation.runtime_path(), encoding="utf-8") as fh:
            self.assertNotIn(self.project, json.load(fh)["projects"])

    def test_runtime_publish_failure_rolls_back_activation_store(self):
        original = activation._atomic_json

        def fail_runtime(path, data, mode):
            if path == activation.runtime_path():
                raise OSError("forced runtime failure")
            return original(path, data, mode)

        with mock.patch.object(activation, "_atomic_json", side_effect=fail_runtime):
            with self.assertRaisesRegex(OSError, "forced runtime failure"):
                activation.activate(self.entry["id"], self.project, ["claude"], self.probe)
        self.assertEqual(activation.load_activations()["projects"], {})

    def test_legacy_tracked_consent_is_dropped_on_next_write(self):
        data = activation.empty_activations()
        data["trackedMcpJson"] = {self.project: True}
        os.makedirs(os.path.dirname(activation.activation_path()), exist_ok=True)
        with open(activation.activation_path(), "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        activation.activate(self.entry["id"], self.project, ["claude"], self.probe)
        with open(activation.activation_path(), encoding="utf-8") as fh:
            self.assertNotIn("trackedMcpJson", json.load(fh))

    def test_stopped_activation_is_pending_in_store_snapshot_and_cli(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli._cmd_activate(
                [
                    self.entry["id"],
                    "--project",
                    self.project,
                    "--for",
                    "claude,codex",
                ],
                as_json=False,
            )
        self.assertEqual(rc, 0)
        self.assertIn("Pending MCP catalog activation", stdout.getvalue())
        self.assertIn(
            f"Next: boxa mcp readiness {self.entry['name']} "
            f"--project {self.project}",
            stdout.getvalue(),
        )
        record = activation.load_activations()["projects"][self.project][self.entry["id"]]
        self.assertFalse(record["enabled"])
        self.assertIn("not running", record["pendingReason"])
        with open(activation.runtime_path(), encoding="utf-8") as fh:
            runtime_record = json.load(fh)["projects"][self.project][self.entry["id"]]
        self.assertEqual(runtime_record, record)

    def test_cli_activation_accepts_repeated_projects_and_reports_each(self):
        other = os.path.join(self.tmp.name, "other-project")
        os.makedirs(other)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli._cmd_activate(
                [
                    self.entry["id"],
                    "--project", self.project,
                    "--project", other,
                    "--for", "claude",
                ],
                as_json=False,
            )
        self.assertEqual(rc, 0)
        self.assertIn(self.project, stdout.getvalue())
        self.assertIn(other, stdout.getvalue())
        records = activation.load_activations()["projects"]
        self.assertIn(self.entry["id"], records[self.project])
        self.assertIn(self.entry["id"], records[other])

    def test_cli_multi_project_preflight_failure_writes_nothing(self):
        other = os.path.join(self.tmp.name, "other-project")
        calls = []

        def preflight(token, project, consumers, **kwargs):
            calls.append(project)
            if project == other:
                raise activation.ActivationError("not ready")

        stderr = io.StringIO()
        with mock.patch.object(cli, "preflight_catalog", side_effect=preflight), \
                mock.patch.object(cli, "activate_catalog") as activate_mock, \
                contextlib.redirect_stderr(stderr):
            rc = cli._cmd_activate([
                self.entry["id"],
                "--project", self.project,
                "--project", other,
                "--for", "claude",
            ], as_json=False)

        self.assertEqual(rc, 1)
        self.assertEqual(calls, [self.project, other])
        activate_mock.assert_not_called()
        self.assertIn(other, stderr.getvalue())
        self.assertEqual(activation.load_activations()["projects"], {})

    def test_cli_mid_write_failure_reports_visible_outcomes(self):
        other = os.path.join(self.tmp.name, "other-project")
        first = activation.ActivationResult(
            self.entry, self.project, ["claude"], True
        )

        def activate_side_effect(token, project, consumers, **kwargs):
            if project == other:
                raise OSError("write failed")
            return first

        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(cli, "preflight_catalog"), \
                mock.patch.object(
                    cli, "activate_catalog", side_effect=activate_side_effect
                ), contextlib.redirect_stdout(stdout), \
                contextlib.redirect_stderr(stderr):
            rc = cli._cmd_activate([
                self.entry["id"],
                "--project", self.project,
                "--project", other,
                "--for", "claude",
            ], as_json=False)

        self.assertEqual(rc, 1)
        self.assertIn(f"activated  {self.project}", stdout.getvalue())
        self.assertIn(f"failed     {other}: write failed", stderr.getvalue())

    def test_pending_reevaluation_passes_and_enables_new_sessions(self):
        result = activation.activate(
            self.entry["id"], self.project, ["claude"], StoppedProbe(self.project)
        )
        self.assertTrue(result.pending)

        rechecked = activation.reevaluate_pending(
            self.project, RecheckProbe(self.project, command_ready=True)
        )

        self.assertTrue(rechecked.changed)
        self.assertTrue(rechecked.attempts[0].ready)
        record = activation.load_activations()["projects"][self.project][self.entry["id"]]
        self.assertTrue(record["enabled"])
        self.assertNotIn("pendingReason", record)
        with open(activation.runtime_path(), encoding="utf-8") as fh:
            runtime = json.load(fh)
        _project, entries = launch_profile.active_project_entries(
            "claude", runtime=runtime, project=self.project
        )
        self.assertEqual(entries[0][0], self.entry["id"])

    def test_pending_reevaluation_failure_keeps_blocking_reason(self):
        activation.activate(
            self.entry["id"], self.project, ["claude"], StoppedProbe(self.project)
        )

        rechecked = activation.reevaluate_pending(
            self.project, RecheckProbe(self.project, command_ready=False)
        )

        self.assertFalse(rechecked.attempts[0].ready)
        record = activation.load_activations()["projects"][self.project][self.entry["id"]]
        self.assertFalse(record["enabled"])
        self.assertIn("executable /bin/cat", record["pendingReason"])
        stderr = io.StringIO()
        with mock.patch.object(cli, "reevaluate_pending", return_value=rechecked), \
                contextlib.redirect_stderr(stderr):
            rc = cli._cmd_reevaluate_pending(["--project", self.project])
        self.assertEqual(rc, 0)
        self.assertIn("WARNING", stderr.getvalue())
        self.assertIn(record["pendingReason"], stderr.getvalue())

    def test_remote_activation_never_becomes_pending(self):
        remote = add_remote_entry("remote", "https://remote.example.test/mcp")
        result = activation.activate(
            remote["id"], self.project, ["claude"], StoppedProbe(self.project)
        )
        record = activation.load_activations()["projects"][self.project][remote["id"]]
        self.assertFalse(result.pending)
        self.assertTrue(record["enabled"])
        self.assertNotIn("pendingReason", record)

    def test_deactivate_removes_pending_activation(self):
        activation.activate(
            self.entry["id"], self.project, ["claude"], StoppedProbe(self.project)
        )
        result = activation.deactivate(self.entry["id"], self.project)
        self.assertTrue(result.changed)
        record = activation.load_activations()["projects"][self.project][self.entry["id"]]
        self.assertEqual(record, {"catalogId": self.entry["id"], "optedOut": True})

    def test_everywhere_propagates_to_running_and_stopped_projects(self):
        stopped = activation.canonical_project(os.path.join(self.tmp.name, "stopped"))
        os.makedirs(stopped)
        projects = [self.project, stopped]

        result = activation.activate_everywhere(
            self.entry["id"],
            ["claude"],
            StubClaude(projects),
            StubVolumeProbe(projects),
            MixedProbe({self.project}),
        )

        outcomes = {item.project_key: item.outcome for item in result.projects}
        self.assertEqual(
            outcomes, {self.project: "activated", stopped: "pending"}
        )
        data = activation.load_activations()
        self.assertEqual(
            data["everywhere"][self.entry["id"]]["consumers"], ["claude"]
        )
        self.assertTrue(data["projects"][self.project][self.entry["id"]]["enabled"])
        self.assertFalse(data["projects"][stopped][self.entry["id"]]["enabled"])

    def test_everywhere_remote_is_immediate_even_for_stopped_project(self):
        remote = add_remote_entry("remote", "https://remote.example.test/mcp")
        stopped = activation.canonical_project(os.path.join(self.tmp.name, "remote-stopped"))
        os.makedirs(stopped)

        result = activation.activate_everywhere(
            remote["id"],
            ["claude"],
            StubClaude([stopped]),
            StubVolumeProbe([stopped]),
            MixedProbe(set()),
        )

        self.assertEqual(result.projects[0].outcome, "activated")
        record = activation.load_activations()["projects"][stopped][remote["id"]]
        self.assertTrue(record["enabled"])
        self.assertNotIn("pendingReason", record)

    def test_first_container_start_seeds_everywhere_entry(self):
        activation.activate_everywhere(
            self.entry["id"],
            ["claude", "codex"],
            StubClaude([]),
            StubVolumeProbe([]),
            MixedProbe(set()),
        )
        new_project = activation.canonical_project(os.path.join(self.tmp.name, "new"))
        os.makedirs(new_project)

        result = activation.reevaluate_pending(
            new_project, RecheckProbe(new_project, command_ready=True)
        )

        self.assertTrue(result.changed)
        self.assertTrue(result.attempts[0].ready)
        record = activation.load_activations()["projects"][new_project][self.entry["id"]]
        self.assertEqual(record["consumers"], ["claude", "codex"])
        self.assertTrue(record["enabled"])

    def test_sticky_opt_out_survives_remark_and_explicit_activate_clears_it(self):
        provider = StubClaude([self.project])
        volumes = StubVolumeProbe([self.project])
        activation.activate_everywhere(
            self.entry["id"], ["claude"], provider, volumes, self.probe
        )
        activation.deactivate(self.entry["id"], self.project)

        remarked = activation.activate_everywhere(
            self.entry["id"], ["codex"], provider, volumes, self.probe
        )

        self.assertEqual(remarked.projects[0].outcome, "opted-out")
        self.assertTrue(
            activation.load_activations()["projects"][self.project][self.entry["id"]][
                "optedOut"
            ]
        )
        activation.activate(self.entry["id"], self.project, ["codex"], self.probe)
        record = activation.load_activations()["projects"][self.project][self.entry["id"]]
        self.assertNotIn("optedOut", record)
        self.assertEqual(record["consumers"], ["codex"])

    def test_everywhere_sweep_canonicalizes_before_checking_opt_out(self):
        link = os.path.join(self.tmp.name, "linked-project")
        os.symlink(self.project, link)
        activation.deactivate(self.entry["id"], self.project)

        result = activation.activate_everywhere(
            self.entry["id"],
            ["claude"],
            StubClaude([link]),
            StubVolumeProbe([link]),
            self.probe,
        )

        self.assertEqual(result.projects[0].outcome, "opted-out")
        self.assertEqual(result.projects[0].project_key, self.project)

    def test_no_everywhere_preserves_existing_activation_and_stops_future_seed(self):
        activation.activate_everywhere(
            self.entry["id"],
            ["claude"],
            StubClaude([self.project]),
            StubVolumeProbe([self.project]),
            self.probe,
        )
        cleared = activation.clear_everywhere(self.entry["id"])
        existing = activation.load_activations()["projects"][self.project][self.entry["id"]]
        new_project = activation.canonical_project(os.path.join(self.tmp.name, "later"))
        os.makedirs(new_project)

        result = activation.reevaluate_pending(
            new_project, RecheckProbe(new_project, command_ready=True)
        )

        self.assertTrue(cleared.changed)
        self.assertTrue(existing["enabled"])
        self.assertEqual(result.attempts, [])
        self.assertNotIn(new_project, activation.load_activations()["projects"])

    def test_agent_trusted_everywhere_requires_yes_and_status_names_scope(self):
        catalog = load_catalog()
        catalog["entries"][self.entry["id"]]["executionMode"] = "agent-trusted"
        save_catalog(catalog)
        with self.assertRaisesRegex(activation.ActivationError, "future Project"):
            activation.activate_everywhere(
                self.entry["id"],
                ["claude"],
                StubClaude([]),
                StubVolumeProbe([]),
            )

        activation.activate_everywhere(
            self.entry["id"],
            ["claude"],
            StubClaude([]),
            StubVolumeProbe([]),
            accept_agent_trust_everywhere=True,
        )
        status = lifecycle.catalog_project_status(
            self.project, RecheckProbe(self.project, command_ready=True)
        )
        row = next(item for item in status["entries"] if item["id"] == self.entry["id"])
        self.assertTrue(row["everywhere"])
        self.assertEqual(row["agentIdentityTrustScope"], "every-project")
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli._cmd_catalog_effective_list(
                ["--project", self.project], as_json=False
            )
        self.assertEqual(rc, 0)
        self.assertIn("every-project", stdout.getvalue())
        self.assertIn("every present and future Project", stdout.getvalue())

    def test_cli_agent_trusted_everywhere_requires_and_reports_yes(self):
        catalog = load_catalog()
        catalog["entries"][self.entry["id"]]["executionMode"] = "agent-trusted"
        save_catalog(catalog)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            rc = cli._cmd_activate(
                [self.entry["id"], "--everywhere", "--for", "claude"],
                as_json=False,
            )
        self.assertEqual(rc, 1)
        self.assertIn("every present and future Project", stderr.getvalue())

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli._cmd_activate(
                [
                    self.entry["id"],
                    "--everywhere",
                    "--for",
                    "claude",
                    "--yes",
                ],
                as_json=False,
            )
        self.assertEqual(rc, 0)
        self.assertIn("future Projects inherit", stdout.getvalue())
        self.assertIn("agent-identity trust", stdout.getvalue())

    def test_cli_rejects_project_with_everywhere(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            rc = cli._cmd_activate(
                [
                    self.entry["id"],
                    "--project",
                    self.project,
                    "--everywhere",
                    "--for",
                    "claude",
                ],
                as_json=False,
            )
        self.assertEqual(rc, 2)
        self.assertIn("cannot be combined", stderr.getvalue())

    def test_status_shows_sticky_everywhere_opt_out(self):
        activation.activate_everywhere(
            self.entry["id"],
            ["claude"],
            StubClaude([]),
            StubVolumeProbe([]),
        )
        activation.deactivate(self.entry["id"], self.project)

        status = lifecycle.catalog_project_status(
            self.project, RecheckProbe(self.project, command_ready=True)
        )
        row = next(item for item in status["entries"] if item["id"] == self.entry["id"])
        self.assertEqual(row["activation"], "opted-out")
        self.assertTrue(row["everywhere"])
        self.assertTrue(row["optedOut"])
        self.assertEqual(status["everywhereOptOuts"], [self.entry["id"]])

    def test_catalog_removal_clears_everywhere_mark_and_opt_out(self):
        activation.activate_everywhere(
            self.entry["id"],
            ["claude"],
            StubClaude([]),
            StubVolumeProbe([]),
        )
        activation.deactivate(self.entry["id"], self.project)

        activation.remove_catalog_entry(self.entry["id"])

        data = activation.load_activations()
        self.assertNotIn(self.entry["id"], data["everywhere"])
        self.assertNotIn(self.project, data["projects"])


if __name__ == "__main__":
    unittest.main()
