#!/usr/bin/env python3
"""Ownership, cancel and recovery states for Jobs (ADR 0037, issue 02).

Run with:

    python3 -m unittest tests.test_jobs_ownership    # from repo root
    python3 tests/test_jobs_ownership.py             # standalone

These tests start REAL processes (that is the whole point: a `setsid` escapee
and a child with a wiped environment cannot be faked), so every test runs
against an isolated HOME/XDG state tree and kills whatever it leaves behind —
including the processes Boxa deliberately refuses to claim it can kill.

What is load-bearing here:

  * the tree walk under a live worker catches a `setsid` escapee and an
    ``env -i`` child that a process-group kill would miss;
  * ``done`` means "command exited AND nothing of the tree is left":
    otherwise ``exited-with-survivors``, with the exit code recorded;
  * a dead worker is detected by identity, not by pid, and yields ``orphaned``
    while the tree lives and ``finished-unknown`` once it does not;
  * ``cancel`` reports what it killed and does NOT claim success for a process
    it can only remember (marker cleared after the worker died);
  * a foreign Container run id makes a record ``interrupted`` lazily, and an
    unclear key never produces a duplicate run.
"""

from __future__ import annotations

import io
import json
import os
import re
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
from jobs import identity as jobs_identity  # noqa: E402
from jobs import procs  # noqa: E402
from jobs import recovery  # noqa: E402
from jobs import worker as jobs_worker  # noqa: E402
from jobs.store import (  # noqa: E402
    STATE_CANCELLED,
    STATE_DONE,
    STATE_FINISHED_UNKNOWN,
    STATE_INTERRUPTED,
    STATE_ORPHANED,
    STATE_RESERVED,
    STATE_SURVIVORS,
    ProjectStore,
    new_job_id,
)

PROJECT_KEY = "/home/vlcak/Projekty/ownershiptest"
ENTRYPOINT = os.path.join(_REPO_ROOT, "scripts", "boxa-entrypoint.sh")

# Generous but bounded: every command here is a shell plus a sleep.
STATE_TIMEOUT = 30.0


def run_cli(*argv: str) -> tuple[int, str]:
    """Run boxa-job in-process, returning (exit code, stdout)."""
    buffer = io.StringIO()
    with redirect_stdout(buffer):
        code = jobs_cli.main(list(argv))
    return code, buffer.getvalue()


class OwnershipTestCase(unittest.TestCase):
    """Isolated state tree, overridden Project key and Container run id."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        home = os.path.join(self.tmp.name, "home")
        state = os.path.join(home, ".local", "state")
        os.makedirs(state, exist_ok=True)
        self.run_id_path = os.path.join(self.tmp.name, "run-id")
        patcher = mock.patch.dict(
            os.environ,
            {
                "HOME": home,
                "XDG_STATE_HOME": state,
                jobs_identity.PROJECT_KEY_ENV: PROJECT_KEY,
                jobs_identity.RUN_ID_PATH_ENV: self.run_id_path,
            },
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        self.store = ProjectStore(PROJECT_KEY)
        self.store.ensure()
        self.addCleanup(self._kill_everything)

    # ------------------------------------------------------------- utilities

    def set_run_id(self, value: str) -> None:
        with open(self.run_id_path, "w", encoding="utf-8") as fh:
            fh.write(value + "\n")

    def _kill_everything(self) -> None:
        """Kill every process any record of this test ever mentioned.

        Including the ones ``cancel`` honestly reported as untrackable: Boxa
        refusing to claim them does not mean a test may leak them.
        """
        pids = set()
        for record in self.store.records():
            for entry in (
                [record.get("worker") or {}, record.get("command") or {}]
                + list(record.get("tree") or [])
                + list(record.get("survivors") or [])
            ):
                if entry.get("pid"):
                    pids.add(int(entry["pid"]))
        for pid in pids:
            if pid in (0, 1) or pid == os.getpid():
                continue
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass

    def start(self, key: str, script: str, *, fresh: bool = False) -> dict:
        argv = ["start", "--json", "--key", key]
        if fresh:
            argv.append("--fresh")
        code, out = run_cli(*argv, "--", "sh", "-c", script)
        self.last_exit = code
        return json.loads(out)

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

    def live_pids(self, job_id: str) -> dict[int, dict]:
        record = self.store.load_record(job_id)
        self.assertIsNotNone(record)
        return recovery.live_job_pids(record)

    def kill_worker(self, job_id: str) -> int:
        """SIGKILL the Job's worker and wait until it is gone by identity."""
        record = self.store.load_record(job_id)
        worker = record["worker"]
        pid, start = int(worker["pid"]), worker["startTime"]
        os.kill(pid, signal.SIGKILL)
        deadline = time.time() + 10
        while time.time() < deadline and procs.is_alive(pid, start):
            time.sleep(0.02)
        self.assertFalse(procs.is_alive(pid, start), "worker survived SIGKILL")
        return pid

    def assertGone(self, pid: int, start_time=None) -> None:
        # Without a remembered start time the question is "is anything running
        # under this pid" (`is_running`): `is_alive` answers False for a pid
        # with no identity by design, which would pass this assert for free.
        def alive() -> bool:
            if start_time is None:
                return procs.is_running(pid)
            return procs.is_alive(pid, start_time)

        deadline = time.time() + 5
        while time.time() < deadline and alive():
            time.sleep(0.02)
        self.assertFalse(alive(), f"pid {pid} still alive")


class ProcessIdentityTests(OwnershipTestCase):
    def test_pid_alone_is_never_an_identity(self) -> None:
        """A recycled pid must not satisfy a record's remembered identity."""
        pid = os.getpid()
        real = procs.process_start_time(pid)
        self.assertIsNotNone(real)
        self.assertTrue(procs.is_alive(pid, real))
        self.assertFalse(procs.is_alive(pid, real + 1))
        self.assertFalse(procs.is_alive(2 ** 22, None))

    def test_a_pid_without_a_start_time_is_not_verifiably_alive(self) -> None:
        """No start time, no identity: the answer is "unknown", never "alive".

        Treating bare existence as identity would let a recycled pid — and
        everything below it in the process tree — be attributed to a Job, and
        then be killed for it.
        """
        pid = os.getpid()
        self.assertFalse(procs.is_alive(pid, None))
        self.assertFalse(procs.is_alive(pid))
        # The weaker question has its own name, and answers honestly.
        self.assertTrue(procs.is_running(pid))
        self.assertFalse(procs.is_running(2 ** 22))

    def test_descendant_walk_reaches_a_grandchild(self) -> None:
        links = procs.parent_map()
        self.assertIn(os.getpid(), links)
        self.assertIn(os.getpid(), procs.descendants(links[os.getpid()], links))


class CancelBeforeSpawnTests(OwnershipTestCase):
    """A cancel that lands while the Job is still `reserved`."""

    def test_a_cancel_seen_before_the_spawn_never_starts_the_command(self) -> None:
        """`cancelled` is terminal, so nothing of the Job may run afterwards.

        The worker's monitor can handle the cancel request after an empty tree
        scan a moment before the spawn; without the spawn gate the command
        then starts anyway and outlives a record that already says
        ``cancelled``.  Provoked deterministically here by requesting the
        cancel before the worker runs at all.
        """
        job_id = new_job_id()
        marker = os.path.join(self.tmp.name, "the-command-ran")
        self.store.write_spec(
            job_id,
            {
                "jobId": job_id,
                "key": "cancel-first",
                "argv": ["sh", "-c", f"touch {marker}; sleep 300"],
                "cwd": self.tmp.name,
                "envNames": [],
                "fingerprint": "fp",
                "ackConcurrent": [],
                "requestedAt": time.time(),
            },
        )
        self.store.request_cancel(job_id, "test")

        self.assertEqual(
            jobs_worker.run_spawn(PROJECT_KEY, job_id, self.store.root), 0
        )

        record = self.store.load_record(job_id)
        self.assertEqual(record["state"], STATE_CANCELLED)
        self.assertTrue(record["cancelledBeforeSpawn"])
        self.assertIsNone(record["exitCode"])
        self.assertIsNone(record["startedAt"])
        self.assertFalse(
            os.path.exists(marker),
            "the command ran despite a cancel recorded before the spawn",
        )


class SetsidEscapeeTests(OwnershipTestCase):
    def test_cancel_kills_the_setsid_escapee_and_reports_it(self) -> None:
        """`kill -pgid` misses this one; the subreaper tree walk does not."""
        started = self.start("escapee", "setsid sleep 300 & sleep 300")
        job_id = started["jobId"]
        self.wait_for_state(job_id, {"running"})
        # Wait until the tree walk sees both the shell and the escapee.
        deadline = time.time() + STATE_TIMEOUT
        live = {}
        while time.time() < deadline:
            live = self.live_pids(job_id)
            if len(live) >= 2:
                break
            time.sleep(0.1)
        self.assertGreaterEqual(
            len(live), 2, f"tree walk never found the escapee: {live}"
        )
        # The escapee really is outside the command's process group, so a
        # group kill would have missed it.
        command_pid = self.store.load_record(job_id)["command"]["pid"]
        command_pgid = os.getpgid(command_pid)
        escapees = [
            pid for pid in live if pid != command_pid and os.getpgid(pid) != command_pgid
        ]
        self.assertTrue(escapees, f"nothing escaped the process group: {live}")

        code, out = run_cli("cancel", "--json", job_id)
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["state"], STATE_CANCELLED)
        for pid in live:
            self.assertIn(pid, payload["killed"], f"cancel did not report pid {pid}")
            self.assertGone(pid)
        self.assertEqual(payload["untrackable"], [])
        self.assertEqual(payload["stillAlive"], [])
        self.assertEqual(len(payload["limits"]), 2)

    def test_cancel_text_output_states_its_limits(self) -> None:
        started = self.start("escapee-text", "setsid sleep 300 & sleep 300")
        self.wait_for_state(started["jobId"], {"running"})
        code, out = run_cli("cancel", started["jobId"])
        self.assertEqual(code, jobs_cli.EXIT_OK)
        self.assertIn("state: cancelled", out)
        self.assertIn("killed:", out)
        self.assertIn("rootless Docker daemon", out)
        self.assertIn("cleared BOXA_JOB_ID", out)


class EnvWipedChildTests(OwnershipTestCase):
    def test_env_i_child_is_tracked_alive_then_honestly_untrackable(self) -> None:
        """The marker cannot survive `env -i`; the subreaper tree can.

        While the worker lives the child is tracked through /proc parent links.
        Once the worker is SIGKILLed there is neither a marker nor a live
        ancestor left, so `cancel` reports it instead of claiming it killed it.
        """
        started = self.start("envwiped", "env -i sleep 300 & exit 0")
        job_id = started["jobId"]
        # Tracked while the worker lives: the command exited, the wiped child
        # reparented to the worker and keeps the Job out of `done`.
        record = self.wait_for_state(job_id, {STATE_SURVIVORS})
        self.assertEqual(record["exitCode"], 0)
        survivors = record["survivors"]
        self.assertEqual(len(survivors), 1, survivors)
        child_pid = int(survivors[0]["pid"])
        child_start = survivors[0]["startTime"]
        self.assertEqual(procs.marker_pids(job_id), set(), "env -i kept the marker")
        code, out = run_cli("result", "--json", job_id)
        self.assertEqual(json.loads(out)["survivors"], [child_pid])

        self.kill_worker(job_id)
        record = self.wait_for_state(job_id, {STATE_ORPHANED})

        code, out = run_cli("cancel", "--json", job_id)
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["state"], STATE_CANCELLED)
        # The honesty that matters: not killed, not claimed, but reported.
        self.assertNotIn(child_pid, payload["killed"])
        self.assertIn(child_pid, payload["untrackable"])
        self.assertTrue(procs.is_alive(child_pid, child_start))
        self.assertEqual(len(payload["limits"]), 2)
        # The test owns the cleanup Boxa refused to promise.
        os.kill(child_pid, signal.SIGKILL)
        self.assertGone(child_pid, child_start)


class SurvivorTests(OwnershipTestCase):
    def test_main_exit_with_a_live_child_is_exited_with_survivors(self) -> None:
        started = self.start("survivors", "sleep 300 & echo hi")
        job_id = started["jobId"]
        record = self.wait_for_state(job_id, {STATE_SURVIVORS})
        self.assertEqual(record["exitCode"], 0)
        self.assertNotEqual(record["state"], STATE_DONE)
        survivor_pid = int(record["survivors"][0]["pid"])

        code, out = run_cli("result", "--json", job_id)
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["state"], STATE_SURVIVORS)
        self.assertEqual(payload["exitCode"], 0)
        self.assertEqual(payload["survivors"], [survivor_pid])
        code, listing = run_cli("list")
        self.assertIn(STATE_SURVIVORS, listing)
        self.assertIn(str(survivor_pid), listing)

        code, out = run_cli("cancel", "--json", job_id)
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["state"], STATE_CANCELLED)
        self.assertIn(survivor_pid, payload["killed"])
        self.assertGone(survivor_pid)

    def test_survivors_ending_on_their_own_finishes_the_job(self) -> None:
        started = self.start("shortlived", "sleep 3 & echo hi")
        record = self.wait_for_state(started["jobId"], {STATE_SURVIVORS})
        self.assertEqual(record["exitCode"], 0)
        record = self.wait_for_state(started["jobId"], {STATE_DONE})
        self.assertEqual(record["exitCode"], 0)
        self.assertEqual(record["survivors"], [])

    def test_a_job_whose_tree_is_gone_is_plain_done(self) -> None:
        started = self.start("clean", "echo hi")
        record = self.wait_for_state(started["jobId"], {STATE_DONE})
        self.assertEqual(record["survivors"], [])


class OrphanAdoptTests(OwnershipTestCase):
    def test_worker_sigkill_orphans_the_job_and_adopt_watches_it_out(self) -> None:
        started = self.start("orphan", "sleep 4; echo ADOPTED_OUTPUT")
        job_id = started["jobId"]
        self.wait_for_state(job_id, {"running"})
        self.kill_worker(job_id)

        record = self.wait_for_state(job_id, {STATE_ORPHANED})
        self.assertTrue(record["survivors"], "orphaned without a live tree")
        # `wait` must not sit on an orphan: nothing changes without a decision.
        code, out = run_cli("wait", "--timeout", "30", job_id)
        self.assertEqual(code, jobs_cli.EXIT_UNCLEAR)
        self.assertIn(STATE_ORPHANED, out)
        self.assertIn("adopt", out)

        code, out = run_cli("adopt", "--json", job_id)
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["result"], "adopted")
        self.assertTrue(payload["adopted"])

        record = self.wait_for_state(job_id, {STATE_FINISHED_UNKNOWN})
        # No exit code will ever be known: nobody held the wait status.
        self.assertIsNone(record["exitCode"])
        with open(self.store.stdout_path(job_id), encoding="utf-8") as fh:
            self.assertIn("ADOPTED_OUTPUT", fh.read())

    def test_adopt_is_refused_when_nothing_is_alive(self) -> None:
        started = self.start("nothing-left", "exit 0")
        job_id = started["jobId"]
        self.wait_for_state(job_id, {STATE_DONE})
        code, out = run_cli("adopt", "--json", job_id)
        self.assertEqual(code, jobs_cli.EXIT_REFUSED)
        self.assertEqual(json.loads(out)["result"], "refused")

    def test_dead_worker_and_dead_tree_is_finished_unknown(self) -> None:
        """The worker died while the command ran and the command then ended."""
        started = self.start("gone", "sleep 1")
        job_id = started["jobId"]
        self.wait_for_state(job_id, {"running"})
        self.kill_worker(job_id)
        record = self.wait_for_state(job_id, {STATE_FINISHED_UNKNOWN})
        self.assertIsNone(record["exitCode"])


class RunIdTests(OwnershipTestCase):
    def test_a_foreign_run_id_interrupts_without_resuming_or_duplicating(self) -> None:
        self.set_run_id("run-one")
        started = self.start("restart", "sleep 300")
        job_id = started["jobId"]
        self.wait_for_state(job_id, {"running"})
        self.assertEqual(
            self.store.load_record(job_id)["worker"]["containerRunId"], "run-one"
        )

        # A new Container run: the old record's pids mean nothing here.
        self.set_run_id("run-two")
        code, out = run_cli("result", "--json", job_id)
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["state"], STATE_INTERRUPTED)
        self.assertEqual(payload["interruptedReason"], "container-restart")

        # Same key, same request: the interrupted record comes back, and the
        # Project still has exactly one Job (never an auto-resume).
        again = self.start("restart", "sleep 300")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_UNCLEAR)
        self.assertEqual(again["result"], "unclear")
        self.assertEqual(again["jobId"], job_id)
        self.assertEqual(again["state"], STATE_INTERRUPTED)
        self.assertEqual(len(self.store.job_ids()), 1)

        # --fresh over an unresolved key is refused with a structured reason.
        refused = self.start("restart", "sleep 300", fresh=True)
        self.assertEqual(self.last_exit, jobs_cli.EXIT_REFUSED)
        self.assertEqual(refused["reason"], "key-unclear")
        self.assertEqual(len(self.store.job_ids()), 1)

    def test_an_unknown_run_id_matches_an_unknown_run_id(self) -> None:
        """No /run/boxa/run-id yet (this Container) must not mean "foreign"."""
        self.assertFalse(os.path.exists(self.run_id_path))
        self.assertEqual(jobs_identity.container_run_id(), "unknown")
        started = self.start("unknown-run", "echo hi")
        record = self.wait_for_state(started["jobId"], {STATE_DONE})
        self.assertEqual(record["worker"]["containerRunId"], "unknown")

    def test_entrypoint_writes_the_run_id_nonce_in_the_root_phase(self) -> None:
        with open(ENTRYPOINT, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn("mkdir -p /run/boxa", text)
        self.assertIn("/run/boxa/run-id", text)
        self.assertIn("chmod 0644 /run/boxa/run-id", text)
        # Root phase only: it must be written before the drop to node.
        run_id_idx = text.find("/run/boxa/run-id")
        node_drop_idx = text.find("--reuid=node")
        self.assertNotEqual(node_drop_idx, -1, "node drop missing")
        self.assertLess(run_id_idx, node_drop_idx)
        # The nonce must actually be a nonce, not just a timestamp.
        self.assertRegex(text, re.compile(r"/dev/urandom[^\n]*\n?[^\n]*run-id"))
        self.assertEqual(
            jobs_identity.DEFAULT_RUN_ID_PATH, "/run/boxa/run-id"
        )


class UnclearKeyTests(OwnershipTestCase):
    def _publish_dead_reservation(self, key: str) -> str:
        """A crash between the reservation and the spawn: reserved, no worker."""
        job_id = new_job_id()
        self.store.publish_reservation(
            key,
            {
                "jobId": job_id,
                "key": key,
                "state": STATE_RESERVED,
                "fingerprint": "fp",
                "argv": ["sh", "-c", "echo hi"],
                "exitCode": None,
                # A pid that is deliberately dead and cannot be this process.
                "worker": {
                    "pid": 2 ** 22,
                    "startTime": 1,
                    "containerRunId": "unknown",
                },
            },
        )
        return job_id

    def test_crash_between_reservation_and_spawn_refuses_a_retry(self) -> None:
        job_id = self._publish_dead_reservation("crashed")
        # Detected lazily on the next call, and not silently retried.
        code, out = run_cli("result", "--json", job_id)
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["state"], STATE_INTERRUPTED)
        self.assertEqual(payload["interruptedReason"], "worker-died-before-spawn")

        blocked = self.start("crashed", "echo hi")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_UNCLEAR)
        self.assertEqual(blocked["jobId"], job_id)
        self.assertEqual(len(self.store.job_ids()), 1)

        # `cancel` is what resolves it — there is nothing alive to kill.
        code, out = run_cli("cancel", "--json", job_id)
        self.assertEqual(code, jobs_cli.EXIT_OK)
        cancelled = json.loads(out)
        self.assertEqual(cancelled["state"], STATE_CANCELLED)
        self.assertEqual(cancelled["killed"], [])

        # Only now may the key run again.
        fresh = self.start("crashed", "echo hi", fresh=True)
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK)
        self.assertEqual(fresh["result"], "started")
        self.assertNotEqual(fresh["jobId"], job_id)
        self.wait_for_state(fresh["jobId"], {STATE_DONE})

    def test_cancel_on_a_clean_terminal_job_kills_nothing(self) -> None:
        started = self.start("finished", "echo hi")
        self.wait_for_state(started["jobId"], {STATE_DONE})
        code, out = run_cli("cancel", "--json", started["jobId"])
        self.assertEqual(code, jobs_cli.EXIT_OK)
        self.assertEqual(json.loads(out)["result"], "already-terminal")
        self.assertEqual(
            self.store.load_record(started["jobId"])["state"], STATE_DONE
        )


class HelpTests(unittest.TestCase):
    def test_help_documents_the_new_states_and_commands(self) -> None:
        help_text = jobs_cli.build_parser().format_help()
        for token in (
            "cancel",
            "adopt",
            STATE_SURVIVORS,
            STATE_ORPHANED,
            STATE_FINISHED_UNKNOWN,
            STATE_INTERRUPTED,
            STATE_CANCELLED,
            "rootless Docker daemon",
        ):
            self.assertIn(token, help_text, f"--help does not mention {token}")
        # No command is pending any more (issue 06 landed `gc`), so the
        # epilog has no "not yet available" section for one to hide in.
        self.assertNotIn("not yet available", help_text)


if __name__ == "__main__":
    unittest.main()
