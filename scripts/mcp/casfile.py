"""One compare-and-swap primitive for every Boxa-owned config write.

Boxa renders derived state into files it does not own alone: a Project's
``.mcp.json`` and ``.claude/settings.local.json`` are edited by Claude Code
too, ``.git/info/exclude`` by Git and by the user. Boxa's mutation lock only
serializes Boxa processes, so a plan built from a pre-image can be stale by the
time it is written. Every render write therefore goes through :func:`swap`,
which re-reads the file immediately before the atomic replace and raises
:class:`ConcurrentModification` instead of clobbering a foreign edit.

The same journal that makes the check possible also makes compensation exact:
:func:`transaction` records what Boxa actually wrote (pre-image + post-image)
and :meth:`Transaction.rollback` restores a path only while its current bytes
still equal Boxa's own post-image. A concurrent edit made *after* Boxa's write
is reported, never overwritten.

``.git/info/exclude`` is append-oriented and shared with Git, so it is written
with :func:`append_rule`, whose compensation removes only Boxa's own appended
line and leaves every concurrent edit in place.

Callers decide what a :class:`ConcurrentModification` means — a bounded retry
(convergence) or an aborted batch reported as skipped/failed (host renders).
The primitive never retries on its own.
"""

from __future__ import annotations

import json
import os
import stat
from contextlib import contextmanager
from dataclasses import dataclass, field
from typing import Any, Callable, Iterator, Optional


class ConcurrentModification(Exception):
    """A file changed between the plan's pre-image and the commit write."""

    def __init__(self, path: str) -> None:
        super().__init__(path)
        self.path = path


@dataclass(frozen=True)
class FileSnapshot:
    """Exact pre-mutation content, existence and mode of one path."""

    path: str
    existed: bool
    data: bytes = b""
    mode: int = 0

    @property
    def image(self) -> Optional[bytes]:
        return self.data if self.existed else None


@dataclass(frozen=True)
class WriteRecord:
    """What Boxa wrote to one path, and how to take it back."""

    preimage: FileSnapshot
    postimage: Optional[bytes]
    appended: Optional[str] = None

    @property
    def path(self) -> str:
        return self.preimage.path


class WriteError(OSError):
    """A write primitive could not read or replace a path."""


def read_bytes(path: str) -> Optional[bytes]:
    """Current bytes of ``path``, or ``None`` when it does not exist."""
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise WriteError(f"cannot read {path}: {exc}") from exc


def snapshot(path: str) -> FileSnapshot:
    """Capture bytes, existence and mode so the path can be restored exactly."""
    try:
        info = os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        return FileSnapshot(path=path, existed=False)
    if not stat.S_ISREG(info.st_mode):
        raise WriteError(f"transaction path is not a regular file: {path}")
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        raise WriteError(f"cannot snapshot transaction file {path}: {exc}") from exc
    return FileSnapshot(
        path=path,
        existed=True,
        data=data,
        mode=stat.S_IMODE(info.st_mode),
    )


def restore(entry: FileSnapshot) -> None:
    """Restore exact pre-mutation bytes/existence without a render write."""
    if not entry.existed:
        try:
            os.unlink(entry.path)
        except FileNotFoundError:
            pass
        return
    os.makedirs(os.path.dirname(entry.path), mode=0o755, exist_ok=True)
    tmp = f"{entry.path}.rollback-{os.getpid()}"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, entry.mode)
        with os.fdopen(fd, "wb") as fh:
            fh.write(entry.data)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, entry.mode)
        os.replace(tmp, entry.path)
        os.chmod(entry.path, entry.mode)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def atomic_text(path: str, text: str) -> None:
    """Replace ``path`` with ``text`` atomically, keeping its current mode.

    Low-level writer: it performs no compare-and-swap. Render writes must call
    :func:`swap`; only Boxa-private stores serialized by the mutation lock may
    use this directly (they still journal through :func:`record`).
    """
    os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
    tmp = f"{path}.tmp-{os.getpid()}"
    try:
        mode = stat.S_IMODE(os.stat(path, follow_symlinks=False).st_mode)
    except FileNotFoundError:
        mode = 0o644
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def atomic_json(path: str, data: dict[str, Any], mode: int) -> None:
    """Replace ``path`` with a pretty JSON document at exactly ``mode``."""
    os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
    tmp = f"{path}.tmp-{os.getpid()}"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


# -- journal ------------------------------------------------------------------


@dataclass
class Transaction:
    """Accumulated writes of one compensating batch."""

    records: list[WriteRecord] = field(default_factory=list)
    rolled_back: bool = False

    def add(self, entry: WriteRecord) -> None:
        self.records.append(entry)

    def rollback(self) -> tuple[list[str], list[str]]:
        """Undo this batch's writes, newest first.

        Returns ``(errors, concurrent_paths)``: paths whose restore failed, and
        paths a foreign process rewrote after Boxa's own write — those are left
        untouched and reported so the caller can say so rather than clobber.
        """
        self.rolled_back = True
        errors: list[str] = []
        concurrent: list[str] = []
        for entry in reversed(self.records):
            try:
                if not undo(entry):
                    concurrent.append(entry.path)
            except OSError as exc:
                errors.append(f"{entry.path}: {exc}")
        self.records.clear()
        return errors, concurrent


_STACK: list[Transaction] = []


def _journal(entry: WriteRecord) -> WriteRecord:
    if _STACK:
        _STACK[-1].add(entry)
    return entry


@contextmanager
def transaction() -> Iterator[Transaction]:
    """Journal every write inside the block so it can be compensated exactly.

    Nesting is supported: an inner batch that completes hands its records to the
    enclosing batch, so an outer failure still takes back the inner writes.
    """
    txn = Transaction()
    _STACK.append(txn)
    try:
        yield txn
    finally:
        _STACK.pop()
        if _STACK and not txn.rolled_back:
            _STACK[-1].records.extend(txn.records)


@contextmanager
def record(path: str) -> Iterator[None]:
    """Journal a bespoke write to ``path`` (mode choreography kept by caller).

    For Boxa-private stores whose permission handling cannot be expressed by
    :func:`atomic_text`. It journals but does not compare-and-swap, so it is
    only correct for files no foreign process writes.
    """
    preimage = snapshot(path)
    try:
        yield
    finally:
        postimage = read_bytes(path)
        if postimage != preimage.image:
            _journal(WriteRecord(preimage=preimage, postimage=postimage))


def undo(entry: WriteRecord) -> bool:
    """Take back one write. False when a foreign process changed it since."""
    current = read_bytes(entry.path)
    if entry.appended is not None:
        return _undo_append(entry, current)
    if current != entry.postimage:
        return False
    restore(entry.preimage)
    return True


def _undo_append(entry: WriteRecord, current: Optional[bytes]) -> bool:
    """Remove only Boxa's own appended line, preserving concurrent edits."""
    if current is None:
        return True
    try:
        text = current.decode("utf-8")
    except UnicodeError:
        return False
    lines = text.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if line.rstrip("\n") == entry.appended:
            del lines[index]
            break
    else:
        return True
    remainder = "".join(lines)
    if not remainder and not entry.preimage.existed:
        try:
            os.unlink(entry.path)
        except FileNotFoundError:
            pass
        return True
    atomic_text(entry.path, remainder)
    return True


# -- compare-and-swap writes --------------------------------------------------


def _mismatch(current: Optional[bytes], expected: Optional[bytes]) -> bool:
    if expected is None:
        return current is not None
    return (current if current is not None else b"") != expected


def swap(
    path: str,
    expected: Optional[bytes],
    text: str,
    *,
    writer: Optional[Callable[[str, str], None]] = None,
) -> Optional[WriteRecord]:
    """Replace ``path`` only while its bytes still equal ``expected``.

    ``expected`` is the exact pre-image the new content was derived from, or
    ``None`` for "must not exist". The check happens immediately before the
    atomic replace; on mismatch nothing is written and
    :class:`ConcurrentModification` is raised. The write is journalled into the
    innermost :func:`transaction`, if any.
    """
    preimage = snapshot(path)
    if _mismatch(preimage.image, expected):
        raise ConcurrentModification(path)
    (writer or atomic_text)(path, text)
    postimage = read_bytes(path)
    if postimage == preimage.image:
        return None
    return _journal(WriteRecord(preimage=preimage, postimage=postimage))


def swap_json(
    path: str,
    expected: Optional[bytes],
    data: dict[str, Any],
    mode: int,
) -> Optional[WriteRecord]:
    """:func:`swap` for a JSON document written at exactly ``mode``."""
    return swap(
        path,
        expected,
        "",
        writer=lambda target, _text: atomic_json(target, data, mode),
    )


def remove(path: str, expected: Optional[bytes]) -> Optional[WriteRecord]:
    """Delete ``path`` only while its bytes still equal ``expected``."""
    preimage = snapshot(path)
    if _mismatch(preimage.image, expected):
        raise ConcurrentModification(path)
    if not preimage.existed:
        return None
    try:
        os.unlink(path)
    except FileNotFoundError:
        return None
    return _journal(WriteRecord(preimage=preimage, postimage=None))


def append_rule(path: str, rule: str) -> Optional[WriteRecord]:
    """Append ``rule`` once to an append-oriented shared file.

    Used for ``.git/info/exclude``: the file belongs to Git and the user, so
    Boxa never rewrites it wholesale. Compensation (see :func:`undo`) removes
    only this line and keeps any edit made meanwhile.
    """
    preimage = snapshot(path)
    existing = preimage.data.decode("utf-8", "replace") if preimage.existed else ""
    if rule in existing.splitlines():
        return None
    separator = "" if not existing or existing.endswith("\n") else "\n"
    atomic_text(path, existing + separator + rule + "\n")
    postimage = read_bytes(path)
    return _journal(
        WriteRecord(preimage=preimage, postimage=postimage, appended=rule)
    )
