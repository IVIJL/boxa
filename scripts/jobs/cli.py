"""``boxa-job`` — the Container-owned Job CLI (ADR 0037).

Implemented here: ``start``, ``wait``, ``result``, ``list`` and ``log`` for a
plain command (issue 01), plus ``cancel``, ``adopt`` and the recovery states
(issue 02).  ``reply``, ``gc`` and ``runtime`` are documented in ``--help``
and refuse with a clear "not yet available" message, so the help stays the
complete command surface the ADR describes.

Every command starts by re-deriving the Project's non-terminal records from
evidence (:func:`jobs.recovery.refresh_states`): a Job from a foreign
Container run becomes ``interrupted``, a Job whose worker died while its tree
lives becomes ``orphaned``, and a Job whose worker and tree are both gone
without an exit code becomes ``finished-unknown``.  The caller therefore never
acts on a record that was only true a restart ago.

Output discipline (ADR 0037 "Frugal waiting"): every command prints at most a
handful of short lines, or one compact JSON object with ``--json``.  An
unchanged run yields only its state, its jobId and the heartbeat age — never
the request text, the argv, the cwd, or any log content.

Exit codes:

===  ============================================================
  0  success; for ``wait``/``result`` the Job reached a terminal state
  2  usage error
  3  the worker could not start or lost its reservation
  4  unknown Job, or an unclear record that needs ``cancel``/``adopt``
  5  refused (``--fresh`` while a Job under that key is not finished)
  6  conflict (same key, different request fingerprint)
  7  command not yet available in this slice
 10  ``wait`` expired while the Job is still running — call ``wait`` again
===  ============================================================
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from typing import Any, Optional

import jobs
from . import recovery
from .env import passthrough_values
from .identity import IdentityError, project_key
from .store import (
    CLEAN_TERMINAL_STATES,
    STATE_ORPHANED,
    STATE_RUNNING,
    TERMINAL_STATES,
    UNCLEAR_STATES,
    JobStoreError,
    ProjectStore,
    fingerprint,
    new_job_id,
)

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_WORKER = 3
EXIT_UNCLEAR = 4
EXIT_REFUSED = 5
EXIT_CONFLICT = 6
EXIT_NOT_YET = 7
EXIT_STILL_RUNNING = 10

# `wait` blocks in-process as long as the verified client limit allows minus a
# margin: the Bash tool call dies at 600 s, so nothing above this is useful.
WAIT_DEFAULT_SECONDS = 540
WAIT_MAX_SECONDS = 570
WAIT_POLL_SECONDS = 0.5
# How often a blocking `wait` re-derives the Project's records. A /proc scan
# per poll would be waste; a dead worker must still surface while waiting.
WAIT_REFRESH_SECONDS = 15.0

# How long `start` holds the registration lock waiting for the worker to
# publish its reservation.  Bounded: a worker that cannot publish in this time
# is a failure to report, not something to wait out.
RESERVATION_TIMEOUT = 20.0

# Commands from ADR 0037 that later slices add.  Listed in --help so the help
# is the whole surface, and refused with a pointer rather than a stack trace.
PENDING_COMMANDS = {
    "reply": "continue a Codex job's thread (Codex jobs only)",
    "gc": "clean up bulky logs and purge Job records",
    "runtime": "list or pin the verified Codex runtime version",
}


# --------------------------------------------------------------------- output


def _emit(json_mode: bool, payload: dict[str, Any], lines: list[str]) -> None:
    if json_mode:
        print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
    else:
        for line in lines:
            print(line)


def _age(seconds: Optional[float]) -> str:
    if seconds is None:
        return "unknown"
    return f"{int(seconds)}s"


def _store(refresh: bool = True) -> ProjectStore:
    """The Project's store, with its non-terminal records re-derived first.

    The refresh is the only sweeper there is: no daemon, no timer, the next
    caller pays for the truth (ADR 0037 "States and honesty").
    """
    store = ProjectStore(project_key())
    store.ensure()
    if refresh:
        recovery.refresh_states(store)
    return store


def _result_payload(store: ProjectStore, record: dict[str, Any]) -> dict[str, Any]:
    job_id = record["jobId"]
    started = record.get("startedAt")
    finished = record.get("finishedAt")
    return {
        "jobId": job_id,
        "key": record.get("key"),
        "state": record.get("state"),
        "exitCode": record.get("exitCode"),
        "error": record.get("error"),
        "reservedAt": record.get("reservedAt"),
        "startedAt": started,
        "finishedAt": finished,
        "durationSeconds": (
            round(finished - started, 3) if started and finished else None
        ),
        "heartbeatAgeSeconds": (
            None
            if record.get("state") in TERMINAL_STATES
            else _round(store.heartbeat_age(job_id))
        ),
        "survivors": [
            entry.get("pid") for entry in (record.get("survivors") or [])
        ],
        "interruptedReason": record.get("interruptedReason"),
        "cancel": record.get("cancel"),
        "adopted": bool(record.get("adopted")),
        "paths": record.get("paths", {}),
    }


def _round(value: Optional[float]) -> Optional[float]:
    return None if value is None else round(value, 1)


def _duration(payload: dict[str, Any]) -> str:
    value = payload.get("durationSeconds")
    return "unknown" if value is None else f"{value}s"


def _result_lines(payload: dict[str, Any]) -> list[str]:
    lines = [
        f"state: {payload['state']}",
        f"job: {payload['jobId']}  key: {payload['key']}",
        f"exit: {payload['exitCode']}  duration: {_duration(payload)}",
    ]
    paths = payload.get("paths", {})
    if paths:
        lines.append(f"stdout: {paths.get('stdout')}")
        lines.append(f"stderr: {paths.get('stderr')}")
    if payload.get("survivors"):
        pids = " ".join(str(pid) for pid in payload["survivors"])
        lines.append(f"survivors: {pids}")
    if payload.get("interruptedReason"):
        lines.append(f"reason: {payload['interruptedReason']}")
    if payload.get("error"):
        lines.append(f"error: {payload['error']}")
    return lines


# ---------------------------------------------------------------------- start


def _spawn_worker(
    store: ProjectStore,
    job_id: str,
    env_values: dict[str, str],
    watch: bool = False,
):
    """Launch the detached worker: own session, own stdio, no caller cwd."""
    package_parent = os.path.dirname(os.path.dirname(os.path.abspath(jobs.__file__)))
    env = dict(os.environ)
    existing = env.get("PYTHONPATH")
    env["PYTHONPATH"] = (
        f"{package_parent}:{existing}" if existing else package_parent
    )
    env.update(env_values)
    err = open(store.worker_err_path(job_id), "ab")
    try:
        return subprocess.Popen(
            [
                sys.executable,
                "-m",
                "jobs.worker",
                *(["--watch"] if watch else []),
                store.project_key,
                job_id,
                store.root,
            ],
            cwd="/",
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=err,
            start_new_session=True,
            close_fds=True,
        )
    finally:
        err.close()


def _detach(proc) -> None:
    """Release our handle on the intentionally detached worker.

    The worker must outlive this process, so it is never waited for. Marking
    the handle as released keeps Python from warning about an "abandoned"
    child; reaping is PID 1's job once this short-lived CLI call exits.
    """
    if proc.poll() is None:
        proc.returncode = 0


def _await_reservation(
    store: ProjectStore, job_id: str, proc
) -> Optional[dict[str, Any]]:
    deadline = time.time() + RESERVATION_TIMEOUT
    while time.time() < deadline:
        record = store.load_record(job_id)
        if record is not None:
            return record
        if proc.poll() is not None:
            return None
        time.sleep(0.02)
    return store.load_record(job_id)


def _worker_error(store: ProjectStore, job_id: str) -> str:
    try:
        with open(store.worker_err_path(job_id), "r", encoding="utf-8") as fh:
            text = fh.read().strip()
    except OSError:
        return ""
    return text.splitlines()[-1] if text else ""


def cmd_start(args: argparse.Namespace) -> int:
    argv = list(args.command)
    if not argv:
        print("boxa-job start: no command given (use -- <argv>)", file=sys.stderr)
        return EXIT_USAGE
    cwd = os.getcwd()
    env_names = sorted(set(args.env or []))
    request_fp = fingerprint(argv, cwd, env_names)
    store = _store()

    with store.lock():
        existing_id = store.key_job_id(args.key)
        if existing_id:
            try:
                existing = store.load_record(existing_id)
            except JobStoreError as exc:
                _emit(
                    args.json,
                    {
                        "result": "unclear",
                        "key": args.key,
                        "jobId": existing_id,
                        "reason": str(exc),
                    },
                    [
                        "result: unclear",
                        f"job: {existing_id}  key: {args.key}",
                        "this key needs `boxa-job cancel` or `adopt` first",
                    ],
                )
                return EXIT_UNCLEAR
            if existing is None:
                _emit(
                    args.json,
                    {
                        "result": "unclear",
                        "key": args.key,
                        "jobId": existing_id,
                        "reason": "reservation without a record",
                    },
                    [
                        "result: unclear",
                        f"job: {existing_id}  key: {args.key}",
                        "reservation has no record; needs `cancel` or `adopt`",
                    ],
                )
                return EXIT_UNCLEAR
            state = existing.get("state")
            terminal = state in TERMINAL_STATES
            if state in UNCLEAR_STATES:
                # Dead worker, foreign Container run, survivors left behind:
                # the Job's fate is not established, so this key does not get
                # a second run until `cancel` or `adopt` resolves it. Plain
                # `start` hands back the record it found (never a duplicate
                # run); `--fresh` is refused with the reason.
                payload = _result_payload(store, existing)
                if args.fresh:
                    payload["result"] = "refused"
                    payload["reason"] = "key-unclear"
                    verdict = "refused (--fresh needs a resolved key)"
                    code = EXIT_REFUSED
                else:
                    payload["result"] = "unclear"
                    payload["reason"] = f"key-{state}"
                    verdict = "unclear"
                    code = EXIT_UNCLEAR
                _emit(
                    args.json,
                    payload,
                    [
                        f"result: {verdict}  state: {state}",
                        f"job: {existing_id}  key: {args.key}",
                        "resolve it first: `boxa-job cancel` or `boxa-job adopt`",
                    ],
                )
                return code
            if args.fresh:
                if state not in CLEAN_TERMINAL_STATES:
                    _emit(
                        args.json,
                        {
                            "result": "refused",
                            "reason": "key-not-finished",
                            "key": args.key,
                            "jobId": existing_id,
                            "state": state,
                        },
                        [
                            "result: refused (--fresh needs the key finished)",
                            f"job: {existing_id}  key: {args.key}",
                            f"state: {state}",
                        ],
                    )
                    return EXIT_REFUSED
                # Finished Job under this key: the key is free to be re-run.
                store.release_key(args.key)
            elif existing.get("fingerprint") == request_fp:
                payload = _result_payload(store, existing)
                payload["result"] = "finished" if terminal else "attached"
                lines = (
                    _result_lines(payload)
                    if terminal
                    else [
                        f"result: attached  state: {state}",
                        f"job: {existing_id}  key: {args.key}",
                        f"heartbeat: {_age(store.heartbeat_age(existing_id))} ago",
                    ]
                )
                _emit(args.json, payload, lines)
                return EXIT_OK
            else:
                _emit(
                    args.json,
                    {
                        "result": "conflict",
                        "reason": "fingerprint-mismatch",
                        "key": args.key,
                        "jobId": existing_id,
                        "state": state,
                    },
                    [
                        "result: conflict (same key, different request)",
                        f"job: {existing_id}  key: {args.key}",
                        f"state: {state}",
                        "use a different key, or --fresh once it is finished",
                    ],
                )
                return EXIT_CONFLICT

        job_id = new_job_id()
        store.write_spec(
            job_id,
            {
                "jobId": job_id,
                "key": args.key,
                "argv": argv,
                "cwd": cwd,
                "envNames": env_names,
                "fingerprint": request_fp,
                "requestedAt": time.time(),
            },
        )
        proc = _spawn_worker(store, job_id, passthrough_values(env_names))
        record = _await_reservation(store, job_id, proc)
        _detach(proc)

    if record is None:
        detail = _worker_error(store, job_id) or "worker exited before reserving"
        _emit(
            args.json,
            {
                "result": "worker-failed",
                "key": args.key,
                "jobId": job_id,
                "reason": detail,
            },
            [
                "result: worker-failed",
                f"job: {job_id}  key: {args.key}",
                f"reason: {detail}",
                f"worker log: {store.worker_err_path(job_id)}",
            ],
        )
        return EXIT_WORKER

    _emit(
        args.json,
        {
            "result": "started",
            "jobId": job_id,
            "key": args.key,
            "state": record.get("state"),
            "fingerprint": request_fp,
        },
        [
            f"result: started  state: {record.get('state')}",
            f"job: {job_id}  key: {args.key}",
            f"wait: boxa-job wait {job_id}",
        ],
    )
    return EXIT_OK


# ----------------------------------------------------------------- wait/result


def _require_record(store: ProjectStore, job_id: str, json_mode: bool):
    try:
        record = store.load_record(job_id)
    except JobStoreError as exc:
        _emit(
            json_mode,
            {"result": "unclear", "jobId": job_id, "reason": str(exc)},
            ["result: unclear", f"job: {job_id}", f"reason: {exc}"],
        )
        return None
    if record is None:
        _emit(
            json_mode,
            {"result": "not-found", "jobId": job_id},
            ["result: not-found", f"job: {job_id}"],
        )
        return None
    return record


def effective_timeout(requested: float) -> float:
    """Clamp a requested wait to the verified client limit minus a margin.

    The agent's Bash tool call dies at 600 s, so a longer wait would lose the
    answer rather than get more of it.
    """
    return max(0.0, min(float(requested), WAIT_MAX_SECONDS))


def cmd_wait(args: argparse.Namespace) -> int:
    store = _store()
    record = _require_record(store, args.job_id, args.json)
    if record is None:
        return EXIT_UNCLEAR
    timeout = effective_timeout(args.timeout)
    deadline = time.time() + timeout
    next_refresh = time.time() + WAIT_REFRESH_SECONDS
    while True:
        if record.get("state") in TERMINAL_STATES:
            payload = _result_payload(store, record)
            payload["result"] = "finished"
            _emit(args.json, payload, _result_lines(payload))
            return EXIT_OK
        if record.get("state") == STATE_ORPHANED:
            # The worker is gone and nothing will change without a decision;
            # waiting on it would hide the problem (ADR 0037 frugality never
            # hides a problem).
            payload = _result_payload(store, record)
            payload["result"] = "unclear"
            _emit(
                args.json,
                payload,
                [
                    f"state: {STATE_ORPHANED}",
                    f"job: {args.job_id}",
                    "worker died, the tree is alive — `boxa-job adopt` or `cancel`",
                ],
            )
            return EXIT_UNCLEAR
        if time.time() >= deadline:
            break
        time.sleep(WAIT_POLL_SECONDS)
        if time.time() >= next_refresh:
            # Cheap enough at this cadence, and it is what turns a died-worker
            # Job into `orphaned` while someone is waiting for it.
            next_refresh = time.time() + WAIT_REFRESH_SECONDS
            recovery.refresh_states(store)
        try:
            refreshed = store.load_record(args.job_id)
        except JobStoreError:
            refreshed = None
        if refreshed is not None:
            record = refreshed
    # Expiry: state, jobId, heartbeat age. Nothing else — no request text, no
    # paths, no logs (ADR 0037 "Frugal waiting").
    payload = {
        "result": "running",
        "jobId": args.job_id,
        "state": record.get("state", STATE_RUNNING),
        "heartbeatAgeSeconds": _round(store.heartbeat_age(args.job_id)),
    }
    _emit(
        args.json,
        payload,
        [
            f"state: {payload['state']}",
            f"job: {payload['jobId']}",
            f"heartbeat: {_age(payload['heartbeatAgeSeconds'])} ago",
            "still running — call `boxa-job wait` again",
        ],
    )
    return EXIT_STILL_RUNNING


def cmd_result(args: argparse.Namespace) -> int:
    store = _store()
    record = _require_record(store, args.job_id, args.json)
    if record is None:
        return EXIT_UNCLEAR
    payload = _result_payload(store, record)
    payload["result"] = (
        "finished" if record.get("state") in TERMINAL_STATES else "running"
    )
    _emit(args.json, payload, _result_lines(payload))
    return EXIT_OK


def cmd_list(args: argparse.Namespace) -> int:
    store = _store()
    records = store.records()
    rows = [
        {
            "jobId": record.get("jobId"),
            "key": record.get("key"),
            "state": record.get("state"),
            "exitCode": record.get("exitCode"),
            "startedAt": record.get("startedAt"),
            "survivors": [
                entry.get("pid") for entry in (record.get("survivors") or [])
            ],
        }
        for record in records
    ]
    if args.json:
        print(
            json.dumps(
                {"jobs": rows, "count": len(rows)},
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return EXIT_OK
    if not rows:
        print("no jobs in this Project")
        return EXIT_OK
    for row in rows:
        # The state column fits the longest state name (`exited-with-survivors`)
        # so the distinct recovery states stay readable in a column.
        print(
            f"{row['jobId']}  {row['state']:<21}  key={row['key']}  "
            f"exit={row['exitCode']}{_list_extra(row)}"
        )
    return EXIT_OK


def cmd_log(args: argparse.Namespace) -> int:
    store = _store()
    record = _require_record(store, args.job_id, False)
    if record is None:
        return EXIT_UNCLEAR
    for stream, path in (
        ("stdout", store.stdout_path(args.job_id)),
        ("stderr", store.stderr_path(args.job_id)),
    ):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                tail = fh.read().splitlines()[-args.tail :]
        except OSError:
            continue
        if not tail:
            continue
        print(f"--- {stream} (last {len(tail)}) ---")
        for line in tail:
            print(line)
    return EXIT_OK


def _list_extra(row: dict[str, Any]) -> str:
    if not row.get("survivors"):
        return ""
    return "  survivors=" + ",".join(str(pid) for pid in row["survivors"])


# --------------------------------------------------------------- cancel/adopt


def cmd_cancel(args: argparse.Namespace) -> int:
    """Kill what Boxa can see of a Job and state what it could not track."""
    store = _store()
    record = _require_record(store, args.job_id, args.json)
    if record is None:
        return EXIT_UNCLEAR
    if record.get("state") in CLEAN_TERMINAL_STATES:
        payload = _result_payload(store, record)
        payload["result"] = "already-terminal"
        _emit(
            args.json,
            payload,
            [
                f"result: already-terminal  state: {record.get('state')}",
                f"job: {args.job_id}",
                "nothing to cancel",
            ],
        )
        return EXIT_OK
    final = recovery.cancel_job(store, record)
    summary = final.get("cancel") or {}
    killed = summary.get("killed", [])
    untrackable = [entry["pid"] for entry in summary.get("untrackable", [])]
    still = summary.get("stillAlive", [])
    payload = _result_payload(store, final)
    payload["result"] = "cancelled"
    payload["killed"] = killed
    payload["untrackable"] = untrackable
    payload["stillAlive"] = still
    payload["limits"] = list(recovery.CANCEL_LIMITS)
    lines = [
        f"state: {final.get('state')}",
        f"job: {args.job_id}",
        "killed: " + (" ".join(str(pid) for pid in killed) or "none"),
    ]
    if untrackable:
        lines.append(
            "untrackable (alive, not killed): "
            + " ".join(str(pid) for pid in untrackable)
        )
    if still:
        lines.append(
            "still alive after KILL: " + " ".join(str(pid) for pid in still)
        )
    for limit in recovery.CANCEL_LIMITS:
        lines.append(f"limit: {limit}")
    _emit(args.json, payload, lines)
    return EXIT_OK


def cmd_adopt(args: argparse.Namespace) -> int:
    """Attach a watching worker to a Job whose worker died.

    The new worker can only watch: the surviving tree does not reparent to it
    and the command's exit status died with the original worker, so the Job
    ends as `finished-unknown`.
    """
    store = _store()
    record = _require_record(store, args.job_id, args.json)
    if record is None:
        return EXIT_UNCLEAR
    if not recovery.adoptable(record):
        state = record.get("state")
        _emit(
            args.json,
            {
                "result": "refused",
                "reason": "nothing-alive" if state != STATE_RUNNING else "worker-alive",
                "jobId": args.job_id,
                "state": state,
            },
            [
                f"result: refused  state: {state}",
                f"job: {args.job_id}",
                "adopt needs an `orphaned` Job (dead worker, live tree)",
            ],
        )
        return EXIT_REFUSED
    proc = _spawn_worker(store, args.job_id, {}, watch=True)
    deadline = time.time() + RESERVATION_TIMEOUT
    adopted = record
    while time.time() < deadline:
        refreshed = store.load_record(args.job_id)
        if refreshed and refreshed.get("adopted"):
            adopted = refreshed
            break
        if proc.poll() is not None:
            break
        time.sleep(0.05)
    _detach(proc)
    if not adopted.get("adopted"):
        detail = _worker_error(store, args.job_id) or "watch worker did not attach"
        _emit(
            args.json,
            {"result": "worker-failed", "jobId": args.job_id, "reason": detail},
            ["result: worker-failed", f"job: {args.job_id}", f"reason: {detail}"],
        )
        return EXIT_WORKER
    payload = _result_payload(store, adopted)
    payload["result"] = "adopted"
    _emit(
        args.json,
        payload,
        [
            f"result: adopted  state: {adopted.get('state')}",
            f"job: {args.job_id}",
            "watching only — this Job ends as `finished-unknown` (no exit code)",
        ],
    )
    return EXIT_OK


def cmd_pending(args: argparse.Namespace) -> int:
    name = args.pending_command
    print(
        f"boxa-job {name}: not yet available — {PENDING_COMMANDS[name]} "
        "(lands in a later slice of ADR 0037).",
        file=sys.stderr,
    )
    return EXIT_NOT_YET


# ----------------------------------------------------------------------- main

_EPILOG = """\
available now:
  start    reserve a key, fork a Job worker, return the jobId at once
  wait     block in-process for a Job (default 540 s, max 570 s)
  result   state, exit code, output paths and timings of a Job
  cancel   kill a Job's tree and report what could not be tracked
  adopt    take over a Job whose worker died (watch only)
  list     the Jobs of this Project
  log      tail a Job's stdout/stderr on demand

not yet available (documented here, refused with exit 7):
  reply    continue a Codex job's thread (Codex jobs only)
  gc       clean up bulky logs and purge Job records
  runtime  list or pin the verified Codex runtime version

states:
  reserved               key taken, the command not spawned yet
  running                the command is running under a live worker
  done | failed          the command exited under a live worker AND nothing
                         of its tree was left alive
  exited-with-survivors  the command exited, tracked descendants are alive:
                         the exit code is recorded, the Job is NOT finished
  orphaned               the worker died, the tree is alive: `adopt` or `cancel`
  finished-unknown       it ended after its worker died; no exit code ever
  cancelled              stopped by `cancel`
  interrupted            a foreign Container run wrote it, or the worker died
                         before spawning: never resumed automatically

ownership and its limits: while the worker lives it is a child subreaper, so
the whole tree is walked through /proc parent links (a `setsid` escapee and a
child with a wiped environment included). Afterwards only the BOXA_JOB_ID
marker in /proc/*/environ is left. `cancel` therefore reports what it killed
AND what it could only remember: a process that cleared the marker after its
worker died, and anything started through the rootless Docker daemon, are
outside what Boxa can see.

exit codes: 0 finished/ok, 2 usage, 3 worker failed, 4 unknown or unclear Job,
5 refused, 6 key conflict, 7 not yet available, 10 wait expired while running.
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="boxa-job",
        description=(
            "Run long work as a Container-owned Job: its lifetime, state and "
            "result belong to the Container, not to the shell call, subagent "
            "or session that started it (ADR 0037)."
        ),
        epilog=_EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command_name")

    start = sub.add_parser(
        "start",
        help="reserve a key, fork a Job worker and return the jobId at once",
        description=(
            "Reserve the key and start the command as a Job. Same key and same "
            "request (argv + cwd + env names) attaches to the running Job or "
            "returns the finished result; same key with a different request is "
            "a conflict. --fresh starts a new run only when no Job under that "
            "key is unfinished."
        ),
    )
    start.add_argument("--key", required=True, help="Job key, scoped to the Project")
    start.add_argument(
        "--env",
        action="append",
        metavar="KEY",
        help="pass this variable through to the command (name recorded, value never)",
    )
    start.add_argument(
        "--fresh",
        action="store_true",
        help="start a new run under a key whose previous Job is finished",
    )
    start.add_argument("--json", action="store_true", help="one compact JSON object")
    start.add_argument(
        "command",
        nargs="*",
        metavar="-- argv",
        help="the command to run, after a literal --",
    )
    start.set_defaults(func=cmd_start)

    wait = sub.add_parser(
        "wait",
        help="block for a Job and print a short status on expiry",
        description=(
            "Block in-process until the Job finishes or the timeout expires. "
            "On expiry it prints only the state, the jobId and the heartbeat "
            "age, and exits 10: call wait again."
        ),
    )
    wait.add_argument("job_id")
    wait.add_argument(
        "--timeout",
        type=float,
        default=WAIT_DEFAULT_SECONDS,
        help=f"seconds to block (default {WAIT_DEFAULT_SECONDS}, max {WAIT_MAX_SECONDS})",
    )
    wait.add_argument("--json", action="store_true", help="one compact JSON object")
    wait.set_defaults(func=cmd_wait)

    result = sub.add_parser(
        "result", help="state, exit code, paths and timings of a Job"
    )
    result.add_argument("job_id")
    result.add_argument("--json", action="store_true", help="one compact JSON object")
    result.set_defaults(func=cmd_result)

    listing = sub.add_parser("list", help="the Jobs of this Project")
    listing.add_argument("--json", action="store_true", help="one compact JSON object")
    listing.set_defaults(func=cmd_list)

    cancel = sub.add_parser(
        "cancel",
        help="kill a Job's tree and report what could not be tracked",
        description=(
            "Write the cancel request, then TERM and KILL everything Boxa can "
            "see of the Job (the tree under a live worker, otherwise the "
            "BOXA_JOB_ID marker matches and their descendants), verified by "
            "pid + start time. Reports what it killed, what it could only "
            "remember from the record, and the two stated limits. Also the way "
            "to resolve an unclear key."
        ),
    )
    cancel.add_argument("job_id")
    cancel.add_argument("--json", action="store_true", help="one compact JSON object")
    cancel.set_defaults(func=cmd_cancel)

    adopt = sub.add_parser(
        "adopt",
        help="take over a Job whose worker died (watch only)",
        description=(
            "Attach a new worker to an `orphaned` Job. It only watches the "
            "surviving tree and the output files: the command's exit status "
            "died with the original worker, so the Job ends as "
            "`finished-unknown`. Refused when nothing of the Job is alive."
        ),
    )
    adopt.add_argument("job_id")
    adopt.add_argument("--json", action="store_true", help="one compact JSON object")
    adopt.set_defaults(func=cmd_adopt)

    log = sub.add_parser("log", help="tail a Job's stdout/stderr on demand")
    log.add_argument("job_id")
    log.add_argument(
        "--tail", type=int, default=20, help="lines per stream (default 20)"
    )
    log.set_defaults(func=cmd_log)

    for name, summary in PENDING_COMMANDS.items():
        pending = sub.add_parser(
            name, help=f"(not yet available) {summary}", description=summary
        )
        pending.add_argument(
            "rest", nargs="*", help=argparse.SUPPRESS
        )
        pending.set_defaults(func=cmd_pending, pending_command=name)

    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return EXIT_USAGE
    try:
        return args.func(args)
    except IdentityError as exc:
        print(f"boxa-job: {exc}", file=sys.stderr)
        return EXIT_USAGE
    except JobStoreError as exc:
        print(f"boxa-job: {exc}", file=sys.stderr)
        return EXIT_UNCLEAR
    except BrokenPipeError:
        return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
