"""ADR 0021 issue 09: catalog operating-path integration proof.

Everything is local and disposable: Docker, login, images, and runtimes are
deterministic probes/stubs; HOME/XDG/Claude and both Git Projects live under a
TemporaryDirectory.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import activation, catalog, lifecycle, migration, trusted  # noqa: E402
from mcp.catalog import add_entry, load_catalog, save_catalog, set_execution_mode, update_entry  # noqa: E402
from mcp.docker_adapter import build_plan as build_docker_plan  # noqa: E402
from mcp.profile import project_profile_path, save_profile  # noqa: E402
from mcp.readiness import ProjectProbe  # noqa: E402
from mcp.secrets import project_secrets_path, store_server_secrets  # noqa: E402


class LocalProbe(ProjectProbe):
    def find_running(self, project_key):
        return "boxa-fixture" if os.path.isdir(project_key) else None

    def command_path(self, container, command, user):
        return f"/fixture/{os.path.basename(command)}"

    def path_is(self, container, path, kind, user):
        return True

    def credential_present(self, container, project_key, server_name, key, user):
        return True

    def image_exists(self, container, engine, image):
        return True

    def codex_logged_in(self, container):
        return True


def legacy_server(argv):
    return {
        "name": "ignored", "type": "stdio", "command": {"argv": argv},
        "envKeys": [], "secretEnvKeys": [], "enabled": True,
        "source": {"provider": "fixture", "importId": "imp-fixture"},
    }


class CatalogOperatingPathIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = {key: os.environ.get(key) for key in ("HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR")}
        self.addCleanup(self._restore)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(self.tmp.name, ".claude")
        self.project = os.path.join(self.tmp.name, "project")
        self.other = os.path.join(self.tmp.name, "unrelated")
        for project in (self.project, self.other):
            os.makedirs(project)
            subprocess.run(["git", "init", "-q", project], check=True)
        patcher = mock.patch.object(trusted, "RUNTIME_SNAPSHOT_PATH", activation.runtime_path())
        patcher.start()
        self.addCleanup(patcher.stop)
        self.probe = LocalProbe()

    def _restore(self):
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _write_legacy_render(self):
        path = activation.render_target_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"projects": {self.project: {"mcpServers": {"boxa-legacy": {
                "command": "boxa-mcp-run", "args": ["--project", self.project, "legacy"],
            }}}}}, fh)

    def test_full_catalog_migration_delegation_docker_and_teardown(self):
        # Fresh state: both Projects have an empty, opt-in catalog view.
        self.assertEqual(lifecycle.catalog_project_status(self.project, self.probe)["entries"], [])
        self.assertEqual(lifecycle.catalog_project_status(self.other, self.probe)["entries"], [])

        # Legacy Project exposure migrates only to its original Claude consumer.
        save_profile(project_profile_path(self.project), {
            "version": 1, "projectKey": self.project,
            "servers": {"legacy": legacy_server(["/bin/cat"])},
        })
        self._write_legacy_render()
        migrated = migration.migrate_legacy()
        self.assertEqual(migrated["status"], "complete")
        legacy_id = migrated["definitions"][0]["catalogId"]
        records = activation.load_activations()["projects"]
        self.assertEqual(records[self.project][legacy_id]["consumers"], ["claude"])
        self.assertNotIn(self.other, records)
        activation.deactivate(legacy_id, self.project)

        # Add/install/readiness are definition/runtime facts, not activation.
        direct = update_entry(add_entry("direct", ["npx", "fixture"])["id"], argv=["/bin/cat"])
        ready = lifecycle.catalog_project_status(self.project, self.probe)
        direct_row = next(row for row in ready["entries"] if row["id"] == direct["id"])
        self.assertEqual(direct_row["readiness"]["state"], "ready")
        self.assertEqual(direct_row["activation"], "inactive")
        activation.activate(direct["id"], self.project, ["claude", "codex"], self.probe)

        # Exact Codex delegation: host-authorized agent identity, Claude-only,
        # local Codex login prerequisite, and independent snapshot validation.
        delegate = add_entry("codex-delegate", ["codex", "mcp-server"])
        with mock.patch.object(catalog, "_host_mode_command", return_value=True):
            set_execution_mode(delegate["id"], "agent-trusted")
        activation.activate(delegate["id"], self.project, ["claude"], self.probe)
        runtime = trusted.load_runtime_snapshot()
        authorized = trusted.authorize_entry(runtime, "codex-delegate", self.project, delegate["id"], "claude")
        launch = trusted.build_launch_plan(authorized, delegate["id"], "claude", self.project, socket_probe=lambda _path: False)
        self.assertEqual(launch["argv"], ["codex", "mcp-server"])
        self.assertEqual(launch["env"]["HOME"], "/home/node")
        self.assertNotIn("TOKEN", launch["env"])

        # Docker adapter gets only declared image/project/env/stdio, never the socket.
        docker = add_entry("docker-fixture", ["docker", "run", "--rm", "fixture:1", "serve"])
        plan = build_docker_plan(docker, docker["id"], "claude", self.project, self.project, {})
        self.assertNotIn("docker.sock", " ".join(plan["argv"]))
        activation.activate(docker["id"], self.project, ["claude"], self.probe)

        status = lifecycle.catalog_project_status(self.project, self.probe)
        by_name = {row["name"]: row for row in status["entries"]}
        self.assertEqual(by_name["direct"]["renders"], {"claude": "rendered", "codex": "rendered"})
        self.assertEqual(by_name["codex-delegate"]["executionUser"], "node")
        self.assertEqual(by_name["docker-fixture"]["executionUser"], "boxa-mcp")
        self.assertTrue(all(row["activation"] == "inactive" for row in lifecycle.catalog_project_status(self.other, self.probe)["entries"]))

        # Doctor repairs derived drift only and never creates cross-Project state.
        with open(activation.render_target_path(), encoding="utf-8") as fh:
            claude = json.load(fh)
        del claude["projects"][self.project]["mcpServers"]["boxa-codex-delegate"]
        with open(activation.render_target_path(), "w", encoding="utf-8") as fh:
            json.dump(claude, fh)
        report = lifecycle.DoctorReport(False, lifecycle._catalog_doctor_findings(self.probe))
        self.assertIn("catalog-claude-render-drift", {finding.code for finding in report.findings})
        fixed = lifecycle.apply_doctor_fixes(report)
        self.assertTrue(any("Claude" in action for action in fixed.actions))
        self.assertNotIn(self.other, activation.load_activations()["projects"])

        # Deactivation blocks new launches; removal destroys stable identity.
        activation.deactivate(delegate["id"], self.project)
        with self.assertRaises(trusted.TrustedAuthorizationError):
            trusted.authorize_entry(trusted.load_runtime_snapshot(), "codex-delegate", self.project, delegate["id"], "claude")
        activation.remove_catalog_entry(delegate["id"])
        self.assertNotIn(delegate["id"], load_catalog()["entries"])

    def test_doctor_names_forbidden_trusted_secret_without_value(self):
        entry = update_entry(add_entry("unsafe", ["npx", "fixture"])["id"], argv=["/bin/cat"])
        store_server_secrets(
            project_secrets_path(self.project), entry["id"],
            {"TOKEN": "do-not-leak"},
        )
        path = catalog.catalog_path()
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
        raw["entries"][entry["id"]]["executionMode"] = "agent-trusted"
        raw["entries"][entry["id"]]["secretEnvKeys"] = ["TOKEN"]
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(raw, fh)

        payload = json.dumps(
            [finding.to_dict() for finding in lifecycle._catalog_doctor_findings()]
        )
        self.assertIn("trusted-secrets-forbidden", payload)
        self.assertNotIn("TOKEN", payload)
        self.assertNotIn("do-not-leak", payload)

    def test_doctor_detects_retained_value_for_inactive_trusted_identity(self):
        entry = update_entry(
            add_entry("retained", ["npx", "fixture"])["id"],
            argv=["/bin/cat"],
        )
        data = load_catalog()
        data["entries"][entry["id"]]["executionMode"] = "agent-trusted"
        data["entries"][entry["id"]]["secretStoreKey"] = entry["id"]
        save_catalog(data)
        store_server_secrets(
            project_secrets_path(self.project), entry["id"],
            {"PRIVATE_KEY_NAME": "retained-do-not-leak"},
        )

        # No activation exists: trust and retained values are catalog-identity
        # invariants, not Project activation checks.
        self.assertEqual(activation.load_activations()["projects"], {})
        payload = json.dumps(
            [finding.to_dict() for finding in lifecycle._catalog_doctor_findings()]
        )
        self.assertIn("trusted-secrets-forbidden", payload)
        self.assertNotIn("PRIVATE_KEY_NAME", payload)
        self.assertNotIn("retained-do-not-leak", payload)
        self.assertNotIn(project_secrets_path(self.project), payload)


if __name__ == "__main__":
    unittest.main()
