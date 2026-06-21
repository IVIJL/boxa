#!/usr/bin/env python3
"""Tests for the MCP render dry-run preview (issue 06).

Run with:

    python3 -m unittest tests.test_mcp_render   # from repo root
    python3 tests/test_mcp_render.py            # standalone

Every test points HOME and XDG_CONFIG_HOME at a fresh tempdir so the real
~/.config/boxa profile is never read, and injects explicit agent config paths
(temp .claude.json / config.toml fixtures) so the real ~/.claude and ~/.codex
are never read or written.

Covers the issue-06 acceptance criteria:
  * render --dry-run previews planned entries for each enabled profile server;
  * rendered names use the boxa- prefix;
  * rendered commands call the wrapper, not the raw MCP command;
  * preview contains no secret env VALUES (env NAMES only);
  * preview distinguishes boxa-managed from inherited/manual agent entries;
  * a re-render would not rewrite manual/inherited entries (ownership);
  * Claude uses a verified config shape;
  * Codex uses its verified shape, or reports unsupported when no TOML parser;
  * the render preview writes NO agent config file.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp import render as render_mod  # noqa: E402
from mcp.profile import (  # noqa: E402
    global_profile_path,
    project_profile_path,
)
from mcp.render import (  # noqa: E402
    BOXA_PREFIX,
    WRAPPER_COMMAND,
    build_claude_plan,
    build_codex_plan,
    build_render_plan,
    collect_profile_servers,
    is_boxa_managed,
    rendered_name,
)

# A realistic-looking secret VALUE that must NEVER appear in any preview output.
_SECRET_VALUE = "sk-ant-super-secret-do-not-leak-0123456789"
_PROJECT_KEY = "/home/tester/Projekty/DemoApp"


class RenderEnv(unittest.TestCase):
    """Base class isolating HOME / XDG_CONFIG_HOME into a tempdir."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self._saved = {}
        for var in ("HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR"):
            self._saved[var] = os.environ.get(var)
        os.environ["HOME"] = self.home
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.home, ".config")
        # Drop CLAUDE_CONFIG_DIR so nothing reads the real container config dir.
        os.environ.pop("CLAUDE_CONFIG_DIR", None)

    def tearDown(self) -> None:
        for var, val in self._saved.items():
            if val is None:
                os.environ.pop(var, None)
            else:
                os.environ[var] = val
        self._tmp.cleanup()

    # -- fixtures -----------------------------------------------------------

    def _write_global_profile(self, servers: dict) -> str:
        path = global_profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "servers": servers}, fh)
        return path

    def _write_project_profile(self, project_key: str, servers: dict) -> str:
        # Modern profile: records the full projectKey (what apply writes since
        # issue 07), so a scan recovers the real key and the server is renderable.
        path = project_profile_path(project_key)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(
                {"version": 1, "projectKey": project_key, "servers": servers}, fh
            )
        return path

    def _write_legacy_project_profile(self, project_key: str, servers: dict) -> str:
        # Legacy profile: written before projectKey was recorded. A scan cannot
        # recover the real key, so render must SKIP it as non-renderable.
        path = project_profile_path(project_key)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "servers": servers}, fh)
        return path

    def _server_entry(self, name: str, *, env_keys=None, secret_keys=None) -> dict:
        return {
            "name": name,
            "type": "stdio",
            "command": {"argv": ["npx", "-y", f"@example/{name}@latest"]},
            "envKeys": list(env_keys or []),
            "secretEnvKeys": list(secret_keys or []),
            "source": {"provider": "claude-code", "importId": f"imp-{name}"},
        }

    def _claude_fixture(self, mcp_servers: dict, projects: dict = None) -> str:
        path = os.path.join(self.home, "claude.json")
        data = {"mcpServers": mcp_servers}
        if projects is not None:
            data["projects"] = projects
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        return path

    def _codex_fixture(self, toml_text: str) -> str:
        path = os.path.join(self.home, "config.toml")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(toml_text)
        return path


class CollectProfileServersTest(RenderEnv):
    def test_collects_global_and_project_servers(self) -> None:
        self._write_global_profile({"context7": self._server_entry("context7")})
        self._write_project_profile(
            _PROJECT_KEY, {"local-tool": self._server_entry("local-tool")}
        )
        servers = collect_profile_servers()
        names = {(s.name, s.scope) for s in servers}
        self.assertIn(("context7", "global"), names)
        self.assertIn(("local-tool", "project"), names)

    def test_no_profile_yields_no_servers(self) -> None:
        self.assertEqual(collect_profile_servers(), [])

    def test_disabled_server_is_excluded(self) -> None:
        entry = self._server_entry("context7")
        entry["enabled"] = False
        self._write_global_profile({"context7": entry})
        self.assertEqual(collect_profile_servers(), [])

    def test_secrets_file_is_not_read_as_profile(self) -> None:
        # A *.secrets.json sibling in the projects dir must never be treated as a
        # project profile (it holds credential VALUES under 0600).
        self._write_project_profile(
            _PROJECT_KEY, {"local-tool": self._server_entry("local-tool")}
        )
        secrets_path = os.path.join(
            os.path.dirname(global_profile_path()),
            "projects",
            "leak.secrets.json",
        )
        with open(secrets_path, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "servers": {"x": {"K": _SECRET_VALUE}}}, fh)
        servers = collect_profile_servers()
        # Only the real project profile contributes; the secrets file is ignored.
        self.assertEqual([s.name for s in servers], ["local-tool"])


class NamingTest(unittest.TestCase):
    def test_prefix_and_managed_detection(self) -> None:
        self.assertEqual(rendered_name("context7"), "boxa-context7")
        self.assertTrue(is_boxa_managed("boxa-context7"))
        self.assertFalse(is_boxa_managed("context7"))
        self.assertEqual(BOXA_PREFIX, "boxa-")


class ClaudePlanTest(RenderEnv):
    def test_planned_entries_are_prefixed_and_call_wrapper(self) -> None:
        self._write_global_profile(
            {"context7": self._server_entry("context7", env_keys=["CONTEXT7_API_KEY"])}
        )
        claude_cfg = self._claude_fixture({})
        servers = collect_profile_servers()
        plan = build_claude_plan(servers, config_path=claude_cfg)
        self.assertTrue(plan.supported)
        self.assertEqual(len(plan.planned), 1)
        entry = plan.planned[0]
        self.assertEqual(entry.rendered_name, "boxa-context7")
        # WRAPPER call, not the raw MCP command (npx ...).
        self.assertEqual(entry.argv, [WRAPPER_COMMAND, "context7"])
        self.assertNotIn("npx", entry.argv)

    def test_ownership_split_managed_vs_inherited(self) -> None:
        self._write_global_profile({"context7": self._server_entry("context7")})
        claude_cfg = self._claude_fixture(
            {
                "boxa-stale": {"command": "x"},
                "manual-thing": {"command": "y"},
            },
            projects={
                "/p": {"mcpServers": {"inherited-proj": {"command": "z"}}},
            },
        )
        servers = collect_profile_servers()
        plan = build_claude_plan(servers, config_path=claude_cfg)
        self.assertEqual(plan.managed_existing, ["boxa-stale"])
        self.assertEqual(
            sorted(plan.inherited_existing), ["inherited-proj", "manual-thing"]
        )

    def test_no_secret_values_in_plan(self) -> None:
        self._write_global_profile(
            {
                "context7": self._server_entry(
                    "context7",
                    env_keys=["CONTEXT7_API_KEY"],
                    secret_keys=["CONTEXT7_API_KEY"],
                )
            }
        )
        claude_cfg = self._claude_fixture({})
        servers = collect_profile_servers()
        plan = build_claude_plan(servers, config_path=claude_cfg)
        blob = json.dumps(plan.to_dict())
        self.assertNotIn(_SECRET_VALUE, blob)
        # Names ARE present, values are not.
        self.assertIn("CONTEXT7_API_KEY", blob)


class CodexPlanTest(RenderEnv):
    def test_supported_against_verified_toml_shape(self) -> None:
        self._write_global_profile({"context7": self._server_entry("context7")})
        codex_cfg = self._codex_fixture(
            '[mcp_servers.some-manual]\ncommand = "npx"\nargs = ["x"]\n'
        )
        servers = collect_profile_servers()
        plan = build_codex_plan(servers, config_path=codex_cfg)
        if render_mod.codex_provider._toml is None:
            self.skipTest("no TOML parser available in this runtime")
        self.assertTrue(plan.supported)
        self.assertEqual(plan.planned[0].rendered_name, "boxa-context7")
        # Inherited Codex table entry is preserved/never boxa-managed.
        self.assertEqual(plan.inherited_existing, ["some-manual"])

    def test_project_servers_excluded_from_codex_plan(self) -> None:
        # Codex has no per-project MCP namespace, so a project-scoped server must
        # NOT appear in the Codex plan (preview must match the write). The global
        # server still renders.
        self._write_global_profile({"context7": self._server_entry("context7")})
        self._write_project_profile(
            _PROJECT_KEY, {"local-tool": self._server_entry("local-tool")}
        )
        codex_cfg = self._codex_fixture("")
        servers = collect_profile_servers()
        if render_mod.codex_provider._toml is None:
            self.skipTest("no TOML parser available in this runtime")
        plan = build_codex_plan(servers, config_path=codex_cfg)
        names = [p.rendered_name for p in plan.planned]
        self.assertIn("boxa-context7", names)
        self.assertNotIn("boxa-local-tool", names)
        self.assertTrue(all(p.scope == "global" for p in plan.planned))

    def test_unsupported_when_no_toml_parser(self) -> None:
        self._write_global_profile({"context7": self._server_entry("context7")})
        codex_cfg = self._codex_fixture("[mcp_servers.x]\ncommand = \"y\"\n")
        servers = collect_profile_servers()
        saved = render_mod.codex_provider._toml
        try:
            render_mod.codex_provider._toml = None
            plan = build_codex_plan(servers, config_path=codex_cfg)
        finally:
            render_mod.codex_provider._toml = saved
        self.assertFalse(plan.supported)
        self.assertIn("unsupported", plan.unsupported_reason.lower())
        self.assertEqual(plan.planned, [])


class RenderPlanWritesNothingTest(RenderEnv):
    def test_build_render_plan_writes_no_agent_config(self) -> None:
        self._write_global_profile(
            {
                "context7": self._server_entry(
                    "context7", secret_keys=["CONTEXT7_API_KEY"]
                )
            }
        )
        claude_cfg = self._claude_fixture({"manual": {"command": "x"}})
        codex_cfg = self._codex_fixture('[mcp_servers.m]\ncommand = "y"\n')

        def _read(path: str) -> str:
            with open(path, encoding="utf-8") as fh:
                return fh.read()

        claude_before = _read(claude_cfg)
        codex_before = _read(codex_cfg)
        claude_mtime = os.path.getmtime(claude_cfg)
        codex_mtime = os.path.getmtime(codex_cfg)

        # build_render_plan uses default agent paths, but it is read-only either
        # way; assert the explicit fixtures we DO control are untouched.
        build_claude_plan(collect_profile_servers(), config_path=claude_cfg)
        build_codex_plan(collect_profile_servers(), config_path=codex_cfg)

        self.assertEqual(_read(claude_cfg), claude_before)
        self.assertEqual(_read(codex_cfg), codex_before)
        self.assertEqual(os.path.getmtime(claude_cfg), claude_mtime)
        self.assertEqual(os.path.getmtime(codex_cfg), codex_mtime)

    def test_full_plan_reports_both_agents(self) -> None:
        self._write_global_profile({"context7": self._server_entry("context7")})
        plan = build_render_plan()
        d = plan.to_dict()
        self.assertTrue(d["dryRun"])
        agents = {a["agent"] for a in d["agents"]}
        self.assertEqual(agents, {"claude-code", "codex"})


class NameCollisionTest(RenderEnv):
    def test_global_and_project_same_name_get_distinct_rendered_names(self) -> None:
        # Same source name in both scopes would otherwise produce two identical
        # boxa-<name> entries (ADR 0013 decision 19).
        self._write_global_profile({"context7": self._server_entry("context7")})
        self._write_project_profile(
            _PROJECT_KEY, {"context7": self._server_entry("context7")}
        )
        claude_cfg = self._claude_fixture({})
        servers = collect_profile_servers()
        plan = build_claude_plan(servers, config_path=claude_cfg)
        rendered = sorted(e.rendered_name for e in plan.planned)
        # Two DISTINCT rendered names, no collision.
        self.assertEqual(len(rendered), 2)
        self.assertEqual(len(set(rendered)), 2)
        self.assertIn("boxa-context7", rendered)
        # The project entry is disambiguated with its label.
        self.assertTrue(
            any(r.startswith("boxa-context7-") for r in rendered),
            rendered,
        )

    def test_colliding_servers_get_distinct_wrapper_argv(self) -> None:
        # Distinct rendered names are not enough; the wrapper argv must also
        # identify which scoped slot to launch, or the wrapper cannot tell the
        # global slot from the Project slot.
        self._write_global_profile({"context7": self._server_entry("context7")})
        self._write_project_profile(
            _PROJECT_KEY, {"context7": self._server_entry("context7")}
        )
        claude_cfg = self._claude_fixture({})
        plan = build_claude_plan(
            collect_profile_servers(), config_path=claude_cfg
        )
        by_scope = {e.scope: e for e in plan.planned}
        # Global keeps the canonical bare wrapper form.
        self.assertEqual(by_scope["global"].argv, [WRAPPER_COMMAND, "context7"])
        # Project carries a scope-qualifying argument; the two argv differ.
        self.assertNotEqual(by_scope["project"].argv, by_scope["global"].argv)
        self.assertIn("--project", by_scope["project"].argv)
        self.assertIn("context7", by_scope["project"].argv)

    def test_same_basename_projects_get_unique_wrapper_argv(self) -> None:
        # Two explicit project profiles whose paths share a basename and server
        # name must still produce uniquely-launchable wrapper commands.
        key_a = "/work/a/api"
        key_b = "/work/b/api"
        self._write_project_profile(key_a, {"srv": self._server_entry("srv")})
        self._write_project_profile(key_b, {"srv": self._server_entry("srv")})
        claude_cfg = self._claude_fixture({})
        servers = collect_profile_servers(project_keys=[key_a, key_b])
        plan = build_claude_plan(servers, config_path=claude_cfg)
        argvs = [tuple(e.argv) for e in plan.planned]
        # Both carry the FULL project key, so the two argv are distinct.
        self.assertEqual(len(argvs), 2)
        self.assertEqual(len(set(argvs)), 2)
        self.assertIn((WRAPPER_COMMAND, "--project", key_a, "srv"), argvs)
        self.assertIn((WRAPPER_COMMAND, "--project", key_b, "srv"), argvs)
        # Rendered names are also distinct (no agent-config collision).
        rendered = [e.rendered_name for e in plan.planned]
        self.assertEqual(len(set(rendered)), 2)

    def test_no_collision_keeps_bare_name(self) -> None:
        self._write_global_profile({"context7": self._server_entry("context7")})
        self._write_project_profile(
            _PROJECT_KEY, {"other": self._server_entry("other")}
        )
        claude_cfg = self._claude_fixture({})
        plan = build_claude_plan(
            collect_profile_servers(), config_path=claude_cfg
        )
        rendered = sorted(e.rendered_name for e in plan.planned)
        self.assertEqual(rendered, ["boxa-context7", "boxa-other"])


class ProjectKeyRoundTripTest(RenderEnv):
    """A scanned project profile must render the FULL key the wrapper resolves.

    Regression for the project-scoped launch bug: when render scans project
    profiles without an explicit --project, the rendered wrapper call must carry
    the original absolute project key recorded at apply time — NOT the
    sanitized+hashed filename label, which the wrapper would re-hash into a
    different, non-existent profile/secrets path and fail to launch.
    """

    def _write_project_profile_with_key(self, project_key: str, servers: dict) -> str:
        path = project_profile_path(project_key)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(
                {"version": 1, "projectKey": project_key, "servers": servers}, fh
            )
        return path

    def test_scanned_profile_emits_recorded_full_key(self) -> None:
        self._write_project_profile_with_key(
            _PROJECT_KEY, {"local-tool": self._server_entry("local-tool")}
        )
        # No explicit project_keys: render must SCAN and recover the stored key.
        servers = collect_profile_servers()
        proj = [s for s in servers if s.scope == "project"]
        self.assertEqual(len(proj), 1)
        # The recovered key is the full absolute key, not the hashed filename.
        self.assertEqual(proj[0].project_key, _PROJECT_KEY)

    def test_scanned_profile_wrapper_argv_carries_full_key(self) -> None:
        self._write_project_profile_with_key(
            _PROJECT_KEY, {"local-tool": self._server_entry("local-tool")}
        )
        claude_cfg = self._claude_fixture({})
        plan = build_claude_plan(collect_profile_servers(), config_path=claude_cfg)
        entry = plan.planned[0]
        self.assertEqual(
            entry.argv, [WRAPPER_COMMAND, "--project", _PROJECT_KEY, "local-tool"]
        )
        # And that key maps back to the SAME profile file render read.
        self.assertEqual(
            project_profile_path(entry.project_key),
            project_profile_path(_PROJECT_KEY),
        )

    def test_legacy_profile_without_key_is_skipped_not_rendered(self) -> None:
        # A profile written before projectKey was recorded: its filename is a
        # sanitized+hashed label the wrapper cannot reverse into a profile path,
        # so rendering a `--project <label>` entry would parse yet fail to launch.
        # Render must SKIP it (renderable=False, with a reason), never emit it.
        self._write_legacy_project_profile(
            _PROJECT_KEY, {"local-tool": self._server_entry("local-tool")}
        )
        servers = collect_profile_servers()
        proj = [s for s in servers if s.scope == "project"]
        self.assertEqual(len(proj), 1)
        self.assertFalse(proj[0].renderable)
        self.assertIn("projectKey", proj[0].skip_reason)

    def test_legacy_profile_excluded_from_planned_entries(self) -> None:
        # The skipped legacy server must not produce an agent entry...
        self._write_legacy_project_profile(
            _PROJECT_KEY, {"local-tool": self._server_entry("local-tool")}
        )
        claude_cfg = self._claude_fixture({})
        servers = collect_profile_servers()
        plan = build_claude_plan(servers, config_path=claude_cfg)
        self.assertEqual(plan.planned, [])

    def test_legacy_profile_surfaced_in_render_plan_skipped(self) -> None:
        # ...but it IS surfaced in the plan's skipped list with its reason.
        self._write_legacy_project_profile(
            _PROJECT_KEY, {"local-tool": self._server_entry("local-tool")}
        )
        plan = build_render_plan()
        self.assertEqual([s.name for s in plan.skipped], ["local-tool"])
        self.assertEqual(plan.renderable_servers, [])
        self.assertIn("skipped", plan.to_dict())


class StaleManagedTest(RenderEnv):
    def test_empty_profile_still_reports_stale_managed_entries(self) -> None:
        # No profile servers, but the agent has a leftover boxa- entry that a
        # re-render would remove. The plan must surface it (cleanup visibility).
        claude_cfg = self._claude_fixture(
            {"boxa-old": {"command": "x"}, "manual": {"command": "y"}}
        )
        servers = collect_profile_servers()
        self.assertEqual(servers, [])
        plan = build_claude_plan(servers, config_path=claude_cfg)
        self.assertEqual(plan.planned, [])
        self.assertEqual(plan.managed_existing, ["boxa-old"])
        self.assertEqual(plan.inherited_existing, ["manual"])


class CliTextTest(RenderEnv):
    """CLI text path (`mcp.cli render-text`) short-circuit behaviour."""

    def _capture_text(self, plan) -> str:
        import io
        from contextlib import redirect_stdout

        from mcp import cli as cli_mod

        buf = io.StringIO()
        with redirect_stdout(buf):
            cli_mod._render_plan_text(plan)  # noqa: SLF001 - direct unit check
        return buf.getvalue()

    def test_empty_profile_with_unsupported_codex_still_reports_codex(self) -> None:
        # No servers, no stale entries, but Codex is unsupported (e.g. no TOML
        # parser). The empty short-circuit must NOT hide the Codex status.
        claude_cfg = self._claude_fixture({})
        servers = collect_profile_servers()
        self.assertEqual(servers, [])
        saved = render_mod.codex_provider._toml
        try:
            render_mod.codex_provider._toml = None
            plan = build_render_plan()
        finally:
            render_mod.codex_provider._toml = saved
        # Point the claude plan at our empty fixture so it does not read a real
        # config; the codex plan is already unsupported.
        plan.claude = build_claude_plan([], config_path=claude_cfg)
        out = self._capture_text(plan)
        self.assertNotIn("Import or add servers first", out)
        self.assertIn("unsupported", out.lower())
        self.assertIn("codex", out.lower())

    def test_empty_profile_all_supported_short_circuits(self) -> None:
        claude_cfg = self._claude_fixture({})
        plan = build_render_plan()
        plan.claude = build_claude_plan([], config_path=claude_cfg)
        # Force codex supported with no entries.
        plan.codex.supported = True
        plan.codex.planned = []
        plan.codex.managed_existing = []
        plan.codex.inherited_existing = []
        out = self._capture_text(plan)
        self.assertIn("Import or add servers first", out)


if __name__ == "__main__":
    unittest.main()
