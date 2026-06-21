"""Root-side secret staging into the boxa-mcp-private store (ADR 0014, issue 16).

The credential-isolation core of ADR 0014 splits secret delivery in two:

  * the secret-FREE MCP profile reaches the Container via a live read-only
    bind-mount the broker reads as ``boxa-mcp`` (references only);
  * the secret VALUES cannot cross by bind-mount — a host ``0600`` file carries
    the host UID (host ``user`` 1000 -> container ``node``), so it would be
    readable by the AGENT and unreadable by ``boxa-mcp`` (backwards). Secrets
    are therefore STAGED by root: copied out of the read-only mount into a
    ``boxa-mcp``-private tmpfs (``/run/boxa-mcp/secrets``, dir ``0700``
    ``boxa-mcp``, file ``0400`` ``boxa-mcp``) that ``node`` cannot read.

This module is that single, reusable staging step. It runs as ROOT (the only
account that can read the host ``0600`` secret files through the gated mount)
from the entrypoint's root phase BEFORE the drop to ``node`` (ADR 0003: no
setuid, no NOPASSWD, no persistent root). Issue 17's ``boxa mcp reload``
re-invokes the SAME code through a momentary ``docker exec -u 0``.

Scope is least-privilege (ADR 0014): only the GLOBAL secret store and THIS
Container's Project store are ever staged. A Container for Project A never
receives Project B's secrets, because only B's sanitized basename is ever
considered, and only when it is *this* Container's Project.

The staged basenames mirror the canonical store exactly (``secrets.json`` for
global, ``<sanitized-key>.secrets.json`` for a Project), because that is what
``mcp.broker._staged_secrets_path`` resolves and reads on every spawn. The
sanitizer is REUSED from ``mcp.profile`` (never reinvented in shell) so the
staged Project filename matches the basename the broker derives from the same
key.

SECRET-SAFE: nothing here ever logs, prints, or returns a secret VALUE. A
:class:`StageResult` carries only scope LABELS, file basenames, and counts —
identity metadata the entrypoint / reload front-end may safely surface.
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass, field
from typing import Optional

from .profile import _sanitize_project

# Staged-file permissions: owner read only. The broker reads it as boxa-mcp;
# nothing else (not even the owner-write the canonical 0600 store keeps, since a
# staged copy is never written back). node cannot read it both because the file
# is 0400 owned boxa-mcp AND because the containing dir is 0700 boxa-mcp.
_STAGED_FILE_MODE = 0o400


@dataclass
class StageResult:
    """SECRET-FREE summary of a staging pass.

    ``staged`` lists each scope that produced a staged file (its label and the
    destination basename). ``skipped_absent`` lists in-scope scopes whose source
    file was simply absent (no secrets stored for that scope) — not an error.
    ``removed_stale`` lists destination basenames cleared because they are no
    longer in scope / no longer present at the source, so a rotation that
    removes a secret store does not leave a stale staged copy behind. No secret
    VALUE or env-key NAME ever appears here.
    """

    staged: list[tuple[str, str]] = field(default_factory=list)
    skipped_absent: list[str] = field(default_factory=list)
    removed_stale: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, object]:
        return {
            "staged": [
                {"scope": label, "file": basename} for label, basename in self.staged
            ],
            "skippedAbsent": list(self.skipped_absent),
            "removedStale": list(self.removed_stale),
        }


def _global_basename() -> str:
    """The canonical basename of the GLOBAL secret store (broker-expected)."""
    return "secrets.json"


def project_staged_basename(project_key: str) -> str:
    """The staged basename for a Project's secret store.

    Mirrors ``mcp.secrets.project_secrets_path`` /
    ``mcp.broker._staged_secrets_path``: the sanitized+hashed project key plus
    the ``.secrets.json`` suffix. REUSES ``mcp.profile._sanitize_project`` so the
    staged filename matches the basename the broker derives from the same key —
    never reinvented in shell.
    """
    return _sanitize_project(project_key) + ".secrets.json"


def _in_scope_sources(
    source_root: str, project_key: Optional[str]
) -> list[tuple[str, str, str]]:
    """Resolve the in-scope (label, source_path, dest_basename) triples.

    ``source_root`` is the Container-visible path of the host MCP store (the
    gated read-only mount's ``boxa/mcp`` dir), laid out like the canonical
    store: ``secrets.json`` for global, ``projects/<sanitized>.secrets.json`` for
    a Project. Only GLOBAL and THIS Container's Project are ever returned (ADR
    0014 least-privilege scope); a Project A Container never references Project
    B's basename.
    """
    triples: list[tuple[str, str, str]] = [
        (
            "global",
            os.path.join(source_root, _global_basename()),
            _global_basename(),
        )
    ]
    if project_key:
        basename = project_staged_basename(project_key)
        triples.append(
            (
                "project",
                os.path.join(source_root, "projects", basename),
                basename,
            )
        )
    return triples


def _stage_one(source_path: str, dest_path: str, owner_uid: Optional[int],
               owner_gid: Optional[int]) -> None:
    """Copy one secret file into the private store as 0400, owned boxa-mcp.

    The copy is written to a temp file created 0400 BEFORE any byte is copied so
    secret values never momentarily exist in a wider-than-0400 file, then chowned
    (root only) and atomically renamed over the destination. Mirrors the
    write-then-replace discipline ``mcp.secrets.save_secrets`` uses for the
    canonical store.
    """
    tmp = dest_path + ".tmp"
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    # O_EXCL: we created this file; fchmod to 0400 before copying any secret.
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, _STAGED_FILE_MODE)
    try:
        os.fchmod(fd, _STAGED_FILE_MODE)
        with open(source_path, "rb") as src, os.fdopen(fd, "wb") as dst:
            shutil.copyfileobj(src, dst)
        # Hand ownership to boxa-mcp so the broker (and only the broker /
        # peers under the same UID) can read it; node cannot (wrong UID + the
        # 0700 parent dir). Only root can chown; when owner is unknown (a unit
        # test running unprivileged), skip it — the dir-perms test covers the
        # ownership contract structurally.
        if owner_uid is not None and owner_gid is not None:
            os.chown(tmp, owner_uid, owner_gid)
        # Re-assert 0400 after chown (chown can clear setuid bits but not mode;
        # defensive against an fchmod that a prior umask interaction altered).
        os.chmod(tmp, _STAGED_FILE_MODE)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.replace(tmp, dest_path)


def stage_secrets(
    source_root: str,
    dest_dir: str,
    project_key: Optional[str] = None,
    owner_uid: Optional[int] = None,
    owner_gid: Optional[int] = None,
) -> StageResult:
    """Stage the in-scope secret stores from ``source_root`` into ``dest_dir``.

    Copies the GLOBAL store and (when ``project_key`` is set) THIS Project's
    store from the read-only mount into the boxa-mcp-private dir, under the
    broker-expected basenames, as ``0400`` files owned by ``owner_uid:owner_gid``
    (the boxa-mcp account; ``None`` skips the chown for unprivileged unit
    tests). A source file that is simply absent is recorded as skipped (not an
    error). Any STALE staged file that is no longer in scope (or whose source has
    gone) is removed, so a rotation that deletes a secret store does not leave a
    readable copy behind.

    Returns a SECRET-FREE :class:`StageResult`. Never logs or returns a value.
    """
    os.makedirs(dest_dir, exist_ok=True)
    result = StageResult()

    triples = _in_scope_sources(source_root, project_key)
    in_scope_basenames = {dest_basename for _, _, dest_basename in triples}

    for label, source_path, dest_basename in triples:
        dest_path = os.path.join(dest_dir, dest_basename)
        if os.path.isfile(source_path):
            _stage_one(source_path, dest_path, owner_uid, owner_gid)
            result.staged.append((label, dest_basename))
        else:
            # No secrets stored for this scope: ensure no stale staged copy
            # lingers, then record the (benign) absence.
            if os.path.lexists(dest_path):
                os.unlink(dest_path)
                result.removed_stale.append(dest_basename)
            result.skipped_absent.append(label)

    # Sweep any other *.secrets.json staged previously that is NOT in scope now
    # (e.g. a prior Project's file after the Container was restarted for a
    # different Project, or any leftover). Never leave an out-of-scope secret
    # copy readable in the private store.
    try:
        existing = os.listdir(dest_dir)
    except OSError:
        existing = []
    for name in existing:
        if not name.endswith(".secrets.json") and name != _global_basename():
            continue
        if name in in_scope_basenames:
            continue
        stale_path = os.path.join(dest_dir, name)
        if os.path.isfile(stale_path):
            try:
                os.unlink(stale_path)
                result.removed_stale.append(name)
            except OSError:
                pass

    return result
