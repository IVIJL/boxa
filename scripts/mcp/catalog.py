"""Host-owned MCP catalog (ADR 0021, catalog slice 01).

The catalog deliberately lives beside, and is independent from, the legacy
global/Project profile files.  Reading or mutating it never migrates a profile
and never renders agent configuration.
"""

from __future__ import annotations

import fcntl
import json
import os
import stat
import threading
import time
import uuid
import re
from contextlib import contextmanager
from typing import Any, Callable, Optional

from . import casfile
from .add import AddError, build_candidate, parse_spec
from .apply import is_applicable, not_applicable_reason
from .merge import MergedCandidate, compute_import_id
from .docker_adapter import DockerAdapterError, parse_declared_run


CATALOG_VERSION = 2
EXECUTION_MODE = "service-isolated"
EXECUTION_MODES = {"service-isolated", "agent-trusted"}
AGENT_TRUSTED_FIXED_ENV_KEYS = {
    "HOME", "USER", "LOGNAME", "PATH", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
    "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "NPM_CONFIG_PREFIX",
    "DOCKER_HOST", "SSH_AUTH_SOCK",
}
READINESS_SUMMARY = "requires-project"
# The exact access boundaries shown before a mode grant. Shared by the
# `boxa mcp mode` preview and the codex-delegate seed offer (mcp.seed) so the
# user always confirms against one canonical wording.
AGENT_TRUSTED_ACCESS = (
    "Container account node",
    "Project source read/write",
    "node private HOME and mounted Codex state",
    "node rootless Docker socket when present",
    "forwarded SSH agent socket when present",
    "declared non-secret catalog environment only",
    "no ambient launcher environment or MCP secret-store values",
)
SERVICE_ISOLATED_ACCESS = (
    "Container account boxa-mcp",
    "Project source read/write",
    "no node private HOME or raw Docker/SSH sockets",
)
DEGRADED_SECRET_ISOLATION = "degraded-secret-isolation"
# The catalog shares the legacy profile directory, which must remain traversable
# by the in-Container broker. The catalog FILE itself is host-only 0600.
_DIR_MODE = 0o755
_FILE_MODE = 0o600
# The mutation window marker is published, not gated: Containers read it.
MUTATION_MARKER_NAME = "mutation-in-progress"
_MARKER_FILE_MODE = 0o644
_MARKER_ATTEMPTS = 100
_MARKER_RETRY_SECONDS = 0.01
_PROCESS_MUTATION_LOCK = threading.RLock()
_MUTATION_LOCAL = threading.local()


class CatalogError(ValueError):
    """Catalog data or a requested catalog mutation is invalid."""


def catalog_path() -> str:
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = xdg if xdg else os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "boxa", "mcp", "catalog.json")


def mutation_lock_path() -> str:
    return os.path.join(os.path.dirname(catalog_path()), ".mutation.lock")


def mutation_marker_path() -> str:
    """Container-visible publication of the host mutation window (ADR 0022).

    The lock itself lives in the gated host store and must stay unreachable
    from a Container. Its *window* is published as a read-only file in the
    already-mounted runtime directory: the host holds an exclusive advisory
    lock on it for the whole transaction, so an in-Container convergence can
    observe — never take — a host mutation whose runtime snapshot is not yet
    republished. The lock is held by an open file description, so a crashed
    host releases it automatically and the window can never go stale.
    """
    return os.path.join(
        os.path.dirname(catalog_path()), "runtime", MUTATION_MARKER_NAME
    )


def _publish_mutation_window() -> Optional[int]:
    path = mutation_marker_path()
    try:
        os.makedirs(os.path.dirname(path), mode=_DIR_MODE, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT, _MARKER_FILE_MODE)
    except OSError:
        return None
    try:
        os.chmod(path, _MARKER_FILE_MODE)
    except OSError:
        pass
    for _attempt in range(_MARKER_ATTEMPTS):
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # Only read-only observers can hold this, and only for the
            # duration of one probe. Never block a host mutation on them.
            time.sleep(_MARKER_RETRY_SECONDS)
            continue
        except OSError:
            break
        return fd
    os.close(fd)
    return None


def _withdraw_mutation_window(fd: Optional[int]) -> None:
    if fd is None:
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    os.close(fd)


@contextmanager
def mutation_lock():
    """Serialize catalog/activation read-modify-write transactions."""
    with _PROCESS_MUTATION_LOCK:
        depth = getattr(_MUTATION_LOCAL, "depth", 0)
        if depth:
            _MUTATION_LOCAL.depth = depth + 1
            try:
                yield
            finally:
                _MUTATION_LOCAL.depth -= 1
            return
        path = mutation_lock_path()
        os.makedirs(os.path.dirname(path), mode=_DIR_MODE, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT, _FILE_MODE)
        marker_fd: Optional[int] = None
        try:
            os.chmod(path, _FILE_MODE)
            fcntl.flock(fd, fcntl.LOCK_EX)
            marker_fd = _publish_mutation_window()
            _MUTATION_LOCAL.depth = 1
            yield
        finally:
            _MUTATION_LOCAL.depth = 0
            _withdraw_mutation_window(marker_fd)
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)


def empty_catalog() -> dict[str, Any]:
    return {"version": CATALOG_VERSION, "entries": {}}


def _validate_string_list(value: Any, label: str) -> None:
    if not isinstance(value, list) or any(not isinstance(v, str) for v in value):
        raise CatalogError(f"malformed catalog ({label} is not a string list)")


_ENV_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")


def _validate_os_string(value: str, label: str, *, allow_empty: bool = False) -> None:
    if (not allow_empty and not value) or "\x00" in value:
        raise CatalogError(f"malformed catalog ({label} is not a valid OS string)")


def _validate_env_names(value: list[str], label: str) -> None:
    for name in value:
        if not _ENV_NAME.fullmatch(name):
            raise CatalogError(f"malformed catalog ({label} contains an invalid environment name)")


def _validate_new_docker_policy(entry: dict[str, Any]) -> None:
    """Reject new unsafe definitions while legacy catalog loads remain readable."""
    if (
        entry.get("executionMode") == "service-isolated"
        and entry.get("runtimeKind") == "docker"
    ):
        try:
            parse_declared_run(entry["command"]["argv"])
        except DockerAdapterError as exc:
            raise CatalogError(str(exc)) from exc


def _validate_entry(entry_id: str, entry: Any) -> None:
    if not isinstance(entry, dict):
        raise CatalogError(f"malformed catalog (entry {entry_id!r} is not an object)")
    if entry.get("id") != entry_id:
        raise CatalogError(f"malformed catalog (entry {entry_id!r} has mismatched id)")
    try:
        uuid.UUID(entry_id)
    except (ValueError, TypeError, AttributeError) as exc:
        raise CatalogError(f"malformed catalog (entry id {entry_id!r} is not opaque UUID)") from exc
    for field in ("name", "type", "executionMode", "runtimeKind"):
        if not isinstance(entry.get(field), str) or not entry[field]:
            raise CatalogError(f"malformed catalog (entry {entry_id!r} has invalid {field})")
    if "description" in entry and not isinstance(entry["description"], str):
        raise CatalogError(
            f"malformed catalog (entry {entry_id!r} has invalid description)"
        )
    if "secretStoreKey" in entry and (
        not isinstance(entry["secretStoreKey"], str) or not entry["secretStoreKey"]
    ):
        raise CatalogError(
            f"malformed catalog (entry {entry_id!r} has invalid secretStoreKey)"
        )
    if entry["executionMode"] not in EXECUTION_MODES:
        raise CatalogError(
            f"malformed catalog (entry {entry_id!r} has unsupported executionMode)"
        )
    command = entry.get("command")
    if not isinstance(command, dict):
        raise CatalogError(f"malformed catalog (entry {entry_id!r} command is not an object)")
    _validate_string_list(command.get("argv"), f"entry {entry_id!r} command.argv")
    if not command["argv"]:
        raise CatalogError(f"malformed catalog (entry {entry_id!r} command.argv is empty)")
    for value in command["argv"]:
        _validate_os_string(value, f"entry {entry_id!r} command.argv token")
    _validate_string_list(entry.get("envKeys"), f"entry {entry_id!r} envKeys")
    _validate_string_list(
        entry.get("secretEnvKeys"), f"entry {entry_id!r} secretEnvKeys"
    )
    _validate_env_names(entry["envKeys"], f"entry {entry_id!r} envKeys")
    _validate_env_names(
        entry["secretEnvKeys"], f"entry {entry_id!r} secretEnvKeys"
    )
    env = entry.get("env", {})
    if not isinstance(env, dict) or any(
        not isinstance(k, str) or not isinstance(v, str) for k, v in env.items()
    ):
        raise CatalogError(f"malformed catalog (entry {entry_id!r} env is invalid)")
    _validate_env_names(list(env), f"entry {entry_id!r} env")
    for value in env.values():
        _validate_os_string(value, f"entry {entry_id!r} env value", allow_empty=True)
    if set(env) & set(entry["secretEnvKeys"]):
        raise CatalogError(f"malformed catalog (entry {entry_id!r} stores secret env values)")
    if entry["executionMode"] == "agent-trusted" and entry["secretEnvKeys"]:
        raise CatalogError(
            f"malformed catalog (agent-trusted entry {entry_id!r} declares secret env keys)"
        )
    fixed_overrides = set(env) & AGENT_TRUSTED_FIXED_ENV_KEYS
    if entry["executionMode"] == "agent-trusted" and fixed_overrides:
        raise CatalogError(
            f"malformed catalog (agent-trusted entry {entry_id!r} overrides "
            "fixed environment: " + ", ".join(sorted(fixed_overrides)) + ")"
        )
    prerequisites = entry.get("prerequisites", {})
    if not isinstance(prerequisites, dict):
        raise CatalogError(f"malformed catalog (entry {entry_id!r} prerequisites is invalid)")
    allowed_prerequisites = {"files", "sockets", "credentials", "probes"}
    unknown = set(prerequisites) - allowed_prerequisites
    if unknown:
        raise CatalogError(
            f"malformed catalog (entry {entry_id!r} has unknown prerequisites: "
            + ", ".join(sorted(unknown))
            + ")"
        )
    for field in sorted(allowed_prerequisites):
        if field in prerequisites:
            _validate_string_list(
                prerequisites[field], f"entry {entry_id!r} prerequisites.{field}"
            )
            for value in prerequisites[field]:
                _validate_os_string(
                    value, f"entry {entry_id!r} prerequisites.{field} value"
                )
    _validate_env_names(
        prerequisites.get("credentials", []),
        f"entry {entry_id!r} prerequisites.credentials",
    )
    supported_probes = {"codex-login-status"}
    unsupported = set(prerequisites.get("probes", [])) - supported_probes
    if unsupported:
        raise CatalogError(
            f"malformed catalog (entry {entry_id!r} has unsupported readiness probes: "
            + ", ".join(sorted(unsupported))
            + ")"
        )


def load_catalog(path: Optional[str] = None) -> dict[str, Any]:
    """Read and validate the catalog; absence means an empty, unwritten catalog."""
    path = path or catalog_path()
    if not os.path.exists(path):
        return empty_catalog()
    if not os.path.isfile(path) or stat.S_ISLNK(os.lstat(path).st_mode):
        raise CatalogError(f"catalog path is not a regular host-owned file: {path}")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        raise CatalogError(f"cannot read catalog {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise CatalogError(f"malformed catalog (not an object): {path}")
    if data.get("version") != CATALOG_VERSION:
        raise CatalogError(
            f"unsupported catalog version {data.get('version')!r} in {path}; "
            f"expected {CATALOG_VERSION}"
        )
    entries = data.get("entries")
    if not isinstance(entries, dict):
        raise CatalogError(f"malformed catalog ('entries' is not an object): {path}")
    names: set[str] = set()
    for entry_id, entry in entries.items():
        _validate_entry(entry_id, entry)
        if entry["name"] in names:
            raise CatalogError(f"malformed catalog (duplicate name {entry['name']!r})")
        names.add(entry["name"])
    return data


def save_catalog(catalog: dict[str, Any], path: Optional[str] = None) -> None:
    """Validate and atomically replace the secret-free host-owned catalog."""
    path = path or catalog_path()
    # Validate before opening a temporary file, so malformed state is never
    # normalized or partially overwritten by a failed mutation.
    if catalog.get("version") != CATALOG_VERSION or not isinstance(
        catalog.get("entries"), dict
    ):
        raise CatalogError("refusing to save malformed catalog")
    for entry_id, entry in catalog["entries"].items():
        _validate_entry(entry_id, entry)
    parent = os.path.dirname(path)
    os.makedirs(parent, mode=_DIR_MODE, exist_ok=True)
    os.chmod(parent, _DIR_MODE)
    # Journalled (not compare-and-swapped): the catalog is Boxa-private and
    # serialized by the mutation lock, but a failed batch must still take this
    # write back exactly.
    with casfile.record(path):
        _write_catalog(catalog, path)


def _write_catalog(catalog: dict[str, Any], path: str) -> None:
    tmp = f"{path}.tmp-{os.getpid()}"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, _FILE_MODE)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(catalog, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, _FILE_MODE)
        os.replace(tmp, path)
        os.chmod(path, _FILE_MODE)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def runtime_kind(argv: list[str]) -> str:
    base = os.path.basename(argv[0]).lower()
    if base in {"docker", "podman"}:
        return "docker"
    if base in {"npx", "npm", "pnpm", "yarn", "bunx", "node"}:
        return "node"
    if base in {"uvx", "uv", "python", "python3", "pipx"}:
        return "python"
    return "direct"


def is_codex_delegate_argv(argv: list[str]) -> bool:
    """True when ``argv`` is the Codex delegation server (``codex mcp-server``)."""
    return (
        bool(argv)
        and os.path.basename(argv[0]).lower() == "codex"
        and len(argv) > 1
        and argv[1] == "mcp-server"
    )


def degradation_status(entry: dict[str, Any]) -> Optional[str]:
    """Visible temporary Docker-secret limitation, without exposing key names."""
    if (
        entry.get("executionMode") == "service-isolated"
        and entry.get("runtimeKind") == "docker"
        and bool(entry.get("secretEnvKeys"))
    ):
        return DEGRADED_SECRET_ISOLATION
    return None


def entries_sorted(catalog: Optional[dict[str, Any]] = None) -> list[dict[str, Any]]:
    catalog = catalog if catalog is not None else load_catalog()
    return sorted(
        (dict(entry) for entry in catalog["entries"].values()),
        key=lambda entry: (entry["name"].casefold(), entry["id"]),
    )


def add_entry(
    name: str,
    spec_argv: list[str],
    *,
    id_factory: Callable[[], uuid.UUID] = uuid.uuid4,
) -> dict[str, Any]:
    with mutation_lock():
        return _add_entry_locked(name, spec_argv, id_factory=id_factory)


def add_entry_trusted(
    name: str,
    spec_argv: list[str],
    *,
    id_factory: Callable[[], uuid.UUID] = uuid.uuid4,
) -> dict[str, Any]:
    """Create agent-trusted with one catalog write.

    A crash can never persist a half-granted entry. The caller (mcp.seed)
    collects the interactive host confirmation.
    """
    if not _host_mode_command():
        raise CatalogError("agent-trusted entries can only be created on the host")
    with mutation_lock():
        return _add_entry_locked(
            name,
            spec_argv,
            id_factory=id_factory,
            execution_mode="agent-trusted",
        )


def _add_entry_locked(
    name: str,
    spec_argv: list[str],
    *,
    id_factory: Callable[[], uuid.UUID],
    execution_mode: str = EXECUTION_MODE,
) -> dict[str, Any]:
    if execution_mode not in EXECUTION_MODES:
        raise CatalogError(
            "execution mode must be service-isolated or agent-trusted"
        )
    if not name or name.strip() != name:
        raise CatalogError("catalog entry name must be non-empty without surrounding space")
    catalog = load_catalog()
    if any(entry["name"] == name for entry in catalog["entries"].values()):
        raise CatalogError(f"catalog entry named {name!r} already exists")
    try:
        spec = parse_spec(spec_argv)
    except AddError as exc:
        raise CatalogError(str(exc)) from exc
    candidate = build_candidate(name, spec, "global", "")
    merged = MergedCandidate(
        candidate=candidate, import_id=compute_import_id(candidate)
    )
    is_codex_delegate = is_codex_delegate_argv(spec.argv)
    if not is_applicable(merged) and not is_codex_delegate:
        raise CatalogError(f"cannot add {name!r}: {not_applicable_reason(merged)}")
    # Catalog data is secret-free. The later migration/secret-store slice can
    # attach credentials; this first slice must never persist an inline value.
    inline_secret_keys = sorted(set(spec.env_values) & set(spec.secret_env_keys))
    if inline_secret_keys:
        raise CatalogError(
            "catalog add does not accept inline secret values; declare/pass them "
            "without a value (keys: " + ", ".join(inline_secret_keys) + ")"
        )
    entry_id = str(id_factory())
    nonsecret_env = {
        key: value
        for key, value in spec.env_values.items()
        if key not in spec.secret_env_keys
    }
    entry: dict[str, Any] = {
        "id": entry_id,
        "name": name,
        "type": "stdio",
        "executionMode": execution_mode,
        "runtimeKind": runtime_kind(spec.argv),
        "readiness": {"summary": READINESS_SUMMARY},
        "command": {"argv": list(spec.argv)},
        "envKeys": list(spec.env_keys),
        "secretEnvKeys": list(spec.secret_env_keys),
    }
    if is_codex_delegate:
        entry["prerequisites"] = {"probes": ["codex-login-status"]}
    if nonsecret_env:
        entry["env"] = nonsecret_env
    _validate_new_docker_policy(entry)
    catalog["entries"][entry_id] = entry
    save_catalog(catalog)
    return dict(entry)


def resolve_entry(catalog: dict[str, Any], token: str) -> tuple[str, dict[str, Any]]:
    if token in catalog["entries"]:
        return token, catalog["entries"][token]
    matches = [
        (entry_id, entry)
        for entry_id, entry in catalog["entries"].items()
        if entry["name"] == token
    ]
    if len(matches) != 1:
        raise CatalogError(f"no catalog entry matches {token!r}")
    return matches[0]


def updated_catalog_entry(
    catalog: dict[str, Any], token: str, changes: dict[str, Any]
) -> tuple[str, dict[str, Any]]:
    """Build and validate an update without publishing it."""
    entry_id, current = resolve_entry(catalog, token)
    updated = dict(current)
    changes = dict(changes)
    if "name" in changes:
        name = changes.pop("name")
        if not isinstance(name, str) or not name:
            raise CatalogError("catalog entry name must be non-empty")
        if any(eid != entry_id and e["name"] == name for eid, e in catalog["entries"].items()):
            raise CatalogError(f"catalog entry named {name!r} already exists")
        updated["name"] = name
    if "argv" in changes:
        argv = changes.pop("argv")
        if not isinstance(argv, list) or not argv or any(not isinstance(v, str) for v in argv):
            raise CatalogError("updated argv must be a non-empty string list")
        updated["command"] = {"argv": list(argv)}
        updated["runtimeKind"] = runtime_kind(argv)
    for field in (
        "envKeys", "secretEnvKeys", "env", "type", "readiness", "prerequisites",
        "description",
    ):
        if field in changes:
            updated[field] = changes.pop(field)
    if changes:
        raise CatalogError(f"unsupported catalog update fields: {', '.join(sorted(changes))}")
    _validate_entry(entry_id, updated)
    _validate_new_docker_policy(updated)
    return entry_id, updated


def definition_changes_from_spec(
    name: str, spec_argv: list[str]
) -> dict[str, Any]:
    """Parse a CLI command spec into the complete runtime-affecting field set."""
    try:
        spec = parse_spec(spec_argv)
    except AddError as exc:
        raise CatalogError(str(exc)) from exc
    candidate = build_candidate(name, spec, "global", "")
    merged = MergedCandidate(
        candidate=candidate, import_id=compute_import_id(candidate)
    )
    is_codex_delegate = is_codex_delegate_argv(spec.argv)
    if not is_applicable(merged) and not is_codex_delegate:
        raise CatalogError(f"cannot update {name!r}: {not_applicable_reason(merged)}")
    inline_secret_keys = sorted(set(spec.env_values) & set(spec.secret_env_keys))
    if inline_secret_keys:
        raise CatalogError(
            "catalog update does not accept inline secret values; declare/pass "
            "them without a value (keys: "
            + ", ".join(inline_secret_keys)
            + ")"
        )
    nonsecret_env = {
        key: value
        for key, value in spec.env_values.items()
        if key not in spec.secret_env_keys
    }
    return {
        "argv": list(spec.argv),
        "envKeys": list(spec.env_keys),
        "secretEnvKeys": list(spec.secret_env_keys),
        "env": nonsecret_env,
        "prerequisites": (
            {"probes": ["codex-login-status"]} if is_codex_delegate else {}
        ),
    }


def update_entry(
    token: str,
    *,
    probe: Optional[object] = None,
    allow_tracked_codex_config: bool = False,
    allow_tracked_mcp_json: bool = False,
    **changes: Any,
) -> dict[str, Any]:
    """Transactionally update a definition while preserving identity/mode."""
    from .activation import update_catalog_entry

    return update_catalog_entry(
        token,
        changes,
        probe=probe,
        allow_tracked_codex_config=allow_tracked_codex_config,
        allow_tracked_mcp_json=allow_tracked_mcp_json,
    ).entry


def remove_entry(
    token: str,
    *,
    activation_count: int = 0,
    allow_tracked_codex_config: bool = False,
    allow_tracked_mcp_json: bool = False,
) -> dict[str, Any]:
    if activation_count:
        raise CatalogError("cannot remove a catalog entry while activations exist")
    from .activation import remove_catalog_entry

    return remove_catalog_entry(
        token,
        allow_tracked_codex_config=allow_tracked_codex_config,
        allow_tracked_mcp_json=allow_tracked_mcp_json,
    ).entry


def _activation_count(entry_id: str) -> int:
    # Local import avoids making catalog reads depend on activation rendering.
    from .activation import load_activations

    return sum(
        1
        for records in load_activations()["projects"].values()
        if entry_id in records
    )


def _stored_secret_keys(entry: dict[str, Any]) -> list[str]:
    """Return retained secret KEY NAMES for this entry, never their values."""
    from .profile import config_root
    from .secrets import load_secrets

    root = config_root()
    paths = [os.path.join(root, "secrets.json")]
    projects = os.path.join(root, "projects")
    try:
        paths.extend(
            os.path.join(projects, name)
            for name in os.listdir(projects)
            if name.endswith(".secrets.json")
        )
    except FileNotFoundError:
        pass

    keys: set[str] = set()
    # Legacy stores use the display name; identity-aware stores may use the ID.
    # Checking both also preserves the guard across a catalog rename.
    blocks = {
        entry["name"],
        entry["id"],
        str(entry.get("secretStoreKey") or entry["id"]),
    }
    for path in paths:
        if not os.path.isfile(path):
            continue
        store = load_secrets(path)
        servers = store.get("servers", {})
        if not isinstance(servers, dict):
            continue
        for block_name in blocks:
            block = servers.get(block_name)
            if isinstance(block, dict):
                keys.update(str(key) for key in block)
    return sorted(keys)


def mode_preview(token: str, mode: str) -> dict[str, Any]:
    """Build the secret-free, exact grant preview for the host UI."""
    if mode not in EXECUTION_MODES:
        raise CatalogError(
            "execution mode must be service-isolated or agent-trusted"
        )
    entry_id, entry = resolve_entry(load_catalog(), token)
    argv = list(entry["command"]["argv"])
    image: Optional[str] = None
    if entry["runtimeKind"] == "docker":
        from .install import _docker_image_from_argv

        image = _docker_image_from_argv(argv)
    preview = {
        "id": entry_id,
        "name": entry["name"],
        "currentMode": entry["executionMode"],
        "requestedMode": mode,
        "command": argv,
        "runtimeKind": entry["runtimeKind"],
        "access": list(
            AGENT_TRUSTED_ACCESS
            if mode == "agent-trusted"
            else SERVICE_ISOLATED_ACCESS
        ),
    }
    if image:
        preview["image"] = image
    return preview


def _host_mode_command() -> bool:
    """True only outside the canonical Boxa Container identity boundary."""
    return not os.path.isfile("/etc/boxa/identity.json")


def set_execution_mode(token: str, mode: str) -> dict[str, Any]:
    """Apply a host-authorized mode change after all immutable guards."""
    # The canonical identity is deliberately not test-overridable here: an
    # in-Container caller may consume a grant but cannot point this host grant
    # check at a fake missing sentinel.
    if not _host_mode_command():
        raise CatalogError(
            "MCP execution mode is host-only; run 'boxa mcp mode' on the host"
        )
    with mutation_lock():
        return _set_execution_mode_locked(token, mode)


def _set_execution_mode_locked(token: str, mode: str) -> dict[str, Any]:
    catalog = load_catalog()
    entry_id, entry = resolve_entry(catalog, token)
    if mode not in EXECUTION_MODES:
        raise CatalogError(
            "execution mode must be service-isolated or agent-trusted"
        )
    if entry["executionMode"] == mode:
        return dict(entry)
    count = _activation_count(entry_id)
    if count:
        raise CatalogError(
            f"cannot change execution mode while {count} activation(s) exist; "
            "deactivate it first"
        )
    if mode == "agent-trusted":
        declared = sorted(set(entry.get("secretEnvKeys", [])))
        retained = _stored_secret_keys(entry)
        incompatible = sorted(set(declared) | set(retained))
        if incompatible:
            raise CatalogError(
                "agent-trusted mode is incompatible with MCP secrets; remove "
                "these key names first: " + ", ".join(incompatible)
            )
        fixed_overrides = sorted(
            set(entry.get("env", {})) & AGENT_TRUSTED_FIXED_ENV_KEYS
        )
        if fixed_overrides:
            raise CatalogError(
                "agent-trusted mode has a fixed baseline; remove catalog "
                "overrides for: " + ", ".join(fixed_overrides)
            )
    updated = dict(entry)
    updated["executionMode"] = mode
    _validate_new_docker_policy(updated)
    catalog["entries"][entry_id] = updated
    save_catalog(catalog)
    return dict(updated)
