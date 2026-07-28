"""Repair Container-visible Claude MCP state from the runtime snapshot."""

from __future__ import annotations

import json
import os
import stat
from dataclasses import dataclass
from typing import Any

from . import activation, trusted
from .render import is_managed_or_legacy, rendered_name


IDENTITY_PATH = "/etc/boxa/identity.json"
STATE_VERSION = 1
MAX_CONVERGE_ATTEMPTS = 3


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


def _load_state() -> tuple[dict[str, Any], str]:
    path = state_path()
    try:
        with open(path, encoding="utf-8") as fh:
            existing = fh.read()
        data = json.loads(existing)
    except FileNotFoundError:
        return _empty_state(), ""
    except (OSError, UnicodeError, ValueError):
        return _empty_state(), ""
    if (
        not isinstance(data, dict)
        or data.get("version") != STATE_VERSION
        or not isinstance(data.get("projects"), dict)
        or not isinstance(data.get("seeded"), dict)
    ):
        return _empty_state(), existing
    return data, existing


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


def _snapshot_records(snapshot: dict[str, Any], project: str) -> dict[str, Any]:
    projects = snapshot["projects"]
    records = projects.get(project)
    if isinstance(records, dict):
        return records
    for key, candidate in projects.items():
        if os.path.realpath(key) == project:
            return candidate
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
        with open(path, "rb") as fh:
            return fh.read()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise activation.ActivationError(
            f"cannot read rendered file {path}: {exc}"
        ) from exc


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
    project: str,
    desired: set[str],
) -> tuple[str, str] | None:
    if not desired:
        return None
    git_paths = activation._claude_git_paths(project)
    if git_paths is None:
        return None
    relative, exclude_path, _path = git_paths
    if not activation._codex_is_tracked(project, relative):
        return exclude_path, relative
    return None


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


def converge(
    project: str | None = None,
    *,
    snapshot_path: str | None = None,
) -> list[ConvergeResult]:
    resolved = _resolve_project(project)
    if resolved is None:
        return _skipped("no Container Project could be determined")
    if not os.path.isdir(resolved):
        return _skipped("Project directory does not exist", resolved)

    for _attempt in range(MAX_CONVERGE_ATTEMPTS):
        try:
            snapshot_raw, snapshot = _read_runtime_snapshot(snapshot_path)
            definitions = _desired_definitions(snapshot, resolved)
        except (trusted.TrustedAuthorizationError, OSError) as exc:
            return _skipped(str(exc), resolved)

        try:
            state, state_existing = _load_state()
            desired = set(definitions)
            previously_owned = _state_names(state, "projects", resolved)
            previously_seeded = _state_names(state, "seeded", resolved)
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
            git_paths = (
                activation._claude_git_paths(resolved)
                if mcp_changed else None
            )
            mcp_tracked = (
                git_paths is not None
                and activation._codex_is_tracked(resolved, git_paths[0])
            )
            if (
                mcp_changed
                and mcp_tracked
                and tracked_mcp_json.get(resolved) is not True
            ):
                return _skipped(
                    "tracked Claude MCP config "
                    f"{activation.claude_config_path(resolved)} requires "
                    "durable consent; authorize it with "
                    "boxa mcp activate ... --allow-tracked-mcp-json",
                    resolved,
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
            state_changed = state_rendered != state_existing
            changed = mcp_changed or approval_changed or state_changed
            exclude_plan = (
                _exclude_after_change_plan(resolved, desired)
                if changed else None
            )

            current_snapshot_raw = _read_snapshot_bytes(snapshot_path)
            if current_snapshot_raw != snapshot_raw:
                continue

            mcp_path = activation.claude_config_path(resolved)
            settings_path = activation.claude_settings_path(resolved)
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

            written_files: list[
                tuple[activation._FileSnapshot, bytes | None]
            ] = []

            if mcp_changed:
                preimage = activation._snapshot_file(mcp_path)
                activation._atomic_text(mcp_path, rendered)
                postimage = _read_bytes(mcp_path)
                if postimage != (
                    preimage.data if preimage.existed else None
                ):
                    written_files.append((preimage, postimage))
            if settings_plan is not None:
                (
                    settings_path,
                    settings_existing,
                    settings_rendered,
                ) = settings_plan
                if settings_rendered != settings_existing:
                    preimage = activation._snapshot_file(settings_path)
                    activation._atomic_text(
                        settings_path, settings_rendered
                    )
                    postimage = _read_bytes(settings_path)
                    if postimage != (
                        preimage.data if preimage.existed else None
                    ):
                        written_files.append((preimage, postimage))
            if state_changed:
                convergence_state_path = state_path()
                preimage = activation._snapshot_file(
                    convergence_state_path
                )
                activation._atomic_text(
                    convergence_state_path, state_rendered
                )
                os.chmod(
                    convergence_state_path,
                    stat.S_IRUSR | stat.S_IWUSR,
                )
                postimage = _read_bytes(convergence_state_path)
                if postimage != (
                    preimage.data if preimage.existed else None
                ):
                    written_files.append((preimage, postimage))
            if exclude_plan is not None:
                exclude_path, relative = exclude_plan
                preimage = activation._snapshot_file(exclude_path)
                activation._ensure_local_exclude(exclude_path, relative)
                postimage = _read_bytes(exclude_path)
                if postimage != (
                    preimage.data if preimage.existed else None
                ):
                    written_files.append((preimage, postimage))

            if _read_snapshot_bytes(snapshot_path) != snapshot_raw:
                rollback_errors: list[str] = []
                concurrent_paths: list[str] = []
                for preimage, postimage in reversed(written_files):
                    if _read_bytes(preimage.path) != postimage:
                        concurrent_paths.append(preimage.path)
                        continue
                    try:
                        activation._restore_file(preimage)
                    except OSError as exc:
                        rollback_errors.append(
                            f"{preimage.path}: {exc}"
                        )
                if rollback_errors:
                    return _skipped(
                        "MCP runtime snapshot changed after convergence "
                        "writes and rollback was incomplete: "
                        + "; ".join(rollback_errors),
                        resolved,
                    )
                if concurrent_paths:
                    return _skipped(
                        "concurrent write to the rendered file was detected "
                        "after convergence writes for "
                        + ", ".join(reversed(concurrent_paths))
                        + "; the next convergence will repair it",
                        resolved,
                    )
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

    return _skipped(
        "MCP runtime snapshot kept changing during convergence; "
        "the next convergence will retry",
        resolved,
    )
