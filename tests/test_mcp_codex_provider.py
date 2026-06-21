#!/usr/bin/env python3
"""Tests for the conservative Codex MCP discovery provider (issue 03).

Run with:

    python3 -m unittest tests.test_mcp_codex_provider   # from repo root
    python3 tests/test_mcp_codex_provider.py            # standalone

Fixture-based: writes temp ``config.toml`` files so the tests never touch the
real ~/.codex. Covers the issue-03 acceptance criteria:

  * the provider returns cleanly (no error) when no MCP config is present;
  * it does not invent support for an unverified/non-stdio config shape;
  * it parses the verified ``[mcp_servers.<name>]`` stdio shape into
    candidates with secret-safe env handling (NAMES only);
  * a missing or malformed file degrades to "none found" rather than raising.
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
from mcp.merge import merge_candidates  # noqa: E402
from mcp.providers import CodexProvider  # noqa: E402
from mcp.providers.codex import PROVIDER  # noqa: E402

_SECRET = "sk-ant-codex-secret-do-not-leak"


def _write(content: str) -> str:
    fh = tempfile.NamedTemporaryFile(
        mode="w", suffix=".toml", delete=False, encoding="utf-8"
    )
    fh.write(content)
    fh.flush()
    fh.close()
    return fh.name


class CodexProviderTest(unittest.TestCase):
    def setUp(self) -> None:
        self._paths: list[str] = []

    def tearDown(self) -> None:
        for p in self._paths:
            if os.path.isfile(p):
                os.unlink(p)

    def _provider(self, content: str) -> CodexProvider:
        path = _write(content)
        self._paths.append(path)
        return CodexProvider(config_path=path)

    # -- conservative "none found" cases ------------------------------------

    def test_missing_file_yields_none(self) -> None:
        provider = CodexProvider(config_path="/nonexistent/config.toml")
        self.assertEqual(provider.discover(), [])
        self.assertIn("No supported Codex MCP config found", provider.note or "")

    def test_no_mcp_table_yields_none(self) -> None:
        # Mirrors THIS machine's real ~/.codex/config.toml: valid TOML, but no
        # [mcp_servers] table. Must report cleanly, not error.
        provider = self._provider(
            '[tools]\nweb_search = true\n\n[projects."/home/x"]\ntrust = "on"\n'
        )
        self.assertEqual(provider.discover(), [])
        self.assertIn("No supported Codex MCP config found", provider.note or "")

    def test_malformed_toml_yields_none(self) -> None:
        provider = self._provider("[tools\nbroken = ")
        self.assertEqual(provider.discover(), [])
        self.assertIn("No supported Codex MCP config found", provider.note or "")

    def test_no_parser_degrades_cleanly(self) -> None:
        # If no TOML parser is available (Python 3.10 host without tomli), the
        # provider must not raise — it returns no candidates with a clear note.
        # Importing the module must already have succeeded (proven by setUp).
        import mcp.providers.codex as codex_mod

        provider = self._provider(
            '[mcp_servers.context7]\ncommand = "npx"\nargs = ["ctx"]\n'
        )
        saved = codex_mod._toml
        try:
            codex_mod._toml = None
            self.assertEqual(provider.discover(), [])
            self.assertIn("No supported Codex MCP config found", provider.note or "")
            self.assertIn("TOML parser", provider.note or "")
        finally:
            codex_mod._toml = saved

    def test_no_global_skips(self) -> None:
        provider = self._provider(
            '[mcp_servers.context7]\ncommand = "npx"\nargs = ["ctx"]\n'
        )
        self.assertEqual(provider.discover(include_global=False), [])

    # -- does not invent support for unverified shapes ----------------------

    def test_remote_like_table_without_command_skipped(self) -> None:
        # A table with no local `command` (e.g. a url-based / unverified entry)
        # must NOT be guessed into a candidate.
        provider = self._provider(
            '[mcp_servers.remote_thing]\nurl = "https://example.test/mcp"\n'
        )
        self.assertEqual(provider.discover(), [])
        self.assertIn("No supported Codex MCP config found", provider.note or "")

    def test_non_stdio_type_with_command_skipped(self) -> None:
        # A table that has a command but an explicit non-stdio type (http/sse)
        # is an unsupported transport and must be skipped, not surfaced.
        provider = self._provider(
            "[mcp_servers.remote_http]\n"
            'type = "http"\n'
            'command = "some-bridge"\n'
            'args = ["--listen"]\n'
        )
        self.assertEqual(provider.discover(), [])
        self.assertIn("No supported Codex MCP config found", provider.note or "")

    def test_mixed_skips_unverified_keeps_stdio(self) -> None:
        provider = self._provider(
            '[mcp_servers.good]\ncommand = "npx"\nargs = ["-y", "good-mcp"]\n\n'
            '[mcp_servers.remote_thing]\nurl = "https://example.test/mcp"\n'
        )
        cands = provider.discover()
        names = {c.name for c in cands}
        self.assertEqual(names, {"good"})
        self.assertIn("skipped 1", provider.note or "")

    # -- verified stdio shape parsing ---------------------------------------

    def test_parses_stdio_server(self) -> None:
        provider = self._provider(
            "[mcp_servers.context7]\n"
            'command = "npx"\n'
            'args = ["-y", "@upstash/context7-mcp@latest"]\n'
            f'env = {{ CONTEXT7_API_KEY = "{_SECRET}", LOG_LEVEL = "info" }}\n'
        )
        cands = provider.discover()
        self.assertEqual(len(cands), 1)
        c = cands[0]
        self.assertEqual(c.provider, PROVIDER)
        self.assertEqual(c.name, "context7")
        self.assertEqual(c.source_scope, "global")
        self.assertEqual(c.command.argv[0], "npx")
        # Env key NAMES present; secret-looking name flagged.
        self.assertIn("CONTEXT7_API_KEY", c.command.env_keys)
        self.assertIn("LOG_LEVEL", c.command.env_keys)
        self.assertIn("CONTEXT7_API_KEY", c.command.secret_env_keys)
        self.assertNotIn("LOG_LEVEL", c.command.secret_env_keys)

    def test_secret_value_never_emitted(self) -> None:
        provider = self._provider(
            "[mcp_servers.s]\n"
            'command = "npx"\n'
            'args = ["-y", "tool", "--api-key", "' + _SECRET + '"]\n'
            f'env = {{ TOKEN = "{_SECRET}" }}\n'
        )
        cands = provider.discover()
        # Exercise the JSON path too, via the merge pipeline.
        payload = json.dumps(import_result(merge_candidates(cands)))
        self.assertNotIn(_SECRET, payload)
        # argv credential is redacted, not present.
        self.assertNotIn(_SECRET, " ".join(cands[0].command.argv))


if __name__ == "__main__":
    unittest.main()
