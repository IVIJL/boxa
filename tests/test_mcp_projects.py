#!/usr/bin/env python3
"""Tests for the boxa-project resolver + apply scope override (issue 11).

Run with:

    PYTHONPATH=scripts python3 -m unittest tests.test_mcp_projects

Two units under test:

  * ``mcp.projects`` — the enumerator that intersects Claude project records with
    existing ``boxa-<name>-history`` marker volumes (matched by ADR 0005
    sanitized basename), carries the absolute host path, and surfaces collisions.
    The docker volume probe is INJECTED via a stub ``VolumeProbe`` subclass so no
    real ``docker`` is ever invoked.
  * ``mcp.apply`` scope override — applying a candidate to an explicit scope that
    overrides its inherited one, with scoped secrets following the chosen scope,
    plus the post-override slot-conflict guard. HOME / XDG_CONFIG_HOME point at a
    fresh tempdir so the real ~/.config/boxa state is never touched.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp.apply import (  # noqa: E402
    ApplyConflictError,
    ScopeOverride,
    apply_candidate,
    apply_selection,
)
from mcp.candidate import Candidate, Classification, Command  # noqa: E402
from mcp.merge import MergedCandidate, compute_import_id  # noqa: E402
from mcp.profile import (  # noqa: E402
    global_profile_path,
    load_profile,
    project_profile_path,
)
from mcp.projects import (  # noqa: E402
    VolumeProbe,
    enumerate_project_targets,
    project_volume_name,
    sanitize_basename,
)
from mcp.secrets import (  # noqa: E402
    global_secrets_path,
    load_secrets,
    project_secrets_path,
)


# -- enumerator stubs ---------------------------------------------------------


class _StubClaude:
    """Stand-in for ClaudeProvider exposing only project_keys()."""

    def __init__(self, keys):
        self._keys = list(keys)

    def project_keys(self):
        return list(self._keys)


class _StubProbe(VolumeProbe):
    """Volume probe backed by a fixed set of names; never calls real docker."""

    def __init__(self, existing):
        super().__init__()
        self._existing = set(existing)
        self.queried: list[str] = []

    def exists(self, volume_name: str) -> bool:
        self.queried.append(volume_name)
        return volume_name in self._existing


# -- sanitizer parity ---------------------------------------------------------


class SanitizeBasenameTest(unittest.TestCase):
    def test_matches_adr_0005_ldh_rule(self):
        # Mirrors `boxa::sanitize`: runs of non-LDH collapse to one dash,
        # leading/trailing dashes trimmed, CASE PRESERVED.
        self.assertEqual(sanitize_basename("My_Project.Name"), "My-Project-Name")
        self.assertEqual(sanitize_basename("résumé-app"), "r-sum-app")
        self.assertEqual(sanitize_basename("--edge--"), "edge")
        self.assertEqual(sanitize_basename("a  b___c"), "a-b-c")
        self.assertEqual(sanitize_basename("plain"), "plain")

    def test_project_volume_name(self):
        self.assertEqual(project_volume_name("DemoApp"), "boxa-DemoApp-history")


# -- enumerator ---------------------------------------------------------------


class EnumerateProjectTargetsTest(unittest.TestCase):
    def test_excludes_records_without_a_volume(self):
        # Two Claude records; only one has a boxa-<name>-history volume.
        claude = _StubClaude(
            ["/home/u/Projekty/HasVol", "/home/u/Projekty/NoVol"]
        )
        probe = _StubProbe(["boxa-HasVol-history"])
        result = enumerate_project_targets(claude, probe)
        self.assertEqual(
            [t.name for t in result.targets], ["HasVol"]
        )
        self.assertEqual(result.collisions, [])

    def test_target_carries_name_and_absolute_path(self):
        claude = _StubClaude(["/home/u/Projekty/App"])
        probe = _StubProbe(["boxa-App-history"])
        result = enumerate_project_targets(claude, probe)
        self.assertEqual(len(result.targets), 1)
        target = result.targets[0]
        self.assertEqual(target.name, "App")
        self.assertEqual(target.project_key, "/home/u/Projekty/App")

    def test_basename_collision_reported_not_merged(self):
        # Two distinct host paths sanitize to the same name "api".
        claude = _StubClaude(["/work/a/api", "/work/b/api"])
        # Even if a volume exists, a collision cannot be disambiguated.
        probe = _StubProbe(["boxa-api-history"])
        result = enumerate_project_targets(claude, probe)
        self.assertEqual(result.targets, [])
        self.assertEqual(len(result.collisions), 1)
        collision = result.collisions[0]
        self.assertEqual(collision.name, "api")
        self.assertEqual(
            collision.project_keys, ["/work/a/api", "/work/b/api"]
        )

    def test_probe_is_only_seam_to_docker(self):
        # The stub probe records every queried volume name; the test passes
        # without any real docker being available, proving injection works.
        claude = _StubClaude(["/home/u/Projekty/App"])
        probe = _StubProbe([])
        result = enumerate_project_targets(claude, probe)
        self.assertEqual(result.targets, [])
        self.assertEqual(probe.queried, ["boxa-App-history"])

    def test_duplicate_keys_not_a_self_collision(self):
        claude = _StubClaude(
            ["/home/u/Projekty/App", "/home/u/Projekty/App"]
        )
        probe = _StubProbe(["boxa-App-history"])
        result = enumerate_project_targets(claude, probe)
        self.assertEqual([t.name for t in result.targets], ["App"])
        self.assertEqual(result.collisions, [])

    def test_trailing_slash_normalized(self):
        claude = _StubClaude(["/home/u/Projekty/App/"])
        probe = _StubProbe(["boxa-App-history"])
        result = enumerate_project_targets(claude, probe)
        self.assertEqual(result.targets[0].project_key, "/home/u/Projekty/App/")
        self.assertEqual(result.targets[0].name, "App")

    def test_sorted_output(self):
        claude = _StubClaude(
            ["/home/u/Zeta", "/home/u/Alpha", "/home/u/Mid"]
        )
        probe = _StubProbe(
            ["boxa-Zeta-history", "boxa-Alpha-history", "boxa-Mid-history"]
        )
        result = enumerate_project_targets(claude, probe)
        self.assertEqual(
            [t.name for t in result.targets], ["Alpha", "Mid", "Zeta"]
        )

    def test_default_probe_is_constructed_when_omitted(self):
        # When no probe is passed, a real VolumeProbe is built; with no docker
        # the OSError path returns "no volume" and the target set is empty.
        claude = _StubClaude(["/home/u/Projekty/App"])
        result = enumerate_project_targets(
            claude, VolumeProbe(docker_bin="/nonexistent/docker-bin-xyz")
        )
        self.assertEqual(result.targets, [])


# -- apply scope override -----------------------------------------------------


def _candidate(
    *,
    scope,
    project=None,
    name="ctx7",
    argv=None,
    env_keys=None,
    secret_env_keys=None,
    placement="container",
    source_path=None,
):
    cmd = Command(
        argv=argv or ["npx", "-y", "@scope/ctx7"],
        env_keys=env_keys or [],
        secret_env_keys=secret_env_keys or [],
    )
    cand = Candidate(
        provider="claude-code",
        source_path=source_path or "",
        source_scope=scope,
        name=name,
        source_project=project,
        type="stdio",
        command=cmd,
        classification=Classification(placement=placement),
    )
    return MergedCandidate(candidate=cand, import_id=compute_import_id(cand))


class ApplyEnv(unittest.TestCase):
    """Isolate HOME / XDG_CONFIG_HOME and provide a source claude.json."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self._saved = {}
        for var in ("HOME", "XDG_CONFIG_HOME"):
            self._saved[var] = os.environ.get(var)
        os.environ["HOME"] = self.home
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.home, ".config")

    def tearDown(self):
        for var, val in self._saved.items():
            if val is None:
                os.environ.pop(var, None)
            else:
                os.environ[var] = val
        self._tmp.cleanup()

    def _write_claude_source(self, *, scope, project, name, env):
        """Write a minimal .claude.json so read_secret_values can recover env."""
        path = os.path.join(self.home, "source.claude.json")
        if scope == "project":
            data = {
                "projects": {
                    project: {"mcpServers": {name: {"command": "npx", "env": env}}}
                }
            }
        else:
            data = {"mcpServers": {name: {"command": "npx", "env": env}}}
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        return path


class ScopeOverrideTest(ApplyEnv):
    def test_project_source_to_global_writes_global_profile_and_secret(self):
        src = self._write_claude_source(
            scope="project",
            project="/home/u/Projekty/App",
            name="ctx7",
            env={"CTX7_API_KEY": "sk-secret-value-123456789012345"},
        )
        m = _candidate(
            scope="project",
            project="/home/u/Projekty/App",
            name="ctx7",
            env_keys=["CTX7_API_KEY"],
            secret_env_keys=["CTX7_API_KEY"],
            source_path=src,
        )
        applied = apply_candidate(m, ScopeOverride(scope="global"))

        self.assertEqual(applied.scope, "global")
        self.assertEqual(applied.project_key, "")
        self.assertEqual(applied.profile_path, global_profile_path())
        # Profile entry landed in the GLOBAL profile.
        profile = load_profile(global_profile_path())
        self.assertIn("ctx7", profile["servers"])
        # Secret value copied into the GLOBAL secret store (not the project one).
        gstore = load_secrets(global_secrets_path())
        self.assertEqual(
            gstore["servers"]["ctx7"]["CTX7_API_KEY"],
            "sk-secret-value-123456789012345",
        )
        # The project secret store was never created.
        self.assertFalse(
            os.path.exists(project_secrets_path("/home/u/Projekty/App"))
        )

    def test_global_source_to_project_writes_project_profile_and_secret(self):
        src = self._write_claude_source(
            scope="global",
            project=None,
            name="ctx7",
            env={"CTX7_API_KEY": "sk-global-secret-1234567890123456"},
        )
        m = _candidate(
            scope="global",
            project=None,
            name="ctx7",
            env_keys=["CTX7_API_KEY"],
            secret_env_keys=["CTX7_API_KEY"],
            source_path=src,
        )
        target_key = "/home/u/Projekty/App"
        applied = apply_candidate(
            m, ScopeOverride(scope="project", project_key=target_key)
        )

        self.assertEqual(applied.scope, "project")
        self.assertEqual(applied.project_key, target_key)
        self.assertEqual(applied.profile_path, project_profile_path(target_key))
        profile = load_profile(project_profile_path(target_key))
        self.assertIn("ctx7", profile["servers"])
        # The profile records the FULL absolute key so render can wrap it.
        self.assertEqual(profile["projectKey"], target_key)
        # Secret landed in THAT project's store, not the global one.
        pstore = load_secrets(project_secrets_path(target_key))
        self.assertEqual(
            pstore["servers"]["ctx7"]["CTX7_API_KEY"],
            "sk-global-secret-1234567890123456",
        )
        self.assertFalse(os.path.exists(global_secrets_path()))

    def test_no_override_is_byte_for_byte_inherited(self):
        # Apply the SAME project candidate twice — once with no override, once
        # via the override path with scope="project"+source key — and assert the
        # resulting profile + secret files are identical.
        src = self._write_claude_source(
            scope="project",
            project="/home/u/Projekty/App",
            name="ctx7",
            env={"CTX7_API_KEY": "sk-inherited-9876543210987654321"},
        )

        def build():
            return _candidate(
                scope="project",
                project="/home/u/Projekty/App",
                name="ctx7",
                env_keys=["CTX7_API_KEY"],
                secret_env_keys=["CTX7_API_KEY"],
                source_path=src,
            )

        # Baseline: no override.
        applied_default = apply_candidate(build())
        prof_default = load_profile(
            project_profile_path("/home/u/Projekty/App")
        )
        sec_default = load_secrets(
            project_secrets_path("/home/u/Projekty/App")
        )

        # Override that names the SAME inherited scope+key must be identical.
        applied_override = apply_candidate(
            build(),
            ScopeOverride(scope="project", project_key="/home/u/Projekty/App"),
        )
        prof_override = load_profile(
            project_profile_path("/home/u/Projekty/App")
        )
        sec_override = load_secrets(
            project_secrets_path("/home/u/Projekty/App")
        )

        self.assertEqual(applied_default.to_dict(), applied_override.to_dict())
        self.assertEqual(prof_default, prof_override)
        self.assertEqual(sec_default, sec_override)

    def test_post_override_slot_conflict_rejected_without_writing(self):
        # Two distinct global candidates, each overridden to the SAME project +
        # name, collide on the post-override slot and must be refused.
        src = self._write_claude_source(
            scope="global", project=None, name="ctx7", env={}
        )
        a = _candidate(
            scope="global", name="ctx7", argv=["npx", "a"], source_path=src
        )
        b = _candidate(
            scope="global", name="ctx7", argv=["npx", "b"], source_path=src
        )
        target = "/home/u/Projekty/App"
        overrides = {
            a.import_id: ScopeOverride(scope="project", project_key=target),
            b.import_id: ScopeOverride(scope="project", project_key=target),
        }
        with self.assertRaises(ApplyConflictError):
            apply_selection([a, b], overrides)
        # Nothing written.
        self.assertFalse(os.path.exists(project_profile_path(target)))

    def test_override_via_selection_applies(self):
        src = self._write_claude_source(
            scope="project",
            project="/home/u/Projekty/App",
            name="ctx7",
            env={},
        )
        m = _candidate(
            scope="project",
            project="/home/u/Projekty/App",
            name="ctx7",
            source_path=src,
        )
        result = apply_selection(
            [m], {m.import_id: ScopeOverride(scope="global")}
        )
        self.assertEqual(len(result.applied), 1)
        self.assertEqual(result.applied[0].scope, "global")
        self.assertIn("ctx7", load_profile(global_profile_path())["servers"])


class ScopeOverrideValidationTest(unittest.TestCase):
    def test_invalid_scope_rejected(self):
        with self.assertRaises(ValueError):
            ScopeOverride(scope="bogus")

    def test_project_scope_requires_key(self):
        with self.assertRaises(ValueError):
            ScopeOverride(scope="project")

    def test_project_scope_with_key_ok(self):
        ov = ScopeOverride(scope="project", project_key="/x/y")
        self.assertEqual(ov.project_key, "/x/y")

    def test_project_scope_rejects_relative_key(self):
        # A bare display name (relative) must be rejected: render uses the key as
        # Claude's absolute `projects` map key, so a relative value never matches.
        with self.assertRaises(ValueError):
            ScopeOverride(scope="project", project_key="App")


if __name__ == "__main__":
    unittest.main()
