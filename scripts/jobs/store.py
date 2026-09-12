"""Job state directory, Project lock, records and key reservations (ADR 0037).

Layout, all under ``$XDG_STATE_HOME/boxa/jobs`` (default
``~/.local/state/boxa/jobs``; issue 06 moves it onto a per-Project volume)::

    <project-key-hash>/
        lock                  # Project-level flock, held for registration only
        keys/<key-hash>       # the key RESERVATION: link-published, immutable
        <jobId>/
            record.json       # the live Job record (atomic temp+rename)
            spec.json         # the request the worker was handed
            heartbeat         # touched by the worker while it waits
            stdout, stderr    # the command's output
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
    needs), ``record.json`` carries the live state.
"""

from __future__ import annotations

import errno
import fcntl
import hashlib
import json
import os
import random
import string
import time
from contextlib import contextmanager
from typing import Any, Iterator, Optional

from .identity import project_key_hash

__all__ = [
    "STATE_RESERVED",
    "STATE_RUNNING",
    "STATE_DONE",
    "STATE_FAILED",
    "TERMINAL_STATES",
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

# States this slice can reach that mean "the Job will never change again".
# Later slices add cancelled / interrupted / exited-with-survivors /
# orphaned / finished-unknown, which are deliberately NOT listed here.
TERMINAL_STATES = frozenset({STATE_DONE, STATE_FAILED})

_ID_ALPHABET = string.ascii_lowercase + string.digits


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

    def update_record(self, job_id: str, **changes: Any) -> dict[str, Any]:
        """Atomically merge ``changes`` into the live record (temp+rename)."""
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
