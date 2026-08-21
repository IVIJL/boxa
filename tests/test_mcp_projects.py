#!/usr/bin/env python3
"""Tests for the boxa-project resolver + apply scope override (issue 11).

Run with:

    PYTHONPATH=scripts python3 -m unittest tests.test_mcp_projects

Two units under test:

  * ``mcp.projects`` — the enumerator that intersects the boxa Project registry
    with Claude project records by exact host path, carries the absolute host
    path, and surfaces same-display-name ambiguity without dropping targets.
  * ``mcp.apply`` scope override — applying a candidate to an explicit scope that
    overrides its inherited one, with scoped secrets following the chosen scope,
    plus the post-override slot-conflict guard. HOME / XDG_CONFIG_HOME point at a
    fresh tempdir so the real ~/.config/boxa state is never touched.
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
    enumerate_volume_project_targets,
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
    """Volume probe backed by a fixed set of names; never calls Docker."""

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
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self._tmp.cleanup()

    def _project(self, relative):
        path = os.path.join(self._tmp.name, relative)
        os.makedirs(path)
        return path

    def test_live_host_shape_offers_only_exact_registered_host_path(self):
        host_project = self._project("home/vlcak/Projekty/easyjukebox_api")
        claude = _StubClaude([
            host_project,
            "/workspace/easyjukebox-api",
            os.path.join(self._tmp.name, "home", "vlcak"),
        ])
        registry = {
            host_project: {"name": "easyjukebox-api"},
        }

        result = enumerate_project_targets(claude, registry)

        self.assertEqual(
            [(target.name, target.project_key) for target in result.targets],
            [("easyjukebox-api", host_project)],
        )
        self.assertEqual(result.collisions, [])
        self.assertEqual(result.missing_claude_records, [])

    def test_same_display_name_keeps_both_paths_and_reports_ambiguity(self):
        paths = [self._project("work/a/api"), self._project("work/b/api")]
        registry = {path: {"name": "api"} for path in paths}

        result = enumerate_project_targets(_StubClaude(paths), registry)

        self.assertEqual(
            [target.project_key for target in result.targets], paths
        )
        self.assertEqual(len(result.collisions), 1)
        self.assertEqual(result.collisions[0].name, "api")
        self.assertEqual(result.collisions[0].project_keys, paths)

    def test_registered_path_without_exact_claude_record_is_diagnostic(self):
        project = self._project("work/app")
        registry = {project: {"name": "app"}}
        result = enumerate_project_targets(_StubClaude([project + "/"]), registry)

        self.assertEqual(result.targets, [])
        self.assertEqual(result.missing_claude_records, [project])

    def test_stale_registered_path_is_diagnostic(self):
        project = os.path.join(self._tmp.name, "deleted")
        registry = {project: {"name": "deleted"}}

        result = enumerate_project_targets(_StubClaude([project]), registry)

        self.assertEqual(result.targets, [])
        self.assertEqual(result.stale_projects, [project])

    def test_control_character_project_key_is_diagnostic(self):
        project = self._project("unsafe\tproject")
        registry = {project: {"name": "unsafe"}}

        result = enumerate_project_targets(_StubClaude([project]), registry)

        self.assertEqual(result.targets, [])
        self.assertEqual(result.unsafe_project_keys, [project])

    def test_ignores_invalid_registry_records(self):
        registry = {
            "relative/app": {"name": "app"},
            "/work/no-metadata": "invalid",
            "/work/no-name": {},
        }
        result = enumerate_project_targets(
            _StubClaude(list(registry)), registry
        )
        self.assertEqual(result.targets, [])
        self.assertEqual(result.missing_claude_records, [])

    def test_sorted_output(self):
        paths = [
            self._project("home/u/Zeta"),
            self._project("home/u/Alpha"),
            self._project("home/u/Mid"),
        ]
        registry = {
            path: {"name": path.rsplit("/", 1)[-1]} for path in paths
        }
        result = enumerate_project_targets(_StubClaude(paths), registry)
        self.assertEqual(
            [t.name for t in result.targets], ["Alpha", "Mid", "Zeta"]
        )

    def test_project_targets_json_uses_the_same_path_based_enumeration(self):
        with tempfile.TemporaryDirectory() as tmp:
            claude_dir = os.path.join(tmp, "claude")
            registry_dir = os.path.join(tmp, "config", "boxa")
            os.makedirs(claude_dir)
            os.makedirs(registry_dir)
            paths = [
                os.path.join(tmp, "work", "a", "api"),
                os.path.join(tmp, "work", "b", "api"),
            ]
            for path in paths:
                os.makedirs(path)
            missing = os.path.join(tmp, "work", "missing")
            os.makedirs(missing)
            stale = os.path.join(tmp, "work", "deleted")
            unsafe = os.path.join(tmp, "work", "unsafe\tproject")
            os.makedirs(unsafe)
            with open(
                os.path.join(claude_dir, ".claude.json"),
                "w",
                encoding="utf-8",
            ) as fh:
                json.dump({"projects": {path: {} for path in paths}}, fh)
            with open(
                os.path.join(registry_dir, "projects.json"),
                "w",
                encoding="utf-8",
            ) as fh:
                json.dump({
                    "version": 1,
                    "projects": {
                        **{path: {"name": "api"} for path in paths},
                        missing: {"name": "missing"},
                        stale: {"name": "deleted"},
                        unsafe: {"name": "unsafe"},
                    },
                }, fh)
            env = dict(
                os.environ,
                CLAUDE_CONFIG_DIR=claude_dir,
                XDG_CONFIG_HOME=os.path.join(tmp, "config"),
                PYTHONPATH=os.path.join(_REPO_ROOT, "scripts"),
            )

            proc = subprocess.run(
                [sys.executable, "-m", "mcp.cli", "project-targets-json"],
                cwd=_REPO_ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            text_proc = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "mcp.cli",
                    "project-targets-text",
                    "--diagnostics",
                ],
                cwd=_REPO_ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = json.loads(proc.stdout)
        self.assertEqual(
            [target["projectKey"] for target in payload["targets"]], paths
        )
        self.assertEqual(payload["collisions"][0]["projectKeys"], paths)
        self.assertEqual(payload["missingClaudeRecords"], [missing])
        self.assertEqual(payload["staleProjects"], [stale])
        self.assertEqual(payload["unsafeProjectKeys"], [unsafe])
        self.assertEqual(text_proc.returncode, 0, text_proc.stderr)
        diagnostic_lines = [
            line for line in text_proc.stdout.splitlines() if "\t" not in line
        ]
        self.assertTrue(any("not an existing directory" in line for line in diagnostic_lines))
        self.assertTrue(any("ASCII protocol delimiter" in line for line in diagnostic_lines))
        self.assertIn(repr(unsafe), text_proc.stdout)


class EnumerateVolumeProjectTargetsTest(unittest.TestCase):
    def test_excludes_records_without_a_volume(self):
        claude = _StubClaude([
            "/home/u/Projekty/HasVol",
            "/home/u/Projekty/NoVol",
        ])
        probe = _StubProbe(["boxa-HasVol-history"])

        result = enumerate_volume_project_targets(claude, probe)

        self.assertEqual([target.name for target in result.targets], ["HasVol"])
        self.assertEqual(result.collisions, [])

    def test_target_carries_name_and_absolute_path(self):
        claude = _StubClaude(["/home/u/Projekty/App"])
        result = enumerate_volume_project_targets(
            claude, _StubProbe(["boxa-App-history"])
        )

        self.assertEqual(
            [(target.name, target.project_key) for target in result.targets],
            [("App", "/home/u/Projekty/App")],
        )

    def test_basename_collision_reported_not_merged(self):
        paths = ["/work/a/api", "/work/b/api"]
        result = enumerate_volume_project_targets(
            _StubClaude(paths), _StubProbe(["boxa-api-history"])
        )

        self.assertEqual(result.targets, [])
        self.assertEqual(result.collisions[0].project_keys, paths)

    def test_duplicate_keys_are_not_a_self_collision(self):
        path = "/home/u/Projekty/App"
        result = enumerate_volume_project_targets(
            _StubClaude([path, path]), _StubProbe(["boxa-App-history"])
        )

        self.assertEqual([target.project_key for target in result.targets], [path])
        self.assertEqual(result.collisions, [])

    def test_trailing_slash_is_preserved_while_basename_is_normalized(self):
        path = "/home/u/Projekty/App/"
        result = enumerate_volume_project_targets(
            _StubClaude([path]), _StubProbe(["boxa-App-history"])
        )

        self.assertEqual(result.targets[0].project_key, path)
        self.assertEqual(result.targets[0].name, "App")

    def test_probe_receives_the_sanitized_volume_name(self):
        probe = _StubProbe([])

        result = enumerate_volume_project_targets(
            _StubClaude(["/home/u/My_App"]), probe
        )

        self.assertEqual(result.targets, [])
        self.assertEqual(probe.queried, ["boxa-My-App-history"])

    def test_probe_failure_yields_no_target(self):
        result = enumerate_volume_project_targets(
            _StubClaude(["/home/u/App"]),
            VolumeProbe(docker_bin="/nonexistent/docker-bin-xyz"),
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
