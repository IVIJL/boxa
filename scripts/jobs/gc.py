"""Retention for Job state: bulky artefacts go, the Job record stays.

ADR 0037 § "State and retention": Job state lives in a per-Project volume, so
it is the Project's own disk that fills up.  Two levels, and the difference
between them is the whole point:

*   **Automatic, on every ``start``/``reply``.** The bulky artefacts of
    TERMINAL Jobs older than :data:`DEFAULT_RETENTION_DAYS` are deleted — the
    event stream, stdout, stderr, the final-message copy, the heartbeat, the
    worker's own stderr.  The :term:`Job record` itself is kept, so the Job
    key stays recognizable and ``result`` still answers with state, exit code,
    thread id and the final message text (the worker copies that onto the
    record when the Job finishes, precisely so it survives this).
*   **Manual ``gc --purge``.** Removes whole record directories, and with them
    the key reservations: a purged key becomes free again.  Nothing does this
    on its own.

What is never touched, at either level: a Job that is not in a terminal state.
That includes ``reserved``, ``running``, ``exited-with-survivors``,
``orphaned`` and an unreadable record — ``exited-with-survivors`` explicitly
so, because its descendants are still alive and its files are still being
written to.

**Age** is the youngest evidence that the Job was active: the later of
``finishedAt`` and the newest mtime under the record directory.  Conservative
on purpose — a Job is only old when *everything* about it is old, so a clock
jump or a hand-edited record cannot make gc delete something recent.
"""

from __future__ import annotations

import os
import shutil
import time
from typing import Any, NamedTuple, Optional

from .store import TERMINAL_STATES, JobStoreError, ProjectStore

__all__ = [
    "BULKY_FILES",
    "DEFAULT_RETENTION_DAYS",
    "GcEntry",
    "GcOutcome",
    "collect",
    "run",
    "sweep_quietly",
]

# The files that hold the bytes. `record.json` and `spec.json` are the small
# durable summary and the request; they are not in here by design.
BULKY_FILES = (
    "events.jsonl",
    "stdout",
    "stderr",
    "last.md",
    "worker.err",
    "heartbeat",
)

DEFAULT_RETENTION_DAYS = 14

_DAY_SECONDS = 86400.0


class GcEntry(NamedTuple):
    """One Job gc has an opinion about."""

    job_id: str
    key: Optional[str]
    state: Optional[str]
    age_seconds: float
    files: list[str]
    bytes: int
    purge: bool

    def as_dict(self) -> dict[str, Any]:
        return {
            "jobId": self.job_id,
            "key": self.key,
            "state": self.state,
            "ageDays": round(self.age_seconds / _DAY_SECONDS, 2),
            "files": list(self.files),
            "bytes": self.bytes,
            "purge": self.purge,
        }


class GcOutcome(NamedTuple):
    """What gc did (or, with ``dry_run``, what it would have done)."""

    entries: list[GcEntry]
    kept: int
    bytes: int
    dry_run: bool
    purge: bool
    older_than_days: float

    def as_dict(self) -> dict[str, Any]:
        return {
            "jobs": [entry.as_dict() for entry in self.entries],
            "count": len(self.entries),
            "kept": self.kept,
            "bytes": self.bytes,
            "dryRun": self.dry_run,
            "purge": self.purge,
            "olderThanDays": self.older_than_days,
        }


def _reference_time(store: ProjectStore, record: dict[str, Any]) -> float:
    """The youngest evidence of activity for this Job (see module docstring)."""
    candidates: list[float] = []
    finished = record.get("finishedAt")
    if isinstance(finished, (int, float)):
        candidates.append(float(finished))
    job_dir = store.job_dir(record["jobId"])
    record_mtime: Optional[float] = None
    try:
        names = os.listdir(job_dir)
    except OSError:
        names = []
    for name in names:
        try:
            mtime = os.stat(os.path.join(job_dir, name)).st_mtime
        except OSError:
            continue
        if name == "record.json":
            # Excluded from the maximum: gc writes `gcAt` onto the record, and
            # that write must not keep postponing a later `--purge`.
            record_mtime = mtime
            continue
        candidates.append(mtime)
    if candidates:
        return max(candidates)
    return record_mtime if record_mtime is not None else 0.0


def _existing_bulky(store: ProjectStore, job_id: str) -> tuple[list[str], int]:
    job_dir = store.job_dir(job_id)
    files: list[str] = []
    total = 0
    for name in BULKY_FILES:
        path = os.path.join(job_dir, name)
        try:
            total += os.stat(path).st_size
        except OSError:
            continue
        files.append(name)
    return files, total


def _dir_bytes(store: ProjectStore, job_id: str) -> int:
    job_dir = store.job_dir(job_id)
    total = 0
    for root, _dirs, names in os.walk(job_dir):
        for name in names:
            try:
                total += os.stat(os.path.join(root, name)).st_size
            except OSError:
                continue
    return total


def collect(
    store: ProjectStore,
    *,
    older_than_days: float = DEFAULT_RETENTION_DAYS,
    purge: bool = False,
    now: Optional[float] = None,
) -> GcOutcome:
    """Decide what gc would remove. Reads only; changes nothing."""
    moment = time.time() if now is None else now
    cutoff = older_than_days * _DAY_SECONDS
    entries: list[GcEntry] = []
    kept = 0
    total = 0
    for job_id in store.job_ids():
        try:
            record = store.load_record(job_id)
        except JobStoreError:
            # An unreadable record is an unclear Job, not garbage: `start`
            # reports it and `cancel`/`adopt` resolve it. gc keeps its hands
            # off (ADR 0037 "States and honesty").
            kept += 1
            continue
        if record is None or record.get("state") not in TERMINAL_STATES:
            kept += 1
            continue
        age = moment - _reference_time(store, record)
        if age < cutoff:
            kept += 1
            continue
        if purge:
            size = _dir_bytes(store, job_id)
            files = ["<record dir>"]
        else:
            files, size = _existing_bulky(store, job_id)
            if not files:
                kept += 1
                continue
        entries.append(
            GcEntry(
                job_id=job_id,
                key=record.get("key"),
                state=record.get("state"),
                age_seconds=age,
                files=files,
                bytes=size,
                purge=purge,
            )
        )
        total += size
    return GcOutcome(
        entries=entries,
        kept=kept,
        bytes=total,
        dry_run=False,
        purge=purge,
        older_than_days=older_than_days,
    )


def _delete_bulky(store: ProjectStore, entry: GcEntry, at: float) -> None:
    job_dir = store.job_dir(entry.job_id)
    for name in entry.files:
        try:
            os.unlink(os.path.join(job_dir, name))
        except OSError:
            continue
    try:
        store.update_record(
            entry.job_id,
            gcAt=at,
            gcRemoved=list(entry.files),
            gcBytes=entry.bytes,
        )
    except JobStoreError:
        pass


def _purge_record(store: ProjectStore, entry: GcEntry) -> None:
    """Remove the record dir and, with it, the key's reservation."""
    key = entry.key
    if key and store.key_job_id(key) == entry.job_id:
        store.release_key(key)
    shutil.rmtree(store.job_dir(entry.job_id), ignore_errors=True)


def run(
    store: ProjectStore,
    *,
    older_than_days: float = DEFAULT_RETENTION_DAYS,
    purge: bool = False,
    dry_run: bool = False,
    now: Optional[float] = None,
) -> GcOutcome:
    """Collect, then (unless ``dry_run``) delete. Returns what was decided.

    ``--purge`` takes the Project lock: it frees key reservations, and a
    concurrent ``start`` decides under that same lock whether a key is taken.
    The bulky-file sweep needs no lock — it only ever touches files of Jobs
    that will never change again.
    """
    outcome = collect(
        store, older_than_days=older_than_days, purge=purge, now=now
    )
    if dry_run:
        return outcome._replace(dry_run=True)
    at = time.time() if now is None else now
    if purge:
        with store.lock():
            for entry in outcome.entries:
                _purge_record(store, entry)
    else:
        for entry in outcome.entries:
            _delete_bulky(store, entry, at)
    return outcome


def sweep_quietly(
    store: ProjectStore, *, older_than_days: float = DEFAULT_RETENTION_DAYS
) -> Optional[GcOutcome]:
    """The automatic sweep every ``start``/``reply`` performs, before the lock.

    Never purges, never raises: retention is housekeeping, and a Job start
    must not fail because a stale file could not be unlinked.
    """
    try:
        return run(store, older_than_days=older_than_days)
    except (OSError, JobStoreError):
        return None
