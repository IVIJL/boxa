#!/usr/bin/env python3
"""The verified immutable Codex runtime copy (ADR 0037, issue 05).

Run with:

    PYTHONPATH=scripts python3 -m unittest tests.test_jobs_runtime   # repo root
    python3 tests/test_jobs_runtime.py                               # standalone

No test here spends money and none of them touches the real versions volume:
every test builds a FAKE ``@openai/codex`` package tree in a temp dir whose
vendor "static binary" is a shell script that answers ``--version`` and cats
one of the recorded event streams in ``tests/fixtures/jobs/``
(``codex-done.jsonl`` + ``codex-resume-done.jsonl`` are one matched real
thread, so thread continuity is proven against a real stream shape).  The
sources, the versions root and the probe are all env-overridable for exactly
this reason.

What is load-bearing here:

  * a source that changes during the copy (the ``npm install`` race) discards
    the temp dir and publishes NOTHING — the previous verified copy stays in
    use;
  * so does a copy whose content does not hash-match its source, and a copy
    whose probe fails; the probe failure is a loud warning, never a broken
    Job;
  * with no verified copy at all a Codex job is REFUSED
    (``no-verified-runtime``), because the alternative — running from the
    mutable npm volume — is the failure ADR 0037 exists to prevent;
  * the fast path costs nothing: newest found == newest verified means no
    manifest, no copy and above all no probe;
  * ``runtime use`` pins a verified copy and beats "newest wins";
  * the publish ``flock`` serializes Containers sharing the volume: a second
    publisher waits and then finds the version already there, so exactly one
    copy is ever published.
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from contextlib import redirect_stdout
from unittest import mock

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from jobs import cli as jobs_cli  # noqa: E402
from jobs import codex as jobs_codex  # noqa: E402
from jobs import identity as jobs_identity  # noqa: E402
from jobs import runtime as jobs_runtime  # noqa: E402

FIXTURES = os.path.join(_REPO_ROOT, "tests", "fixtures", "jobs")
PROJECT_KEY = "/home/node/Projekty/runtime-test"
MODEL = "gpt-5.6-luna"
EFFORT = "low"


def fixture(name: str) -> str:
    return os.path.join(FIXTURES, name)


def make_package(root: str, version: str) -> str:
    """A fake ``@openai/codex`` package tree whose binary behaves like Codex.

    Same shape as the real npm package (``package.json``, ``bin/codex.js``,
    the nested platform package with ``vendor/<triple>/bin/codex`` plus its
    ``codex-path``/``codex-resources`` siblings), so the copy, the manifest,
    the hash check and the binary path resolution all run over a realistic
    tree.
    """
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, "package.json"), "w", encoding="utf-8") as fh:
        json.dump({"name": "@openai/codex", "version": version}, fh)
    os.makedirs(os.path.join(root, "bin"), exist_ok=True)
    with open(os.path.join(root, "bin", "codex.js"), "w", encoding="utf-8") as fh:
        fh.write("// fake node entry point\n")
    binary = jobs_runtime.package_binary(root)
    vendor = os.path.dirname(os.path.dirname(binary))
    os.makedirs(os.path.dirname(binary), exist_ok=True)
    for extra in ("codex-path", "codex-resources"):
        os.makedirs(os.path.join(vendor, extra), exist_ok=True)
        with open(os.path.join(vendor, extra, "data"), "w", encoding="utf-8") as fh:
            fh.write(f"{extra} of {version}\n")
    script = textwrap.dedent(
        f"""\
        #!/bin/bash
        # Fake Codex: answers --version and replays a recorded event stream.
        if [ "$1" = "--version" ]; then
            echo "codex-cli {version}-fake"
            exit 0
        fi
        prev=""
        out=""
        for arg in "$@"; do
            if [ "$prev" = "-o" ]; then out="$arg"; fi
            prev="$arg"
        done
        if [ "$2" = "resume" ]; then
            cat {fixture('codex-resume-done.jsonl')!r}
        else
            cat {fixture('codex-done.jsonl')!r}
        fi
        if [ -n "$out" ]; then printf 'fake final message\\n' > "$out"; fi
        exit 0
        """
    )
    with open(binary, "w", encoding="utf-8") as fh:
        fh.write(script)
    os.chmod(binary, 0o755)
    return root


def ok_prober(_binary: str) -> jobs_runtime.ProbeResult:
    return jobs_runtime.ProbeResult(True, None, "thread-fake")


def failing_prober(_binary: str) -> jobs_runtime.ProbeResult:
    return jobs_runtime.ProbeResult(False, "fake 401 from the API", None)


def never_prober(_binary: str) -> jobs_runtime.ProbeResult:
    raise AssertionError("the fast path must not probe")


class RuntimeTestCase(unittest.TestCase):
    """A versions root and both sources in temp dirs; nothing shared, nothing real."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = os.path.join(self.tmp.name, "versions")
        self.npm = os.path.join(self.tmp.name, "npm-pkg")
        self.host = os.path.join(self.tmp.name, "host-pkg")
        patcher = mock.patch.dict(
            os.environ,
            {
                jobs_runtime.CODEX_VERSIONS_DIR_ENV: self.root,
                jobs_runtime.CODEX_NPM_PKG_DIR_ENV: self.npm,
                jobs_runtime.CODEX_HOST_PKG_DIR_ENV: self.host,
            },
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def npm_source(self, version: str) -> jobs_runtime.Source:
        make_package(self.npm, version)
        return jobs_runtime.Source(jobs_runtime.SOURCE_NPM, self.npm, version)

    def host_source(self, version: str) -> jobs_runtime.Source:
        make_package(self.host, version)
        return jobs_runtime.Source(jobs_runtime.SOURCE_HOST, self.host, version)

    def temp_dirs(self) -> list[str]:
        """The snapshot temp dirs currently under the versions root."""
        try:
            names = os.listdir(self.root)
        except OSError:
            return []
        return sorted(
            name for name in names if name.startswith(jobs_runtime.TEMP_PREFIX)
        )

    def publish(self, version: str) -> jobs_runtime.Published:
        source = self.npm_source(version)
        result = jobs_runtime.snapshot(source, root=self.root, prober=ok_prober)
        self.assertIsNotNone(result.published, result.discarded)
        assert result.published is not None
        return result.published


# --------------------------------------------------------------- the discovery


class DiscoveryTests(RuntimeTestCase):
    def test_newest_of_the_two_sources_wins(self) -> None:
        self.npm_source("0.149.1")
        self.host_source("0.154.0")
        sources = jobs_runtime.discover_sources()
        self.assertEqual(
            [(src.name, src.version) for src in sources],
            [
                (jobs_runtime.SOURCE_HOST, "0.154.0"),
                (jobs_runtime.SOURCE_NPM, "0.149.1"),
            ],
        )

    def test_absent_host_mount_leaves_the_npm_volume_alone(self) -> None:
        """The macOS branch: docker-run.sh mounts no host package there."""
        self.npm_source("0.149.1")
        sources = jobs_runtime.discover_sources()
        self.assertEqual(len(sources), 1)
        self.assertEqual(sources[0].name, jobs_runtime.SOURCE_NPM)

    def test_version_key_orders_numerically(self) -> None:
        key = jobs_runtime.version_key
        self.assertLess(key("0.149.1"), key("0.149.2"))
        self.assertLess(key("0.149.9"), key("0.154.0"))
        self.assertLess(key("0.99.0"), key("0.100.0"))


# ---------------------------------------------------------------- the snapshot


class SnapshotTests(RuntimeTestCase):
    def test_publishes_a_verified_read_only_copy(self) -> None:
        source = self.npm_source("0.149.1")
        result = jobs_runtime.snapshot(source, root=self.root, prober=ok_prober)
        self.assertIsNone(result.discarded)
        assert result.published is not None
        self.assertTrue(result.probed)
        self.assertTrue(result.published.verified)
        self.assertEqual(
            result.published.path, os.path.join(self.root, "0.149.1")
        )
        marker = result.published.marker or {}
        self.assertEqual(marker["version"], "0.149.1")
        self.assertEqual(marker["source"], jobs_runtime.SOURCE_NPM)
        self.assertEqual(marker["probeModel"], jobs_runtime.probe_model())
        self.assertIsNotNone(marker["probedAt"])
        # The copy is self-contained: its own binary, its own resources.
        assert result.published.binary is not None
        self.assertTrue(result.published.binary.startswith(result.published.path))
        vendor = os.path.dirname(os.path.dirname(result.published.binary))
        self.assertTrue(os.path.isdir(os.path.join(vendor, "codex-path")))
        # Read-only for node: a convention, stated as such (ADR 0037).
        self.assertFalse(
            os.access(os.path.join(result.published.package, "package.json"), os.W_OK)
        )

    def test_real_probe_over_the_fake_binary(self) -> None:
        """The probe itself: a turn, then a resume into the SAME thread."""
        source = self.npm_source("0.149.1")
        result = jobs_runtime.snapshot(source, root=self.root)
        self.assertIsNone(result.discarded)
        assert result.published is not None
        self.assertEqual(
            (result.published.marker or {})["probeThreadId"],
            "01a094e8-21fc-7641-beef-44dadd0b0235",
        )

    def test_probe_rejects_a_stream_without_a_terminal_event(self) -> None:
        source = self.npm_source("0.149.1")
        binary = jobs_runtime.package_binary(source.path)
        with open(binary, "w", encoding="utf-8") as fh:
            fh.write(
                "#!/bin/bash\n"
                'if [ "$1" = "--version" ]; then echo fake; exit 0; fi\n'
                f"cat {fixture('codex-killed-no-terminal.jsonl')!r}\n"
                "exit 0\n"
            )
        os.chmod(binary, 0o755)
        result = jobs_runtime.snapshot(source, root=self.root)
        self.assertIsNotNone(result.discarded)
        self.assertIn("turn.completed", result.discarded or "")
        self.assertEqual(jobs_runtime.published(self.root), {})

    def test_probe_rejects_a_resume_that_never_states_its_thread(self) -> None:
        """Thread continuity is proven, not assumed from a silent stream."""
        source = self.npm_source("0.149.1")
        binary = jobs_runtime.package_binary(source.path)
        with open(binary, "w", encoding="utf-8") as fh:
            # The first turn is a real recorded stream; the resume replies with
            # a completed turn and no `thread.started` at all.
            fh.write(
                "#!/bin/bash\n"
                'if [ "$1" = "--version" ]; then echo fake; exit 0; fi\n'
                'prev=""; out=""\n'
                'for arg in "$@"; do if [ "$prev" = "-o" ]; then out="$arg"; fi; '
                'prev="$arg"; done\n'
                '[ -n "$out" ] && printf "fake final message\\n" > "$out"\n'
                'if [ "$2" = "resume" ]; then\n'
                '  echo \'{"type":"turn.completed","usage":{}}\'\n'
                "else\n"
                f"  cat {fixture('codex-done.jsonl')!r}\n"
                "fi\n"
                "exit 0\n"
            )
        os.chmod(binary, 0o755)
        result = jobs_runtime.snapshot(source, root=self.root)
        self.assertIsNone(result.published)
        self.assertIn("thread.started", result.discarded or "")
        self.assertEqual(jobs_runtime.published(self.root), {})

    def test_an_interrupted_snapshot_leaves_no_temp_dir(self) -> None:
        """A snapshot temp dir is a whole package copy: never leak one.

        An interruption in the middle of the copy or the probe is not a
        handled return path, so only a ``finally`` can clean up after it.
        """
        source = self.npm_source("0.149.1")

        def interrupted(src: str, dst: str) -> None:
            jobs_runtime._copy_tree(src, dst)
            raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            jobs_runtime.snapshot(
                source,
                root=self.root,
                prober=never_prober,
                copy_tree=interrupted,
            )
        self.assertEqual(self.temp_dirs(), [])

    def test_a_stale_snapshot_dir_is_swept_on_the_next_attempt(self) -> None:
        """Whatever an older interruption left behind goes on the next refresh."""
        os.makedirs(self.root, exist_ok=True)
        # A known Container run id: a dead pid is evidence of abandonment only
        # for a temp dir this Container run owns (pid namespaces differ, and
        # the versions volume is shared).
        run_id_path = os.path.join(self.tmp.name, "run-id")
        with open(run_id_path, "w", encoding="utf-8") as fh:
            fh.write("run-sweep\n")
        patcher = mock.patch.dict(
            os.environ, {jobs_identity.RUN_ID_PATH_ENV: run_id_path}
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        # Two leftovers: one whose owner pid of THIS Container run is dead,
        # one with no owner marker at all and an old mtime.
        dead = os.path.join(self.root, f"{jobs_runtime.TEMP_PREFIX}0.0.1-dead")
        os.makedirs(dead)
        owner = os.path.join(dead, jobs_runtime.OWNER_NAME)
        with open(owner, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "pid": 2 ** 22,
                    "startTime": 1,
                    "containerRunId": jobs_identity.container_run_id(),
                    "createdAt": time.time(),
                },
                fh,
            )
        old = os.path.join(self.root, f"{jobs_runtime.TEMP_PREFIX}0.0.2-old")
        os.makedirs(old)
        ancient = time.time() - 2 * jobs_runtime.STALE_SNAPSHOT_SECONDS
        os.utime(old, (ancient, ancient))
        # And one that is in flight right now: owned by this very process.
        mine = os.path.join(self.root, f"{jobs_runtime.TEMP_PREFIX}0.0.3-mine")
        os.makedirs(mine)
        jobs_runtime._write_owner(mine)

        source = self.npm_source("0.149.1")
        result = jobs_runtime.snapshot(source, root=self.root, prober=ok_prober)
        self.assertIsNotNone(result.published, result.discarded)
        self.assertEqual(self.temp_dirs(), [os.path.basename(mine)])

    def test_a_published_copy_carries_no_owner_marker(self) -> None:
        entry = self.publish("0.149.1")
        self.assertFalse(
            os.path.exists(os.path.join(entry.path, jobs_runtime.OWNER_NAME))
        )

    def test_source_changed_during_the_copy_is_discarded(self) -> None:
        """A concurrent `npm install -g @openai/codex`, simulated exactly."""
        source = self.npm_source("0.149.1")

        def copy_and_mutate(src: str, dst: str) -> None:
            jobs_runtime._copy_tree(src, dst)
            with open(os.path.join(src, "bin", "codex.js"), "a", encoding="utf-8") as fh:
                fh.write("// npm landed here, mid-copy\n")

        result = jobs_runtime.snapshot(
            source, root=self.root, prober=never_prober, copy_tree=copy_and_mutate
        )
        self.assertIsNone(result.published)
        self.assertIn("source changed", result.discarded or "")
        self.assertFalse(result.probed)
        # Nothing published, and no temp dir left behind.
        self.assertEqual(jobs_runtime.published(self.root), {})
        self.assertEqual(
            [
                name
                for name in os.listdir(self.root)
                if name.startswith(jobs_runtime.TEMP_PREFIX)
            ],
            [],
        )
        self.assertTrue(any("discarded" in w for w in result.warnings))

    def test_content_mismatch_is_discarded(self) -> None:
        """The copy differs from its source even though the manifest agrees."""
        source = self.npm_source("0.149.1")

        def copy_then_corrupt(src: str, dst: str) -> None:
            jobs_runtime._copy_tree(src, dst)
            target = os.path.join(dst, "bin", "codex.js")
            stat = os.stat(target)
            with open(target, "w", encoding="utf-8") as fh:
                fh.write("// truncated copy" + " " * 8)
            os.truncate(target, stat.st_size)
            os.utime(target, ns=(stat.st_atime_ns, stat.st_mtime_ns))

        result = jobs_runtime.snapshot(
            source, root=self.root, prober=never_prober, copy_tree=copy_then_corrupt
        )
        self.assertIsNone(result.published)
        self.assertIn("content mismatch", result.discarded or "")
        self.assertEqual(jobs_runtime.published(self.root), {})

    def test_a_copy_whose_binary_is_silent_is_discarded(self) -> None:
        source = self.npm_source("0.149.1")
        os.chmod(jobs_runtime.package_binary(source.path), 0o644)
        result = jobs_runtime.snapshot(
            source, root=self.root, prober=never_prober
        )
        self.assertIsNone(result.published)
        self.assertIn("--version", result.discarded or "")

    def test_an_already_verified_version_is_not_copied_again(self) -> None:
        self.publish("0.149.1")
        source = jobs_runtime.Source(
            jobs_runtime.SOURCE_NPM, self.npm, "0.149.1"
        )
        result = jobs_runtime.snapshot(
            source, root=self.root, prober=never_prober, copy_tree=never_prober
        )
        self.assertIsNotNone(result.published)
        self.assertFalse(result.probed)


# ---------------------------------------------------------------- the selection


class EnsureTests(RuntimeTestCase):
    def test_first_job_snapshots_and_probes_once(self) -> None:
        self.npm_source("0.149.1")
        probes: list[str] = []

        def counting(binary: str) -> jobs_runtime.ProbeResult:
            probes.append(binary)
            return ok_prober(binary)

        first = jobs_runtime.ensure(root=self.root, prober=counting)
        self.assertEqual(first.version, "0.149.1")
        self.assertTrue(first.probed)
        self.assertEqual(len(probes), 1)
        # Fast path: the newest found version IS the newest verified copy.
        second = jobs_runtime.ensure(root=self.root, prober=counting)
        self.assertEqual(second.binary, first.binary)
        self.assertFalse(second.probed)
        self.assertEqual(len(probes), 1)

    def test_a_newer_version_is_snapshotted_and_takes_over(self) -> None:
        self.publish("0.149.1")
        self.host_source("0.154.0")
        chosen = jobs_runtime.ensure(root=self.root, prober=ok_prober)
        self.assertEqual(chosen.version, "0.154.0")
        self.assertEqual(chosen.source, jobs_runtime.SOURCE_HOST)
        self.assertTrue(chosen.probed)

    def test_probe_failure_keeps_the_previous_version_and_warns(self) -> None:
        previous = self.publish("0.149.1")
        self.host_source("0.154.0")
        chosen = jobs_runtime.ensure(root=self.root, prober=failing_prober)
        self.assertEqual(chosen.version, "0.149.1")
        self.assertEqual(chosen.binary, previous.binary)
        self.assertFalse(chosen.probed)
        self.assertTrue(chosen.warnings)
        self.assertIn("probe failed", chosen.warnings[0])
        self.assertNotIn("0.154.0", jobs_runtime.published(self.root))

    def test_no_verified_copy_at_all_refuses(self) -> None:
        self.npm_source("0.149.1")
        with self.assertRaises(jobs_runtime.NoVerifiedRuntime) as caught:
            jobs_runtime.ensure(root=self.root, prober=failing_prober)
        self.assertTrue(caught.exception.warnings)
        # It IS a CodexNotFound to any caller: there is nothing to run on.
        self.assertIsInstance(caught.exception, jobs_codex.CodexNotFound)

    def test_no_source_at_all_refuses_with_the_paths_it_looked_in(self) -> None:
        with self.assertRaises(jobs_runtime.NoVerifiedRuntime) as caught:
            jobs_runtime.ensure(root=self.root)
        self.assertIn(self.npm, str(caught.exception))
        self.assertIn(self.host, str(caught.exception))

    def test_pin_wins_over_newest_and_never_probes(self) -> None:
        self.publish("0.149.1")
        self.publish("0.154.0")
        jobs_runtime.pin("0.149.1", self.root)
        chosen = jobs_runtime.ensure(root=self.root, prober=never_prober)
        self.assertEqual(chosen.version, "0.149.1")
        self.assertEqual(chosen.source, "pin")
        jobs_runtime.clear_pin(self.root)
        self.assertEqual(
            jobs_runtime.ensure(root=self.root, prober=never_prober).version,
            "0.154.0",
        )

    def test_a_pin_on_an_unverified_version_warns_and_falls_back(self) -> None:
        self.publish("0.149.1")
        jobs_runtime.pin("9.9.9", self.root)
        chosen = jobs_runtime.ensure(root=self.root, prober=never_prober)
        self.assertEqual(chosen.version, "0.149.1")
        self.assertTrue(any("9.9.9" in w for w in chosen.warnings))

    def test_an_unwritable_versions_root_refuses_instead_of_crashing(self) -> None:
        """A Container started before the volume existed, or a root-owned one."""
        self.npm_source("0.149.1")
        blocked = os.path.join(self.tmp.name, "blocked")
        os.makedirs(blocked, exist_ok=True)
        os.chmod(blocked, 0o500)
        self.addCleanup(os.chmod, blocked, 0o700)
        root = os.path.join(blocked, "versions")
        with self.assertRaises(jobs_runtime.NoVerifiedRuntime) as caught:
            jobs_runtime.ensure(root=root, prober=never_prober)
        self.assertTrue(any("not usable" in w for w in caught.exception.warnings))

    def test_a_copy_without_its_marker_is_not_used(self) -> None:
        published = self.publish("0.149.1")
        os.chmod(published.path, 0o755)
        os.unlink(os.path.join(published.path, jobs_runtime.MARKER_NAME))
        self.assertFalse(jobs_runtime.published(self.root)["0.149.1"].verified)
        with self.assertRaises(jobs_runtime.NoVerifiedRuntime):
            jobs_runtime.ensure(root=self.root, prober=failing_prober)


# ------------------------------------------------------------- the publish lock


_PUBLISH_SCRIPT = """\
import os, sys, time
sys.path.insert(0, {scripts!r})
from jobs import runtime as rt

root, source, version, hold = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
if hold:
    with rt.publish_lock(root):
        time.sleep(hold)
    sys.exit(0)
result = rt.snapshot(
    rt.Source(rt.SOURCE_NPM, source, version), root=root,
    prober=lambda binary: rt.ProbeResult(True, None, "thread-fake"),
)
print("published" if result.published else "discarded:" + str(result.discarded))
"""


class PublishLockTests(RuntimeTestCase):
    def _script(self) -> str:
        path = os.path.join(self.tmp.name, "publish.py")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(
                _PUBLISH_SCRIPT.format(
                    scripts=os.path.join(_REPO_ROOT, "scripts")
                )
            )
        return path

    def test_a_second_publisher_waits_for_the_lock(self) -> None:
        source = self.npm_source("0.149.1")
        os.makedirs(self.root, exist_ok=True)
        holder = subprocess.Popen(
            [sys.executable, self._script(), self.root, source.path, "0.149.1", "1.5"]
        )
        self.addCleanup(holder.kill)
        # Let the other process take the lock before we try to publish.
        deadline = time.monotonic() + 5
        while not os.path.exists(os.path.join(self.root, jobs_runtime.LOCK_NAME)):
            if time.monotonic() > deadline:
                self.fail("the holder never created the lock file")
            time.sleep(0.05)
        time.sleep(0.3)
        started = time.monotonic()
        result = jobs_runtime.snapshot(source, root=self.root, prober=ok_prober)
        elapsed = time.monotonic() - started
        self.assertIsNotNone(result.published, result.discarded)
        self.assertGreater(elapsed, 0.8)
        holder.wait(timeout=10)

    def test_two_publishers_publish_exactly_one_copy(self) -> None:
        source = self.npm_source("0.149.1")
        script = self._script()
        procs = [
            subprocess.Popen(
                [sys.executable, script, self.root, source.path, "0.149.1", "0"],
                stdout=subprocess.PIPE,
                text=True,
            )
            for _ in range(2)
        ]
        outputs = [proc.communicate(timeout=120)[0].strip() for proc in procs]
        for proc in procs:
            self.assertEqual(proc.returncode, 0)
        self.assertEqual([out for out in outputs if out == "published"], outputs)
        entries = jobs_runtime.published(self.root)
        self.assertEqual(list(entries), ["0.149.1"])
        self.assertTrue(entries["0.149.1"].verified)
        # One published copy, and no temp dir survived the race.
        self.assertEqual(self.temp_dirs(), [])

    def test_concurrent_pins_never_tear_the_shared_pin(self) -> None:
        """Two `runtime use` calls are two writers of one shared file."""
        self.publish("0.149.1")
        self.publish("0.154.0")
        versions = ["0.149.1", "0.154.0"]
        errors: list[Exception] = []

        def pin_repeatedly(version: str) -> None:
            for _ in range(20):
                try:
                    jobs_runtime.pin(version, self.root)
                    self.assertIn(jobs_runtime.read_pin(self.root), versions)
                except Exception as exc:  # noqa: BLE001 - reported, not swallowed
                    errors.append(exc)
                    return

        threads = [
            threading.Thread(target=pin_repeatedly, args=(version,))
            for version in versions
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=30)
        self.assertEqual(errors, [])
        self.assertIn(jobs_runtime.read_pin(self.root), versions)
        # No fixed `pin.tmp` and no leftover temp file of either writer.
        leftovers = [
            name
            for name in os.listdir(self.root)
            if name.endswith(".tmp") or jobs_runtime.PIN_NAME in name
        ]
        self.assertEqual(leftovers, [jobs_runtime.PIN_NAME])


# ------------------------------------------------------------------- the CLI


class RuntimeCliTests(RuntimeTestCase):
    def setUp(self) -> None:
        super().setUp()
        home = os.path.join(self.tmp.name, "home")
        state = os.path.join(home, ".local", "state")
        os.makedirs(state, exist_ok=True)
        patcher = mock.patch.dict(
            os.environ,
            {
                "HOME": home,
                "XDG_STATE_HOME": state,
                jobs_identity.PROJECT_KEY_ENV: PROJECT_KEY,
                jobs_identity.RUN_ID_PATH_ENV: os.path.join(self.tmp.name, "run-id"),
                jobs_codex.CODEX_BIN_ENV: "",
            },
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_cli(self, argv: list[str]) -> tuple[int, dict]:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = jobs_cli.main(argv)
        text = buffer.getvalue().strip()
        payload = json.loads(text) if text.startswith("{") else {}
        return code, payload

    def test_runtime_list_shows_sources_verified_and_in_use(self) -> None:
        self.publish("0.149.1")
        self.host_source("0.154.0")
        code, payload = self.run_cli(["runtime", "list", "--json"])
        self.assertEqual(code, 0)
        rows = {row["version"]: row for row in payload["versions"]}
        self.assertEqual(rows["0.149.1"]["verified"], True)
        self.assertEqual(rows["0.149.1"]["inUse"], True)
        self.assertEqual(rows["0.154.0"]["verified"], False)
        self.assertEqual(rows["0.154.0"]["sources"], [jobs_runtime.SOURCE_HOST])
        self.assertEqual(payload["versionsDir"], self.root)

    def test_runtime_refresh_probes_a_new_version(self) -> None:
        self.publish("0.149.1")
        self.host_source("0.154.0")
        code, payload = self.run_cli(["runtime", "refresh", "--json"])
        self.assertEqual(code, 0)
        self.assertEqual(payload["version"], "0.154.0")
        self.assertTrue(payload["probed"])
        # And again: nothing new to find, so nothing is probed.
        code, payload = self.run_cli(["runtime", "refresh", "--json"])
        self.assertEqual(code, 0)
        self.assertFalse(payload["probed"])

    def test_runtime_use_pins_and_auto_unpins(self) -> None:
        self.publish("0.149.1")
        self.publish("0.154.0")
        code, payload = self.run_cli(["runtime", "use", "0.149.1", "--json"])
        self.assertEqual(code, 0)
        self.assertEqual(payload["pin"], "0.149.1")
        rows = {row["version"]: row for row in payload["versions"]}
        self.assertTrue(rows["0.149.1"]["inUse"])
        self.assertFalse(rows["0.154.0"]["inUse"])
        code, payload = self.run_cli(["runtime", "use", "--auto", "--json"])
        self.assertEqual(code, 0)
        self.assertIsNone(payload["pin"])
        self.assertIsNone(jobs_runtime.read_pin(self.root))

    def test_runtime_use_reports_a_pin_it_could_not_write(self) -> None:
        """Shared state on a shared volume: a failure is a structured refusal."""
        self.publish("0.149.1")
        with mock.patch.object(
            jobs_runtime,
            "publish_lock",
            side_effect=OSError("versions root is read-only"),
        ):
            code, payload = self.run_cli(["runtime", "use", "0.149.1", "--json"])
        self.assertEqual(code, jobs_cli.EXIT_REFUSED)
        self.assertEqual(payload["reason"], jobs_runtime.PinFailed.reason)
        self.assertIn("read-only", payload["detail"])
        self.assertIsNone(jobs_runtime.read_pin(self.root))

    def test_runtime_use_refuses_an_unverified_version(self) -> None:
        self.publish("0.149.1")
        code, payload = self.run_cli(["runtime", "use", "0.154.0", "--json"])
        self.assertEqual(code, jobs_cli.EXIT_REFUSED)
        self.assertEqual(payload["reason"], "not-verified")

    def test_a_codex_job_without_a_verified_runtime_is_refused(self) -> None:
        self.npm_source("0.149.1")
        with mock.patch.object(jobs_runtime, "probe", failing_prober):
            code, payload = self.run_cli(
                [
                    "start",
                    "--key",
                    "no-runtime",
                    "--codex",
                    "--model",
                    MODEL,
                    "--effort",
                    EFFORT,
                    "--json",
                    "prompt",
                ]
            )
        self.assertEqual(code, jobs_cli.EXIT_REFUSED)
        self.assertEqual(payload["reason"], "no-verified-runtime")
        self.assertTrue(payload["warnings"])

    def test_a_codex_job_runs_from_the_verified_copy(self) -> None:
        self.npm_source("0.149.1")
        code, payload = self.run_cli(
            [
                "start",
                "--key",
                "from-copy",
                "--codex",
                "--model",
                MODEL,
                "--effort",
                EFFORT,
                "--json",
                "prompt",
            ]
        )
        self.assertEqual(code, 0, payload)
        self.assertEqual(payload["codexVersion"], "0.149.1")
        self.assertTrue(payload["runtimeProbed"])
        self.assertTrue(payload["codexBinary"].startswith(self.root))
        # The record keeps the copy that ran it, not "codex on PATH".
        code, result = self.run_cli(["wait", payload["jobId"], "--json"])
        self.assertEqual(result["codex"]["codexVersion"], "0.149.1")
        self.assertTrue(result["codex"]["codexBinary"].startswith(self.root))

    def test_a_failed_probe_warns_loudly_on_start(self) -> None:
        self.publish("0.149.1")
        self.host_source("0.154.0")
        with mock.patch.object(jobs_runtime, "probe", failing_prober):
            with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
                code, payload = self.run_cli(
                    [
                        "start",
                        "--key",
                        "warned",
                        "--codex",
                        "--model",
                        MODEL,
                        "--effort",
                        EFFORT,
                        "--json",
                        "prompt",
                    ]
                )
        self.assertEqual(code, 0, payload)
        self.assertEqual(payload["codexVersion"], "0.149.1")
        self.assertTrue(payload["warnings"])
        self.assertIn("WARNING", err.getvalue())
        self.assertIn("probe failed", err.getvalue())


if __name__ == "__main__":
    unittest.main()
