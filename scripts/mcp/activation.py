"""Project-scoped MCP catalog activations (ADR 0021, issue 02)."""

from __future__ import annotations

import json
import os
import stat
import subprocess
from dataclasses import dataclass
from typing import Any, Optional

from . import casfile
from .catalog import (
    CatalogError,
    degradation_status,
    load_catalog,
    mutation_lock,
    resolve_entry,
    save_catalog,
    updated_catalog_entry,
)
from .profile import config_root
from .projects import VolumeProbe, enumerate_project_targets
from .readiness import (
    ProjectProbe,
    ReadinessError,
    ReadinessReport,
    readiness,
    readiness_for_entry,
)
from .secrets import global_secrets_path, load_secrets, save_secrets

ACTIVATION_VERSION = 1
RUNTIME_VERSION = 1
CONSUMERS = {"claude", "codex"}
_FILE_MODE = 0o600
_RUNTIME_MODE = 0o644


class ActivationError(RuntimeError):
    pass


def _git_env() -> dict[str, str]:
    # Git failure classification relies on message text; translated diagnostics
    # would misclassify a valid non-Git Project as an inspection failure.
    env = os.environ.copy()
    env.update({"LC_ALL": "C", "LC_MESSAGES": "C", "LANGUAGE": ""})
    return env


def git_metadata_path(project: str) -> Optional[str]:
    """Return the nearest ``.git`` entry at or above the Project, if any.

    A linked worktree or a submodule keeps its real repository elsewhere and
    only leaves a ``.git`` *file* pointing at that gitdir. When the gitdir sits
    outside the Project bind mount, Git in the Container reports the very same
    "not a git repository" as a directory with no Git metadata at all — but the
    former is an inspection failure (the tracked state is unknown) while only
    the latter is a genuinely non-Git Project. The walk stops at the mount
    boundary because anything above it is not part of the Project mount.
    """
    current = project
    while True:
        try:
            candidate = os.path.join(current, ".git")
            if os.path.lexists(candidate):
                return candidate
            at_boundary = os.path.ismount(current)
        except OSError:
            return None
        parent = os.path.dirname(current)
        if at_boundary or not parent or parent == current:
            return None
        current = parent


def _root() -> str:
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = xdg if xdg else os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "boxa", "mcp")


def activation_path() -> str:
    return os.path.join(_root(), "activations.json")


def runtime_path() -> str:
    # Dedicated secret-free directory bind-mounted read-only into Containers.
    # Mounting the DIRECTORY (not the file) keeps atomic os.replace updates live.
    return os.path.join(_root(), "runtime", "catalog-runtime.json")


def canonical_project(path: str) -> str:
    if not path:
        raise ActivationError("Project path must be non-empty")
    return os.path.realpath(os.path.abspath(os.path.expanduser(path))).rstrip("/") or "/"


def empty_activations() -> dict[str, Any]:
    return {
        "version": ACTIVATION_VERSION,
        "projects": {},
        "everywhere": {},
        "acknowledgements": {},
    }


def load_activations(path: Optional[str] = None) -> dict[str, Any]:
    path = path or activation_path()
    if not os.path.exists(path):
        return empty_activations()
    if not os.path.isfile(path) or stat.S_ISLNK(os.lstat(path).st_mode):
        raise ActivationError(f"activation path is not a regular host-owned file: {path}")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        raise ActivationError(f"cannot read activations {path}: {exc}") from exc
    if not isinstance(data, dict) or data.get("version") != ACTIVATION_VERSION:
        raise ActivationError("malformed or unsupported MCP activation store")
    projects = data.get("projects")
    if not isinstance(projects, dict):
        raise ActivationError("malformed MCP activation store (projects)")
    for project, records in projects.items():
        if canonical_project(project) != project or not isinstance(records, dict):
            raise ActivationError("malformed MCP activation Project record")
        for entry_id, record in records.items():
            if not isinstance(record, dict) or record.get("catalogId") != entry_id:
                raise ActivationError("malformed MCP activation record")
            if record.get("optedOut") is True:
                if set(record) != {"catalogId", "optedOut"}:
                    raise ActivationError("malformed MCP activation opt-out")
                continue
            consumers = record.get("consumers")
            if not isinstance(consumers, list) or not consumers or any(c not in CONSUMERS for c in consumers):
                raise ActivationError("malformed MCP activation consumers")
            if "enabled" in record and not isinstance(record["enabled"], bool):
                raise ActivationError("malformed MCP activation enabled flag")
            if "pendingReason" in record and not isinstance(record["pendingReason"], str):
                raise ActivationError("malformed MCP activation pending reason")
            if "pendingReason" in record and record.get("enabled", True) is not False:
                raise ActivationError("malformed effective MCP activation pending reason")
    everywhere = data.get("everywhere", {})
    if not isinstance(everywhere, dict):
        raise ActivationError("malformed MCP everywhere activation store")
    for entry_id, record in everywhere.items():
        if not isinstance(record, dict) or record.get("catalogId") != entry_id:
            raise ActivationError("malformed MCP everywhere activation record")
        consumers = record.get("consumers")
        if not isinstance(consumers, list) or not consumers or any(c not in CONSUMERS for c in consumers):
            raise ActivationError("malformed MCP everywhere activation consumers")
        if "degradedSecretIsolationAcknowledged" in record and record[
            "degradedSecretIsolationAcknowledged"
        ] is not True:
            raise ActivationError("malformed MCP everywhere activation acknowledgement")
    acknowledgements = data.get("acknowledgements", {})
    if not isinstance(acknowledgements, dict):
        raise ActivationError("malformed MCP activation acknowledgements")
    for project, records in acknowledgements.items():
        if canonical_project(project) != project or not isinstance(records, dict):
            raise ActivationError("malformed MCP activation acknowledgement Project")
        if any(not isinstance(entry_id, str) or value is not True for entry_id, value in records.items()):
            raise ActivationError("malformed MCP activation acknowledgement")
    data.setdefault("acknowledgements", acknowledgements)
    data.setdefault("everywhere", everywhere)
    # ADR 0028 retired durable consent for shared render writes. Tolerate the
    # old field while upgrading, but never publish or persist it again.
    data.pop("trackedMcpJson", None)
    return data


def _atomic_json(path: str, data: dict[str, Any], mode: int) -> None:
    """Write a Boxa-private JSON store, journalled for exact compensation."""
    with casfile.record(path):
        casfile.atomic_json(path, data, mode)


def _compensate(
    txn: casfile.Transaction, label: str, exc: BaseException
) -> None:
    """Take back a failed batch and report why it failed. Always raises.

    Rollback restores only paths whose bytes are still Boxa's own, so a foreign
    edit made after Boxa's write is reported rather than erased.
    """
    errors, concurrent = txn.rollback()
    problems = list(errors)
    if concurrent:
        problems.append(
            "concurrent writes left in place for " + ", ".join(concurrent)
        )
    if problems:
        raise ActivationError(
            f"{label} failed and rollback was incomplete: "
            + "; ".join(problems)
        ) from exc
    # The refusal may arrive translated into a writer's public error type, so
    # follow the cause chain rather than matching the type directly.
    conflict = casfile.concurrent_conflict(exc)
    if conflict is not None:
        raise ActivationError(
            f"{label} refused: {conflict.path} changed on disk; "
            "nothing was written — re-run the command"
        ) from exc
    raise exc


def codex_config_path(project: str) -> str:
    return os.path.join(project, ".codex", "config.toml")


def claude_config_path(project: str) -> str:
    return os.path.join(project, ".mcp.json")


def claude_settings_path(project: str) -> str:
    return os.path.join(project, ".claude", "settings.local.json")


def _codex_is_tracked(project: str, relative: str) -> bool:
    try:
        proc = subprocess.run(
            [
                "git", "-C", project, "ls-files", "--error-unmatch", "--",
                f":(top,literal){relative}",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            env=_git_env(),
        )
    except OSError as exc:
        raise ActivationError(
            f"cannot determine whether {relative} is tracked in {project}: {exc}"
        ) from exc
    if proc.returncode == 0:
        return True
    if proc.returncode == 1:
        return False
    detail = (proc.stderr or "").strip()
    raise ActivationError(
        f"cannot determine whether {relative} is tracked in {project}"
        + (f": {detail}" if detail else "")
    )


def _claude_git_paths(
    project: str,
    *,
    path: Optional[str] = None,
) -> Optional[tuple[str, str, str]]:
    """Resolve local Git paths, while keeping non-repository Projects valid."""
    path = path or claude_config_path(project)
    try:
        top_proc = subprocess.run(
            ["git", "-C", project, "rev-parse", "--show-toplevel"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
            env=_git_env(),
        )
    except OSError as exc:
        raise ActivationError(
            f"cannot determine whether {path} is inside a Git repository: {exc}"
        ) from exc
    if top_proc.returncode != 0:
        detail = (top_proc.stderr or top_proc.stdout).strip()
        non_repository = (
            "not a git repository" in detail.casefold()
            or "this operation must be run in a work tree" in detail.casefold()
        )
        if non_repository:
            metadata = git_metadata_path(project)
            if metadata is None:
                return None
            # Git metadata exists but Git refuses to use it (typically a linked
            # worktree or submodule whose gitdir is outside the Project mount).
            # The tracked state is unknown, so callers must skip rather than
            # treat the derived files as safely untracked.
            raise ActivationError(
                f"cannot determine whether {path} is inside a Git repository: "
                f"Git metadata {metadata} exists but Git cannot use it"
                + (f" ({detail})" if detail else "")
            )
        raise ActivationError(
            f"cannot determine whether {path} is inside a Git repository"
            + (f": {detail}" if detail else "")
        )
    top_output = top_proc.stdout.strip()
    if not top_output:
        raise ActivationError(
            f"cannot determine whether {path} is inside a Git repository: "
            "git rev-parse returned an empty repository path"
        )
    top = os.path.realpath(top_output)
    try:
        relative = os.path.relpath(path, top)
    except ValueError as exc:
        raise ActivationError(
            f"Claude MCP config is outside the Project Git repository: {path}"
        ) from exc
    if relative == ".." or relative.startswith(".." + os.sep):
        raise ActivationError(f"Claude MCP config is outside the Project Git repository: {path}")
    try:
        exclude_proc = subprocess.run(
            [
                "git", "-C", project, "rev-parse", "--path-format=absolute",
                "--git-path", "info/exclude",
            ],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
            env=_git_env(),
        )
    except OSError as exc:
        raise ActivationError(
            f"cannot resolve local Git exclude for Claude MCP config {path}: {exc}"
        ) from exc
    if exclude_proc.returncode != 0:
        detail = (exclude_proc.stderr or exclude_proc.stdout).strip()
        raise ActivationError(
            f"cannot resolve local Git exclude for Claude MCP config {path}"
            + (f": {detail}" if detail else "")
        )
    exclude_output = exclude_proc.stdout.strip()
    if not exclude_output:
        raise ActivationError(
            f"cannot resolve local Git exclude for Claude MCP config {path}: "
            "git rev-parse returned an empty exclude path"
        )
    return (
        relative.replace(os.sep, "/"),
        os.path.realpath(exclude_output),
        path,
    )


def _commit_activation_state(data: dict[str, Any]) -> None:
    """Atomically publish host-owned activation state and runtime snapshot."""
    with casfile.transaction() as txn:
        try:
            save_activation_store(data)
            refresh_runtime(data)
        except Exception as exc:
            _compensate(txn, "MCP activation mutation", exc)


def save_activations(data: dict[str, Any]) -> None:
    save_activation_store(data)
    refresh_runtime(data)


def save_activation_store(data: dict[str, Any]) -> None:
    """Persist authoritative activation state without publishing broker runtime."""
    _atomic_json(activation_path(), data, _FILE_MODE)


def runtime_payload(
    activations: dict[str, Any],
    catalog: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    """Build the normalized secret-free runtime snapshot payload."""
    catalog = catalog if catalog is not None else load_catalog()
    projects = {
        project: {
            entry_id: record
            for entry_id, record in records.items()
            if record.get("optedOut") is not True
        }
        for project, records in activations["projects"].items()
    }
    return {
        "version": RUNTIME_VERSION,
        "catalogVersion": catalog["version"],
        "entries": catalog["entries"],
        "projects": {project: records for project, records in projects.items() if records},
    }


def refresh_runtime(activations: Optional[dict[str, Any]] = None) -> None:
    """Publish the secret-free broker view; authoritative activation stays 0600."""
    activations = activations if activations is not None else load_activations()
    payload = runtime_payload(activations)
    path = runtime_path()
    runtime_dir = os.path.dirname(path)
    os.makedirs(runtime_dir, mode=0o755, exist_ok=True)
    os.chmod(runtime_dir, 0o755)
    _atomic_json(path, payload, _RUNTIME_MODE)


class DockerProbe:
    """Readiness/running probe, injectable for unit tests."""

    def find_running(self, project_key: str) -> Optional[str]:
        try:
            ps = subprocess.run(
                ["docker", "ps", "--filter", "name=^boxa-", "--format", "{{.Names}}"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False,
            )
        except OSError:
            return None
        for container in (ps.stdout or "").splitlines():
            inspect = subprocess.run(
                ["docker", "inspect", "-f", "{{range .Config.Env}}{{println .}}{{end}}", container],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False,
            )
            marker = f"BOXA_PROJECT_HOST_PATH={project_key}"
            if inspect.returncode == 0 and marker in (inspect.stdout or "").splitlines():
                return container
        return None

    def ready(self, container: str, entry: dict[str, Any]) -> bool:
        argv = entry["command"]["argv"]
        if entry.get("runtimeKind") != "direct":
            return False
        proc = subprocess.run(
            ["docker", "exec", container, "sh", "-c", "command -v -- \"$1\" >/dev/null", "sh", argv[0]],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
        return proc.returncode == 0


@dataclass
class ActivationResult:
    entry: dict[str, Any]
    project_key: str
    consumers: list[str]
    changed: bool
    pending: bool = False
    pending_reason: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "entry": self.entry,
            "projectKey": self.project_key,
            "consumers": self.consumers,
            "changed": self.changed,
            "pending": self.pending,
            "pendingReason": self.pending_reason,
        }


@dataclass
class PendingActivationAttempt:
    entry: dict[str, Any]
    ready: bool
    reason: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "entry": self.entry,
            "ready": self.ready,
            "reason": self.reason,
        }


@dataclass
class PendingReevaluationResult:
    project_key: str
    attempts: list[PendingActivationAttempt]
    changed: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "projectKey": self.project_key,
            "attempts": [attempt.to_dict() for attempt in self.attempts],
            "changed": self.changed,
        }


@dataclass
class EverywhereProjectOutcome:
    project_key: str
    outcome: str
    reason: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "projectKey": self.project_key,
            "outcome": self.outcome,
            "reason": self.reason,
        }


@dataclass
class EverywhereActivationResult:
    entry: dict[str, Any]
    consumers: list[str]
    marked: bool
    changed: bool
    projects: list[EverywhereProjectOutcome]

    def to_dict(self) -> dict[str, Any]:
        return {
            "entry": self.entry,
            "consumers": self.consumers,
            "everywhere": self.marked,
            "changed": self.changed,
            "projects": [project.to_dict() for project in self.projects],
        }


@dataclass
class CatalogUpdateResult:
    entry: dict[str, Any]
    runtime_affecting: bool
    affected: list[dict[str, Any]]

    def to_dict(self) -> dict[str, Any]:
        return {
            "entry": self.entry,
            "runtimeAffecting": self.runtime_affecting,
            "affected": self.affected,
        }


@dataclass
class CatalogRemovalResult:
    entry: dict[str, Any]
    affected: list[dict[str, Any]]

    def to_dict(self) -> dict[str, Any]:
        return {"removed": self.entry, "affected": self.affected}


def _validate_activation_request(entry: dict[str, Any], consumers: list[str]) -> None:
    if not consumers or any(c not in CONSUMERS for c in consumers):
        raise ActivationError(
            "activation requires an explicit supported consumer "
            "(--for claude, codex, or both)"
        )
    argv = entry.get("command", {}).get("argv", [])
    if (
        "codex" in consumers
        and argv
        and os.path.basename(argv[0]).lower() == "codex"
        and len(argv) > 1
        and argv[1] == "mcp-server"
    ):
        raise ActivationError(
            "codex mcp-server delegation can activate only for Claude; "
            "self-activation for Codex is not implicit"
        )


def activate(
    token: str, project: str, consumers: list[str], probe: Optional[object] = None,
    *, accept_degraded_secret_isolation: bool = False,
) -> ActivationResult:
    with mutation_lock():
        return _activate_locked(
            token,
            project,
            consumers,
            probe,
            accept_degraded_secret_isolation=accept_degraded_secret_isolation,
        )


def preflight_activate(
    token: str, project: str, consumers: list[str], probe: Optional[object] = None,
    *, accept_degraded_secret_isolation: bool = False,
) -> None:
    """Validate one activation without mutating the activation store."""
    with mutation_lock():
        _activation_preflight(
            token,
            project,
            consumers,
            probe,
            accept_degraded_secret_isolation=accept_degraded_secret_isolation,
        )


def _activate_locked(
    token: str, project: str, consumers: list[str], probe: Optional[object] = None,
    *, accept_degraded_secret_isolation: bool = False,
) -> ActivationResult:
    entry_id, entry, key, pending_reason = _activation_preflight(
        token,
        project,
        consumers,
        probe,
        accept_degraded_secret_isolation=accept_degraded_secret_isolation,
    )
    data = load_activations()
    degraded = degradation_status(entry)
    accepted = data.get("acknowledgements", {}).get(key, {}).get(entry_id) is True
    if degraded and not accepted:
        data.setdefault("acknowledgements", {}).setdefault(key, {})[entry_id] = True
    records = data["projects"].setdefault(key, {})
    record = {
        "catalogId": entry_id,
        "consumers": sorted(set(consumers)),
        "enabled": not bool(pending_reason),
    }
    if pending_reason:
        record["pendingReason"] = pending_reason
    previous = records.get(entry_id)
    changed = previous != record
    records[entry_id] = record
    _commit_activation_state(data)
    return ActivationResult(
        dict(entry),
        key,
        record["consumers"],
        changed,
        pending=bool(pending_reason),
        pending_reason=pending_reason,
    )


def _activation_preflight(
    token: str, project: str, consumers: list[str], probe: Optional[object] = None,
    *, accept_degraded_secret_isolation: bool = False,
) -> tuple[str, dict[str, Any], str, str]:
    key = canonical_project(project)
    try:
        catalog = load_catalog()
        entry_id, entry = resolve_entry(catalog, token)
    except CatalogError as exc:
        raise ActivationError(str(exc)) from exc
    _validate_activation_request(entry, consumers)
    pending_reason = ""
    # Keep the issue-02 boolean probe seam until legacy profile migration in
    # issue 08. New/default callers receive the detailed deterministic report.
    if entry.get("type") == "http":
        is_ready = True
        missing: list[str] = []
    elif isinstance(probe, DockerProbe) and type(probe).ready is not DockerProbe.ready:
        container = probe.find_running(key)
        if not container:
            is_ready = False
            pending_reason = (
                f"target Boxa for {key} is not running; readiness never starts it implicitly"
            )
        else:
            is_ready = probe.ready(container, entry)
        missing = []
    else:
        readiness_probe = probe if isinstance(probe, ProjectProbe) else ProjectProbe()
        try:
            report = readiness(entry_id, key, readiness_probe)
        except ReadinessError as exc:
            stopped_reason = (
                f"target Boxa for {key} is not running; "
                "readiness never starts it implicitly"
            )
            if str(exc) != stopped_reason:
                raise ActivationError(str(exc)) from exc
            is_ready = False
            missing = []
            pending_reason = stopped_reason
        else:
            is_ready = report.ready
            missing = [
                f"{check.label} ({check.detail})" if check.detail else check.label
                for check in report.missing
            ]
    if not is_ready and not pending_reason:
        suffix = f"; missing: {', '.join(missing)}" if missing else ""
        raise ActivationError(
            f"catalog entry {entry['name']!r} is not ready for Project {key}{suffix}"
        )
    data = load_activations()
    degraded = degradation_status(entry)
    accepted = data.get("acknowledgements", {}).get(key, {}).get(entry_id) is True
    if degraded and not accepted and not accept_degraded_secret_isolation:
        raise ActivationError(
            "degraded-secret-isolation: node owns the Docker daemon and can inspect "
            "this server's container environment; acknowledge interactively or use "
            "--accept-degraded-secret-isolation for non-interactive activation"
        )
    return entry_id, entry, key, pending_reason


def activate_everywhere(
    token: str,
    consumers: list[str],
    claude_provider: object,
    volume_probe: Optional[VolumeProbe] = None,
    probe: Optional[object] = None,
    *,
    accept_degraded_secret_isolation: bool = False,
    accept_agent_trust_everywhere: bool = False,
) -> EverywhereActivationResult:
    """Durably mark and propagate one entry to every known Project.

    The mark is committed before the best-effort sweep. A later Container start
    therefore converges a Project even if it was not enumerable or ready during
    this command, while each known Project still gets an immediate outcome.
    """
    targets = enumerate_project_targets(claude_provider, volume_probe)
    with mutation_lock():
        catalog = load_catalog()
        entry_id, entry = resolve_entry(catalog, token)
        _validate_activation_request(entry, consumers)
        if (
            entry.get("executionMode") == "agent-trusted"
            and not accept_agent_trust_everywhere
        ):
            raise ActivationError(
                "agent-trusted everywhere activation extends agent-identity "
                "trust to every present and future Project; explicitly "
                "acknowledge this scope with --yes"
            )
        degraded = degradation_status(entry)
        if degraded and not accept_degraded_secret_isolation:
            raise ActivationError(
                "degraded-secret-isolation: node owns the Docker daemon and can "
                "inspect this server's container environment; acknowledge "
                "interactively or use --accept-degraded-secret-isolation for "
                "non-interactive activation"
            )
        data = load_activations()
        mark = {
            "catalogId": entry_id,
            "consumers": sorted(set(consumers)),
        }
        if degraded:
            mark["degradedSecretIsolationAcknowledged"] = True
        previous = data["everywhere"].get(entry_id)
        mark_changed = previous != mark
        data["everywhere"][entry_id] = mark
        if mark_changed:
            _commit_activation_state(data)

        outcomes: list[EverywhereProjectOutcome] = []
        changed = mark_changed
        for target in targets.targets:
            project_key = canonical_project(target.project_key)
            current = load_activations()["projects"].get(project_key, {}).get(
                entry_id
            )
            if isinstance(current, dict) and current.get("optedOut") is True:
                outcomes.append(
                    EverywhereProjectOutcome(project_key, "opted-out")
                )
                continue
            try:
                result = _activate_locked(
                    entry_id,
                    project_key,
                    consumers,
                    probe,
                    accept_degraded_secret_isolation=accept_degraded_secret_isolation,
                )
            except ActivationError as exc:
                outcomes.append(
                    EverywhereProjectOutcome(
                        project_key, "skipped", str(exc)
                    )
                )
                continue
            outcome = "pending" if result.pending else "activated"
            if not result.changed:
                outcome = "skipped"
            changed = changed or result.changed
            outcomes.append(
                EverywhereProjectOutcome(
                    project_key, outcome, result.pending_reason
                )
            )
        for collision in targets.collisions:
            reason = (
                f"Project name {collision.name!r} is ambiguous; "
                "resolve the colliding host paths explicitly"
            )
            outcomes.extend(
                EverywhereProjectOutcome(project_key, "skipped", reason)
                for project_key in collision.project_keys
            )
        return EverywhereActivationResult(
            dict(entry), mark["consumers"], True, changed, outcomes
        )


def clear_everywhere(token: str) -> EverywhereActivationResult:
    """Clear only the durable mark; existing activations and opt-outs survive."""
    with mutation_lock():
        catalog = load_catalog()
        entry_id, entry = resolve_entry(catalog, token)
        data = load_activations()
        mark = data["everywhere"].pop(entry_id, None)
        if mark is not None:
            _commit_activation_state(data)
        consumers = list(mark.get("consumers", [])) if isinstance(mark, dict) else []
        return EverywhereActivationResult(
            dict(entry), consumers, False, mark is not None, []
        )


def _not_ready_reason(entry: dict[str, Any], report: ReadinessReport) -> str:
    missing = [
        f"{check.label} ({check.detail})" if check.detail else check.label
        for check in report.missing
    ]
    suffix = f"; missing: {', '.join(missing)}" if missing else ""
    return (
        f"catalog entry {entry['name']!r} is not ready for Project "
        f"{report.project_key}{suffix}"
    )


def reevaluate_pending(
    project: str,
    probe: Optional[ProjectProbe] = None,
) -> PendingReevaluationResult:
    """Seed everywhere marks and re-evaluate pending state after setup."""
    with mutation_lock():
        key = canonical_project(project)
        catalog = load_catalog()
        data = load_activations()
        records = data["projects"].get(key, {})
        local_probe = probe if probe is not None else ProjectProbe()
        attempts: list[PendingActivationAttempt] = []
        changed = False
        for entry_id, mark in sorted(data.get("everywhere", {}).items()):
            if entry_id in records:
                continue
            entry = catalog["entries"].get(entry_id)
            if not isinstance(entry, dict):
                continue
            if key not in data["projects"]:
                records = data["projects"].setdefault(key, {})
            record = {
                "catalogId": entry_id,
                "consumers": list(mark["consumers"]),
                "enabled": entry.get("type") == "http",
            }
            records[entry_id] = record
            if mark.get("degradedSecretIsolationAcknowledged") is True:
                data.setdefault("acknowledgements", {}).setdefault(key, {})[
                    entry_id
                ] = True
            changed = True
            if entry.get("type") == "http":
                attempts.append(PendingActivationAttempt(dict(entry), True))
        for entry_id, record in sorted(records.items()):
            if record.get("optedOut") is True:
                continue
            if record.get("enabled", True) is not False:
                continue
            entry = catalog["entries"].get(entry_id)
            if not isinstance(entry, dict):
                continue
            try:
                report = readiness_for_entry(
                    entry,
                    key,
                    local_probe,
                    secret_name=str(entry.get("secretStoreKey") or entry["name"]),
                )
                reason = "" if report.ready else _not_ready_reason(entry, report)
            except ReadinessError as exc:
                report = None
                reason = str(exc)
            if report is not None and report.ready:
                updated = dict(record)
                updated["enabled"] = True
                updated.pop("pendingReason", None)
                records[entry_id] = updated
                attempts.append(PendingActivationAttempt(dict(entry), True))
                changed = changed or updated != record
                continue
            updated = dict(record)
            updated["enabled"] = False
            updated["pendingReason"] = reason
            records[entry_id] = updated
            attempts.append(PendingActivationAttempt(dict(entry), False, reason))
            changed = changed or updated != record
        if changed:
            _commit_activation_state(data)
        return PendingReevaluationResult(key, attempts, changed)


def deactivate(token: str, project: str) -> ActivationResult:
    with mutation_lock():
        return _deactivate_locked(token, project)


def _deactivate_locked(
    token: str,
    project: str,
) -> ActivationResult:
    key = canonical_project(project)
    catalog = load_catalog()
    entry_id, entry = resolve_entry(catalog, token)
    data = load_activations()
    records = data["projects"].setdefault(key, {})
    record = records.get(entry_id)
    opt_out = {"catalogId": entry_id, "optedOut": True}
    changed = record != opt_out
    records[entry_id] = opt_out
    if changed:
        _commit_activation_state(data)
    consumers = list(record.get("consumers", [])) if isinstance(record, dict) else []
    return ActivationResult(dict(entry), key, consumers, changed)


_RUNTIME_FIELDS = {
    "command",
    "env",
    "envKeys",
    "prerequisites",
    "runtimeKind",
    "secretEnvKeys",
    "type",
    "url",
}


def _entry_activations(
    activations: dict[str, Any], entry_id: str
) -> list[dict[str, Any]]:
    affected: list[dict[str, Any]] = []
    for project, records in sorted(activations["projects"].items()):
        record = records.get(entry_id)
        if isinstance(record, dict) and record.get("optedOut") is not True:
            affected.append(
                {
                    "projectKey": project,
                    "consumers": sorted(record.get("consumers", [])),
                }
            )
    return affected


def _catalog_secret_paths() -> list[str]:
    paths = [global_secrets_path()]
    project_dir = os.path.join(config_root(), "projects")
    try:
        paths.extend(
            os.path.join(project_dir, name)
            for name in sorted(os.listdir(project_dir))
            if name.endswith(".secrets.json")
        )
    except FileNotFoundError:
        pass
    return [path for path in paths if os.path.isfile(path)]


def _catalog_secret_updates(
    entry_id: str,
    current_name: str,
    *,
    replacement_name: Optional[str],
) -> dict[str, dict[str, Any]]:
    """Move name-keyed credentials on rename or purge this identity on remove."""
    updates: dict[str, dict[str, Any]] = {}
    for path in _catalog_secret_paths():
        try:
            store = load_secrets(path)
        except (OSError, ValueError) as exc:
            raise ActivationError(f"cannot update MCP secret store {path}: {exc}") from exc
        servers = store["servers"]
        changed = False
        if replacement_name is None:
            for key in (current_name, entry_id):
                if key in servers:
                    del servers[key]
                    changed = True
        elif replacement_name != current_name and current_name in servers:
            if replacement_name in servers:
                raise ActivationError(
                    f"cannot rename catalog entry: secret store already contains "
                    f"a block named {replacement_name!r} in {path}"
                )
            servers[replacement_name] = servers.pop(current_name)
            changed = True
        if changed:
            updates[path] = store
    return updates


def _commit_catalog_state(
    catalog: dict[str, Any],
    activations: dict[str, Any],
    secret_updates: dict[str, dict[str, Any]],
    *,
    persist_activations: bool,
) -> None:
    with casfile.transaction() as txn:
        try:
            save_catalog(catalog)
            for path, store in secret_updates.items():
                save_secrets(path, store)
            if persist_activations:
                save_activation_store(activations)
            refresh_runtime(activations)
        except Exception as exc:
            _compensate(txn, "MCP catalog mutation", exc)


def _preflight_replacement(
    entry: dict[str, Any],
    affected: list[dict[str, Any]],
    probe: Optional[object],
    *,
    secret_name: Optional[str] = None,
) -> None:
    failures: list[str] = []
    if entry.get("type") == "http":
        return
    for item in affected:
        project = item["projectKey"]
        if isinstance(probe, DockerProbe) and type(probe).ready is not DockerProbe.ready:
            container = probe.find_running(project)
            if not container:
                failures.append(f"{project}: target Boxa is not running")
            elif not probe.ready(container, entry):
                failures.append(f"{project}: replacement is not ready")
            continue
        readiness_probe = probe if isinstance(probe, ProjectProbe) else ProjectProbe()
        try:
            report = readiness_for_entry(
                entry,
                project,
                readiness_probe,
                secret_name=str(entry.get("secretStoreKey") or secret_name or entry["name"]),
            )
        except ReadinessError as exc:
            failures.append(f"{project}: {exc}")
            continue
        if not report.ready:
            missing = ", ".join(check.label for check in report.missing)
            failures.append(f"{project}: replacement is not ready; missing: {missing}")
    if failures:
        raise ActivationError(
            "runtime-affecting catalog update refused; every activated Project "
            "must be running and ready: " + "; ".join(failures)
        )


def update_catalog_entry(
    token: str,
    changes: dict[str, Any],
    *,
    probe: Optional[object] = None,
) -> CatalogUpdateResult:
    """Publish one identity-preserving catalog update across all activations."""
    with mutation_lock():
        catalog = load_catalog()
        entry_id, current = resolve_entry(catalog, token)
        _updated_id, updated = updated_catalog_entry(catalog, token, changes)
        activations = load_activations()
        affected = _entry_activations(activations, entry_id)
        runtime_affecting = any(
            current.get(field) != updated.get(field) for field in _RUNTIME_FIELDS
        )
        if runtime_affecting and affected:
            _preflight_replacement(
                updated, affected, probe, secret_name=current["name"]
            )
        if updated == current:
            return CatalogUpdateResult(dict(updated), runtime_affecting, affected)
        catalog["entries"][entry_id] = updated
        secret_updates = (
            _catalog_secret_updates(
                entry_id, current["name"], replacement_name=updated["name"]
            )
            if current["name"] != updated["name"]
            else {}
        )
        _commit_catalog_state(
            catalog, activations, secret_updates,
            persist_activations=False,
        )
        return CatalogUpdateResult(dict(updated), runtime_affecting, affected)


def remove_catalog_entry(token: str) -> CatalogRemovalResult:
    """Atomically destroy an entry identity and every activation referencing it."""
    with mutation_lock():
        catalog = load_catalog()
        entry_id, entry = resolve_entry(catalog, token)
        activations = load_activations()
        affected = _entry_activations(activations, entry_id)
        had_acknowledgement = any(
            entry_id in records
            for records in activations.get("acknowledgements", {}).values()
        )
        had_everywhere = entry_id in activations.get("everywhere", {})
        had_project_state = any(
            entry_id in records for records in activations["projects"].values()
        )
        for project in list(activations["projects"]):
            records = activations["projects"][project]
            records.pop(entry_id, None)
            if not records:
                activations["projects"].pop(project, None)
        for project in list(activations.get("acknowledgements", {})):
            records = activations["acknowledgements"][project]
            records.pop(entry_id, None)
            if not records:
                activations["acknowledgements"].pop(project, None)
        activations.get("everywhere", {}).pop(entry_id, None)
        del catalog["entries"][entry_id]
        secret_updates = _catalog_secret_updates(
            entry_id, entry["name"], replacement_name=None
        )
        _commit_catalog_state(
            catalog, activations, secret_updates,
            persist_activations=(
                bool(affected)
                or had_acknowledgement
                or had_everywhere
                or had_project_state
            ),
        )
        return CatalogRemovalResult(dict(entry), affected)


def effective_catalog(project: str) -> list[dict[str, Any]]:
    key = canonical_project(project)
    catalog = load_catalog()
    activations = load_activations()
    records = activations["projects"].get(key, {})
    result = []
    for entry in sorted(catalog["entries"].values(), key=lambda e: (e["name"].casefold(), e["id"])):
        record = records.get(entry["id"])
        row = dict(entry)
        # Effective Project list is operational status, not definition export.
        # Keep degradation visible without unnecessarily repeating credential
        # key names (or the docker ``-e KEY`` tokens that contain them).
        row.pop("command", None)
        row.pop("env", None)
        row.pop("envKeys", None)
        row.pop("secretEnvKeys", None)
        row["available"] = True
        opted_out = bool(record and record.get("optedOut") is True)
        mark = activations.get("everywhere", {}).get(entry["id"])
        row["activated"] = bool(
            record and not opted_out and record.get("enabled", True)
        )
        row["consumers"] = list(record.get("consumers", [])) if isinstance(record, dict) else []
        row["everywhere"] = isinstance(mark, dict)
        row["everywhereConsumers"] = (
            list(mark.get("consumers", [])) if isinstance(mark, dict) else []
        )
        row["optedOut"] = opted_out
        row["agentIdentityTrustScope"] = (
            "every-project"
            if isinstance(mark, dict) and entry.get("executionMode") == "agent-trusted"
            else "project"
            if record and not opted_out and entry.get("executionMode") == "agent-trusted"
            else "none"
        )
        row["isolationStatus"] = degradation_status(entry) or "isolated"
        row["degradedSecretIsolationAcknowledged"] = (
            activations.get("acknowledgements", {}).get(key, {}).get(entry["id"]) is True
        )
        result.append(row)
    return result
