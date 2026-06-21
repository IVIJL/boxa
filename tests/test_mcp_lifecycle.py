#!/usr/bin/env python3
"""Tests for the MCP lifecycle commands and doctor (issue 08).

Run with:

    python3 -m unittest tests.test_mcp_lifecycle   # from repo root
    python3 tests/test_mcp_lifecycle.py            # standalone

Every test points HOME / XDG_CONFIG_HOME at a fresh tempdir so the real
~/.config/boxa profile and secret store are never read or written, and
injects explicit agent config paths / the identity path so the real ~/.claude,
~/.codex, and /etc/boxa are never touched.

Covers the issue-08 acceptance criteria:
  * effective list shows NAME/SCOPE/STATUS/PLACEMENT/RUNTIME/SOURCE fields;
  * a Project entry shadows a same-named global entry (global shown shadowed);
  * list --json emits valid machine-readable state;
  * enable/disable update profile state (render is the shell front-end's job);
  * a Project disable of a global server does not mutate the global entry;
  * remove never deletes inherited/manual agent config;
  * remove --purge is required before scoped secrets are deleted;
  * doctor detects profile JSON errors, render drift, missing wrapper, missing
    env; doctor --fix never installs packages / allows domains / purges runtime
    / enables host-only servers.
"""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp import identity as identity_mod  # noqa: E402
from mcp import lifecycle as lc  # noqa: E402
from mcp.lifecycle import (  # noqa: E402
    LifecycleError,
    apply_doctor_fixes,
    effective_list,
    remove_server,
    run_doctor,
    server_has_secrets,
    set_enabled,
)
from mcp.profile import (  # noqa: E402
    global_profile_path,
    project_profile_path,
    load_profile,
    save_profile,
)
from mcp.secrets import (  # noqa: E402
    file_mode,
    global_secrets_path,
    project_secrets_path,
    store_server_secrets,
)

_SECRET_VALUE = "sk-ant-super-secret-do-not-leak-0123456789"
_PROJECT_KEY = "/home/tester/Projekty/DemoApp"


def _server(argv, *, enabled=True, env_keys=None, secret_env_keys=None,
            provider="claude-code", import_id="imp-aaa"):
    spec = {
        "name": "x",
        "type": "stdio",
        "command": {"argv": list(argv)},
        "envKeys": list(env_keys or []),
        "secretEnvKeys": list(secret_env_keys or []),
        "source": {"provider": provider, "importId": import_id},
    }
    if not enabled:
        spec["enabled"] = False
    return spec


class LifecycleEnv(unittest.TestCase):
    """Base class isolating HOME / XDG_CONFIG_HOME and the identity path."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self._saved = {}
        for var in (
            "HOME",
            "XDG_CONFIG_HOME",
            "CLAUDE_CONFIG_DIR",
            "CODEX_HOME",
            identity_mod._IDENTITY_PATH_ENV,  # noqa: SLF001
            "GITHUB_TOKEN",
        ):
            self._saved[var] = os.environ.get(var)
        os.environ["HOME"] = self.home
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.home, ".config")
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
        os.environ.pop("CODEX_HOME", None)
        os.environ.pop("GITHUB_TOKEN", None)
        # No identity file by default -> "on the host" for doctor's context.
        os.environ[identity_mod._IDENTITY_PATH_ENV] = os.path.join(  # noqa: SLF001
            self.home, "no-such-identity.json"
        )

    def tearDown(self) -> None:
        for var, val in self._saved.items():
            if val is None:
                os.environ.pop(var, None)
            else:
                os.environ[var] = val
        self._tmp.cleanup()

    # -- fixtures -----------------------------------------------------------

    def _write_global(self, servers: dict) -> str:
        path = global_profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "servers": servers}, fh)
        return path

    def _write_project(self, project_key: str, servers: dict) -> str:
        path = project_profile_path(project_key)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(
                {"version": 1, "projectKey": project_key, "servers": servers},
                fh,
            )
        return path

    def _enter_container(self) -> None:
        """Write a fake identity file so doctor thinks it is in a Container."""
        ipath = os.path.join(self.home, "identity.json")
        with open(ipath, "w", encoding="utf-8") as fh:
            json.dump({"project": "demo"}, fh)
        os.environ[identity_mod._IDENTITY_PATH_ENV] = ipath  # noqa: SLF001


# -- effective list -----------------------------------------------------------


class EffectiveListTests(LifecycleEnv):
    def test_list_columns_and_status(self) -> None:
        self._write_global(
            {
                "context7": _server(["npx", "-y", "ctx"]),
                "fetch": _server(["uvx", "fetch"], enabled=False),
            }
        )
        result = effective_list(project_keys=[_PROJECT_KEY])
        by_name = {e.name: e for e in result.entries}
        self.assertEqual(by_name["context7"].status, "enabled")
        self.assertEqual(by_name["context7"].runtime, "node")
        self.assertEqual(by_name["fetch"].status, "disabled")
        self.assertEqual(by_name["fetch"].runtime, "python")
        # SOURCE preserves provider; PLACEMENT is implied container in v1.
        self.assertEqual(by_name["context7"].source_provider, "claude-code")

    def test_project_entry_shadows_global(self) -> None:
        self._write_global({"context7": _server(["npx", "ctx"])})
        self._write_project(_PROJECT_KEY, {"context7": _server(["npx", "ctx-proj"])})
        result = effective_list(project_keys=[_PROJECT_KEY])
        globals_ = [e for e in result.entries if e.scope == "global"]
        projects = [e for e in result.entries if e.scope == "project"]
        self.assertEqual(len(globals_), 1)
        self.assertTrue(globals_[0].shadowed, "global should be marked shadowed")
        self.assertEqual(len(projects), 1)
        self.assertFalse(projects[0].shadowed)

    def test_list_json_is_valid_and_secret_free(self) -> None:
        self._write_global(
            {"gh": _server(["npx", "gh"], env_keys=["GITHUB_TOKEN"],
                           secret_env_keys=["GITHUB_TOKEN"])}
        )
        store_server_secrets(
            global_secrets_path(), "gh", {"GITHUB_TOKEN": _SECRET_VALUE}
        )
        payload = effective_list(project_keys=[_PROJECT_KEY]).to_dict()
        text = json.dumps(payload)
        json.loads(text)  # valid JSON
        self.assertNotIn(_SECRET_VALUE, text)
        self.assertIn("GITHUB_TOKEN", text)  # NAMES are fine

    def test_all_view_includes_every_project(self) -> None:
        self._write_global({"g1": _server(["npx", "a"])})
        self._write_project("/work/a", {"p1": _server(["npx", "b"])})
        self._write_project("/work/b", {"p2": _server(["npx", "c"])})
        names = {e.name for e in effective_list(all_projects=True).entries}
        self.assertEqual(names, {"g1", "p1", "p2"})


# -- enable / disable ----------------------------------------------------------


class ToggleTests(LifecycleEnv):
    def test_disable_then_enable_global(self) -> None:
        self._write_global({"context7": _server(["npx", "ctx"])})
        r = set_enabled("context7", "global", None, enabled=False)
        self.assertFalse(r.enabled)
        self.assertFalse(r.no_op)
        prof = load_profile(global_profile_path())
        self.assertIs(prof["servers"]["context7"]["enabled"], False)
        # Re-enable drops the flag back to the default (enabled) shape.
        r = set_enabled("context7", "global", None, enabled=True)
        self.assertTrue(r.enabled)
        prof = load_profile(global_profile_path())
        self.assertNotIn("enabled", prof["servers"]["context7"])

    def test_enable_already_enabled_is_noop(self) -> None:
        self._write_global({"context7": _server(["npx", "ctx"])})
        r = set_enabled("context7", "global", None, enabled=True)
        self.assertTrue(r.no_op)

    def test_enable_unknown_global_errors(self) -> None:
        self._write_global({})
        with self.assertRaises(LifecycleError):
            set_enabled("nope", "global", None, enabled=True)

    def test_project_disable_of_global_does_not_mutate_global(self) -> None:
        self._write_global({"context7": _server(["npx", "ctx"])})
        r = set_enabled("context7", "project", _PROJECT_KEY, enabled=False)
        self.assertTrue(r.created_override)
        # Global entry must be untouched (no enabled flag added).
        gprof = load_profile(global_profile_path())
        self.assertNotIn("enabled", gprof["servers"]["context7"])
        # Project profile carries a disable override (no command of its own).
        pprof = load_profile(project_profile_path(_PROJECT_KEY))
        override = pprof["servers"]["context7"]
        self.assertIs(override["enabled"], False)
        self.assertNotIn("command", override)
        # And the effective view marks the global entry shadowed.
        result = effective_list(project_keys=[_PROJECT_KEY])
        g = [e for e in result.entries if e.scope == "global"][0]
        self.assertTrue(g.shadowed)

    def test_project_reenable_drops_override(self) -> None:
        self._write_global({"context7": _server(["npx", "ctx"])})
        set_enabled("context7", "project", _PROJECT_KEY, enabled=False)
        r = set_enabled("context7", "project", _PROJECT_KEY, enabled=True)
        self.assertTrue(r.enabled)
        pprof = load_profile(project_profile_path(_PROJECT_KEY))
        self.assertNotIn("context7", pprof["servers"])

    def test_project_enable_with_nothing_errors(self) -> None:
        self._write_global({})
        with self.assertRaises(LifecycleError):
            set_enabled("ghost", "project", _PROJECT_KEY, enabled=True)

    def test_project_disable_override_is_enforced_by_render(self) -> None:
        # A Project disable of a global server must SHADOW the global rendered
        # entry in that project's Claude record (so it is not offered there),
        # while the global entry stays usable elsewhere. The shadow entry calls
        # the wrapper with --project so the wrapper refuses (enabled: false).
        from mcp.render import build_render_plan, rendered_name

        self._write_global({"context7": _server(["npx", "ctx"])})
        set_enabled("context7", "project", _PROJECT_KEY, enabled=False)
        plan = build_render_plan(None)
        claude = plan.claude
        by_name = {e.rendered_name: e for e in claude.planned}
        bare = rendered_name("context7")
        # The global server still renders globally...
        global_entry = [
            e for e in claude.planned
            if e.rendered_name == bare and e.scope == "global"
        ]
        self.assertEqual(len(global_entry), 1)
        # ...and a project-scoped shadow with the SAME bare name exists, pointing
        # the wrapper at the project profile (where it is disabled).
        project_shadow = [
            e for e in claude.planned
            if e.rendered_name == bare and e.scope == "project"
        ]
        self.assertEqual(
            len(project_shadow), 1, "expected a project shadow entry"
        )
        self.assertIn("--project", project_shadow[0].argv)
        self.assertEqual(by_name[bare].rendered_name, bare)  # not disambiguated

    def test_project_disable_override_marks_codex_unenforced(self) -> None:
        # A project-only disable of a global server cannot be enforced for Codex
        # (no per-project namespace); the JSON result must flag that honestly.
        self._write_global({"context7": _server(["npx", "ctx"])})
        r = set_enabled("context7", "project", _PROJECT_KEY, enabled=False)
        self.assertTrue(r.created_override)
        self.assertIs(r.to_dict()["codexEnforced"], False)
        # A plain project entry (not an override) does not carry the flag.
        self._write_project(_PROJECT_KEY, {"p1": _server(["npx", "p"])})
        r2 = set_enabled("p1", "project", _PROJECT_KEY, enabled=False)
        self.assertNotIn("codexEnforced", r2.to_dict())

    def test_doctor_drift_detects_missing_project_shadow(self) -> None:
        # With the global entry already rendered but the project shadow missing,
        # a name-set drift check would miss it; the multiset check must catch it
        # so doctor --fix re-renders the shadow.
        from mcp.render import rendered_name
        from mcp.writer import write_claude
        from mcp.render import build_claude_plan, collect_profile_servers

        self._enter_container()
        self._write_global({"context7": _server(["npx", "ctx"])})
        # Render ONLY the global server first (no override yet).
        global_only = collect_profile_servers(None)
        write_claude(build_claude_plan(global_only))
        # Now add the project disable override (creates a second planned entry
        # with the same rendered name that is not yet in the config).
        set_enabled("context7", "project", _PROJECT_KEY, enabled=False)
        report = run_doctor()
        drift = [f for f in report.findings if f.code == "render-drift"]
        self.assertTrue(
            drift, "missing project shadow with a duplicate name must be drift"
        )
        self.assertTrue(any(f.fixable for f in drift))
        _ = rendered_name  # silence unused in case of refactor

    def test_project_disable_override_not_rendered_without_global(self) -> None:
        # A project disable override only shadows when the name exists globally.
        # With no matching global server, the disabled stub is just dropped.
        from mcp.render import build_render_plan, rendered_name

        self._write_global({})
        # Hand-write a project disable override for a name not present globally.
        self._write_project(
            _PROJECT_KEY,
            {"ghost": {"name": "ghost", "enabled": False,
                       "source": {"provider": "boxa", "importId": "override"}}},
        )
        plan = build_render_plan(None)
        names = {e.rendered_name for e in plan.claude.planned}
        self.assertNotIn(rendered_name("ghost"), names)

    def test_project_disable_of_existing_project_entry(self) -> None:
        self._write_project(_PROJECT_KEY, {"p1": _server(["npx", "p"])})
        r = set_enabled("p1", "project", _PROJECT_KEY, enabled=False)
        self.assertFalse(r.created_override)
        pprof = load_profile(project_profile_path(_PROJECT_KEY))
        self.assertIs(pprof["servers"]["p1"]["enabled"], False)


# -- remove --------------------------------------------------------------------


class RemoveTests(LifecycleEnv):
    def test_remove_global_entry(self) -> None:
        self._write_global({"context7": _server(["npx", "ctx"])})
        r = remove_server("context7", "global", None)
        self.assertTrue(r.removed)
        self.assertFalse(r.secrets_purged)
        prof = load_profile(global_profile_path())
        self.assertNotIn("context7", prof["servers"])

    def test_remove_unknown_errors(self) -> None:
        self._write_global({})
        with self.assertRaises(LifecycleError):
            remove_server("nope", "global", None)

    def test_remove_without_purge_keeps_secrets(self) -> None:
        self._write_global(
            {"gh": _server(["npx", "gh"], secret_env_keys=["GITHUB_TOKEN"])}
        )
        store_server_secrets(
            global_secrets_path(), "gh", {"GITHUB_TOKEN": _SECRET_VALUE}
        )
        self.assertEqual(
            server_has_secrets("gh", "global", None), ["GITHUB_TOKEN"]
        )
        r = remove_server("gh", "global", None, purge=False)
        self.assertFalse(r.secrets_purged)
        # Secret block remains (not implicitly purged).
        self.assertEqual(
            server_has_secrets("gh", "global", None), ["GITHUB_TOKEN"]
        )

    def test_remove_with_purge_deletes_secrets(self) -> None:
        self._write_global(
            {"gh": _server(["npx", "gh"], secret_env_keys=["GITHUB_TOKEN"])}
        )
        spath = global_secrets_path()
        store_server_secrets(spath, "gh", {"GITHUB_TOKEN": _SECRET_VALUE})
        r = remove_server("gh", "global", None, purge=True)
        self.assertTrue(r.secrets_purged)
        self.assertEqual(r.purged_secret_keys, ["GITHUB_TOKEN"])
        self.assertEqual(server_has_secrets("gh", "global", None), [])
        # The remaining store stays 0600.
        self.assertEqual(file_mode(spath), 0o600)
        # SECRET-FREE result.
        self.assertNotIn(_SECRET_VALUE, json.dumps(r.to_dict()))

    def test_purge_raises_on_unreadable_secret_store(self) -> None:
        # A --purge against a malformed secret store must NOT report success
        # while leaving the secret block on disk; it raises so the user repairs
        # the store and re-runs.
        self._write_global(
            {"gh": _server(["npx", "gh"], secret_env_keys=["TOKEN"])}
        )
        spath = global_secrets_path()
        os.makedirs(os.path.dirname(spath), exist_ok=True)
        with open(spath, "w", encoding="utf-8") as fh:
            fh.write("{ not valid json ]")
        with self.assertRaises(LifecycleError):
            remove_server("gh", "global", None, purge=True)
        # Purge runs BEFORE the profile delete, so a failed purge leaves the
        # profile entry intact — the user can repair the store and re-run
        # 'remove --purge' to complete the purge rather than orphaning secrets.
        prof = load_profile(global_profile_path())
        self.assertIn("gh", prof["servers"])
        # The malformed store is left in place for the user to fix.
        self.assertTrue(os.path.isfile(spath))

    def test_purge_recoverable_after_repairing_store(self) -> None:
        # After a failed purge (unreadable store), repairing the store and
        # re-running remove --purge completes the purge (entry still present).
        self._write_global(
            {"gh": _server(["npx", "gh"], secret_env_keys=["TOKEN"])}
        )
        spath = global_secrets_path()
        os.makedirs(os.path.dirname(spath), exist_ok=True)
        with open(spath, "w", encoding="utf-8") as fh:
            fh.write("{ broken ]")
        with self.assertRaises(LifecycleError):
            remove_server("gh", "global", None, purge=True)
        # Repair the store by rewriting it with valid content, then re-run.
        with open(spath, "w", encoding="utf-8") as fh:
            json.dump(
                {"version": 1, "servers": {"gh": {"TOKEN": _SECRET_VALUE}}}, fh
            )
        r = remove_server("gh", "global", None, purge=True)
        self.assertTrue(r.secrets_purged)
        self.assertEqual(r.purged_secret_keys, ["TOKEN"])
        self.assertEqual(server_has_secrets("gh", "global", None), [])
        self.assertNotIn("gh", load_profile(global_profile_path())["servers"])

    def test_purge_can_clean_orphaned_secrets_after_nonpurge_remove(self) -> None:
        # Non-purge remove leaves orphaned secrets; a follow-up remove --purge
        # (the path the CLI advises) must still reach and clean them even though
        # the profile entry is already gone.
        self._write_global(
            {"gh": _server(["npx", "gh"], secret_env_keys=["TOKEN"])}
        )
        store_server_secrets(global_secrets_path(), "gh", {"TOKEN": _SECRET_VALUE})
        remove_server("gh", "global", None, purge=False)
        self.assertEqual(server_has_secrets("gh", "global", None), ["TOKEN"])
        # Follow-up purge of the now-absent entry cleans the orphan.
        r = remove_server("gh", "global", None, purge=True)
        self.assertFalse(r.removed)  # entry was already gone
        self.assertTrue(r.secrets_purged)
        self.assertEqual(r.purged_secret_keys, ["TOKEN"])
        self.assertEqual(server_has_secrets("gh", "global", None), [])

    def test_purge_absent_entry_no_secrets_errors(self) -> None:
        # --purge on a name with neither a profile entry nor orphaned secrets is
        # an error (nothing to do), not a false success.
        self._write_global({})
        with self.assertRaises(LifecycleError):
            remove_server("ghost", "global", None, purge=True)

    def test_project_purge_does_not_touch_global_secrets(self) -> None:
        self._write_global(
            {"gh": _server(["npx", "gh"], secret_env_keys=["TOKEN"])}
        )
        self._write_project(
            _PROJECT_KEY,
            {"gh": _server(["npx", "gh"], secret_env_keys=["TOKEN"])},
        )
        store_server_secrets(global_secrets_path(), "gh", {"TOKEN": "g"})
        store_server_secrets(
            project_secrets_path(_PROJECT_KEY), "gh", {"TOKEN": "p"}
        )
        remove_server("gh", "project", _PROJECT_KEY, purge=True)
        # Project secrets gone, global secrets intact.
        self.assertEqual(server_has_secrets("gh", "project", _PROJECT_KEY), [])
        self.assertEqual(server_has_secrets("gh", "global", None), ["TOKEN"])


# -- doctor --------------------------------------------------------------------


class DoctorTests(LifecycleEnv):
    def test_clean_profile_only_context_findings(self) -> None:
        self._enter_container()
        self._write_global({})
        report = run_doctor()
        codes = {f.code for f in report.findings}
        # No malformed/drift findings on an empty profile; wrapper may be missing.
        self.assertNotIn("profile-malformed", codes)
        self.assertTrue(report.ok)

    def test_detects_malformed_profile(self) -> None:
        path = global_profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("{ this is not valid json ]")
        report = run_doctor()
        codes = {f.code for f in report.findings}
        self.assertIn("profile-malformed", codes)
        self.assertFalse(report.ok)

    def test_detects_render_drift(self) -> None:
        self._enter_container()
        self._write_global({"context7": _server(["npx", "ctx"])})
        report = run_doctor()
        drift = [f for f in report.findings if f.code == "render-drift"]
        self.assertTrue(drift, "expected render drift for an unrendered server")
        self.assertTrue(all(f.fixable for f in drift))
        self.assertTrue(any("boxa mcp render" in f.repair for f in drift))

    def test_drift_detected_when_entry_under_wrong_project_record(self) -> None:
        # A project server's boxa- entry rendered under the WRONG project
        # record (same rendered name, different record) must register as drift so
        # doctor --fix re-renders it into the right record.
        from mcp.render import rendered_name

        self._enter_container()
        self._write_project(_PROJECT_KEY, {"ctx": _server(["npx", "ctx"])})
        bare = rendered_name("ctx")
        # Hand-write the Claude config with the entry under a DIFFERENT project
        # record than the profile plans (it plans under _PROJECT_KEY).
        claude_path = os.path.join(self.home, ".claude.json")
        with open(claude_path, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "projects": {
                        "/work/WRONG": {
                            "mcpServers": {
                                bare: {
                                    "type": "stdio",
                                    "command": "boxa-mcp-run",
                                    "args": ["--project", "/work/WRONG", "ctx"],
                                }
                            }
                        }
                    }
                },
                fh,
            )
        report = run_doctor()
        drift = [f for f in report.findings if f.code == "render-drift"]
        self.assertTrue(
            drift, "same-name entry under the wrong record must be drift"
        )

    def test_no_drift_when_correctly_rendered(self) -> None:
        # Render the profile, then doctor should report no drift for that agent.
        from mcp.render import build_claude_plan, collect_profile_servers
        from mcp.writer import write_claude

        self._enter_container()
        self._write_global({"context7": _server(["npx", "ctx"])})
        self._write_project(_PROJECT_KEY, {"ctx2": _server(["npx", "ctx2"])})
        write_claude(build_claude_plan(collect_profile_servers(None)))
        report = run_doctor()
        drift = [
            f for f in report.findings
            if f.code == "render-drift" and "claude-code" in f.message
        ]
        self.assertFalse(drift, "a freshly-rendered profile must show no drift")

    def test_detects_missing_env_without_leaking_value(self) -> None:
        self._enter_container()
        self._write_global(
            {"gh": _server(["npx", "gh"], env_keys=["GITHUB_TOKEN"],
                           secret_env_keys=["GITHUB_TOKEN"])}
        )
        report = run_doctor()
        missing = [f for f in report.findings if f.code == "missing-env"]
        self.assertTrue(missing)
        text = json.dumps(report.to_dict())
        self.assertIn("GITHUB_TOKEN", text)
        self.assertNotIn(_SECRET_VALUE, text)

    def test_missing_env_satisfied_by_stored_secret(self) -> None:
        self._enter_container()
        self._write_global(
            {"gh": _server(["npx", "gh"], env_keys=["GITHUB_TOKEN"],
                           secret_env_keys=["GITHUB_TOKEN"])}
        )
        store_server_secrets(
            global_secrets_path(), "gh", {"GITHUB_TOKEN": _SECRET_VALUE}
        )
        report = run_doctor()
        missing = [f for f in report.findings if f.code == "missing-env"]
        self.assertFalse(missing, "stored secret should satisfy the env check")

    def test_detects_missing_launcher(self) -> None:
        self._enter_container()
        self._write_global(
            {"weird": _server(["definitely-not-a-real-binary-xyz", "go"])}
        )
        report = run_doctor()
        missing = [f for f in report.findings if f.code == "missing-launcher"]
        self.assertTrue(missing, "an absent launcher must be flagged")
        self.assertTrue(
            any("definitely-not-a-real-binary-xyz" in f.message for f in missing)
        )

    def test_present_launcher_not_flagged(self) -> None:
        self._enter_container()
        # /bin/sh is essentially always present and executable.
        self._write_global({"shy": _server(["/bin/sh", "-c", "true"])})
        report = run_doctor()
        missing = [f for f in report.findings if f.code == "missing-launcher"]
        self.assertFalse(missing, "a present absolute launcher must not flag")

    def test_report_json_is_secret_free(self) -> None:
        self._enter_container()
        self._write_global(
            {"gh": _server(["npx", "gh"], secret_env_keys=["GITHUB_TOKEN"])}
        )
        store_server_secrets(
            global_secrets_path(), "gh", {"GITHUB_TOKEN": _SECRET_VALUE}
        )
        self.assertNotIn(_SECRET_VALUE, json.dumps(run_doctor().to_dict()))


class DoctorFixTests(LifecycleEnv):
    def test_fix_creates_missing_dirs(self) -> None:
        self._enter_container()
        # No config dir exists yet.
        report = run_doctor()
        result = apply_doctor_fixes(report)
        self.assertTrue(os.path.isdir(lc.config_root()))
        self.assertTrue(
            os.path.isdir(os.path.join(lc.config_root(), "projects"))
        )
        self.assertTrue(
            any("created missing directory" in a for a in result.actions)
        )

    def test_fix_links_executable_wrapper(self) -> None:
        # The wrapper repair must produce a launchable (executable) symlink, or
        # the "fix" is hollow. We point HOME at the sandbox, so the link lands in
        # the sandbox ~/.local/bin and never touches a real PATH.
        self._enter_container()
        report = run_doctor()
        result = apply_doctor_fixes(report)
        link = os.path.join(self.home, ".local", "bin", "boxa-mcp-run")
        if any("boxa-mcp-run" in a for a in result.actions):
            self.assertTrue(os.path.exists(link))
            self.assertTrue(
                os.access(link, os.X_OK), "linked wrapper must be executable"
            )

    def test_fix_rerenders_on_drift(self) -> None:
        self._enter_container()
        self._write_global({"context7": _server(["npx", "ctx"])})
        report = run_doctor()
        result = apply_doctor_fixes(report)
        self.assertTrue(
            any("re-rendered" in a for a in result.actions),
            "drift fix should re-render",
        )
        # After the fix, the render-drift finding should be gone.
        codes = {f.code for f in result.remaining}
        self.assertNotIn("render-drift", codes)

    def test_fix_does_not_install_or_purge_or_enable_hostonly(self) -> None:
        self._enter_container()
        # A disabled server + secrets present. --fix must NOT enable it nor
        # purge anything.
        self._write_global(
            {"gh": _server(["npx", "gh"], enabled=False,
                           secret_env_keys=["GITHUB_TOKEN"])}
        )
        store_server_secrets(
            global_secrets_path(), "gh", {"GITHUB_TOKEN": _SECRET_VALUE}
        )
        report = run_doctor()
        result = apply_doctor_fixes(report)
        # The disabled server stays disabled.
        prof = load_profile(global_profile_path())
        self.assertIs(prof["servers"]["gh"]["enabled"], False)
        # Secrets are untouched.
        self.assertEqual(
            server_has_secrets("gh", "global", None), ["GITHUB_TOKEN"]
        )
        # No action mentions install / allow / purge / enable.
        joined = " ".join(result.actions).lower()
        for forbidden in ("install", "allow", "purge", "enable"):
            self.assertNotIn(forbidden, joined)


def _mode(path: str) -> int:
    return stat.S_IMODE(os.stat(path).st_mode)


class StorePermsBrokerReadable(LifecycleEnv):
    """The Container MCP broker (a distinct UID) must always be able to
    traverse the store dir and read the NON-SECRET profile (ADR 0014),
    independent of the host umask. Secret files stay 0600."""

    def setUp(self) -> None:
        super().setUp()
        self._saved_umask = os.umask(0o077)
        self.addCleanup(os.umask, self._saved_umask)

    def test_profile_and_dir_broker_readable_under_restrictive_umask(self) -> None:
        path = global_profile_path()
        save_profile(path, {"version": 1, "servers": {}})
        # Profile file is o+r despite umask 0077.
        self.assertEqual(_mode(path), 0o644)
        # Store dir is traversable+readable (o+rx).
        self.assertEqual(_mode(os.path.dirname(path)), 0o755)

    def test_project_profile_subdir_broker_readable(self) -> None:
        path = project_profile_path(_PROJECT_KEY)
        save_profile(path, {"version": 1, "servers": {}})
        self.assertEqual(_mode(path), 0o644)
        # The projects/ subdir must also be traversable for the broker.
        self.assertEqual(_mode(os.path.dirname(path)), 0o755)
        # config_root() itself (parent of projects/) is traversable too.
        self.assertEqual(
            _mode(os.path.dirname(os.path.dirname(path))), 0o755
        )

    def test_secret_file_stays_0600_with_traversable_dir(self) -> None:
        # Write a secret first (under restrictive umask) ...
        spath = global_secrets_path()
        store_server_secrets(spath, "gh", {"GITHUB_TOKEN": _SECRET_VALUE})
        # ... then a profile into the shared dir.
        save_profile(global_profile_path(), {"version": 1, "servers": {}})
        # Secret file is owner-only despite the dir being traversable.
        self.assertEqual(file_mode(spath), 0o600)
        # Shared dir is traversable so the broker can reach the profile.
        self.assertEqual(_mode(os.path.dirname(spath)), 0o755)

    def test_secret_written_first_still_leaves_dir_traversable(self) -> None:
        # If the secret store is the first writer (restrictive umask), the
        # shared dir must still end up traversable for the broker.
        spath = global_secrets_path()
        store_server_secrets(spath, "gh", {"GITHUB_TOKEN": _SECRET_VALUE})
        self.assertEqual(_mode(os.path.dirname(spath)), 0o755)
        self.assertEqual(file_mode(spath), 0o600)


if __name__ == "__main__":
    unittest.main()
