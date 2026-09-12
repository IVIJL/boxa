"""Codex jobs: the command line, the event stream and the derived outcome.

A **Codex job** (ADR 0037 § "Codex job contract") is a Job whose command is a
non-interactive ``codex exec`` run.  Three things make it different from a
plain command Job, and all three live here:

*   **The command line is fixed.**  Model and effort are required and always
    passed explicitly (nothing is inherited from ``~/.codex/config.toml``), the
    run is unconditionally ``--dangerously-bypass-approvals-and-sandbox``
    (the Container is the boundary), and the final message is captured with
    ``-o <job>/last.md``.  ``codex exec resume`` accepts a *smaller* flag set
    than ``codex exec`` — verified against codex-cli 0.149.1, it rejects
    ``-C``/``--cd`` and ``-s`` — so the resume argv omits ``-C`` and the
    worker supplies the original Job's cwd by spawning the child in it.
*   **The outcome comes from the event stream, not from the exit code alone.**
    ``codex exec --json`` writes JSONL events to stdout (``events.jsonl`` in
    the job dir): ``thread.started`` carries the thread id, ``item.*`` the
    work, and the turn ends with ``turn.completed`` or ``turn.failed``.  A
    SIGTERM'ed Codex exits 0 *without* a terminal event, so "exit 0" alone
    would report a killed run as a success — hence
    :func:`derive_outcome`.
*   **The result is an extract, never the log.**  :func:`result_extract`
    builds the compact ``codex`` object ``boxa-job result`` prints: thread id,
    final message, usage, requested vs. actually used model/effort, the Codex
    version captured at start, and per-item-type counts.  The raw events stay
    on disk for ``boxa-job log``.

Binary resolution is deliberately one function, :func:`resolve_binary`: issue
05 replaces it with the verified runtime copy under the
``boxa-codex-versions`` volume and nothing else has to change.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from typing import Any, Iterable, NamedTuple, Optional

from .store import (
    STATE_CANCELLED,
    STATE_DONE,
    STATE_FAILED,
    STATE_FINISHED_UNKNOWN,
)

__all__ = [
    "CODEX_BIN_ENV",
    "CodexNotFound",
    "StreamSummary",
    "binary_version",
    "derive_outcome",
    "Finish",
    "final_message",
    "finish",
    "fingerprint_argv",
    "resolve_binary",
    "result_extract",
    "resume_argv",
    "start_argv",
    "summarize_stream",
    "thread_id_of",
]

# Test/override seam for the Codex binary.  Production resolution is PATH (the
# Container's interactive Codex) until issue 05 pins the verified runtime copy.
CODEX_BIN_ENV = "BOXA_JOB_CODEX_BIN"

# `-o` is the only part of the Codex argv that depends on the job dir, and the
# binary path changes the day issue 05 lands; neither makes a *different
# request*, so both stay out of the fingerprint (see `fingerprint_argv`).
_FINGERPRINT_BINARY = "codex"

# Reasons recorded on a failed Codex job, echoed in `--json` so a skill can
# branch on them.
REASON_NO_TERMINAL_EVENT = "no-terminal-event"
REASON_TURN_FAILED = "turn-failed"
REASON_STREAM_ERROR = "stream-error"
REASON_NONZERO_EXIT = "nonzero-exit"

# How much of the final message the human output prints; `--json` carries it
# whole (it is the answer, unlike the event log).
FINAL_MESSAGE_PREVIEW_CHARS = 300


class CodexNotFound(RuntimeError):
    """No Codex binary to run a Codex job with."""


def resolve_binary(explicit: Optional[str] = None) -> str:
    """Absolute path of the Codex binary a Codex job runs.

    One function on purpose: issue 05 swaps PATH resolution for the verified
    runtime copy here and the CLI, the worker and the tests follow.
    """
    candidate = explicit or os.environ.get(CODEX_BIN_ENV) or shutil.which("codex")
    if not candidate:
        raise CodexNotFound(
            "no `codex` binary on PATH: a Codex job needs Codex in the Container"
        )
    return os.path.abspath(candidate)


def binary_version(binary: str) -> Optional[str]:
    """``codex --version`` captured at start, or None when it cannot be read.

    Recorded rather than re-derived later: the runtime under a Job must stay
    the one the Job actually ran, even after an ``npm install -g``.
    """
    try:
        proc = subprocess.run(
            [binary, "--version"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    out = (proc.stdout or proc.stderr or "").strip().splitlines()
    return out[0] if out else None


# ------------------------------------------------------------------- argv


def _effort_override(effort: str) -> list[str]:
    return ["-c", f"model_reasoning_effort={effort}"]


def start_argv(
    binary: str,
    *,
    model: str,
    effort: str,
    cwd: str,
    last_message: str,
    prompt: str,
) -> list[str]:
    """``codex exec`` argv for a fresh thread (stdin is ``/dev/null``)."""
    return [
        binary,
        "exec",
        "--json",
        "--dangerously-bypass-approvals-and-sandbox",
        "--skip-git-repo-check",
        "-m",
        model,
        *_effort_override(effort),
        "-C",
        cwd,
        "-o",
        last_message,
        prompt,
    ]


def resume_argv(
    binary: str,
    *,
    thread_id: str,
    model: str,
    effort: str,
    last_message: str,
    prompt: str,
) -> list[str]:
    """``codex exec resume`` argv for an existing thread.

    No ``-C``: ``codex exec resume`` rejects it (measured on codex-cli
    0.149.1), so the worker spawns this in the original Job's cwd instead.
    """
    return [
        binary,
        "exec",
        "resume",
        thread_id,
        "--json",
        "--dangerously-bypass-approvals-and-sandbox",
        "--skip-git-repo-check",
        "-m",
        model,
        *_effort_override(effort),
        "-o",
        last_message,
        prompt,
    ]


def fingerprint_argv(
    *,
    model: str,
    effort: str,
    cwd: str,
    prompt: str,
    thread_id: Optional[str] = None,
) -> list[str]:
    """The argv a Codex request is fingerprinted by: the request, nothing else.

    The prompt text is in here, so two starts under one key are "the same
    request" only when the prompt matches; the job-dir ``-o`` path and the
    binary location are excluded because neither changes what was asked.
    """
    return [
        _FINGERPRINT_BINARY,
        "exec",
        *(["resume", thread_id] if thread_id else []),
        "-m",
        model,
        *_effort_override(effort),
        "-C",
        cwd,
        prompt,
    ]


# ----------------------------------------------------------- event stream


class StreamSummary(NamedTuple):
    """Everything a Codex job's outcome and result need from its events."""

    thread_id: Optional[str]
    terminal: Optional[str]
    usage: Optional[dict[str, Any]]
    item_counts: dict[str, int]
    error: Optional[str]
    used_model: Optional[str]
    used_effort: Optional[str]
    malformed_lines: int


def _iter_events(lines: Iterable[str]) -> Iterable[tuple[dict[str, Any], bool]]:
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            yield {}, False
            continue
        if isinstance(event, dict):
            yield event, True
        else:
            yield {}, False


def _error_message(event: dict[str, Any]) -> Optional[str]:
    error = event.get("error")
    if isinstance(error, dict):
        message = error.get("message")
        if message:
            return str(message)
    if isinstance(error, str) and error:
        return error
    message = event.get("message")
    return str(message) if message else None


def _probe_used(event: dict[str, Any], summary: dict[str, Any]) -> None:
    """Pick up the model/effort Codex says it used, when the stream says it.

    codex-cli 0.149.1 does not report either, so these stay ``None`` and the
    result shows only what was requested — honest beats invented.
    """
    for key in ("model", "model_slug"):
        value = event.get(key)
        if isinstance(value, str) and value:
            summary["used_model"] = value
            break
    for key in ("reasoning_effort", "model_reasoning_effort", "effort"):
        value = event.get(key)
        if isinstance(value, str) and value:
            summary["used_effort"] = value
            break


def summarize_stream(path: str) -> StreamSummary:
    """Read ``events.jsonl`` once and reduce it to the facts that matter.

    Items are counted by identity (``item.started`` and ``item.completed``
    describe the same item), so ``itemCounts`` is a count of work done and not
    a count of events seen.  Only a *top-level* ``error`` event is an error:
    an ``item.completed`` carrying an ``error`` item is a warning Codex keeps
    running through, and treating it as a failure would misreport a good run.
    """
    state: dict[str, Any] = {
        "thread_id": None,
        "terminal": None,
        "usage": None,
        "error": None,
        "used_model": None,
        "used_effort": None,
    }
    item_types: dict[str, str] = {}
    anonymous: dict[str, int] = {}
    malformed = 0
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for event, ok in _iter_events(fh):
                if not ok:
                    malformed += 1
                    continue
                kind = str(event.get("type") or "")
                if kind == "thread.started":
                    state["thread_id"] = event.get("thread_id") or state["thread_id"]
                    _probe_used(event, state)
                elif kind == "turn.started":
                    _probe_used(event, state)
                elif kind == "turn.completed":
                    state["terminal"] = kind
                    usage = event.get("usage")
                    state["usage"] = usage if isinstance(usage, dict) else None
                    _probe_used(event, state)
                elif kind == "turn.failed":
                    state["terminal"] = kind
                    state["error"] = _error_message(event) or state["error"]
                elif kind == "error":
                    # Terminal only if nothing better follows; `turn.failed`
                    # usually does and overwrites it.
                    state["error"] = _error_message(event) or state["error"]
                    if state["terminal"] is None:
                        state["terminal"] = kind
                elif kind.startswith("item."):
                    item = event.get("item")
                    if not isinstance(item, dict):
                        continue
                    item_type = str(item.get("type") or "unknown")
                    item_id = item.get("id")
                    if item_id:
                        item_types[str(item_id)] = item_type
                    else:
                        anonymous[item_type] = anonymous.get(item_type, 0) + 1
    except FileNotFoundError:
        pass
    except OSError:
        pass
    counts = dict(anonymous)
    for item_type in item_types.values():
        counts[item_type] = counts.get(item_type, 0) + 1
    return StreamSummary(
        thread_id=state["thread_id"],
        terminal=state["terminal"],
        usage=state["usage"],
        item_counts=dict(sorted(counts.items())),
        error=state["error"],
        used_model=state["used_model"],
        used_effort=state["used_effort"],
        malformed_lines=malformed,
    )


def thread_id_of(path: str) -> Optional[str]:
    """The thread id alone, for the worker's mid-run record update.

    Stops at the first ``thread.started``: this runs on the worker's
    heartbeat tick until it succeeds, and the answer is on line one.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for event, ok in _iter_events(fh):
                if ok and event.get("type") == "thread.started":
                    value = event.get("thread_id")
                    return str(value) if value else None
    except OSError:
        return None
    return None


def final_message(path: str) -> Optional[str]:
    """Codex's final message, as written by ``-o``."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read().strip()
    except OSError:
        return None
    return text or None


# ---------------------------------------------------------------- outcome


class Outcome(NamedTuple):
    state: str
    reason: Optional[str]
    error: Optional[str]


def derive_outcome(
    summary: StreamSummary,
    exit_code: Optional[int],
    *,
    cancel_requested: bool = False,
) -> Outcome:
    """The Codex job's terminal state, derived from the stream AND the exit.

    Order is the contract (ADR 0037 § "States and honesty"):

    1.  a cancel was requested → ``cancelled``: a killed run is never a
        failure, and its missing terminal event proves nothing;
    2.  no exit code (the worker died) → ``finished-unknown``: a
        ``turn.completed`` in the stream is *evidence* that Codex finished its
        turn, not proof that the process exited cleanly;
    3.  ``turn.failed`` / a top-level ``error`` event → ``failed`` with the
        message Codex gave;
    4.  a non-zero exit → ``failed``;
    5.  exit 0 with ``turn.completed`` → ``done``;
    6.  exit 0 without any terminal event → ``failed``
        (``no-terminal-event``): this is what a SIGTERM'ed Codex looks like,
        and calling it ``done`` would be the one lie this design must not
        tell.
    """
    if cancel_requested:
        return Outcome(STATE_CANCELLED, None, None)
    if exit_code is None:
        return Outcome(STATE_FINISHED_UNKNOWN, None, summary.error)
    if summary.terminal == "turn.failed":
        return Outcome(STATE_FAILED, REASON_TURN_FAILED, summary.error)
    if summary.terminal == "error":
        return Outcome(STATE_FAILED, REASON_STREAM_ERROR, summary.error)
    if exit_code != 0:
        return Outcome(STATE_FAILED, REASON_NONZERO_EXIT, summary.error)
    if summary.terminal == "turn.completed":
        return Outcome(STATE_DONE, None, None)
    return Outcome(
        STATE_FAILED,
        REASON_NO_TERMINAL_EVENT,
        summary.error or "codex exited 0 without a terminal event",
    )


# ----------------------------------------------------------------- result


def stream_extract(
    events_path: str,
    last_message_path: str,
    spec: dict[str, Any],
    summary: Optional[StreamSummary] = None,
) -> dict[str, Any]:
    """The ``codex`` object written onto the record when a Codex job ends."""
    if summary is None:
        summary = summarize_stream(events_path)
    return {
        "threadId": summary.thread_id,
        "terminalEvent": summary.terminal,
        "usage": summary.usage,
        "itemCounts": summary.item_counts,
        "usedModel": summary.used_model,
        "usedEffort": summary.used_effort,
        "requestedModel": spec.get("model"),
        "requestedEffort": spec.get("effort"),
        "codexVersion": spec.get("version"),
        "codexBinary": spec.get("binary"),
        "parentJobId": spec.get("parentJobId"),
        "mode": spec.get("mode", "start"),
        "finalMessage": final_message(last_message_path),
        "malformedEventLines": summary.malformed_lines,
    }


class Finish(NamedTuple):
    """What the worker writes when a Codex job ends: a state and an extract."""

    state: str
    reason: Optional[str]
    error: Optional[str]
    extract: dict[str, Any]


def finish(
    events_path: str,
    last_message_path: str,
    spec: dict[str, Any],
    exit_code: Optional[int],
    *,
    cancel_requested: bool = False,
) -> Finish:
    """Read the stream once; derive the state and the result extract from it.

    One read: the outcome and the result answer the same question about the
    same file, so they must never disagree about what it said.
    """
    summary = summarize_stream(events_path)
    outcome = derive_outcome(
        summary, exit_code, cancel_requested=cancel_requested
    )
    extract = stream_extract(events_path, last_message_path, spec, summary)
    extract["outcomeReason"] = outcome.reason
    return Finish(outcome.state, outcome.reason, outcome.error, extract)


def result_extract(record: dict[str, Any], paths: dict[str, str]) -> dict[str, Any]:
    """The ``codex`` block of ``boxa-job result`` — an extract, never the log.

    Recomputed from the files when the record has no finished extract yet, so
    ``result`` on a *running* Codex job already shows its thread id and what
    the stream has produced so far.
    """
    stored = record.get("codex")
    if isinstance(stored, dict) and stored.get("terminalEvent") is not None:
        return dict(stored)
    spec = record.get("codexRequest") or {}
    live = stream_extract(
        paths.get("events", ""), paths.get("lastMessage", ""), spec
    )
    if isinstance(stored, dict):
        # Keep whatever the worker already recorded (the mid-run thread id)
        # when the files cannot say it.
        for key, value in stored.items():
            if live.get(key) in (None, {}, []) and value not in (None, {}, []):
                live[key] = value
    live["threadId"] = live.get("threadId") or record.get("threadId")
    return live


def result_lines(extract: dict[str, Any]) -> list[str]:
    """Short human form: identity, cost, work done, the answer's first lines."""
    usage = extract.get("usage") or {}
    items = extract.get("itemCounts") or {}
    lines = [
        "codex: thread={} model={}/{} version={}".format(
            extract.get("threadId") or "unknown",
            extract.get("requestedModel") or "?",
            extract.get("requestedEffort") or "?",
            extract.get("codexVersion") or "unknown",
        )
    ]
    if usage:
        lines.append(
            "usage: in={} out={} cached={}".format(
                usage.get("input_tokens"),
                usage.get("output_tokens"),
                usage.get("cached_input_tokens"),
            )
        )
    if items:
        lines.append(
            "items: " + " ".join(f"{name}={count}" for name, count in items.items())
        )
    message = extract.get("finalMessage")
    if message:
        flat = " ".join(str(message).split())
        if len(flat) > FINAL_MESSAGE_PREVIEW_CHARS:
            flat = flat[: FINAL_MESSAGE_PREVIEW_CHARS - 1] + "…"
        lines.append(f"final: {flat}")
    return lines
