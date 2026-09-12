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

import io
import json
import os
import signal
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

    def test_record_update_never_rewrites_the_reservation(self) -> None:
        """State changes replace the record; the reservation stays immutable."""
        job_id = new_job_id()
        self.store.publish_reservation("k", self._record(job_id, "k"))
        self.store.update_record(job_id, state=STATE_DONE, exitCode=0)
        with open(self.store.key_path("k"), "r", encoding="utf-8") as fh:
            reserved = json.load(fh)
        self.assertEqual(reserved["state"], STATE_RESERVED)
        self.assertEqual(self.store.load_record(job_id)["state"], STATE_DONE)


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
        second = self.start_json("--key", "l2", "--", "sh", "-c", "exit 1")
        for started in (first, second):
            self.wait_for_state(started["jobId"], {STATE_DONE, STATE_FAILED})
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
        self.assertIn("not yet available", help_text)


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


if __name__ == "__main__":
    unittest.main()
