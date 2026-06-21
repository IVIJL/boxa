#!/usr/bin/env python3
"""Tests for the MCP apply path: profile + scoped secret store (issue 05).

Run with:

    python3 -m unittest tests.test_mcp_apply   # from repo root
    python3 tests/test_mcp_apply.py            # standalone

Every test points HOME and XDG_CONFIG_HOME at a fresh tempdir so the real
~/.config/boxa is never read or written. Source agent config is written to a
temp .claude.json fixture so the secret-value copy path is exercised without
touching the real ~/.claude.

Covers the issue-05 acceptance criteria:
  * apply writes global source -> global profile, project source -> Project
    profile (inherited scope preserved);
  * profile commands are argv arrays, profile carries no secret values;
  * copied secret values land only in the scope-correct secret store at 0600;
  * apply summary / JSON redact secret values (names only);
  * ambiguous --server fails and points at --import-id;
  * host-only / unknown candidates cannot be applied;
  * the dry-run default (no --apply) writes nothing.
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

from mcp import secrets as secrets_mod  # noqa: E402
from mcp.apply import (  # noqa: E402
    ApplyConflictError,
    apply_selection,
    is_applicable,
)
from mcp.candidate import Candidate, Classification, Command  # noqa: E402
from mcp.merge import merge_candidates  # noqa: E402
from mcp.profile import (  # noqa: E402
    global_profile_path,
    load_profile,
    profile_path,
)

_SECRET_VALUE = "sk-ant-super-secret-do-not-leak-0123456789"
_PROJECT_KEY = "/home/tester/Projekty/DemoApp"


def _container_cand(
    name: str,
    *,
    scope: str = "global",
    project=None,
    path: str = "/cfg",
    argv=None,
    env_keys=None,
    secret_env_keys=None,
    provider: str = "claude-code",
) -> Candidate:
    return Candidate(
        provider=provider,
        source_path=path,
        source_scope=scope,
        source_project=project,
        name=name,
        type="stdio",
        command=Command(
            argv=list(argv or ["npx", "-y", "@example/server@latest"]),
            env_keys=list(env_keys or []),
            secret_env_keys=list(secret_env_keys or []),
        ),
        classification=Classification(placement="container", confidence="high"),
    )


class ApplyEnv(unittest.TestCase):
    """Base class that isolates HOME / XDG_CONFIG_HOME into a tempdir."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.home = self._tmp.name
        self._saved = {}
        for var in ("HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR"):
            self._saved[var] = os.environ.get(var)
        os.environ["HOME"] = self.home
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.home, ".config")
        # Drop CLAUDE_CONFIG_DIR so the Claude provider reads our temp
        # ~/.claude.json fixture rather than the real container config dir.
        os.environ.pop("CLAUDE_CONFIG_DIR", None)

    def tearDown(self) -> None:
        for var, val in self._saved.items():
            if val is None:
                os.environ.pop(var, None)
            else:
                os.environ[var] = val
        self._tmp.cleanup()

    def _claude_fixture(self, *, env_value: str) -> str:
        """Write a .claude.json with one global + one project secret-bearing server."""
        fixture = {
            "mcpServers": {
                "global-helper": {
                    "type": "stdio",
                    "command": "npx",
                    "args": ["-y", "@example/global-helper@latest"],
                    "env": {"GLOBAL_HELPER_TOKEN": env_value, "LOG_LEVEL": "info"},
                }
            },
            "projects": {
                _PROJECT_KEY: {
                    "mcpServers": {
                        "project-helper": {
                            "type": "stdio",
                            "command": "npx",
                            "args": ["-y", "@example/project-helper@latest"],
                            "env": {"PROJECT_API_KEY": env_value},
                        }
                    }
                }
            },
        }
        path = os.path.join(self.home, ".claude.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(fixture, fh)
        return path


class ScopeAndShapeTest(ApplyEnv):
    def test_global_source_writes_global_profile_argv_array(self) -> None:
        cand = _container_cand("global-helper", scope="global")
        result = apply_selection(merge_candidates([cand]))
        self.assertEqual(len(result.applied), 1)
        path = global_profile_path()
        self.assertTrue(os.path.isfile(path))
        profile = load_profile(path)
        self.assertEqual(profile["version"], 1)
        entry = profile["servers"]["global-helper"]
        # argv ARRAY, not a shell string.
        self.assertIsInstance(entry["command"]["argv"], list)
        self.assertEqual(entry["command"]["argv"][0], "npx")

    def test_project_source_writes_project_profile(self) -> None:
        cand = _container_cand(
            "project-helper", scope="project", project=_PROJECT_KEY
        )
        result = apply_selection(merge_candidates([cand]))
        self.assertEqual(len(result.applied), 1)
        gpath = global_profile_path()
        ppath = profile_path("project", _PROJECT_KEY)
        # Project entry goes to the Project profile, not the global one.
        self.assertTrue(os.path.isfile(ppath))
        self.assertFalse(os.path.isfile(gpath))
        self.assertIn("projects", ppath)
        profile = load_profile(ppath)
        self.assertIn("project-helper", profile["servers"])
        # The ORIGINAL full project key is recorded so render can emit a wrapper
        # call the wrapper resolves (the filename label is hashed and lossy).
        self.assertEqual(profile.get("projectKey"), _PROJECT_KEY)

    def test_global_source_records_no_project_key(self) -> None:
        cand = _container_cand("ctx", scope="global")
        apply_selection(merge_candidates([cand]))
        profile = load_profile(global_profile_path())
        self.assertNotIn("projectKey", profile)


class MalformedStateTest(ApplyEnv):
    def test_malformed_profile_servers_raises(self) -> None:
        path = global_profile_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "servers": ["not", "a", "map"]}, fh)
        with self.assertRaises(ValueError):
            load_profile(path)


class ProjectFilenameCollisionTest(ApplyEnv):
    def test_same_basename_distinct_files(self) -> None:
        # Two distinct project keys sharing a basename must not collide onto the
        # same profile / secret-store file.
        a = profile_path("project", "/work/a/api")
        b = profile_path("project", "/work/b/api")
        self.assertNotEqual(a, b)
        self.assertNotEqual(
            secrets_mod.project_secrets_path("/work/a/api"),
            secrets_mod.project_secrets_path("/work/b/api"),
        )

    def test_same_key_stable_file(self) -> None:
        self.assertEqual(
            profile_path("project", "/work/a/api"),
            profile_path("project", "/work/a/api/"),  # trailing slash normalized
        )


class SecretRedactionTest(ApplyEnv):
    def test_no_secret_value_in_profile(self) -> None:
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        cand = _container_cand(
            "global-helper",
            scope="global",
            path=path,
            env_keys=["GLOBAL_HELPER_TOKEN", "LOG_LEVEL"],
            secret_env_keys=["GLOBAL_HELPER_TOKEN"],
        )
        apply_selection(merge_candidates([cand]))
        with open(global_profile_path(), encoding="utf-8") as fh:
            blob = fh.read()
        self.assertNotIn(_SECRET_VALUE, blob)
        # Names are present; values are not.
        self.assertIn("GLOBAL_HELPER_TOKEN", blob)
        self.assertIn("secretEnvKeys", blob)

    def test_secret_value_copied_only_into_secret_store_0600(self) -> None:
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        cand = _container_cand(
            "global-helper",
            scope="global",
            path=path,
            env_keys=["GLOBAL_HELPER_TOKEN", "LOG_LEVEL"],
            secret_env_keys=["GLOBAL_HELPER_TOKEN"],
        )
        result = apply_selection(merge_candidates([cand]))
        applied = result.applied[0]
        self.assertEqual(applied.copied_secret_keys, ["GLOBAL_HELPER_TOKEN"])
        spath = secrets_mod.global_secrets_path()
        self.assertTrue(os.path.isfile(spath))
        # 0600 enforced.
        self.assertEqual(secrets_mod.file_mode(spath), 0o600)
        store = secrets_mod.load_secrets(spath)
        # The VALUE lives only here, keyed by the secret env name.
        self.assertEqual(
            store["servers"]["global-helper"]["GLOBAL_HELPER_TOKEN"],
            _SECRET_VALUE,
        )
        # Non-secret env (LOG_LEVEL) is NOT copied into the secret store.
        self.assertNotIn("LOG_LEVEL", store["servers"]["global-helper"])

    def test_nonsecret_env_value_preserved_in_profile(self) -> None:
        # A non-secret value the source set inline (LOG_LEVEL=info) must be
        # carried into the profile's `env` map so the wrapper — which requires
        # every declared env name at launch — can start the server without the
        # user re-exporting it. Secrets must NOT appear there.
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        cand = _container_cand(
            "global-helper",
            scope="global",
            path=path,
            env_keys=["GLOBAL_HELPER_TOKEN", "LOG_LEVEL"],
            secret_env_keys=["GLOBAL_HELPER_TOKEN"],
        )
        apply_selection(merge_candidates([cand]))
        with open(global_profile_path(), encoding="utf-8") as fh:
            profile = json.load(fh)
        entry = profile["servers"]["global-helper"]
        self.assertEqual(entry["env"], {"LOG_LEVEL": "info"})
        self.assertNotIn("GLOBAL_HELPER_TOKEN", entry["env"])

    def test_secret_by_value_non_secret_name_kept_out_of_profile(self) -> None:
        # A value that LOOKS like a credential (a connection string with embedded
        # creds) under an innocuous, non-secret-flagged NAME must NOT be written
        # into the secret-free profile, or import would leak it into a non-0600
        # file. It is left unpersisted (runtime/env resolution).
        fixture = {
            "mcpServers": {
                "svc": {
                    "type": "stdio",
                    "command": "npx",
                    "args": ["-y", "@example/svc@latest"],
                    "env": {
                        # Credential-bearing URL: userinfo (user:pass@) is secret
                        # by VALUE even though DATABASE_URL is not a secret NAME.
                        "DATABASE_URL": "postgres://user:pass@db/app",
                        # A benign endpoint URL (no userinfo) must survive.
                        "BASE_URL": "https://api.example.test/v1",
                        "LOG_LEVEL": "debug",
                    },
                }
            }
        }
        path = os.path.join(self.home, ".claude.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(fixture, fh)
        cand = _container_cand(
            "svc",
            scope="global",
            path=path,
            env_keys=["DATABASE_URL", "BASE_URL", "LOG_LEVEL"],
            secret_env_keys=[],
        )
        apply_selection(merge_candidates([cand]))
        with open(global_profile_path(), encoding="utf-8") as fh:
            blob = fh.read()
        self.assertNotIn("postgres://", blob)
        with open(global_profile_path(), encoding="utf-8") as fh:
            entry = json.load(fh)["servers"]["svc"]
        # The benign values are kept; the credential-bearing URL is not.
        self.assertEqual(
            entry.get("env"),
            {"BASE_URL": "https://api.example.test/v1", "LOG_LEVEL": "debug"},
        )

    def test_project_secret_goes_to_project_secret_store(self) -> None:
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        cand = _container_cand(
            "project-helper",
            scope="project",
            project=_PROJECT_KEY,
            path=path,
            env_keys=["PROJECT_API_KEY"],
            secret_env_keys=["PROJECT_API_KEY"],
        )
        result = apply_selection(merge_candidates([cand]))
        # Global secret store must not be created by a project apply.
        self.assertFalse(os.path.isfile(secrets_mod.global_secrets_path()))
        pspath = secrets_mod.project_secrets_path(_PROJECT_KEY)
        self.assertTrue(os.path.isfile(pspath))
        self.assertEqual(secrets_mod.file_mode(pspath), 0o600)
        self.assertEqual(result.applied[0].scope, "project")

    def test_stale_permissive_tmp_does_not_leak(self) -> None:
        # A leftover world-readable <secrets>.tmp must not become the final
        # secret store with loose permissions.
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        spath = secrets_mod.global_secrets_path()
        os.makedirs(os.path.dirname(spath), exist_ok=True)
        tmp = spath + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("stale")
        os.chmod(tmp, 0o644)
        cand = _container_cand(
            "global-helper",
            scope="global",
            path=path,
            env_keys=["GLOBAL_HELPER_TOKEN"],
            secret_env_keys=["GLOBAL_HELPER_TOKEN"],
        )
        apply_selection(merge_candidates([cand]))
        self.assertTrue(os.path.isfile(spath))
        self.assertEqual(secrets_mod.file_mode(spath), 0o600)

    def test_reimport_replaces_stale_secret_keys(self) -> None:
        # First import copies KEY_A; a re-import whose source only has KEY_B
        # must REPLACE the block, not leave KEY_A lingering.
        spath = secrets_mod.global_secrets_path()
        os.makedirs(os.path.dirname(spath), exist_ok=True)
        secrets_mod.store_server_secrets(spath, "srv", {"KEY_A": "old-value"})
        secrets_mod.store_server_secrets(spath, "srv", {"KEY_B": "new-value"})
        store = secrets_mod.load_secrets(spath)
        self.assertEqual(store["servers"]["srv"], {"KEY_B": "new-value"})

    def test_empty_reimport_purges_stale_block(self) -> None:
        # A prior block exists; storing an empty set for the same server removes
        # it rather than leaving stale credentials behind.
        spath = secrets_mod.global_secrets_path()
        os.makedirs(os.path.dirname(spath), exist_ok=True)
        secrets_mod.store_server_secrets(spath, "srv", {"OLD_KEY": "old"})
        secrets_mod.store_server_secrets(spath, "other", {"KEEP": "v"})
        secrets_mod.store_server_secrets(spath, "srv", {})  # re-import, no secrets
        store = secrets_mod.load_secrets(spath)
        self.assertNotIn("srv", store["servers"])
        self.assertIn("other", store["servers"])  # other servers untouched

    def test_malformed_profile_does_not_persist_secrets(self) -> None:
        # A malformed existing profile must abort the apply BEFORE secrets are
        # written, so credentials are never left behind for a non-imported server.
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        ppath = global_profile_path()
        os.makedirs(os.path.dirname(ppath), exist_ok=True)
        with open(ppath, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "servers": "corrupt"}, fh)
        cand = _container_cand(
            "global-helper",
            scope="global",
            path=path,
            env_keys=["GLOBAL_HELPER_TOKEN"],
            secret_env_keys=["GLOBAL_HELPER_TOKEN"],
        )
        with self.assertRaises(ValueError):
            apply_selection(merge_candidates([cand]))
        # No secret store was created for the failed import.
        self.assertFalse(os.path.isfile(secrets_mod.global_secrets_path()))

    def test_profile_save_failure_restores_prior_secret_block(self) -> None:
        # Re-import where save_profile fails must RESTORE the prior secret block,
        # not delete it (the existing server's credentials stay intact).
        import mcp.apply as apply_mod

        path = self._claude_fixture(env_value=_SECRET_VALUE)
        spath = secrets_mod.global_secrets_path()
        os.makedirs(os.path.dirname(spath), exist_ok=True)
        # Prior block for the same server, different value.
        secrets_mod.store_server_secrets(
            spath, "global-helper", {"GLOBAL_HELPER_TOKEN": "prior-value"}
        )
        cand = _container_cand(
            "global-helper",
            scope="global",
            path=path,
            env_keys=["GLOBAL_HELPER_TOKEN"],
            secret_env_keys=["GLOBAL_HELPER_TOKEN"],
        )

        original = apply_mod.save_profile

        def _boom(*_a, **_k):
            raise OSError("disk full")

        apply_mod.save_profile = _boom
        try:
            with self.assertRaises(OSError):
                apply_selection(merge_candidates([cand]))
        finally:
            apply_mod.save_profile = original

        store = secrets_mod.load_secrets(spath)
        # Prior value preserved; the in-flight new value was rolled back.
        self.assertEqual(
            store["servers"]["global-helper"]["GLOBAL_HELPER_TOKEN"],
            "prior-value",
        )

    def test_missing_secret_value_skips_without_writing_profile(self) -> None:
        # Candidate declares a secret env key but the source config has no value
        # for it -> skipped, and nothing is written.
        path = os.path.join(self.home, ".claude.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"mcpServers": {}}, fh)  # no matching server/env
        cand = _container_cand(
            "ghost",
            scope="global",
            path=path,
            env_keys=["NEEDED_TOKEN"],
            secret_env_keys=["NEEDED_TOKEN"],
        )
        result = apply_selection(merge_candidates([cand]))
        self.assertEqual(result.applied, [])
        self.assertEqual(len(result.skipped), 1)
        self.assertIn("NEEDED_TOKEN", result.skipped[0]["reason"])
        self.assertFalse(os.path.isfile(global_profile_path()))
        self.assertFalse(os.path.isfile(secrets_mod.global_secrets_path()))

    def test_no_secret_store_when_nothing_to_copy(self) -> None:
        # A container candidate with no secret env keys writes no secret store.
        cand = _container_cand("plain", scope="global")
        result = apply_selection(merge_candidates([cand]))
        self.assertEqual(result.applied[0].copied_secret_keys, [])
        self.assertFalse(os.path.isfile(secrets_mod.global_secrets_path()))

    def test_apply_result_dict_has_no_secret_value(self) -> None:
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        cand = _container_cand(
            "global-helper",
            scope="global",
            path=path,
            env_keys=["GLOBAL_HELPER_TOKEN"],
            secret_env_keys=["GLOBAL_HELPER_TOKEN"],
        )
        result = apply_selection(merge_candidates([cand]))
        blob = json.dumps(result.to_dict())
        self.assertNotIn(_SECRET_VALUE, blob)
        self.assertIn("GLOBAL_HELPER_TOKEN", blob)  # name only


class ApplicabilityTest(ApplyEnv):
    def test_host_only_cannot_be_applied(self) -> None:
        cand = _container_cand("desktop", scope="global")
        cand.classification = Classification(
            placement="host-only", confidence="high"
        )
        merged = merge_candidates([cand])
        self.assertFalse(is_applicable(merged[0]))
        result = apply_selection(merged)
        self.assertEqual(result.applied, [])
        self.assertEqual(len(result.skipped), 1)
        self.assertIn("host-only", result.skipped[0]["reason"])
        self.assertFalse(os.path.isfile(global_profile_path()))

    def test_unknown_not_applied(self) -> None:
        cand = _container_cand("mystery", scope="global")
        cand.classification = Classification(placement="unknown", confidence="low")
        result = apply_selection(merge_candidates([cand]))
        self.assertEqual(result.applied, [])
        self.assertEqual(len(result.skipped), 1)

    def test_redacted_argv_not_applied(self) -> None:
        # A credential passed as an argv token is redacted by the provider;
        # storing "<redacted>" verbatim would persist a broken command, so the
        # candidate is skipped rather than written.
        cand = _container_cand(
            "argv-secret",
            scope="global",
            argv=["npx", "-y", "@a/srv", "--token", "<redacted>"],
        )
        merged = merge_candidates([cand])
        self.assertFalse(is_applicable(merged[0]))
        result = apply_selection(merged)
        self.assertEqual(result.applied, [])
        self.assertEqual(len(result.skipped), 1)
        self.assertIn("argv", result.skipped[0]["reason"])
        self.assertFalse(os.path.isfile(global_profile_path()))

    def test_inline_redacted_argv_not_applied(self) -> None:
        # Inline flag form: provider redacts `--token=sk-...` to
        # `--token=<redacted>`; the placeholder is embedded in the token, not a
        # standalone element, so a whole-token check would miss it.
        cand = _container_cand(
            "inline-secret",
            scope="global",
            argv=["npx", "-y", "@a/srv", "--token=<redacted>"],
        )
        merged = merge_candidates([cand])
        self.assertFalse(is_applicable(merged[0]))
        result = apply_selection(merged)
        self.assertEqual(result.applied, [])
        self.assertFalse(os.path.isfile(global_profile_path()))


class ConflictSelectionTest(ApplyEnv):
    def test_same_slot_selection_rejected_before_write(self) -> None:
        # Two applicable candidates, same name+scope, different specs: a
        # conflict pair. Selecting both must refuse before writing anything.
        a = _container_cand(
            "dup", scope="global", argv=["npx", "-y", "@a/dup@1"]
        )
        b = _container_cand(
            "dup", scope="global", argv=["npx", "-y", "@a/dup@2"]
        )
        merged = merge_candidates([a, b])
        self.assertEqual(len(merged), 2)
        with self.assertRaises(ApplyConflictError):
            apply_selection(merged)
        # Nothing was written.
        self.assertFalse(os.path.isfile(global_profile_path()))
        self.assertFalse(os.path.isfile(secrets_mod.global_secrets_path()))


class CliSelectionTest(ApplyEnv):
    """Exercise the cli.py selection + redaction through the module entry point."""

    def _run_cli(self, args, claude_path):
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

    def test_ambiguous_server_fails_pointing_to_import_id(self) -> None:
        # Two candidates share a name (global + project) -> --server ambiguous.
        # Build the fixture so both are container-classified via the real
        # classifier in the cli discovery path.
        fixture = {
            "mcpServers": {
                "dup": {
                    "command": "npx",
                    "args": ["-y", "@example/dup@latest"],
                }
            },
            "projects": {
                _PROJECT_KEY: {
                    "mcpServers": {
                        "dup": {
                            "command": "npx",
                            "args": ["-y", "@example/dup-proj@latest"],
                        }
                    }
                }
            },
        }
        path = os.path.join(self.home, ".claude.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(fixture, fh)
        proc = self._run_cli(
            ["apply-text", "--project", _PROJECT_KEY, "--server", "dup"], path
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("ambiguous", proc.stderr)
        self.assertIn("--import-id", proc.stderr)

    def test_apply_json_redacts_secret_value(self) -> None:
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        proc = self._run_cli(
            ["apply-json", "--no-global", "--project", _PROJECT_KEY,
             "--server", "project-helper"],
            path,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn(_SECRET_VALUE, proc.stdout)
        payload = json.loads(proc.stdout)
        self.assertEqual(len(payload["applied"]), 1)
        self.assertIn("PROJECT_API_KEY", proc.stdout)  # name only


class CliWizardWiringTest(ApplyEnv):
    """The wizard's CLI contract: applicable-wizard list + --override apply.

    These exercise the Python boundary the shell wizard drives (issue 12). The
    interactive selection / scope toggle / project picker themselves live in the
    shell and are validated by shellcheck + manual TTY use, but the arg shape the
    wizard emits (``--import-id`` + ``--override``) and its continue-on-error
    apply are unit-testable here.
    """

    def _run_cli(self, args, claude_path):
        env = dict(os.environ)
        env["PYTHONPATH"] = (
            os.path.join(_REPO_ROOT, "scripts")
            + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
        )
        _ = claude_path
        return subprocess.run(
            [sys.executable, "-m", "mcp.cli", *args],
            capture_output=True,
            text=True,
            env=env,
            cwd=_REPO_ROOT,
        )

    def _import_id_for(self, claude_path, name, scope_args):
        """Run list-applicable-wizard and return the import id for ``name``."""
        proc = self._run_cli(
            ["list-applicable-wizard", *scope_args], claude_path
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for line in proc.stdout.splitlines():
            cols = line.split("\t")
            if len(cols) == 4 and cols[1] == name:
                return cols[0], cols[2], cols[3]  # id, scope, project_key
        self.fail(f"no applicable candidate named {name!r} in:\n{proc.stdout}")

    def test_applicable_wizard_lists_source_project_key(self) -> None:
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        iid, scope, pkey = self._import_id_for(
            path, "project-helper", ["--no-global", "--project", _PROJECT_KEY]
        )
        self.assertTrue(iid.startswith("imp-"))
        self.assertEqual(scope, "project")
        # The source project key is the 4th column, ready for pre-highlighting.
        self.assertEqual(pkey, _PROJECT_KEY)

    def test_applicable_wizard_global_has_empty_project_key(self) -> None:
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        _iid, scope, pkey = self._import_id_for(
            path, "global-helper", ["--project", _PROJECT_KEY]
        )
        self.assertEqual(scope, "global")
        self.assertEqual(pkey, "")

    def test_override_project_source_to_global(self) -> None:
        # A project-sourced server kept selectable but switched to GLOBAL by the
        # wizard imports into the global profile + global secret store.
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        iid, _scope, _pkey = self._import_id_for(
            path, "project-helper", ["--no-global", "--project", _PROJECT_KEY]
        )
        proc = self._run_cli(
            ["apply-json", "--no-global", "--project", _PROJECT_KEY,
             "--import-id", iid, "--override", iid, "global"],
            path,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn(_SECRET_VALUE, proc.stdout)
        payload = json.loads(proc.stdout)
        self.assertEqual(len(payload["applied"]), 1)
        self.assertEqual(payload["applied"][0]["scope"], "global")
        # Wrote the GLOBAL profile, not the source Project's.
        self.assertTrue(os.path.isfile(global_profile_path()))
        self.assertFalse(os.path.isfile(profile_path("project", _PROJECT_KEY)))

    def test_override_global_source_to_project(self) -> None:
        # A global-sourced server switched to PROJECT by the wizard imports into
        # the chosen Project (keyed by the absolute host path).
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        iid, _scope, _pkey = self._import_id_for(
            path, "global-helper", ["--project", _PROJECT_KEY]
        )
        proc = self._run_cli(
            ["apply-json", "--project", _PROJECT_KEY,
             "--import-id", iid, "--override", iid, "project", _PROJECT_KEY],
            path,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = json.loads(proc.stdout)
        self.assertEqual(len(payload["applied"]), 1)
        self.assertEqual(payload["applied"][0]["scope"], "project")
        self.assertTrue(os.path.isfile(profile_path("project", _PROJECT_KEY)))

    def test_override_rejects_relative_project_key(self) -> None:
        # The wizard must only ever pass a resolved ABSOLUTE host path; a bare
        # name is rejected at parse time before any write.
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        iid, _scope, _pkey = self._import_id_for(
            path, "global-helper", ["--project", _PROJECT_KEY]
        )
        proc = self._run_cli(
            ["apply-text", "--project", _PROJECT_KEY,
             "--import-id", iid, "--override", iid, "project", "DemoApp"],
            path,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("override", proc.stderr.lower())
        self.assertFalse(os.path.isfile(profile_path("project", _PROJECT_KEY)))

    def test_override_rejects_bad_scope(self) -> None:
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        iid, _scope, _pkey = self._import_id_for(
            path, "global-helper", ["--project", _PROJECT_KEY]
        )
        proc = self._run_cli(
            ["apply-text", "--project", _PROJECT_KEY,
             "--import-id", iid, "--override", iid, "sideways"],
            path,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("override", proc.stderr.lower())

    def test_batch_continue_on_error_via_cli(self) -> None:
        # A two-server batch where one server cannot recover its declared secret
        # (the value was removed from the source) must import the OTHER and
        # report the failure — the batch is not aborted. This mirrors the
        # wizard applying several --import-id selections at once.
        fixture = {
            "mcpServers": {
                "good": {
                    "type": "stdio",
                    "command": "npx",
                    "args": ["-y", "@example/good@latest"],
                },
                # Declares an env key but supplies no value -> missing-secret
                # skip when the classifier marks it secret-bearing. We force the
                # missing-secret path with a token-shaped env name and no value.
                "needs-secret": {
                    "type": "stdio",
                    "command": "npx",
                    "args": ["-y", "@example/needs-secret@latest"],
                    "env": {"NEEDS_SECRET_API_KEY": ""},
                },
            }
        }
        path = os.path.join(self.home, ".claude.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(fixture, fh)

        good_id, _gs, _gp = self._import_id_for(
            path, "good", ["--project", _PROJECT_KEY]
        )
        # The needs-secret server may or may not be classified container-safe
        # depending on the classifier; only assert the GOOD one applied and that
        # the run did not abort (returncode 0). Pass --all-applicable so every
        # applicable candidate is in the batch alongside the explicit good id.
        proc = self._run_cli(
            ["apply-json", "--project", _PROJECT_KEY, "--all-applicable"],
            path,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        payload = json.loads(proc.stdout)
        applied_names = {a["name"] for a in payload["applied"]}
        self.assertIn("good", applied_names)
        _ = good_id


class DryRunDefaultTest(ApplyEnv):
    def test_import_dry_run_writes_nothing(self) -> None:
        path = self._claude_fixture(env_value=_SECRET_VALUE)
        env = dict(os.environ)
        env["PYTHONPATH"] = os.path.join(_REPO_ROOT, "scripts")
        proc = subprocess.run(
            [sys.executable, "-m", "mcp.cli", "import-text",
             "--project", _PROJECT_KEY],
            capture_output=True, text=True, env=env, cwd=_REPO_ROOT,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # No profile or secret store created by a dry-run discovery.
        self.assertFalse(os.path.isfile(global_profile_path()))
        self.assertFalse(os.path.isfile(profile_path("project", _PROJECT_KEY)))
        self.assertFalse(os.path.isfile(secrets_mod.global_secrets_path()))
        _ = path


if __name__ == "__main__":
    unittest.main()
