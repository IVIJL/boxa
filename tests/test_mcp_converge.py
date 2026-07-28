"""ADR 0022 issue 04: in-Container MCP render convergence."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import activation, cli, converge, trusted  # noqa: E402
from mcp.catalog import CATALOG_VERSION, add_entry, update_entry  # noqa: E402


class ConvergeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        keys = (
            "HOME",
            "XDG_CONFIG_HOME",
            "CLAUDE_CONFIG_DIR",
            "BOXA_PROJECT_HOST_PATH",
        )
        self.old = {key: os.environ.get(key) for key in keys}
        self.addCleanup(self._restore_environment)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(
            self.tmp.name, ".claude"
        )
        os.environ.pop("BOXA_PROJECT_HOST_PATH", None)
        os.makedirs(os.environ["CLAUDE_CONFIG_DIR"])

        self.project = activation.canonical_project(
            os.path.join(self.tmp.name, "project")
        )
        os.makedirs(self.project)
        self.snapshot = os.path.join(self.tmp.name, "runtime.json")
        patch = mock.patch.object(
            trusted, "RUNTIME_SNAPSHOT_PATH", self.snapshot
        )
        patch.start()
        self.addCleanup(patch.stop)

        added = add_entry("echo", ["npx", "placeholder"])
        self.entry = update_entry(added["id"], argv=["/bin/cat"])
        added = add_entry("other", ["npx", "placeholder"])
        self.other = update_entry(added["id"], argv=["/bin/echo"])
        self.entries = {
            self.entry["id"]: self.entry,
            self.other["id"]: self.other,
        }

    def _restore_environment(self):
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _record(self, entry, consumers=None, enabled=None):
        record = {
            "catalogId": entry["id"],
            "consumers": consumers or ["claude"],
        }
        if enabled is not None:
            record["enabled"] = enabled
        return record

    def _write_snapshot(
        self, records=None, projects=None, tracked_mcp_json=None
    ):
        if projects is None:
            projects = {self.project: records or {}}
        data = {
            "version": 1,
            "catalogVersion": CATALOG_VERSION,
            "entries": self.entries,
            "projects": projects,
        }
        if tracked_mcp_json is not None:
            data["trackedMcpJson"] = tracked_mcp_json
        with open(self.snapshot, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        return data

    def _desired_records(self):
        return {self.entry["id"]: self._record(self.entry)}

    def _mcp_data(self):
        with open(
            activation.claude_config_path(self.project), encoding="utf-8"
        ) as fh:
            return json.load(fh)

    def _settings_data(self):
        with open(
            activation.claude_settings_path(self.project), encoding="utf-8"
        ) as fh:
            return json.load(fh)

    def _write_mcp(self, data):
        with open(
            activation.claude_config_path(self.project), "w", encoding="utf-8"
        ) as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")

    def _remove_converge_state(self):
        try:
            os.unlink(converge.state_path())
        except FileNotFoundError:
            pass

    def _git(self, *args):
        return subprocess.run(
            ["git", "-C", self.project, *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout.strip()

    def _init_git(self):
        self._git("init", "-q")
        self._git("config", "user.email", "boxa-tests@example.invalid")
        self._git("config", "user.name", "Boxa Tests")

    def test_deleted_render_is_restored_from_snapshot_without_host_store(self):
        self._write_snapshot(self._desired_records())
        host_store = os.path.join(
            os.environ["XDG_CONFIG_HOME"], "boxa", "mcp"
        )
        shutil.rmtree(host_store)

        with (
            mock.patch.object(
                activation,
                "load_catalog",
                side_effect=AssertionError("host catalog accessed"),
            ),
            mock.patch.object(
                activation,
                "load_activations",
                side_effect=AssertionError("host activations accessed"),
            ),
            mock.patch.object(
                activation,
                "render_state_path",
                side_effect=AssertionError("host render state accessed"),
            ),
        ):
            result = converge.converge(self.project)[0]

        self.assertEqual(result.status, "converged")
        self.assertEqual(result.added, ["boxa-echo"])
        self.assertEqual(
            self._mcp_data()["mcpServers"]["boxa-echo"]["command"],
            "boxa-mcp-run",
        )
        self.assertFalse(os.path.exists(host_store))

    def test_second_convergence_is_in_sync_and_writes_nothing(self):
        self._write_snapshot(self._desired_records())
        converge.converge(self.project)
        paths = (
            activation.claude_config_path(self.project),
            activation.claude_settings_path(self.project),
            converge.state_path(),
        )
        before = {
            path: (os.stat(path).st_mtime_ns, os.stat(path).st_ino)
            for path in paths
        }

        with mock.patch.object(
            activation,
            "_atomic_text",
            side_effect=AssertionError("in-sync convergence wrote a file"),
        ), mock.patch.object(
            activation,
            "_claude_git_paths",
            side_effect=AssertionError("in-sync convergence invoked Git"),
        ):
            result = converge.converge(self.project)[0]

        self.assertEqual(result.status, "in-sync")
        self.assertEqual(
            {
                path: (os.stat(path).st_mtime_ns, os.stat(path).st_ino)
                for path in paths
            },
            before,
        )

    def test_desired_hand_edited_entry_is_repaired_not_removed(self):
        self._write_snapshot(self._desired_records())
        self._write_mcp({
            "z": "first",
            "mcpServers": {
                "boxa-echo": {
                    "command": "hand-edited",
                    "args": ["wrong"],
                    "extra": True,
                },
            },
            "a": "last",
        })

        result = converge.converge(self.project)[0]

        self.assertEqual(result.repaired, ["boxa-echo"])
        self.assertEqual(result.removed, [])
        data = self._mcp_data()
        self.assertEqual(data["z"], "first")
        self.assertEqual(data["a"], "last")
        self.assertEqual(
            data["mcpServers"]["boxa-echo"]["args"][-1], "echo"
        )

    def test_converge_preserves_unmanaged_mcp_json_bytes(self):
        records = {
            self.entry["id"]: self._record(self.entry),
            self.other["id"]: self._record(self.other),
        }
        self._write_snapshot(records)
        original = (
            '{\n'
            '\t"label": "caf\\u00e9",\n'
            '\t"mcpServers": {\n'
            '\t\t"foreign": {"command":"keep","ratio":1.0},\n'
            '\t\t"boxa-echo": {"command":"old"},\n'
            '\t\t"boxa-stale": {"command":"old"}\n'
            '\t},\n'
            '\t"numeric": 1e3\n'
            '}\t'
        )
        mcp_path = activation.claude_config_path(self.project)
        with open(mcp_path, "w", encoding="utf-8") as fh:
            fh.write(original)
        os.makedirs(os.path.dirname(converge.state_path()), exist_ok=True)
        with open(converge.state_path(), "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "version": 1,
                    "projects": {
                        self.project: ["boxa-echo", "boxa-stale"],
                    },
                    "seeded": {},
                },
                fh,
            )

        result = converge.converge(self.project)[0]

        echo = json.dumps(
            activation.claude_server_definition(
                self.entry["id"], self.project, self.entry
            ),
            separators=(",", ":"),
        )
        other = json.dumps(
            activation.claude_server_definition(
                self.other["id"], self.project, self.other
            ),
            separators=(",", ":"),
        )
        expected = (
            '{\n'
            '\t"label": "caf\\u00e9",\n'
            '\t"mcpServers": {\n'
            '\t\t"foreign": {"command":"keep","ratio":1.0},\n'
            f'\t\t"boxa-echo": {echo},\n'
            f'\t\t"boxa-other": {other}\n'
            '\t},\n'
            '\t"numeric": 1e3\n'
            '}\t'
        )
        with open(mcp_path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), expected)
        self.assertEqual(result.added, ["boxa-other"])
        self.assertEqual(result.repaired, ["boxa-echo"])
        self.assertEqual(result.removed, ["boxa-stale"])

    def test_snapshot_deactivation_removes_only_the_deactivated_entry(self):
        records = {
            self.entry["id"]: self._record(self.entry),
            self.other["id"]: self._record(self.other),
        }
        self._write_snapshot(records)
        converge.converge(self.project)
        self._write_snapshot({self.other["id"]: self._record(self.other)})

        result = converge.converge(self.project)[0]

        self.assertEqual(result.removed, ["boxa-echo"])
        self.assertEqual(
            set(self._mcp_data()["mcpServers"]), {"boxa-other"}
        )

    def test_snapshot_deactivation_withdraws_only_boxa_seeded_approval(self):
        self._write_snapshot(self._desired_records())
        converge.converge(self.project)
        settings_path = activation.claude_settings_path(self.project)
        settings = self._settings_data()
        settings["enabledMcpjsonServers"].append("user-enabled")
        settings["unrelated"] = {"keep": True}
        with open(settings_path, "w", encoding="utf-8") as fh:
            json.dump(settings, fh, indent=2)
            fh.write("\n")
        self._write_snapshot({})

        result = converge.converge(self.project)[0]

        self.assertTrue(result.approval_changed)
        settings = self._settings_data()
        self.assertEqual(settings["enabledMcpjsonServers"], ["user-enabled"])
        self.assertEqual(settings["unrelated"], {"keep": True})
        self.assertNotIn(
            "boxa-echo", settings.get("disabledMcpjsonServers", [])
        )

    def test_tracked_mcp_change_without_snapshot_consent_skips_all_writes(self):
        self._init_git()
        mcp_path = activation.claude_config_path(self.project)
        settings_path = activation.claude_settings_path(self.project)
        os.makedirs(os.path.dirname(settings_path))
        with open(mcp_path, "w", encoding="utf-8") as fh:
            fh.write('{"theme":"tracked"}\n')
        with open(settings_path, "w", encoding="utf-8") as fh:
            fh.write('{"enabledMcpjsonServers":["user-enabled"]}\n')
        self._git("add", ".mcp.json")
        self._git("commit", "-qm", "tracked mcp config")
        exclude_path = self._git(
            "rev-parse", "--path-format=absolute", "--git-path", "info/exclude"
        )
        paths = (mcp_path, settings_path, exclude_path)
        before = {}
        for path in paths:
            with open(path, "rb") as fh:
                before[path] = fh.read()
        self._write_snapshot(self._desired_records())

        result = converge.converge(self.project)[0]

        self.assertEqual(result.status, "skipped")
        self.assertIn(mcp_path, result.reason)
        self.assertIn("--allow-tracked-mcp-json", result.reason)
        self.assertFalse(os.path.exists(converge.state_path()))
        for path in paths:
            with open(path, "rb") as fh:
                self.assertEqual(fh.read(), before[path])

    def test_tracked_mcp_change_with_snapshot_consent_converges(self):
        self._init_git()
        mcp_path = activation.claude_config_path(self.project)
        with open(mcp_path, "w", encoding="utf-8") as fh:
            fh.write('{"theme":"tracked"}\n')
        self._git("add", ".mcp.json")
        self._git("commit", "-qm", "tracked mcp config")
        self._write_snapshot(
            self._desired_records(),
            tracked_mcp_json={self.project: True},
        )

        result = converge.converge(self.project)[0]

        self.assertEqual(result.status, "converged")
        self.assertIn("boxa-echo", self._mcp_data()["mcpServers"])

    def test_in_sync_tracked_mcp_allows_approval_repair_without_consent(self):
        self._write_snapshot(self._desired_records())
        converge.converge(self.project)
        self._init_git()
        self._git("add", "-f", ".mcp.json")
        self._git("commit", "-qm", "track rendered mcp config")
        settings_path = activation.claude_settings_path(self.project)
        os.unlink(settings_path)

        result = converge.converge(self.project)[0]

        self.assertEqual(result.status, "converged")
        self.assertEqual(result.seeded, ["boxa-echo"])
        self.assertEqual(
            self._settings_data()["enabledMcpjsonServers"], ["boxa-echo"]
        )

    def test_untracked_mcp_change_needs_no_snapshot_consent(self):
        self._init_git()
        self._write_snapshot(self._desired_records(), tracked_mcp_json={})

        result = converge.converge(self.project)[0]

        self.assertEqual(result.status, "converged")
        self.assertIn("boxa-echo", self._mcp_data()["mcpServers"])

    def test_foreign_servers_and_top_level_keys_survive_and_are_not_seeded(self):
        self._write_snapshot(self._desired_records())
        foreign = {"command": "foreign", "args": ["--keep"], "x": {"y": 1}}
        self._write_mcp({
            "unrelated": {"keep": True},
            "mcpServers": {
                "foreign": foreign,
                "boxa-lookalike": {"command": "not-boxa-mcp-run"},
            },
        })

        converge.converge(self.project)
        data = self._mcp_data()
        settings = self._settings_data()

        self.assertEqual(data["unrelated"], {"keep": True})
        self.assertEqual(data["mcpServers"]["foreign"], foreign)
        self.assertIn("boxa-lookalike", data["mcpServers"])
        self.assertEqual(
            settings["enabledMcpjsonServers"], ["boxa-echo"]
        )

    def test_invalid_snapshots_skip_without_writes_or_removal(self):
        valid = self._write_snapshot(self._desired_records())
        converge.converge(self.project)
        mcp_path = activation.claude_config_path(self.project)
        with open(mcp_path, "rb") as fh:
            baseline = fh.read()
        cases = {
            "missing": None,
            "empty": b"",
            "non-json": b"{not json",
            "wrong-version": json.dumps(
                {**valid, "version": 999}
            ).encode(),
            "malformed-maps": json.dumps(
                {**valid, "projects": []}
            ).encode(),
            "malformed-tracked-consent": json.dumps(
                {**valid, "trackedMcpJson": {self.project: "yes"}}
            ).encode(),
        }

        for name, payload in cases.items():
            with self.subTest(name=name):
                if payload is None:
                    try:
                        os.unlink(self.snapshot)
                    except FileNotFoundError:
                        pass
                else:
                    with open(self.snapshot, "wb") as fh:
                        fh.write(payload)
                with mock.patch.object(
                    activation,
                    "_atomic_text",
                    side_effect=AssertionError("invalid snapshot caused a write"),
                ):
                    result = converge.converge(self.project)[0]
                self.assertEqual(result.status, "skipped")
                with open(mcp_path, "rb") as fh:
                    self.assertEqual(fh.read(), baseline)

    def test_approval_reseeding_and_disabled_decisions(self):
        self._write_snapshot(self._desired_records())
        converge.converge(self.project)
        settings_path = activation.claude_settings_path(self.project)
        os.unlink(settings_path)

        result = converge.converge(self.project)[0]
        self.assertEqual(result.seeded, ["boxa-echo"])
        self.assertEqual(
            self._settings_data()["enabledMcpjsonServers"], ["boxa-echo"]
        )
        self.assertNotIn(
            "enableAllProjectMcpServers", self._settings_data()
        )

        self._remove_converge_state()
        self._write_mcp(self._mcp_data())
        with open(settings_path, "w", encoding="utf-8") as fh:
            json.dump({"disabledMcpjsonServers": ["boxa-echo"]}, fh)
        result = converge.converge(self.project)[0]
        self.assertEqual(result.seeded, [])
        settings = self._settings_data()
        self.assertNotIn(
            "boxa-echo", settings.get("enabledMcpjsonServers", [])
        )
        self.assertEqual(
            settings["disabledMcpjsonServers"], ["boxa-echo"]
        )

        os.unlink(settings_path)
        self._remove_converge_state()
        claude_data = {
            "projects": {
                self.project: {
                    "enabledMcpjsonServers": [],
                    "disabledMcpjsonServers": ["boxa-echo"],
                }
            }
        }
        with open(
            activation.render_target_path(), "w", encoding="utf-8"
        ) as fh:
            json.dump(claude_data, fh)
        converge.converge(self.project)
        settings = self._settings_data()
        self.assertNotIn(
            "boxa-echo", settings.get("enabledMcpjsonServers", [])
        )
        self.assertEqual(
            settings["disabledMcpjsonServers"], ["boxa-echo"]
        )
        self.assertNotIn("enableAllProjectMcpServers", settings)

    def test_disabled_or_non_claude_snapshot_records_are_not_desired(self):
        self._write_snapshot(self._desired_records())
        converge.converge(self.project)
        cases = {
            "disabled": self._record(self.entry, enabled=False),
            "codex-only": self._record(self.entry, consumers=["codex"]),
        }
        for name, record in cases.items():
            with self.subTest(name=name):
                self._write_snapshot({self.entry["id"]: record})
                result = converge.converge(self.project)[0]
                self.assertEqual(result.status, "converged")
                self.assertEqual(result.removed, ["boxa-echo"])
                self.assertNotIn(
                    "boxa-echo", self._mcp_data().get("mcpServers", {})
                )
                self._write_snapshot(self._desired_records())
                converge.converge(self.project)

    def test_project_resolution_sources_and_no_project_skip(self):
        alias = os.path.join(self.project, "..", "project")
        self._write_snapshot(
            projects={alias: self._desired_records()}
        )

        explicit = converge.converge(self.project)[0]
        self.assertEqual(explicit.project, self.project)
        self.assertIn("boxa-echo", self._mcp_data()["mcpServers"])

        os.environ["BOXA_PROJECT_HOST_PATH"] = alias
        self.assertEqual(
            converge.converge()[0].status, "in-sync"
        )

        os.environ.pop("BOXA_PROJECT_HOST_PATH")
        identity = os.path.join(self.tmp.name, "identity.json")
        with open(identity, "w", encoding="utf-8") as fh:
            json.dump({"projectKey": alias}, fh)
        with mock.patch.object(converge, "IDENTITY_PATH", identity):
            self.assertEqual(
                converge.converge()[0].project, self.project
            )

        missing_identity = os.path.join(self.tmp.name, "missing-identity.json")
        with (
            mock.patch.object(converge, "IDENTITY_PATH", missing_identity),
            mock.patch.object(
                activation,
                "_atomic_text",
                side_effect=AssertionError("no-Project skip wrote a file"),
            ),
        ):
            result = converge.converge()[0]
        self.assertEqual(result.status, "skipped")
        self.assertIn("no Container Project", result.reason)

    def test_state_is_private_and_cli_supports_json_quiet_and_project(self):
        self._write_snapshot(self._desired_records())
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli.main([
                "converge", "--project", self.project, "--json"
            ])
        self.assertEqual(rc, 0)
        self.assertEqual(
            json.loads(stdout.getvalue())["results"][0]["status"],
            "converged",
        )
        self.assertEqual(
            stat.S_IMODE(os.stat(converge.state_path()).st_mode), 0o600
        )

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli.main([
                "converge", "--project", self.project, "--quiet"
            ])
        self.assertEqual(rc, 0)
        self.assertEqual(stdout.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
