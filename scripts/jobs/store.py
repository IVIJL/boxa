"""Job state directory, Project lock, records and key reservations (ADR 0037).

Layout, all under ``$XDG_STATE_HOME/boxa/jobs`` (default
``~/.local/state/boxa/jobs``; issue 06 moves it onto a per-Project volume)::

    <project-key-hash>/
        lock                  # Project-level flock, held for registration only
        keys/<key-hash>       # the key RESERVATION: link-published, immutable
        <jobId>/
            record.json       # the live Job record (atomic temp+rename)
            record.lock       # flock around one record read-modify-write
            spec.json         # the request the worker was handed
            heartbeat         # touched by the worker while it waits
            stdout, stderr    # the command's output
            events.jsonl      # a Codex job's stdout: its --json event stream
            last.md           # a Codex job's final message (codex exec -o)
            worker.err        # the worker's own stderr (diagnosis only)

Two writes carry the atomicity guarantees:

*   **The reservation.** The worker writes its full identity (worker pid,
    worker start time, Container run id) to a temporary file and publishes it
    with :func:`os.link` under ``keys/<key-hash>``.  That either creates the
    complete record or fails with ``EEXIST`` because the key is taken — there
    is never an empty or partial reservation, and a leftover temporary file is
    garbage, not a Job.  The same temporary file is linked to
    ``<jobId>/record.json``, so the reservation and the record start out as
    one inode with identical content.
*   **Every later state change.** Written to a temporary file and
    :func:`os.replace`-d over ``record.json``, so a reader never sees a torn
    record.  That breaks the hard link, which is intended: ``keys/<key-hash>``
    keeps the immutable reservation (its jobId is what the index lookup
    needs), ``record.json`` carries the live state.  The merge that precedes
    the rename is a read-modify-write and runs under ``record.lock``, so two
    processes (the worker, ``cancel``, a lazy refresh, gc) cannot each publish
    a copy read before the other's write.
"""

from __future__ import annotations

import errno
import fcntl
import hashlib
import json
import os
import random
import string
import threading
import time
from contextlib import contextmanager
from typing import Any, Iterator, Optional

from .identity import project_key_hash

__all__ = [
    "STATE_RESERVED",
    "STATE_RUNNING",
    "STATE_DONE",
    "STATE_FAILED",
    "STATE_CANCELLED",
    "STATE_INTERRUPTED",
    "STATE_SURVIVORS",
    "STATE_ORPHANED",
    "STATE_FINISHED_UNKNOWN",
    "TERMINAL_STATES",
    "CLEAN_TERMINAL_STATES",
    "UNCLEAR_STATES",
    "RUNNING_STATES",
    "JobStoreError",
    "KeyReserved",
    "ProjectStore",
    "fingerprint",
    "new_job_id",
]

STATE_RESERVED = "reserved"
STATE_RUNNING = "running"
STATE_DONE = "done"
STATE_FAILED = "failed"
STATE_CANCELLED = "cancelled"
STATE_INTERRUPTED = "interrupted"
# Command exited, tracked descendants still alive: the exit code is recorded
# but the Job is NOT finished (ADR 0037 "States and honesty").
STATE_SURVIVORS = "exited-with-survivors"
# Worker dead by identity check, command or tree still alive.
STATE_ORPHANED = "orphaned"
# The command ended after its worker died: no exit code will ever be known.
STATE_FINISHED_UNKNOWN = "finished-unknown"

# "The Job will never change again."
TERMINAL_STATES = frozenset(
    {
        STATE_DONE,
        STATE_FAILED,
        STATE_CANCELLED,
        STATE_INTERRUPTED,
        STATE_FINISHED_UNKNOWN,
    }
)

# Terminal AND fully understood: what `--fresh` may re-run over.
CLEAN_TERMINAL_STATES = frozenset(
    {STATE_DONE, STATE_FAILED, STATE_CANCELLED, STATE_FINISHED_UNKNOWN}
)

# Unclear: the Job's fate is not established (dead worker, foreign Container
# run, survivors left behind). These refuse a retry under the same key until
# `cancel` or `adopt` resolves them.
UNCLEAR_STATES = frozenset(
    {STATE_ORPHANED, STATE_INTERRUPTED, STATE_SURVIVORS}
)

# "Running" for the concurrency ack (issue 03): every non-finished state.
RUNNING_STATES = frozenset(
    {STATE_RESERVED, STATE_RUNNING, STATE_SURVIVORS, STATE_ORPHANED}
)

_ID_ALPHABET = string.ascii_lowercase + string.digits

# In-process guard for the record's read-modify-write. The Job worker updates
# its record from two threads (the main wait and the heartbeat/tree monitor),
# and without this one of them could merge its change into a stale copy and
# silently revert the other's state change.
_RECORD_WRITE_LOCK = threading.RLock()

# Cross-process guard for the same read-modify-write. The writers are separate
# processes — the worker finalizing, `cancel`, the lazy `refresh_states` of any
# CLI call, and gc writing its `gcAt` — and a merge into a stale copy would
# silently revert someone else's change (a `cancelled` record reverted to
# `interrupted` by a gc sweep that read it a moment earlier). The Project lock
# is the wrong instrument here: it guards registration and is never held for
# the length of a sweep, so every record carries its own `flock`, taken inside
# the in-process lock so the worker's two threads never race for it.
RECORD_LOCK_NAME = "record.lock"

# Nesting depth of the record lock per lock path, so a caller already holding
# it can call `update_record` without blocking against its own `flock` (which
# is per open file description, not per process). Only ever touched while
# `_RECORD_WRITE_LOCK` is held, so it is this thread's depth by construction.
_RECORD_LOCK_DEPTH: dict[str, int] = {}


class JobStoreError(RuntimeError):
    """Unusable state directory, unreadable record, or a broken publish."""


class KeyReserved(JobStoreError):
    """The Job key already has a reservation (the link lost the race)."""

    def __init__(self, key: str, job_id: Optional[str]) -> None:
        super().__init__(f"job key {key!r} is already reserved")
        self.key = key
        self.job_id = job_id


def state_root() -> str:
    """Root of the Job state tree, honouring ``XDG_STATE_HOME``."""
    xdg = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return os.path.join(xdg, "boxa", "jobs")


def new_job_id(now: Optional[float] = None) -> str:
    """Short, sortable, collision-resistant Job id (UTC stamp + random tail)."""
    stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime(now or time.time()))
    tail = "".join(random.choice(_ID_ALPHABET) for _ in range(6))
    return f"{stamp}-{tail}"


def fingerprint(argv: list[str], cwd: str, env_names: list[str]) -> str:
    """Request fingerprint: argv + cwd + env NAMES (never env values).

    Two starts under one key are "the same request" exactly when this matches;
    anything else is a conflict rather than a silent second run.
    """
    payload = json.dumps(
        {"argv": list(argv), "cwd": cwd, "envNames": sorted(env_names)},
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:32]


def _key_hash(key: str) -> str:
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:32]


def _read_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise JobStoreError(f"malformed record (not an object): {path}")
    return data


class ProjectStore:
    """All Job state of one Project, addressed by its Project key."""

    def __init__(self, project_key: str, root: Optional[str] = None) -> None:
        self.project_key = project_key
        self.root = root or state_root()
        self.dir = os.path.join(self.root, project_key_hash(project_key))
        self.keys_dir = os.path.join(self.dir, "keys")
        self.lock_path = os.path.join(self.dir, "lock")

    # ---------------------------------------------------------------- layout

    def ensure(self) -> None:
        os.makedirs(self.keys_dir, mode=0o700, exist_ok=True)

    def job_dir(self, job_id: str) -> str:
        return os.path.join(self.dir, job_id)

    def record_path(self, job_id: str) -> str:
        return os.path.join(self.job_dir(job_id), "record.json")

    def spec_path(self, job_id: str) -> str:
        return os.path.join(self.job_dir(job_id), "spec.json")

    def heartbeat_path(self, job_id: str) -> str:
        return os.path.join(self.job_dir(job_id), "heartbeat")

    def stdout_path(self, job_id: str) -> str:
        return os.path.join(self.job_dir(job_id), "stdout")

    def stderr_path(self, job_id: str) -> str:
        return os.path.join(self.job_dir(job_id), "stderr")

    def worker_err_path(self, job_id: str) -> str:
        return os.path.join(self.job_dir(job_id), "worker.err")

    def events_path(self, job_id: str) -> str:
        """A Codex job's stdout: the ``codex exec --json`` event stream.

        A Codex job's stdout *is* the event log, so it gets the name that says
        so; ``boxa-job log`` tails it on demand and nothing else ever prints
        it (ADR 0037: the result is an extract, never the log).
        """
        return os.path.join(self.job_dir(job_id), "events.jsonl")

    def last_message_path(self, job_id: str) -> str:
        """Where ``codex exec -o`` writes the run's final message."""
        return os.path.join(self.job_dir(job_id), "last.md")

    def cancel_path(self, job_id: str) -> str:
        """The cancel REQUEST file: ``cancel`` writes it, the worker obeys it.

        One mechanism, no signalling protocol: ``boxa-job cancel`` creates this
        file *before* it kills anything, so whichever process finalizes the
        record — the live worker or the CLI itself when the worker is gone —
        records ``cancelled`` rather than mistaking a killed command for a
        failed one.
        """
        return os.path.join(self.job_dir(job_id), "cancel")

    def request_cancel(self, job_id: str, by: str) -> None:
        os.makedirs(self.job_dir(job_id), mode=0o700, exist_ok=True)
        with open(self.cancel_path(job_id), "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"requestedAt": time.time(), "by": by}) + "\n")

    def cancel_requested(self, job_id: str) -> bool:
        return os.path.exists(self.cancel_path(job_id))

    def record_lock_path(self, job_id: str) -> str:
        return os.path.join(self.job_dir(job_id), RECORD_LOCK_NAME)

    def key_path(self, key: str) -> str:
        return os.path.join(self.keys_dir, _key_hash(key))

    # ------------------------------------------------------------ locking

    @contextmanager
    def lock(self, timeout: float = 30.0) -> Iterator[None]:
        """Short Project-level ``flock`` around registration (never the work).

        ADR 0037: the check for an existing key and the new Job's reservation
        happen under one lock, so two simultaneous starts cannot both see an
        empty Project.  The lock is released before the command runs.
        """
        self.ensure()
        fd = os.open(self.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        deadline = time.time() + timeout
        try:
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError as exc:
                    if exc.errno not in (errno.EACCES, errno.EAGAIN):
                        raise
                    if time.time() >= deadline:
                        raise JobStoreError(
                            "timed out waiting for the Project job lock at "
                            f"{self.lock_path}"
                        ) from exc
                    time.sleep(0.05)
            try:
                yield
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)

    # ------------------------------------------------------------- records

    def write_spec(self, job_id: str, spec: dict[str, Any]) -> None:
        os.makedirs(self.job_dir(job_id), mode=0o700, exist_ok=True)
        self._atomic_write(self.spec_path(job_id), spec)

    def load_spec(self, job_id: str) -> dict[str, Any]:
        return _read_json(self.spec_path(job_id))

    def load_record(self, job_id: str) -> Optional[dict[str, Any]]:
        """The live record, or None when it was never published."""
        try:
            return _read_json(self.record_path(job_id))
        except FileNotFoundError:
            return None
        except (OSError, ValueError) as exc:
            raise JobStoreError(
                f"unreadable job record for {job_id}: {exc}"
            ) from exc

    def publish_reservation(self, key: str, record: dict[str, Any]) -> None:
        """Publish the worker's identity as the key's reservation, or fail.

        Complete-or-nothing: the temporary file holds the whole record before
        any published name exists.  ``EEXIST`` on the key link means another
        worker already owns this key.
        """
        job_id = record["jobId"]
        job_dir = self.job_dir(job_id)
        os.makedirs(job_dir, mode=0o700, exist_ok=True)
        self.ensure()
        tmp = os.path.join(job_dir, f"record.json.new.{os.getpid()}")
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(record, fh, sort_keys=True, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        try:
            os.link(tmp, self.key_path(key))
        except FileExistsError:
            os.unlink(tmp)
            raise KeyReserved(key, self.key_job_id(key)) from None
        except OSError:
            os.unlink(tmp)
            raise
        try:
            os.link(tmp, self.record_path(job_id))
        except FileExistsError as exc:
            raise JobStoreError(
                f"job record already exists for {job_id} (refusing to reuse)"
            ) from exc
        finally:
            os.unlink(tmp)

    @contextmanager
    def record_lock(self, job_id: str, timeout: float = 30.0) -> Iterator[None]:
        """Per-record ``flock`` around one read-modify-write.

        Held for the merge only (read, update, rename), never for any work.
        A missing Job directory is not an error here: the caller's
        :meth:`update_record` is about to fail with a clear message instead.

        Re-entrant, and it has to be: ``flock`` is per open file description,
        so a caller that already holds this record's lock and then calls
        :meth:`update_record` would block against itself.  The in-process
        ``RLock`` is held for the whole body, so the nesting depth below is
        only ever this thread's.
        """
        path = self.record_lock_path(job_id)
        with _RECORD_WRITE_LOCK:
            held = _RECORD_LOCK_DEPTH.get(path, 0)
            if held:
                _RECORD_LOCK_DEPTH[path] = held + 1
                try:
                    yield
                finally:
                    _RECORD_LOCK_DEPTH[path] = held
                return
            try:
                fd = os.open(
                    self.record_lock_path(job_id), os.O_RDWR | os.O_CREAT, 0o600
                )
            except OSError:
                yield
                return
            deadline = time.time() + timeout
            try:
                while True:
                    try:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except OSError as exc:
                        if exc.errno not in (errno.EACCES, errno.EAGAIN):
                            raise
                        if time.time() >= deadline:
                            raise JobStoreError(
                                "timed out waiting for the record lock of "
                                f"{job_id}"
                            ) from exc
                        time.sleep(0.02)
                _RECORD_LOCK_DEPTH[path] = 1
                try:
                    yield
                finally:
                    _RECORD_LOCK_DEPTH.pop(path, None)
                    fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)

    def update_record(self, job_id: str, **changes: Any) -> dict[str, Any]:
        """Atomically merge ``changes`` into the live record (temp+rename).

        The merge is a read-modify-write, so it runs under the record's own
        lock: another process must not read this record, be overtaken by this
        write and then re-publish its stale copy on top.
        """
        with self.record_lock(job_id):
            record = self.load_record(job_id)
            if record is None:
                raise JobStoreError(f"no published record for {job_id}")
            record.update(changes)
            self._atomic_write(self.record_path(job_id), record)
            return record

    def _atomic_write(self, path: str, payload: dict[str, Any]) -> None:
        tmp = f"{path}.tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, sort_keys=True, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)

    # --------------------------------------------------------------- index

    def key_job_id(self, key: str) -> Optional[str]:
        """The jobId reserved under ``key``, straight from the index."""
        try:
            data = _read_json(self.key_path(key))
        except FileNotFoundError:
            return None
        except (OSError, ValueError) as exc:
            raise JobStoreError(
                f"unreadable key reservation for {key!r}: {exc}"
            ) from exc
        job_id = data.get("jobId")
        return str(job_id) if job_id else None

    def release_key(self, key: str) -> None:
        """Drop a key's reservation (only under the lock, only when finished)."""
        try:
            os.unlink(self.key_path(key))
        except FileNotFoundError:
            pass

    def stash_key(self, key: str) -> Optional[str]:
        """Move a finished Job's binding aside so a new worker can publish.

        ``--fresh`` must not free the key until the replacement Job's
        reservation actually exists: a worker that never gets to ``link()``
        would otherwise leave the Project with the old result on disk and no
        binding for it, so the next ``start`` would run the work again.  The
        rename is atomic and happens under the Project lock — the lock every
        ``start`` and every ``gc --purge`` takes to decide key ownership — so
        no other caller ever observes the key as free, and
        :meth:`restore_key` puts it back if the reservation does not appear.
        """
        path = self.key_path(key)
        stash = f"{path}.stash.{os.getpid()}"
        try:
            os.rename(path, stash)
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise JobStoreError(
                f"could not set aside the reservation of key {key!r}: {exc}"
            ) from exc
        return stash

    def restore_key(self, key: str, stash: Optional[str]) -> bool:
        """Put a stashed binding back. False means it could not be restored."""
        if not stash:
            return False
        try:
            os.rename(stash, self.key_path(key))
        except OSError:
            return False
        return True

    def drop_key_stash(self, stash: Optional[str]) -> None:
        """Forget a stashed binding: the replacement reservation is published."""
        if not stash:
            return
        try:
            os.unlink(stash)
        except OSError:
            pass

    def job_ids(self) -> list[str]:
        """Every Job id in this Project, newest last."""
        try:
            names = os.listdir(self.dir)
        except FileNotFoundError:
            return []
        ids = [
            name
            for name in names
            if name not in ("keys", "lock")
            and os.path.isdir(os.path.join(self.dir, name))
        ]
        return sorted(ids)

    def records(self) -> list[dict[str, Any]]:
        """Every published record in this Project (unpublished dirs skipped)."""
        out = []
        for job_id in self.job_ids():
            try:
                record = self.load_record(job_id)
            except JobStoreError:
                continue
            if record is not None:
                out.append(record)
        return out

    # ----------------------------------------------------------- heartbeat

    def touch_heartbeat(self, job_id: str) -> None:
        path = self.heartbeat_path(job_id)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(f"{time.time():.3f}\n")

    def heartbeat_age(self, job_id: str) -> Optional[float]:
        """Seconds since the worker last touched the heartbeat, or None."""
        try:
            return max(0.0, time.time() - os.stat(self.heartbeat_path(job_id)).st_mtime)
        except OSError:
            return None
