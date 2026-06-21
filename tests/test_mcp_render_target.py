#!/usr/bin/env python3
"""Tests for the render target / discovery-source split (ADR 0014, issue 14).

Run with:

    python3 -m unittest tests.test_mcp_render_target   # from repo root
    python3 tests/test_mcp_render_target.py            # standalone

The Container runs Claude Code with CLAUDE_CONFIG_DIR=/home/node/.claude and
docker-run.sh bind-mounts the host ~/.claude directory there, so the agent reads
~/.claude/.claude.json (the config-dir form). boxa render must WRITE boxa-
entries to that config-dir file, NOT the host-native ~/.claude.json that
discovery prefers. These tests lock in:

  * render_target_path resolves to ~/.claude/.claude.json (host present/absent);
  * render_target_path does NOT honor a host CLAUDE_CONFIG_DIR (the footgun),
    while discovery's default_config_path still does;
  * build_claude_plan defaults to the render target and keeps the injectable
    config_path for tests;
  * after a write, the boxa- entry is in the config-dir file and ABSENT from
    the host's own ~/.claude.json, which stays byte-stable;
  * render only mutates boxa- keys; other content is preserved;
  * Codex render target is unchanged.

Every test points HOME at a tempdir so the real ~/.claude is never read/written.
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
import sys

sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp.providers import codex as codex_provider  # noqa: E402
from mcp.providers.claude import (  # noqa: E402
    ClaudeProvider,
    default_config_path as claude_default_config_path,
    render_target_path as claude_render_target_path,
)
from mcp.render import (  # noqa: E402
    ProfileServer,
    build_claude_plan,
    build_codex_plan,
)
from mcp.writer import write_claude  # noqa: E402


class _HomeEnv(unittest.TestCase):
    """Base case: redirect HOME to a tempdir and clear CLAUDE_CONFIG_DIR."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self._saved = {
            k: os.environ.get(k) for k in ("HOME", "CLAUDE_CONFIG_DIR")
        }
        os.environ["HOME"] = self.home
        os.environ.pop("CLAUDE_CONFIG_DIR", None)

    def tearDown(self) -> None:
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self._tmp.cleanup()

    @property
    def host_native(self) -> str:
        return os.path.join(self.home, ".claude.json")

    @property
    def config_dir_file(self) -> str:
        return os.path.join(self.home, ".claude", ".claude.json")


def _server(name: str) -> ProfileServer:
    return ProfileServer(name=name, scope="global", project_key="")


class RenderTargetResolutionTest(_HomeEnv):
    def test_render_target_is_config_dir_form_when_host_native_absent(self) -> None:
        self.assertFalse(os.path.exists(self.host_native))
        self.assertEqual(claude_render_target_path(), self.config_dir_file)

    def test_render_target_is_config_dir_form_when_host_native_present(self) -> None:
        # Even when host-native ~/.claude.json EXISTS, render targets the
        # config-dir form the Container reads.
        with open(self.host_native, "w", encoding="utf-8") as fh:
            json.dump({"mcpServers": {}}, fh)
        self.assertEqual(claude_render_target_path(), self.config_dir_file)

    def test_render_target_ignores_host_claude_config_dir(self) -> None:
        # The CLAUDE_CONFIG_DIR footgun: on the host the user may point their
        # OWN Claude Code at a config dir that is NOT bind-mounted into the
        # Container. Discovery DOES honor it (first candidate), proving render
        # intentionally diverges rather than coincidentally matching; the render
        # target must NOT divert there.
        elsewhere = os.path.join(self.home, "elsewhere")
        os.makedirs(elsewhere)
        os.environ["CLAUDE_CONFIG_DIR"] = elsewhere
        self.assertEqual(
            claude_default_config_path(),
            os.path.join(elsewhere, ".claude.json"),
        )
        self.assertEqual(claude_render_target_path(), self.config_dir_file)


class BuildClaudePlanTargetTest(_HomeEnv):
    def test_defaults_to_render_target_even_with_host_native(self) -> None:
        with open(self.host_native, "w", encoding="utf-8") as fh:
            json.dump({"mcpServers": {}}, fh)
        plan = build_claude_plan([_server("context7")])
        self.assertEqual(plan.config_path, self.config_dir_file)

    def test_injected_config_path_is_honored(self) -> None:
        target = os.path.join(self.home, "injected", ".claude.json")
        plan = build_claude_plan([_server("context7")], config_path=target)
        self.assertEqual(plan.config_path, target)


class WriteTargetTest(_HomeEnv):
    def test_write_lands_in_config_dir_and_not_host_native(self) -> None:
        with open(self.host_native, "w", encoding="utf-8") as fh:
            json.dump({"mcpServers": {"manual": {"command": "x"}}, "k": 1}, fh)
        host_before = Path(self.host_native).read_text(encoding="utf-8")

        plan = build_claude_plan([_server("context7")])
        write_claude(plan)

        # The boxa- entry is in the config-dir file the Container reads.
        self.assertTrue(os.path.isfile(self.config_dir_file))
        with open(self.config_dir_file, encoding="utf-8") as fh:
            written = json.load(fh)
        self.assertIn("boxa-context7", written["mcpServers"])

        # The host's own ~/.claude.json is byte-stable (no boxa- entry).
        self.assertEqual(
            Path(self.host_native).read_text(encoding="utf-8"), host_before
        )
        host_data = json.loads(host_before)
        self.assertNotIn("boxa-context7", host_data["mcpServers"])

    def test_write_touches_only_boxa_keys_in_config_dir(self) -> None:
        os.makedirs(os.path.dirname(self.config_dir_file))
        with open(self.config_dir_file, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "mcpServers": {"manual": {"command": "keep"}},
                    "numAccountSwitches": 7,
                },
                fh,
            )
        plan = build_claude_plan([_server("context7")])
        write_claude(plan)

        with open(self.config_dir_file, encoding="utf-8") as fh:
            data = json.load(fh)
        # Manual entry and unrelated config preserved; boxa- entry added.
        self.assertEqual(data["mcpServers"]["manual"], {"command": "keep"})
        self.assertEqual(data["numAccountSwitches"], 7)
        self.assertIn("boxa-context7", data["mcpServers"])


class MigrationCleanupTest(_HomeEnv):
    """A previous render's boxa- entries in the host-native file are stripped."""

    def test_stale_host_native_boxa_entries_removed_on_render(self) -> None:
        # Host-native ~/.claude.json carries a stale boxa- entry (old render)
        # plus a manual one and an unrelated key.
        with open(self.host_native, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "mcpServers": {
                        "boxa-old": {"command": "boxa-mcp-run", "args": ["old"]},
                        "manual": {"command": "x"},
                    },
                    "numAccountSwitches": 3,
                },
                fh,
            )
        write_claude(build_claude_plan([_server("context7")]))

        with open(self.host_native, encoding="utf-8") as fh:
            host = json.load(fh)
        # Stale boxa- entry gone; manual entry and unrelated key preserved.
        self.assertNotIn("boxa-old", host["mcpServers"])
        self.assertIn("manual", host["mcpServers"])
        self.assertEqual(host["numAccountSwitches"], 3)
        # And the new entry is in the config-dir file, not the host-native one.
        with open(self.config_dir_file, encoding="utf-8") as fh:
            written = json.load(fh)
        self.assertIn("boxa-context7", written["mcpServers"])
        self.assertNotIn("boxa-context7", host["mcpServers"])

    def test_stale_host_native_project_boxa_entries_removed(self) -> None:
        with open(self.host_native, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "projects": {
                        "/p": {
                            "mcpServers": {
                                "boxa-old": {"command": "boxa-mcp-run"},
                                "manual-proj": {"command": "keep"},
                            }
                        }
                    }
                },
                fh,
            )
        write_claude(build_claude_plan([_server("context7")]))

        with open(self.host_native, encoding="utf-8") as fh:
            proj = json.load(fh)["projects"]["/p"]["mcpServers"]
        self.assertNotIn("boxa-old", proj)
        self.assertIn("manual-proj", proj)

    def test_clean_host_native_file_left_byte_stable(self) -> None:
        # A host-native file with NO boxa- entries must not be rewritten.
        with open(self.host_native, "w", encoding="utf-8") as fh:
            json.dump({"mcpServers": {"manual": {"command": "x"}}, "k": 1}, fh)
        before = Path(self.host_native).read_text(encoding="utf-8")
        write_claude(build_claude_plan([_server("context7")]))
        self.assertEqual(Path(self.host_native).read_text(encoding="utf-8"), before)

    def test_no_cleanup_when_target_equals_host_native(self) -> None:
        # When the injected target IS the host-native file (e.g. running in a
        # Container where the paths coincide), the single rewrite handles
        # everything; there is no separate other-file to clean and the file is
        # the normal render output.
        with open(self.host_native, "w", encoding="utf-8") as fh:
            json.dump({"mcpServers": {"boxa-old": {"command": "x"}}}, fh)
        write_claude(
            build_claude_plan([_server("context7")], config_path=self.host_native)
        )
        with open(self.host_native, encoding="utf-8") as fh:
            data = json.load(fh)
        # Normal render replaced the stale boxa- entry with the planned one.
        self.assertNotIn("boxa-old", data["mcpServers"])
        self.assertIn("boxa-context7", data["mcpServers"])


class DiscoveryUnchangedTest(_HomeEnv):
    def test_discovery_default_prefers_host_native_when_present(self) -> None:
        with open(self.host_native, "w", encoding="utf-8") as fh:
            fh.write("{}")
        self.assertEqual(claude_default_config_path(), self.host_native)

    def test_discovery_reads_host_native_servers(self) -> None:
        with open(self.host_native, "w", encoding="utf-8") as fh:
            json.dump({"mcpServers": {"context7": {"command": "npx"}}}, fh)
        provider = ClaudeProvider(config_path=self.host_native)
        servers = provider.discover()
        self.assertEqual([s.name for s in servers], ["context7"])


class CodexRenderTargetUnchangedTest(_HomeEnv):
    def test_codex_render_target_is_codex_config(self) -> None:
        # Codex has no host/Container drift; its target stays the codex config
        # (config.toml), never the Claude .claude.json.
        plan = build_codex_plan([_server("context7")])
        self.assertEqual(plan.config_path, codex_provider.default_config_path())
        self.assertNotEqual(os.path.basename(plan.config_path), ".claude.json")


if __name__ == "__main__":
    unittest.main()
