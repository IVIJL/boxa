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

**What gc claims, it did.** Only a successful unlink counts as a removal and
only its bytes count as freed; anything that could not be removed is named in
``failed`` on the entry (and in ``gcFailed`` on the record), never silently
swallowed — including a record that could not be updated, which leaves the
freed bytes without a durable ``gcAt``.  ``--purge`` removes the record
directory *before* it frees the key, so a failed removal leaves both in place
instead of reporting a purge that did not happen, and re-checks eligibility
under the Project lock.  ``cancel`` takes that same lock for its record
mutations, so the recheck cannot be overtaken by a cancel landing mid-removal;
every other record update (here, in the worker, in ``cancel``) is a
read-modify-write under the record's own ``flock``, so no writer merges its
change into a copy another process has already replaced.

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

from .store import (
    RECORD_LOCK_NAME,
    TERMINAL_STATES,
    JobStoreError,
    ProjectStore,
)

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
    """One Job gc has an opinion about.

    After a real run ``files`` and ``bytes`` are what gc *actually* removed and
    freed, and ``failed`` names what it could not: a removal that fails must
    never be reported as space reclaimed (the record and the output would then
    claim artefacts are gone while they still occupy the volume).
    """

    job_id: str
    key: Optional[str]
    state: Optional[str]
    age_seconds: float
    files: list[str]
    bytes: int
    purge: bool
    failed: tuple[str, ...] = ()

    def as_dict(self) -> dict[str, Any]:
        return {
            "jobId": self.job_id,
            "key": self.key,
            "state": self.state,
            "ageDays": round(self.age_seconds / _DAY_SECONDS, 2),
            "files": list(self.files),
            "bytes": self.bytes,
            "purge": self.purge,
            "failed": list(self.failed),
        }


class GcOutcome(NamedTuple):
    """What gc did (or, with ``dry_run``, what it would have done)."""

    entries: list[GcEntry]
    kept: int
    bytes: int
    dry_run: bool
    purge: bool
    older_than_days: float

    @property
    def failures(self) -> list[GcEntry]:
        """The entries gc could not fully remove. Empty is the normal case."""
        return [entry for entry in self.entries if entry.failed]

    def as_dict(self) -> dict[str, Any]:
        return {
            "jobs": [entry.as_dict() for entry in self.entries],
            "count": len(self.entries),
            "kept": self.kept,
            "bytes": self.bytes,
            "dryRun": self.dry_run,
            "purge": self.purge,
            "olderThanDays": self.older_than_days,
            "failed": [
                {"jobId": entry.job_id, "files": list(entry.failed)}
                for entry in self.failures
            ],
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
        if name == RECORD_LOCK_NAME:
            # Bookkeeping of the record write, not activity of the Job: it is
            # created by the first update and would otherwise make gc's own
            # writes evidence of a young Job.
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


def _delete_bulky(store: ProjectStore, entry: GcEntry, at: float) -> GcEntry:
    """Unlink this Job's bulky files; report only what really went.

    A file that could not be unlinked still occupies the volume, so counting
    it as freed would make both the record's ``gcRemoved``/``gcBytes`` and the
    command's output claim space that was never reclaimed.
    """
    job_dir = store.job_dir(entry.job_id)
    removed: list[str] = []
    failed: list[str] = []
    freed = 0
    for name in entry.files:
        path = os.path.join(job_dir, name)
        try:
            size = os.stat(path).st_size
        except OSError:
            size = 0
        try:
            os.unlink(path)
        except FileNotFoundError:
            # Already gone: nothing to reclaim, and nothing to complain about.
            continue
        except OSError:
            failed.append(name)
            continue
        removed.append(name)
        freed += size
    if not removed and not failed:
        return entry._replace(files=removed, bytes=freed, failed=())
    changes: dict[str, Any] = {
        "gcAt": at,
        "gcRemoved": removed,
        "gcBytes": freed,
        # Always written, so a successful retry clears what an earlier failed
        # sweep recorded: a stale `gcFailed` would keep naming a file that is
        # long gone.
        "gcFailed": failed,
    }
    try:
        store.update_record(entry.job_id, **changes)
    except (JobStoreError, OSError) as exc:
        # The bytes really are gone, but nothing durable says so: without
        # `gcAt` the next sweep re-reports this Job, and a caller told
        # "success" would never learn the record is unwritable. It is this
        # Job's failure, named on the entry — and still not fatal to the rest
        # of the sweep.
        failed.append(f"<{os.path.basename(store.record_path(entry.job_id))}>: {exc}")
    return entry._replace(files=removed, bytes=freed, failed=tuple(failed))


def _purge_record(store: ProjectStore, entry: GcEntry) -> GcEntry:
    """Remove the record dir and, with it, the key's reservation.

    The tree goes **first** and its errors are surfaced: freeing the key while
    the record dir survives would report a purge that did not happen and leave
    the key pointing at a reservation a new ``start`` could then collide with.
    """
    job_dir = store.job_dir(entry.job_id)
    try:
        shutil.rmtree(job_dir)
    except OSError as exc:
        return entry._replace(bytes=0, failed=(f"<record dir>: {exc}",))
    if os.path.exists(job_dir):
        return entry._replace(
            bytes=0, failed=("<record dir>: still present after removal",)
        )
    key = entry.key
    try:
        if key and store.key_job_id(key) == entry.job_id:
            store.release_key(key)
    except (JobStoreError, OSError) as exc:
        # The Job is gone and its key is not: say exactly that, with no
        # traceback. `start` under this key finds a binding with no record
        # directory behind it, treats it as free and says so, so the Project
        # is usable meanwhile.
        return entry._replace(
            failed=(
                f"<key reservation>: {exc} (key {key!r} still bound to the "
                "purged job; the next `start` under it frees the binding)",
            )
        )
    return entry


def _still_eligible(
    store: ProjectStore,
    job_id: str,
    *,
    older_than_days: float,
    now: Optional[float] = None,
) -> bool:
    """Re-answer "may this Job be purged?" with the record as it is NOW.

    ``collect`` decided before the Project lock was taken.  A ``cancel`` that
    landed in between writes a cancel request and a fresh record, which is
    recent activity on a Job the sweep had already written off — so the
    verdict is taken again under the lock, right before the deletion.
    """
    moment = time.time() if now is None else now
    try:
        record = store.load_record(job_id)
    except JobStoreError:
        return False
    if record is None or record.get("state") not in TERMINAL_STATES:
        return False
    age = moment - _reference_time(store, record)
    return age >= older_than_days * _DAY_SECONDS


def _cancel_in_flight(store: ProjectStore, job_id: str) -> bool:
    """Is there a cancel request this Job's record does not reflect yet?

    ``cancel`` writes its request under the record lock *before* it kills
    anything, so a request newer than the record's own ``finishedAt`` belongs
    to a cancel whose record write is still to come — gc deleting the
    artefacts under it would take away exactly what that cancel is about to
    report on.  A request older than ``finishedAt`` is the finished cancel the
    record already states, and keeps nothing out of retention.
    """
    try:
        requested = os.stat(store.cancel_path(job_id)).st_mtime
    except OSError:
        return False
    try:
        record = store.load_record(job_id)
    except JobStoreError:
        return True
    finished = (record or {}).get("finishedAt")
    if not isinstance(finished, (int, float)) or isinstance(finished, bool):
        return True
    return requested > float(finished)


def run(
    store: ProjectStore,
    *,
    older_than_days: float = DEFAULT_RETENTION_DAYS,
    purge: bool = False,
    dry_run: bool = False,
    now: Optional[float] = None,
) -> GcOutcome:
    """Collect, then (unless ``dry_run``) delete. Returns what was really done.

    ``--purge`` takes the Project lock: it frees key reservations, a
    concurrent ``start`` decides under that same lock whether a key is taken,
    and ``cancel`` mutates a record under it too.  Eligibility is re-checked
    under that lock (``_still_eligible``), because ``collect`` ran before it,
    and the recheck now holds for the whole removal.  The bulky-file sweep
    takes no Project lock — it frees no keys and removes no records — but it
    re-checks state and age under each record's own lock, the lock every
    record writer holds for its read-modify-write, and keeps it for the
    unlinks: a Job made active again by a concurrent cancel keeps its logs.
    Both levels also refuse a Job with a cancel request its record does not
    reflect yet (:func:`_cancel_in_flight`), because a cancel writes that
    request before its record write.

    The returned entries describe the *result*: files that were removed, bytes
    that were really freed, and ``failed`` for anything that survived.
    """
    outcome = collect(
        store, older_than_days=older_than_days, purge=purge, now=now
    )
    if dry_run:
        return outcome._replace(dry_run=True)
    at = time.time() if now is None else now
    done: list[GcEntry] = []
    skipped = 0
    if purge:
        with store.lock():
            for entry in outcome.entries:
                if not _still_eligible(
                    store,
                    entry.job_id,
                    older_than_days=older_than_days,
                    now=now,
                ) or _cancel_in_flight(store, entry.job_id):
                    # Active again since `collect` looked: not garbage.
                    skipped += 1
                    continue
                done.append(_purge_record(store, entry))
    else:
        for entry in outcome.entries:
            # `collect` decided before anything was held. A cancel that landed
            # since writes a cancel request and a fresh record, which is
            # recent activity on a Job whose artefacts are about to go — so
            # the verdict is taken again under that record's own lock, which
            # every record writer holds for its read-modify-write, and it then
            # holds for the whole unlink.
            with store.record_lock(entry.job_id):
                if not _still_eligible(
                    store,
                    entry.job_id,
                    older_than_days=older_than_days,
                    now=now,
                ) or _cancel_in_flight(store, entry.job_id):
                    # Active again since `collect` looked — or a cancel is in
                    # flight on it, which the unlinks must not undercut.
                    skipped += 1
                    continue
                done.append(_delete_bulky(store, entry, at))
    return outcome._replace(
        entries=done,
        kept=outcome.kept + skipped,
        bytes=sum(entry.bytes for entry in done),
    )


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
