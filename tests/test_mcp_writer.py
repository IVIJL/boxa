#!/usr/bin/env python3
"""Tests for the real render write path (issue 07).

Run with:

    python3 -m unittest tests.test_mcp_writer   # from repo root
    python3 tests/test_mcp_writer.py            # standalone

Every test injects explicit temp agent config paths (a temp .claude.json and a
temp config.toml) so the real ~/.claude and ~/.codex are never read or written,
and points HOME / XDG_CONFIG_HOME at a tempdir so the real boxa profile is
never touched.

Covers the issue-07 real-render acceptance criteria:
  * `boxa mcp render` writes boxa- entries into Claude Code and Codex config;
  * the write is idempotent (rendering the same plan twice => identical file);
  * manual/inherited entries survive a render unchanged;
  * stale boxa- entries are removed/replaced on re-render;
  * no secret VALUE is ever written into agent config;
  * the dry-run preview writes NO file (write-free).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp.providers import codex as codex_provider  # noqa: E402
from mcp.render import (  # noqa: E402
    AgentPlan,
    PlannedEntry,
    build_render_plan,
)
from mcp.writer import (  # noqa: E402
    write_claude,
    write_codex,
    write_plan,
)

_SECRET_VALUE = "sk-ant-super-secret-do-not-leak-0123456789"

_HAS_TOML = codex_provider._toml is not None  # noqa: SLF001


def _entry(name: str, *, project_key: str = "", env_keys=None,
           secret_keys=None) -> PlannedEntry:
    """A planned entry mirroring what render.py produces (wrapper argv, no env)."""
    if project_key:
        argv = ["boxa-mcp-run", "--project", project_key, name]
        scope = "project"
    else:
        argv = ["boxa-mcp-run", name]
        scope = "global"
    return PlannedEntry(
        rendered_name=f"boxa-{name}",
        source_name=name,
        scope=scope,
        project_key=project_key,
        argv=argv,
        env_keys=list(env_keys or []),
        secret_env_keys=list(secret_keys or []),
    )


class WriterEnv(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name
        self.claude_path = os.path.join(self.dir, "claude.json")
        self.codex_path = os.path.join(self.dir, "config.toml")
        self._saved_xdg = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.dir, ".config")

    def tearDown(self) -> None:
        if self._saved_xdg is None:
            os.environ.pop("XDG_CONFIG_HOME", None)
        else:
            os.environ["XDG_CONFIG_HOME"] = self._saved_xdg
        self._tmp.cleanup()

    def _claude_plan(self, entries) -> AgentPlan:
        return AgentPlan(
            agent="claude-code",
            config_path=self.claude_path,
            planned=list(entries),
        )

    def _codex_plan(self, entries, *, supported=True) -> AgentPlan:
        return AgentPlan(
            agent="codex",
            config_path=self.codex_path,
            supported=supported,
            planned=list(entries),
        )

    def _read_claude(self) -> dict:
        with open(self.claude_path, "r", encoding="utf-8") as fh:
            return json.load(fh)

    def _read_codex(self) -> str:
        with open(self.codex_path, "r", encoding="utf-8") as fh:
            return fh.read()


class ClaudeWriteTest(WriterEnv):
    def test_writes_boxa_entry_calling_wrapper(self) -> None:
        write_claude(self._claude_plan([_entry("context7")]))
        data = self._read_claude()
        self.assertIn("boxa-context7", data["mcpServers"])
        entry = data["mcpServers"]["boxa-context7"]
        self.assertEqual(entry["command"], "boxa-mcp-run")
        self.assertEqual(entry["args"], ["context7"])
        self.assertEqual(entry["type"], "stdio")

    def test_no_secret_value_in_file(self) -> None:
        write_claude(self._claude_plan(
            [_entry("context7", env_keys=["K"], secret_keys=["K"])]
        ))
        with open(self.claude_path, "r", encoding="utf-8") as fh:
            text = fh.read()
        self.assertNotIn(_SECRET_VALUE, text)

    def test_idempotent(self) -> None:
        plan = self._claude_plan([_entry("context7"), _entry("other")])
        write_claude(plan)
        first = self._read_claude()
        write_claude(self._claude_plan([_entry("context7"), _entry("other")]))
        self.assertEqual(self._read_claude(), first)

    def test_manual_entries_survive(self) -> None:
        # Pre-seed an inherited/manual entry and an unrelated top-level key.
        with open(self.claude_path, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "mcpServers": {"manual-thing": {"command": "x"}},
                    "someOtherKey": {"keep": True},
                },
                fh,
            )
        write_claude(self._claude_plan([_entry("context7")]))
        data = self._read_claude()
        # Manual entry untouched, unrelated key preserved, boxa entry added.
        self.assertIn("manual-thing", data["mcpServers"])
        self.assertEqual(data["mcpServers"]["manual-thing"], {"command": "x"})
        self.assertEqual(data["someOtherKey"], {"keep": True})
        self.assertIn("boxa-context7", data["mcpServers"])

    def test_stale_boxa_entry_replaced(self) -> None:
        with open(self.claude_path, "w", encoding="utf-8") as fh:
            json.dump(
                {"mcpServers": {"boxa-old": {"command": "stale"}}}, fh
            )
        write_claude(self._claude_plan([_entry("context7")]))
        data = self._read_claude()
        self.assertNotIn("boxa-old", data["mcpServers"])
        self.assertIn("boxa-context7", data["mcpServers"])

    def test_stale_boxa_entry_in_project_record_removed(self) -> None:
        with open(self.claude_path, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "projects": {
                        "/p": {
                            "mcpServers": {
                                "boxa-old": {"command": "stale"},
                                "manual-proj": {"command": "keep"},
                            }
                        }
                    }
                },
                fh,
            )
        write_claude(self._claude_plan([_entry("context7")]))
        data = self._read_claude()
        proj = data["projects"]["/p"]["mcpServers"]
        self.assertNotIn("boxa-old", proj)
        self.assertIn("manual-proj", proj)

    def test_project_entry_written_to_project_record_not_global(self) -> None:
        # A project-scoped server must land in projects[<key>].mcpServers, NOT
        # the global top-level block — otherwise it would be offered in every
        # Claude project (cross-project scope leak).
        write_claude(
            self._claude_plan([_entry("local", project_key="/home/x/Proj")])
        )
        data = self._read_claude()
        proj = data["projects"]["/home/x/Proj"]["mcpServers"]
        self.assertIn("boxa-local", proj)
        self.assertNotIn("boxa-local", data.get("mcpServers", {}))

    def test_global_and_project_entries_split_by_scope(self) -> None:
        write_claude(
            self._claude_plan(
                [
                    _entry("context7"),
                    _entry("local", project_key="/home/x/Proj"),
                ]
            )
        )
        data = self._read_claude()
        self.assertIn("boxa-context7", data["mcpServers"])
        self.assertNotIn("boxa-local", data["mcpServers"])
        proj = data["projects"]["/home/x/Proj"]["mcpServers"]
        self.assertIn("boxa-local", proj)
        self.assertNotIn("boxa-context7", proj)

    def test_project_entry_is_idempotent(self) -> None:
        plan = self._claude_plan([_entry("local", project_key="/home/x/Proj")])
        write_claude(plan)
        first = self._read_claude()
        write_claude(plan)
        self.assertEqual(self._read_claude(), first)

    def test_project_entry_preserves_existing_project_manual_entries(self) -> None:
        with open(self.claude_path, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "projects": {
                        "/home/x/Proj": {
                            "mcpServers": {"manual-proj": {"command": "keep"}},
                            "history": ["unrelated"],
                        }
                    }
                },
                fh,
            )
        write_claude(
            self._claude_plan([_entry("local", project_key="/home/x/Proj")])
        )
        data = self._read_claude()
        record = data["projects"]["/home/x/Proj"]
        self.assertIn("manual-proj", record["mcpServers"])
        self.assertIn("boxa-local", record["mcpServers"])
        # Non-MCP project metadata is left untouched.
        self.assertEqual(record["history"], ["unrelated"])

    def test_new_global_entry_defaults_disabled_in_existing_projects(self) -> None:
        with open(self.claude_path, "w", encoding="utf-8") as fh:
            json.dump({"projects": {"/home/x/Proj": {"history": []}}}, fh)

        write_claude(self._claude_plan([_entry("context7")]))

        record = self._read_claude()["projects"]["/home/x/Proj"]
        self.assertEqual(record["disabledMcpServers"], ["boxa-context7"])

    def test_new_project_entry_defaults_disabled(self) -> None:
        write_claude(
            self._claude_plan([_entry("local", project_key="/home/x/Proj")])
        )

        record = self._read_claude()["projects"]["/home/x/Proj"]
        self.assertEqual(record["disabledMcpServers"], ["boxa-local"])

    def test_render_preserves_native_mcp_enable_choice(self) -> None:
        plan = self._claude_plan([_entry("context7")])
        with open(self.claude_path, "w", encoding="utf-8") as fh:
            json.dump({"projects": {"/home/x/Proj": {}}}, fh)
        write_claude(plan)

        # Claude Code `/mcp -> Enable` removes the name from this array.
        data = self._read_claude()
        data["projects"]["/home/x/Proj"]["disabledMcpServers"] = []
        with open(self.claude_path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)

        write_claude(plan)
        record = self._read_claude()["projects"]["/home/x/Proj"]
        self.assertEqual(record["disabledMcpServers"], [])

    def test_later_new_server_defaults_disabled_without_re_disabling_enabled(self) -> None:
        with open(self.claude_path, "w", encoding="utf-8") as fh:
            json.dump({"projects": {"/home/x/Proj": {}}}, fh)
        write_claude(self._claude_plan([_entry("context7")]))

        data = self._read_claude()
        data["projects"]["/home/x/Proj"]["disabledMcpServers"] = []
        with open(self.claude_path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)

        write_claude(
            self._claude_plan([_entry("context7"), _entry("taskmaster")])
        )
        disabled = self._read_claude()["projects"]["/home/x/Proj"][
            "disabledMcpServers"
        ]
        self.assertEqual(disabled, ["boxa-taskmaster"])

    def test_removed_server_cleans_its_disabled_default(self) -> None:
        with open(self.claude_path, "w", encoding="utf-8") as fh:
            json.dump({"projects": {"/home/x/Proj": {}}}, fh)
        write_claude(self._claude_plan([_entry("context7")]))

        write_claude(self._claude_plan([]))
        disabled = self._read_claude()["projects"]["/home/x/Proj"][
            "disabledMcpServers"
        ]
        self.assertEqual(disabled, [])


@unittest.skipUnless(_HAS_TOML, "no TOML parser available")
class CodexWriteTest(WriterEnv):
    def test_writes_boxa_table_calling_wrapper(self) -> None:
        write_codex(self._codex_plan([_entry("context7")]))
        text = self._read_codex()
        self.assertIn("[mcp_servers.boxa-context7]", text)
        self.assertIn('command = "boxa-mcp-run"', text)
        self.assertIn('args = ["context7"]', text)

    def test_no_secret_value_in_file(self) -> None:
        write_codex(self._codex_plan(
            [_entry("context7", env_keys=["K"], secret_keys=["K"])]
        ))
        self.assertNotIn(_SECRET_VALUE, self._read_codex())

    def test_idempotent(self) -> None:
        write_codex(self._codex_plan([_entry("context7"), _entry("other")]))
        first = self._read_codex()
        write_codex(self._codex_plan([_entry("context7"), _entry("other")]))
        self.assertEqual(self._read_codex(), first)

    def test_manual_tables_survive(self) -> None:
        with open(self.codex_path, "w", encoding="utf-8") as fh:
            fh.write(
                "model = \"gpt-5\"\n\n"
                "[mcp_servers.manual]\n"
                'command = "manual-cmd"\n'
                "args = []\n"
            )
        write_codex(self._codex_plan([_entry("context7")]))
        text = self._read_codex()
        # The manual table AND the unrelated top-level key survive verbatim.
        self.assertIn("[mcp_servers.manual]", text)
        self.assertIn('command = "manual-cmd"', text)
        self.assertIn('model = "gpt-5"', text)
        self.assertIn("[mcp_servers.boxa-context7]", text)

    def test_stale_boxa_table_replaced(self) -> None:
        with open(self.codex_path, "w", encoding="utf-8") as fh:
            fh.write(
                "[mcp_servers.boxa-old]\n"
                'command = "stale"\n'
                "args = []\n"
            )
        write_codex(self._codex_plan([_entry("context7")]))
        text = self._read_codex()
        self.assertNotIn("boxa-old", text)
        self.assertIn("[mcp_servers.boxa-context7]", text)

    def test_manual_table_with_commented_header_after_stale_survives(self) -> None:
        # A stale boxa table immediately followed by a manual table whose
        # header carries a trailing comment: the body-end scan must recognize the
        # commented header as a header, or it sweeps the manual table into the
        # boxa body and deletes it.
        with open(self.codex_path, "w", encoding="utf-8") as fh:
            fh.write(
                "[mcp_servers.boxa-old]\n"
                'command = "stale"\n'
                "args = []\n"
                "[mcp_servers.manual] # keep me\n"
                'command = "manual-cmd"\n'
                "args = []\n"
            )
        write_codex(self._codex_plan([_entry("context7")]))
        text = self._read_codex()
        self.assertNotIn("boxa-old", text)
        self.assertIn("[mcp_servers.manual]", text)
        self.assertIn('command = "manual-cmd"', text)
        self.assertIn("[mcp_servers.boxa-context7]", text)
        # And it still parses, with both manual and boxa tables present.
        with open(self.codex_path, "rb") as fh:
            parsed = codex_provider._toml.load(fh)  # noqa: SLF001
        self.assertIn("manual", parsed["mcp_servers"])
        self.assertIn("boxa-context7", parsed["mcp_servers"])

    def test_quoted_name_table_is_idempotent(self) -> None:
        # A server name needing quoting (a dot) must use a strip-recognized
        # header form, or a re-render appends a duplicate table (idempotency bug).
        plan = lambda: self._codex_plan([_entry("foo.bar")])  # noqa: E731
        write_codex(plan())
        first = self._read_codex()
        write_codex(plan())
        second = self._read_codex()
        self.assertEqual(first, second)
        # Exactly one boxa table for the quoted name, and it parses back.
        self.assertEqual(second.count("mcp_servers"), 1)
        with open(self.codex_path, "rb") as fh:
            parsed = codex_provider._toml.load(fh)  # noqa: SLF001
        self.assertIn("boxa-foo.bar", parsed["mcp_servers"])

    def test_quoted_name_with_embedded_quote_is_idempotent(self) -> None:
        # A name with a double quote emits an ESCAPED header
        # (`[mcp_servers."boxa-weird\"name"]`); the strip regex must recognize
        # the escaped quote or a re-render appends a duplicate table.
        plan = lambda: self._codex_plan([_entry('weird"name')])  # noqa: E731
        write_codex(plan())
        first = self._read_codex()
        write_codex(plan())
        second = self._read_codex()
        self.assertEqual(first, second)
        self.assertEqual(second.count("mcp_servers"), 1)
        with open(self.codex_path, "rb") as fh:
            parsed = codex_provider._toml.load(fh)  # noqa: SLF001
        self.assertIn('boxa-weird"name', parsed["mcp_servers"])

    def test_written_codex_is_parseable(self) -> None:
        # Round-trip: the emitted TOML must parse back with the GLOBAL boxa
        # table. The project-scoped entry is NOT written to Codex (no per-project
        # Codex namespace), so it must be absent from the single global table.
        with open(self.codex_path, "w", encoding="utf-8") as fh:
            fh.write('model = "gpt-5"\n[mcp_servers.manual]\ncommand = "m"\n')
        write_codex(self._codex_plan(
            [_entry("context7"), _entry("local", project_key="/home/x/Proj")]
        ))
        with open(self.codex_path, "rb") as fh:
            parsed = codex_provider._toml.load(fh)  # noqa: SLF001
        tables = parsed["mcp_servers"]
        self.assertIn("boxa-context7", tables)
        self.assertNotIn("boxa-local", tables)  # project entry not promoted
        self.assertIn("manual", tables)
        self.assertEqual(parsed["model"], "gpt-5")

    def test_project_entry_not_written_to_codex_global(self) -> None:
        # A project-scoped server alone must produce NO boxa table in Codex.
        write_codex(
            self._codex_plan([_entry("local", project_key="/home/x/Proj")])
        )
        self.assertNotIn("boxa-local", self._read_codex())

    def test_stale_codex_project_table_is_stripped(self) -> None:
        # A previously-rendered boxa project table must be removed on re-render
        # even though no project entry is re-written for Codex.
        with open(self.codex_path, "w", encoding="utf-8") as fh:
            fh.write(
                "[mcp_servers.boxa-local-Proj]\n"
                'command = "boxa-mcp-run"\n'
                'args = ["--project", "/home/x/Proj", "local"]\n'
            )
        write_codex(
            self._codex_plan([_entry("local", project_key="/home/x/Proj")])
        )
        self.assertNotIn("boxa-local-Proj", self._read_codex())


class WritePlanTest(WriterEnv):
    def test_writes_claude_always(self) -> None:
        written = write_plan(
            self._claude_plan([_entry("context7")]),
            self._codex_plan([], supported=False),
        )
        self.assertIn("claude-code", written)
        # Unsupported Codex is SKIPPED, not failed.
        self.assertNotIn("codex", written)
        self.assertTrue(os.path.isfile(self.claude_path))

    @unittest.skipUnless(_HAS_TOML, "no TOML parser available")
    def test_writes_both_when_supported(self) -> None:
        written = write_plan(
            self._claude_plan([_entry("context7")]),
            self._codex_plan([_entry("context7")]),
        )
        self.assertEqual(sorted(written), ["claude-code", "codex"])


class DryRunIsWriteFreeTest(unittest.TestCase):
    """The dry-run plan builder must not create any agent config file."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self._saved = {}
        for var in ("HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR"):
            self._saved[var] = os.environ.get(var)
        os.environ["HOME"] = self.home
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.home, ".config")
        os.environ.pop("CLAUDE_CONFIG_DIR", None)

    def tearDown(self) -> None:
        for var, val in self._saved.items():
            if val is None:
                os.environ.pop(var, None)
            else:
                os.environ[var] = val
        self._tmp.cleanup()

    def test_build_render_plan_writes_nothing(self) -> None:
        # Seed a global profile so there IS something to (not) render.
        from mcp.profile import global_profile_path

        path = global_profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "version": 1,
                    "servers": {
                        "context7": {
                            "name": "context7",
                            "command": {"argv": ["npx", "context7"]},
                            "envKeys": [],
                            "secretEnvKeys": [],
                        }
                    },
                },
                fh,
            )
        plan = build_render_plan()
        # The dry-run plan names target agent config paths but must not create
        # them.
        self.assertFalse(os.path.isfile(plan.claude.config_path))
        if plan.codex.supported:
            self.assertFalse(os.path.isfile(plan.codex.config_path))


class ScopedWriteRejectedTest(unittest.TestCase):
    """The real render write must reject --project (full-surface only).

    A scoped write would drop other projects' already-rendered boxa entries,
    because the writers own and rewrite the whole boxa- set. Tested through the
    cli entry point (the dispatch is where the guard lives).
    """

    def _run_cli(self, args):
        env = dict(os.environ)
        env["PYTHONPATH"] = (
            os.path.join(_REPO_ROOT, "scripts")
            + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
        )
        return subprocess.run(
            [sys.executable, "-m", "mcp.cli", *args],
            capture_output=True,
            text=True,
            env=env,
            cwd=_REPO_ROOT,
        )

    def test_render_write_rejects_project_flag(self) -> None:
        res = self._run_cli(
            ["render-write-text", "--project", "/home/x/Proj"]
        )
        self.assertEqual(res.returncode, 2)
        self.assertIn("--project", res.stderr)
        self.assertIn("full", res.stderr.lower())

    def test_dry_run_still_accepts_project_flag(self) -> None:
        # The preview path keeps --project; an empty profile previews cleanly.
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ)
            env["HOME"] = home
            env["XDG_CONFIG_HOME"] = os.path.join(home, ".config")
            env.pop("CLAUDE_CONFIG_DIR", None)
            env["PYTHONPATH"] = os.path.join(_REPO_ROOT, "scripts")
            res = subprocess.run(
                [
                    sys.executable, "-m", "mcp.cli",
                    "render-text", "--project", "/home/x/Proj",
                ],
                capture_output=True, text=True, env=env, cwd=_REPO_ROOT,
            )
        self.assertEqual(res.returncode, 0)


if __name__ == "__main__":
    unittest.main()
