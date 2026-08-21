"""ADR 0028: catalog changes republish runtime without consumer renders."""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import activation, cli, lifecycle  # noqa: E402
from mcp.catalog import add_entry, add_remote_entry, load_catalog, update_entry  # noqa: E402


class Probe(activation.DockerProbe):
    def __init__(self, projects):
        self.projects = set(projects)

    def find_running(self, project_key):
        return "boxa-test" if project_key in self.projects else None

    def ready(self, container, entry):
        return True

    def command_path(self, container, command, user):
        return command

    def path_is(self, container, path, kind, user):
        return True

    def credential_present(self, container, project_key, server_name, key, user):
        return True

    def image_exists(self, container, engine, image):
        return True

    def codex_logged_in(self, container):
        return True


class MissingCommandProbe(Probe):
    def command_path(self, container, command, user):
        return None


class CatalogLifecycleIsolationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = {key: os.environ.get(key) for key in ("HOME", "XDG_CONFIG_HOME")}
        self.addCleanup(self._restore)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")
        self.projects = [os.path.join(self.tmp.name, name) for name in ("one", "two")]
        for project in self.projects:
            os.makedirs(project)
            with open(os.path.join(project, "keep.txt"), "wb") as fh:
                fh.write(b"byte-identical\n")
        added = add_entry("echo", ["npx", "placeholder"])
        self.entry = update_entry(added["id"], argv=["/bin/echo", "old"])
        probe = Probe(self.projects)
        for project, consumers in zip(self.projects, (["claude"], ["codex"])):
            activation.activate(self.entry["id"], project, consumers, probe)

    def _restore(self):
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _project_bytes(self):
        values = []
        for project in self.projects:
            with open(os.path.join(project, "keep.txt"), "rb") as fh:
                values.append(fh.read())
        return values

    def test_runtime_affecting_update_touches_no_project_file(self):
        before = self._project_bytes()
        updated = update_entry(
            self.entry["id"], argv=["/bin/echo", "new"], probe=Probe(self.projects)
        )
        self.assertEqual(updated["id"], self.entry["id"])
        self.assertEqual(self._project_bytes(), before)
        with open(activation.runtime_path(), encoding="utf-8") as fh:
            runtime = json.load(fh)
        self.assertEqual(runtime["entries"][self.entry["id"]]["command"]["argv"], ["/bin/echo", "new"])

    def test_remove_cascades_activations_without_project_writes(self):
        before = self._project_bytes()
        result = activation.remove_catalog_entry(self.entry["id"])
        self.assertEqual(len(result.affected), 2)
        self.assertEqual(self._project_bytes(), before)
        self.assertNotIn(self.entry["id"], load_catalog()["entries"])
        self.assertEqual(activation.load_activations()["projects"], {})

    def test_status_has_no_render_or_tracked_file_state(self):
        status = lifecycle.catalog_project_status(self.projects[0], Probe(self.projects))
        row = next(entry for entry in status["entries"] if entry["id"] == self.entry["id"])
        self.assertNotIn("renders", row)
        self.assertNotIn("trackedCodexConfig", row)
        self.assertNotIn("trackedMcpJson", row)
        self.assertEqual(row["activationProjectCount"], 2)
        self.assertEqual(row["activationProjects"], self.projects)

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli._cmd_catalog_effective_list(
                ["--project", self.projects[0]], as_json=True
            )
        self.assertEqual(rc, 0)
        payload = json.loads(stdout.getvalue())
        json_row = next(
            item for item in payload["catalogEntries"]
            if item["id"] == self.entry["id"]
        )
        self.assertEqual(json_row["activationProjects"], self.projects)

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli._cmd_catalog_effective_list(
                ["--project", self.projects[0]], as_json=False
            )
        self.assertEqual(rc, 0)
        self.assertIn("PROJECTS", stdout.getvalue())
        self.assertIn("2", stdout.getvalue())

    def test_remote_status_names_no_runtime_readiness_and_allowlist_hint(self):
        remote = add_remote_entry(
            "dozzle", "https://mcp.dozzle.example.test/api"
        )
        status = lifecycle.catalog_project_status(
            self.projects[0], Probe(set())
        )
        row = next(entry for entry in status["entries"] if entry["id"] == remote["id"])
        self.assertEqual(row["readiness"]["state"], "no-runtime-readiness")
        self.assertEqual(
            row["readiness"]["hints"],
            ["boxa allow mcp.dozzle.example.test"],
        )
        self.assertEqual(row["executionMode"], "none")

    def test_pending_status_names_state_and_stored_blocking_reason(self):
        pending_project = os.path.join(self.tmp.name, "pending")
        os.makedirs(pending_project)
        activation.activate(
            self.entry["id"], pending_project, ["claude"], Probe(set())
        )
        activation.reevaluate_pending(
            pending_project, MissingCommandProbe({pending_project})
        )
        reason = activation.load_activations()["projects"][pending_project][
            self.entry["id"]
        ]["pendingReason"]
        self.assertIn("executable /bin/echo", reason)

        status = lifecycle.catalog_project_status(
            pending_project, MissingCommandProbe({pending_project})
        )
        row = next(entry for entry in status["entries"] if entry["id"] == self.entry["id"])
        self.assertEqual(row["activation"], "pending")
        self.assertEqual(row["pendingReason"], reason)

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli._cmd_catalog_effective_list(
                ["--project", pending_project], as_json=False
            )
        self.assertEqual(rc, 0)
        self.assertIn("pending", stdout.getvalue())
        self.assertIn(reason, stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
