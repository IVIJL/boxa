#!/usr/bin/env python3
"""Concurrency ack for `boxa-job start` (ADR 0037, issue 03).

Run with:

    PYTHONPATH=scripts python3 -m unittest tests.test_jobs_ack   # repo root
    python3 tests/test_jobs_ack.py                               # standalone

Every test runs against an isolated HOME/XDG state tree and an overridden
Project key, and kills whatever Jobs it left behind.

What is load-bearing here:

  * a second `start` under another key is REFUSED, not silently parallel, and
    the refusal carries the list the caller needs to ack;
  * the ack must name exactly the current set: a Job that appeared in between
    makes it stale, so nobody can ack a picture they never saw;
  * the check and the reservation are under one Project lock, so two
    simultaneous starts in an empty Project cannot both come out ack-free;
  * `exited-with-survivors` and `orphaned` count as running (nothing about
    them is finished), while attaching to the same key needs no ack at all.
"""

from __future__ import annotations

import io
import json
import os
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

from jobs import ack as jobs_ack  # noqa: E402
from jobs import cli as jobs_cli  # noqa: E402
from jobs import identity as jobs_identity  # noqa: E402
from jobs import procs  # noqa: E402
from jobs import recovery  # noqa: E402
from jobs.store import (  # noqa: E402
    STATE_ORPHANED,
    STATE_RUNNING,
    STATE_SURVIVORS,
    ProjectStore,
)

PROJECT_KEY = "/home/vlcak/Projekty/acktest"

# Generous but bounded: every Job here is a shell plus a sleep.
STATE_TIMEOUT = 30.0


def run_cli(*argv: str) -> tuple[int, str]:
    """Run boxa-job in-process, returning (exit code, stdout)."""
    buffer = io.StringIO()
    with redirect_stdout(buffer):
        code = jobs_cli.main(list(argv))
    return code, buffer.getvalue()


class AckTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = os.path.join(self.tmp.name, "home")
        self.state = os.path.join(self.home, ".local", "state")
        os.makedirs(self.state, exist_ok=True)
        self.run_id_path = os.path.join(self.tmp.name, "run-id")
        self.env = {
            "HOME": self.home,
            "XDG_STATE_HOME": self.state,
            jobs_identity.PROJECT_KEY_ENV: PROJECT_KEY,
            jobs_identity.RUN_ID_PATH_ENV: self.run_id_path,
        }
        patcher = mock.patch.dict(os.environ, self.env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.store = ProjectStore(PROJECT_KEY)
        self.store.ensure()
        self.addCleanup(self._kill_everything)

    # ------------------------------------------------------------- utilities

    def _kill_everything(self) -> None:
        pids = set()
        for record in self.store.records():
            entries = (
                [record.get("worker") or {}, record.get("command") or {}]
                + list(record.get("tree") or [])
                + list(record.get("survivors") or [])
            )
            for entry in entries:
                if entry.get("pid"):
                    pids.add(int(entry["pid"]))
        for pid in pids:
            if pid in (0, 1) or pid == os.getpid():
                continue
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass

    def start(self, key: str, script: str = "sleep 300", *, ack: str = "") -> dict:
        argv = ["start", "--json", "--key", key]
        if ack:
            argv += ["--ack-concurrent", ack]
        code, out = run_cli(*argv, "--", "sh", "-c", script)
        self.last_exit = code
        return json.loads(out)

    def start_running(self, key: str, script: str = "sleep 300", **kw) -> str:
        """Start a Job and return its id once its command is really running."""
        payload = self.start(key, script, **kw)
        self.assertEqual(
            self.last_exit, jobs_cli.EXIT_OK, f"start {key} refused: {payload}"
        )
        self.wait_for_state(payload["jobId"], {STATE_RUNNING})
        return payload["jobId"]

    def wait_for_state(self, job_id: str, states: set[str]) -> dict:
        deadline = time.time() + STATE_TIMEOUT
        last = None
        while time.time() < deadline:
            recovery.refresh_states(self.store)
            last = self.store.load_record(job_id)
            if last is not None and last.get("state") in states:
                return last
            time.sleep(0.05)
        self.fail(f"job {job_id} never reached {states}: {last}")

    def kill_worker(self, job_id: str) -> None:
        worker = self.store.load_record(job_id)["worker"]
        pid, start = int(worker["pid"]), worker["startTime"]
        os.kill(pid, signal.SIGKILL)
        deadline = time.time() + 10
        while time.time() < deadline and procs.is_alive(pid, start):
            time.sleep(0.02)
        self.assertFalse(procs.is_alive(pid, start), "worker survived SIGKILL")

    def assertNeedsAck(self, payload: dict, job_ids: list[str], reason: str) -> None:
        self.assertEqual(self.last_exit, jobs_cli.EXIT_NEEDS_ACK, payload)
        self.assertEqual(payload["result"], "needs-ack")
        self.assertEqual(payload["reason"], reason)
        self.assertEqual(sorted(payload["ackConcurrent"]), sorted(job_ids))
        self.assertEqual(
            sorted(item["jobId"] for item in payload["concurrent"]),
            sorted(job_ids),
        )


class SecondStartTests(AckTestCase):
    def test_second_key_needs_ack_then_starts_with_it(self) -> None:
        first = self.start_running("ack-a")
        second = self.start("ack-b")
        self.assertNeedsAck(second, [first], jobs_ack.REASON_MISSING)
        listed = second["concurrent"][0]
        self.assertEqual(listed["key"], "ack-a")
        self.assertEqual(listed["state"], STATE_RUNNING)
        self.assertIsNotNone(listed["startedAt"])
        self.assertIn("sleep 300", listed["request"])
        self.assertIn(first, second["hint"])
        # Refusing means refusing: no key was reserved for the second Job.
        self.assertIsNone(self.store.key_job_id("ack-b"))

        payload = self.start("ack-b", ack=first)
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK, payload)
        self.assertEqual(payload["ackConcurrent"], [first])
        record = self.store.load_record(payload["jobId"])
        self.assertEqual(record["ackConcurrent"], [first])
        code, out = run_cli("result", "--json", payload["jobId"])
        self.assertEqual(code, jobs_cli.EXIT_OK)
        self.assertEqual(json.loads(out)["ackConcurrent"], [first])

    def test_first_start_in_an_empty_project_asks_nothing(self) -> None:
        payload = self.start("only-job")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK, payload)
        self.assertEqual(payload["ackConcurrent"], [])

    def test_text_output_lists_the_jobs_and_the_flag(self) -> None:
        first = self.start_running("ack-a")
        code, out = run_cli(
            "start", "--key", "ack-b", "--", "sh", "-c", "sleep 300"
        )
        self.assertEqual(code, jobs_cli.EXIT_NEEDS_ACK)
        self.assertIn("result: needs-ack", out)
        self.assertIn(first, out)
        self.assertIn("key=ack-a", out)
        self.assertIn(f"--ack-concurrent {first}", out)

    def test_ack_with_nothing_running_is_refused(self) -> None:
        payload = self.start("lonely", ack="20200101T000000-aaaaaa")
        self.assertNeedsAck(payload, [], jobs_ack.REASON_NOT_NEEDED)
        self.assertIn("without --ack-concurrent", payload["hint"])


class StaleAckTests(AckTestCase):
    def test_third_job_makes_the_ack_stale(self) -> None:
        first = self.start_running("ack-a")
        second = self.start_running("ack-b", ack=first)
        # The caller still holds the ack it got when only `first` ran.
        payload = self.start("ack-c", ack=first)
        self.assertNeedsAck(payload, [first, second], jobs_ack.REASON_STALE)
        payload = self.start("ack-c", ack=f"{second},{first}")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK, payload)
        self.assertEqual(sorted(payload["ackConcurrent"]), sorted([first, second]))

    def test_unknown_and_partial_acks_are_stale(self) -> None:
        first = self.start_running("ack-a")
        second = self.start_running("ack-b", ack=first)
        for given in (
            "20200101T000000-aaaaaa",
            f"{first},20200101T000000-aaaaaa",
            first,
        ):
            with self.subTest(ack=given):
                payload = self.start("ack-c", ack=given)
                self.assertNeedsAck(
                    payload, [first, second], jobs_ack.REASON_STALE
                )


class KeySemanticsTests(AckTestCase):
    def test_attaching_to_the_same_key_needs_no_ack(self) -> None:
        first = self.start_running("ack-a")
        self.start_running("ack-b", ack=first)
        # Same key, same request, other Jobs running: an attach is not a new
        # run, so it must not demand an ack.
        payload = self.start("ack-a")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK, payload)
        self.assertEqual(payload["result"], "attached")
        self.assertEqual(payload["jobId"], first)

    def test_fresh_on_a_finished_key_still_needs_the_ack(self) -> None:
        done = self.start("quick", "exit 0")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK, done)
        self.wait_for_state(done["jobId"], {"done"})
        other = self.start_running("ack-a")
        payload = self.start("quick", "exit 0")
        # Same key, same request, finished Job: the finished result comes back
        # without a new run and therefore without an ack.
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK, payload)
        self.assertEqual(payload["result"], "finished")

        code, out = run_cli(
            "start", "--json", "--key", "quick", "--fresh", "--", "sh", "-c", "exit 0"
        )
        self.last_exit = code
        self.assertNeedsAck(json.loads(out), [other], jobs_ack.REASON_MISSING)

    def test_a_needs_ack_refusal_never_frees_the_fresh_key(self) -> None:
        """A refused `--fresh` must leave the finished Job's binding intact.

        Releasing the key before the ack passed would lose the only thing that
        makes a Job key useful: the next `start` under it would run the work
        again instead of handing back the result that is already there.
        """
        done = self.start("quick", "exit 0")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK, done)
        self.wait_for_state(done["jobId"], {"done"})
        other = self.start_running("ack-a")

        code, out = run_cli(
            "start", "--json", "--key", "quick", "--fresh", "--", "sh", "-c", "exit 0"
        )
        self.last_exit = code
        self.assertNeedsAck(json.loads(out), [other], jobs_ack.REASON_MISSING)

        # The key still names the finished Job, and nothing new was created.
        self.assertEqual(self.store.key_job_id("quick"), done["jobId"])
        self.assertEqual(len(self.store.job_ids()), 2)

        again = self.start("quick", "exit 0")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK, again)
        self.assertEqual(again["result"], "finished")
        self.assertEqual(again["jobId"], done["jobId"])

        # With the ack given, the key really does hand over to a new run.
        code, out = run_cli(
            "start",
            "--json",
            "--key",
            "quick",
            "--fresh",
            "--ack-concurrent",
            other,
            "--",
            "sh",
            "-c",
            "exit 0",
        )
        self.assertEqual(code, jobs_cli.EXIT_OK, out)
        rerun = json.loads(out)
        self.assertEqual(rerun["result"], "started")
        self.assertNotEqual(rerun["jobId"], done["jobId"])
        self.wait_for_state(rerun["jobId"], {"done"})
        self.assertEqual(self.store.key_job_id("quick"), rerun["jobId"])


class RecoveryStatesCountTests(AckTestCase):
    def test_exited_with_survivors_counts_as_running(self) -> None:
        job_id = self.start("survivors", "sleep 300 & exit 0")["jobId"]
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK)
        self.wait_for_state(job_id, {STATE_SURVIVORS})
        payload = self.start("ack-b")
        self.assertNeedsAck(payload, [job_id], jobs_ack.REASON_MISSING)
        self.assertEqual(payload["concurrent"][0]["state"], STATE_SURVIVORS)
        payload = self.start("ack-b", ack=job_id)
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK, payload)

    def test_orphaned_counts_as_running(self) -> None:
        job_id = self.start_running("orphan")
        self.kill_worker(job_id)
        self.wait_for_state(job_id, {STATE_ORPHANED})
        payload = self.start("ack-b")
        self.assertNeedsAck(payload, [job_id], jobs_ack.REASON_MISSING)
        self.assertEqual(payload["concurrent"][0]["state"], STATE_ORPHANED)

    def test_interrupted_is_terminal_and_does_not_count(self) -> None:
        """Documented choice: `interrupted` never asks for an ack.

        Nothing of it is alive (a foreign Container run wrote it), it already
        refuses a retry under its own key, and making every restart cost an
        ack for dead work would train callers to ack blindly.
        """
        with open(self.run_id_path, "w", encoding="utf-8") as fh:
            fh.write("run-one\n")
        job_id = self.start_running("stale-run")
        with open(self.run_id_path, "w", encoding="utf-8") as fh:
            fh.write("run-two\n")
        self.wait_for_state(job_id, {"interrupted"})
        payload = self.start("after-restart")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK, payload)
        self.assertEqual(payload["ackConcurrent"], [])

    def test_unreadable_record_counts_as_an_unclear_job(self) -> None:
        job_id = self.start_running("broken")
        with open(self.store.record_path(job_id), "w", encoding="utf-8") as fh:
            fh.write("{not json")
        outcome = jobs_ack.gate(self.store, [])
        self.assertFalse(outcome.ok)
        self.assertEqual([item.job_id for item in outcome.concurrent], [job_id])
        self.assertEqual(outcome.concurrent[0].state, "unclear")


class SimultaneousStartTests(AckTestCase):
    """Two starts racing into an empty Project: at most one gets in ack-free.

    Two real processes, not threads: the refusal is decided under a Project
    ``flock``, and a same-process pair would share the lock's owner (and
    stdout) and prove nothing.
    """

    def test_two_processes_cannot_both_start_without_an_ack(self) -> None:
        """The real shape: two `boxa-job` processes, one Project flock."""
        env = dict(os.environ)
        env.update(self.env)
        env["PYTHONPATH"] = os.path.join(_REPO_ROOT, "scripts")
        procs_started = [
            subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "jobs.cli",
                    "start",
                    "--json",
                    "--key",
                    key,
                    "--",
                    "sh",
                    "-c",
                    "sleep 300",
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for key in ("proc-a", "proc-b")
        ]
        outputs = [proc.communicate(timeout=STATE_TIMEOUT * 2) for proc in procs_started]
        codes = [proc.returncode for proc in procs_started]
        payloads = [json.loads(out) for out, _ in outputs]
        started = [
            payload
            for code, payload in zip(codes, payloads)
            if code == jobs_cli.EXIT_OK
        ]
        self.assertLessEqual(len(started), 1, list(zip(codes, payloads)))
        self.assertEqual(
            sorted(codes),
            sorted([jobs_cli.EXIT_OK, jobs_cli.EXIT_NEEDS_ACK]),
            list(zip(codes, outputs)),
        )
        refused = next(
            payload
            for code, payload in zip(codes, payloads)
            if code == jobs_cli.EXIT_NEEDS_ACK
        )
        self.assertEqual(refused["reason"], jobs_ack.REASON_MISSING)
        self.assertEqual(
            [item["jobId"] for item in refused["concurrent"]],
            [started[0]["jobId"]],
        )


class ParseIdsTests(unittest.TestCase):
    def test_parse_ids_is_forgiving_about_spacing_only(self) -> None:
        self.assertEqual(jobs_ack.parse_ids(None), [])
        self.assertEqual(jobs_ack.parse_ids(""), [])
        self.assertEqual(jobs_ack.parse_ids("a, b ,,c"), ["a", "b", "c"])


if __name__ == "__main__":
    unittest.main()
