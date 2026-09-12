"""Codex runtime: the verified immutable per-version copy Jobs run from.

ADR 0037 § "Codex runtime".  Interactive ``codex`` in a Container keeps
running from the mutable shared ``boxa-npm-global`` volume, so
``npm install -g @openai/codex`` takes effect at once.  A **Codex job** never
executes from that volume: ``npm`` rewrites files in place while a run is in
flight and Codex spawns helpers from its own package path.

What this module does, in the order it does it:

1.  **Find.**  Candidate sources are the npm-volume package dir and — on
    Linux, where a host binary is runnable in the Container — the host's
    ``@openai/codex`` package bind-mounted read-only by ``docker-run.sh``.
    The version is the source's ``package.json`` version; newest wins by a
    numeric-component compare.
2.  **Snapshot.**  A found version is not yet a version used.  A manifest of
    the source (relative path, size, mtime) is taken *before* and *after* the
    copy and every copied file is content-hashed against its source; any
    difference — which is exactly what a concurrent ``npm install`` looks
    like — discards the temp dir and keeps the previous runtime.  An
    incomplete or inconsistent copy is never published.
3.  **Check.**  The Linux binary inside the *copy* must answer ``--version``,
    so the copy is proven self-contained (the static binary carries its
    ``codex-path``/``codex-resources`` siblings in the same vendor dir).
4.  **Probe.**  Not a help scan: one real ``codex exec --json`` on the
    cheapest configured model followed by ``codex exec resume`` into that
    thread, verifying ``thread.started``, ``turn.completed``, a non-empty
    ``-o`` file and thread continuity.  The argv comes from
    :mod:`jobs.codex`, so the probe exercises the same command line a Job
    gets.
5.  **Publish.**  Atomically, by renaming the temp dir to
    ``<versions-root>/<version>/``, under a ``flock`` in the versions root
    that serializes Containers sharing the volume.  A ``verified.json``
    marker is what makes a copy usable; the tree is then chmod'ed read-only
    for ``node`` — a convention the Container user could undo, not root
    enforcement (ADR 0037 accepts that for v1).  The temp dir is deleted on
    every way out of :func:`snapshot`, interruptions included, and one an
    interrupted attempt left behind is swept under the same lock by the next
    attempt (:func:`sweep_stale_snapshots`): a snapshot dir is a whole package
    copy, so leaking one is tens of megabytes on a shared volume.

A failed probe is never fatal by itself: the previous verified copy stays in
use and the failure is reported as a loud warning on ``start``/``reply``.
Only when there is no verified copy at all is a Codex job refused, with
``no-verified-runtime`` — there is nothing else to run on, and running from
the mutable volume is the failure this design exists to prevent.

Jobs run the vendor **static binary** of the copy directly, not the copy's
``bin/codex.js``: that is the very process ``codex.js`` spawns, and skipping
the node wrapper removes one process from the Job's tree.

The rollback pin lives in the same shared root and is written under the same
publish lock: every Container on the volume reads it, so two ``runtime use``
calls are two writers of one file, not one.

Paths are env-overridable so the flow can be proven without a Container
restart; the defaults are the fixed Container paths ``docker-run.sh`` mounts.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import platform
import shutil
import subprocess
import tempfile
import time
from contextlib import contextmanager
from typing import Any, Callable, Iterator, NamedTuple, Optional

from . import codex as codex_mod
from . import procs
from .env import baseline_env
from .identity import UNKNOWN_RUN_ID, container_run_id

__all__ = [
    "CODEX_HOST_PKG_DIR_ENV",
    "CODEX_NPM_PKG_DIR_ENV",
    "CODEX_VERSIONS_DIR_ENV",
    "DEFAULT_HOST_PKG_DIR",
    "DEFAULT_NPM_PKG_DIR",
    "DEFAULT_VERSIONS_DIR",
    "NoVerifiedRuntime",
    "PinFailed",
    "Published",
    "Runtime",
    "Snapshot",
    "Source",
    "clear_pin",
    "discover_sources",
    "ensure",
    "listing",
    "manifest",
    "package_binary",
    "package_version",
    "pin",
    "published",
    "read_pin",
    "snapshot",
    "sweep_stale_snapshots",
    "sweep_stale_snapshots_if_idle",
    "version_key",
    "versions_root",
]

# Where the verified copies live: the shared `boxa-codex-versions` volume.
CODEX_VERSIONS_DIR_ENV = "BOXA_JOB_CODEX_VERSIONS_DIR"
DEFAULT_VERSIONS_DIR = "/usr/local/share/boxa-codex-versions"

# The two candidate sources.  The npm volume is the interactive install; the
# host package is bind-mounted read-only by docker-run.sh on Linux only.
CODEX_NPM_PKG_DIR_ENV = "BOXA_JOB_CODEX_NPM_PKG_DIR"
DEFAULT_NPM_PKG_DIR = "/usr/local/share/npm-global/lib/node_modules/@openai/codex"
CODEX_HOST_PKG_DIR_ENV = "BOXA_JOB_CODEX_HOST_PKG_DIR"
DEFAULT_HOST_PKG_DIR = "/run/boxa-codex-host-pkg"

SOURCE_NPM = "npm-volume"
SOURCE_HOST = "host-mount"

# The probe: the cheapest model, the smallest possible turn, twice.
PROBE_MODEL_ENV = "BOXA_JOB_PROBE_MODEL"
DEFAULT_PROBE_MODEL = "gpt-5.6-luna"
PROBE_EFFORT = "low"
PROBE_TIMEOUT_ENV = "BOXA_JOB_PROBE_TIMEOUT"
DEFAULT_PROBE_TIMEOUT = 300.0
PROBE_PROMPT = "Reply with the single word READY and nothing else."
PROBE_RESUME_PROMPT = "Reply with the single word AGAIN and nothing else."

# Name of the marker that makes a published copy usable at all.
MARKER_NAME = "verified.json"
# The copied package tree inside a published version dir.
PACKAGE_NAME = "package"
PIN_NAME = "pin"
LOCK_NAME = "publish.lock"
TEMP_PREFIX = ".snapshot-"
# Written into every snapshot temp dir so a later refresh can tell an
# in-flight copy from one an interrupted process left behind.
OWNER_NAME = "owner.json"

PUBLISH_LOCK_TIMEOUT = 900.0

# A snapshot temp dir this old is garbage whoever owns it: a copy plus the
# probe cannot outlast this (the probe alone is capped at
# `DEFAULT_PROBE_TIMEOUT`), and the dirs are big enough to matter.
STALE_SNAPSHOT_SECONDS = 3600.0

# Vendor layout of the npm package, per architecture: the platform package
# holding the static binary and the target triple under its `vendor/`.
_VENDOR_BY_MACHINE = {
    "x86_64": ("codex-linux-x64", "x86_64-unknown-linux-musl"),
    "amd64": ("codex-linux-x64", "x86_64-unknown-linux-musl"),
    "aarch64": ("codex-linux-arm64", "aarch64-unknown-linux-musl"),
    "arm64": ("codex-linux-arm64", "aarch64-unknown-linux-musl"),
}


class NoVerifiedRuntime(codex_mod.CodexNotFound):
    """No verified Codex runtime copy exists, so a Codex job cannot run.

    A subclass of :class:`jobs.codex.CodexNotFound`: to a caller it is the
    same fact — there is no Codex to run this Job with — with a reason
    attached.
    """

    reason = "no-verified-runtime"

    def __init__(self, message: str, warnings: Optional[list[str]] = None) -> None:
        super().__init__(message)
        self.warnings = list(warnings or [])


class PinFailed(RuntimeError):
    """The shared runtime pin could not be written (lock busy, unwritable root)."""

    reason = "pin-failed"


class Source(NamedTuple):
    """A candidate package dir and the version its ``package.json`` claims."""

    name: str
    path: str
    version: str


class Published(NamedTuple):
    """A version dir under the versions root."""

    version: str
    path: str
    package: str
    binary: Optional[str]
    verified: bool
    marker: Optional[dict[str, Any]]


class Runtime(NamedTuple):
    """The runtime a Codex job runs from, and how it was arrived at."""

    version: str
    binary: str
    path: str
    source: str
    probed: bool
    warnings: list[str]


class Snapshot(NamedTuple):
    """The outcome of one snapshot attempt."""

    published: Optional[Published]
    discarded: Optional[str]
    warnings: list[str]
    probed: bool


# ------------------------------------------------------------------ locations


def versions_root() -> str:
    return os.environ.get(CODEX_VERSIONS_DIR_ENV) or DEFAULT_VERSIONS_DIR


def _npm_pkg_dir() -> str:
    return os.environ.get(CODEX_NPM_PKG_DIR_ENV) or DEFAULT_NPM_PKG_DIR


def _host_pkg_dir() -> str:
    return os.environ.get(CODEX_HOST_PKG_DIR_ENV) or DEFAULT_HOST_PKG_DIR


def package_version(pkg_dir: str) -> Optional[str]:
    """The version in ``<pkg_dir>/package.json``, or None when unreadable."""
    try:
        with open(os.path.join(pkg_dir, "package.json"), "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    version = data.get("version") if isinstance(data, dict) else None
    return str(version) if version else None


def package_binary(pkg_dir: str) -> str:
    """Path of the vendor static binary inside a package dir (this arch)."""
    machine = platform.machine().lower()
    platform_pkg, triple = _VENDOR_BY_MACHINE.get(
        machine, _VENDOR_BY_MACHINE["x86_64"]
    )
    return os.path.join(
        pkg_dir,
        "node_modules",
        "@openai",
        platform_pkg,
        "vendor",
        triple,
        "bin",
        "codex",
    )


def version_key(version: str) -> tuple:
    """Comparison key for a package version: numbers as numbers.

    Deliberately tolerant — a version is whatever ``package.json`` says, and
    an unparsable component must not crash the runtime choice.
    """
    parts: list[tuple[int, Any]] = []
    for chunk in str(version).replace("-", ".").split("."):
        if chunk.isdigit():
            parts.append((1, int(chunk)))
        else:
            parts.append((0, chunk))
    return tuple(parts)


def discover_sources() -> list[Source]:
    """Candidate sources, newest first.

    The host mount is simply absent on macOS (``docker-run.sh`` skips it
    there, a Mach-O binary being unrunnable in a Linux Container), so the
    macOS branch needs no code of its own: the npm volume is the only source.
    """
    found: list[Source] = []
    for name, path in ((SOURCE_NPM, _npm_pkg_dir()), (SOURCE_HOST, _host_pkg_dir())):
        version = package_version(path)
        if version:
            found.append(Source(name, os.path.abspath(path), version))
    found.sort(key=lambda src: version_key(src.version), reverse=True)
    return found


# ------------------------------------------------------------------ published


def _read_marker(path: str) -> Optional[dict[str, Any]]:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def published(root: Optional[str] = None) -> dict[str, Published]:
    """Every version dir under the versions root, verified or not."""
    root = root or versions_root()
    result: dict[str, Published] = {}
    try:
        entries = sorted(os.listdir(root))
    except OSError:
        return result
    for name in entries:
        if name.startswith(".") or name in {LOCK_NAME, PIN_NAME}:
            continue
        path = os.path.join(root, name)
        if not os.path.isdir(path):
            continue
        pkg = os.path.join(path, PACKAGE_NAME)
        marker = _read_marker(os.path.join(path, MARKER_NAME))
        binary = package_binary(pkg)
        usable = marker is not None and os.access(binary, os.X_OK)
        result[name] = Published(
            version=name,
            path=path,
            package=pkg,
            binary=binary if os.path.exists(binary) else None,
            verified=usable,
            marker=marker,
        )
    return result


def _verified(root: str) -> dict[str, Published]:
    return {
        version: entry
        for version, entry in published(root).items()
        if entry.verified
    }


def _newest(versions: list[str]) -> Optional[str]:
    if not versions:
        return None
    return max(versions, key=version_key)


# ------------------------------------------------------------------ pin


def _pin_path(root: str) -> str:
    return os.path.join(root, PIN_NAME)


def read_pin(root: Optional[str] = None) -> Optional[str]:
    """The pinned version, or None.

    The pin lives in the versions root, not in Project state: the copies are
    shared by every Container on the volume, and so is a rollback decision
    about them.
    """
    root = root or versions_root()
    try:
        with open(_pin_path(root), "r", encoding="utf-8") as fh:
            value = fh.read().strip()
    except OSError:
        return None
    return value or None


def pin(version: str, root: Optional[str] = None) -> None:
    """Write the shared pin atomically, under the publish lock.

    The pin file is shared by every Container on the volume, so two
    ``runtime use`` calls are two writers: a fixed ``pin.tmp`` would let one
    ``os.replace`` the other's half-written file, or fail outright because the
    other already consumed it.  Unique temp name plus the publish lock makes
    the last writer win cleanly, and any failure is raised as
    :class:`PinFailed` for the CLI to report as a structured refusal.
    """
    root = root or versions_root()
    try:
        with publish_lock(root):
            fd, tmp = tempfile.mkstemp(prefix=f".{PIN_NAME}.", suffix=".tmp", dir=root)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(f"{version}\n")
                os.replace(tmp, _pin_path(root))
            except OSError:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
    except (OSError, TimeoutError) as exc:
        raise PinFailed(f"could not pin version {version}: {exc}") from exc


def clear_pin(root: Optional[str] = None) -> None:
    """Drop the shared pin, under the same lock ``pin`` writes it with.

    Unpinning is the same shared-volume mutation as pinning, so it takes the
    publish lock too, and a failure is reported rather than swallowed: a
    ``runtime use --auto`` that silently left the old pin in place would keep
    every Container on the rolled-back version while claiming otherwise.
    """
    root = root or versions_root()
    try:
        with publish_lock(root):
            try:
                os.unlink(_pin_path(root))
            except FileNotFoundError:
                # Nothing pinned: already the state the caller asked for.
                pass
    except (OSError, TimeoutError) as exc:
        raise PinFailed(f"could not clear the version pin: {exc}") from exc


# ------------------------------------------------------------------ manifest


def manifest(pkg_dir: str) -> dict[str, tuple]:
    """Relative path → (kind, size, mtime_ns) for every entry in a package.

    Taken before and after the copy: an ``npm install`` landing mid-copy
    changes at least one of these, and that is the whole point of comparing
    them.  Symlinks are recorded by their target, never followed.
    """
    result: dict[str, tuple] = {}
    for dirpath, dirnames, filenames in os.walk(pkg_dir, followlinks=False):
        dirnames.sort()
        for name in sorted(filenames) + sorted(dirnames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, pkg_dir)
            try:
                st = os.lstat(full)
            except OSError:
                result[rel] = ("missing",)
                continue
            if os.path.islink(full):
                try:
                    result[rel] = ("link", os.readlink(full))
                except OSError:
                    result[rel] = ("missing",)
            elif os.path.isdir(full):
                result[rel] = ("dir",)
            else:
                result[rel] = ("file", st.st_size, st.st_mtime_ns)
    return result


def _sha256(path: str) -> Optional[str]:
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for block in iter(lambda: fh.read(1024 * 1024), b""):
                digest.update(block)
    except OSError:
        return None
    return digest.hexdigest()


def _content_mismatch(source: str, copied: str, entries: dict[str, tuple]) -> Optional[str]:
    """First relative path whose copy does not match the source, or None."""
    for rel, entry in entries.items():
        kind = entry[0]
        src_path = os.path.join(source, rel)
        dst_path = os.path.join(copied, rel)
        if kind == "dir":
            if not os.path.isdir(dst_path):
                return rel
            continue
        if kind == "link":
            try:
                if os.readlink(dst_path) != entry[1]:
                    return rel
            except OSError:
                return rel
            continue
        if kind != "file":
            continue
        src_hash = _sha256(src_path)
        dst_hash = _sha256(dst_path)
        if src_hash is None or dst_hash is None or src_hash != dst_hash:
            return rel
    return None


def _copy_tree(source: str, dest: str) -> None:
    """The copy step, one function so a test can mutate the source mid-copy."""
    shutil.copytree(source, dest, symlinks=True)


def _make_read_only(path: str) -> None:
    """chmod the published tree read-only for ``node``.

    A convention, not enforcement: the Container user owns these files and
    could chmod them back (ADR 0037 accepts that for v1).  It documents
    "nothing rewrites files under a running Job" in the filesystem itself.
    """
    for dirpath, dirnames, filenames in os.walk(path, topdown=False):
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            try:
                mode = os.stat(full).st_mode
                os.chmod(full, 0o555 if mode & 0o111 else 0o444)
            except OSError:
                pass
        for name in dirnames:
            try:
                os.chmod(os.path.join(dirpath, name), 0o555)
            except OSError:
                pass
    try:
        os.chmod(path, 0o555)
    except OSError:
        pass


def _rmtree_writable(path: str) -> None:
    """Delete a tree even when it was already chmod'ed read-only."""
    for dirpath, _dirnames, _filenames in os.walk(path, topdown=True):
        try:
            os.chmod(dirpath, 0o755)
        except OSError:
            pass
    shutil.rmtree(path, ignore_errors=True)


def _write_owner(temp: str) -> None:
    """Record who is filling this temp dir, so a sweep can leave it alone."""
    pid = os.getpid()
    try:
        with open(os.path.join(temp, OWNER_NAME), "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "pid": pid,
                    "startTime": procs.process_start_time(pid),
                    "containerRunId": container_run_id(),
                    "createdAt": time.time(),
                },
                fh,
                sort_keys=True,
            )
            fh.write("\n")
    except OSError:
        pass


def _is_stale_snapshot(path: str, *, now: float, max_age: float) -> bool:
    """Is this ``.snapshot-*`` dir abandoned rather than in flight?

    Two ways to be sure, and a pid is only one of them: the volume is shared
    by Containers with separate pid namespaces, so a dead pid is evidence only
    when the owner recorded *this* Container run.  Otherwise age decides.
    """
    owner = _read_marker(os.path.join(path, OWNER_NAME)) or {}
    run_id = owner.get("containerRunId")
    current = container_run_id()
    if (
        run_id
        and run_id != UNKNOWN_RUN_ID
        and run_id == current
        and not procs.is_alive(owner.get("pid"), owner.get("startTime"))
    ):
        return True
    created = owner.get("createdAt")
    if not isinstance(created, (int, float)):
        try:
            created = os.stat(path).st_mtime
        except OSError:
            return False
    return (now - float(created)) >= max_age


def sweep_stale_snapshots(
    root: Optional[str] = None, *, max_age: float = STALE_SNAPSHOT_SECONDS
) -> list[str]:
    """Delete ``.snapshot-*`` dirs an interrupted snapshot left behind.

    A snapshot dir is a whole copy of the Codex package, so an interruption
    between ``mkdtemp`` and the publish would otherwise leak tens of megabytes
    per attempt, forever.  Runs under the publish lock on the next snapshot
    attempt: the same lock the publish itself takes, so no publisher is racing
    a sweeper.
    """
    root = root or versions_root()
    now = time.time()
    removed: list[str] = []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return removed
    for name in names:
        if not name.startswith(TEMP_PREFIX):
            continue
        path = os.path.join(root, name)
        if not os.path.isdir(path):
            continue
        if not _is_stale_snapshot(path, now=now, max_age=max_age):
            continue
        _rmtree_writable(path)
        if not os.path.exists(path):
            removed.append(name)
    return removed


def sweep_stale_snapshots_if_idle(
    root: Optional[str] = None, *, max_age: float = STALE_SNAPSHOT_SECONDS
) -> list[str]:
    """Sweep only if there is something to sweep and nobody is publishing.

    The opportunistic counterpart of :func:`sweep_stale_snapshots`, for the
    paths that do no publishing themselves (a version that is already
    verified).  Both preconditions are there so this can never cost a job
    anything: no ``.snapshot-*`` dir means no work, and a busy publish lock
    means someone else is in the publish path and will sweep there.
    """
    root = root or versions_root()
    try:
        names = os.listdir(root)
    except OSError:
        return []
    if not any(name.startswith(TEMP_PREFIX) for name in names):
        return []
    try:
        with publish_lock(root, timeout=0.0):
            return sweep_stale_snapshots(root, max_age=max_age)
    except (OSError, TimeoutError):
        return []


@contextmanager
def publish_lock(root: str, timeout: float = PUBLISH_LOCK_TIMEOUT) -> Iterator[None]:
    """``flock`` in the versions root: one publisher across all Containers."""
    os.makedirs(root, exist_ok=True)
    fd = os.open(os.path.join(root, LOCK_NAME), os.O_CREAT | os.O_RDWR, 0o666)
    deadline = time.monotonic() + timeout
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise TimeoutError(
                        f"codex runtime publish lock busy for {timeout:.0f}s"
                    )
                time.sleep(0.1)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


# ------------------------------------------------------------------ the probe


class ProbeResult(NamedTuple):
    ok: bool
    detail: Optional[str]
    thread_id: Optional[str]


def probe_model() -> str:
    return os.environ.get(PROBE_MODEL_ENV) or DEFAULT_PROBE_MODEL


def _probe_timeout() -> float:
    raw = os.environ.get(PROBE_TIMEOUT_ENV)
    try:
        return float(raw) if raw else DEFAULT_PROBE_TIMEOUT
    except ValueError:
        return DEFAULT_PROBE_TIMEOUT


def _run_codex(argv: list[str], *, cwd: str, events: str) -> Optional[int]:
    with open(events, "wb") as out:
        try:
            proc = subprocess.run(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=out,
                stderr=subprocess.DEVNULL,
                cwd=cwd,
                env=baseline_env(),
                timeout=_probe_timeout(),
            )
        except (OSError, subprocess.SubprocessError):
            return None
    return proc.returncode


def probe(binary: str, *, model: Optional[str] = None) -> ProbeResult:
    """One real turn plus a resume into its thread, on the copy's own binary.

    A help scan would not have caught the failure this ADR started from: only
    an actual turn proves the copy can authenticate, reach the API, honour
    ``-o`` and continue a thread.
    """
    model = model or probe_model()
    with tempfile.TemporaryDirectory(prefix="boxa-codex-probe-") as work:
        cwd = os.path.join(work, "cwd")
        os.makedirs(cwd, exist_ok=True)
        first_events = os.path.join(work, "start.jsonl")
        first_out = os.path.join(work, "start.md")
        code = _run_codex(
            codex_mod.start_argv(
                binary,
                model=model,
                effort=PROBE_EFFORT,
                cwd=cwd,
                last_message=first_out,
                prompt=PROBE_PROMPT,
            ),
            cwd=cwd,
            events=first_events,
        )
        first = codex_mod.summarize_stream(first_events)
        if code is None:
            return ProbeResult(False, "probe `codex exec` did not run", None)
        if code != 0:
            return ProbeResult(
                False, f"probe `codex exec` exited {code}", first.thread_id
            )
        if not first.thread_id:
            return ProbeResult(False, "probe produced no `thread.started`", None)
        if first.terminal != "turn.completed":
            return ProbeResult(
                False,
                "probe produced no `turn.completed` "
                f"(terminal={first.terminal or 'none'}, error={first.error})",
                first.thread_id,
            )
        if not codex_mod.final_message(first_out):
            return ProbeResult(False, "probe wrote no `-o` message", first.thread_id)

        resume_events = os.path.join(work, "resume.jsonl")
        resume_out = os.path.join(work, "resume.md")
        code = _run_codex(
            codex_mod.resume_argv(
                binary,
                thread_id=first.thread_id,
                model=model,
                effort=PROBE_EFFORT,
                last_message=resume_out,
                prompt=PROBE_RESUME_PROMPT,
            ),
            cwd=cwd,
            events=resume_events,
        )
        second = codex_mod.summarize_stream(resume_events)
        if code is None or code != 0:
            return ProbeResult(
                False, f"probe `codex exec resume` exited {code}", first.thread_id
            )
        if second.terminal != "turn.completed":
            return ProbeResult(
                False,
                "probe resume produced no `turn.completed` "
                f"(terminal={second.terminal or 'none'}, error={second.error})",
                first.thread_id,
            )
        if not second.thread_id:
            # Thread continuity is a thing to PROVE, not to assume from a
            # silent stream: a resume that never says `thread.started` has
            # shown nothing about which thread it landed in (ADR 0037 § "Codex
            # runtime": the probe verifies thread continuity).
            return ProbeResult(
                False,
                "probe resume produced no `thread.started`, so thread "
                "continuity is unproven",
                first.thread_id,
            )
        if second.thread_id != first.thread_id:
            return ProbeResult(
                False,
                "probe resume landed in another thread "
                f"({second.thread_id} != {first.thread_id})",
                first.thread_id,
            )
        if not codex_mod.final_message(resume_out):
            return ProbeResult(
                False, "probe resume wrote no `-o` message", first.thread_id
            )
    return ProbeResult(True, None, first.thread_id)


def binary_answers_version(binary: str) -> Optional[str]:
    """``--version`` of the copied binary: is the copy self-contained at all."""
    if not os.access(binary, os.X_OK):
        return None
    try:
        proc = subprocess.run(
            [binary, "--version"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    out = (proc.stdout or proc.stderr or "").strip().splitlines()
    return out[0] if out else None


# ------------------------------------------------------------------ snapshot


def snapshot(
    source: Source,
    *,
    root: Optional[str] = None,
    do_probe: bool = True,
    prober: Optional[Callable[[str], ProbeResult]] = None,
    copy_tree: Optional[Callable[[str, str], None]] = None,
) -> Snapshot:
    """Copy, verify, probe and publish one source version.

    Returns the published copy, or the reason the attempt was discarded.  It
    never raises for a bad source: keeping the previous runtime and reporting
    is the contract.
    """
    root = root or versions_root()
    copy_tree = copy_tree or _copy_tree
    warnings: list[str] = []

    existing = published(root).get(source.version)
    if existing is not None and existing.verified:
        # Nothing to copy — but a publish that was killed mid-copy leaves a
        # whole package behind, and if every later job takes this fast path
        # that copy is never collected. One cheap `listdir` decides whether
        # there is anything to sweep at all, and the sweep itself is skipped
        # when the publish lock is busy: this path must never wait, and a
        # holder of that lock is about to sweep anyway.
        sweep_stale_snapshots_if_idle(root)
        return Snapshot(existing, None, warnings, False)

    try:
        os.makedirs(root, exist_ok=True)
        with publish_lock(root):
            # Before adding one: drop the temp dirs earlier attempts were
            # interrupted in the middle of (see `sweep_stale_snapshots`).
            sweep_stale_snapshots(root)
        temp = tempfile.mkdtemp(prefix=f"{TEMP_PREFIX}{source.version}-", dir=root)
        _write_owner(temp)
    except (OSError, TimeoutError) as exc:
        # A Container started before the `boxa-codex-versions` volume existed
        # (or a root-owned fresh volume) must produce a clear refusal, not a
        # traceback.
        reason = f"versions root {root} is not usable: {exc}"
        warnings.append(f"codex runtime: {reason}")
        return Snapshot(None, reason, warnings, False)

    def discard(reason: str) -> Snapshot:
        warnings.append(
            f"codex runtime: snapshot of {source.version} from "
            f"{source.name} discarded ({reason}); previous verified runtime "
            "stays in use"
        )
        return Snapshot(None, reason, warnings, False)

    # `temp` holds a whole copy of the Codex package, so it is deleted on every
    # way out of here — the handled discards, an unexpected exception, and a
    # KeyboardInterrupt/SIGTERM in the middle of the copy or the probe alike.
    # Only a successful publish takes it away from us (`os.rename`).
    renamed = False
    try:
        package = os.path.join(temp, PACKAGE_NAME)
        before = manifest(source.path)
        try:
            copy_tree(source.path, package)
        except (OSError, shutil.Error) as exc:
            return discard(f"copy failed: {exc}")

        after = manifest(source.path)
        if after != before:
            # Exactly what a concurrent `npm install -g @openai/codex` looks like.
            return discard("source changed during the copy")
        copied_version = package_version(package)
        if copied_version != source.version:
            return discard(
                f"copied package.json says {copied_version}, source said "
                f"{source.version}",
            )
        mismatch = _content_mismatch(source.path, package, before)
        if mismatch is not None:
            return discard(f"content mismatch at {mismatch}")

        binary = package_binary(package)
        reported = binary_answers_version(binary)
        if reported is None:
            return discard("copied binary does not answer --version")

        probed = False
        if do_probe:
            result = (prober or probe)(binary)
            probed = True
            if not result.ok:
                return discard(f"probe failed: {result.detail}")
            probe_thread = result.thread_id
        else:
            probe_thread = None

        marker = {
            "version": source.version,
            "reportedVersion": reported,
            "source": source.name,
            "sourcePath": source.path,
            "probed": probed,
            "probeModel": probe_model() if probed else None,
            "probeEffort": PROBE_EFFORT if probed else None,
            "probeThreadId": probe_thread,
            "probedAt": time.time() if probed else None,
            "publishedAt": time.time(),
        }
        final = os.path.join(root, source.version)
        try:
            with publish_lock(root):
                winner = published(root).get(source.version)
                if winner is not None and winner.verified:
                    # Another Container published this version while we probed.
                    return Snapshot(winner, None, warnings, probed)
                if os.path.exists(final):
                    _rmtree_writable(final)
                with open(
                    os.path.join(temp, MARKER_NAME), "w", encoding="utf-8"
                ) as fh:
                    json.dump(marker, fh, sort_keys=True)
                    fh.write("\n")
                # The owner marker says "a snapshot is in flight here"; it has
                # no business inside a published version dir.
                try:
                    os.unlink(os.path.join(temp, OWNER_NAME))
                except OSError:
                    pass
                os.rename(temp, final)
                renamed = True
                _make_read_only(final)
        except (OSError, TimeoutError) as exc:
            return discard(f"publish failed: {exc}")

        entry = published(root).get(source.version)
        if entry is None or not entry.verified:
            return Snapshot(None, "published copy is not usable", warnings, probed)
        return Snapshot(entry, None, warnings, probed)
    finally:
        if not renamed:
            _rmtree_writable(temp)


# ------------------------------------------------------------------ selection


def ensure(
    *,
    root: Optional[str] = None,
    do_probe: bool = True,
    prober: Optional[Callable[[str], ProbeResult]] = None,
) -> Runtime:
    """The runtime a Codex job must run from, snapshotting a new version first.

    Called *before* the Project lock is taken: a probe takes many seconds and
    the registration lock has to stay short.

    Fast path: the newest found version is already the newest verified copy →
    no manifest, no copy, no probe.  A pin short-circuits even that: a
    rollback means "run this version", so a newer one is not chased.
    """
    root = root or versions_root()
    warnings: list[str] = []
    verified = _verified(root)

    pinned = read_pin(root)
    if pinned:
        entry = verified.get(pinned)
        if entry is not None and entry.binary:
            return Runtime(entry.version, entry.binary, entry.path, "pin", False, [])
        warnings.append(
            f"codex runtime: pinned version {pinned} is not a verified copy; "
            "falling back to the newest verified one"
        )

    sources = discover_sources()
    newest_verified = _newest(list(verified))
    newest_source = sources[0] if sources else None

    if newest_source is not None and (
        newest_verified is None
        or version_key(newest_source.version) > version_key(newest_verified)
    ):
        result = snapshot(
            newest_source, root=root, do_probe=do_probe, prober=prober
        )
        warnings.extend(result.warnings)
        if result.published is not None and result.published.binary:
            entry = result.published
            return Runtime(
                entry.version,
                entry.binary,
                entry.path,
                newest_source.name,
                result.probed,
                warnings,
            )

    if newest_verified is not None:
        entry = verified[newest_verified]
        assert entry.binary is not None
        return Runtime(
            entry.version,
            entry.binary,
            entry.path,
            (entry.marker or {}).get("source") or "published",
            False,
            warnings,
        )

    detail = (
        f"newest found version {newest_source.version} from "
        f"{newest_source.name} could not be verified"
        if newest_source is not None
        else f"no Codex package found (looked in {_npm_pkg_dir()} and "
        f"{_host_pkg_dir()})"
    )
    raise NoVerifiedRuntime(
        "no verified Codex runtime to run a Codex job from: " + detail,
        warnings,
    )


def listing(root: Optional[str] = None) -> list[dict[str, Any]]:
    """One row per version known to this Container: found, verified, in use."""
    root = root or versions_root()
    entries = published(root)
    sources: dict[str, list[str]] = {}
    for src in discover_sources():
        sources.setdefault(src.version, []).append(src.name)
    pinned = read_pin(root)
    verified = [v for v, entry in entries.items() if entry.verified]
    in_use = pinned if pinned in verified else _newest(verified)
    rows = []
    for version in sorted(set(entries) | set(sources), key=version_key, reverse=True):
        entry = entries.get(version)
        rows.append(
            {
                "version": version,
                "sources": sources.get(version, []),
                "verified": bool(entry and entry.verified),
                "inUse": version == in_use,
                "pinned": version == pinned,
                "path": entry.path if entry else None,
                "binary": entry.binary if entry else None,
                "probeModel": (entry.marker or {}).get("probeModel")
                if entry
                else None,
                "probedAt": (entry.marker or {}).get("probedAt") if entry else None,
            }
        )
    return rows
