"""Project-scoped MCP catalog activations (ADR 0021, issue 02)."""

from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import tomllib
from dataclasses import dataclass
from typing import Any, Optional

from .catalog import (
    CatalogError,
    catalog_path,
    degradation_status,
    load_catalog,
    mutation_lock,
    resolve_entry,
    save_catalog,
    updated_catalog_entry,
)
from .providers.claude import render_target_path
from .profile import config_root
from .render import is_managed_or_legacy, rendered_name
from .readiness import (
    ProjectProbe,
    ReadinessError,
    readiness,
    readiness_for_entry,
)
from .secrets import global_secrets_path, load_secrets, save_secrets


ACTIVATION_VERSION = 1
RUNTIME_VERSION = 1
CONSUMERS = {"claude", "codex"}
_FILE_MODE = 0o600
_RUNTIME_MODE = 0o644
_CODEX_BEGIN = "# >>> boxa managed MCP servers >>>"
_CODEX_END = "# <<< boxa managed MCP servers <<<"


class ActivationError(RuntimeError):
    pass


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


def render_state_path() -> str:
    return os.path.join(_root(), "claude-activation-render-state.json")


def canonical_project(path: str) -> str:
    if not path:
        raise ActivationError("Project path must be non-empty")
    return os.path.realpath(os.path.abspath(os.path.expanduser(path))).rstrip("/") or "/"


def empty_activations() -> dict[str, Any]:
    return {"version": ACTIVATION_VERSION, "projects": {}, "acknowledgements": {}}


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
            consumers = record.get("consumers")
            if not isinstance(consumers, list) or not consumers or any(c not in CONSUMERS for c in consumers):
                raise ActivationError("malformed MCP activation consumers")
            if "enabled" in record and not isinstance(record["enabled"], bool):
                raise ActivationError("malformed MCP activation enabled flag")
    acknowledgements = data.get("acknowledgements", {})
    if not isinstance(acknowledgements, dict):
        raise ActivationError("malformed MCP activation acknowledgements")
    for project, records in acknowledgements.items():
        if canonical_project(project) != project or not isinstance(records, dict):
            raise ActivationError("malformed MCP activation acknowledgement Project")
        if any(not isinstance(entry_id, str) or value is not True for entry_id, value in records.items()):
            raise ActivationError("malformed MCP activation acknowledgement")
    data.setdefault("acknowledgements", acknowledgements)
    return data


def _atomic_json(path: str, data: dict[str, Any], mode: int) -> None:
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


@dataclass(frozen=True)
class _FileSnapshot:
    path: str
    existed: bool
    data: bytes = b""
    mode: int = 0


def _snapshot_file(path: str) -> _FileSnapshot:
    try:
        info = os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        return _FileSnapshot(path=path, existed=False)
    if not stat.S_ISREG(info.st_mode):
        raise ActivationError(f"transaction path is not a regular file: {path}")
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as exc:
        raise ActivationError(f"cannot snapshot transaction file {path}: {exc}") from exc
    return _FileSnapshot(
        path=path,
        existed=True,
        data=data,
        mode=stat.S_IMODE(info.st_mode),
    )


def _restore_file(snapshot: _FileSnapshot) -> None:
    """Restore exact pre-mutation bytes/existence without using render writes."""
    if not snapshot.existed:
        try:
            os.unlink(snapshot.path)
        except FileNotFoundError:
            pass
        return
    os.makedirs(os.path.dirname(snapshot.path), mode=0o755, exist_ok=True)
    tmp = f"{snapshot.path}.rollback-{os.getpid()}"
    try:
        fd = os.open(
            tmp,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            snapshot.mode,
        )
        with os.fdopen(fd, "wb") as fh:
            fh.write(snapshot.data)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, snapshot.mode)
        os.replace(tmp, snapshot.path)
        os.chmod(snapshot.path, snapshot.mode)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def _git_output(project: str, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-C", project, *args], stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        raise ActivationError(
            f"Codex activation requires a Git repository for Project {project}"
            + (f": {detail}" if detail else "")
        )
    return proc.stdout.strip()


def codex_config_path(project: str) -> str:
    return os.path.join(project, ".codex", "config.toml")


def claude_config_path(project: str) -> str:
    return os.path.join(project, ".mcp.json")


def _codex_git_paths(project: str) -> tuple[str, str, str]:
    top = os.path.realpath(_git_output(project, "rev-parse", "--show-toplevel"))
    config = codex_config_path(project)
    try:
        relative = os.path.relpath(config, top)
    except ValueError as exc:
        raise ActivationError(f"Codex config is outside the Project Git repository: {config}") from exc
    if relative == ".." or relative.startswith(".." + os.sep):
        raise ActivationError(f"Codex config is outside the Project Git repository: {config}")
    exclude = _git_output(
        project, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude"
    )
    return relative.replace(os.sep, "/"), os.path.realpath(exclude), config


def _codex_is_tracked(project: str, relative: str) -> bool:
    proc = subprocess.run(
        ["git", "-C", project, "ls-files", "--error-unmatch", "--", relative],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    return proc.returncode == 0


def _claude_git_paths(project: str) -> Optional[tuple[str, str, str]]:
    """Resolve local Git paths, while keeping non-repository Projects valid."""
    try:
        top_proc = subprocess.run(
            ["git", "-C", project, "rev-parse", "--show-toplevel"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
        )
    except OSError:
        return None
    if top_proc.returncode != 0:
        return None
    top = os.path.realpath(top_proc.stdout.strip())
    path = claude_config_path(project)
    relative = os.path.relpath(path, top)
    if relative == ".." or relative.startswith(".." + os.sep):
        raise ActivationError(f"Claude MCP config is outside the Project Git repository: {path}")
    try:
        exclude_proc = subprocess.run(
            [
                "git", "-C", project, "rev-parse", "--path-format=absolute",
                "--git-path", "info/exclude",
            ],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
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
    return (
        relative.replace(os.sep, "/"),
        os.path.realpath(exclude_proc.stdout.strip()),
        path,
    )


def _toml_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def _codex_header(name: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_-]+", name):
        return f"[mcp_servers.{name}]"
    return f'[mcp_servers."{_toml_escape(name)}"]'


def _split_codex_region(text: str, path: str) -> tuple[str, str]:
    begins = [m.start() for m in re.finditer(re.escape(_CODEX_BEGIN), text)]
    ends = [m.start() for m in re.finditer(re.escape(_CODEX_END), text)]
    if not begins and not ends:
        return text, ""
    if len(begins) != 1 or len(ends) != 1 or begins[0] >= ends[0]:
        raise ActivationError(f"malformed Boxa managed region in Codex config: {path}")
    begin = begins[0]
    if begin and text[begin - 1] == "\n":
        begin -= 1
    end = ends[0] + len(_CODEX_END)
    if end < len(text) and text[end] == "\n":
        end += 1
    return text[:begin], text[end:]


def _codex_region(project: str, records: dict[str, Any], catalog: dict[str, Any]) -> str:
    tables: list[str] = []
    for entry_id, record in sorted(records.items()):
        if record.get("enabled", True) is False or "codex" not in record["consumers"]:
            continue
        entry = catalog["entries"].get(entry_id)
        if not isinstance(entry, dict):
            continue
        args = [
            "--catalog-id", entry_id, "--consumer", "codex",
            "--project", project, entry["name"],
        ]
        rendered_args = ", ".join(f'"{_toml_escape(value)}"' for value in args)
        tables.append(
            f"{_codex_header(rendered_name(entry['name']))}\n"
            'command = "boxa-mcp-run"\n'
            f"args = [{rendered_args}]\n"
        )
    if not tables:
        return ""
    return f"{_CODEX_BEGIN}\n" + "\n".join(tables) + f"{_CODEX_END}\n"


def _codex_render_plan(
    activations: dict[str, Any],
    project: str,
    catalog: dict[str, Any],
) -> tuple[str, str, str, bool, str, str, str]:
    relative, exclude_path, path = _codex_git_paths(project)
    tracked = _codex_is_tracked(project, relative)
    records = activations["projects"].get(project, {})
    try:
        with open(path, encoding="utf-8", newline="") as fh:
            existing = fh.read()
    except FileNotFoundError:
        existing = ""
    except (OSError, UnicodeError) as exc:
        raise ActivationError(f"cannot read Codex config {path}: {exc}") from exc
    prefix, suffix = _split_codex_region(existing, path)
    region = _codex_region(project, records, catalog)
    if region:
        rendered = prefix + ("\n" if prefix else "") + region + suffix
    else:
        rendered = prefix + suffix
    if rendered:
        try:
            tomllib.loads(rendered)
        except (tomllib.TOMLDecodeError, ValueError) as exc:
            raise ActivationError(f"cannot render invalid Codex TOML {path}: {exc}") from exc
    return relative, exclude_path, path, tracked, existing, rendered, region


def _render_codex_activation(
    activations: dict[str, Any], project: str, *, allow_tracked: bool,
    catalog: Optional[dict[str, Any]] = None,
) -> None:
    (
        relative, exclude_path, path, tracked, existing, rendered, region,
    ) = _codex_render_plan(activations, project, catalog or load_catalog())
    if tracked and rendered != existing and not allow_tracked:
        raise ActivationError(
            f"tracked Codex config {path} requires --allow-tracked-codex-config"
        )
    if rendered != existing:
        if not rendered and not os.path.exists(path):
            return
        _atomic_text(path, rendered)
    if not tracked and region:
        _ensure_local_exclude(exclude_path, relative)


def _atomic_text(path: str, text: str) -> None:
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


def _ensure_local_exclude(path: str, relative: str) -> None:
    pattern = "/" + relative
    try:
        with open(path, encoding="utf-8", newline="") as fh:
            existing = fh.read()
    except FileNotFoundError:
        existing = ""
    lines = existing.splitlines()
    if pattern in lines:
        return
    separator = "" if not existing or existing.endswith("\n") else "\n"
    _atomic_text(path, existing + separator + pattern + "\n")


def _commit_activation_render(
    data: dict[str, Any], project: str, *, allow_tracked_codex_config: bool = False,
    allow_tracked_mcp_json: bool = False,
    render_codex: bool = False,
) -> None:
    """Atomically expose activation + runtime + Claude-derived state as a set.

    The files cannot share a filesystem-level rename transaction, so take
    exact pre-images and compensate on any failed write/read in the sequence.
    Rollback deliberately bypasses ``_atomic_json``: tests and real failures may
    make that render writer itself the failing component.
    """
    catalog = load_catalog()
    state = _load_render_state()
    _preflight_claude_lifecycle(
        catalog,
        data,
        state,
        allow_tracked=allow_tracked_mcp_json,
    )
    if render_codex:
        _preflight_codex_lifecycle(
            catalog,
            data,
            [project],
            allow_tracked=allow_tracked_codex_config,
        )
    paths: tuple[str, ...] = (
        activation_path(),
        runtime_path(),
        render_target_path(),
        render_state_path(),
    )
    for claude_project in _claude_render_projects(data, state):
        paths += (claude_config_path(claude_project),)
        git_paths = _claude_git_paths(claude_project)
        if git_paths is not None:
            _relative, exclude_path, _claude_path = git_paths
            paths += (exclude_path,)
    if render_codex:
        _relative, exclude_path, codex_path = _codex_git_paths(project)
        paths += (codex_path, exclude_path)
    snapshots = [_snapshot_file(path) for path in paths]
    try:
        save_activation_store(data)
        render_claude_activations(data, allow_tracked=allow_tracked_mcp_json)
        if render_codex:
            _render_codex_activation(
                data,
                project,
                allow_tracked=allow_tracked_codex_config,
                catalog=catalog,
            )
        refresh_runtime(data)
    except Exception:
        rollback_errors: list[str] = []
        for snapshot in reversed(snapshots):
            try:
                _restore_file(snapshot)
            except OSError as exc:
                rollback_errors.append(f"{snapshot.path}: {exc}")
        if rollback_errors:
            raise ActivationError(
                "MCP activation mutation failed and rollback was incomplete: "
                + "; ".join(rollback_errors)
            )
        raise


def save_activations(data: dict[str, Any]) -> None:
    save_activation_store(data)
    refresh_runtime(data)


def save_activation_store(data: dict[str, Any]) -> None:
    """Persist authoritative activation state without publishing broker runtime."""
    _atomic_json(activation_path(), data, _FILE_MODE)


def refresh_runtime(activations: Optional[dict[str, Any]] = None) -> None:
    """Publish the secret-free broker view; authoritative activation stays 0600."""
    activations = activations if activations is not None else load_activations()
    catalog = load_catalog()
    payload = {
        "version": RUNTIME_VERSION,
        "catalogVersion": catalog["version"],
        "entries": catalog["entries"],
        "projects": activations["projects"],
    }
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

    def to_dict(self) -> dict[str, Any]:
        return {"entry": self.entry, "projectKey": self.project_key, "consumers": self.consumers, "changed": self.changed}


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


def _load_render_state() -> dict[str, Any]:
    try:
        with open(render_state_path(), encoding="utf-8") as fh:
            value = json.load(fh)
        return value if isinstance(value, dict) else {"projects": {}}
    except (OSError, ValueError):
        return {"projects": {}}


def _claude_render_projects(
    activations: dict[str, Any], state: dict[str, Any]
) -> list[str]:
    old = state.get("projects") if isinstance(state.get("projects"), dict) else {}
    return sorted(set(activations["projects"]) | set(old))


def _json_document(data: dict[str, Any]) -> str:
    return json.dumps(data, indent=2) + "\n"


def _claude_render_plan(
    activations: dict[str, Any],
    project: str,
    catalog: dict[str, Any],
    state: dict[str, Any],
) -> tuple[str, Optional[str], Optional[str], bool, str, str, list[str]]:
    path = claude_config_path(project)
    try:
        with open(path, encoding="utf-8") as fh:
            existing = fh.read()
        data = json.loads(existing)
    except FileNotFoundError:
        existing = ""
        data = {}
    except (OSError, ValueError) as exc:
        raise ActivationError(f"cannot read Claude MCP config {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ActivationError(f"Claude MCP config is not an object: {path}")

    old = state.get("projects") if isinstance(state.get("projects"), dict) else {}
    old_names = old.get(project, [])
    if not isinstance(old_names, list):
        old_names = []
    owned = {
        name for name in old_names
        if isinstance(name, str)
    }
    definitions: dict[str, dict[str, Any]] = {}
    records = activations["projects"].get(project, {})
    for entry_id, activation in records.items():
        if activation.get("enabled", True) is False or "claude" not in activation["consumers"]:
            continue
        entry = catalog["entries"].get(entry_id)
        if not isinstance(entry, dict):
            continue
        name = rendered_name(entry["name"])
        definitions[name] = {
            "type": "stdio",
            "command": "boxa-mcp-run",
            "args": [
                "--catalog-id", entry_id, "--consumer", "claude",
                "--project", project, entry["name"],
            ],
        }

    block = data.get("mcpServers")
    if block is not None and not isinstance(block, dict):
        raise ActivationError(f"Claude MCP config mcpServers is not an object: {path}")
    changed_block = bool(owned or definitions)
    if changed_block:
        if block is None:
            block = {}
            data["mcpServers"] = block
        for name in owned | set(definitions):
            block.pop(name, None)
        block.update(definitions)
        if not block:
            data.pop("mcpServers", None)
    rendered = _json_document(data) if data else ""

    git_paths = _claude_git_paths(project)
    tracked = False
    exclude_path: Optional[str] = None
    relative: Optional[str] = None
    if git_paths is not None:
        relative, exclude_path, _path = git_paths
        tracked = _codex_is_tracked(project, ".mcp.json")
    return (
        path, exclude_path, relative, tracked, existing, rendered,
        sorted(definitions),
    )


def _retire_old_claude_render(state: dict[str, Any]) -> None:
    """Purge only Project-scoped catalog renders from Claude's rewritten file."""
    path = render_target_path()
    try:
        with open(path, encoding="utf-8") as fh:
            existing = fh.read()
        data = json.loads(existing)
    except FileNotFoundError:
        return
    except (OSError, ValueError) as exc:
        raise ActivationError(f"cannot read Claude config {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ActivationError(f"Claude config is not an object: {path}")
    projects = data.get("projects")
    if not isinstance(projects, dict):
        return
    old = state.get("projects") if isinstance(state.get("projects"), dict) else {}
    changed = False
    for project, record in projects.items():
        if not isinstance(record, dict):
            continue
        names = old.get(project, [])
        if not isinstance(names, list):
            names = []
        owned = {
            name for name in names
            if isinstance(name, str)
        }
        block = record.get("mcpServers")
        if isinstance(block, dict):
            remove = {
                name for name in block
                if name in owned or is_managed_or_legacy(name)
            }
            for name in remove:
                del block[name]
            changed = changed or bool(remove)
            owned |= remove
        disabled = record.get("disabledMcpServers")
        if isinstance(disabled, list):
            retained = [
                name for name in disabled
                if not (
                    isinstance(name, str)
                    and (name in owned or is_managed_or_legacy(name))
                )
            ]
            if retained != disabled:
                record["disabledMcpServers"] = retained
                changed = True
    if changed:
        _atomic_text(path, _json_document(data))


def _preflight_claude_lifecycle(
    catalog: dict[str, Any],
    activations: dict[str, Any],
    state: dict[str, Any],
    *,
    allow_tracked: bool,
) -> None:
    """Validate every Project render before any lifecycle store is changed."""
    refusals: list[str] = []
    for project in _claude_render_projects(activations, state):
        (
            path, _exclude, _relative, tracked, existing, rendered, _names,
        ) = _claude_render_plan(activations, project, catalog, state)
        if tracked and rendered != existing and not allow_tracked:
            refusals.append(path)
    if refusals:
        raise ActivationError(
            "tracked Claude MCP config requires --allow-tracked-mcp-json for: "
            + ", ".join(refusals)
        )


def render_claude_activations(
    activations: Optional[dict[str, Any]] = None,
    *,
    allow_tracked: bool = False,
) -> None:
    activations = activations if activations is not None else load_activations()
    catalog = load_catalog()
    state = _load_render_state()
    _preflight_claude_lifecycle(
        catalog, activations, state, allow_tracked=allow_tracked
    )
    plans = [
        _claude_render_plan(activations, project, catalog, state)
        for project in _claude_render_projects(activations, state)
    ]
    _retire_old_claude_render(state)
    new_state: dict[str, list[str]] = {}
    for (
        path, exclude_path, relative, tracked, existing, rendered, names,
    ) in plans:
        if rendered != existing:
            if rendered:
                _atomic_text(path, rendered)
            else:
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass
        if (
            exclude_path is not None
            and relative is not None
            and not tracked
            and names
        ):
            _ensure_local_exclude(exclude_path, relative)
        if names:
            project = os.path.dirname(path)
            new_state[project] = names
    _atomic_json(render_state_path(), {"projects": new_state}, 0o600)


def activate(
    token: str, project: str, consumers: list[str], probe: Optional[object] = None,
    *, allow_tracked_codex_config: bool = False,
    allow_tracked_mcp_json: bool = False,
    accept_degraded_secret_isolation: bool = False,
) -> ActivationResult:
    with mutation_lock():
        return _activate_locked(
            token,
            project,
            consumers,
            probe,
            allow_tracked_codex_config=allow_tracked_codex_config,
            allow_tracked_mcp_json=allow_tracked_mcp_json,
            accept_degraded_secret_isolation=accept_degraded_secret_isolation,
        )


def _activate_locked(
    token: str, project: str, consumers: list[str], probe: Optional[object] = None,
    *, allow_tracked_codex_config: bool = False,
    allow_tracked_mcp_json: bool = False,
    accept_degraded_secret_isolation: bool = False,
) -> ActivationResult:
    if not consumers or any(c not in CONSUMERS for c in consumers):
        raise ActivationError("activation requires an explicit supported consumer (--for claude, codex, or both)")
    key = canonical_project(project)
    try:
        catalog = load_catalog()
        entry_id, entry = resolve_entry(catalog, token)
    except CatalogError as exc:
        raise ActivationError(str(exc)) from exc
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
    # Keep the issue-02 boolean probe seam until legacy profile migration in
    # issue 08. New/default callers receive the detailed deterministic report.
    if isinstance(probe, DockerProbe) and type(probe).ready is not DockerProbe.ready:
        container = probe.find_running(key)
        if not container:
            raise ActivationError(f"target Boxa for {key} is not running; activation never starts it implicitly")
        is_ready = probe.ready(container, entry)
        missing = []
    else:
        readiness_probe = probe if isinstance(probe, ProjectProbe) else ProjectProbe()
        try:
            report = readiness(entry_id, key, readiness_probe)
        except ReadinessError as exc:
            raise ActivationError(str(exc)) from exc
        is_ready = report.ready
        missing = [
            f"{check.label} ({check.detail})" if check.detail else check.label
            for check in report.missing
        ]
    if not is_ready:
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
    if degraded and not accepted:
        data.setdefault("acknowledgements", {}).setdefault(key, {})[entry_id] = True
    records = data["projects"].setdefault(key, {})
    record = {"catalogId": entry_id, "consumers": sorted(set(consumers)), "enabled": True}
    previous = records.get(entry_id)
    changed = previous != record
    records[entry_id] = record
    _commit_activation_render(
        data, key, allow_tracked_codex_config=allow_tracked_codex_config,
        allow_tracked_mcp_json=allow_tracked_mcp_json,
        render_codex=("codex" in record["consumers"] or (
            isinstance(previous, dict) and "codex" in previous.get("consumers", [])
        )),
    )
    return ActivationResult(dict(entry), key, record["consumers"], changed)


def deactivate(
    token: str,
    project: str,
    *,
    allow_tracked_codex_config: bool = False,
    allow_tracked_mcp_json: bool = False,
) -> ActivationResult:
    with mutation_lock():
        return _deactivate_locked(
            token,
            project,
            allow_tracked_codex_config=allow_tracked_codex_config,
            allow_tracked_mcp_json=allow_tracked_mcp_json,
        )


def _deactivate_locked(
    token: str,
    project: str,
    *,
    allow_tracked_codex_config: bool,
    allow_tracked_mcp_json: bool,
) -> ActivationResult:
    key = canonical_project(project)
    catalog = load_catalog()
    entry_id, entry = resolve_entry(catalog, token)
    data = load_activations()
    records = data["projects"].get(key, {})
    record = records.pop(entry_id, None)
    if not records:
        data["projects"].pop(key, None)
    _commit_activation_render(
        data, key,
        allow_tracked_codex_config=allow_tracked_codex_config,
        allow_tracked_mcp_json=allow_tracked_mcp_json,
        render_codex=isinstance(record, dict) and "codex" in record.get("consumers", []),
    )
    consumers = list(record.get("consumers", [])) if isinstance(record, dict) else []
    return ActivationResult(dict(entry), key, consumers, record is not None)


_RUNTIME_FIELDS = {
    "command",
    "env",
    "envKeys",
    "prerequisites",
    "runtimeKind",
    "secretEnvKeys",
    "type",
}


def _entry_activations(
    activations: dict[str, Any], entry_id: str
) -> list[dict[str, Any]]:
    affected: list[dict[str, Any]] = []
    for project, records in sorted(activations["projects"].items()):
        record = records.get(entry_id)
        if isinstance(record, dict):
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


def _catalog_transaction_paths(
    codex_projects: list[str],
    claude_projects: list[str],
    secret_paths: list[str],
    *,
    persist_activations: bool,
    render_consumers: bool,
) -> list[str]:
    paths = [
        catalog_path(),
        runtime_path(),
    ]
    if persist_activations:
        paths.append(activation_path())
    if render_consumers:
        paths.extend(
            (render_target_path(), render_state_path())
        )
    paths.extend(secret_paths)
    for project in codex_projects:
        _relative, exclude_path, codex_path = _codex_git_paths(project)
        paths.extend((codex_path, exclude_path))
    for project in claude_projects:
        paths.append(claude_config_path(project))
        git_paths = _claude_git_paths(project)
        if git_paths is not None:
            _relative, exclude_path, _claude_path = git_paths
            paths.append(exclude_path)
    # One Project can only appear once today, but preserve one exact pre-image
    # if future consumer records introduce duplicates.
    return list(dict.fromkeys(paths))


def _preflight_codex_lifecycle(
    catalog: dict[str, Any],
    activations: dict[str, Any],
    projects: list[str],
    *,
    allow_tracked: bool,
) -> None:
    """Validate every affected Codex render and tracked-write consent up front."""
    refusals: list[str] = []
    for project in projects:
        (
            _relative,
            _exclude_path,
            path,
            tracked,
            existing,
            rendered,
            _region,
        ) = _codex_render_plan(activations, project, catalog)
        if tracked and rendered != existing and not allow_tracked:
            refusals.append(path)
    if refusals:
        raise ActivationError(
            "tracked Codex config requires --allow-tracked-codex-config for: "
            + ", ".join(refusals)
        )


def _commit_catalog_render(
    catalog: dict[str, Any],
    activations: dict[str, Any],
    codex_projects: list[str],
    secret_updates: dict[str, dict[str, Any]],
    *,
    persist_activations: bool,
    render_consumers: bool,
    allow_tracked_codex_config: bool = False,
    allow_tracked_mcp_json: bool = False,
) -> None:
    state = _load_render_state()
    claude_projects = (
        _claude_render_projects(activations, state) if render_consumers else []
    )
    if render_consumers:
        _preflight_claude_lifecycle(
            catalog,
            activations,
            state,
            allow_tracked=allow_tracked_mcp_json,
        )
    _preflight_codex_lifecycle(
        catalog,
        activations,
        codex_projects,
        allow_tracked=allow_tracked_codex_config,
    )
    snapshots = [
        _snapshot_file(path)
        for path in _catalog_transaction_paths(
            codex_projects,
            claude_projects,
            list(secret_updates),
            persist_activations=persist_activations,
            render_consumers=render_consumers,
        )
    ]
    try:
        save_catalog(catalog)
        for path, store in secret_updates.items():
            save_secrets(path, store)
        if persist_activations:
            save_activation_store(activations)
        if render_consumers:
            render_claude_activations(
                activations, allow_tracked=allow_tracked_mcp_json
            )
            for project in codex_projects:
                _render_codex_activation(
                    activations,
                    project,
                    allow_tracked=allow_tracked_codex_config,
                    catalog=catalog,
                )
        # Broker authority is the final commit point. Until every fallible host
        # store and consumer render above succeeds, concurrent launches keep
        # reading the exact old runtime snapshot.
        refresh_runtime(activations)
    except Exception:
        rollback_errors: list[str] = []
        for snapshot in reversed(snapshots):
            try:
                _restore_file(snapshot)
            except OSError as exc:
                rollback_errors.append(f"{snapshot.path}: {exc}")
        if rollback_errors:
            raise ActivationError(
                "MCP catalog mutation failed and rollback was incomplete: "
                + "; ".join(rollback_errors)
            )
        raise


def _preflight_replacement(
    entry: dict[str, Any],
    affected: list[dict[str, Any]],
    probe: Optional[object],
    *,
    secret_name: Optional[str] = None,
) -> None:
    failures: list[str] = []
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
    allow_tracked_codex_config: bool = False,
    allow_tracked_mcp_json: bool = False,
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
        render_consumers = bool(affected) and (
            runtime_affecting or current.get("name") != updated.get("name")
        )
        codex_projects = (
            [
                item["projectKey"] for item in affected
                if "codex" in item["consumers"]
            ]
            if render_consumers
            else []
        )
        _commit_catalog_render(
            catalog, activations, codex_projects, secret_updates,
            persist_activations=False,
            render_consumers=render_consumers,
            allow_tracked_codex_config=allow_tracked_codex_config,
            allow_tracked_mcp_json=allow_tracked_mcp_json,
        )
        return CatalogUpdateResult(dict(updated), runtime_affecting, affected)


def remove_catalog_entry(
    token: str, *, allow_tracked_codex_config: bool = False,
    allow_tracked_mcp_json: bool = False,
) -> CatalogRemovalResult:
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
        del catalog["entries"][entry_id]
        secret_updates = _catalog_secret_updates(
            entry_id, entry["name"], replacement_name=None
        )
        codex_projects = [
            item["projectKey"] for item in affected
            if "codex" in item["consumers"]
        ]
        _commit_catalog_render(
            catalog, activations, codex_projects, secret_updates,
            persist_activations=bool(affected) or had_acknowledgement,
            render_consumers=bool(affected),
            allow_tracked_codex_config=allow_tracked_codex_config,
            allow_tracked_mcp_json=allow_tracked_mcp_json,
        )
        return CatalogRemovalResult(dict(entry), affected)


def effective_catalog(project: str) -> list[dict[str, Any]]:
    key = canonical_project(project)
    catalog = load_catalog()
    records = load_activations()["projects"].get(key, {})
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
        row["activated"] = bool(record and record.get("enabled", True))
        row["consumers"] = list(record.get("consumers", [])) if isinstance(record, dict) else []
        row["isolationStatus"] = degradation_status(entry) or "isolated"
        row["degradedSecretIsolationAcknowledged"] = (
            load_activations().get("acknowledgements", {}).get(key, {}).get(entry["id"]) is True
        )
        result.append(row)
    return result
