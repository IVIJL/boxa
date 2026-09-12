"""Process ownership primitives (ADR 0037 "Ownership by subreaper and marker").

Everything Boxa knows about a Job's processes comes from two sources of
evidence, in this order:

1.  **The tree under a live worker.** The worker is a child subreaper, so every
    descendant of the Job reparents to it — including one that called
    ``setsid``, and including one that wiped its environment. Walking
    ``/proc/*/stat`` parent links downwards from the worker's pid therefore
    enumerates the whole tree while the worker lives.
2.  **The ``BOXA_JOB_ID`` marker.** Every Job command gets ``BOXA_JOB_ID`` in
    its environment, so ``/proc/*/environ`` finds its descendants even after
    the worker died and the tree reparented to PID 1. Descendants of a marker
    match are found by walking downwards from it, which catches children that
    cleared their own environment while their marked parent is still alive.

Neither source is complete, and the CLI says so: a process that cleared the
marker *after* its worker died has no live ancestor Boxa can anchor on and no
marker to find, and anything started through the rootless Docker daemon is not
a descendant at all. "No owned process found" means "nothing Boxa can see".

Process identity is **pid plus start time** (field 22 of ``/proc/<pid>/stat``,
the clock ticks since boot) plus the Container run id recorded on the Job.
A pid alone is not an identity: pids are reused, and a stale record pointing at
a recycled pid must never make Boxa kill an innocent process.
"""

from __future__ import annotations

import errno
import os
import signal
import time
from typing import Any, Iterable, Optional

__all__ = [
    "JOB_ID_MARKER",
    "is_alive",
    "is_running",
    "is_zombie",
    "identity_of",
    "marker_pids",
    "parent_map",
    "process_ppid",
    "process_start_time",
    "signal_pids",
    "snapshot",
    "tracked_pids",
    "wait_until_gone",
]

PROC_ROOT = "/proc"

# The marker ADR 0037 relies on. Set by jobs.env.child_env on every Job
# command, and the only evidence left once the worker is gone.
JOB_ID_MARKER = "BOXA_JOB_ID"

# pids that are never a Job's process, whatever a record claims.
_NEVER = (0, 1)


def _stat_tail(pid: int) -> Optional[list[str]]:
    """Fields 3.. of ``/proc/<pid>/stat`` (comm may contain spaces and ')')."""
    try:
        with open(f"{PROC_ROOT}/{pid}/stat", "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return None
    tail = raw[raw.rfind(")") + 1 :].split()
    return tail if len(tail) >= 20 else None


def process_start_time(pid: int) -> Optional[int]:
    """Field 22 of ``/proc/<pid>/stat``: the half of a process identity."""
    tail = _stat_tail(pid)
    if tail is None:
        return None
    try:
        return int(tail[19])
    except ValueError:
        return None


def process_ppid(pid: int) -> Optional[int]:
    """Field 4 of ``/proc/<pid>/stat``: the parent link the tree walk follows."""
    tail = _stat_tail(pid)
    if tail is None:
        return None
    try:
        return int(tail[1])
    except ValueError:
        return None


def is_zombie(pid: int) -> bool:
    """A reaped-but-unwaited descendant is NOT a survivor.

    A descendant whose own parent died reparents to the worker (the subreaper)
    and sits in state ``Z`` until someone waits for it. It holds no resources
    and cannot be signalled, so counting it as alive would keep a finished Job
    out of ``done`` forever.
    """
    tail = _stat_tail(pid)
    return bool(tail) and tail[0] == "Z"


def process_comm(pid: int) -> str:
    """Short command name, for reports a human has to act on. Never parsed."""
    try:
        with open(f"{PROC_ROOT}/{pid}/comm", "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def is_running(pid: Optional[int]) -> bool:
    """The weaker check: this pid exists and is not a zombie.

    Deliberately NOT an identity: it says only that *something* is running
    under this pid.  Valid for a pid observed a moment ago by a ``/proc`` scan
    (which is where its own start time comes from anyway), never for a pid
    remembered on a record.
    """
    if not pid or int(pid) in _NEVER:
        return False
    return process_start_time(int(pid)) is not None and not is_zombie(int(pid))


def is_alive(pid: Optional[int], start_time: Optional[int] = None) -> bool:
    """Identity check: this pid exists *and* is still the same process.

    A pid alone is never an identity (ADR 0037 "Ownership by subreaper and
    marker"), so **without a recorded start time the answer is False**: the
    process is not verifiably alive, and an unverifiable claim must never make
    Boxa kill a recycled pid, or attribute one and its descendants to a Job.
    Existence alone is :func:`is_running`, which says so in its name.
    """
    if start_time is None:
        return False
    if not pid or int(pid) in _NEVER:
        return False
    current = process_start_time(int(pid))
    if current is None or is_zombie(int(pid)):
        return False
    try:
        return current == int(start_time)
    except (TypeError, ValueError):
        return False


def identity_of(pid: int) -> dict[str, Any]:
    """A process' identity as it is recorded on a Job."""
    return {
        "pid": int(pid),
        "startTime": process_start_time(int(pid)),
        "comm": process_comm(int(pid)),
    }


def snapshot(pids: Iterable[int]) -> list[dict[str, Any]]:
    """Identities of the given pids, skipping the ones that just exited."""
    out = []
    for pid in sorted({int(p) for p in pids}):
        entry = identity_of(pid)
        if entry["startTime"] is not None:
            out.append(entry)
    return out


def _pids() -> list[int]:
    out = []
    try:
        names = os.listdir(PROC_ROOT)
    except OSError:
        return out
    for name in names:
        if name.isdigit():
            out.append(int(name))
    return out


def parent_map() -> dict[int, int]:
    """pid → ppid for every process this Container can see."""
    links = {}
    for pid in _pids():
        ppid = process_ppid(pid)
        if ppid is not None:
            links[pid] = ppid
    return links


def descendants(root_pid: int, links: Optional[dict[int, int]] = None) -> set[int]:
    """Every process whose parent chain reaches ``root_pid`` (root excluded)."""
    links = parent_map() if links is None else links
    children: dict[int, list[int]] = {}
    for pid, ppid in links.items():
        children.setdefault(ppid, []).append(pid)
    found: set[int] = set()
    queue = list(children.get(int(root_pid), []))
    while queue:
        pid = queue.pop()
        if pid in found or pid in _NEVER:
            continue
        found.add(pid)
        queue.extend(children.get(pid, []))
    return found


def marker_pids(job_id: str) -> set[int]:
    """Processes carrying ``BOXA_JOB_ID=<job_id>``, by ``/proc/*/environ``.

    Unreadable ``environ`` (a process of another UID, or one that exited
    mid-scan) is skipped: it is not evidence either way.
    """
    needle = f"{JOB_ID_MARKER}={job_id}".encode("utf-8")
    found: set[int] = set()
    for pid in _pids():
        if pid in _NEVER:
            continue
        try:
            with open(f"{PROC_ROOT}/{pid}/environ", "rb") as fh:
                blob = fh.read()
        except OSError:
            continue
        if needle in blob.split(b"\0"):
            found.add(pid)
    return found


def tracked_pids(
    job_id: str,
    *,
    worker_pid: Optional[int] = None,
    worker_start_time: Optional[int] = None,
    exclude: Iterable[int] = (),
) -> dict[int, str]:
    """Everything Boxa can currently see of one Job: pid → evidence source.

    Sources, strongest first: ``tree`` (walked down from a live worker),
    ``marker`` (``BOXA_JOB_ID`` in the environment), ``descendant`` (walked
    down from a marker match, which is how a child that cleared its own
    environment stays visible while its marked parent lives).
    """
    skip = {int(p) for p in exclude} | {os.getpid()}
    links = parent_map()
    sources: dict[int, str] = {}

    if worker_pid and is_alive(worker_pid, worker_start_time):
        for pid in descendants(int(worker_pid), links):
            sources[pid] = "tree"

    marked = marker_pids(job_id)
    for pid in marked:
        sources[pid] = "marker"
    for pid in marked:
        for child in descendants(pid, links):
            sources.setdefault(child, "descendant")

    for pid in skip:
        sources.pop(pid, None)
    if worker_pid:
        sources.pop(int(worker_pid), None)
    # Zombies and processes that exited during the scan are not survivors.
    # These pids were just read out of `/proc`, so existence is all the
    # evidence there is to re-check — and all that is needed (`is_running`).
    return {pid: source for pid, source in sources.items() if is_running(pid)}


def signal_pids(pids: Iterable[int], sig: int) -> list[int]:
    """Signal these pids, returning the ones that accepted it.

    A pid that already exited is not an error; a pid we may not signal is
    reported by leaving it out of the result.
    """
    sent = []
    for pid in sorted({int(p) for p in pids}):
        if pid in _NEVER or pid == os.getpid():
            continue
        try:
            os.kill(pid, sig)
        except OSError as exc:
            if exc.errno == errno.ESRCH:
                continue
            continue
        sent.append(pid)
    return sent


def wait_until_gone(
    targets: dict[int, Optional[int]], timeout: float, poll: float = 0.05
) -> list[int]:
    """Poll until every ``pid → startTime`` target is gone; return the rest."""
    deadline = time.time() + timeout
    remaining = list(targets)
    while True:
        remaining = [
            pid for pid in remaining if is_alive(pid, targets.get(pid))
        ]
        if not remaining or time.time() >= deadline:
            return remaining
        time.sleep(poll)


def terminate_tree(
    targets: dict[int, Optional[int]],
    *,
    term_grace: float = 3.0,
    kill_grace: float = 1.0,
) -> tuple[list[int], list[int]]:
    """TERM, then KILL what is left. Returns (gone, still alive).

    Identity-checked on the way in and on the way out, so a pid that was
    recycled between the record and this call is never signalled, and success
    is claimed only for a process that actually disappeared.
    """
    live = {
        pid: start for pid, start in targets.items() if is_alive(pid, start)
    }
    if not live:
        return [], []
    signal_pids(live, signal.SIGTERM)
    remaining = wait_until_gone(live, term_grace)
    if remaining:
        signal_pids(remaining, signal.SIGKILL)
        remaining = wait_until_gone(
            {pid: live[pid] for pid in remaining}, kill_grace
        )
    gone = [pid for pid in live if pid not in remaining]
    return sorted(gone), sorted(remaining)
