"""The detached Job worker (ADR 0037 "Ownership by subreaper and marker").

Invoked as ``python3 -m jobs.worker [--watch] <project-key> <job-id> [root]``
by ``boxa-job start`` / ``boxa-job adopt``, already in its own session
(``setsid`` via ``start_new_session``), with stdio detached from the caller's
shell.

**Spawn mode** (``start``) does all of this:

1.  becomes a **child subreaper** (``PR_SET_CHILD_SUBREAPER``), so every
    descendant of the Job — including one that calls ``setsid`` and one that
    wipes its environment — reparents to it and stays walkable through
    ``/proc`` parent links while the worker lives;
2.  **reserves the Job key** by publishing its own full identity (worker pid,
    worker start time, Container run id) with :func:`os.link`;
3.  spawns the command with ``BOXA_JOB_ID`` in a fixed environment, stdout and
    stderr to files;
4.  keeps a **heartbeat** file fresh and a **tree snapshot** on the record
    while it waits, so a client can tell "still working" from "worker died"
    and a later ``cancel`` knows what existed;
5.  waits for the **whole tree**, not just the command: once the command has
    exited, tracked descendants that are still alive make the Job
    ``exited-with-survivors`` — the exit code is recorded, the Job is not
    finished, and only the survivors ending (or ``cancel``) moves it on;
6.  obeys the **cancel request file**: when it appears, the worker kills its
    tracked tree and finalizes the record as ``cancelled``, so a killed
    command is never recorded as a failure.

**Watch mode** (``adopt``) takes over a Job whose worker died. It cannot
reparent the surviving tree and it will never learn the command's exit code,
so it only watches the surviving processes (by marker, by descendant walk, by
remembered identity) and the output files. When nothing is left the Job is
``finished-unknown``: it ended, but nobody was watching when it did.
"""

from __future__ import annotations

import ctypes
import os
import signal
import subprocess
import sys
import threading
import time
from typing import Any, Optional

from . import procs
from .env import child_env
from .identity import container_run_id
from .recovery import live_job_pids, survivor_snapshot
from .store import (
    STATE_CANCELLED,
    STATE_DONE,
    STATE_FAILED,
    STATE_FINISHED_UNKNOWN,
    STATE_RESERVED,
    STATE_RUNNING,
    STATE_SURVIVORS,
    KeyReserved,
    ProjectStore,
)

# linux/prctl.h
PR_SET_CHILD_SUBREAPER = 36

HEARTBEAT_INTERVAL = 2.0

# How long the worker waits for survivors to end on their own once a cancel
# has been requested and its tree has been signalled.
CANCEL_SETTLE_SECONDS = 5.0

# Re-exported for compatibility with issue 01's callers/tests.
process_start_time = procs.process_start_time


def set_child_subreaper() -> bool:
    """Become a child subreaper; False when the kernel refuses (best effort)."""
    try:
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        return libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == 0
    except OSError:
        return False


def _now() -> float:
    return time.time()


class _Monitor(threading.Thread):
    """The worker's own eyes: heartbeat, tree snapshot, cancel enforcement.

    Runs for the whole life of the worker so the main thread can block in
    ``wait()``. It writes only the ``tree`` field of the record and only when
    the tracked pid set actually changed, so a long Job does not rewrite its
    record every two seconds.
    """

    def __init__(self, store: ProjectStore, job_id: str, worker_pid: int) -> None:
        super().__init__(daemon=True)
        self.store = store
        self.job_id = job_id
        self.worker_pid = worker_pid
        self.stop = threading.Event()
        self.cancel_seen = threading.Event()
        self._last_pids: set[int] = set()

    def tracked(self) -> dict[int, str]:
        return procs.tracked_pids(
            self.job_id,
            worker_pid=self.worker_pid,
            worker_start_time=procs.process_start_time(self.worker_pid),
        )

    def _record_tree(self, pids: set[int]) -> None:
        if pids == self._last_pids:
            return
        self._last_pids = set(pids)
        try:
            self.store.update_record(self.job_id, tree=procs.snapshot(pids))
        except Exception:  # noqa: BLE001 - bookkeeping must never kill the Job
            pass

    def kill_tracked(self) -> tuple[list[int], list[int]]:
        tracked = self.tracked()
        targets = {pid: procs.process_start_time(pid) for pid in tracked}
        return procs.terminate_tree(targets)

    def run(self) -> None:
        while not self.stop.is_set():
            try:
                self.store.touch_heartbeat(self.job_id)
            except OSError:
                pass
            try:
                self._record_tree(set(self.tracked()))
            except OSError:
                pass
            if not self.cancel_seen.is_set() and self.store.cancel_requested(
                self.job_id
            ):
                # The CLI asked for a cancel and already signalled what it
                # could see; as the subreaper the worker can see more.
                self.cancel_seen.set()
                self.kill_tracked()
            self.stop.wait(HEARTBEAT_INTERVAL)


def _wait_for_child(child: subprocess.Popen) -> Optional[int]:
    """Wait for the main command while reaping reparented descendants.

    As a subreaper the worker inherits every descendant whose own parent died,
    and an unreaped one stays in ``/proc`` as a zombie. Reaping happens in this
    thread only — a second thread calling ``waitpid(-1)`` could steal the main
    command's exit status, which is the one thing that makes a Job ``done``.
    """
    while True:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            # No children left at all: the main command was already reaped.
            return child.returncode
        if pid == 0:
            time.sleep(0.05)
            continue
        if pid == child.pid:
            child.returncode = os.waitstatus_to_exitcode(status)
            return child.returncode


def _final_state(store: ProjectStore, job_id: str, exit_code: Optional[int]) -> str:
    if store.cancel_requested(job_id):
        return STATE_CANCELLED
    if exit_code is None:
        return STATE_FINISHED_UNKNOWN
    return STATE_DONE if exit_code == 0 else STATE_FAILED


def _wait_for_tree(
    store: ProjectStore,
    job_id: str,
    monitor: _Monitor,
    record_survivors: bool,
    exit_code: Optional[int],
) -> list[dict[str, Any]]:
    """Wait until nothing of the Job is left; return the last survivor set.

    ``done`` requires this to come back empty. A cancel request cuts the wait
    short: the tree is signalled once, given a short settle, and whatever is
    still there is reported rather than waited out forever.
    """
    announced = False
    cancel_deadline: Optional[float] = None
    fallback = {
        "jobId": job_id,
        "worker": {
            "pid": monitor.worker_pid,
            "startTime": procs.process_start_time(monitor.worker_pid),
        },
    }
    while True:
        live = live_job_pids(store.load_record(job_id) or fallback)
        survivors = survivor_snapshot(live)
        if not survivors:
            return []
        if record_survivors and not announced:
            announced = True
            store.update_record(
                job_id,
                state=STATE_SURVIVORS,
                exitCode=exit_code,
                exitedAt=_now(),
                survivors=survivors,
            )
        if monitor.cancel_seen.is_set() or store.cancel_requested(job_id):
            if cancel_deadline is None:
                cancel_deadline = _now() + CANCEL_SETTLE_SECONDS
                monitor.kill_tracked()
            elif _now() >= cancel_deadline:
                return survivors
        time.sleep(0.2)


def run_spawn(project_key: str, job_id: str, root: Optional[str] = None) -> int:
    subreaper = set_child_subreaper()
    store = ProjectStore(project_key, root)
    spec = store.load_spec(job_id)
    key = spec["key"]
    argv = list(spec["argv"])
    cwd = spec["cwd"]
    env_names = list(spec.get("envNames", []))

    worker_pid = os.getpid()
    record = {
        "jobId": job_id,
        "key": key,
        "projectKey": project_key,
        "state": STATE_RESERVED,
        "argv": argv,
        "cwd": cwd,
        "envNames": env_names,
        "fingerprint": spec["fingerprint"],
        # The concurrency ack the caller gave at `start` (ADR 0037): the Jobs
        # it knowingly ran beside, kept so the decision stays traceable.
        "ackConcurrent": list(spec.get("ackConcurrent") or []),
        "worker": {
            "pid": worker_pid,
            "startTime": procs.process_start_time(worker_pid),
            "containerRunId": container_run_id(),
            "childSubreaper": subreaper,
        },
        "reservedAt": _now(),
        "startedAt": None,
        "finishedAt": None,
        "exitCode": None,
        "error": None,
        "tree": [],
        "survivors": [],
        "paths": {
            "record": store.record_path(job_id),
            "stdout": store.stdout_path(job_id),
            "stderr": store.stderr_path(job_id),
            "heartbeat": store.heartbeat_path(job_id),
            "workerStderr": store.worker_err_path(job_id),
        },
    }

    try:
        store.publish_reservation(key, record)
    except KeyReserved as exc:
        # Another worker owns this key.  Nothing of ours is published, so this
        # Job never existed; the parent reports the attach/conflict.
        print(f"key already reserved by job {exc.job_id}", file=sys.stderr)
        return 3

    store.touch_heartbeat(job_id)
    monitor = _Monitor(store, job_id, worker_pid)
    monitor.start()

    # The worker must not die with the terminal that started it.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)

    try:
        with open(store.stdout_path(job_id), "wb") as out, open(
            store.stderr_path(job_id), "wb"
        ) as err:
            try:
                child = subprocess.Popen(
                    argv,
                    cwd=cwd,
                    env=child_env(env_names, job_id),
                    stdin=subprocess.DEVNULL,
                    stdout=out,
                    stderr=err,
                    close_fds=True,
                )
            except OSError as exc:
                # Spawn failure is a failed Job, not a missing one.
                store.update_record(
                    job_id,
                    state=STATE_FAILED,
                    startedAt=_now(),
                    finishedAt=_now(),
                    error=f"spawn failed: {exc}",
                )
                return 1
            store.update_record(
                job_id,
                state=STATE_RUNNING,
                startedAt=_now(),
                command=procs.identity_of(child.pid),
            )
            exit_code = _wait_for_child(child)

        # `done` needs the whole tree gone, not just the command (ADR 0037).
        survivors = _wait_for_tree(
            store, job_id, monitor, record_survivors=True, exit_code=exit_code
        )
    finally:
        monitor.stop.set()
        monitor.join(timeout=HEARTBEAT_INTERVAL + 1.0)

    store.update_record(
        job_id,
        state=_final_state(store, job_id, exit_code),
        exitCode=exit_code,
        finishedAt=_now(),
        survivors=survivors,
    )
    store.touch_heartbeat(job_id)
    return 0


def run_watch(project_key: str, job_id: str, root: Optional[str] = None) -> int:
    """Adopt mode: watch a surviving tree whose original worker is gone.

    The exit code is unknowable here — nobody held the command's wait status —
    so the Job ends as ``finished-unknown`` unless it was already recorded
    (a Codex terminal event in issue 04 is evidence, not proof).
    """
    set_child_subreaper()
    store = ProjectStore(project_key, root)
    record = store.load_record(job_id)
    if record is None:
        print(f"no record to adopt for {job_id}", file=sys.stderr)
        return 4

    worker_pid = os.getpid()
    store.update_record(
        job_id,
        state=STATE_RUNNING,
        adopted=True,
        adoptedAt=_now(),
        worker={
            "pid": worker_pid,
            "startTime": procs.process_start_time(worker_pid),
            "containerRunId": container_run_id(),
            "childSubreaper": True,
            "watchOnly": True,
        },
    )
    store.touch_heartbeat(job_id)
    monitor = _Monitor(store, job_id, worker_pid)
    monitor.start()
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    exit_code = record.get("exitCode")
    try:
        survivors = _wait_for_tree(
            store, job_id, monitor, record_survivors=False, exit_code=exit_code
        )
    finally:
        monitor.stop.set()
        monitor.join(timeout=HEARTBEAT_INTERVAL + 1.0)
    store.update_record(
        job_id,
        state=_final_state(store, job_id, exit_code),
        finishedAt=_now(),
        survivors=survivors,
    )
    store.touch_heartbeat(job_id)
    return 0


def run(
    project_key: str,
    job_id: str,
    root: Optional[str] = None,
    watch: bool = False,
) -> int:
    if watch:
        return run_watch(project_key, job_id, root)
    return run_spawn(project_key, job_id, root)


def main(argv: Optional[list[str]] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    watch = False
    if args and args[0] == "--watch":
        watch = True
        args = args[1:]
    if len(args) < 2:
        print(
            "usage: python3 -m jobs.worker [--watch] <project-key> <job-id> [root]",
            file=sys.stderr,
        )
        return 2
    root = args[2] if len(args) > 2 else None
    return run(args[0], args[1], root, watch=watch)


if __name__ == "__main__":
    sys.exit(main())
