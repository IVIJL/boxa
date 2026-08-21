"""Compare-and-swap writes and compensating transactions for MCP state.

Migration uses conditional replacement while removing retired Boxa content
from shared Project files. A target is re-read immediately before replace, so
a concurrent user edit is refused rather than overwritten. Boxa-private stores
use the same journal for exact multi-file compensation.

An expected pre-image is existence-aware: ``None`` means that the file did not
exist and never compares equal to ``b""``, the pre-image of an existing empty
file. The primitive never retries on its own.
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


def preimage(text: Optional[str]) -> Optional[bytes]:
    """Encode a text pre-image, keeping "the file was absent" distinct.

    ``None`` in, ``None`` out: a caller that read a missing file as empty text
    must pass ``None``, never ``""`` — otherwise the two states collapse and the
    compare-and-swap stops catching a concurrent create/delete.
    """
    return None if text is None else text.encode("utf-8")


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
    """Restore exact pre-mutation bytes/existence without a journalled write.

    Like the atomic writers, this HONOURS a pre-image armed by :func:`_arm`
    (compensation arms Boxa's own post-image) and checks it as the last thing
    before the ``unlink``/``os.replace``, so an edit landing while the temporary
    file is prepared is refused instead of clobbered. Unarmed callers restore
    unconditionally.
    """
    if not entry.existed:
        _verify_armed(entry.path)
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
        # Last act before the replace: honour an armed pre-image, so an edit
        # that landed while this temporary file was written is refused here.
        _verify_armed(entry.path)
        os.replace(tmp, entry.path)
        os.chmod(entry.path, entry.mode)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def _mismatch(current: Optional[bytes], expected: Optional[bytes]) -> bool:
    """Whether ``current`` differs from the expected pre-image.

    Existence is part of the value: a missing file (``None``) is never the
    expected empty file (``b""``) and vice versa, so a concurrent create or
    delete of an empty file is reported instead of being silently accepted.
    """
    return current != expected


# -- conditional replace ------------------------------------------------------
#
# ``swap`` arms the expected pre-image for one path; the atomic writers check it
# as the LAST thing before ``os.replace``. Arming (rather than an extra writer
# argument) keeps the injected writer signature ``(path, text)``, so a writer
# built on :func:`atomic_text` / :func:`atomic_json` — which is what every render
# write is — inherits the check without threading it through by hand.


@dataclass
class _Armed:
    path: str
    expected: Optional[bytes]
    checked: bool = False


_ARMED: list[_Armed] = []


@contextmanager
def _arm(path: str, expected: Optional[bytes]) -> Iterator[_Armed]:
    entry = _Armed(path=os.path.abspath(path), expected=expected)
    _ARMED.append(entry)
    try:
        yield entry
    finally:
        _ARMED.pop()


def _verify_armed(path: str) -> None:
    """Refuse an armed replace whose target no longer holds its pre-image.

    Called from inside the atomic writers with the temporary file already
    written and fsynced, so the re-read reflects the file as it is at the very
    moment of the replace. Unarmed paths (Boxa-private stores) pass through.
    """
    target = os.path.abspath(path)
    for entry in reversed(_ARMED):
        if entry.path == target:
            if _mismatch(read_bytes(path), entry.expected):
                raise ConcurrentModification(path)
            entry.checked = True
            return


def atomic_text(path: str, text: str) -> None:
    """Replace ``path`` with ``text`` atomically, keeping its current mode.

    Low-level writer: it starts no compare-and-swap of its own, but it HONOURS
    one armed by :func:`swap` (see :func:`_verify_armed`). Render writes must go
    through :func:`swap`; only Boxa-private stores serialized by the mutation
    lock may call this directly (they still journal through :func:`record`).
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
        # Last act before the replace: honour an armed pre-image, so an edit
        # that landed while this temporary file was written is refused here.
        _verify_armed(path)
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
        # Last act before the replace: honour an armed pre-image, so an edit
        # that landed while this temporary file was written is refused here.
        _verify_armed(path)
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
    """Take back one write. False when a foreign process changed it since.

    The post-image is compared twice, exactly as the forward path compares the
    pre-image: once up front, so a doomed restore never even creates a temporary
    file, and once inside :func:`restore` immediately before the replace — so an
    edit landing while the rollback's temporary file is written is reported as a
    conflict instead of being overwritten with stale bytes.
    """
    current = read_bytes(entry.path)
    if _mismatch(current, entry.postimage):
        return False
    return _restore_if_unchanged(entry.preimage, entry.postimage)


def _restore_if_unchanged(
    preimage: FileSnapshot, expected: Optional[bytes]
) -> bool:
    """Restore ``preimage`` only while the path still holds ``expected``."""
    try:
        with _arm(preimage.path, expected):
            restore(preimage)
    except ConcurrentModification:
        return False
    return True


# -- compare-and-swap writes --------------------------------------------------


def concurrent_conflict(exc: BaseException) -> Optional[ConcurrentModification]:
    """The CAS refusal behind ``exc``, if any — following translated errors.

    A caller that translates :class:`ConcurrentModification` into its own public
    public lifecycle error type chains the original as ``__cause__``. Batch
    compensation still has to recognize the refusal to report it as "nothing was
    written", so it asks here instead of matching the type directly.
    """
    seen: set[int] = set()
    current: Optional[BaseException] = exc
    while current is not None and id(current) not in seen:
        if isinstance(current, ConcurrentModification):
            return current
        seen.add(id(current))
        current = current.__cause__
    return None


def swap(
    path: str,
    expected: Optional[bytes],
    text: str,
    *,
    writer: Optional[Callable[[str, str], None]] = None,
) -> Optional[WriteRecord]:
    """Replace ``path`` only while its bytes still equal ``expected``.

    ``expected`` is the exact pre-image the new content was derived from, or
    ``None`` for "must not exist" — which is NOT the same as ``b""``, the
    pre-image of an existing empty file. The pre-image is checked twice: once up
    front, so a doomed write never even creates a temporary file, and once inside
    the atomic writer immediately before ``os.replace`` — so an edit landing
    while the temporary file is written is refused too. On mismatch nothing is
    written and :class:`ConcurrentModification` is raised. The write is
    journalled into the innermost :func:`transaction`, if any.

    ``writer`` must perform its replace through :func:`atomic_text` or
    :func:`atomic_json`; that is what makes the check conditional on the
    pre-image. A writer that replaces the path by itself is a programming error
    and is reported as such.
    """
    preimage = snapshot(path)
    if _mismatch(preimage.image, expected):
        raise ConcurrentModification(path)
    with _arm(path, expected) as armed:
        (writer or atomic_text)(path, text)
    if not armed.checked:
        raise WriteError(
            f"conditional writer for {path} bypassed the compare-and-swap replace"
        )
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
    """Delete ``path`` only while its bytes still equal ``expected``.

    ``expected=None`` means "already gone"; an ``expected`` of ``b""`` demands
    an existing empty file, so a concurrent delete raises rather than passing
    for the plan's pre-image.
    """
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
