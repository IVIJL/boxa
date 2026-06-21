#!/usr/bin/env python3
"""Tests for provider merge + stable import IDs (issue 03).

Run with:

    python3 -m unittest tests.test_mcp_merge   # from repo root
    python3 tests/test_mcp_merge.py            # standalone

Fixture-based: builds `Candidate`s in memory (no live config) so the merge and
conflict semantics are exercised deterministically. Covers the issue-03
acceptance criteria:

  * every merged candidate has a stable, secret-free ``importId``;
  * identical candidates from two providers merge into one result that retains
    every contributing provider in metadata;
  * same name+scope with a different spec is reported as a conflict and the two
    candidates remain distinguishable by import ID;
  * import IDs are stable across runs and appear in JSON output.
"""

from __future__ import annotations

import json
import os
import sys
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp import import_result  # noqa: E402
from mcp.candidate import Candidate, Command  # noqa: E402
from mcp.merge import compute_import_id, merge_candidates  # noqa: E402

_SECRET = "sk-ant-do-not-leak-this-value"


def _cand(
    provider: str,
    name: str,
    *,
    scope: str = "global",
    project=None,
    path: str = "/cfg",
    argv=None,
    env_keys=None,
    secret_env_keys=None,
    ctype="stdio",
) -> Candidate:
    return Candidate(
        provider=provider,
        source_path=path,
        source_scope=scope,
        source_project=project,
        name=name,
        type=ctype,
        command=Command(
            argv=list(argv or []),
            env_keys=list(env_keys or []),
            secret_env_keys=list(secret_env_keys or []),
        ),
    )


class ImportIdTest(unittest.TestCase):
    def test_import_id_present_and_prefixed(self) -> None:
        cand = _cand("claude-code", "context7", argv=["npx", "ctx"])
        iid = compute_import_id(cand)
        self.assertTrue(iid.startswith("imp-"))
        self.assertGreater(len(iid), len("imp-"))

    def test_import_id_stable_across_runs(self) -> None:
        a = _cand("claude-code", "context7", argv=["npx", "ctx"], env_keys=["A", "B"])
        b = _cand("claude-code", "context7", argv=["npx", "ctx"], env_keys=["A", "B"])
        self.assertEqual(compute_import_id(a), compute_import_id(b))

    def test_import_id_independent_of_provider_and_path(self) -> None:
        # The same logical server discovered by different providers / from
        # different files must share an import ID so it can merge.
        a = _cand("claude-code", "context7", argv=["npx", "ctx"], path="/a")
        b = _cand("codex", "context7", argv=["npx", "ctx"], path="/b")
        self.assertEqual(compute_import_id(a), compute_import_id(b))

    def test_import_id_changes_with_argv(self) -> None:
        a = _cand("claude-code", "context7", argv=["npx", "ctx"])
        b = _cand("claude-code", "context7", argv=["npx", "ctx", "--flag"])
        self.assertNotEqual(compute_import_id(a), compute_import_id(b))

    def test_import_id_env_key_order_insensitive(self) -> None:
        a = _cand("claude-code", "s", env_keys=["A", "B"])
        b = _cand("claude-code", "s", env_keys=["B", "A"])
        self.assertEqual(compute_import_id(a), compute_import_id(b))

    def test_import_id_secret_free(self) -> None:
        # An env VALUE never enters the model, but prove the ID derivation does
        # not somehow incorporate secret material even if a name is secret-ish.
        cand = _cand(
            "claude-code",
            "s",
            argv=["npx", "tool"],
            env_keys=["ANTHROPIC_API_KEY"],
            secret_env_keys=["ANTHROPIC_API_KEY"],
        )
        iid = compute_import_id(cand)
        self.assertNotIn(_SECRET, iid)
        self.assertNotIn("ANTHROPIC_API_KEY", iid)  # hashed, not embedded raw


class MergeTest(unittest.TestCase):
    def test_identical_candidates_merge_with_all_providers(self) -> None:
        claude = _cand("claude-code", "context7", argv=["npx", "ctx"], path="/claude")
        codex = _cand("codex", "context7", argv=["npx", "ctx"], path="/codex")
        merged = merge_candidates([claude, codex])
        self.assertEqual(len(merged), 1)
        m = merged[0]
        self.assertEqual(set(m.providers), {"claude-code", "codex"})
        paths = {s.source_path for s in m.sources}
        self.assertEqual(paths, {"/claude", "/codex"})
        self.assertFalse(m.conflict)

    def test_implicit_stdio_type_merges_with_explicit(self) -> None:
        # Claude records type="stdio"; Codex omits type for the same server.
        # Both mean stdio, so they must merge rather than conflict.
        claude = _cand(
            "claude-code", "context7", argv=["npx", "ctx"], ctype="stdio", path="/c"
        )
        codex = _cand("codex", "context7", argv=["npx", "ctx"], ctype=None, path="/x")
        merged = merge_candidates([claude, codex])
        self.assertEqual(len(merged), 1)
        self.assertFalse(merged[0].conflict)
        self.assertEqual(set(merged[0].providers), {"claude-code", "codex"})

    def test_duplicate_exact_source_deduped(self) -> None:
        a = _cand("claude-code", "context7", argv=["npx", "ctx"], path="/same")
        b = _cand("claude-code", "context7", argv=["npx", "ctx"], path="/same")
        merged = merge_candidates([a, b])
        self.assertEqual(len(merged), 1)
        self.assertEqual(len(merged[0].sources), 1)

    def test_same_name_scope_different_spec_is_conflict(self) -> None:
        a = _cand("claude-code", "context7", argv=["npx", "ctx-v1"])
        b = _cand("codex", "context7", argv=["npx", "ctx-v2"])
        merged = merge_candidates([a, b])
        self.assertEqual(len(merged), 2)
        self.assertTrue(all(m.conflict for m in merged))
        ids = {m.import_id for m in merged}
        self.assertEqual(len(ids), 2)  # distinguishable by import ID
        # Each conflict points at the other's import ID.
        self.assertEqual(merged[0].conflict_with, [merged[1].import_id])
        self.assertEqual(merged[1].conflict_with, [merged[0].import_id])

    def test_different_scope_same_name_not_conflict(self) -> None:
        g = _cand("claude-code", "context7", scope="global", argv=["npx", "x"])
        p = _cand(
            "claude-code",
            "context7",
            scope="project",
            project="/p",
            argv=["npx", "y"],
        )
        merged = merge_candidates([g, p])
        self.assertEqual(len(merged), 2)
        self.assertFalse(any(m.conflict for m in merged))

    def test_env_key_name_difference_is_conflict(self) -> None:
        a = _cand("claude-code", "s", argv=["x"], env_keys=["A_KEY"])
        b = _cand("codex", "s", argv=["x"], env_keys=["B_KEY"])
        merged = merge_candidates([a, b])
        self.assertEqual(len(merged), 2)
        self.assertTrue(all(m.conflict for m in merged))

    def test_deterministic_order(self) -> None:
        cands = [
            _cand("claude-code", "zeta", argv=["a"]),
            _cand("claude-code", "alpha", argv=["b"]),
        ]
        names1 = [m.candidate.name for m in merge_candidates(list(cands))]
        names2 = [m.candidate.name for m in merge_candidates(list(reversed(cands)))]
        self.assertEqual(names1, names2)
        self.assertEqual(names1, ["alpha", "zeta"])

    def test_json_envelope_exposes_import_id_and_providers(self) -> None:
        claude = _cand("claude-code", "context7", argv=["npx", "ctx"], path="/claude")
        codex = _cand("codex", "context7", argv=["npx", "ctx"], path="/codex")
        merged = merge_candidates([claude, codex])
        payload = import_result(merged)
        blob = json.dumps(payload)
        self.assertIn("importId", blob)
        self.assertIn("providers", blob)
        entry = payload["candidates"][0]
        self.assertTrue(entry["importId"].startswith("imp-"))
        self.assertEqual(set(entry["providers"]), {"claude-code", "codex"})
        self.assertEqual(entry["conflict"], False)

    def test_json_conflict_marker_present(self) -> None:
        a = _cand("claude-code", "s", argv=["v1"])
        b = _cand("codex", "s", argv=["v2"])
        payload = import_result(merge_candidates([a, b]))
        for entry in payload["candidates"]:
            self.assertTrue(entry["conflict"])
            self.assertIn("conflictWith", entry)
            self.assertEqual(len(entry["conflictWith"]), 1)


if __name__ == "__main__":
    unittest.main()
