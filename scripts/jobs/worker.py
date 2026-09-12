"""The detached Job worker (ADR 0037 "Ownership by subreaper and marker").

Invoked as ``python3 -m jobs.worker <project-key> <job-id> <state-root>`` by
``boxa-job start``, already in its own session (``setsid`` via
``start_new_session``), with stdio detached from the caller's shell.  It then:

1.  becomes a **child subreaper** (``PR_SET_CHILD_SUBREAPER``), so every
    descendant of the Job — including one that calls ``setsid`` itself —
    reparents to it and stays walkable through ``/proc`` parent links while
    the worker lives (the tree walk itself lands in issue 02);
2.  **reserves the Job key** by publishing its own full identity (worker pid,
    worker start time, Container run id) with :func:`os.link`;
3.  spawns the command with ``BOXA_JOB_ID`` in a fixed environment, stdout and
    stderr to files;
4.  keeps a **heartbeat** file fresh while it waits, so a waiting client can
    tell "still working" from "worker died";
5.  records the exit **atomically**, which is the only thing that makes a Job
    ``done`` or ``failed``.

The worker inherits the caller's environment for its own bookkeeping (it must
see ``XDG_STATE_HOME`` and the passthrough values) but the *command* gets only
:func:`jobs.env.child_env`.

Scope of this slice: the worker waits for the direct child.  Waiting for the
whole tree — and therefore the ``exited-with-survivors`` state — is issue 02.
"""

from __future__ import annotations

import ctypes
import os
import signal
import subprocess
import sys
import threading
import time
from typing import Optional

from .env import child_env
from .identity import container_run_id
from .store import (
    STATE_DONE,
    STATE_FAILED,
    STATE_RESERVED,
    STATE_RUNNING,
    KeyReserved,
    ProjectStore,
)

# linux/prctl.h
PR_SET_CHILD_SUBREAPER = 36

HEARTBEAT_INTERVAL = 2.0


def set_child_subreaper() -> bool:
    """Become a child subreaper; False when the kernel refuses (best effort)."""
    try:
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        return libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == 0
    except OSError:
        return False


def process_start_time(pid: int) -> Optional[int]:
    """Field 22 of ``/proc/<pid>/stat`` — the clock ticks since boot.

    pid alone is not an identity (pids are reused); pid + start time + the
    Container run id is, which is what the reservation records.
    """
    try:
        with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return None
    # comm can contain spaces and parentheses: everything up to the LAST ')'
    # belongs to fields 1-2.
    tail = raw[raw.rfind(")") + 1 :].split()
    if len(tail) < 20:
        return None
    try:
        return int(tail[19])
    except ValueError:
        return None


def _now() -> float:
    return time.time()


def _heartbeat_loop(store: ProjectStore, job_id: str, stop: threading.Event) -> None:
    while not stop.is_set():
        try:
            store.touch_heartbeat(job_id)
        except OSError:
            pass
        stop.wait(HEARTBEAT_INTERVAL)


def run(project_key: str, job_id: str, root: Optional[str] = None) -> int:
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
        "worker": {
            "pid": worker_pid,
            "startTime": process_start_time(worker_pid),
            "containerRunId": container_run_id(),
            "childSubreaper": subreaper,
        },
        "reservedAt": _now(),
        "startedAt": None,
        "finishedAt": None,
        "exitCode": None,
        "error": None,
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
    stop = threading.Event()
    beat = threading.Thread(
        target=_heartbeat_loop, args=(store, job_id, stop), daemon=True
    )
    beat.start()

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
                command={"pid": child.pid, "startTime": process_start_time(child.pid)},
            )
            exit_code = child.wait()
    finally:
        stop.set()

    store.update_record(
        job_id,
        state=STATE_DONE if exit_code == 0 else STATE_FAILED,
        exitCode=exit_code,
        finishedAt=_now(),
    )
    store.touch_heartbeat(job_id)
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) < 2:
        print("usage: python3 -m jobs.worker <project-key> <job-id> [root]",
              file=sys.stderr)
        return 2
    root = args[2] if len(args) > 2 else None
    return run(args[0], args[1], root)


if __name__ == "__main__":
    sys.exit(main())
