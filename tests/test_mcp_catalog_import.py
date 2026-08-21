"""ADR 0021 issue 08: inherited import is definition-only."""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import cli  # noqa: E402
from mcp.activation import (  # noqa: E402
    activate,
    activation_path,
    load_activations,
    runtime_path,
)
from mcp.apply import ScopeOverride  # noqa: E402
from mcp.migration import render_state_path  # noqa: E402
from mcp.catalog import load_catalog, save_catalog, update_entry  # noqa: E402
from mcp.catalog_import import (  # noqa: E402
    CatalogImportConflictError,
    catalog_verdicts,
    import_definitions,
)
from mcp.candidate import Candidate, Classification, Command  # noqa: E402
from mcp.merge import merge_candidates  # noqa: E402
from mcp.providers.claude import render_target_path  # noqa: E402
from mcp.readiness import ProjectProbe, readiness  # noqa: E402
from mcp.source_values import read_secret_values  # noqa: E402
from mcp.secrets import (  # noqa: E402
    global_secrets_path,
    project_secrets_path,
    read_header_secrets,
    read_server_secrets,
)


def _candidate(name, argv, *, scope="global", project=None):
    return Candidate(
        provider="fixture",
        source_path="/does/not/exist",
        source_scope=scope,
        source_project=project,
        name=name,
        type="stdio",
        command=Command(argv=list(argv)),
        classification=Classification(placement="container", confidence="high"),
    )


def _remote_candidate(name, url, *, headers=None, secret_header_keys=None):
    return Candidate(
        provider="fixture",
        source_path="/does/not/exist",
        source_scope="global",
        name=name,
        type="http",
        url=url,
        headers=dict(headers or {}),
        secret_header_keys=list(secret_header_keys or []),
        classification=Classification(placement="container", confidence="high"),
    )


class CatalogImportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = {
            key: os.environ.get(key)
            for key in ("HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR")
        }
        self.addCleanup(self._restore)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")
        os.environ.pop("CLAUDE_CONFIG_DIR", None)

    def _restore(self):
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_import_writes_catalog_only_and_never_infers_trust(self):
        claude = render_target_path()
        os.makedirs(os.path.dirname(claude), exist_ok=True)
        manual = {"projects": {"/p": {"mcpServers": {"manual": {"command": "keep"}}}}}
        with open(claude, "w", encoding="utf-8") as fh:
            json.dump(manual, fh)

        result = import_definitions(merge_candidates([_candidate("echo", ["/bin/echo"])]))

        self.assertTrue(result.to_dict()["definitionOnly"])
        entry = next(iter(load_catalog()["entries"].values()))
        self.assertEqual(entry["executionMode"], "service-isolated")
        for path in (activation_path(), runtime_path(), render_state_path()):
            self.assertFalse(os.path.exists(path))
        with open(claude, encoding="utf-8") as fh:
            self.assertEqual(json.load(fh), manual)

    def test_remote_import_round_trips_header_declarations(self):
        candidate = _remote_candidate(
            "remote",
            "https://example.test/mcp",
            headers={"X-Tenant": "engineering"},
            secret_header_keys=["Authorization"],
        )
        import_definitions(merge_candidates([candidate]))
        entry = next(iter(load_catalog()["entries"].values()))
        self.assertEqual(entry["headers"], {"X-Tenant": "engineering"})
        self.assertEqual(entry["secretHeaderKeys"], ["Authorization"])
        with open(os.path.join(os.environ["XDG_CONFIG_HOME"], "boxa", "mcp", "catalog.json"), encoding="utf-8") as fh:
            raw = fh.read()
        self.assertNotIn("Bearer ", raw)

    def test_repeat_is_idempotent_and_deduplicates_across_source_scope(self):
        candidates = merge_candidates([
            _candidate("echo", ["/bin/echo"]),
            _candidate("echo", ["/bin/echo"], scope="project", project="/p"),
        ])
        first = import_definitions(candidates)
        second = import_definitions(candidates)
        self.assertEqual(len(load_catalog()["entries"]), 1)
        self.assertTrue(any(item.changed for item in first.imported))
        self.assertTrue(all(not item.changed for item in second.imported))

    def test_http_import_writes_url_without_local_runtime_fields(self):
        import_definitions(
            merge_candidates(
                [_remote_candidate("dozzle", "https://dozzle.example.test/mcp")]
            )
        )
        entry = next(iter(load_catalog()["entries"].values()))
        self.assertEqual(entry["type"], "http")
        self.assertEqual(entry["url"], "https://dozzle.example.test/mcp")
        self.assertNotIn("command", entry)
        self.assertNotIn("executionMode", entry)

    def test_empty_container_fields_do_not_report_catalog_changes(self):
        cases = (
            (
                _remote_candidate("headers", "https://example.test/mcp"),
                "headers", None,
            ),
            (
                _remote_candidate(
                    "secret-headers", "https://other.example.test/mcp"
                ),
                "secretHeaderKeys", None,
            ),
            (_candidate("env", ["npx", "tool"]), "env", {}),
        )
        for candidate, field, stored_value in cases:
            with self.subTest(field=field):
                imported = import_definitions(merge_candidates([candidate]))
                entry_id = imported.imported[0].catalog_id
                catalog = load_catalog()
                if stored_value is None:
                    catalog["entries"][entry_id].pop(field, None)
                else:
                    catalog["entries"][entry_id][field] = stored_value
                save_catalog(catalog)
                before = load_catalog()

                verdict = catalog_verdicts(merge_candidates([candidate]))[0]

                self.assertEqual(verdict.catalog_status, "in-sync")
                self.assertEqual(verdict.catalog_diff, [])
                result = import_definitions([verdict])
                self.assertFalse(result.imported[0].changed)
                self.assertEqual(load_catalog(), before)

    def test_missing_headers_with_secret_change_reports_only_secret_values(self):
        secret_one = "Bearer initial-value"
        secret_two = "Bearer changed-value"
        path = self._write_source("remote", {
            "type": "http",
            "url": "https://example.test/mcp",
            "headers": {"Authorization": secret_one},
        })
        candidate = _remote_candidate(
            "remote", "https://example.test/mcp",
            secret_header_keys=["Authorization"],
        )
        candidate.provider = "claude-code"
        candidate.source_path = path
        imported = import_definitions(
            merge_candidates([candidate]), secret_consent=lambda *_args: True
        )
        entry_id = imported.imported[0].catalog_id
        catalog = load_catalog()
        catalog["entries"][entry_id].pop("headers")
        save_catalog(catalog)
        self._write_source("remote", {
            "type": "http",
            "url": "https://example.test/mcp",
            "headers": {"Authorization": secret_two},
        })

        verdict = catalog_verdicts(merge_candidates([candidate]))[0]

        self.assertEqual(verdict.catalog_status, "changed")
        self.assertEqual(
            verdict.catalog_diff,
            [{
                "field": "secretValues",
                "catalog": "stored values",
                "candidate": "host values differ",
                "keys": ["Authorization"],
            }],
        )
        serialized = json.dumps(verdict.to_dict())
        self.assertNotIn(secret_one, serialized)
        self.assertNotIn(secret_two, serialized)

    def test_same_scope_name_conflict_is_refused_before_write(self):
        selected = merge_candidates([
            _candidate("dup", ["npx", "one"]),
            _candidate("dup", ["uvx", "two"]),
        ])
        with self.assertRaises(CatalogImportConflictError):
            import_definitions(selected)
        self.assertEqual(load_catalog()["entries"], {})

    def test_discovery_marks_identical_definition_already_cataloged(self):
        original = merge_candidates([_candidate("original", ["/bin/echo"])])
        imported = import_definitions(original).imported[0]

        rediscovered = catalog_verdicts(
            merge_candidates([_candidate("alias", ["/bin/echo"])])
        )[0]

        self.assertEqual(rediscovered.catalog_status, "already-cataloged")
        self.assertEqual(rediscovered.catalog_id, imported.catalog_id)
        self.assertTrue(rediscovered.to_dict()["alreadyCataloged"])

    def test_same_import_identity_is_reimported_with_host_definition(self):
        original = import_definitions(
            merge_candidates([_candidate("tool", ["/bin/echo", "old"])])
        ).imported[0]
        conflicting = catalog_verdicts(
            merge_candidates([_candidate("tool", ["/bin/echo", "new"])])
        )[0]
        self.assertEqual(conflicting.catalog_status, "changed")
        self.assertEqual(conflicting.catalog_id, original.catalog_id)
        self.assertEqual(conflicting.catalog_diff[0]["field"], "command")

        updated = import_definitions([conflicting])
        self.assertEqual(updated.imported[0].catalog_id, original.catalog_id)
        entry = load_catalog()["entries"][original.catalog_id]
        self.assertEqual(entry["command"]["argv"], ["/bin/echo", "new"])

    def test_host_only_candidate_requires_explicit_force(self):
        candidate = merge_candidates([_candidate("desktop", ["npx", "desktop-mcp"])])[0]
        candidate.candidate.classification = Classification(
            placement="host-only",
            confidence="high",
            reasons=["needs host desktop"],
        )

        skipped = import_definitions([candidate])
        self.assertEqual(skipped.imported, [])
        self.assertIn("host-only", skipped.skipped[0]["reason"])

        imported = import_definitions([candidate], force_host_only=True)
        self.assertEqual(len(imported.imported), 1)

    def _write_source(self, name, spec):
        path = os.path.join(self.tmp.name, ".claude.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"mcpServers": {name: spec}, "projects": {}}, fh)
        return path

    def _write_project_source(self, project, name, spec):
        path = os.path.join(self.tmp.name, ".claude.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({
                "mcpServers": {},
                "projects": {
                    project: {"mcpServers": {name: spec}},
                },
            }, fh)
        return path

    def _consenting_cli_apply(
        self, candidate, projects, *, override=None, all_projects=False
    ):
        merged = merge_candidates([candidate])
        selection = cli._Selection()
        selection.scope.project_keys = list(projects)
        selection.scope.all_projects = all_projects
        selection.import_ids = [merged[0].import_id]
        if override is not None:
            selection.overrides[merged[0].import_id] = override
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), \
                mock.patch.object(
                    cli, "_controlling_terminal_usable", return_value=True
                ), \
                mock.patch.object(cli, "_secret_consent", return_value=True):
            self.assertEqual(cli._render_apply_text(merged, selection), 0)
        for value in read_secret_values(candidate).values():
            self.assertNotIn(value, stdout.getvalue())
        return load_catalog()["entries"]

    def test_http_secret_takeover_rotation_and_renamed_reimport(self):
        secret_one = "Bearer takeover-value-one"
        secret_two = "Bearer takeover-value-two"
        path = self._write_source("remote", {
            "type": "http",
            "url": "https://example.test/mcp",
            "headers": {"Authorization": secret_one, "X-Tenant": "one"},
        })
        candidate = _remote_candidate(
            "remote", "https://example.test/mcp",
            headers={"X-Tenant": "one"},
            secret_header_keys=["Authorization"],
        )
        candidate.provider = "claude-code"
        candidate.source_path = path
        merged = merge_candidates([candidate])
        imported = import_definitions(
            merged, secret_consent=lambda *_args: True
        ).imported[0]
        self.assertEqual(
            read_header_secrets(global_secrets_path(), imported.catalog_id),
            {"authorization": secret_one},
        )
        self.assertTrue(readiness(imported.catalog_id, "/project").ready)
        self.assertEqual(catalog_verdicts(merge_candidates([candidate]))[0].catalog_status, "in-sync")

        update_entry(imported.catalog_id, name="catalog-renamed")
        activate(imported.catalog_id, "/project", ["claude"])
        self._write_source("remote", {
            "type": "http",
            "url": "https://changed.example.test/mcp",
            "headers": {"Authorization": secret_two, "X-Tenant": "two"},
        })
        candidate.url = "https://changed.example.test/mcp"
        candidate.headers = {"X-Tenant": "two"}
        changed = catalog_verdicts(merge_candidates([candidate]))[0]
        self.assertEqual(changed.catalog_status, "changed")
        self.assertEqual(changed.catalog_name, "catalog-renamed")
        declined = import_definitions([changed], secret_consent=lambda *_args: False)
        self.assertEqual(declined.skipped_secrets[0]["keys"], ["Authorization"])
        self.assertEqual(
            read_header_secrets(global_secrets_path(), imported.catalog_id),
            {"authorization": secret_one},
        )
        rotated = import_definitions([changed], secret_consent=lambda *_args: True)
        self.assertTrue(rotated.imported[0].changed)
        self.assertEqual(
            read_header_secrets(global_secrets_path(), imported.catalog_id),
            {"authorization": secret_two},
        )
        self.assertEqual(
            load_activations()["projects"]["/project"][imported.catalog_id]["consumers"],
            ["claude"],
        )
        with open(
            os.path.join(os.environ["XDG_CONFIG_HOME"], "boxa", "mcp", "catalog.json"),
            encoding="utf-8",
        ) as fh:
            catalog_raw = fh.read()
        self.assertNotIn(secret_one, catalog_raw)
        self.assertNotIn(secret_two, catalog_raw)
        with open(path, encoding="utf-8") as fh:
            self.assertEqual(
                json.load(fh)["mcpServers"]["remote"]["headers"]["Authorization"],
                secret_two,
            )

    def test_stdio_mapping_detection_secret_consent_and_boxa_state(self):
        secret = "sk-test-secret-value-never-output"
        path = self._write_source("tool", {
            "command": "npx",
            "args": ["old"],
            "env": {"API_KEY": secret, "LOG_LEVEL": "info"},
        })
        candidate = _candidate("tool", ["npx", "old"])
        candidate.provider = "claude-code"
        candidate.source_path = path
        candidate.command = Command(
            argv=["npx", "old"],
            env_keys=["API_KEY", "LOG_LEVEL"],
            secret_env_keys=["API_KEY"],
        )
        imported = import_definitions(
            merge_candidates([candidate]), secret_consent=lambda *_args: True
        ).imported[0]
        self.assertEqual(
            read_server_secrets(global_secrets_path(), "tool"),
            {"API_KEY": secret},
        )
        catalog = load_catalog()
        catalog["entries"][imported.catalog_id]["description"] = "keep me"
        save_catalog(catalog)

        self._write_source("tool", {
            "command": "uvx",
            "args": ["new"],
            "env": {"API_KEY": secret, "LOG_LEVEL": "debug", "REGION": "eu"},
        })
        candidate.command = Command(
            argv=["uvx", "new"],
            env_keys=["API_KEY", "LOG_LEVEL", "REGION"],
            secret_env_keys=["API_KEY"],
        )
        changed = catalog_verdicts(merge_candidates([candidate]))[0]
        self.assertEqual(changed.catalog_status, "changed")
        import_definitions([changed], secret_consent=lambda *_args: True)
        entry = load_catalog()["entries"][imported.catalog_id]
        self.assertEqual(entry["command"]["argv"], ["uvx", "new"])
        self.assertEqual(entry["env"], {"LOG_LEVEL": "debug", "REGION": "eu"})
        self.assertEqual(entry["description"], "keep me")
        self.assertEqual(entry["executionMode"], "service-isolated")
        self.assertEqual(catalog_verdicts(merge_candidates([candidate]))[0].catalog_status, "in-sync")

    def test_global_stdio_takeover_uses_target_project_store(self):
        secret = "project-only-takeover-value"
        project = os.path.join(self.tmp.name, "target-project")
        os.makedirs(project)
        self._write_source("tool", {
            "command": "uvx",
            "args": ["example-tool"],
            "env": {"API_KEY": secret},
        })
        stdout = io.StringIO()
        stderr = io.StringIO()
        read_fd, write_fd = os.pipe()
        os.close(write_fd)
        old_cwd = os.getcwd()
        try:
            os.chdir(project)
            with os.fdopen(read_fd, encoding="utf-8") as piped_stdin, \
                    contextlib.redirect_stdout(stdout), \
                    contextlib.redirect_stderr(stderr), \
                    mock.patch.object(cli.sys, "stdin", piped_stdin), \
                    mock.patch.object(
                        cli, "_controlling_terminal_usable", return_value=True
                    ), mock.patch.object(
                        cli, "_secret_consent", return_value=True
                    ) as consent:
                self.assertFalse(piped_stdin.isatty())
                self.assertEqual(
                    cli.main(["apply-text", "--all", "--server", "tool"]), 0
                )
        finally:
            os.chdir(old_cwd)
        self.assertNotIn(secret, stdout.getvalue())
        self.assertNotIn(secret, stderr.getvalue())
        self.assertNotIn("Skipped credential values", stdout.getvalue())
        consent.assert_called_once()
        entries = load_catalog()["entries"]
        self.assertNotIn(secret, json.dumps(entries))
        imported_id = next(iter(entries))

        self.assertEqual(
            read_server_secrets(project_secrets_path(project), "tool"),
            {"API_KEY": secret},
        )
        self.assertIsNone(read_server_secrets(global_secrets_path(), "tool"))
        probe = ProjectProbe()
        probe.find_running = lambda _project: "boxa-target"  # type: ignore[method-assign]
        probe.command_path = (  # type: ignore[method-assign]
            lambda _container, command, _user: f"/usr/bin/{command}"
        )
        self.assertTrue(readiness(imported_id, project, probe).ready)

        discovery_stdout = io.StringIO()
        changed_stdout = io.StringIO()
        rerun_stderr = io.StringIO()
        old_cwd = os.getcwd()
        try:
            os.chdir(project)
            with contextlib.redirect_stdout(discovery_stdout), \
                    contextlib.redirect_stderr(rerun_stderr):
                self.assertEqual(cli.main(["import-text", "--all"]), 0)
            with contextlib.redirect_stdout(changed_stdout), \
                    contextlib.redirect_stderr(rerun_stderr):
                self.assertEqual(cli.main(["apply-json", "--all-changed"]), 0)
        finally:
            os.chdir(old_cwd)
        self.assertIn(
            "1 entries in sync with host configs.", discovery_stdout.getvalue()
        )
        status_stdout = io.StringIO()
        with contextlib.redirect_stdout(status_stdout):
            self.assertEqual(
                cli._cmd_catalog_effective_list(
                    ["--project", project], as_json=True
                ),
                0,
            )
        status = json.loads(status_stdout.getvalue())
        self.assertEqual(
            status["inheritedCandidates"][0]["catalogStatus"],
            "in-sync",
        )
        self.assertEqual(json.loads(changed_stdout.getvalue())["imported"], [])
        self.assertNotIn(secret, discovery_stdout.getvalue())
        self.assertNotIn(secret, changed_stdout.getvalue())
        self.assertNotIn(secret, status_stdout.getvalue())
        self.assertNotIn(secret, rerun_stderr.getvalue())

    def test_unusable_tty_keeps_secret_takeover_noninteractive(self):
        secret = "unusable-tty-secret-value"
        path = self._write_source("tool", {
            "command": "uvx",
            "env": {"API_KEY": secret},
        })
        candidate = _candidate("tool", ["uvx"])
        candidate.provider = "claude-code"
        candidate.source_path = path
        candidate.command = Command(
            argv=["uvx"],
            env_keys=["API_KEY"],
            secret_env_keys=["API_KEY"],
        )
        merged = merge_candidates([candidate])
        selection = cli._Selection()
        selection.import_ids = [merged[0].import_id]
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), mock.patch.object(
            cli, "_controlling_terminal_usable", return_value=False
        ), mock.patch.object(cli, "_secret_consent") as consent:
            self.assertEqual(cli._render_apply_text(merged, selection), 0)

        self.assertIn("Skipped credential values for tool: API_KEY", stdout.getvalue())
        self.assertIn("Next: boxa mcp secret set", stdout.getvalue())
        self.assertNotIn(secret, stdout.getvalue())
        consent.assert_not_called()
        self.assertIsNone(read_server_secrets(global_secrets_path(), "tool"))
        self.assertNotIn(secret, json.dumps(load_catalog()["entries"]))

    def test_json_apply_unconditionally_disables_secret_consent(self):
        secret = "json-disabled-consent-value"
        self._write_source("tool", {
            "command": "uvx",
            "env": {"API_KEY": secret},
        })
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout), mock.patch.object(
            cli, "_controlling_terminal_usable", return_value=True
        ) as tty_probe, mock.patch.object(cli, "_secret_consent") as consent:
            self.assertEqual(
                cli.main(["apply-json", "--all", "--server", "tool"]), 0
            )

        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["skippedSecrets"][0]["keys"], ["API_KEY"])
        self.assertNotIn(secret, stdout.getvalue())
        tty_probe.assert_not_called()
        consent.assert_not_called()
        self.assertIsNone(read_server_secrets(global_secrets_path(), "tool"))
        self.assertNotIn(secret, json.dumps(load_catalog()["entries"]))

    def test_json_import_activate_never_probes_for_secret_consent(self):
        candidate = merge_candidates([_candidate("tool", ["uvx"])])
        imported = mock.Mock()
        imported.imported = []
        imported.secret_scopes = []
        imported.to_dict.return_value = {"imported": []}
        stdout = io.StringIO()
        with mock.patch.object(
            cli, "_discover", return_value=candidate
        ), mock.patch.object(
            cli, "import_definitions", return_value=imported
        ) as importer, mock.patch.object(
            cli, "_controlling_terminal_usable", return_value=True
        ) as tty_probe, contextlib.redirect_stdout(stdout):
            self.assertEqual(
                cli._cmd_import_activate(
                    [
                        "--target-project", "/project",
                        "--for", "claude",
                        "--server", "tool",
                    ],
                    as_json=True,
                ),
                0,
            )

        self.assertIsNone(importer.call_args.kwargs["secret_consent"])
        tty_probe.assert_not_called()
        self.assertEqual(json.loads(stdout.getvalue())["flow"], [])

    def test_all_applicable_global_stdio_takeover_uses_target_project_store(self):
        secret = "all-applicable-project-only-value"
        project = os.path.join(self.tmp.name, "all-applicable-project")
        os.makedirs(project)
        self._write_source("tool", {
            "command": "uvx",
            "args": ["example-tool"],
            "env": {"API_KEY": secret},
        })
        stdout = io.StringIO()
        stderr = io.StringIO()
        old_cwd = os.getcwd()
        try:
            os.chdir(project)
            with contextlib.redirect_stdout(stdout), \
                    contextlib.redirect_stderr(stderr), \
                    mock.patch.object(
                        cli, "_controlling_terminal_usable", return_value=True
                    ), \
                    mock.patch.object(cli, "_secret_consent", return_value=True):
                self.assertEqual(
                    cli.main(["apply-text", "--all", "--all-applicable"]), 0
                )
        finally:
            os.chdir(old_cwd)
        self.assertNotIn(secret, stdout.getvalue())
        self.assertNotIn(secret, stderr.getvalue())
        self.assertNotIn(secret, json.dumps(load_catalog()["entries"]))
        self.assertEqual(
            read_server_secrets(project_secrets_path(project), "tool"),
            {"API_KEY": secret},
        )
        self.assertIsNone(read_server_secrets(global_secrets_path(), "tool"))

    def test_project_stdio_takeover_uses_only_discovered_project_store(self):
        secret = "single-project-takeover-value"
        project_a = "/projects/a"
        project_b = "/projects/b"
        path = self._write_project_source(project_a, "tool", {
            "command": "/bin/echo",
            "env": {"API_KEY": secret},
        })
        candidate = _candidate(
            "tool", ["/bin/echo"], scope="project", project=project_a
        )
        candidate.provider = "claude-code"
        candidate.source_path = path
        candidate.command = Command(
            argv=["/bin/echo"],
            env_keys=["API_KEY"],
            secret_env_keys=["API_KEY"],
        )

        self._consenting_cli_apply(candidate, [project_a, project_b])

        self.assertEqual(
            read_server_secrets(project_secrets_path(project_a), "tool"),
            {"API_KEY": secret},
        )
        self.assertIsNone(
            read_server_secrets(project_secrets_path(project_b), "tool")
        )
        self.assertEqual(
            catalog_verdicts(merge_candidates([candidate]))[0].catalog_status,
            "in-sync",
        )

    def test_in_sync_legacy_match_persists_import_identity_before_rename(self):
        candidate = _candidate("source-name", ["npx", "tool"])
        imported = import_definitions(merge_candidates([candidate])).imported[0]
        catalog = load_catalog()
        del catalog["entries"][imported.catalog_id]["importIdentity"]
        save_catalog(catalog)

        legacy_match = catalog_verdicts(merge_candidates([candidate]))[0]
        self.assertEqual(legacy_match.catalog_status, "in-sync")
        import_definitions([legacy_match])
        self.assertIn(
            "importIdentity", load_catalog()["entries"][imported.catalog_id]
        )

        update_entry(imported.catalog_id, name="catalog-renamed")
        candidate.command.argv = ["npx", "changed"]
        renamed_match = catalog_verdicts(merge_candidates([candidate]))[0]
        self.assertEqual(renamed_match.catalog_id, imported.catalog_id)
        self.assertEqual(renamed_match.catalog_status, "changed")

    def test_reimport_preserves_renamed_agent_trusted_identity(self):
        candidate = _candidate("source-name", ["npx", "old"])
        imported = import_definitions(merge_candidates([candidate])).imported[0]
        catalog = load_catalog()
        entry = catalog["entries"][imported.catalog_id]
        entry["name"] = "catalog-name"
        entry["description"] = "keep description"
        entry["executionMode"] = "agent-trusted"
        save_catalog(catalog)

        candidate.command.argv = ["npx", "new"]
        changed = catalog_verdicts(merge_candidates([candidate]))[0]
        self.assertEqual(changed.catalog_status, "changed")
        self.assertEqual(changed.catalog_name, "catalog-name")
        import_definitions([changed])
        updated = load_catalog()["entries"][imported.catalog_id]
        self.assertEqual(updated["name"], "catalog-name")
        self.assertEqual(updated["description"], "keep description")
        self.assertEqual(updated["executionMode"], "agent-trusted")


if __name__ == "__main__":
    unittest.main()
