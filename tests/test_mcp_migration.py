"""ADR 0028: state-driven cleanup of retired shared MCP artifacts."""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import activation, cli, migration  # noqa: E402
from mcp.catalog import load_catalog  # noqa: E402
from mcp.profile import (  # noqa: E402
    global_profile_path,
    load_profile,
    project_profile_path,
    save_profile,
)
from mcp.secrets import (  # noqa: E402
    global_secrets_path,
    load_secrets,
    project_secrets_path,
    save_secrets,
)


def _server(argv):
    return {
        "name": "ignored",
        "type": "stdio",
        "command": {"argv": list(argv)},
        "envKeys": [],
        "secretEnvKeys": [],
        "enabled": True,
        "source": {"provider": "legacy", "importId": "imp-old"},
    }


class MigrationCleanupTest(unittest.TestCase):
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
        subprocess.run(["git", "-C", self.project, "init", "-q"], check=True)

    def _restore(self):
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _write(self, relative, text):
        path = os.path.join(self.project, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        return path

    @staticmethod
    def _bytes(path):
        with open(path, "rb") as fh:
            return fh.read()

    def _seed_artifacts(self):
        state_path = migration.render_state_path()
        os.makedirs(os.path.dirname(state_path), exist_ok=True)
        with open(state_path, "w", encoding="utf-8") as fh:
            json.dump({
                "projects": {
                    self.project: {
                        "boxa-echo": {"command": "boxa-mcp-run"},
                    }
                },
                "seeded": {self.project: ["boxa-echo"]},
            }, fh)
        mcp = self._write(
            ".mcp.json",
            '{\n  "before": "KEEP-A",\n  "mcpServers": {\n'
            '    "boxa-echo": {"command":"boxa-mcp-run"},\n'
            '    "manual": { "command" : "KEEP-MANUAL" }\n'
            '  },\n  "after": "KEEP-B"\n}\n',
        )
        settings = self._write(
            ".claude/settings.local.json",
            '{\n  "theme": { "exact" : true },\n'
            '  "enabledMcpjsonServers": ["manual","boxa-echo"],\n'
            '  "disabledMcpjsonServers": ["foreign"]\n}\n',
        )
        codex = self._write(
            ".codex/config.toml",
            'model = "KEEP"\n\n# >>> boxa managed MCP servers >>>\n'
            '[mcp_servers.boxa-echo]\ncommand = "boxa-mcp-run"\n'
            '# <<< boxa managed MCP servers <<<\n\n[manual]\nvalue = "KEEP"\n',
        )
        exclude = os.path.join(self.project, ".git", "info", "exclude")
        with open(exclude, "w", encoding="utf-8") as fh:
            fh.write("# KEEP\n/.mcp.json\n/.claude/settings.local.json\n/.codex/config.toml\n/manual\n")
        return mcp, settings, codex, exclude

    def test_cleanup_all_four_artifacts_preserves_foreign_content_and_is_idempotent(self):
        mcp, settings, codex, exclude = self._seed_artifacts()
        result = migration.migrate_legacy()
        self.assertTrue(result["changed"])

        with open(mcp, encoding="utf-8") as fh:
            mcp_text = fh.read()
        self.assertNotIn("boxa-echo", mcp_text)
        self.assertIn('"manual": { "command" : "KEEP-MANUAL" }', mcp_text)
        self.assertIn('"before": "KEEP-A"', mcp_text)
        self.assertIn('"after": "KEEP-B"', mcp_text)

        with open(settings, encoding="utf-8") as fh:
            settings_text = fh.read()
        self.assertNotIn("boxa-echo", settings_text)
        self.assertIn('"theme": { "exact" : true }', settings_text)
        self.assertIn('"manual"', settings_text)
        self.assertIn('"foreign"', settings_text)

        with open(codex, encoding="utf-8") as fh:
            codex_text = fh.read()
        self.assertEqual(codex_text, 'model = "KEEP"\n\n[manual]\nvalue = "KEEP"\n')
        with open(exclude, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "# KEEP\n/manual\n")
        self.assertFalse(os.path.exists(migration.render_state_path()))

        before = {path: self._bytes(path) for path in (mcp, settings, codex, exclude)}
        second = migration.migrate_legacy()
        self.assertFalse(second["changed"])
        after = {path: self._bytes(path) for path in before}
        self.assertEqual(after, before)

    def test_tracked_claude_cleanup_refuses_and_names_file(self):
        mcp, settings, codex, exclude = self._seed_artifacts()
        subprocess.run(["git", "-C", self.project, "add", "-f", ".mcp.json"], check=True)
        with self.assertRaises(migration.MigrationError) as refused:
            migration.migrate_legacy()
        self.assertIn(mcp, str(refused.exception))
        self.assertIn("--allow-tracked-mcp-json", str(refused.exception))
        self.assertTrue(os.path.exists(migration.render_state_path()))
        self.assertFalse(os.path.exists(migration.cleanup_marker_path()))

        migration.migrate_legacy(allow_tracked_mcp_json=True)
        with open(mcp, encoding="utf-8") as fh:
            self.assertNotIn("boxa-echo", fh.read())
        self.assertTrue(os.path.exists(settings))
        self.assertTrue(os.path.exists(codex))
        self.assertTrue(os.path.exists(exclude))

    def test_cleanup_preserves_changed_mcp_entry_and_its_approval_seeds(self):
        mcp, settings, _codex, _exclude = self._seed_artifacts()
        self._write(
            ".mcp.json",
            '{"mcpServers":{"boxa-echo":{"command":"user-owned"}}}\n',
        )
        self._write(
            ".claude/settings.local.json",
            '{"enabledMcpjsonServers":["boxa-echo"],'
            '"disabledMcpjsonServers":["boxa-echo"]}\n',
        )

        migration.migrate_legacy()

        with open(mcp, encoding="utf-8") as fh:
            self.assertEqual(
                json.load(fh)["mcpServers"]["boxa-echo"],
                {"command": "user-owned"},
            )
        with open(settings, encoding="utf-8") as fh:
            settings_data = json.load(fh)
        self.assertEqual(settings_data["enabledMcpjsonServers"], ["boxa-echo"])
        self.assertEqual(settings_data["disabledMcpjsonServers"], ["boxa-echo"])

    def test_remove_mcp_members_reports_existing_names_without_definitions(self):
        original = '{"mcpServers":{"untouched":{"command":"manual"}}}\n'

        rendered, removed, existing = migration._remove_mcp_members(original, {})

        self.assertEqual(rendered, original)
        self.assertEqual(removed, set())
        self.assertEqual(existing, {"untouched"})
        self.assertEqual(
            migration._remove_mcp_members("not-json", {}),
            ("not-json", set(), set()),
        )

    def test_cleanup_leaves_malformed_mcp_file_without_owned_definitions(self):
        state_path = migration.render_state_path()
        os.makedirs(os.path.dirname(state_path), exist_ok=True)
        with open(state_path, "w", encoding="utf-8") as fh:
            json.dump({"projects": {self.project: []}, "seeded": {}}, fh)
        mcp = self._write(".mcp.json", '{"mcpServers":')
        before = self._bytes(mcp)

        migration.migrate_legacy()

        self.assertEqual(self._bytes(mcp), before)

    def test_cleanup_leaves_non_object_mcp_file_without_owned_definitions(self):
        state_path = migration.render_state_path()
        os.makedirs(os.path.dirname(state_path), exist_ok=True)
        for foreign in ('[]', 'null', '"servers"'):
            with self.subTest(foreign=foreign):
                with open(state_path, "w", encoding="utf-8") as fh:
                    json.dump({"projects": {self.project: []}, "seeded": {}}, fh)
                with contextlib.suppress(FileNotFoundError):
                    os.remove(migration.cleanup_marker_path())
                mcp = self._write(".mcp.json", foreign)
                before = self._bytes(mcp)

                migration.migrate_legacy()

                self.assertEqual(self._bytes(mcp), before)

    def test_name_only_state_preserves_approval_seed_for_retained_server(self):
        _mcp, settings, _codex, _exclude = self._seed_artifacts()
        with open(migration.render_state_path(), "w", encoding="utf-8") as fh:
            json.dump({
                "projects": {self.project: ["boxa-echo"]},
                "seeded": {self.project: ["boxa-echo"]},
            }, fh)
        self._write(
            ".mcp.json",
            '{"mcpServers":{"boxa-echo":{"command":"user-owned"}}}\n',
        )

        migration.migrate_legacy()

        with open(settings, encoding="utf-8") as fh:
            settings_data = json.load(fh)
        self.assertIn("boxa-echo", settings_data["enabledMcpjsonServers"])

    def test_cleanup_removes_approval_seed_when_mcp_member_is_absent(self):
        _mcp, settings, _codex, _exclude = self._seed_artifacts()
        self._write(".mcp.json", '{"mcpServers":{"manual":{}}}\n')

        migration.migrate_legacy()

        with open(settings, encoding="utf-8") as fh:
            settings_data = json.load(fh)
        self.assertEqual(settings_data["enabledMcpjsonServers"], ["manual"])

    def test_name_only_render_state_requires_durable_ownership_proof(self):
        entry_id = "entry-id"
        entry = {
            "id": entry_id,
            "name": "echo",
            "type": "stdio",
        }
        state = {
            "projects": {self.project: ["boxa-echo"]},
            "seeded": {},
        }
        activations = {
            "projects": {
                self.project: {
                    entry_id: {
                        "catalogId": entry_id,
                        "consumers": ["claude"],
                        "enabled": True,
                    }
                }
            }
        }

        definitions = migration._recorded_mcp_definitions(
            state,
            self.project,
            activations,
            {"entries": {entry_id: entry}},
        )

        self.assertEqual(
            definitions["boxa-echo"]["command"],
            "boxa-mcp-run",
        )
        self.assertEqual(
            migration._recorded_mcp_definitions(
                state, self.project, {"projects": {}}, {"entries": {}}
            ),
            {},
        )

    def test_unavailable_project_defers_cleanup_marker_and_retries(self):
        mcp, _settings, _codex, _exclude = self._seed_artifacts()
        unavailable = self.project + "-unavailable"
        os.rename(self.project, unavailable)
        try:
            migration.migrate_legacy()
            self.assertFalse(os.path.exists(migration.cleanup_marker_path()))
            self.assertTrue(os.path.exists(migration.render_state_path()))
        finally:
            os.rename(unavailable, self.project)

        migration.migrate_legacy()

        self.assertTrue(os.path.exists(migration.cleanup_marker_path()))
        self.assertFalse(os.path.exists(migration.render_state_path()))
        with open(mcp, encoding="utf-8") as fh:
            self.assertNotIn("boxa-echo", fh.read())

    def test_tracked_codex_cleanup_uses_separate_consent(self):
        _mcp, _settings, codex, _exclude = self._seed_artifacts()
        subprocess.run(["git", "-C", self.project, "add", "-f", ".codex/config.toml"], check=True)
        with self.assertRaises(migration.MigrationError) as refused:
            migration.migrate_legacy(allow_tracked_mcp_json=True)
        self.assertIn(codex, str(refused.exception))
        self.assertIn("--allow-tracked-codex-config", str(refused.exception))
        migration.migrate_legacy(
            allow_tracked_mcp_json=True,
            allow_tracked_codex_config=True,
        )
        with open(codex, encoding="utf-8") as fh:
            self.assertNotIn("boxa managed MCP", fh.read())

    def test_legacy_definition_migrates_without_creating_project_artifacts(self):
        save_profile(project_profile_path(self.project), {
            "version": 1,
            "projectKey": self.project,
            "servers": {"legacy": _server(["/bin/cat"])},
        })
        before = set(os.listdir(self.project))
        result = migration.migrate_legacy()
        self.assertTrue(result["changed"])
        self.assertEqual(len(load_catalog()["entries"]), 1)
        self.assertEqual(set(os.listdir(self.project)), before)
        self.assertEqual(activation.load_activations()["projects"], {})

    def test_stale_codex_placeholder_file_does_not_break_migration(self):
        # A zero-byte `.codex` plain file (leftover bind-mount placeholder)
        # makes `.codex/config.toml` raise ENOTDIR; migration must treat it
        # as "nothing rendered there" instead of failing.
        with open(os.path.join(self.project, ".codex"), "w", encoding="utf-8"):
            pass
        save_profile(project_profile_path(self.project), {
            "version": 1,
            "projectKey": self.project,
            "servers": {"legacy": _server(["/bin/cat"])},
        })
        result = migration.migrate_legacy()
        self.assertTrue(result["changed"])
        self.assertEqual(len(load_catalog()["entries"]), 1)

    def test_complete_migration_purges_profile_and_is_idempotent(self):
        path = global_profile_path()
        save_profile(path, {
            "version": 1,
            "servers": {"legacy": _server(["/bin/cat"])},
        })

        first = migration.migrate_legacy()

        self.assertFalse(first["legacyRetained"])
        self.assertTrue(first["legacyPurged"])
        self.assertFalse(os.path.exists(path))
        manifest_before = self._bytes(migration.migration_path())

        second = migration.migrate_legacy()

        self.assertFalse(second["changed"])
        self.assertEqual(self._bytes(migration.migration_path()), manifest_before)

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli.main(["migrate-text"])
        self.assertEqual(rc, 0)
        self.assertIn("Migrated legacy entries were purged", stdout.getvalue())
        self.assertIn("Next: boxa mcp status", stdout.getvalue())

    def test_modified_migrated_entry_survives_purge(self):
        path = global_profile_path()
        save_profile(path, {
            "version": 1,
            "servers": {"legacy": _server(["/bin/cat"])},
        })
        with mock.patch.object(
            migration,
            "_purge_migrated_legacy",
            side_effect=lambda manifest, catalog: (manifest, False),
        ):
            migration.migrate_legacy()
        save_profile(path, {
            "version": 1,
            "servers": {"legacy": _server(["/bin/echo"])},
        })

        result = migration.migrate_legacy()

        self.assertTrue(result["legacyRetained"])
        self.assertEqual(
            load_profile(path)["servers"]["legacy"]["command"]["argv"],
            ["/bin/echo"],
        )
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli._cmd_catalog_effective_list(
                ["--project", self.project], as_json=False
            )
        self.assertEqual(rc, 0)
        self.assertIn("superseded by the catalog", stdout.getvalue())
        self.assertIn("legacy", stdout.getvalue())

    def test_old_manifest_without_fingerprint_keeps_legacy_entry(self):
        path = global_profile_path()
        save_profile(path, {
            "version": 1,
            "servers": {"legacy": _server(["/bin/cat"])},
        })
        with mock.patch.object(
            migration,
            "_purge_migrated_legacy",
            side_effect=lambda manifest, catalog: (manifest, False),
        ):
            migration.migrate_legacy()
        manifest_path = migration.migration_path()
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
        for row in manifest["definitions"]:
            row.pop("legacyFingerprint", None)
        activation._atomic_json(manifest_path, manifest, 0o600)

        first = migration.migrate_legacy()
        manifest_after = self._bytes(manifest_path)
        second = migration.migrate_legacy()

        self.assertTrue(first["legacyRetained"])
        self.assertTrue(os.path.exists(path))
        self.assertFalse(second["changed"])
        self.assertEqual(self._bytes(manifest_path), manifest_after)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli.main(["migrate-text"])
        self.assertEqual(rc, 0)
        self.assertIn("without matching migration proof were retained", stdout.getvalue())

    def test_complete_manifest_purges_only_recorded_profile_entries(self):
        path = global_profile_path()
        save_profile(path, {
            "version": 1,
            "servers": {"migrated": _server(["/bin/cat"])},
        })
        first = migration.migrate_legacy()
        self.assertFalse(os.path.exists(path))

        save_profile(path, {
            "version": 1,
            "servers": {"later-added": _server(["/bin/echo"])},
        })
        manifest_path = migration.migration_path()
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
        manifest["legacyRetained"] = True
        manifest.pop("legacyPurged", None)
        activation._atomic_json(manifest_path, manifest, 0o600)

        rerun = migration.migrate_legacy()

        self.assertTrue(rerun["changed"])
        self.assertEqual(
            set(load_profile(path)["servers"]),
            {"later-added"},
        )
        self.assertEqual(first["definitions"], rerun["definitions"])

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            rc = cli._cmd_catalog_effective_list(
                ["--project", self.project], as_json=False
            )
        self.assertEqual(rc, 0)
        self.assertIn("superseded by the catalog", stdout.getvalue())
        self.assertIn("later-added", stdout.getvalue())
        self.assertNotIn("issue 08", stdout.getvalue())

    def test_purge_moves_migrated_secrets_and_preserves_later_blocks(self):
        cases = (
            (
                "global",
                "",
                global_profile_path(),
                global_secrets_path(),
            ),
            (
                "project",
                self.project,
                project_profile_path(self.project),
                project_secrets_path(self.project),
            ),
        )
        for scope, project, profile_path, secret_path in cases:
            with self.subTest(scope=scope):
                server = _server(["/bin/cat"])
                server["secretEnvKeys"] = ["TOKEN"]
                profile = {"version": 1, "servers": {"legacy": server}}
                if project:
                    profile["projectKey"] = project
                save_profile(profile_path, profile)
                save_secrets(secret_path, {
                    "version": 1,
                    "servers": {
                        "legacy": {"TOKEN": "secret"},
                        "later-added": {"TOKEN": "keep"},
                    },
                })

                result = migration.migrate_legacy()
                entry_id = result["definitions"][0]["catalogId"]
                store = load_secrets(secret_path)

                self.assertNotIn("legacy", store["servers"])
                self.assertEqual(store["servers"][entry_id], {"TOKEN": "secret"})
                self.assertEqual(
                    store["servers"]["later-added"], {"TOKEN": "keep"}
                )

                # Reset isolated state before the second subtest.
                for path in (
                    migration.migration_path(),
                    migration.cleanup_marker_path(),
                    migration.render_state_path(),
                    migration.legacy_render_state_path(),
                ):
                    with contextlib.suppress(FileNotFoundError):
                        os.remove(path)
                mcp_root = os.path.dirname(migration.migration_path())
                for name in ("catalog.json", "activations.json"):
                    with contextlib.suppress(FileNotFoundError):
                        os.remove(os.path.join(mcp_root, name))

    def test_purge_deletes_empty_project_secret_file(self):
        profile_path = project_profile_path(self.project)
        secret_path = project_secrets_path(self.project)
        server = _server(["/bin/cat"])
        save_profile(profile_path, {
            "version": 1,
            "projectKey": self.project,
            "servers": {"legacy": server},
        })
        save_secrets(secret_path, {
            "version": 1,
            "servers": {"legacy": {}},
        })

        migration.migrate_legacy()

        self.assertFalse(os.path.exists(profile_path))
        self.assertFalse(os.path.exists(secret_path))

    def test_missing_profile_still_purges_matching_secret_block(self):
        profile_path = global_profile_path()
        secret_path = global_secrets_path()
        server = _server(["/bin/cat"])
        server["secretEnvKeys"] = ["TOKEN"]
        save_profile(profile_path, {
            "version": 1,
            "servers": {"legacy": server},
        })
        save_secrets(secret_path, {
            "version": 1,
            "servers": {"legacy": {"TOKEN": "secret"}},
        })
        with mock.patch.object(
            migration,
            "_purge_migrated_legacy",
            side_effect=lambda manifest, catalog: (manifest, False),
        ):
            migration.migrate_legacy()
        os.remove(profile_path)

        result = migration.migrate_legacy()
        entry_id = result["definitions"][0]["catalogId"]

        self.assertFalse(result["legacyRetained"])
        self.assertNotIn("legacy", load_secrets(secret_path)["servers"])
        self.assertEqual(
            load_secrets(secret_path)["servers"][entry_id], {"TOKEN": "secret"}
        )

    def test_missing_profile_member_still_purges_matching_secret_block(self):
        profile_path = global_profile_path()
        secret_path = global_secrets_path()
        server = _server(["/bin/cat"])
        server["secretEnvKeys"] = ["TOKEN"]
        save_profile(profile_path, {
            "version": 1,
            "servers": {"legacy": server},
        })
        save_secrets(secret_path, {
            "version": 1,
            "servers": {"legacy": {"TOKEN": "secret"}},
        })
        with mock.patch.object(
            migration,
            "_purge_migrated_legacy",
            side_effect=lambda manifest, catalog: (manifest, False),
        ):
            migration.migrate_legacy()
        save_profile(profile_path, {"version": 1, "servers": {}})

        result = migration.migrate_legacy()
        entry_id = result["definitions"][0]["catalogId"]

        self.assertFalse(result["legacyRetained"])
        self.assertNotIn("legacy", load_secrets(secret_path)["servers"])
        self.assertEqual(
            load_secrets(secret_path)["servers"][entry_id], {"TOKEN": "secret"}
        )


class ReadTextTargetTests(unittest.TestCase):
    def test_plain_file_path_component_reads_as_missing_target(self):
        # A stale zero-byte `.codex` bind-mount placeholder file makes
        # `.codex/config.toml` raise ENOTDIR; that means "no legacy config
        # here", not a migration failure.
        with tempfile.TemporaryDirectory() as tmp:
            placeholder = os.path.join(tmp, ".codex")
            with open(placeholder, "w", encoding="utf-8"):
                pass
            self.assertIsNone(
                migration._read_text(os.path.join(placeholder, "config.toml"))
            )


if __name__ == "__main__":
    unittest.main()
