"""Ownership, cancel and recovery states for Jobs (ADR 0037, issue 02).

Three questions are answered here, all of them from evidence rather than from
what a record claims:

*   **What of this Job is still alive?** :func:`live_job_pids` unions the tree
    under a live worker, the ``BOXA_JOB_ID`` marker scan and the identities the
    record itself remembers, and labels every pid with the evidence that found
    it. The label matters: ``cancel`` acts on what it can see *now* and only
    reports what it merely remembers.
*   **Is a record still true?** :func:`refresh_states` runs on every CLI call
    and lazily marks a record whose Container run id is foreign
    ``interrupted``, a record whose worker died while its tree lives
    ``orphaned``, and a record whose worker and tree are both gone without an
    exit code ``finished-unknown``. There is no auto-resume and no background
    sweeper: the next caller pays for the truth.
*   **How does a Job stop?** :func:`cancel_job`. One mechanism: the CLI writes
    the cancel REQUEST file first, then kills what Boxa can see, TERM before
    KILL, identity-checked both ways. A live worker sees the request file and
    finalizes the record to ``cancelled`` itself; when no worker is left (or it
    does not cooperate in time) the CLI finalizes the record. Either way a
    killed command is never mistaken for a failed one.

Stated limits, printed by ``cancel`` because they are part of the contract: a
process that cleared the marker after its worker died has neither a marker nor
a live ancestor to anchor on, and anything started through the rootless Docker
daemon is not a descendant and may not even appear in the Container's
``/proc``.
"""

from __future__ import annotations

import signal
import time
from typing import Any, Optional

from . import codex
from . import procs
from .identity import container_run_id
from .store import (
    CLEAN_TERMINAL_STATES,
    STATE_CANCELLED,
    STATE_DONE,
    STATE_FAILED,
    STATE_FINISHED_UNKNOWN,
    STATE_INTERRUPTED,
    STATE_ORPHANED,
    STATE_RESERVED,
    TERMINAL_STATES,
    JobStoreError,
    ProjectStore,
)

__all__ = [
    "CANCEL_LIMITS",
    "cancel_job",
    "live_job_pids",
    "refresh_states",
    "survivor_snapshot",
]

# Two sentences, printed verbatim by `cancel`: "no owned process found" means
# "nothing Boxa can see", and these are the two ways that can be wrong.
CANCEL_LIMITS = (
    "a process that cleared BOXA_JOB_ID after its worker died is invisible "
    "to Boxa",
    "anything started through the rootless Docker daemon is not a descendant "
    "and may be outside this /proc",
)

# Evidence labels. The first three are things Boxa can see right now; `record`
# is memory only, and `cancel` never claims to have killed one of those.
SEEN_SOURCES = ("tree", "marker", "descendant")
REMEMBERED_SOURCE = "record"

# How long `cancel` waits for a live worker to finalize the record itself
# before doing it in the worker's place.
WORKER_FINALIZE_TIMEOUT = 10.0


def _worker_identity(record: dict[str, Any]) -> tuple[Optional[int], Optional[int]]:
    worker = record.get("worker") or {}
    return worker.get("pid"), worker.get("startTime")


def worker_alive(record: dict[str, Any]) -> bool:
    """Identity check on the Job's worker: pid *and* start time must match."""
    pid, start = _worker_identity(record)
    return procs.is_alive(pid, start)


def remembered_identities(record: dict[str, Any]) -> list[dict[str, Any]]:
    """Identities the record remembers: the main command and the last tree."""
    out = []
    command = record.get("command") or {}
    if command.get("pid"):
        out.append(command)
    for entry in (record.get("tree") or []) + (record.get("survivors") or []):
        if entry.get("pid"):
            out.append(entry)
    return out


def live_job_pids(record: dict[str, Any]) -> dict[int, dict[str, Any]]:
    """pid → {source, startTime, comm} for everything of this Job still alive.

    ``source`` is the evidence that found it: ``tree`` (walked down from a live
    worker), ``marker``, ``descendant`` (walked down from a marker match) or
    ``record`` (remembered identity, verified alive, but with no live evidence
    linking it to this Job any more).
    """
    job_id = record["jobId"]
    worker_pid, worker_start = _worker_identity(record)
    worker_pid_int = int(worker_pid) if worker_pid else None
    seen = procs.tracked_pids(
        job_id, worker_pid=worker_pid, worker_start_time=worker_start
    )
    live: dict[int, dict[str, Any]] = {}
    for pid, source in seen.items():
        entry = procs.identity_of(pid)
        if entry["startTime"] is None:
            continue
        entry["source"] = source
        live[pid] = entry
    for remembered in remembered_identities(record):
        pid = int(remembered["pid"])
        if pid in live or pid == worker_pid_int:
            continue
        if not procs.is_alive(pid, remembered.get("startTime")):
            continue
        entry = procs.identity_of(pid)
        entry["source"] = REMEMBERED_SOURCE
        live[pid] = entry
    return live


def survivor_snapshot(live: dict[int, dict[str, Any]]) -> list[dict[str, Any]]:
    """The live set as it is written to a record: sorted, small, pid-first."""
    return [live[pid] for pid in sorted(live)]


# --------------------------------------------------------------- lazy refresh


def _finalize_without_worker(
    store: ProjectStore, record: dict[str, Any]
) -> Optional[dict[str, Any]]:
    """A record whose worker is gone and whose tree is empty: what happened?

    The exit code is the only proof of a clean end. Without it the Job is
    ``finished-unknown`` — it ended, but nobody was watching when it did.
    """
    job_id = record["jobId"]
    if store.cancel_requested(job_id):
        return store.update_record(
            job_id, state=STATE_CANCELLED, finishedAt=time.time(), survivors=[]
        )
    exit_code = record.get("exitCode")
    if exit_code is not None:
        codex_spec = record.get("codexRequest")
        if codex_spec:
            # A Codex job's exit code is not the whole truth: a killed
            # `codex exec` exits 0 with no terminal event, so the stream has
            # to be read before this is called `done` (issue 04).
            finished = codex.finish(
                store.events_path(job_id),
                store.last_message_path(job_id),
                codex_spec,
                exit_code,
            )
            return store.update_record(
                job_id,
                state=finished.state,
                codex=finished.extract,
                codexReason=finished.reason,
                finishedAt=record.get("finishedAt") or time.time(),
                survivors=[],
            )
        return store.update_record(
            job_id,
            state=STATE_DONE if exit_code == 0 else STATE_FAILED,
            finishedAt=record.get("finishedAt") or time.time(),
            survivors=[],
        )
    if record.get("state") == STATE_RESERVED:
        # Crash between the reservation and the spawn: there is no command to
        # find, and no way to tell whether one ever ran. Unclear on purpose.
        return store.update_record(
            job_id,
            state=STATE_INTERRUPTED,
            finishedAt=time.time(),
            interruptedReason="worker-died-before-spawn",
        )
    return store.update_record(
        job_id, state=STATE_FINISHED_UNKNOWN, finishedAt=time.time(), survivors=[]
    )


def refresh_record(
    store: ProjectStore, record: dict[str, Any], current_run_id: str
) -> dict[str, Any]:
    """Bring one record up to date with the evidence. Returns the record."""
    state = record.get("state")
    if state in TERMINAL_STATES:
        return record
    job_id = record["jobId"]
    recorded_run_id = (record.get("worker") or {}).get("containerRunId")

    if recorded_run_id != current_run_id:
        # A different Container run wrote this record: its pids mean nothing
        # here, so nothing is killed and nothing is resumed (ADR 0037).
        return store.update_record(
            job_id,
            state=STATE_INTERRUPTED,
            finishedAt=time.time(),
            interruptedReason="container-restart",
        )

    if worker_alive(record):
        # The worker owns the record; it is the one that writes state changes.
        return record

    live = live_job_pids(record)
    if live:
        survivors = survivor_snapshot(live)
        if state == STATE_ORPHANED and record.get("survivors") == survivors:
            return record
        return store.update_record(
            job_id,
            state=STATE_ORPHANED,
            survivors=survivors,
            orphanedAt=record.get("orphanedAt") or time.time(),
        )
    return _finalize_without_worker(store, record)


def refresh_states(store: ProjectStore, run_id: Optional[str] = None) -> None:
    """Lazily re-derive every non-terminal record of the Project.

    Called at the start of every ``boxa-job`` command: an unclear record must
    be unclear *before* the caller acts on it, not after.
    """
    current = container_run_id() if run_id is None else run_id
    for job_id in store.job_ids():
        try:
            record = store.load_record(job_id)
        except JobStoreError:
            # Unreadable record: `start` reports it as unclear from the key
            # index; there is nothing safe to rewrite here.
            continue
        if record is None or record.get("state") in TERMINAL_STATES:
            continue
        try:
            refresh_record(store, record, current)
        except JobStoreError:
            continue


# ---------------------------------------------------------------------- cancel


def cancel_job(
    store: ProjectStore, record: dict[str, Any], *, by: str = "cli"
) -> dict[str, Any]:
    """Kill what Boxa can see of a Job and report what it could not track.

    Order matters: the cancel request file is written *before* any signal, so
    whoever finalizes the record calls the result ``cancelled`` and not
    ``failed``.
    """
    job_id = record["jobId"]
    store.request_cancel(job_id, by)
    live = live_job_pids(record)
    targets = {
        pid: entry.get("startTime")
        for pid, entry in live.items()
        if entry["source"] in SEEN_SOURCES
    }
    untrackable = [
        live[pid] for pid in sorted(live) if live[pid]["source"] == REMEMBERED_SOURCE
    ]
    killed, survived = procs.terminate_tree(targets)

    final = record
    if worker_alive(record):
        # The worker sees the request file and records `cancelled` itself.
        deadline = time.time() + WORKER_FINALIZE_TIMEOUT
        while time.time() < deadline:
            try:
                refreshed = store.load_record(job_id)
            except JobStoreError:
                refreshed = None
            if refreshed and refreshed.get("state") in TERMINAL_STATES:
                final = refreshed
                break
            time.sleep(0.05)
        else:
            # It did not cooperate: stop it, then finalize in its place.
            pid, start = _worker_identity(record)
            procs.terminate_tree({int(pid): start} if pid else {})
            final = None
    else:
        final = None

    summary = {
        "killed": killed,
        "untrackable": [
            {"pid": entry["pid"], "comm": entry.get("comm", "")}
            for entry in untrackable
        ],
        "stillAlive": survived,
        "limits": list(CANCEL_LIMITS),
        "at": time.time(),
    }
    if final is None:
        final = store.update_record(
            job_id,
            state=STATE_CANCELLED,
            finishedAt=time.time(),
            survivors=survivor_snapshot(live_job_pids(record)),
            cancel=summary,
        )
    else:
        final = store.update_record(job_id, cancel=summary)
    return final


# ----------------------------------------------------------------------- adopt


def adoptable(record: dict[str, Any]) -> bool:
    """Only an ``orphaned`` Job can be adopted: something must still be alive."""
    return record.get("state") == STATE_ORPHANED


def clean_terminal(record: dict[str, Any]) -> bool:
    return record.get("state") in CLEAN_TERMINAL_STATES


def sigterm_worker(record: dict[str, Any]) -> None:
    """Used only by tests and by cancel's non-cooperation path."""
    pid, start = _worker_identity(record)
    if pid and procs.is_alive(pid, start):
        procs.signal_pids([int(pid)], signal.SIGTERM)
