#!/usr/bin/env python3
"""Unit tests for the provider-neutral MCP candidate model (ADR 0013, issue 01).

Run with:

    python3 -m unittest tests.test_mcp_candidate   # from repo root
    python3 tests/test_mcp_candidate.py            # standalone

Covers:
  * the candidate shape carries every ADR 0013 / local-plan-mcp.md field;
  * env key names round-trip and no secret *values* are ever stored;
  * the empty-JSON contract for `import` and `list --inherited`;
  * classification placement / confidence validation.
"""

from __future__ import annotations

import json
import os
import sys
import unittest

# Put scripts/ on the path so `import mcp` resolves to the package under test,
# mirroring how scripts/mcp-cli.sh sets PYTHONPATH.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp import (  # noqa: E402
    SCHEMA_VERSION,
    Candidate,
    Classification,
    Command,
    import_result,
    inherited_list_result,
)
from mcp import cli as mcp_cli  # noqa: E402


class CandidateShapeTest(unittest.TestCase):
    def test_full_candidate_serializes_all_adr_fields(self) -> None:
        cand = Candidate(
            provider="claude-code",
            source_path="/home/user/.claude/.claude.json",
            source_scope="project",
            source_project="myapp",
            name="context7",
            type="stdio",
            command=Command(
                argv=["npx", "-y", "@upstash/context7-mcp@latest"],
                env_keys=["CONTEXT7_API_KEY", "LOG_LEVEL"],
                secret_env_keys=["CONTEXT7_API_KEY"],
            ),
            classification=Classification(
                placement="container",
                confidence="high",
                reasons=["npx command family", "no absolute host paths"],
            ),
        )
        d = cand.to_dict()
        # Exactly the ADR 0013 / local-plan-mcp.md slice-1 field set.
        self.assertEqual(
            set(d.keys()),
            {
                "provider",
                "sourcePath",
                "sourceScope",
                "sourceProject",
                "name",
                "type",
                "command",
                "classification",
            },
        )
        self.assertEqual(
            set(d["command"].keys()),
            {"argv", "envKeys", "secretEnvKeys"},
        )
        self.assertEqual(
            set(d["classification"].keys()),
            {"placement", "confidence", "reasons"},
        )
        self.assertEqual(d["command"]["argv"][0], "npx")
        self.assertEqual(d["classification"]["placement"], "container")
        self.assertEqual(d["classification"]["confidence"], "high")

    def test_secret_env_keys_are_names_only(self) -> None:
        # The model must be redaction-ready: secret env *keys* are names, and
        # no field can hold a secret value because none is ever accepted.
        cand = Candidate(
            provider="codex",
            source_path="/home/user/.codex/config.toml",
            source_scope="global",
            name="task-master-ai",
            command=Command(
                env_keys=["ANTHROPIC_API_KEY"],
                secret_env_keys=["ANTHROPIC_API_KEY"],
            ),
        )
        # The model has no field that accepts a secret value, so a value
        # cannot be stored even by mistake. Assert structurally: env keys hold
        # names, and no key is shaped like a typical secret value.
        self.assertIn("ANTHROPIC_API_KEY", cand.command.secret_env_keys)
        self.assertIn("ANTHROPIC_API_KEY", cand.command.env_keys)
        for key in cand.command.env_keys + cand.command.secret_env_keys:
            self.assertNotIn("sk-ant-", key)
            self.assertEqual(key, key.upper().replace("-", "_").replace(" ", ""))

    def test_defaults_are_unclassified_and_empty(self) -> None:
        cand = Candidate(
            provider="claude-code",
            source_path="/x",
            source_scope="global",
            name="srv",
        )
        d = cand.to_dict()
        self.assertIsNone(d["sourceProject"])
        self.assertIsNone(d["type"])
        self.assertEqual(d["command"]["argv"], [])
        self.assertEqual(d["classification"]["placement"], "unknown")
        self.assertIsNone(d["classification"]["confidence"])
        self.assertEqual(d["classification"]["reasons"], [])

    def test_invalid_placement_rejected(self) -> None:
        with self.assertRaises(ValueError):
            Classification(placement="nonsense")

    def test_invalid_confidence_rejected(self) -> None:
        with self.assertRaises(ValueError):
            Classification(placement="container", confidence="certain")


class EmptyJsonContractTest(unittest.TestCase):
    def test_import_result_empty_envelope(self) -> None:
        env = import_result([])
        self.assertEqual(env["version"], SCHEMA_VERSION)
        self.assertEqual(env["candidates"], [])
        # Must serialize cleanly.
        json.dumps(env)

    def test_inherited_list_result_empty_envelope(self) -> None:
        env = inherited_list_result([])
        self.assertEqual(env["version"], SCHEMA_VERSION)
        self.assertEqual(env["inherited"], [])
        json.dumps(env)

    def test_import_result_with_candidate(self) -> None:
        cand = Candidate(
            provider="claude-code",
            source_path="/x",
            source_scope="global",
            name="srv",
        )
        env = import_result([cand])
        self.assertEqual(len(env["candidates"]), 1)
        self.assertEqual(env["candidates"][0]["name"], "srv")


class CliEntryPointTest(unittest.TestCase):
    def test_import_json_command(self) -> None:
        self.assertEqual(mcp_cli.main(["import-json"]), 0)

    def test_list_inherited_json_command(self) -> None:
        self.assertEqual(mcp_cli.main(["list-inherited-json"]), 0)

    def test_unknown_command_returns_2(self) -> None:
        self.assertEqual(mcp_cli.main(["bogus"]), 2)

    def test_missing_command_returns_2(self) -> None:
        self.assertEqual(mcp_cli.main([]), 2)


if __name__ == "__main__":
    unittest.main()
