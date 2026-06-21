"""Unit tests for root-side secret staging (ADR 0014, issue 16).

These cover the UNIT-TESTABLE parts: the staged basename mapping, the
least-privilege scope filtering (global + THIS Project only, never a foreign
Project), the 0400 file mode, and stale-copy removal. The SECURITY ACCEPTANCE
properties — that the gated source dir is non-traversable as node, that the
staged copy is unreadable as node, and that /proc/<server-pid>/environ is
unreadable cross-UID — are CONTAINER-RUNTIME-ONLY (they need a live container
with the boxa-mcp account and a rebuilt image). They are NOT exercised here;
see the host-side validation TODO in the issue report. The chown to boxa-mcp
is likewise skipped here (unit tests run unprivileged), so these tests pass
``owner_uid=None`` and assert mode + scope only.
"""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(__file__)), "scripts"))

from mcp.profile import _sanitize_project  # noqa: E402
from mcp.staging import (  # noqa: E402
    project_staged_basename,
    stage_secrets,
)


def _write_store(path: str, server: str, values: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"version": 1, "servers": {server: values}}, fh)


class StagedBasenameTests(unittest.TestCase):
    def test_project_basename_matches_sanitizer(self):
        # The staged Project basename MUST equal the broker-derived one (the
        # sanitized+hashed key + .secrets.json) so the broker finds it.
        key = "/home/user/Projekty/boxa"
        self.assertEqual(
            project_staged_basename(key),
            _sanitize_project(key) + ".secrets.json",
        )

    def test_distinct_keys_get_distinct_basenames(self):
        # A basename collision (/work/a/api vs /work/b/api) must NOT collapse to
        # one staged file — different full keys hash differently.
        a = project_staged_basename("/work/a/api")
        b = project_staged_basename("/work/b/api")
        self.assertNotEqual(a, b)


class StageScopeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(self._cleanup)
        self.source = os.path.join(self.tmp, "src")  # mirrors boxa/mcp layout
        self.dest = os.path.join(self.tmp, "staged")
        os.makedirs(self.source)
        os.makedirs(os.path.join(self.source, "projects"))

    def _cleanup(self):
        import shutil

        shutil.rmtree(self.tmp, ignore_errors=True)

    def _global(self):
        return os.path.join(self.source, "secrets.json")

    def _project(self, key):
        return os.path.join(
            self.source, "projects", project_staged_basename(key)
        )

    def test_global_only_when_no_project(self):
        _write_store(self._global(), "srv", {"K": "v"})
        result = stage_secrets(self.source, self.dest, project_key=None)
        staged_files = sorted(os.listdir(self.dest))
        self.assertEqual(staged_files, ["secrets.json"])
        self.assertEqual([s[0] for s in result.staged], ["global"])

    def test_global_and_this_project_staged(self):
        key = "/work/this/proj"
        _write_store(self._global(), "g", {"GK": "gv"})
        _write_store(self._project(key), "p", {"PK": "pv"})
        stage_secrets(self.source, self.dest, project_key=key)
        staged = sorted(os.listdir(self.dest))
        self.assertEqual(
            staged, sorted(["secrets.json", project_staged_basename(key)])
        )

    def test_foreign_project_never_staged(self):
        # A Container for project A must NEVER stage project B's secrets, even
        # though both files exist at the source.
        this_key = "/work/a/proj"
        other_key = "/work/b/proj"
        _write_store(self._global(), "g", {"GK": "gv"})
        _write_store(self._project(this_key), "p", {"PK": "pv"})
        _write_store(self._project(other_key), "x", {"XK": "xv"})
        stage_secrets(self.source, self.dest, project_key=this_key)
        staged = set(os.listdir(self.dest))
        self.assertIn("secrets.json", staged)
        self.assertIn(project_staged_basename(this_key), staged)
        self.assertNotIn(project_staged_basename(other_key), staged)

    def test_staged_file_is_0400(self):
        _write_store(self._global(), "srv", {"K": "v"})
        stage_secrets(self.source, self.dest, project_key=None)
        mode = stat.S_IMODE(
            os.stat(os.path.join(self.dest, "secrets.json")).st_mode
        )
        self.assertEqual(mode, 0o400)

    def test_staged_content_round_trips(self):
        _write_store(self._global(), "srv", {"K": "v"})
        stage_secrets(self.source, self.dest, project_key=None)
        with open(os.path.join(self.dest, "secrets.json"), encoding="utf-8") as fh:
            data = json.load(fh)
        self.assertEqual(data["servers"]["srv"], {"K": "v"})

    def test_absent_global_is_not_an_error(self):
        # No global store -> staged nothing, recorded as a benign absence.
        result = stage_secrets(self.source, self.dest, project_key=None)
        self.assertEqual(result.staged, [])
        self.assertIn("global", result.skipped_absent)
        self.assertEqual(os.listdir(self.dest), [])

    def test_stale_in_scope_copy_removed_when_source_gone(self):
        # A previously-staged global file is removed when the source store is no
        # longer present (rotation that deleted all global secrets).
        os.makedirs(self.dest)
        with open(os.path.join(self.dest, "secrets.json"), "w") as fh:
            fh.write("{}")
        result = stage_secrets(self.source, self.dest, project_key=None)
        self.assertNotIn("secrets.json", os.listdir(self.dest))
        self.assertIn("secrets.json", result.removed_stale)

    def test_out_of_scope_staged_file_swept(self):
        # A leftover foreign-Project staged file (e.g. the Container was
        # restarted for a different Project) is swept out of the private store.
        this_key = "/work/a/proj"
        foreign = project_staged_basename("/work/b/proj")
        _write_store(self._global(), "g", {"GK": "gv"})
        _write_store(self._project(this_key), "p", {"PK": "pv"})
        os.makedirs(self.dest)
        with open(os.path.join(self.dest, foreign), "w") as fh:
            fh.write("{}")
        result = stage_secrets(self.source, self.dest, project_key=this_key)
        self.assertNotIn(foreign, os.listdir(self.dest))
        self.assertIn(foreign, result.removed_stale)

    def test_restage_overwrites_in_place(self):
        # A second staging pass with a changed source overwrites the staged copy
        # (issue 17 reload re-stages); the new value wins and mode stays 0400.
        _write_store(self._global(), "srv", {"K": "old"})
        stage_secrets(self.source, self.dest, project_key=None)
        _write_store(self._global(), "srv", {"K": "new"})
        stage_secrets(self.source, self.dest, project_key=None)
        with open(os.path.join(self.dest, "secrets.json"), encoding="utf-8") as fh:
            data = json.load(fh)
        self.assertEqual(data["servers"]["srv"], {"K": "new"})
        mode = stat.S_IMODE(
            os.stat(os.path.join(self.dest, "secrets.json")).st_mode
        )
        self.assertEqual(mode, 0o400)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
