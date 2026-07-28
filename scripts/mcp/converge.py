"""Repair Container-visible Claude MCP state from the runtime snapshot."""

from __future__ import annotations

import fcntl
import json
import os
import stat
from dataclasses import dataclass
from typing import Any

from . import activation, casfile, trusted
from .catalog import MUTATION_MARKER_NAME
from .render import is_managed_or_legacy, rendered_name


IDENTITY_PATH = "/etc/boxa/identity.json"
STATE_VERSION = 1
MAX_CONVERGE_ATTEMPTS = 3


# A rendered file changed between planning and the commit write. Raised by the
# shared compare-and-swap primitive, so host renders and convergence report the
# very same condition.
_ConcurrentRender = casfile.ConcurrentModification


class _SnapshotChanged(Exception):
    """The runtime snapshot was republished during the commit."""


class _HostMutationInProgress(Exception):
    """The host holds its mutation window; its publication is still pending."""


@dataclass
class ConvergeResult:
    status: str
    reason: str | None
    project: str | None
    added: list[str]
    removed: list[str]
    repaired: list[str]
    seeded: list[str]
    approval_changed: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "reason": self.reason,
            "project": self.project,
            "added": self.added,
            "removed": self.removed,
            "repaired": self.repaired,
            "seeded": self.seeded,
            "approvalChanged": self.approval_changed,
        }


def state_path() -> str:
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = xdg if xdg else os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "boxa", "mcp-converge-state.json")


def _empty_state() -> dict[str, Any]:
    return {"version": STATE_VERSION, "projects": {}, "seeded": {}}


def _load_state() -> tuple[dict[str, Any], bytes | None]:
    """Convergence state plus its exact pre-image (``None`` = no file yet).

    The pre-image stays bytes-or-``None`` so the commit's compare-and-swap can
    tell "state file absent" from "state file emptied by someone else".
    """
    path = state_path()
    try:
        raw = casfile.read_bytes(path)
    except casfile.WriteError:
        # Unreadable: no usable pre-image, so any commit swap must refuse.
        return _empty_state(), b""
    if raw is None:
        return _empty_state(), None
    try:
        existing = raw.decode("utf-8")
        data = json.loads(existing)
    except (UnicodeError, ValueError):
        return _empty_state(), raw
    if (
        not isinstance(data, dict)
        or data.get("version") != STATE_VERSION
        or not isinstance(data.get("projects"), dict)
        or not isinstance(data.get("seeded"), dict)
    ):
        return _empty_state(), raw
    return data, raw


def _project_from_identity() -> str | None:
    try:
        with open(IDENTITY_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, UnicodeError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    project = data.get("projectKey")
    return project if isinstance(project, str) and project else None


def _resolve_project(project: str | None) -> str | None:
    candidate = project or os.environ.get("BOXA_PROJECT_HOST_PATH") or None
    if candidate is None:
        candidate = _project_from_identity()
    if candidate is None:
        return None
    return activation.canonical_project(candidate)


def _snapshot_project_value(
    snapshot: dict[str, Any],
    field: str,
    project: str,
) -> Any:
    projects = snapshot.get(field, {})
    value = projects.get(project)
    if value is not None:
        return value
    for key, candidate in projects.items():
        if os.path.realpath(key) == project:
            return candidate
    return None


def _snapshot_records(snapshot: dict[str, Any], project: str) -> dict[str, Any]:
    records = _snapshot_project_value(snapshot, "projects", project)
    if isinstance(records, dict):
        return records
    return {}


def _desired_definitions(
    snapshot: dict[str, Any],
    project: str,
) -> dict[str, dict[str, Any]]:
    definitions: dict[str, dict[str, Any]] = {}
    for entry_id, record in _snapshot_records(snapshot, project).items():
        if record.get("enabled", True) is False or "claude" not in record["consumers"]:
            continue
        entry = snapshot["entries"].get(entry_id)
        if not isinstance(entry, dict):
            raise trusted.TrustedAuthorizationError(
                f"MCP runtime snapshot activation {entry_id!r} has no catalog entry"
            )
        name = rendered_name(entry["name"])
        definitions[name] = activation.claude_server_definition(
            entry_id, project, entry
        )
    return definitions


def _read_bytes(path: str) -> bytes | None:
    try:
        return casfile.read_bytes(path)
    except casfile.WriteError as exc:
        raise activation.ActivationError(
            f"cannot read rendered file {path}: {exc}"
        ) from exc


def _swap(path: str, expected: bytes | None, text: str) -> None:
    """Compare-and-swap a rendered file, journalled into the open batch.

    The write goes through ``activation._atomic_text`` so convergence and the
    host render share one writer (and one injection point in tests).
    """
    casfile.swap(
        path,
        expected,
        text,
        writer=lambda target, payload: activation._atomic_text(target, payload),
    )


def _read_snapshot_bytes(path: str | None) -> bytes:
    resolved_path = path or trusted.runtime_snapshot_path()
    try:
        info = os.lstat(resolved_path)
        if not stat.S_ISREG(info.st_mode):
            raise trusted.TrustedAuthorizationError(
                f"MCP runtime snapshot is not a regular file: {resolved_path}"
            )
        with open(resolved_path, "rb") as fh:
            return fh.read()
    except trusted.TrustedAuthorizationError:
        raise
    except OSError as exc:
        raise trusted.TrustedAuthorizationError(
            f"cannot read host-owned MCP runtime snapshot: {exc}"
        ) from exc


def _has_managed_render(project: str) -> bool:
    """True when the Project's Claude config still holds a boxa render."""
    try:
        _raw, _existing, data = _read_mcp_document(project)
    except activation.ActivationError:
        # An unreadable render is drift the next convergence must repair, so
        # treat it as evidence rather than as a pristine installation.
        return True
    block = data.get("mcpServers")
    if not isinstance(block, dict):
        return False
    return any(
        is_managed_or_legacy(name)
        and isinstance(definition, dict)
        and definition.get("command") == "boxa-mcp-run"
        for name, definition in block.items()
    )


def _snapshot_never_published(path: str | None, project: str) -> bool:
    """True when no runtime state has ever reached this Container.

    A pristine installation mounts the runtime directory but the host has not
    published a snapshot yet, so there is genuinely nothing to converge — that
    must stay silent instead of being reported as an operational skip on every
    interactive shell. The distinction from "expected but gone" is evidence of
    an earlier publication: a snapshot file that exists at all (empty, corrupt,
    or unreadable), recorded convergence state for this Project, or a
    boxa-managed render left behind in the Project's Claude config. Any of
    those keeps the missing snapshot an operational skip.
    """
    resolved = path or trusted.runtime_snapshot_path()
    try:
        os.lstat(resolved)
    except FileNotFoundError:
        pass
    except OSError:
        return False
    else:
        return False
    state, _existing = _load_state()
    if _state_names(state, "projects", project) or _state_names(
        state, "seeded", project
    ):
        return False
    return not _has_managed_render(project)


def mutation_marker_path(snapshot_path: str | None = None) -> str:
    """The host mutation window as published beside the runtime snapshot."""
    resolved = snapshot_path or trusted.runtime_snapshot_path()
    return os.path.join(os.path.dirname(resolved), MUTATION_MARKER_NAME)


def _mutation_in_progress(snapshot_path: str | None) -> bool:
    """Observe the host mutation lock the Container may never take.

    The Container must not reach the gated host store, so the host publishes
    its mutation window as a shared-lock probe on a read-only file inside the
    already-published runtime directory. A host mutation that has written a
    Project file but not yet republished the snapshot is therefore visible
    here, which is what closes the post-check publication race. Probing is
    fail-open: an environment without working advisory locks degrades to the
    snapshot comparison alone rather than refusing to converge.
    """
    try:
        fd = os.open(mutation_marker_path(snapshot_path), os.O_RDONLY)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    except OSError:
        return False
    else:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        return False
    finally:
        os.close(fd)


def _read_runtime_snapshot(
    path: str | None,
) -> tuple[bytes, dict[str, Any]]:
    raw = _read_snapshot_bytes(path)
    return raw, trusted.parse_runtime_snapshot(raw)


def _read_mcp_document(
    project: str,
) -> tuple[bytes | None, str, dict[str, Any]]:
    path = activation.claude_config_path(project)
    raw = _read_bytes(path)
    if raw is None:
        return None, "", {}
    try:
        existing = raw.decode("utf-8")
        data = json.loads(existing)
    except (UnicodeError, ValueError) as exc:
        raise activation.ActivationError(
            f"cannot read Claude MCP config {path}: {exc}"
        ) from exc
    if not isinstance(data, dict):
        raise activation.ActivationError(
            f"Claude MCP config is not an object: {path}"
        )
    block = data.get("mcpServers")
    if block is not None and not isinstance(block, dict):
        raise activation.ActivationError(
            f"Claude MCP config mcpServers is not an object: {path}"
        )
    return raw, existing, data


def _state_names(state: dict[str, Any], field: str, project: str) -> set[str]:
    records = state.get(field)
    names = records.get(project, []) if isinstance(records, dict) else []
    if not isinstance(names, list):
        return set()
    return {name for name in names if isinstance(name, str)}


def _settings_status(
    project: str,
) -> tuple[bytes | None, bool, str, set[str]]:
    path = activation.claude_settings_path(project)
    raw = _read_bytes(path)
    if raw is None:
        return None, False, "", set()
    try:
        existing = raw.decode("utf-8")
        data = json.loads(existing)
    except (UnicodeError, ValueError):
        return raw, True, raw.decode("utf-8", errors="replace"), set()
    if not isinstance(data, dict):
        return raw, True, existing, set()
    names = data.get("disabledMcpjsonServers", [])
    if not isinstance(names, list):
        return raw, True, existing, set()
    return (
        raw,
        True,
        existing,
        {name for name in names if isinstance(name, str)},
    )


def _set_project_names(
    state: dict[str, Any],
    field: str,
    project: str,
    names: set[str],
) -> None:
    records = state[field]
    if names:
        records[project] = sorted(names)
    else:
        records.pop(project, None)


def _exclude_after_change_plan(
    git_paths: tuple[str, str, str] | None,
    tracked: bool,
) -> tuple[str, str] | None:
    if git_paths is None or tracked:
        return None
    relative, exclude_path, _path = git_paths
    return exclude_path, relative


def _abort_reason(exc: Exception) -> str:
    if isinstance(exc, _SnapshotChanged):
        return "MCP runtime snapshot changed after convergence writes"
    if isinstance(exc, _HostMutationInProgress):
        return "a host MCP mutation was in progress during convergence writes"
    if isinstance(exc, _ConcurrentRender):
        return "concurrent write to the rendered file was detected"
    return f"convergence write failed: {exc}"


def _skipped(reason: str, project: str | None = None) -> list[ConvergeResult]:
    return [
        ConvergeResult(
            status="skipped",
            reason=reason,
            project=project,
            added=[],
            removed=[],
            repaired=[],
            seeded=[],
            approval_changed=False,
        )
    ]


def _not_applicable(
    reason: str,
    project: str | None = None,
) -> list[ConvergeResult]:
    return [
        ConvergeResult(
            status="not-applicable",
            reason=reason,
            project=project,
            added=[],
            removed=[],
            repaired=[],
            seeded=[],
            approval_changed=False,
        )
    ]


def converge(
    project: str | None = None,
    *,
    snapshot_path: str | None = None,
) -> list[ConvergeResult]:
    resolved = _resolve_project(project)
    if resolved is None:
        return _not_applicable("no Container Project could be determined")
    if not os.path.isdir(resolved):
        return _not_applicable("Project directory does not exist", resolved)

    render_concurrent_paths: set[str] = set()
    host_mutation_pending = False
    for _attempt in range(MAX_CONVERGE_ATTEMPTS):
        # Planning from a snapshot the host is about to replace only wastes an
        # attempt, so defer before reading it as well as after writing.
        if _mutation_in_progress(snapshot_path):
            host_mutation_pending = True
            continue
        try:
            snapshot_raw, snapshot = _read_runtime_snapshot(snapshot_path)
            definitions = _desired_definitions(snapshot, resolved)
        except (trusted.TrustedAuthorizationError, OSError) as exc:
            if _snapshot_never_published(snapshot_path, resolved):
                return _not_applicable(
                    "no MCP runtime snapshot has been published for this "
                    "Container",
                    resolved,
                )
            return _skipped(str(exc), resolved)

        try:
            state, state_raw = _load_state()
            desired = set(definitions)
            previously_owned = _state_names(state, "projects", resolved)
            snapshot_seeded = _snapshot_project_value(
                snapshot, "seededApprovals", resolved
            )
            previously_seeded = (
                _state_names(state, "seeded", resolved)
                | set(snapshot_seeded or [])
            )
            mcp_preimage, existing, data = _read_mcp_document(resolved)
            block = data.get("mcpServers")
            if block is None:
                block = {}

            added: list[str] = []
            removed: list[str] = []
            repaired: list[str] = []
            for name, definition in definitions.items():
                if name not in block:
                    block[name] = definition
                    added.append(name)
                elif block[name] != definition:
                    block[name] = definition
                    repaired.append(name)

            for name, definition in list(block.items()):
                boxa_command = (
                    isinstance(definition, dict)
                    and definition.get("command") == "boxa-mcp-run"
                )
                owned = name in previously_owned or (
                    is_managed_or_legacy(name) and boxa_command
                )
                if owned and name not in desired:
                    del block[name]
                    removed.append(name)

            rendered = activation._render_mcp_json(
                existing,
                definitions,
                set(removed),
            ) or activation._json_document({})
            mcp_changed = bool(added or removed or repaired)
            tracked_mcp_json = snapshot.get("trackedMcpJson", {})
            mcp_path = activation.claude_config_path(resolved)
            git_paths = (
                activation._claude_git_paths(resolved, path=mcp_path)
                if mcp_changed or desired else None
            )
            mcp_tracked = (
                git_paths is not None
                and activation._codex_is_tracked(resolved, git_paths[0])
            )
            (
                settings_preimage,
                settings_exists,
                settings_existing,
                disabled_names,
            ) = _settings_status(resolved)
            disabled = disabled_names & desired
            planning_state = json.loads(json.dumps(state))
            # A missing approval document is repairable drift. Once it exists,
            # the one-time marker protects removals from enabled and explicit
            # rejections.
            protected_seeded = (
                previously_seeded if settings_exists else set()
            ) | disabled
            _set_project_names(
                planning_state, "seeded", resolved, protected_seeded
            )
            settings_plan = activation._claude_settings_plan(
                resolved,
                sorted(desired),
                planning_state,
                retire=previously_seeded - desired,
                existing_document=(settings_exists, settings_existing),
            )
            approval_changed = settings_plan is not None
            settings_path = activation.claude_settings_path(resolved)
            settings_git_paths = (
                activation._claude_git_paths(
                    resolved, path=settings_path
                )
                if approval_changed else None
            )
            settings_tracked = (
                settings_git_paths is not None
                and activation._codex_is_tracked(
                    resolved, settings_git_paths[0]
                )
            )
            tracked_refusals = []
            if mcp_changed and mcp_tracked:
                tracked_refusals.append(mcp_path)
            if approval_changed and settings_tracked:
                tracked_refusals.append(settings_path)
            if (
                tracked_refusals
                and tracked_mcp_json.get(resolved) is not True
            ):
                return _skipped(
                    "tracked Claude Project files "
                    + ", ".join(tracked_refusals)
                    + " require durable consent; authorize them with "
                    "boxa mcp activate ... --allow-tracked-mcp-json",
                    resolved,
                )
            seeded: list[str] = []
            if settings_plan is not None:
                (
                    settings_path,
                    settings_existing,
                    settings_rendered,
                ) = settings_plan
                try:
                    before = (
                        json.loads(settings_existing)
                        if settings_existing else {}
                    )
                    after = json.loads(settings_rendered)
                    before_enabled = set(
                        before.get("enabledMcpjsonServers", [])
                    )
                    after_enabled = set(
                        after.get("enabledMcpjsonServers", [])
                    )
                    seeded = sorted(
                        (after_enabled - before_enabled) & desired
                    )
                except (AttributeError, TypeError, ValueError):
                    seeded = []

            _set_project_names(state, "projects", resolved, desired)
            _set_project_names(state, "seeded", resolved, desired)
            state_rendered = activation._json_document(state)
            state_changed = state_rendered.encode("utf-8") != state_raw
            changed = mcp_changed or approval_changed or state_changed
            exclude_plans = [
                plan
                for plan in (
                    (
                        _exclude_after_change_plan(
                            git_paths, mcp_tracked
                        )
                        if changed and desired else None
                    ),
                    _exclude_after_change_plan(
                        settings_git_paths, settings_tracked
                    ),
                )
                if plan is not None
            ]

            current_snapshot_raw = _read_snapshot_bytes(snapshot_path)
            if current_snapshot_raw != snapshot_raw:
                continue

            concurrent_paths = []
            if _read_bytes(mcp_path) != mcp_preimage:
                concurrent_paths.append(mcp_path)
            if _read_bytes(settings_path) != settings_preimage:
                concurrent_paths.append(settings_path)
            if concurrent_paths:
                return _skipped(
                    "concurrent write to the rendered file was detected for "
                    + ", ".join(concurrent_paths)
                    + "; the next convergence will repair it",
                    resolved,
                )

            # Every write below goes through the shared compare-and-swap
            # primitive and is journalled as one set: any later failure,
            # concurrent edit, snapshot republication or host mutation window
            # takes back exactly the bytes Boxa wrote, so the Project is never
            # left half-converged — and never loses a foreign edit.
            with casfile.transaction() as txn:
                try:
                    if mcp_changed:
                        _swap(mcp_path, mcp_preimage, rendered)
                    if settings_plan is not None:
                        (
                            settings_path,
                            settings_existing,
                            settings_rendered,
                        ) = settings_plan
                        if settings_rendered != (settings_existing or ""):
                            _swap(
                                settings_path,
                                settings_preimage,
                                settings_rendered,
                            )
                    if state_changed:
                        convergence_state_path = state_path()
                        _swap(
                            convergence_state_path,
                            state_raw,
                            state_rendered,
                        )
                        os.chmod(
                            convergence_state_path,
                            stat.S_IRUSR | stat.S_IWUSR,
                        )
                    for exclude_plan in exclude_plans:
                        exclude_path, relative = exclude_plan
                        activation._ensure_local_exclude(exclude_path, relative)

                    # A host mutation that already wrote the Project files but has
                    # not yet republished the snapshot is invisible to the snapshot
                    # comparison alone, so observe its published window first.
                    if _mutation_in_progress(snapshot_path):
                        raise _HostMutationInProgress()
                    if _read_snapshot_bytes(snapshot_path) != snapshot_raw:
                        raise _SnapshotChanged()
                except (
                    _ConcurrentRender,
                    _SnapshotChanged,
                    _HostMutationInProgress,
                    activation.ActivationError,
                    trusted.TrustedAuthorizationError,
                    OSError,
                ) as exc:
                    if isinstance(exc, _ConcurrentRender):
                        render_concurrent_paths.add(exc.path)
                    rollback_errors, rollback_concurrent = txn.rollback()
                    if rollback_errors:
                        return _skipped(
                            _abort_reason(exc)
                            + " and rollback was incomplete: "
                            + "; ".join(rollback_errors),
                            resolved,
                        )
                    if rollback_concurrent:
                        return _skipped(
                            "concurrent write to the rendered file was detected "
                            "after convergence writes for "
                            + ", ".join(reversed(rollback_concurrent))
                            + "; the next convergence will repair it",
                            resolved,
                        )
                    if isinstance(exc, _HostMutationInProgress):
                        host_mutation_pending = True
                    elif not isinstance(
                        exc, (_ConcurrentRender, _SnapshotChanged)
                    ):
                        return _skipped(str(exc), resolved)
                    continue
        except (
            activation.ActivationError,
            trusted.TrustedAuthorizationError,
        ) as exc:
            return _skipped(str(exc), resolved)

        return [
            ConvergeResult(
                status="converged" if changed else "in-sync",
                reason=None,
                project=resolved,
                added=sorted(added),
                removed=sorted(removed),
                repaired=sorted(repaired),
                seeded=seeded,
                approval_changed=approval_changed,
            )
        ]

    if render_concurrent_paths:
        return _skipped(
            "concurrent write to the rendered file was detected for "
            + ", ".join(sorted(render_concurrent_paths))
            + "; the next convergence will repair it",
            resolved,
        )
    if host_mutation_pending:
        return _skipped(
            "a host MCP mutation is in progress; the next convergence will "
            "apply its published result",
            resolved,
        )
    return _skipped(
        "MCP runtime snapshot kept changing during convergence; "
        "the next convergence will retry",
        resolved,
    )
