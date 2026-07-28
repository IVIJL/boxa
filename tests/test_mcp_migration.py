"""ADR 0021 issue 08: safe legacy migration and definition-only import."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import activation, migration  # noqa: E402
from mcp.catalog import catalog_path, load_catalog  # noqa: E402
from mcp.profile import (  # noqa: E402
    global_profile_path,
    project_profile_path,
    save_profile,
)
from mcp.render import build_render_plan  # noqa: E402
from mcp.runner import RunnerError, _resolve_env  # noqa: E402
from mcp.secrets import (  # noqa: E402
    project_secrets_path,
    read_server_secrets,
    store_server_secrets,
)


def _server(argv, *, enabled=True, secrets=None):
    return {
        "name": "ignored",
        "type": "stdio",
        "command": {"argv": list(argv)},
        "envKeys": list(secrets or []),
        "secretEnvKeys": list(secrets or []),
        "enabled": enabled,
        "source": {"provider": "legacy", "importId": "imp-old"},
    }


class MigrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = {key: os.environ.get(key) for key in ("HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR")}
        self.addCleanup(self._restore)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(self.tmp.name, ".claude")
        self.project = os.path.realpath(os.path.join(self.tmp.name, "project"))
        os.makedirs(self.project)

    def _restore(self):
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _write_project(self, project, servers):
        save_profile(project_profile_path(project), {
            "version": 1, "projectKey": project, "servers": servers,
        })

    def _write_claude(self, projects, *, global_entries=None):
        path = activation.render_target_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({
                "mcpServers": global_entries or {},
                "projects": projects,
            }, fh)
        return path

    @staticmethod
    def _state(paths):
        result = {}
        for path in paths:
            if os.path.exists(path):
                with open(path, "rb") as fh:
                    result[path] = (True, fh.read(), stat.S_IMODE(os.stat(path).st_mode))
            else:
                result[path] = (False, b"", 0)
        return result

    def test_mixed_profiles_keep_only_actually_rendered_project_consumer(self):
        save_profile(global_profile_path(), {
            "version": 1, "servers": {"global": _server(["npx", "global"])},
        })
        self._write_project(self.project, {
            "active": _server(["npx", "active"]),
            "disabled": _server(["npx", "disabled"], enabled=False),
        })
        legacy_global = {"command": "boxa-mcp-run", "args": ["global"]}
        claude_path = self._write_claude({
            self.project: {
                "mcpServers": {
                    "boxa-active": {
                        "type": "stdio", "command": "boxa-mcp-run",
                        "args": ["--project", self.project, "active"],
                    },
                    "manual": {"command": "manual-server"},
                }
            }
        }, global_entries={"boxa-global": legacy_global, "manual-global": {"command": "keep"}})
        legacy_profile = self._state([global_profile_path(), project_profile_path(self.project)])

        result = migration.migrate_legacy()

        self.assertTrue(result["changed"])
        entries = load_catalog()["entries"]
        self.assertEqual(len(entries), 3)
        self.assertTrue(all(e["executionMode"] == "service-isolated" for e in entries.values()))
        acts = activation.load_activations()["projects"]
        self.assertEqual(len(acts[self.project]), 1)
        record = next(iter(acts[self.project].values()))
        self.assertEqual(record["consumers"], ["claude"])
        self.assertEqual(self._state([global_profile_path(), project_profile_path(self.project)]), legacy_profile)
        with open(claude_path, encoding="utf-8") as fh:
            claude = json.load(fh)
        self.assertNotIn("boxa-global", claude["mcpServers"])
        self.assertIn("manual-global", claude["mcpServers"])
        self.assertIn("manual", claude["projects"][self.project]["mcpServers"])
        self.assertNotIn("boxa-active", claude["projects"][self.project]["mcpServers"])
        with open(
            activation.claude_config_path(self.project), encoding="utf-8"
        ) as fh:
            project_render = json.load(fh)
        self.assertIn("boxa-active", project_render["mcpServers"])
        self.assertTrue(result["legacyRetained"])
        self.assertNotIn("secret", json.dumps(result).lower())

    def test_duplicate_name_different_definition_has_audited_conflict_and_scoped_secrets(self):
        other = os.path.realpath(os.path.join(self.tmp.name, "other"))
        os.makedirs(other)
        self._write_project(self.project, {"dup": _server(["npx", "one"], secrets=["TOKEN"])})
        self._write_project(other, {"dup": _server(["uvx", "two"], secrets=["TOKEN"])})
        store_server_secrets(project_secrets_path(self.project), "dup", {"TOKEN": "one-value"})
        store_server_secrets(project_secrets_path(other), "dup", {"TOKEN": "two-value"})
        rendered = {
            entry.project_key: entry.rendered_name
            for entry in build_render_plan().claude.planned
            if entry.source_name == "dup"
        }
        self._write_claude({
            project: {"mcpServers": {rendered[project]: {
                "command": "boxa-mcp-run", "args": ["--project", project, "dup"],
            }}}
            for project in (self.project, other)
        })

        result = migration.migrate_legacy()

        rows = [row for row in result["definitions"] if row["legacyName"] == "dup"]
        self.assertEqual(len({row["catalogId"] for row in rows}), 2)
        renamed = next(row for row in rows if row["nameConflict"])
        self.assertTrue(renamed["catalogName"].startswith("dup-migrated-"))
        expected = "one-value" if renamed["project"] == self.project else "two-value"
        self.assertEqual(
            read_server_secrets(project_secrets_path(renamed["project"]), renamed["catalogId"]),
            {"TOKEN": expected},
        )
        # A later activation of the identity that retained the original display
        # name cannot inherit this Project's legacy name-keyed credential.
        original_name = next(row for row in rows if not row["nameConflict"])
        self.assertNotEqual(original_name["catalogId"], renamed["catalogId"])
        renamed_entry = load_catalog()["entries"][renamed["catalogId"]]
        original_entry = load_catalog()["entries"][original_name["catalogId"]]
        self.assertEqual(renamed_entry["secretStoreKey"], renamed["catalogId"])
        self.assertEqual(original_entry["secretStoreKey"], original_name["catalogId"])
        self.assertIsNone(
            read_server_secrets(
                project_secrets_path(renamed["project"]), original_name["catalogId"]
            )
        )
        spec = {
            "envKeys": ["TOKEN"], "secretEnvKeys": ["TOKEN"], "env": {},
        }
        secret_path = project_secrets_path(renamed["project"])
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(
                _resolve_env(spec, secret_path, renamed_entry["secretStoreKey"]),
                {"TOKEN": expected},
            )
            with self.assertRaises(RunnerError):
                _resolve_env(spec, secret_path, original_entry["secretStoreKey"])
        with open(migration.migration_path(), encoding="utf-8") as fh:
            manifest = fh.read()
        self.assertNotIn("one-value", manifest)
        self.assertNotIn("two-value", manifest)

    def test_malformed_partial_profile_preserved_without_publication(self):
        path = global_profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        raw = b'{"version":1,"servers":{"broken":{"command":{}}}}\n'
        with open(path, "wb") as fh:
            fh.write(raw)
        with self.assertRaises(migration.MigrationError):
            migration.migrate_legacy()
        self.assertFalse(os.path.exists(catalog_path()))
        self.assertFalse(os.path.exists(migration.migration_path()))
        with open(path, "rb") as fh:
            self.assertEqual(fh.read(), raw)

    def test_failure_rolls_back_exact_and_retry_is_idempotent(self):
        self._write_project(self.project, {
            "echo": _server(["/bin/echo"], secrets=["TOKEN"]),
        })
        secret_path = project_secrets_path(self.project)
        store_server_secrets(secret_path, "echo", {"TOKEN": "rollback-value"})
        self._write_claude({self.project: {"mcpServers": {"boxa-echo": {
            "command": "boxa-mcp-run", "args": ["--project", self.project, "echo"],
        }}}})
        paths = [catalog_path(), activation.activation_path(), activation.runtime_path(),
                 activation.render_target_path(), activation.render_state_path(),
                 activation.claude_config_path(self.project),
                 migration.migration_path(), secret_path]
        before = self._state(paths)
        with mock.patch.object(activation, "render_claude_activations", side_effect=OSError("injected")):
            with self.assertRaises(OSError):
                migration.migrate_legacy()
        self.assertEqual(self._state(paths), before)
        first = migration.migrate_legacy()
        second = migration.migrate_legacy()
        self.assertTrue(first["changed"])
        self.assertFalse(second["changed"])
        self.assertEqual(first["definitions"], second["definitions"])

    def test_missing_previously_rendered_project_does_not_block_migration(self):
        missing = os.path.realpath(os.path.join(self.tmp.name, "missing"))
        self._write_project(self.project, {"echo": _server(["/bin/echo"])})
        self._write_claude({self.project: {"mcpServers": {"boxa-echo": {
            "command": "boxa-mcp-run",
            "args": ["--project", self.project, "echo"],
        }}}})
        state_path = activation.render_state_path()
        os.makedirs(os.path.dirname(state_path), exist_ok=True)
        with open(state_path, "w", encoding="utf-8") as fh:
            json.dump({"projects": {missing: ["boxa-stale"]}}, fh)

        result = migration.migrate_legacy()

        self.assertEqual(result["status"], "complete")
        record = next(iter(
            activation.load_activations()["projects"][self.project].values()
        ))
        self.assertEqual(record["consumers"], ["claude"])
        with open(
            activation.claude_config_path(self.project), encoding="utf-8"
        ) as fh:
            self.assertIn("boxa-echo", json.load(fh)["mcpServers"])

    def _git(self, project, *args):
        return subprocess.run(
            ["git", "-C", project, *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ, "LC_ALL": "C"},
        ).stdout.strip()

    def _init_git(self, project):
        self._git(project, "init", "-q")
        self._git(project, "config", "user.email", "boxa@example.invalid")
        self._git(project, "config", "user.name", "Boxa Tests")

    def _track(self, project, relative, content):
        path = os.path.join(project, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        self._git(project, "add", "-f", "--", relative)
        self._git(project, "commit", "-q", "-m", "track")
        return path

    def _legacy_claude_project(self, project, name="echo"):
        self._write_project(project, {name: _server(["/bin/echo", name])})
        return {project: {"mcpServers": {f"boxa-{name}": {
            "command": "boxa-mcp-run",
            "args": ["--project", project, name],
        }}}}

    def test_tracked_mcp_json_refuses_whole_migration_without_consent(self):
        other = os.path.realpath(os.path.join(self.tmp.name, "other"))
        os.makedirs(other)
        rendered = self._legacy_claude_project(self.project)
        rendered.update(self._legacy_claude_project(other, "sibling"))
        self._write_claude(rendered)
        self._init_git(self.project)
        tracked = self._track(
            self.project, ".mcp.json", '{"mcpServers":{}}\n'
        )
        paths = [
            catalog_path(), activation.activation_path(),
            activation.runtime_path(), activation.render_target_path(),
            activation.render_state_path(), migration.migration_path(),
            tracked,
            activation.claude_config_path(other),
        ]
        before = self._state(paths)

        with self.assertRaises(migration.MigrationError) as ctx:
            migration.migrate_legacy()

        self.assertIn(tracked, str(ctx.exception))
        self.assertIn("--allow-tracked-mcp-json", str(ctx.exception))
        # Whole-batch semantics: the untracked sibling Project is not written
        # either, and no legacy state was consumed.
        self.assertEqual(self._state(paths), before)

    def test_tracked_settings_local_json_refuses_migration_without_consent(self):
        self._write_claude(self._legacy_claude_project(self.project))
        self._init_git(self.project)
        tracked = self._track(
            self.project,
            os.path.join(".claude", "settings.local.json"),
            '{"enabledMcpjsonServers":[]}\n',
        )

        with self.assertRaises(migration.MigrationError) as ctx:
            migration.migrate_legacy()

        self.assertIn(tracked, str(ctx.exception))
        self.assertFalse(os.path.exists(catalog_path()))

    def test_migration_flag_authorizes_batch_without_durable_consent(self):
        self._write_claude(self._legacy_claude_project(self.project))
        self._init_git(self.project)
        tracked = self._track(
            self.project, ".mcp.json", '{"mcpServers":{}}\n'
        )

        result = migration.migrate_legacy(allow_tracked_mcp_json=True)

        self.assertEqual(result["status"], "complete")
        with open(tracked, encoding="utf-8") as fh:
            self.assertIn("boxa-echo", json.load(fh)["mcpServers"])
        # A catalog-wide batch flag never records new durable Project consent.
        self.assertEqual(
            activation.load_activations().get("trackedMcpJson", {}), {}
        )

    def test_durable_project_consent_authorizes_migration(self):
        self._write_claude(self._legacy_claude_project(self.project))
        self._init_git(self.project)
        tracked = self._track(
            self.project, ".mcp.json", '{"mcpServers":{}}\n'
        )
        store = activation.empty_activations()
        store["trackedMcpJson"][self.project] = True
        activation.save_activation_store(store)

        result = migration.migrate_legacy()

        self.assertEqual(result["status"], "complete")
        with open(tracked, encoding="utf-8") as fh:
            self.assertIn("boxa-echo", json.load(fh)["mcpServers"])

    def test_byte_identical_tracked_render_does_not_need_migration_consent(self):
        self._write_claude(self._legacy_claude_project(self.project))
        self._init_git(self.project)
        # Render once with consent, then commit exactly those bytes. A repeat
        # migration over the tracked-but-identical file must not refuse.
        migration.migrate_legacy(allow_tracked_mcp_json=True)
        with open(
            activation.claude_config_path(self.project), encoding="utf-8"
        ) as fh:
            rendered_bytes = fh.read()
        self._track(self.project, ".mcp.json", rendered_bytes)
        with open(migration.migration_path(), encoding="utf-8") as fh:
            manifest = json.load(fh)
        manifest["status"] = "prepared"
        with open(migration.migration_path(), "w", encoding="utf-8") as fh:
            json.dump(manifest, fh)

        result = migration.migrate_legacy()

        self.assertEqual(result["status"], "complete")
        with open(
            activation.claude_config_path(self.project), encoding="utf-8"
        ) as fh:
            self.assertEqual(fh.read(), rendered_bytes)

    def test_vanished_project_still_does_not_block_migration_consent(self):
        missing = os.path.realpath(os.path.join(self.tmp.name, "missing"))
        self._write_claude(self._legacy_claude_project(self.project))
        state_path = activation.render_state_path()
        os.makedirs(os.path.dirname(state_path), exist_ok=True)
        with open(state_path, "w", encoding="utf-8") as fh:
            json.dump({"projects": {missing: ["boxa-stale"]}}, fh)

        result = migration.migrate_legacy()

        self.assertEqual(result["status"], "complete")

    def test_crash_after_partial_publication_resumes_from_prepared_manifest(self):
        self._write_project(self.project, {"echo": _server(["/bin/echo"])})
        self._write_claude({self.project: {"mcpServers": {"boxa-echo": {
            "command": "boxa-mcp-run", "args": ["--project", self.project, "echo"],
        }}}})
        with mock.patch.object(activation, "render_claude_activations", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                migration.migrate_legacy()
        with open(migration.migration_path(), encoding="utf-8") as fh:
            self.assertEqual(json.load(fh)["status"], "prepared")

        resumed = migration.migrate_legacy()

        self.assertEqual(resumed["status"], "complete")
        record = next(iter(activation.load_activations()["projects"][self.project].values()))
        self.assertEqual(record["consumers"], ["claude"])
        self.assertEqual(len(load_catalog()["entries"]), 1)


if __name__ == "__main__":
    unittest.main()
