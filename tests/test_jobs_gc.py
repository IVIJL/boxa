#!/usr/bin/env python3
"""Retention and restart semantics for Jobs (ADR 0037, issue 06).

Run with:

    python3 -m unittest tests.test_jobs_gc    # from repo root
    python3 tests/test_jobs_gc.py             # standalone

Every test points HOME and XDG_STATE_HOME at a fresh tempdir, so the real
per-Project Job state volume (``~/.local/state/boxa/jobs``) is never read or
written.

What is load-bearing here:

  * gc deletes only the bulky artefacts and only of TERMINAL Jobs old enough
    to qualify: a record survives its logs, and a Job that is still running,
    has survivors, is orphaned or is unreadable is never touched;
  * a Codex job's final message survives gc because the worker copied it onto
    the record, so ``result`` still answers after ``last.md`` is gone;
  * ``--purge`` removes the whole record dir AND frees its key reservation;
  * ``--dry-run`` changes nothing on disk;
  * ``start`` sweeps automatically;
  * after a Container restart (a foreign run id against persisted records)
    exactly the foreign non-terminal Jobs become ``interrupted``, including
    when their old worker pid now belongs to a live foreign process.
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from unittest import mock

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from jobs import cli as jobs_cli  # noqa: E402
from jobs import codex as jobs_codex  # noqa: E402
from jobs import gc as jobs_gc  # noqa: E402
from jobs import identity as jobs_identity  # noqa: E402
from jobs import procs as jobs_procs  # noqa: E402
from jobs import recovery  # noqa: E402
from jobs.store import (  # noqa: E402
    STATE_DONE,
    STATE_INTERRUPTED,
    STATE_ORPHANED,
    STATE_RUNNING,
    STATE_SURVIVORS,
    ProjectStore,
    new_job_id,
)

PROJECT_KEY = "/home/vlcak/Projekty/gctest"
CURRENT_RUN = "run-current"
OLD_RUN = "run-previous"
DAY = 86400.0


def run_cli(*argv: str) -> tuple[int, str]:
    """Run boxa-job in-process, returning (exit code, stdout)."""
    buffer = io.StringIO()
    with redirect_stdout(buffer):
        code = jobs_cli.main(list(argv))
    return code, buffer.getvalue()


class GcTestCase(unittest.TestCase):
    """Isolated state tree, overridden Project key and Container run id."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        home = os.path.join(self.tmp.name, "home")
        state = os.path.join(home, ".local", "state")
        os.makedirs(state, exist_ok=True)
        self.run_id_path = os.path.join(self.tmp.name, "run-id")
        with open(self.run_id_path, "w", encoding="utf-8") as fh:
            fh.write(CURRENT_RUN + "\n")
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

    # ------------------------------------------------------------- fixtures

    def make_job(
        self,
        key: str,
        state: str,
        *,
        age_days: float = 0.0,
        run_id: str = CURRENT_RUN,
        worker_pid: int = 2 ** 22,
        worker_start: int = 1,
        codex: bool = False,
        artefacts: tuple[str, ...] = ("stdout", "stderr"),
    ) -> str:
        """A persisted Job record plus its artefacts, aged on disk."""
        job_id = new_job_id(time.time() - age_days * DAY)
        finished = time.time() - age_days * DAY
        record = {
            "jobId": job_id,
            "key": key,
            "state": state,
            "fingerprint": f"fp-{key}",
            "exitCode": 0 if state == STATE_DONE else None,
            "startedAt": finished - 1,
            "worker": {
                "pid": worker_pid,
                "startTime": worker_start,
                "containerRunId": run_id,
            },
        }
        if state in (STATE_DONE, STATE_INTERRUPTED):
            record["finishedAt"] = finished
        job_dir = self.store.job_dir(job_id)
        os.makedirs(job_dir, mode=0o700, exist_ok=True)
        names = list(artefacts)
        if codex:
            record["codexRequest"] = {
                "model": "gpt-5.6",
                "effort": "high",
                "version": "0.149.1",
            }
            record["codex"] = {
                "threadId": "thread-abc",
                "terminalEvent": "turn.completed",
                "finalMessage": "the answer stays on the record",
                "finalMessageTruncated": False,
            }
            names += ["events.jsonl", "last.md"]
        for name in names:
            with open(os.path.join(job_dir, name), "w", encoding="utf-8") as fh:
                fh.write(f"{name} of {job_id}\n" * 4)
        self.store.touch_heartbeat(job_id)
        self.store.publish_reservation(key, record)
        self.age_files(job_id, age_days)
        return job_id

    def age_files(self, job_id: str, age_days: float) -> None:
        """Backdate every file of the Job, record.json included."""
        when = time.time() - age_days * DAY
        job_dir = self.store.job_dir(job_id)
        for name in os.listdir(job_dir):
            os.utime(os.path.join(job_dir, name), (when, when))

    def artefacts(self, job_id: str) -> set[str]:
        return set(os.listdir(self.store.job_dir(job_id)))


class SweepTests(GcTestCase):
    def test_old_terminal_job_loses_artefacts_but_keeps_its_record(self) -> None:
        job_id = self.make_job("old", STATE_DONE, age_days=20, codex=True)
        outcome = jobs_gc.run(self.store)
        self.assertEqual([entry.job_id for entry in outcome.entries], [job_id])
        left = self.artefacts(job_id)
        self.assertEqual(left, {"record.json"})
        record = self.store.load_record(job_id)
        self.assertEqual(record["state"], STATE_DONE)
        self.assertEqual(record["exitCode"], 0)
        self.assertIsNotNone(record["gcAt"])
        self.assertIn("stdout", record["gcRemoved"])
        # The durable summary is still the whole answer: key, state, exit and
        # the Codex final message (copied onto the record at finish).
        self.assertEqual(record["key"], "old")
        self.assertEqual(
            record["codex"]["finalMessage"], "the answer stays on the record"
        )
        self.assertEqual(self.store.key_job_id("old"), job_id)

    def test_result_still_answers_after_a_sweep(self) -> None:
        job_id = self.make_job("old", STATE_DONE, age_days=20, codex=True)
        jobs_gc.run(self.store)
        code, out = run_cli("result", job_id, "--json")
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["state"], STATE_DONE)
        self.assertEqual(payload["exitCode"], 0)
        self.assertIsNotNone(payload["gcAt"])
        self.assertEqual(
            payload["codex"]["finalMessage"], "the answer stays on the record"
        )
        _, human = run_cli("result", job_id)
        self.assertIn("artefacts: removed by gc", human)
        # `log` says why there is nothing rather than printing nothing at all.
        _, log_out = run_cli("log", job_id)
        self.assertIn("gc removed this Job's artefacts", log_out)

    def test_fresh_and_non_terminal_jobs_are_never_touched(self) -> None:
        fresh = self.make_job("fresh", STATE_DONE, age_days=1)
        running = self.make_job("running", STATE_RUNNING, age_days=99)
        survivors = self.make_job("survivors", STATE_SURVIVORS, age_days=99)
        orphaned = self.make_job("orphaned", STATE_ORPHANED, age_days=99)
        outcome = jobs_gc.run(self.store)
        self.assertEqual(outcome.entries, [])
        self.assertEqual(outcome.kept, 4)
        for job_id in (fresh, running, survivors, orphaned):
            self.assertIn("stdout", self.artefacts(job_id))

    def test_unreadable_record_is_kept_not_collected(self) -> None:
        job_id = self.make_job("broken", STATE_DONE, age_days=99)
        with open(self.store.record_path(job_id), "w", encoding="utf-8") as fh:
            fh.write("{ not json")
        self.age_files(job_id, 99)
        outcome = jobs_gc.run(self.store)
        self.assertEqual(outcome.entries, [])
        self.assertEqual(outcome.kept, 1)
        self.assertIn("stdout", self.artefacts(job_id))

    def test_recent_artefact_protects_an_old_finishedat(self) -> None:
        """Age is the YOUNGEST evidence: a fresh file keeps the Job alive."""
        job_id = self.make_job("mixed", STATE_DONE, age_days=99)
        with open(self.store.stdout_path(job_id), "a", encoding="utf-8") as fh:
            fh.write("touched now\n")
        self.assertEqual(jobs_gc.run(self.store).entries, [])
        self.assertIn("stdout", self.artefacts(job_id))

    def test_older_than_threshold_is_honoured(self) -> None:
        job_id = self.make_job("week", STATE_DONE, age_days=7)
        self.assertEqual(jobs_gc.run(self.store).entries, [])
        outcome = jobs_gc.run(self.store, older_than_days=3)
        self.assertEqual([entry.job_id for entry in outcome.entries], [job_id])
        self.assertEqual(self.artefacts(job_id), {"record.json"})

    def test_an_already_swept_job_is_not_reported_again(self) -> None:
        self.make_job("old", STATE_DONE, age_days=20)
        first = jobs_gc.run(self.store)
        self.assertEqual(len(first.entries), 1)
        second = jobs_gc.run(self.store)
        self.assertEqual(second.entries, [])
        self.assertEqual(second.kept, 1)


class DryRunTests(GcTestCase):
    def test_dry_run_lists_and_touches_nothing(self) -> None:
        job_id = self.make_job("old", STATE_DONE, age_days=20)
        before = {
            name: os.stat(os.path.join(self.store.job_dir(job_id), name)).st_mtime
            for name in self.artefacts(job_id)
        }
        code, out = run_cli("gc", "--dry-run", "--json")
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertTrue(payload["dryRun"])
        self.assertEqual(payload["count"], 1)
        self.assertEqual(payload["jobs"][0]["jobId"], job_id)
        self.assertIn("stdout", payload["jobs"][0]["files"])
        after = {
            name: os.stat(os.path.join(self.store.job_dir(job_id), name)).st_mtime
            for name in self.artefacts(job_id)
        }
        self.assertEqual(before, after)
        self.assertIsNone(self.store.load_record(job_id).get("gcAt"))

    def test_dry_run_purge_keeps_the_record_and_the_key(self) -> None:
        job_id = self.make_job("old", STATE_DONE, age_days=20)
        code, out = run_cli("gc", "--purge", "--dry-run", "--json")
        self.assertEqual(code, jobs_cli.EXIT_OK)
        self.assertEqual(json.loads(out)["count"], 1)
        self.assertIsNotNone(self.store.load_record(job_id))
        self.assertEqual(self.store.key_job_id("old"), job_id)


class PurgeTests(GcTestCase):
    def test_purge_removes_the_record_and_frees_the_key(self) -> None:
        job_id = self.make_job("gone", STATE_DONE, age_days=20)
        code, out = run_cli("gc", "--purge", "--older-than", "14", "--json")
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertTrue(payload["purge"])
        self.assertEqual(payload["count"], 1)
        self.assertFalse(os.path.exists(self.store.job_dir(job_id)))
        self.assertIsNone(self.store.key_job_id("gone"))
        # A purged key is free: the same key starts a new Job without --fresh.
        code, out = run_cli(
            "start", "--json", "--key", "gone", "--", "true"
        )
        self.assertEqual(code, jobs_cli.EXIT_OK)
        started = json.loads(out)
        self.assertEqual(started["result"], "started")
        self.assertNotEqual(started["jobId"], job_id)

    def test_purge_never_takes_a_non_terminal_job(self) -> None:
        running = self.make_job("running", STATE_RUNNING, age_days=99)
        survivors = self.make_job("survivors", STATE_SURVIVORS, age_days=99)
        code, out = run_cli("gc", "--purge", "--older-than", "1", "--json")
        self.assertEqual(code, jobs_cli.EXIT_OK)
        self.assertEqual(json.loads(out)["count"], 0)
        for key, job_id in (("running", running), ("survivors", survivors)):
            self.assertTrue(os.path.exists(self.store.job_dir(job_id)))
            self.assertEqual(self.store.key_job_id(key), job_id)

    def test_negative_threshold_is_a_usage_error(self) -> None:
        code, _ = run_cli("gc", "--older-than", "-1")
        self.assertEqual(code, jobs_cli.EXIT_USAGE)


class AutomaticSweepTests(GcTestCase):
    def test_start_sweeps_old_artefacts_first(self) -> None:
        old = self.make_job("old", STATE_DONE, age_days=20)
        code, out = run_cli(
            "start", "--json", "--key", "new", "--ack-concurrent", "", "--", "true"
        )
        # Only the new Job is registered; the old one is terminal, so no ack
        # is needed and the sweep has already run by the time it returns.
        self.assertEqual(code, jobs_cli.EXIT_OK, out)
        self.assertEqual(self.artefacts(old), {"record.json"})
        self.assertIsNotNone(self.store.load_record(old).get("gcAt"))

    def test_a_broken_sweep_never_breaks_a_start(self) -> None:
        self.make_job("old", STATE_DONE, age_days=20)
        with mock.patch.object(
            jobs_gc, "run", side_effect=OSError("disk on fire")
        ):
            self.assertIsNone(jobs_gc.sweep_quietly(self.store))
            code, _ = run_cli("start", "--json", "--key", "new", "--", "true")
        self.assertEqual(code, jobs_cli.EXIT_OK)


class RestartTests(GcTestCase):
    """A Container restart against persisted records (the volume's whole point)."""

    def test_only_foreign_non_terminal_records_flip_to_interrupted(self) -> None:
        # A live foreign process the old record's worker pid now points at:
        # the identity check must not save the record, because the run id is
        # already wrong before any pid is looked at.
        stolen_pid = os.getpid()
        foreign_running = self.make_job(
            "foreign-running", STATE_RUNNING, run_id=OLD_RUN, worker_pid=stolen_pid
        )
        foreign_reserved = self.make_job(
            "foreign-reserved", STATE_ORPHANED, run_id=OLD_RUN
        )
        foreign_done = self.make_job(
            "foreign-done", STATE_DONE, run_id=OLD_RUN, age_days=1
        )
        # This run's own record with a genuinely live worker: the restart
        # sweep has no business rewriting it at all.
        mine = jobs_procs.identity_of(os.getpid())
        mine_running = self.make_job(
            "mine-running",
            STATE_RUNNING,
            worker_pid=os.getpid(),
            worker_start=mine["startTime"],
        )
        mine_done = self.make_job("mine-done", STATE_DONE)

        recovery.refresh_states(self.store, run_id=CURRENT_RUN)

        for job_id in (foreign_running, foreign_reserved):
            record = self.store.load_record(job_id)
            self.assertEqual(record["state"], STATE_INTERRUPTED, job_id)
            self.assertEqual(record["interruptedReason"], "container-restart")
            self.assertIsNotNone(record["finishedAt"])
        # Terminal records and this run's own records are left exactly alone.
        self.assertEqual(self.store.load_record(foreign_done)["state"], STATE_DONE)
        self.assertEqual(self.store.load_record(mine_done)["state"], STATE_DONE)
        self.assertEqual(
            self.store.load_record(mine_running)["state"], STATE_RUNNING
        )

    def test_an_interrupted_job_keeps_its_logs_and_its_key(self) -> None:
        job_id = self.make_job(
            "restart-proof", STATE_RUNNING, run_id=OLD_RUN
        )
        code, out = run_cli("list", "--json")
        self.assertEqual(code, jobs_cli.EXIT_OK)
        rows = {row["jobId"]: row["state"] for row in json.loads(out)["jobs"]}
        self.assertEqual(rows[job_id], STATE_INTERRUPTED)
        # The logs of the previous Container run survived the restart.
        _, log_out = run_cli("log", job_id, "--tail", "2")
        self.assertIn(job_id, log_out)
        # An interrupted key is unclear, never silently re-run (ADR 0037).
        code, out = run_cli("start", "--json", "--key", "restart-proof", "--", "true")
        self.assertEqual(code, jobs_cli.EXIT_UNCLEAR)
        payload = json.loads(out)
        self.assertEqual(payload["jobId"], job_id)
        self.assertEqual(payload["state"], STATE_INTERRUPTED)

    def test_interrupted_artefacts_are_collected_once_old(self) -> None:
        job_id = self.make_job(
            "old-interrupted", STATE_INTERRUPTED, age_days=20, run_id=OLD_RUN
        )
        outcome = jobs_gc.run(self.store)
        self.assertEqual([entry.job_id for entry in outcome.entries], [job_id])
        self.assertEqual(self.artefacts(job_id), {"record.json"})


class FinalMessageTests(unittest.TestCase):
    """The record must outlive ``last.md``, without becoming a log itself."""

    def test_a_huge_final_message_is_capped_and_flagged(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "last.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("x" * (jobs_codex.FINAL_MESSAGE_RECORD_BYTES + 5000))
            extract = jobs_codex.stream_extract(
                os.path.join(tmp, "missing-events.jsonl"), path, {}
            )
        self.assertTrue(extract["finalMessageTruncated"])
        self.assertEqual(
            len(extract["finalMessage"].encode("utf-8")),
            jobs_codex.FINAL_MESSAGE_RECORD_BYTES,
        )

    def test_a_normal_final_message_is_stored_whole(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "last.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("short answer\n")
            extract = jobs_codex.stream_extract(
                os.path.join(tmp, "missing-events.jsonl"), path, {}
            )
        self.assertEqual(extract["finalMessage"], "short answer")
        self.assertFalse(extract["finalMessageTruncated"])


if __name__ == "__main__":
    unittest.main()
