#!/usr/bin/env python3
"""Fixture-based tests for the Claude Code MCP discovery provider (issue 02).

Run with:

    python3 -m unittest tests.test_mcp_claude_provider   # from repo root
    python3 tests/test_mcp_claude_provider.py            # standalone

These tests use an in-memory `.claude.json`-shaped fixture written to a temp
file so they never depend on (or touch) the real ~/.claude. The fixture has:

  * a global `mcpServers` block,
  * a project with MULTIPLE MCP servers,
  * at least one server carrying a SECRET env value,
  * a Claude hosted/remote connector (http type) that must be excluded.

Assertions cover the issue-02 acceptance criteria:
  * candidates are discovered for global, project, and --all scope;
  * provider / source scope / source project / name / type / argv / env key
    NAMES are all present;
  * secret env VALUES never appear in any output (dict or JSON);
  * remote connectors are surfaced as excluded, not dropped;
  * discovery does not modify the source file (byte-identical before/after).
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp import import_result  # noqa: E402
from mcp.providers import ClaudeProvider  # noqa: E402
from mcp.providers.claude import PROVIDER  # noqa: E402

# A secret value that must NEVER appear in any output.
_SECRET_VALUE = "sk-ant-super-secret-value-do-not-leak"
_TM_PROJECT = "/home/tester/Projekty/MultiServerApp"
_OTHER_PROJECT = "/home/tester/Projekty/OtherApp"

_FIXTURE = {
    "mcpServers": {
        "global-helper": {
            "type": "stdio",
            "command": "npx",
            "args": ["-y", "@example/global-helper@latest"],
            "env": {"GLOBAL_HELPER_TOKEN": _SECRET_VALUE},
        }
    },
    "projects": {
        _TM_PROJECT: {
            "mcpServers": {
                "task-master-ai": {
                    "type": "stdio",
                    "command": "npx",
                    "args": ["-y", "--package=task-master-ai", "task-master-ai"],
                    "env": {
                        "ANTHROPIC_API_KEY": _SECRET_VALUE,
                        "LOG_LEVEL": "info",
                    },
                },
                "context7": {
                    "type": "stdio",
                    "command": "npx",
                    "args": ["-y", "@upstash/context7-mcp@latest"],
                },
                "gmail-connector": {
                    "type": "http",
                    "url": "https://mcp.claude.ai/gmail",
                },
            }
        },
        _OTHER_PROJECT: {
            "mcpServers": {
                "other-server": {
                    "type": "stdio",
                    "command": "uvx",
                    "args": ["some-tool"],
                }
            }
        },
        "/home/tester/Projekty/SecretArgsApp": {
            "mcpServers": {
                "argv-secret-server": {
                    "type": "stdio",
                    "command": "npx",
                    "args": [
                        "-y",
                        "some-mcp",
                        "--api-key",
                        _SECRET_VALUE,
                        "--token=" + _SECRET_VALUE,
                        _SECRET_VALUE,
                        # Embedded secrets inside larger tokens (codex P1).
                        "--header",
                        "Authorization: Bearer " + _SECRET_VALUE,
                        "API_KEY=" + _SECRET_VALUE,
                        "--header=X-Auth: " + _SECRET_VALUE,
                    ],
                }
            }
        },
        "/home/tester/Projekty/NoMcpApp": {
            "allowedTools": [],
        },
    },
}
_SECRET_ARGS_PROJECT = "/home/tester/Projekty/SecretArgsApp"


class ClaudeProviderTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".claude.json", delete=False, encoding="utf-8"
        )
        json.dump(_FIXTURE, self._tmp, indent=2)
        self._tmp.flush()
        self._tmp.close()
        self.path = self._tmp.name
        self.provider = ClaudeProvider(config_path=self.path)

    def tearDown(self) -> None:
        os.unlink(self.path)

    # -- discovery scope -----------------------------------------------------

    def test_discover_global(self) -> None:
        cands = self.provider.discover_global()
        names = {c.name for c in cands}
        self.assertEqual(names, {"global-helper"})
        self.assertEqual(cands[0].source_scope, "global")
        self.assertIsNone(cands[0].source_project)
        self.assertEqual(cands[0].provider, PROVIDER)

    def test_discover_project_multiple_servers(self) -> None:
        cands = self.provider.discover_project(_TM_PROJECT)
        names = {c.name for c in cands}
        # Multiple MCP servers in one project, including the excluded connector.
        self.assertIn("task-master-ai", names)
        self.assertIn("context7", names)
        self.assertIn("gmail-connector", names)
        for c in cands:
            self.assertEqual(c.source_scope, "project")
            self.assertEqual(c.source_project, _TM_PROJECT)

    def test_discover_all_spans_projects(self) -> None:
        cands = self.provider.discover(all_projects=True)
        names = {c.name for c in cands}
        # global + both projects with mcpServers.
        self.assertIn("global-helper", names)
        self.assertIn("task-master-ai", names)
        self.assertIn("other-server", names)

    def test_project_keys_includes_all_records(self) -> None:
        # project_keys must expose every known project record (even ones with
        # no MCP servers yet) so `--project <name>` can resolve them.
        keys = set(self.provider.project_keys())
        self.assertEqual(
            keys,
            {
                _TM_PROJECT,
                _OTHER_PROJECT,
                _SECRET_ARGS_PROJECT,
                "/home/tester/Projekty/NoMcpApp",
            },
        )

    def test_project_without_mcp_resolves_empty(self) -> None:
        # A real project record with no project-scoped MCP yields no project
        # candidates rather than an error.
        cands = self.provider.discover_project("/home/tester/Projekty/NoMcpApp")
        self.assertEqual(cands, [])

    def test_no_global_flag(self) -> None:
        cands = self.provider.discover(
            project_keys=[_TM_PROJECT], include_global=False
        )
        names = {c.name for c in cands}
        self.assertNotIn("global-helper", names)
        self.assertIn("context7", names)

    # -- candidate shape -----------------------------------------------------

    def test_candidate_fields_present(self) -> None:
        cand = next(
            c
            for c in self.provider.discover_project(_TM_PROJECT)
            if c.name == "task-master-ai"
        )
        d = cand.to_dict()
        self.assertEqual(d["provider"], PROVIDER)
        self.assertEqual(d["sourceScope"], "project")
        self.assertEqual(d["sourceProject"], _TM_PROJECT)
        self.assertEqual(d["sourcePath"], self.path)
        self.assertEqual(d["type"], "stdio")
        self.assertEqual(d["command"]["argv"][0], "npx")
        # Env key NAMES are present.
        self.assertIn("ANTHROPIC_API_KEY", d["command"]["envKeys"])
        self.assertIn("LOG_LEVEL", d["command"]["envKeys"])
        # Secret-looking name is flagged; non-secret name is not.
        self.assertIn("ANTHROPIC_API_KEY", d["command"]["secretEnvKeys"])
        self.assertNotIn("LOG_LEVEL", d["command"]["secretEnvKeys"])

    def test_context7_no_env(self) -> None:
        cand = next(
            c
            for c in self.provider.discover_project(_TM_PROJECT)
            if c.name == "context7"
        )
        self.assertEqual(cand.command.env_keys, [])
        self.assertEqual(cand.command.secret_env_keys, [])

    # -- remote connector exclusion -----------------------------------------

    def test_remote_connector_excluded(self) -> None:
        cand = next(
            c
            for c in self.provider.discover_project(_TM_PROJECT)
            if c.name == "gmail-connector"
        )
        self.assertEqual(cand.classification.placement, "excluded")
        self.assertEqual(cand.classification.confidence, "high")
        self.assertTrue(cand.classification.reasons)

    def test_stdio_candidate_not_excluded(self) -> None:
        cand = next(
            c
            for c in self.provider.discover_project(_TM_PROJECT)
            if c.name == "context7"
        )
        self.assertNotEqual(cand.classification.placement, "excluded")

    # -- secret-safety -------------------------------------------------------

    def test_secret_value_never_in_json(self) -> None:
        cands = self.provider.discover(all_projects=True)
        payload = json.dumps(import_result(cands))
        self.assertNotIn(_SECRET_VALUE, payload)
        # The KEY name is allowed to appear; the VALUE must not.
        self.assertIn("ANTHROPIC_API_KEY", payload)

    def test_secret_value_never_in_any_field(self) -> None:
        for cand in self.provider.discover(all_projects=True):
            blob = json.dumps(cand.to_dict())
            self.assertNotIn(_SECRET_VALUE, blob)
            for token in cand.command.argv:
                self.assertNotIn(_SECRET_VALUE, token)

    def test_secret_in_argv_is_redacted(self) -> None:
        # Credentials passed as CLI arguments must be scrubbed too, not just
        # env values (codex P1).
        cand = next(
            c
            for c in self.provider.discover_project(_SECRET_ARGS_PROJECT)
            if c.name == "argv-secret-server"
        )
        joined = " ".join(cand.command.argv)
        self.assertNotIn(_SECRET_VALUE, joined)
        # Also ensure no fragment of the secret survives anywhere.
        self.assertNotIn(_SECRET_VALUE[:20], joined)
        # Flag shape survives; only the value is redacted.
        self.assertIn("--api-key", cand.command.argv)
        self.assertIn("<redacted>", cand.command.argv)
        self.assertTrue(
            any(a.startswith("--token=") for a in cand.command.argv)
        )
        # Non-secret structural args are untouched.
        self.assertIn("-y", cand.command.argv)
        self.assertIn("some-mcp", cand.command.argv)
        # The bearer-header flag itself stays; its value token is redacted.
        self.assertIn("--header", cand.command.argv)

    def test_opaque_value_after_unknown_flag_redacted(self) -> None:
        # A credential passed through an agent-specific short flag whose name
        # does not match secret-name heuristics is still redacted (codex P1).
        from mcp.providers.claude import _redact_argv

        out = _redact_argv(["-k", "abc123", "server"])
        self.assertEqual(out, ["-k", "<redacted>", "server"])

    def test_structural_values_preserved(self) -> None:
        # Real-world structural args must survive redaction so command fidelity
        # is kept for later import/apply.
        from mcp.providers.claude import _redact_argv

        self.assertEqual(
            _redact_argv(["npx", "-y", "@upstash/context7-mcp@latest"]),
            ["npx", "-y", "@upstash/context7-mcp@latest"],
        )
        self.assertEqual(
            _redact_argv(["--data-dir", "/home/u/x", "run"]),
            ["--data-dir", "/home/u/x", "run"],
        )
        # numbers / booleans following a flag stay intact
        self.assertEqual(_redact_argv(["--port", "8080"]), ["--port", "8080"])
        self.assertEqual(
            _redact_argv(["--verbose", "true"]), ["--verbose", "true"]
        )

    def test_path_flag_not_redacted(self) -> None:
        # `--path /some/dir` must survive; `PAT` is a delimited hint, not a
        # substring of "path" (codex P2).
        from mcp.providers.claude import _is_secret_flag, _redact_argv

        self.assertFalse(_is_secret_flag("--path"))
        out = _redact_argv(["--path", "/home/user/data", "server"])
        self.assertEqual(out, ["--path", "/home/user/data", "server"])

    def test_pat_token_still_secret(self) -> None:
        from mcp.providers.claude import _is_secret_env_name, _is_secret_flag

        self.assertTrue(_is_secret_env_name("GITHUB_PAT"))
        self.assertTrue(_is_secret_env_name("PAT_TOKEN"))
        self.assertTrue(_is_secret_flag("--pat"))
        self.assertFalse(_is_secret_env_name("PATH"))

    def test_claude_config_dir_env_override(self) -> None:
        # candidate_config_paths honors CLAUDE_CONFIG_DIR first (ADR 0002).
        # Read at call time, so no module reload is needed.
        from mcp.providers.claude import candidate_config_paths

        prev = os.environ.get("CLAUDE_CONFIG_DIR")
        try:
            os.environ["CLAUDE_CONFIG_DIR"] = "/custom/claude/dir"
            paths = candidate_config_paths()
            self.assertEqual(
                paths[0], os.path.join("/custom/claude/dir", ".claude.json")
            )
            # The modern dir form and the legacy host form are still probed.
            self.assertTrue(any(p.endswith("/.claude/.claude.json") for p in paths))
            self.assertTrue(any(p.endswith("/.claude.json") for p in paths))
        finally:
            if prev is None:
                os.environ.pop("CLAUDE_CONFIG_DIR", None)
            else:
                os.environ["CLAUDE_CONFIG_DIR"] = prev

    def test_host_path_preferred_without_env(self) -> None:
        # Without CLAUDE_CONFIG_DIR, the host file ~/.claude.json must be
        # preferred over the config-dir form so a host import does not read a
        # container's bind-mounted metadata (codex P2 / ADR 0002 line 117-119).
        from mcp.providers.claude import candidate_config_paths

        prev = os.environ.get("CLAUDE_CONFIG_DIR")
        home = os.path.expanduser("~")
        try:
            os.environ.pop("CLAUDE_CONFIG_DIR", None)
            paths = candidate_config_paths()
            self.assertIn(os.path.join(home, ".claude.json"), paths)
            self.assertIn(os.path.join(home, ".claude", ".claude.json"), paths)
            # Host file comes before the config-dir form.
            self.assertLess(
                paths.index(os.path.join(home, ".claude.json")),
                paths.index(os.path.join(home, ".claude", ".claude.json")),
            )
        finally:
            if prev is not None:
                os.environ["CLAUDE_CONFIG_DIR"] = prev

    # -- read-only -----------------------------------------------------------

    def test_discovery_does_not_modify_source(self) -> None:
        with open(self.path, "rb") as fh:
            before = fh.read()
        mtime_before = os.stat(self.path).st_mtime_ns
        self.provider.discover(all_projects=True)
        self.provider.discover_global()
        self.provider.project_keys()
        with open(self.path, "rb") as fh:
            after = fh.read()
        self.assertEqual(before, after, "source .claude.json was modified")
        self.assertEqual(mtime_before, os.stat(self.path).st_mtime_ns)

    # -- robustness ----------------------------------------------------------

    def test_missing_file_yields_empty(self) -> None:
        provider = ClaudeProvider(config_path="/nonexistent/.claude.json")
        self.assertEqual(provider.discover(all_projects=True), [])
        self.assertEqual(provider.project_keys(), [])

    def test_malformed_file_yields_empty(self) -> None:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False, encoding="utf-8"
        ) as fh:
            fh.write("{ not valid json")
            bad = fh.name
        try:
            provider = ClaudeProvider(config_path=bad)
            self.assertEqual(provider.discover(all_projects=True), [])
        finally:
            os.unlink(bad)


if __name__ == "__main__":
    unittest.main()
