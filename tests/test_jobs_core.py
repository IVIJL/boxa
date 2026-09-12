#!/usr/bin/env python3
"""Tests for the Container-owned Job core (ADR 0037, issue 01).

Run with:

    python3 -m pytest tests/test_jobs_core.py -q   # from repo root
    python3 -m unittest tests.test_jobs_core       # from repo root
    python3 tests/test_jobs_core.py                # standalone

Every test points HOME and XDG_STATE_HOME at a fresh tempdir, so the real
``~/.local/state/boxa/jobs`` tree is never read or written, and overrides the
Project key via ``BOXA_JOB_PROJECT_KEY`` plus the Container run-id path, so
neither ``/etc/boxa`` nor ``/run/boxa`` is touched.

What is load-bearing here and therefore tested directly:

  * the reservation is complete-or-nothing and the ``link()`` race has exactly
    one winner (ADR 0037 "States and honesty");
  * key semantics: attach, finished-return, conflict, ``--fresh`` refusal;
  * the wait-expiry output shape — at most 5 short lines / one compact JSON
    object, and never the request text, paths or logs ("Frugal waiting");
  * the worker environment is the fixed baseline plus caller-named variables,
    with only the NAMES persisted ("Worker environment").
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from unittest import mock

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from jobs import cli as jobs_cli  # noqa: E402
from jobs import env as jobs_env  # noqa: E402
from jobs import identity as jobs_identity  # noqa: E402
from jobs import procs as jobs_procs  # noqa: E402
from jobs import store as jobs_store  # noqa: E402
from jobs.store import (  # noqa: E402
    STATE_DONE,
    STATE_FAILED,
    STATE_RESERVED,
    KeyReserved,
    ProjectStore,
    fingerprint,
    new_job_id,
)

PROJECT_KEY = "/home/vlcak/Projekty/testproj"

# Generous but bounded: a Job here runs a trivial shell command.
JOB_TIMEOUT = 30.0


def _run_cli(*argv: str) -> tuple[int, str]:
    """Run boxa-job in-process, returning (exit code, stdout)."""
    buffer = io.StringIO()
    with redirect_stdout(buffer):
        code = jobs_cli.main(list(argv))
    return code, buffer.getvalue()


class JobsTestCase(unittest.TestCase):
    """Base: isolated HOME/XDG state, overridden Project key and run id."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
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
            },
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        self.store = ProjectStore(PROJECT_KEY)
        self.store.ensure()
        self.addCleanup(self._kill_leftover_jobs)

    def _kill_leftover_jobs(self) -> None:
        """Kill Jobs still running at the end of a test (they outlive it by design)."""
        for record in self.store.records():
            if record.get("state") in {STATE_DONE, STATE_FAILED}:
                continue
            pids = [record.get("worker", {}).get("pid")]
            pids.append(record.get("command", {}).get("pid"))
            for pid in pids:
                if not pid or int(pid) == os.getpid():
                    continue
                try:
                    os.kill(int(pid), signal.SIGKILL)
                except OSError:
                    pass
        self._await_quiet()

    def _await_quiet(self) -> None:
        """Wait for killed or finished workers to really be gone.

        A Job's worker outlives the CLI call that started it by design; if it
        is still writing its record when ``TemporaryDirectory.cleanup`` walks
        the state tree, the removal fails with "directory not empty".
        """
        deadline = time.time() + 20
        while time.time() < deadline:
            if not any(
                jobs_procs.is_alive(
                    (record.get("worker") or {}).get("pid"),
                    (record.get("worker") or {}).get("startTime"),
                )
                for record in self.store.records()
            ):
                return
            time.sleep(0.05)

    def wait_for_state(self, job_id: str, states: set[str]) -> dict:
        deadline = time.time() + JOB_TIMEOUT
        while time.time() < deadline:
            record = self.store.load_record(job_id)
            if record is not None and record.get("state") in states:
                return record
            time.sleep(0.05)
        self.fail(f"job {job_id} never reached {states}: {self.store.load_record(job_id)}")

    def start_json(self, *argv: str) -> dict:
        # --json must precede the `--` that introduces the command.
        code, out = _run_cli("start", "--json", *argv)
        self.last_exit = code
        return json.loads(out)


class ReservationTests(JobsTestCase):
    def _record(self, job_id: str, key: str) -> dict:
        return {
            "jobId": job_id,
            "key": key,
            "state": STATE_RESERVED,
            "fingerprint": "fp",
            # A pid that is deliberately not this process: the fake record
            # must never make the cleanup kill the test runner itself.
            "worker": {"pid": 2 ** 22, "startTime": 1, "containerRunId": "unknown"},
        }

    def test_link_race_has_exactly_one_winner(self) -> None:
        """Two workers publishing the same key: one record, one EEXIST."""
        first, second = new_job_id(), new_job_id() + "b"
        self.store.publish_reservation("shared", self._record(first, "shared"))
        with self.assertRaises(KeyReserved) as raised:
            self.store.publish_reservation("shared", self._record(second, "shared"))
        self.assertEqual(raised.exception.job_id, first)
        # The loser published nothing at all, and left no temp file behind.
        self.assertIsNone(self.store.load_record(second))
        leftovers = [
            name
            for name in os.listdir(self.store.job_dir(second))
            if name.startswith("record.json")
        ]
        self.assertEqual(leftovers, [])
        self.assertEqual(self.store.key_job_id("shared"), first)

    def test_reservation_is_complete_or_nothing(self) -> None:
        """The published key entry carries the worker's full identity at once."""
        job_id = new_job_id()
        self.store.publish_reservation("k", self._record(job_id, "k"))
        with open(self.store.key_path("k"), "r", encoding="utf-8") as fh:
            reserved = json.load(fh)
        self.assertEqual(reserved["jobId"], job_id)
        self.assertIn("pid", reserved["worker"])
        self.assertIn("containerRunId", reserved["worker"])
        # Reservation and record start as the same inode (linked, not copied).
        self.assertEqual(
            os.stat(self.store.key_path("k")).st_ino,
            os.stat(self.store.record_path(job_id)).st_ino,
        )

    def test_the_record_is_linked_before_the_key(self) -> None:
        """Publish order IS the contract: record first, key last.

        The key link is what the starting CLI waits for, so it has to be the
        last thing published. Reversed, a worker that stalls between the two
        links shows a reserved key with no record — and a CLI that times out
        there restores the previous binding over a key the worker owns.
        """
        job_id = new_job_id()
        seen: list[str] = []
        real_link = os.link

        def spy(src: str, dst: str) -> None:
            seen.append(dst)
            real_link(src, dst)

        with mock.patch("jobs.store.os.link", spy):
            self.store.publish_reservation("ord", self._record(job_id, "ord"))
        self.assertEqual(
            seen, [self.store.record_path(job_id), self.store.key_path("ord")]
        )

    def test_a_key_lost_to_another_worker_leaves_no_record(self) -> None:
        """The loser of the key race published nothing: that Job never was."""
        self.store.publish_reservation("dup", self._record(new_job_id(), "dup"))
        loser = new_job_id()
        with self.assertRaises(KeyReserved):
            self.store.publish_reservation("dup", self._record(loser, "dup"))
        self.assertIsNone(self.store.load_record(loser))

    def test_record_update_never_rewrites_the_reservation(self) -> None:
        """State changes replace the record; the reservation stays immutable."""
        job_id = new_job_id()
        self.store.publish_reservation("k", self._record(job_id, "k"))
        self.store.update_record(job_id, state=STATE_DONE, exitCode=0)
        with open(self.store.key_path("k"), "r", encoding="utf-8") as fh:
            reserved = json.load(fh)
        self.assertEqual(reserved["state"], STATE_RESERVED)
        self.assertEqual(self.store.load_record(job_id)["state"], STATE_DONE)


_RMW_SCRIPT = """\
import sys, time
sys.path.insert(0, {scripts!r})
from jobs.store import ProjectStore

project_key, root, job_id = sys.argv[1], sys.argv[2], sys.argv[3]
store = ProjectStore(project_key, root)
# Let the other writer take the record lock first: this update must wait for
# it and then merge into what that writer left, not into a stale copy.
time.sleep(0.3)
store.update_record(job_id, mine="yes")
"""


class RecordLockTests(JobsTestCase):
    """The record's read-modify-write is safe across PROCESSES, not just threads.

    The writers are separate processes — the worker finalizing, ``cancel``, the
    lazy refresh of any CLI call, gc writing its ``gcAt`` — so an in-process
    lock alone would let one of them re-publish a copy it read before another
    process replaced it (a ``cancelled`` record reverted to ``interrupted``).
    """

    def test_a_second_process_merges_into_the_first_writers_result(self) -> None:
        job_id = new_job_id()
        self.store.publish_reservation(
            "rmw",
            {
                "jobId": job_id,
                "key": "rmw",
                "state": STATE_RESERVED,
                "fingerprint": "fp",
                "worker": {"pid": 2 ** 22, "startTime": 1, "containerRunId": "unknown"},
            },
        )
        script = os.path.join(self.tmp.name, "rmw.py")
        with open(script, "w", encoding="utf-8") as fh:
            fh.write(_RMW_SCRIPT.format(scripts=os.path.join(_REPO_ROOT, "scripts")))
        other = subprocess.Popen(
            [sys.executable, script, PROJECT_KEY, self.store.root, job_id]
        )
        self.addCleanup(other.kill)
        # A deliberately slowed `update_record`: read, pause long enough for
        # the other process to want the record, then write the merged copy.
        # That pause is the whole race — unlocked, the other write lands in
        # the middle of it and this rename erases it.
        with self.store.record_lock(job_id):
            record = self.store.load_record(job_id)
            time.sleep(0.8)
            record["state"] = STATE_DONE
            record["exitCode"] = 0
            self.store._atomic_write(self.store.record_path(job_id), record)
        self.assertEqual(other.wait(timeout=30), 0)
        record = self.store.load_record(job_id)
        # Both writes survived: the late one did not revert the state change.
        self.assertEqual(record["state"], STATE_DONE)
        self.assertEqual(record["exitCode"], 0)
        self.assertEqual(record["mine"], "yes")


class FingerprintTests(unittest.TestCase):
    def test_fingerprint_covers_argv_cwd_and_env_names(self) -> None:
        base = fingerprint(["sh", "-c", "true"], "/w", ["A"])
        self.assertEqual(base, fingerprint(["sh", "-c", "true"], "/w", ["A"]))
        self.assertNotEqual(base, fingerprint(["sh", "-c", "false"], "/w", ["A"]))
        self.assertNotEqual(base, fingerprint(["sh", "-c", "true"], "/other", ["A"]))
        self.assertNotEqual(base, fingerprint(["sh", "-c", "true"], "/w", ["B"]))

    def test_env_name_order_is_irrelevant(self) -> None:
        self.assertEqual(
            fingerprint(["x"], "/w", ["A", "B"]), fingerprint(["x"], "/w", ["B", "A"])
        )


class EnvironmentTests(JobsTestCase):
    def test_child_env_is_the_fixed_baseline_plus_named(self) -> None:
        with mock.patch.dict(os.environ, {"MY_TOKEN": "s3cret", "OTHER": "x"}):
            env = jobs_env.child_env(["MY_TOKEN"], "job-1", socket_probe=lambda _: False)
        self.assertEqual(env["HOME"], "/home/node")
        self.assertIn("XDG_STATE_HOME", env)
        self.assertEqual(env["MY_TOKEN"], "s3cret")
        self.assertEqual(env["BOXA_JOB_ID"], "job-1")
        # The caller's other variables never reach the command.
        self.assertNotIn("OTHER", env)
        self.assertNotIn("BOXA_JOB_PROJECT_KEY", env)

    def test_baseline_adds_sockets_only_when_present(self) -> None:
        without = jobs_env.baseline_env(socket_probe=lambda _: False)
        self.assertNotIn("DOCKER_HOST", without)
        self.assertNotIn("SSH_AUTH_SOCK", without)
        with_sockets = jobs_env.baseline_env(socket_probe=lambda _: True)
        self.assertIn("DOCKER_HOST", with_sockets)
        self.assertIn("SSH_AUTH_SOCK", with_sockets)

    def test_only_env_names_are_persisted(self) -> None:
        with mock.patch.dict(os.environ, {"MY_TOKEN": "s3cret"}):
            started = self.start_json(
                "--key", "envjob", "--env", "MY_TOKEN", "--", "sh", "-c", "echo $MY_TOKEN"
            )
        job_id = started["jobId"]
        record = self.wait_for_state(job_id, {STATE_DONE, STATE_FAILED})
        self.assertEqual(record["envNames"], ["MY_TOKEN"])
        blob = json.dumps(record) + json.dumps(self.store.load_spec(job_id))
        self.assertNotIn("s3cret", blob)
        # The value did reach the command, though.
        with open(self.store.stdout_path(job_id), "r", encoding="utf-8") as fh:
            self.assertEqual(fh.read().strip(), "s3cret")

    def test_control_env_is_boxa_job_variables_without_the_marker(self) -> None:
        with mock.patch.dict(
            os.environ, {"BOXA_JOB_ID": "outer-job", "SOME_TOKEN": "s3cret"}
        ):
            control = jobs_cli._control_env()
        self.assertIn(jobs_identity.PROJECT_KEY_ENV, control)
        self.assertNotIn("SOME_TOKEN", control)
        # The marker is a Job's own ownership stamp, never inherited: a nested
        # `boxa-job start` must not make its processes answer to the outer Job.
        self.assertNotIn("BOXA_JOB_ID", control)

    def test_the_worker_itself_does_not_inherit_the_caller(self) -> None:
        """ADR 0037 "Worker environment" is about the worker, not just its child.

        The Job's command prints its parent's (i.e. the worker's) environment,
        which is the only way to see what the detached worker really got.
        """
        caller_pythonpath = os.path.join(self.tmp.name, "caller-pythonpath")
        with mock.patch.dict(
            os.environ,
            {
                "MY_TOKEN": "s3cret",
                "UNNAMED_SECRET": "leak-me",
                "PYTHONPATH": caller_pythonpath,
            },
        ):
            started = self.start_json(
                "--key",
                "workerenv",
                "--env",
                "MY_TOKEN",
                "--",
                "sh",
                "-c",
                "tr '\\0' '\\n' < /proc/$PPID/environ",
            )
        job_id = started["jobId"]
        self.wait_for_state(job_id, {STATE_DONE, STATE_FAILED})
        with open(self.store.stdout_path(job_id), "r", encoding="utf-8") as fh:
            worker_env = set(fh.read().splitlines())
        # The baseline, the named passthrough and Boxa's own control variables.
        self.assertIn("HOME=/home/node", worker_env)
        self.assertIn("MY_TOKEN=s3cret", worker_env)
        self.assertIn(f"{jobs_identity.PROJECT_KEY_ENV}={PROJECT_KEY}", worker_env)
        # PYTHONPATH is built, not merged: exactly the directory this `jobs`
        # package was imported from, with no trace of the caller's own value
        # (which could otherwise shadow what the worker imports).
        package_parent = os.path.dirname(
            os.path.dirname(os.path.abspath(jobs_cli.jobs.__file__))
        )
        self.assertIn(f"PYTHONPATH={package_parent}", worker_env)
        self.assertNotIn(
            caller_pythonpath,
            "\n".join(line for line in worker_env if line.startswith("PYTHONPATH=")),
        )
        # Nothing else of the caller's environment, named or not.
        self.assertNotIn("UNNAMED_SECRET=leak-me", worker_env)


class LifecycleTests(JobsTestCase):
    def test_done_with_exit_zero_and_stdout_captured(self) -> None:
        started = self.start_json("--key", "ok", "--", "sh", "-c", "echo hello; exit 0")
        self.assertEqual(started["result"], "started")
        record = self.wait_for_state(started["jobId"], {STATE_DONE, STATE_FAILED})
        self.assertEqual(record["state"], STATE_DONE)
        self.assertEqual(record["exitCode"], 0)
        with open(self.store.stdout_path(started["jobId"]), encoding="utf-8") as fh:
            self.assertEqual(fh.read().strip(), "hello")
        # The worker recorded a real identity, not just a pid.
        self.assertIsNotNone(record["worker"]["startTime"])
        self.assertEqual(record["worker"]["containerRunId"], "unknown")

    def test_non_zero_exit_is_failed(self) -> None:
        started = self.start_json("--key", "bad", "--", "sh", "-c", "echo oops >&2; exit 7")
        record = self.wait_for_state(started["jobId"], {STATE_DONE, STATE_FAILED})
        self.assertEqual(record["state"], STATE_FAILED)
        self.assertEqual(record["exitCode"], 7)
        with open(self.store.stderr_path(started["jobId"]), encoding="utf-8") as fh:
            self.assertEqual(fh.read().strip(), "oops")

    def test_spawn_failure_is_failed(self) -> None:
        started = self.start_json("--key", "nope", "--", "/nonexistent/boxa-job-test")
        record = self.wait_for_state(started["jobId"], {STATE_FAILED})
        self.assertIsNone(record["exitCode"])
        self.assertIn("spawn failed", record["error"])

    def test_result_reports_state_exit_paths_and_timings(self) -> None:
        started = self.start_json("--key", "r", "--", "sh", "-c", "exit 0")
        self.wait_for_state(started["jobId"], {STATE_DONE})
        code, out = _run_cli("result", started["jobId"], "--json")
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["state"], STATE_DONE)
        self.assertEqual(payload["exitCode"], 0)
        self.assertIsNotNone(payload["durationSeconds"])
        self.assertTrue(payload["paths"]["stdout"].endswith("stdout"))

    def test_list_shows_the_projects_jobs(self) -> None:
        first = self.start_json("--key", "l1", "--", "sh", "-c", "exit 0")
        # One at a time: a second key started while the first Job still runs
        # would need a concurrency ack (issue 03), which is not what this test
        # is about.
        self.wait_for_state(first["jobId"], {STATE_DONE})
        second = self.start_json("--key", "l2", "--", "sh", "-c", "exit 1")
        self.wait_for_state(second["jobId"], {STATE_FAILED})
        code, out = _run_cli("list", "--json")
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["count"], 2)
        self.assertEqual(
            {row["key"] for row in payload["jobs"]}, {"l1", "l2"}
        )

    def test_log_tails_the_captured_output(self) -> None:
        started = self.start_json(
            "--key", "logs", "--", "sh", "-c", "for i in 1 2 3 4 5; do echo line$i; done"
        )
        self.wait_for_state(started["jobId"], {STATE_DONE})
        code, out = _run_cli("log", started["jobId"], "--tail", "2")
        self.assertEqual(code, jobs_cli.EXIT_OK)
        self.assertIn("line5", out)
        self.assertNotIn("line1", out)

    def test_a_relative_cwd_is_resolved_against_the_caller(self) -> None:
        """The worker runs from `/`, so a relative `--cwd` must be resolved here."""
        sub = os.path.join(self.tmp.name, "sub dir")
        os.makedirs(sub, exist_ok=True)
        previous = os.getcwd()
        os.chdir(self.tmp.name)
        self.addCleanup(os.chdir, previous)
        started = self.start_json(
            "--key", "cwd", "--cwd", "sub dir", "--", "sh", "-c", "pwd"
        )
        job_id = started["jobId"]
        record = self.wait_for_state(job_id, {STATE_DONE, STATE_FAILED})
        self.assertEqual(record["state"], STATE_DONE)
        self.assertEqual(record["cwd"], sub)
        with open(self.store.stdout_path(job_id), encoding="utf-8") as fh:
            self.assertEqual(fh.read().strip(), sub)
        # The absolute path is what the request is fingerprinted by, so the
        # same directory spelled either way is the same request.
        attached = self.start_json(
            "--key", "cwd", "--cwd", sub, "--", "sh", "-c", "pwd"
        )
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK)
        self.assertEqual(attached["jobId"], job_id)

    def test_a_cwd_that_is_not_a_directory_is_a_usage_error(self) -> None:
        code, out = _run_cli(
            "start",
            "--key",
            "badcwd",
            "--cwd",
            os.path.join(self.tmp.name, "no-such-dir"),
            "--",
            "sh",
            "-c",
            "exit 0",
        )
        self.assertEqual(code, jobs_cli.EXIT_USAGE)
        self.assertEqual(out, "")
        # A usage error reserves nothing and starts nothing.
        self.assertEqual(self.store.job_ids(), [])
        self.assertEqual(os.listdir(self.store.keys_dir), [])

    def test_unknown_job_is_not_found(self) -> None:
        code, out = _run_cli("result", "20990101T000000-zzzzzz", "--json")
        self.assertEqual(code, jobs_cli.EXIT_UNCLEAR)
        self.assertEqual(json.loads(out)["result"], "not-found")


class KeySemanticsTests(JobsTestCase):
    ARGV = ("sh", "-c", "sleep 5")

    def test_same_key_same_request_attaches(self) -> None:
        first = self.start_json("--key", "same", "--", *self.ARGV)
        second = self.start_json("--key", "same", "--", *self.ARGV)
        self.assertEqual(second["result"], "attached")
        self.assertEqual(second["jobId"], first["jobId"])
        self.assertEqual(len(self.store.job_ids()), 1)

    def test_same_key_same_request_returns_the_finished_result(self) -> None:
        first = self.start_json("--key", "fin", "--", "sh", "-c", "exit 0")
        self.wait_for_state(first["jobId"], {STATE_DONE})
        second = self.start_json("--key", "fin", "--", "sh", "-c", "exit 0")
        self.assertEqual(second["result"], "finished")
        self.assertEqual(second["jobId"], first["jobId"])
        self.assertEqual(second["exitCode"], 0)
        self.assertEqual(len(self.store.job_ids()), 1)

    def test_same_key_different_request_is_a_conflict(self) -> None:
        self.start_json("--key", "conf", "--", *self.ARGV)
        conflict = self.start_json("--key", "conf", "--", "sh", "-c", "sleep 6")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_CONFLICT)
        self.assertEqual(conflict["result"], "conflict")
        self.assertEqual(conflict["reason"], "fingerprint-mismatch")
        self.assertEqual(len(self.store.job_ids()), 1)

    def test_fresh_is_refused_while_the_key_is_unfinished(self) -> None:
        self.start_json("--key", "fr", "--", *self.ARGV)
        refused = self.start_json("--key", "fr", "--fresh", "--", "sh", "-c", "exit 0")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_REFUSED)
        self.assertEqual(refused["result"], "refused")
        self.assertEqual(refused["reason"], "key-not-finished")
        self.assertEqual(len(self.store.job_ids()), 1)

    def test_fresh_starts_a_new_run_once_the_key_is_finished(self) -> None:
        first = self.start_json("--key", "fr2", "--", "sh", "-c", "exit 0")
        self.wait_for_state(first["jobId"], {STATE_DONE})
        second = self.start_json("--key", "fr2", "--fresh", "--", "sh", "-c", "exit 0")
        self.assertEqual(second["result"], "started")
        self.assertNotEqual(second["jobId"], first["jobId"])
        self.wait_for_state(second["jobId"], {STATE_DONE})
        self.assertEqual(len(self.store.job_ids()), 2)

    def test_fresh_keeps_the_old_binding_when_the_worker_cannot_spawn(self) -> None:
        """A failed `--fresh` costs the caller nothing, least of all the result.

        The old binding is only set aside for the new worker's `link()`; if no
        reservation is ever published the key still means the finished Job, so
        the result stays reachable by key instead of only by jobId.
        """
        first = self.start_json("--key", "fr3", "--", "sh", "-c", "exit 0")
        self.wait_for_state(first["jobId"], {STATE_DONE})
        with mock.patch.object(
            jobs_cli.sys, "executable", os.path.join(self.tmp.name, "no-python")
        ):
            failed = self.start_json(
                "--key", "fr3", "--fresh", "--", "sh", "-c", "exit 0"
            )
        self.assertEqual(self.last_exit, jobs_cli.EXIT_WORKER)
        self.assertEqual(failed["result"], "worker-failed")
        self.assertEqual(failed["keyStillBoundTo"], first["jobId"])
        self.assertEqual(self.store.key_job_id("fr3"), first["jobId"])
        # And the key still answers with the finished result, not a re-run.
        again = self.start_json("--key", "fr3", "--", "sh", "-c", "exit 0")
        self.assertEqual(again["result"], "finished")
        self.assertEqual(again["jobId"], first["jobId"])

    def test_a_timed_out_reservation_never_overwrites_the_new_binding(self) -> None:
        """A late worker keeps its key: the old binding is not put back over it.

        The worker publishes the record first and the key last, so a key that
        names the new Job means the reservation exists — even if this CLI gave
        up waiting for it. Restoring the stash there would leave a live worker
        running under a key that answers with somebody else's Job.
        """
        first = self.start_json("--key", "fr4", "--", "sh", "-c", "exit 0")
        self.wait_for_state(first["jobId"], {STATE_DONE})
        real_await = jobs_cli._await_reservation

        def times_out_anyway(store, job_id, proc, key):
            # The worker really does publish; this CLI just does not see it.
            real_await(store, job_id, proc, key)
            return None

        with mock.patch.object(
            jobs_cli, "_await_reservation", times_out_anyway
        ):
            failed = self.start_json(
                "--key", "fr4", "--fresh", "--", "sh", "-c", "exit 0"
            )
        self.assertEqual(self.last_exit, jobs_cli.EXIT_WORKER)
        self.assertEqual(failed["result"], "worker-failed")
        self.assertEqual(failed["keyBoundTo"], failed["jobId"])
        self.assertNotIn("keyStillBoundTo", failed)
        self.assertEqual(self.store.key_job_id("fr4"), failed["jobId"])
        self.wait_for_state(failed["jobId"], {STATE_DONE})

    def test_a_stash_left_by_a_dead_fresh_is_restored_not_duplicated(self) -> None:
        """A `--fresh` whose CLI was killed mid-flight must not cost the result.

        The stash is discoverable from the key and names its Job, so the next
        `start` under that key puts it back and answers with the finished Job
        instead of running the work a second time.
        """
        first = self.start_json("--key", "fr5", "--", "sh", "-c", "exit 0")
        self.wait_for_state(first["jobId"], {STATE_DONE})
        # A stash of a CLI that is gone: a foreign Container run's owner tag.
        stash = (
            self.store.key_path("fr5")
            + jobs_store.STASH_INFIX
            + "deadrun.4194304"
        )
        os.rename(self.store.key_path("fr5"), stash)
        self.assertIsNone(self.store.key_job_id("fr5"))

        again = self.start_json("--key", "fr5", "--", "sh", "-c", "exit 0")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK)
        self.assertEqual(again["result"], "finished")
        self.assertEqual(again["jobId"], first["jobId"])
        self.assertEqual(again["restoredFreshStash"], first["jobId"])
        self.assertEqual(self.store.key_job_id("fr5"), first["jobId"])
        self.assertEqual(len(self.store.job_ids()), 1)
        self.assertFalse(os.path.exists(stash))

    def test_a_stash_of_a_live_start_is_left_alone(self) -> None:
        """Only an ORPHANED stash is restored: a live `--fresh` owns its own."""
        first = self.start_json("--key", "fr6", "--", "sh", "-c", "exit 0")
        self.wait_for_state(first["jobId"], {STATE_DONE})
        stash = self.store.stash_key("fr6")
        assert stash is not None
        self.assertIn(str(os.getpid()), os.path.basename(stash))
        self.assertIsNone(self.store.restore_orphan_stash("fr6"))
        self.assertTrue(os.path.exists(stash))
        self.assertIsNone(self.store.key_job_id("fr6"))
        # And a stash naming a Job that is gone is garbage, not a binding.
        shutil.rmtree(self.store.job_dir(first["jobId"]))
        dead = self.store.key_path("fr6") + jobs_store.STASH_INFIX + "deadrun.1"
        os.rename(stash, dead)
        self.assertIsNone(self.store.restore_orphan_stash("fr6"))
        self.assertFalse(os.path.exists(dead))

    def _dead_owner_stash(self, key: str, suffix: str) -> str:
        """The key's current binding, set aside under a dead owner's name."""
        stash = self.store.stash_key(key)
        assert stash is not None
        dead = self.store.key_path(key) + jobs_store.STASH_INFIX + suffix
        os.rename(stash, dead)
        return dead

    def test_restoring_a_stash_never_overwrites_a_binding(self) -> None:
        """A late worker may publish its key link while the stash is aside.

        Restoration therefore *links* the stash back instead of renaming over
        the key: the reservation that appeared in the gap wins untouched, and
        the stash is dropped only because that binding names a Job of its own.
        """
        first = self.start_json("--key", "fr7", "--", "sh", "-c", "exit 0")
        self.wait_for_state(first["jobId"], {STATE_DONE})
        stash = self.store.stash_key("fr7")
        assert stash is not None
        late = new_job_id()
        self.store.publish_reservation(
            "fr7",
            {
                "jobId": late,
                "key": "fr7",
                "state": STATE_RESERVED,
                "fingerprint": "fp",
                "worker": {"pid": 1, "startTime": 1, "containerRunId": "unknown"},
            },
        )

        self.assertFalse(self.store.restore_key("fr7", stash))
        self.assertEqual(self.store.key_job_id("fr7"), late)
        self.assertFalse(os.path.exists(stash))

        # And the orphan-stash self-heal leaves that binding alone too.
        orphan = (
            self.store.key_path("fr7") + jobs_store.STASH_INFIX + "deadrun.1.1"
        )
        with open(orphan, "w", encoding="utf-8") as fh:
            json.dump({"jobId": first["jobId"]}, fh)
        self.assertIsNone(self.store.restore_orphan_stash("fr7"))
        self.assertEqual(self.store.key_job_id("fr7"), late)

    def test_a_stash_whose_pid_was_reused_is_not_treated_as_owned(self) -> None:
        """Stash ownership is an identity: pid AND start time AND run tag.

        A dead `--fresh` whose pid was handed to an unrelated process would
        otherwise look owned forever, and its orphaned binding would never be
        restored.
        """
        first = self.start_json("--key", "fr8", "--", "sh", "-c", "exit 0")
        self.wait_for_state(first["jobId"], {STATE_DONE})
        stash = self.store.stash_key("fr8")
        assert stash is not None
        # This run, this (live) pid — but not the process that made the stash.
        other_start = (jobs_procs.process_start_time(os.getpid()) or 0) + 1
        reused = f"{stash.rsplit('.', 1)[0]}.{other_start}"
        os.rename(stash, reused)

        self.assertFalse(jobs_store._stash_owner_alive(os.path.basename(reused)))
        self.assertEqual(
            self.store.restore_orphan_stash("fr8"), first["jobId"]
        )
        self.assertEqual(self.store.key_job_id("fr8"), first["jobId"])
        self.assertFalse(os.path.exists(reused))

    def test_the_newest_of_several_orphan_stashes_is_the_one_restored(self) -> None:
        """A chain of dead `--fresh` calls leaves more than one stash.

        The key last meant the newest of them, so that is what comes back —
        not whichever name sorts first — and its predecessors go with it.
        """
        older = new_job_id()
        newer = new_job_id()
        for job_id, reserved_at, suffix in (
            (older, 100.0, "deadrun.1.1"),
            (newer, 200.0, "deadrun.2.2"),
        ):
            self.store.publish_reservation(
                "fr9",
                {
                    "jobId": job_id,
                    "key": "fr9",
                    "state": STATE_DONE,
                    "fingerprint": "fp",
                    "reservedAt": reserved_at,
                    "worker": {
                        "pid": 1,
                        "startTime": 1,
                        "containerRunId": "unknown",
                    },
                },
            )
            self._dead_owner_stash("fr9", suffix)
        keys_before = sorted(os.listdir(self.store.keys_dir))
        self.assertEqual(len(keys_before), 2)

        self.assertEqual(self.store.restore_orphan_stash("fr9"), newer)
        self.assertEqual(self.store.key_job_id("fr9"), newer)
        # Both stashes are gone: the restored one and its superseded
        # predecessor, which must never be put back over a newer result.
        self.assertEqual(
            os.listdir(self.store.keys_dir), [os.path.basename(self.store.key_path("fr9"))]
        )

    def test_an_unwritable_key_index_refuses_instead_of_crashing(self) -> None:
        """The dangling-binding recovery needs to write the index to happen.

        A read-only keys dir makes that impossible, and the promised recovery
        then has to be a structured refusal rather than an OSError traceback.
        """
        job_id = new_job_id()
        self.store.publish_reservation(
            "stuck",
            {
                "jobId": job_id,
                "key": "stuck",
                "state": STATE_DONE,
                "fingerprint": "fp",
                "worker": {"pid": 1, "startTime": 1, "containerRunId": "unknown"},
            },
        )
        shutil.rmtree(self.store.job_dir(job_id))
        os.chmod(self.store.keys_dir, 0o500)
        self.addCleanup(os.chmod, self.store.keys_dir, 0o700)
        payload = self.start_json("--key", "stuck", "--", "sh", "-c", "exit 0")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_REFUSED)
        self.assertEqual(payload["result"], "refused")
        self.assertEqual(payload["reason"], "key-index-unwritable")
        self.assertIn("stuck", payload["detail"])
        self.assertEqual(self.store.job_ids(), [])

    def test_a_key_bound_to_a_purged_job_counts_as_free(self) -> None:
        """`gc --purge` that could not free the key leaves a binding, not a Job.

        There is nothing to attach to and nothing unclear about it, so `start`
        takes the key and names the binding it dropped.
        """
        job_id = new_job_id()
        self.store.publish_reservation(
            "gonekey",
            {
                "jobId": job_id,
                "key": "gonekey",
                "state": STATE_DONE,
                "fingerprint": "fp",
                "worker": {"pid": 1, "startTime": 1, "containerRunId": "unknown"},
            },
        )
        shutil.rmtree(self.store.job_dir(job_id))
        started = self.start_json("--key", "gonekey", "--", "sh", "-c", "exit 0")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK)
        self.assertEqual(started["result"], "started")
        self.assertEqual(started["freedDanglingKey"], job_id)
        self.assertEqual(self.store.key_job_id("gonekey"), started["jobId"])
        self.wait_for_state(started["jobId"], {STATE_DONE})

    def test_reservation_without_a_record_is_unclear(self) -> None:
        """A half-known key refuses a retry until cancel/adopt (issue 02)."""
        job_id = new_job_id()
        self.store.publish_reservation(
            "half",
            {
                "jobId": job_id,
                "key": "half",
                "state": STATE_RESERVED,
                "fingerprint": "fp",
                "worker": {"pid": 1, "startTime": 1, "containerRunId": "unknown"},
            },
        )
        os.unlink(self.store.record_path(job_id))
        payload = self.start_json("--key", "half", "--", "sh", "-c", "exit 0")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_UNCLEAR)
        self.assertEqual(payload["result"], "unclear")


class WaitTests(JobsTestCase):
    def test_wait_returns_the_finished_job(self) -> None:
        started = self.start_json("--key", "w", "--", "sh", "-c", "echo done")
        code, out = _run_cli("wait", "--timeout", "30", "--json", started["jobId"])
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["state"], STATE_DONE)
        self.assertEqual(payload["exitCode"], 0)

    def test_wait_expiry_output_is_short_and_says_nothing_else(self) -> None:
        started = self.start_json(
            "--key", "slow", "--", "sh", "-c", "sleep 20; echo SECRETPAYLOAD"
        )
        code, out = _run_cli("wait", "--timeout", "1", started["jobId"])
        self.assertEqual(code, jobs_cli.EXIT_STILL_RUNNING)
        lines = [line for line in out.splitlines() if line.strip()]
        self.assertLessEqual(len(lines), 5)
        self.assertIn("state: running", out)
        self.assertIn(started["jobId"], out)
        self.assertIn("heartbeat:", out)
        # Never the request text, the paths, or any log content.
        self.assertNotIn("SECRETPAYLOAD", out)
        self.assertNotIn("sleep", out)
        self.assertNotIn(self.store.dir, out)

    def test_wait_expiry_json_is_one_compact_object(self) -> None:
        started = self.start_json(
            "--key", "slowjson", "--", "sh", "-c", "sleep 20; echo SECRETPAYLOAD"
        )
        code, out = _run_cli("wait", "--timeout", "1", "--json", started["jobId"])
        self.assertEqual(code, jobs_cli.EXIT_STILL_RUNNING)
        self.assertEqual(len(out.strip().splitlines()), 1)
        payload = json.loads(out)
        self.assertEqual(
            set(payload), {"result", "jobId", "state", "heartbeatAgeSeconds"}
        )
        self.assertEqual(payload["state"], "running")
        self.assertLess(payload["heartbeatAgeSeconds"], 10)

    def test_wait_timeout_is_capped_under_the_bash_limit(self) -> None:
        self.assertLess(jobs_cli.WAIT_MAX_SECONDS, 600)
        self.assertLessEqual(jobs_cli.WAIT_DEFAULT_SECONDS, jobs_cli.WAIT_MAX_SECONDS)
        self.assertEqual(
            jobs_cli.effective_timeout(99999), jobs_cli.WAIT_MAX_SECONDS
        )
        self.assertEqual(jobs_cli.effective_timeout(5), 5)
        self.assertEqual(jobs_cli.effective_timeout(-1), 0)


class HelpTests(unittest.TestCase):
    def test_help_documents_every_command(self) -> None:
        help_text = jobs_cli.build_parser().format_help()
        for name in (
            "start",
            "wait",
            "result",
            "log",
            "cancel",
            "adopt",
            "list",
            "reply",
            "gc",
            "runtime",
        ):
            self.assertIn(name, help_text, f"--help does not mention {name}")
        # Issue 06 closed the last gap: nothing is "not yet available" and
        # --help is the whole command surface ADR 0037 describes.
        self.assertNotIn("not yet available", help_text)
        self.assertEqual(jobs_cli.PENDING_COMMANDS, {})


class PendingCommandTests(JobsTestCase):
    def test_pending_commands_refuse_clearly(self) -> None:
        for name in jobs_cli.PENDING_COMMANDS:
            code, _ = _run_cli(name)
            self.assertEqual(code, jobs_cli.EXIT_NOT_YET, name)


class IdentityTests(JobsTestCase):
    def test_project_key_override_and_hash(self) -> None:
        self.assertEqual(jobs_identity.project_key(), PROJECT_KEY)
        digest = jobs_identity.project_key_hash(PROJECT_KEY)
        self.assertEqual(len(digest), 16)
        self.assertTrue(self.store.dir.endswith(digest))

    def test_missing_identity_refuses(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                jobs_identity.PROJECT_KEY_ENV: "",
                "BOXA_MCP_IDENTITY_PATH": os.path.join(self.tmp.name, "absent.json"),
            },
        ):
            with self.assertRaises(jobs_identity.IdentityError):
                jobs_identity.project_key()

    def test_run_id_is_read_when_the_entrypoint_wrote_it(self) -> None:
        path = os.environ[jobs_identity.RUN_ID_PATH_ENV]
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("run-abc\n")
        self.assertEqual(jobs_identity.container_run_id(), "run-abc")
        os.unlink(path)
        self.assertEqual(
            jobs_identity.container_run_id(), jobs_identity.UNKNOWN_RUN_ID
        )


class StateDirectoryTests(JobsTestCase):
    """An unusable state tree is a setup error with a message, not a traceback."""

    @unittest.skipIf(os.geteuid() == 0, "root ignores directory modes")
    def test_unwritable_state_root_is_a_named_refusal(self) -> None:
        root = os.path.join(self.tmp.name, "ro-state")
        os.makedirs(root)
        os.chmod(root, 0o500)
        self.addCleanup(os.chmod, root, 0o700)
        store = ProjectStore(PROJECT_KEY, root)
        with self.assertRaises(jobs_store.JobStoreError) as caught:
            store.ensure()
        self.assertIn("Job state directory unusable", str(caught.exception))
        self.assertIn("boxa-<project>-jobs", str(caught.exception))
        # Through the CLI the same failure is a one-line stderr message and the
        # usual "unclear" exit, exactly like any other JobStoreError.
        with mock.patch.dict(os.environ, {"XDG_STATE_HOME": root}), \
                mock.patch.object(jobs_store, "state_root", return_value=root):
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                code, out = _run_cli("list")
        self.assertEqual(code, jobs_cli.EXIT_UNCLEAR)
        self.assertEqual(out, "")
        self.assertIn("boxa-job: Job state directory unusable", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())

    @unittest.skipIf(os.geteuid() == 0, "root ignores directory modes")
    def test_existing_foreign_owned_tree_is_refused_before_the_lock(self) -> None:
        # The tree exists (as a root-owned volume would), so makedirs(exist_ok)
        # is happy; ensure() must still refuse, and so must the lock path.
        root = os.path.join(self.tmp.name, "foreign-state")
        store = ProjectStore(PROJECT_KEY, root)
        os.makedirs(store.keys_dir)
        os.chmod(store.dir, 0o500)
        self.addCleanup(os.chmod, store.dir, 0o700)
        with self.assertRaises(jobs_store.JobStoreError) as caught:
            store.ensure()
        self.assertIn("is not writable", str(caught.exception))
        with self.assertRaises(jobs_store.JobStoreError):
            with store.lock():
                pass


if __name__ == "__main__":
    unittest.main()
