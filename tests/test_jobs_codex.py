#!/usr/bin/env python3
"""Codex jobs: `start --codex`, `reply`, and the event-derived outcome (issue 04).

Run with:

    PYTHONPATH=scripts python3 -m unittest tests.test_jobs_codex   # repo root
    python3 tests/test_jobs_codex.py                               # standalone

No test here spends money.  The event streams under ``tests/fixtures/jobs/``
are RAW captures of real ``codex exec --json`` runs in a boxa Container
(codex-cli 0.149.1, ``gpt-5.6-luna``, effort low), kept verbatim — including
one model reply that came back in Czech — because their value is being exactly
what Codex emits, and an edited capture proves nothing about the real stream.
The one exception is named as such: ``codex-error-then-completed.jsonl`` is the
recorded ``error`` stream with the recorded ``turn.completed`` line of a good
run appended, because the ordering it tests (a failure followed by a completed
turn) is not something a live run can be asked for on demand.
The CLI-level tests run a fake ``codex`` shell script that cats one of those
fixtures (or sleeps), which is also how a ``thread-busy`` refusal is provoked
without a live turn.

What is load-bearing here:

  * ``done`` needs BOTH a ``turn.completed`` event and exit 0: a killed
    ``codex exec`` exits 0 with no terminal event, and calling that ``done``
    is the one lie this design must not tell (ADR 0037 "States and honesty");
  * ``turn.failed`` / a top-level ``error`` event become ``failed`` carrying
    Codex's own message, while an ``error`` *item* inside ``item.completed``
    is a warning a good run survives;
  * the thread id reaches the record mid-run, because ``reply`` and ``result``
    need it while the turn is still in flight;
  * the result is an extract — thread id, final message, usage, item counts —
    and never the event log;
  * ``--model``/``--effort`` are required: a missing one is a usage error that
    reserves nothing;
  * one thread runs one Job: ``reply`` into a busy thread is refused
    ``thread-busy`` with its own exit code, and the refusal beats the
    concurrency ack to the answer.
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
from jobs import codex as jobs_codex  # noqa: E402
from jobs import identity as jobs_identity  # noqa: E402
from jobs import runtime as jobs_runtime  # noqa: E402
from jobs.store import (  # noqa: E402
    STATE_CANCELLED,
    STATE_DONE,
    STATE_FAILED,
    STATE_FINISHED_UNKNOWN,
    ProjectStore,
)

FIXTURES = os.path.join(_REPO_ROOT, "tests", "fixtures", "jobs")
PROJECT_KEY = "/home/vlcak/Projekty/testproj-codex"

# A Codex job here is a fake `codex` that cats a fixture: seconds, not minutes.
JOB_TIMEOUT = 30.0

MODEL = "gpt-5.6-luna"
EFFORT = "low"


def fixture(name: str) -> str:
    return os.path.join(FIXTURES, name)


def _run_cli(*argv: str) -> tuple[int, str]:
    buffer = io.StringIO()
    with redirect_stdout(buffer):
        code = jobs_cli.main(list(argv))
    return code, buffer.getvalue()


# --------------------------------------------------------------- pure parsing


class StreamSummaryTests(unittest.TestCase):
    """The recorded streams, read exactly as the worker reads them."""

    def test_done_stream_yields_thread_usage_and_item_counts(self) -> None:
        summary = jobs_codex.summarize_stream(fixture("codex-done.jsonl"))
        self.assertEqual(
            summary.thread_id, "01a094e8-21fc-7641-beef-44dadd0b0235"
        )
        self.assertEqual(summary.terminal, "turn.completed")
        self.assertEqual(summary.usage["input_tokens"], 33767)
        self.assertEqual(summary.usage["output_tokens"], 96)
        # Counted by item identity: `file_change` appears as item.started AND
        # item.completed and is still one file change.
        self.assertEqual(
            summary.item_counts, {"agent_message": 2, "file_change": 1}
        )
        self.assertIsNone(summary.error)
        self.assertEqual(summary.malformed_lines, 0)

    def test_killed_stream_has_a_thread_but_no_terminal_event(self) -> None:
        summary = jobs_codex.summarize_stream(
            fixture("codex-killed-no-terminal.jsonl")
        )
        self.assertEqual(
            summary.thread_id, "01a094e8-6fc8-77c3-bcd0-433d469d6850"
        )
        self.assertIsNone(summary.terminal)
        self.assertIsNone(summary.usage)
        self.assertEqual(summary.item_counts["command_execution"], 1)

    def test_turn_failed_carries_codex_own_message(self) -> None:
        summary = jobs_codex.summarize_stream(fixture("codex-turn-failed.jsonl"))
        self.assertEqual(summary.terminal, "turn.failed")
        self.assertIn("not supported", summary.error)
        # An `error` ITEM is a warning Codex kept running through: it is
        # counted as work seen, not treated as the turn's verdict.
        self.assertEqual(summary.item_counts.get("error"), 1)

    def test_error_event_without_turn_failed_is_still_terminal(self) -> None:
        summary = jobs_codex.summarize_stream(fixture("codex-error-event.jsonl"))
        self.assertEqual(summary.terminal, "error")
        self.assertIn("not supported", summary.error)

    def test_an_error_event_survives_a_later_turn_completed(self) -> None:
        """A stated failure is sticky: line order must not rewrite the verdict.

        The fixture is the recorded ``error`` stream with the recorded
        ``turn.completed`` of a good run appended, i.e. exactly the shape that
        would otherwise report a Job that Codex said failed as ``done``.
        """
        summary = jobs_codex.summarize_stream(
            fixture("codex-error-then-completed.jsonl")
        )
        self.assertEqual(summary.terminal, "error")
        self.assertIn("not supported", summary.error)
        # The usage of the completed turn is still recorded: it happened.
        self.assertEqual(summary.usage["output_tokens"], 96)

    def test_used_model_and_effort_are_null_when_the_stream_is_silent(self) -> None:
        """codex-cli 0.149.1 never says it: honest null beats an invented echo."""
        summary = jobs_codex.summarize_stream(fixture("codex-done.jsonl"))
        self.assertIsNone(summary.used_model)
        self.assertIsNone(summary.used_effort)

    def test_malformed_and_missing_streams_do_not_raise(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "events.jsonl")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("not json\n")
                fh.write('{"type":"thread.started","thread_id":"t1"}\n')
            summary = jobs_codex.summarize_stream(path)
            self.assertEqual(summary.thread_id, "t1")
            self.assertEqual(summary.malformed_lines, 1)
            missing = jobs_codex.summarize_stream(os.path.join(tmp, "nope"))
            self.assertIsNone(missing.thread_id)

    def test_thread_id_of_reads_the_first_event_only(self) -> None:
        self.assertEqual(
            jobs_codex.thread_id_of(fixture("codex-resume-done.jsonl")),
            "01a094e8-21fc-7641-beef-44dadd0b0235",
        )


class OutcomeTests(unittest.TestCase):
    """The rule that makes a Codex job honest about how it ended."""

    def _summary(self, name: str) -> jobs_codex.StreamSummary:
        return jobs_codex.summarize_stream(fixture(name))

    def test_terminal_event_plus_exit_zero_is_done(self) -> None:
        outcome = jobs_codex.derive_outcome(self._summary("codex-done.jsonl"), 0)
        self.assertEqual(outcome.state, STATE_DONE)
        self.assertIsNone(outcome.reason)

    def test_exit_zero_without_terminal_event_is_failed(self) -> None:
        outcome = jobs_codex.derive_outcome(
            self._summary("codex-killed-no-terminal.jsonl"), 0
        )
        self.assertEqual(outcome.state, STATE_FAILED)
        self.assertEqual(outcome.reason, jobs_codex.REASON_NO_TERMINAL_EVENT)

    def test_turn_failed_is_failed_with_the_message(self) -> None:
        outcome = jobs_codex.derive_outcome(
            self._summary("codex-turn-failed.jsonl"), 1
        )
        self.assertEqual(outcome.state, STATE_FAILED)
        self.assertEqual(outcome.reason, jobs_codex.REASON_TURN_FAILED)
        self.assertIn("not supported", outcome.error)

    def test_error_event_is_failed_even_on_exit_zero(self) -> None:
        outcome = jobs_codex.derive_outcome(
            self._summary("codex-error-event.jsonl"), 0
        )
        self.assertEqual(outcome.state, STATE_FAILED)
        self.assertEqual(outcome.reason, jobs_codex.REASON_STREAM_ERROR)

    def test_error_then_turn_completed_on_exit_zero_is_still_failed(self) -> None:
        """ADR 0037: any top-level `error` event fails the Job, order aside."""
        outcome = jobs_codex.derive_outcome(
            self._summary("codex-error-then-completed.jsonl"), 0
        )
        self.assertEqual(outcome.state, STATE_FAILED)
        self.assertEqual(outcome.reason, jobs_codex.REASON_STREAM_ERROR)
        self.assertIn("not supported", outcome.error)

    def test_nonzero_exit_without_any_event_is_failed(self) -> None:
        outcome = jobs_codex.derive_outcome(
            self._summary("codex-killed-no-terminal.jsonl"), 3
        )
        self.assertEqual(outcome.state, STATE_FAILED)
        self.assertEqual(outcome.reason, jobs_codex.REASON_NONZERO_EXIT)

    def test_cancel_beats_everything(self) -> None:
        """A killed run is never a failure, whatever its stream says."""
        for name in ("codex-done.jsonl", "codex-killed-no-terminal.jsonl"):
            outcome = jobs_codex.derive_outcome(
                self._summary(name), 0, cancel_requested=True
            )
            self.assertEqual(outcome.state, STATE_CANCELLED)

    def test_unknown_exit_code_is_finished_unknown_despite_turn_completed(
        self,
    ) -> None:
        """The terminal event is evidence the turn ended, not proof of a clean exit."""
        outcome = jobs_codex.derive_outcome(self._summary("codex-done.jsonl"), None)
        self.assertEqual(outcome.state, STATE_FINISHED_UNKNOWN)


class ArgvTests(unittest.TestCase):
    """The flag sets verified against codex-cli 0.149.1 in a Container."""

    def test_start_argv_bypasses_the_sandbox_and_pins_model_and_effort(self) -> None:
        argv = jobs_codex.start_argv(
            "/bin/codex",
            model=MODEL,
            effort=EFFORT,
            cwd="/work",
            last_message="/jobs/j1/last.md",
            prompt="hi",
        )
        self.assertEqual(argv[:3], ["/bin/codex", "exec", "--json"])
        self.assertIn("--dangerously-bypass-approvals-and-sandbox", argv)
        self.assertIn("--skip-git-repo-check", argv)
        self.assertEqual(argv[argv.index("-m") + 1], MODEL)
        self.assertIn(f"model_reasoning_effort={EFFORT}", argv)
        self.assertEqual(argv[argv.index("-C") + 1], "/work")
        self.assertEqual(argv[argv.index("-o") + 1], "/jobs/j1/last.md")
        self.assertEqual(argv[-1], "hi")

    def test_resume_argv_omits_the_flags_resume_rejects(self) -> None:
        argv = jobs_codex.resume_argv(
            "/bin/codex",
            thread_id="t-1",
            model=MODEL,
            effort=EFFORT,
            last_message="/jobs/j2/last.md",
            prompt="again",
        )
        self.assertEqual(argv[:4], ["/bin/codex", "exec", "resume", "t-1"])
        # `codex exec resume` accepts neither -C nor -s: the worker supplies
        # the original Job's cwd by spawning the child there instead.
        self.assertNotIn("-C", argv)
        self.assertNotIn("-s", argv)
        self.assertEqual(argv[-1], "again")

    def test_fingerprint_ignores_the_binary_and_the_job_dir(self) -> None:
        """Same request, different runtime copy / job dir: still the same request."""
        first = jobs_codex.fingerprint_argv(
            model=MODEL, effort=EFFORT, cwd="/work", prompt="contract"
        )
        second = jobs_codex.fingerprint_argv(
            model=MODEL, effort=EFFORT, cwd="/work", prompt="contract"
        )
        self.assertEqual(first, second)
        self.assertIn("contract", first)
        self.assertNotIn("-o", first)
        changed = jobs_codex.fingerprint_argv(
            model=MODEL, effort=EFFORT, cwd="/work", prompt="other"
        )
        self.assertNotEqual(first, changed)

    def test_resolve_binary_refuses_when_there_is_no_verified_runtime(self) -> None:
        """No PATH fallback: a Codex job runs only from a verified copy.

        The runtime itself is tested in ``tests/test_jobs_runtime.py``; what
        matters here is that the seam still refuses with ``CodexNotFound``
        when it has nothing to hand back.
        """
        with tempfile.TemporaryDirectory() as empty:
            with mock.patch.dict(
                os.environ,
                {
                    jobs_codex.CODEX_BIN_ENV: "",
                    jobs_runtime.CODEX_VERSIONS_DIR_ENV: os.path.join(
                        empty, "versions"
                    ),
                    jobs_runtime.CODEX_NPM_PKG_DIR_ENV: os.path.join(empty, "npm"),
                    jobs_runtime.CODEX_HOST_PKG_DIR_ENV: os.path.join(empty, "host"),
                },
            ):
                with self.assertRaises(jobs_codex.CodexNotFound):
                    jobs_codex.resolve_binary()


# ------------------------------------------------------------------ CLI level


class CodexCliTestCase(unittest.TestCase):
    """Isolated state tree, isolated Project key, and a fake `codex` on disk."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        home = os.path.join(self.tmp.name, "home")
        state = os.path.join(home, ".local", "state")
        os.makedirs(state, exist_ok=True)
        self.bin_dir = os.path.join(self.tmp.name, "bin")
        os.makedirs(self.bin_dir, exist_ok=True)
        self.work = os.path.join(self.tmp.name, "work")
        os.makedirs(self.work, exist_ok=True)
        patcher = mock.patch.dict(
            os.environ,
            {
                "HOME": home,
                "XDG_STATE_HOME": state,
                jobs_identity.PROJECT_KEY_ENV: PROJECT_KEY,
                jobs_identity.RUN_ID_PATH_ENV: os.path.join(self.tmp.name, "run-id"),
                jobs_codex.CODEX_BIN_ENV: self.fake_codex("codex-ok.jsonl"),
            },
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        self.store = ProjectStore(PROJECT_KEY)
        self.store.ensure()
        self.addCleanup(self._kill_leftover_jobs)

    def fake_codex(self, stream: str, sleep_seconds: int = 0) -> str:
        """A `codex` that emits a recorded stream (and optionally hangs).

        It honours ``-o`` and ``--version`` because the Job's result reads
        both; everything else about the argv it ignores, which is the point —
        the real flags are asserted in :class:`ArgvTests`.
        """
        path = os.path.join(self.bin_dir, f"codex-{stream}-{sleep_seconds}")
        script = f"""#!/bin/bash
if [ "$1" = "--version" ]; then echo "codex-cli 0.149.1-fake"; exit 0; fi
prev=""
out=""
for arg in "$@"; do
    if [ "$prev" = "-o" ]; then out="$arg"; fi
    prev="$arg"
done
cat {fixture(stream)!r}
if [ -n "$out" ]; then printf 'fake final message\\n' > "$out"; fi
sleep {sleep_seconds}
exit 0
"""
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(script)
        os.chmod(path, 0o755)
        return path

    def _kill_leftover_jobs(self) -> None:
        for record in self.store.records():
            if record.get("state") in {STATE_DONE, STATE_FAILED}:
                continue
            for entry in (record.get("worker"), record.get("command")):
                pid = (entry or {}).get("pid")
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
        self.fail(
            f"job {job_id} never reached {states}: {self.store.load_record(job_id)}"
        )

    def wait_for_thread_id(self, job_id: str) -> str:
        deadline = time.time() + JOB_TIMEOUT
        while time.time() < deadline:
            record = self.store.load_record(job_id) or {}
            if record.get("threadId"):
                return str(record["threadId"])
            time.sleep(0.05)
        self.fail(f"job {job_id} never published a thread id")

    def start_codex(self, key: str, prompt: str = "hello", *extra: str) -> dict:
        code, out = _run_cli(
            "start",
            "--key",
            key,
            "--codex",
            "--model",
            MODEL,
            "--effort",
            EFFORT,
            "--cwd",
            self.work,
            "--json",
            *extra,
            prompt,
        )
        self.last_exit = code
        return json.loads(out)


class UsageTests(CodexCliTestCase):
    def _nothing_reserved(self) -> None:
        self.assertEqual(self.store.job_ids(), [])
        self.assertEqual(os.listdir(self.store.keys_dir), [])

    def test_missing_model_is_a_usage_error_that_reserves_nothing(self) -> None:
        code, out = _run_cli(
            "start", "--key", "k", "--codex", "--effort", EFFORT, "hi"
        )
        self.assertEqual(code, jobs_cli.EXIT_USAGE)
        self.assertEqual(out, "")
        self._nothing_reserved()

    def test_missing_effort_is_a_usage_error_that_reserves_nothing(self) -> None:
        code, _ = _run_cli(
            "start", "--key", "k", "--codex", "--model", MODEL, "hi"
        )
        self.assertEqual(code, jobs_cli.EXIT_USAGE)
        self._nothing_reserved()

    def test_missing_prompt_is_a_usage_error(self) -> None:
        code, _ = _run_cli(
            "start",
            "--key",
            "k",
            "--codex",
            "--model",
            MODEL,
            "--effort",
            EFFORT,
        )
        self.assertEqual(code, jobs_cli.EXIT_USAGE)
        self._nothing_reserved()

    def test_several_positionals_are_refused_rather_than_joined(self) -> None:
        """A prompt split by the shell is a different prompt: refuse, never guess."""
        code, _ = _run_cli(
            "start",
            "--key",
            "k",
            "--codex",
            "--model",
            MODEL,
            "--effort",
            EFFORT,
            "two",
            "words",
        )
        self.assertEqual(code, jobs_cli.EXIT_USAGE)
        self._nothing_reserved()

    def test_model_without_codex_is_a_usage_error(self) -> None:
        code, _ = _run_cli(
            "start", "--key", "k", "--model", MODEL, "--", "true"
        )
        self.assertEqual(code, jobs_cli.EXIT_USAGE)
        self._nothing_reserved()

    def test_reply_needs_model_and_effort(self) -> None:
        code, _ = _run_cli("reply", "some-thread", "--key", "k", "hi")
        self.assertEqual(code, jobs_cli.EXIT_USAGE)
        self._nothing_reserved()

    def test_reply_to_an_unknown_target_is_not_found(self) -> None:
        code, out = _run_cli(
            "reply",
            "no-such-thread",
            "--key",
            "k",
            "--model",
            MODEL,
            "--effort",
            EFFORT,
            "--json",
            "hi",
        )
        self.assertEqual(code, jobs_cli.EXIT_UNCLEAR)
        self.assertEqual(json.loads(out)["result"], "not-found")


class CodexJobTests(CodexCliTestCase):
    def test_done_job_records_thread_usage_items_and_final_message(self) -> None:
        started = self.start_codex("ok")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_OK)
        job_id = started["jobId"]
        self.wait_for_state(job_id, {STATE_DONE})

        code, out = _run_cli("result", job_id, "--json")
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["state"], STATE_DONE)
        codex = payload["codex"]
        self.assertEqual(codex["threadId"], "01a094e0-7de0-7331-b51a-c8b256106ceb")
        self.assertEqual(payload["threadId"], codex["threadId"])
        self.assertEqual(codex["terminalEvent"], "turn.completed")
        self.assertEqual(codex["requestedModel"], MODEL)
        self.assertEqual(codex["requestedEffort"], EFFORT)
        self.assertIsNone(codex["usedModel"])
        self.assertEqual(codex["codexVersion"], "codex-cli 0.149.1-fake")
        self.assertEqual(codex["usage"]["output_tokens"], 5)
        self.assertEqual(codex["itemCounts"], {"agent_message": 1})
        self.assertEqual(codex["finalMessage"], "fake final message")
        # The result is an extract: no event text, no raw stream, anywhere.
        self.assertNotIn("thread.started", out)
        self.assertNotIn("turn.completed\\", out)

    def test_result_never_carries_the_event_log_but_log_shows_it(self) -> None:
        job_id = self.start_codex("logged")["jobId"]
        self.wait_for_state(job_id, {STATE_DONE})
        _, result_out = _run_cli("result", job_id)
        self.assertNotIn('{"type":', result_out)
        _, log_out = _run_cli("log", job_id, "--tail", "10")
        self.assertIn("--- events", log_out)
        self.assertIn('"type":"thread.started"', log_out)

    def test_stream_without_a_terminal_event_fails_instead_of_done(self) -> None:
        with mock.patch.dict(
            os.environ,
            {jobs_codex.CODEX_BIN_ENV: self.fake_codex("codex-killed-no-terminal.jsonl")},
        ):
            job_id = self.start_codex("killed")["jobId"]
        record = self.wait_for_state(job_id, {STATE_DONE, STATE_FAILED})
        self.assertEqual(record["state"], STATE_FAILED)
        self.assertEqual(record["exitCode"], 0)
        self.assertEqual(
            record["codexReason"], jobs_codex.REASON_NO_TERMINAL_EVENT
        )

    def test_turn_failed_stream_fails_with_codex_message(self) -> None:
        with mock.patch.dict(
            os.environ,
            {jobs_codex.CODEX_BIN_ENV: self.fake_codex("codex-turn-failed.jsonl")},
        ):
            job_id = self.start_codex("failed")["jobId"]
        record = self.wait_for_state(job_id, {STATE_DONE, STATE_FAILED})
        self.assertEqual(record["state"], STATE_FAILED)
        self.assertEqual(record["codexReason"], jobs_codex.REASON_TURN_FAILED)
        self.assertIn("not supported", record["error"])

    def test_error_then_completed_stream_fails_the_whole_job(self) -> None:
        """End to end: exit 0 plus `error` then `turn.completed` is not `done`."""
        with mock.patch.dict(
            os.environ,
            {
                jobs_codex.CODEX_BIN_ENV: self.fake_codex(
                    "codex-error-then-completed.jsonl"
                )
            },
        ):
            job_id = self.start_codex("error-then-done")["jobId"]
        record = self.wait_for_state(job_id, {STATE_DONE, STATE_FAILED})
        self.assertEqual(record["state"], STATE_FAILED)
        self.assertEqual(record["exitCode"], 0)
        self.assertEqual(record["codexReason"], jobs_codex.REASON_STREAM_ERROR)
        self.assertIn("not supported", record["error"])

    def test_thread_id_lands_on_the_record_while_the_job_still_runs(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                jobs_codex.CODEX_BIN_ENV: self.fake_codex(
                    "codex-ok.jsonl", sleep_seconds=20
                )
            },
        ):
            job_id = self.start_codex("midrun")["jobId"]
            thread_id = self.wait_for_thread_id(job_id)
        self.assertEqual(thread_id, "01a094e0-7de0-7331-b51a-c8b256106ceb")
        record = self.store.load_record(job_id)
        self.assertNotIn(record["state"], (STATE_DONE, STATE_FAILED))
        # `result` on a running Codex job already answers "which thread?".
        _, out = _run_cli("result", job_id, "--json")
        self.assertEqual(json.loads(out)["threadId"], thread_id)

    def test_same_key_and_prompt_attaches_instead_of_paying_twice(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                jobs_codex.CODEX_BIN_ENV: self.fake_codex(
                    "codex-ok.jsonl", sleep_seconds=20
                )
            },
        ):
            first = self.start_codex("attach", "same prompt")
            second = self.start_codex("attach", "same prompt")
        self.assertEqual(second["result"], "attached")
        self.assertEqual(second["jobId"], first["jobId"])

    def test_a_different_prompt_under_one_key_is_a_conflict(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                jobs_codex.CODEX_BIN_ENV: self.fake_codex(
                    "codex-ok.jsonl", sleep_seconds=20
                )
            },
        ):
            self.start_codex("conflict", "first prompt")
            payload = self.start_codex("conflict", "second prompt")
        self.assertEqual(self.last_exit, jobs_cli.EXIT_CONFLICT)
        self.assertEqual(payload["reason"], "fingerprint-mismatch")

    def test_prompt_file_is_the_same_request_as_the_argument(self) -> None:
        prompt_path = os.path.join(self.tmp.name, "contract.md")
        with open(prompt_path, "w", encoding="utf-8") as fh:
            fh.write("a long frozen contract")
        with mock.patch.dict(
            os.environ,
            {
                jobs_codex.CODEX_BIN_ENV: self.fake_codex(
                    "codex-ok.jsonl", sleep_seconds=20
                )
            },
        ):
            first = self.start_codex("promptfile", "a long frozen contract")
            code, out = _run_cli(
                "start",
                "--key",
                "promptfile",
                "--codex",
                "--model",
                MODEL,
                "--effort",
                EFFORT,
                "--cwd",
                self.work,
                "--prompt-file",
                prompt_path,
                "--json",
            )
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["result"], "attached")
        self.assertEqual(payload["jobId"], first["jobId"])


class ReplyTests(CodexCliTestCase):
    def _finished_thread(self, key: str = "parent") -> tuple[str, str]:
        """A finished Codex job whose thread the resume fixture continues.

        The two fixtures are a real matched pair: ``codex-done.jsonl`` and
        ``codex-resume-done.jsonl`` were captured from one live thread
        (`start` wrote a file, `reply` recalled its content), so a reply here
        reports the same thread id a real resume would.
        """
        with mock.patch.dict(
            os.environ,
            {jobs_codex.CODEX_BIN_ENV: self.fake_codex("codex-done.jsonl")},
        ):
            job_id = self.start_codex(key)["jobId"]
        record = self.wait_for_state(job_id, {STATE_DONE})
        return job_id, str(record["threadId"])

    def test_reply_by_thread_id_runs_resume_on_the_same_thread(self) -> None:
        parent_id, thread_id = self._finished_thread()
        with mock.patch.dict(
            os.environ,
            {jobs_codex.CODEX_BIN_ENV: self.fake_codex("codex-resume-done.jsonl")},
        ):
            code, out = _run_cli(
                "reply",
                thread_id,
                "--key",
                "turn2",
                "--model",
                MODEL,
                "--effort",
                EFFORT,
                "--json",
                "and again",
            )
        self.assertEqual(code, jobs_cli.EXIT_OK)
        payload = json.loads(out)
        self.assertEqual(payload["threadId"], thread_id)
        self.assertEqual(payload["parentJobId"], parent_id)
        record = self.wait_for_state(payload["jobId"], {STATE_DONE})
        self.assertEqual(record["parentJobId"], parent_id)
        self.assertEqual(record["threadId"], thread_id)
        self.assertEqual(record["codexRequest"]["mode"], "resume")
        # The turn runs in the thread's original cwd: `resume` rejects -C.
        self.assertEqual(record["cwd"], self.work)
        self.assertNotIn("-C", record["argv"])
        self.assertEqual(record["argv"][2], "resume")

    def test_reply_by_job_id_works_too(self) -> None:
        parent_id, thread_id = self._finished_thread()
        with mock.patch.dict(
            os.environ,
            {jobs_codex.CODEX_BIN_ENV: self.fake_codex("codex-resume-done.jsonl")},
        ):
            code, out = _run_cli(
                "reply",
                parent_id,
                "--key",
                "turn2",
                "--model",
                MODEL,
                "--effort",
                EFFORT,
                "--json",
                "and again",
            )
        self.assertEqual(code, jobs_cli.EXIT_OK)
        self.assertEqual(json.loads(out)["threadId"], thread_id)

    def test_reply_into_a_running_thread_is_thread_busy(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                jobs_codex.CODEX_BIN_ENV: self.fake_codex(
                    "codex-ok.jsonl", sleep_seconds=20
                )
            },
        ):
            job_id = self.start_codex("busy")["jobId"]
            thread_id = self.wait_for_thread_id(job_id)
            code, out = _run_cli(
                "reply",
                thread_id,
                "--key",
                "steer",
                "--model",
                MODEL,
                "--effort",
                EFFORT,
                "--json",
                "steering attempt",
            )
        self.assertEqual(code, jobs_cli.EXIT_THREAD_BUSY)
        payload = json.loads(out)
        self.assertEqual(payload["result"], "thread-busy")
        self.assertEqual(payload["threadId"], thread_id)
        self.assertEqual([item["jobId"] for item in payload["jobs"]], [job_id])
        self.assertIn("cancel", payload["hint"])
        # Refused means refused: no second Job, and the key stays free.
        self.assertIsNone(self.store.key_job_id("steer"))

    def test_thread_busy_is_decided_before_the_concurrency_ack(self) -> None:
        """The stronger refusal answers first: acking would not help here."""
        with mock.patch.dict(
            os.environ,
            {
                jobs_codex.CODEX_BIN_ENV: self.fake_codex(
                    "codex-ok.jsonl", sleep_seconds=20
                )
            },
        ):
            job_id = self.start_codex("busy2")["jobId"]
            thread_id = self.wait_for_thread_id(job_id)
            code, out = _run_cli(
                "reply",
                thread_id,
                "--key",
                "steer2",
                "--model",
                MODEL,
                "--effort",
                EFFORT,
                "--ack-concurrent",
                job_id,
                "--json",
                "steering attempt",
            )
        self.assertEqual(code, jobs_cli.EXIT_THREAD_BUSY)
        self.assertEqual(json.loads(out)["result"], "thread-busy")

    def test_reply_after_cancel_is_allowed_again(self) -> None:
        """Steering is `cancel` then `reply`, and that has to actually work."""
        with mock.patch.dict(
            os.environ,
            {
                jobs_codex.CODEX_BIN_ENV: self.fake_codex(
                    "codex-ok.jsonl", sleep_seconds=20
                )
            },
        ):
            job_id = self.start_codex("steerable")["jobId"]
            thread_id = self.wait_for_thread_id(job_id)
            cancel_code, _ = _run_cli("cancel", job_id, "--json")
        self.assertEqual(cancel_code, jobs_cli.EXIT_OK)
        self.assertEqual(self.store.load_record(job_id)["state"], STATE_CANCELLED)
        with mock.patch.dict(
            os.environ,
            {jobs_codex.CODEX_BIN_ENV: self.fake_codex("codex-resume-done.jsonl")},
        ):
            code, out = _run_cli(
                "reply",
                thread_id,
                "--key",
                "after-cancel",
                "--model",
                MODEL,
                "--effort",
                EFFORT,
                "--json",
                "carry on",
            )
        self.assertEqual(code, jobs_cli.EXIT_OK)
        self.assertEqual(json.loads(out)["threadId"], thread_id)

    def test_reply_to_a_plain_command_job_is_refused(self) -> None:
        code, out = _run_cli("start", "--key", "plain", "--json", "--", "true")
        self.assertEqual(code, jobs_cli.EXIT_OK)
        job_id = json.loads(out)["jobId"]
        self.wait_for_state(job_id, {STATE_DONE})
        code, _ = _run_cli(
            "reply",
            job_id,
            "--key",
            "nope",
            "--model",
            MODEL,
            "--effort",
            EFFORT,
            "hi",
        )
        self.assertEqual(code, jobs_cli.EXIT_USAGE)


class HelpContractTests(unittest.TestCase):
    """The skill-facing contract has to be IN --help, not only in the ADR."""

    def test_help_states_the_one_thread_one_job_rule_and_steering(self) -> None:
        text = jobs_cli.build_parser().format_help()
        self.assertIn("ONE subagent = ONE Codex thread = ONE running Job", text)
        self.assertIn("thread-busy", text)
        self.assertIn("cancel", text)
        self.assertIn("no-terminal-event", text)
        self.assertIn("--prompt-file", text)
        # `reply` is no longer a "not yet available" command.
        self.assertNotIn("reply", jobs_cli.PENDING_COMMANDS)


if __name__ == "__main__":
    unittest.main()
