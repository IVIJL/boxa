"""Legacy catalog migration and shared MCP render cleanup (ADR 0028)."""

from __future__ import annotations

import hashlib
import json
import os
import re
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional

from . import activation, casfile
from .catalog import (
    EXECUTION_MODE,
    READINESS_SUMMARY,
    load_catalog,
    mutation_lock,
    runtime_kind,
    save_catalog,
)
from .launch_profile import claude_server_definition, rendered_name
from .profile import PROFILE_VERSION, config_root, global_profile_path, load_profile
from .providers.claude import render_target_path
from .providers.codex import default_config_path as codex_global_config_path
from .secrets import global_secrets_path, load_secrets, project_secrets_path, save_secrets


MIGRATION_VERSION = 1
CLEANUP_VERSION = 1
_NAMESPACE = uuid.UUID("eaf81ab8-f607-4ed0-a47a-e3898950acc9")
_BOXA_PREFIXES = ("boxa-", "devbox-")
_WRAPPER_COMMANDS = ("boxa-mcp-run", "devbox-mcp-run")
_CODEX_BEGIN = "# >>> boxa managed MCP servers >>>"
_CODEX_END = "# <<< boxa managed MCP servers <<<"


class MigrationError(RuntimeError):
    pass


def migration_path() -> str:
    return os.path.join(config_root(), "migration-v1.json")


def render_state_path() -> str:
    return os.path.join(config_root(), "claude-activation-render-state.json")


def legacy_render_state_path() -> str:
    return os.path.join(config_root(), "claude-render-state.json")


def render_target_marker_path() -> str:
    return os.path.join(config_root(), "claude-render-target.json")


def cleanup_marker_path() -> str:
    return os.path.join(config_root(), "shared-render-cleanup.json")


@dataclass
class LegacyDefinition:
    scope: str
    project: str
    name: str
    entry: dict[str, Any]
    source_path: str
    consumers: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class _JsonMember:
    key: str
    leading_start: int
    key_start: int
    key_end: int
    value_start: int
    value_end: int
    comma_after: Optional[int]


@dataclass(frozen=True)
class _JsonObject:
    start: int
    close: int
    members: tuple[_JsonMember, ...]


_JSON_DECODER = json.JSONDecoder()
_JSON_WHITESPACE = " \t\r\n"


def _canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _definition_key(name: str, entry: dict[str, Any]) -> str:
    definition = {key: value for key, value in entry.items() if key != "id"}
    return hashlib.sha256(_canonical([name, definition]).encode()).hexdigest()


def _legacy_fingerprint(entry: dict[str, Any]) -> str:
    return hashlib.sha256(_canonical(entry).encode()).hexdigest()


def _catalog_entry(name: str, legacy: dict[str, Any]) -> dict[str, Any]:
    command = legacy.get("command")
    argv = command.get("argv") if isinstance(command, dict) else None
    if not isinstance(argv, list) or not argv or any(not isinstance(v, str) for v in argv):
        raise MigrationError(f"legacy MCP definition {name!r} has no valid command.argv")
    env_keys = legacy.get("envKeys", [])
    secret_keys = legacy.get("secretEnvKeys", [])
    env = legacy.get("env", {})
    if (
        not isinstance(env_keys, list)
        or any(not isinstance(v, str) for v in env_keys)
        or not isinstance(secret_keys, list)
        or any(not isinstance(v, str) for v in secret_keys)
        or not isinstance(env, dict)
        or any(not isinstance(k, str) or not isinstance(v, str) for k, v in env.items())
    ):
        raise MigrationError(f"legacy MCP definition {name!r} has malformed environment data")
    if set(env) & set(secret_keys):
        raise MigrationError(f"legacy MCP definition {name!r} stores a secret value inline")
    entry: dict[str, Any] = {
        "name": name,
        "type": str(legacy.get("type") or "stdio"),
        "executionMode": EXECUTION_MODE,
        "runtimeKind": runtime_kind(argv),
        "readiness": {"summary": READINESS_SUMMARY},
        "command": {"argv": list(argv)},
        "envKeys": sorted(set(env_keys)),
        "secretEnvKeys": sorted(set(secret_keys)),
    }
    if env:
        entry["env"] = dict(sorted(env.items()))
    return entry


def _load_legacy_profile(path: str) -> dict[str, Any]:
    try:
        profile = load_profile(path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise MigrationError(f"cannot migrate malformed legacy profile {path}: {exc}") from exc
    if profile.get("version") != PROFILE_VERSION or not isinstance(profile.get("servers"), dict):
        raise MigrationError(f"unsupported legacy profile schema in {path}")
    return profile


def _project_profiles() -> list[tuple[str, str]]:
    root = os.path.join(config_root(), "projects")
    try:
        names = sorted(os.listdir(root))
    except FileNotFoundError:
        return []
    result: list[tuple[str, str]] = []
    for name in names:
        if not name.endswith(".json") or name.endswith(".secrets.json"):
            continue
        path = os.path.join(root, name)
        profile = _load_legacy_profile(path)
        project = profile.get("projectKey")
        if not isinstance(project, str) or not project or not os.path.isabs(project):
            raise MigrationError(f"legacy Project profile has no canonical projectKey: {path}")
        result.append((path, activation.canonical_project(project)))
    return result


def _is_managed(name: str) -> bool:
    return name.startswith(_BOXA_PREFIXES)


def _rendered_name(name: str) -> str:
    return f"boxa-{name}"


def _server_definition_matches(value: Any, project: str, server: str) -> bool:
    if not isinstance(value, dict) or value.get("command") not in _WRAPPER_COMMANDS:
        return False
    args = value.get("args")
    return isinstance(args, list) and (
        args == ["--project", project, server]
        or ("--project" in args and project in args and server in args)
    )


def _claude_rendered(project: str, rendered_name: str, server: str) -> bool:
    paths = [activation.claude_config_path(project), render_target_path()]
    for path in paths:
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except FileNotFoundError:
            continue
        except (OSError, ValueError) as exc:
            raise MigrationError(f"cannot inspect rendered Claude config {path}: {exc}") from exc
        if not isinstance(data, dict):
            continue
        candidates = [data.get("mcpServers", {})]
        record = data.get("projects", {}).get(project, {}) if isinstance(data.get("projects"), dict) else {}
        if isinstance(record, dict):
            candidates.append(record.get("mcpServers", {}))
        if any(
            isinstance(block, dict)
            and _server_definition_matches(block.get(rendered_name), project, server)
            for block in candidates
        ):
            return True
    return False


def _codex_rendered(project: str, rendered_name: str, server: str) -> bool:
    try:
        import tomllib
        with open(activation.codex_config_path(project), "rb") as fh:
            data = tomllib.load(fh)
    except FileNotFoundError:
        return False
    except (OSError, ValueError) as exc:
        raise MigrationError(f"cannot inspect rendered Codex config for {project}: {exc}") from exc
    table = data.get("mcp_servers", {}).get(rendered_name) if isinstance(data, dict) else None
    return _server_definition_matches(table, project, server)


def _inventory() -> list[LegacyDefinition]:
    definitions: list[LegacyDefinition] = []
    global_path = global_profile_path()
    if os.path.isfile(global_path):
        profile = _load_legacy_profile(global_path)
        for name, value in sorted(profile["servers"].items()):
            if not isinstance(value, dict) or "command" not in value:
                if isinstance(value, dict) and value.get("enabled") is False:
                    continue
                raise MigrationError(f"malformed legacy MCP definition {name!r} in {global_path}")
            definitions.append(LegacyDefinition("global", "", str(name), _catalog_entry(str(name), value), global_path))
    for path, project in _project_profiles():
        profile = _load_legacy_profile(path)
        for name, value in sorted(profile["servers"].items()):
            if not isinstance(value, dict) or "command" not in value:
                if isinstance(value, dict) and value.get("enabled") is False:
                    continue
                raise MigrationError(f"malformed legacy MCP definition {name!r} in {path}")
            name = str(name)
            consumers: list[str] = []
            rendered = _rendered_name(name)
            if value.get("enabled", True) is not False:
                if _claude_rendered(project, rendered, name):
                    consumers.append("claude")
                if _codex_rendered(project, rendered, name):
                    consumers.append("codex")
            definitions.append(LegacyDefinition("project", project, name, _catalog_entry(name, value), path, consumers))
    return definitions


def _unique_name(base: str, fingerprint: str, used: set[str]) -> str:
    if base not in used:
        return base
    candidate = f"{base}-migrated-{fingerprint[:8]}"
    suffix = 2
    while candidate in used:
        candidate = f"{base}-migrated-{fingerprint[:8]}-{suffix}"
        suffix += 1
    return candidate


def _load_manifest() -> Optional[dict[str, Any]]:
    path = migration_path()
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.load(fh)
    except (OSError, ValueError) as exc:
        raise MigrationError(f"cannot read migration audit manifest {path}: {exc}") from exc
    if not isinstance(value, dict) or value.get("version") != MIGRATION_VERSION:
        raise MigrationError(f"unsupported migration audit manifest: {path}")
    if value.get("status") not in {"prepared", "complete"}:
        raise MigrationError(f"malformed migration audit manifest: {path}")
    return value


def _load_render_state() -> dict[str, Any]:
    path = render_state_path()
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.load(fh)
    except FileNotFoundError:
        return {"projects": {}, "seeded": {}}
    except (OSError, ValueError) as exc:
        raise MigrationError(f"cannot read legacy MCP render state {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise MigrationError(f"malformed legacy MCP render state: {path}")
    projects = value.get("projects", {})
    seeded = value.get("seeded", {})
    if not isinstance(projects, dict) or not isinstance(seeded, dict):
        raise MigrationError(f"malformed legacy MCP render state: {path}")
    if any(
        not isinstance(project, str)
        or not (
            isinstance(definitions, list)
            and all(isinstance(name, str) for name in definitions)
            or isinstance(definitions, dict)
            and all(
                isinstance(name, str) and isinstance(definition, dict)
                for name, definition in definitions.items()
            )
        )
        for project, definitions in projects.items()
    ) or any(
        not isinstance(project, str)
        or not isinstance(names, list)
        or any(not isinstance(name, str) for name in names)
        for project, names in seeded.items()
    ):
        raise MigrationError(f"malformed legacy MCP render state: {path}")
    return {"projects": projects, "seeded": seeded}


def _cleanup_complete() -> bool:
    try:
        with open(cleanup_marker_path(), encoding="utf-8") as fh:
            value = json.load(fh)
    except FileNotFoundError:
        return False
    except (OSError, ValueError) as exc:
        raise MigrationError(f"cannot read shared-render cleanup marker: {exc}") from exc
    return isinstance(value, dict) and value.get("version") == CLEANUP_VERSION


def _skip_json_whitespace(text: str, position: int) -> int:
    while position < len(text) and text[position] in _JSON_WHITESPACE:
        position += 1
    return position


def _scan_json_object(text: str, start: int) -> _JsonObject:
    if start >= len(text) or text[start] != "{":
        raise ValueError("JSON value is not an object")
    members: list[_JsonMember] = []
    position = start + 1
    while True:
        leading_start = position
        position = _skip_json_whitespace(text, position)
        if position >= len(text):
            raise ValueError("unterminated JSON object")
        if text[position] == "}":
            return _JsonObject(start, position, tuple(members))
        key_start = position
        key, key_end = _JSON_DECODER.raw_decode(text, position)
        if not isinstance(key, str):
            raise ValueError("JSON object member name is not a string")
        position = _skip_json_whitespace(text, key_end)
        if position >= len(text) or text[position] != ":":
            raise ValueError("JSON object member has no colon")
        value_start = _skip_json_whitespace(text, position + 1)
        _value, value_end = _JSON_DECODER.raw_decode(text, value_start)
        position = _skip_json_whitespace(text, value_end)
        comma_after: Optional[int] = None
        if position < len(text) and text[position] == ",":
            comma_after = position
            position += 1
        elif position >= len(text) or text[position] != "}":
            raise ValueError("JSON object member has no separator")
        members.append(_JsonMember(key, leading_start, key_start, key_end, value_start, value_end, comma_after))


def _delete_json_member(text: str, object_start: int, index: int) -> str:
    scanned = _scan_json_object(text, object_start)
    member = scanned.members[index]
    if len(scanned.members) == 1:
        return text[:scanned.start + 1] + text[scanned.close:]
    if index == 0:
        if member.comma_after is None:
            raise ValueError("first JSON member has no following comma")
        return text[:member.leading_start] + text[member.comma_after + 1:]
    previous = scanned.members[index - 1]
    return text[:previous.value_end] + text[member.value_end:]


def _remove_mcp_members(
    original: str, definitions: dict[str, dict[str, Any]]
) -> tuple[str, set[str], set[str]]:
    try:
        parsed = json.loads(original)
    except (TypeError, ValueError) as exc:
        # Without a recorded definition Boxa has no ownership claim on this
        # malformed file, so its foreign content must remain untouched.
        if not definitions:
            return original, set(), set()
        raise MigrationError("cannot clean malformed .mcp.json") from exc
    if not isinstance(parsed, dict):
        # Same ownership rule as the malformed case: a foreign non-object
        # top level is only an error while Boxa still owns definitions here.
        if not definitions:
            return original, set(), set()
        raise MigrationError("cannot clean .mcp.json that is not an object")
    block = parsed.get("mcpServers")
    existing = set(block) if isinstance(block, dict) else set()
    if not definitions:
        return original, set(), existing
    effective = (
        {
            name
            for name, definition in definitions.items()
            if block.get(name) == definition
        }
        if isinstance(block, dict)
        else set()
    )
    if not effective:
        return original, set(), existing
    try:
        text = original
        root = _scan_json_object(text, _skip_json_whitespace(text, 0))
        top = next(member for member in root.members if member.key == "mcpServers")
        nested = _scan_json_object(text, top.value_start)
        if len({member.key for member in nested.members}) != len(nested.members):
            raise ValueError("duplicate MCP server names")
        for name in effective:
            root = _scan_json_object(text, _skip_json_whitespace(text, 0))
            top = next(member for member in root.members if member.key == "mcpServers")
            nested = _scan_json_object(text, top.value_start)
            index = next(i for i, member in enumerate(nested.members) if member.key == name)
            text = _delete_json_member(text, nested.start, index)
        data = json.loads(text)
        remaining = data.get("mcpServers")
        if remaining == {}:
            root = _scan_json_object(text, _skip_json_whitespace(text, 0))
            index = next(i for i, member in enumerate(root.members) if member.key == "mcpServers")
            text = _delete_json_member(text, root.start, index)
        if json.loads(text) == {}:
            return "", effective, existing
        return text, effective, existing
    except (StopIteration, TypeError, ValueError) as exc:
        raise MigrationError("cannot surgically clean .mcp.json") from exc


def _replace_top_level_value(original: str, key: str, value: Any) -> str:
    root = _scan_json_object(original, _skip_json_whitespace(original, 0))
    matches = [member for member in root.members if member.key == key]
    if len(matches) != 1:
        raise ValueError(f"expected one {key!r} member")
    member = matches[0]
    rendered = json.dumps(value, separators=(",", ":"))
    return original[:member.value_start] + rendered + original[member.value_end:]


def _remove_approval_seeds(original: str, names: set[str]) -> str:
    if not names:
        return original
    try:
        data = json.loads(original)
    except ValueError as exc:
        raise MigrationError("cannot clean malformed Claude Project settings") from exc
    if not isinstance(data, dict):
        raise MigrationError("cannot clean Claude Project settings that is not an object")
    text = original
    for key in ("enabledMcpjsonServers", "disabledMcpjsonServers"):
        current = data.get(key)
        if current is None:
            continue
        if not isinstance(current, list) or any(not isinstance(name, str) for name in current):
            raise MigrationError(f"cannot clean malformed Claude Project settings member {key}")
        retained = [name for name in current if name not in names]
        if retained != current:
            try:
                text = _replace_top_level_value(text, key, retained)
            except (StopIteration, TypeError, ValueError) as exc:
                raise MigrationError("cannot surgically clean Claude Project settings") from exc
    return text


def _strip_codex_region(text: str, path: str) -> str:
    begins = [match.start() for match in re.finditer(re.escape(_CODEX_BEGIN), text)]
    ends = [match.start() for match in re.finditer(re.escape(_CODEX_END), text)]
    if not begins and not ends:
        return text
    if len(begins) != 1 or len(ends) != 1 or begins[0] >= ends[0]:
        raise MigrationError(f"malformed Boxa managed region in Codex config: {path}")
    begin = begins[0]
    if begin and text[begin - 1] == "\n":
        begin -= 1
    end = ends[0] + len(_CODEX_END)
    if end < len(text) and text[end] == "\n":
        end += 1
    return text[:begin] + text[end:]


_TABLE_HEADER = re.compile(
    r'''^\s*\[\s*(?:mcp_servers\s*\.\s*"(?P<dquoted>(?:\\.|[^"\\])+)"|mcp_servers\s*\.\s*(?P<bare>[A-Za-z0-9_.\-]+)|"mcp_servers\.(?P<quoted>(?:\\.|[^"\\])+)"\s*)\]\s*(?:\#.*)?$'''
)
_ANY_HEADER = re.compile(r"^\s*\[\[?[^\]]+\]\]?\s*(?:#.*)?$")


def _strip_legacy_codex_tables(text: str) -> str:
    out: list[str] = []
    lines = text.splitlines(keepends=True)
    index = 0
    while index < len(lines):
        match = _TABLE_HEADER.match(lines[index])
        name = None if match is None else match.group("dquoted") or match.group("bare") or match.group("quoted")
        if name is not None and _is_managed(name):
            index += 1
            while index < len(lines) and not _ANY_HEADER.match(lines[index]):
                index += 1
            continue
        out.append(lines[index])
        index += 1
    return "".join(out)


def _read_text(path: str) -> Optional[str]:
    try:
        with open(path, encoding="utf-8", newline="") as fh:
            return fh.read()
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError) as exc:
        raise MigrationError(f"cannot read migration target {path}: {exc}") from exc


def _swap_text(path: str, expected: str, rendered: str) -> None:
    if rendered == expected:
        return
    try:
        if not rendered:
            casfile.remove(path, casfile.preimage(expected))
        else:
            casfile.swap(
                path,
                casfile.preimage(expected),
                rendered,
                writer=lambda target, payload: casfile.atomic_text(target, payload),
            )
    except casfile.WriteError as exc:
        raise MigrationError(str(exc)) from exc


def _remove_exclude_rules(path: str, rules: set[str]) -> bool:
    existing = _read_text(path)
    if existing is None:
        return False
    lines = existing.splitlines(keepends=True)
    rendered = "".join(line for line in lines if line.rstrip("\r\n") not in rules)
    if rendered == existing:
        return False
    _swap_text(path, existing, rendered)
    return True


def _tracked(project: str, path: str) -> tuple[bool, Optional[tuple[str, str, str]]]:
    try:
        git_paths = activation._claude_git_paths(project, path=path)
        return (
            git_paths is not None and activation._codex_is_tracked(project, git_paths[0]),
            git_paths,
        )
    except activation.ActivationError as exc:
        raise MigrationError(str(exc)) from exc


def _cleanup_projects(state: dict[str, Any], activations: dict[str, Any], manifest: Optional[dict[str, Any]]) -> list[str]:
    projects = set(state["projects"]) | set(state["seeded"]) | set(activations.get("projects", {}))
    if manifest is not None:
        projects.update(
            row["project"]
            for row in manifest.get("definitions", [])
            if isinstance(row, dict) and isinstance(row.get("project"), str)
        )
    return sorted(projects)


def _recorded_mcp_definitions(
    state: dict[str, Any],
    project: str,
    activations: dict[str, Any],
    catalog: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    recorded = state["projects"].get(project, {})
    if isinstance(recorded, dict):
        return recorded

    # Legacy state recorded names only. Reconstruct an exact definition only
    # while the matching durable activation and catalog identity still exist;
    # otherwise ownership is ambiguous and cleanup must preserve the member.
    names = set(recorded)
    definitions: dict[str, dict[str, Any]] = {}
    records = activations.get("projects", {}).get(project, {})
    for entry_id, record in records.items():
        entry = catalog.get("entries", {}).get(entry_id)
        if (
            not isinstance(record, dict)
            or record.get("enabled", True) is False
            or "claude" not in record.get("consumers", [])
            or not isinstance(entry, dict)
        ):
            continue
        name = rendered_name(entry["name"])
        if name in names:
            definitions[name] = claude_server_definition(entry_id, project, entry)
    return definitions


def _cleanup_shared_renders(
    activations: dict[str, Any],
    manifest: Optional[dict[str, Any]],
    *,
    allow_tracked_mcp_json: bool,
    allow_tracked_codex_config: bool,
) -> bool:
    if _cleanup_complete():
        return False
    state = _load_render_state()
    catalog = load_catalog()
    projects = _cleanup_projects(state, activations, manifest)
    plans: list[tuple[str, str, str]] = []
    exclude_plans: dict[str, set[str]] = {}
    refusals: list[str] = []
    unavailable_projects: list[str] = []
    for project in projects:
        if not os.path.isdir(project):
            unavailable_projects.append(project)
            continue
        rendered_definitions = _recorded_mcp_definitions(
            state, project, activations, catalog
        )
        rendered_names = set(state["projects"].get(project, []))
        seeded_names = set(state["seeded"].get(project, []))
        mcp_path = activation.claude_config_path(project)
        existing = _read_text(mcp_path)
        removed_mcp_names: set[str] = set()
        existing_mcp_names: set[str] = set()
        if existing is not None:
            rendered, removed_mcp_names, existing_mcp_names = _remove_mcp_members(
                existing, rendered_definitions
            )
            if rendered != existing:
                tracked, git_paths = _tracked(project, mcp_path)
                if tracked and not allow_tracked_mcp_json:
                    refusals.append(mcp_path)
                else:
                    plans.append((mcp_path, existing, rendered))
        if rendered_names:
            _tracked_state, git_paths = _tracked(project, mcp_path)
            if git_paths is not None:
                exclude_plans.setdefault(git_paths[1], set()).add("/" + git_paths[0])
        settings_path = activation.claude_settings_path(project)
        existing = _read_text(settings_path)
        if existing is not None:
            removable_seeds = seeded_names - (
                existing_mcp_names - removed_mcp_names
            )
            rendered = _remove_approval_seeds(existing, removable_seeds)
            if rendered != existing:
                tracked, git_paths = _tracked(project, settings_path)
                if tracked and not allow_tracked_mcp_json:
                    refusals.append(settings_path)
                else:
                    plans.append((settings_path, existing, rendered))
        if seeded_names:
            _tracked_state, git_paths = _tracked(project, settings_path)
            if git_paths is not None:
                exclude_plans.setdefault(git_paths[1], set()).add("/" + git_paths[0])
        codex_path = activation.codex_config_path(project)
        existing = _read_text(codex_path)
        if existing is not None:
            rendered = _strip_codex_region(existing, codex_path)
            if rendered != existing:
                tracked, git_paths = _tracked(project, codex_path)
                if tracked and not allow_tracked_codex_config:
                    refusals.append(codex_path)
                else:
                    plans.append((codex_path, existing, rendered))
                if git_paths is not None:
                    exclude_plans.setdefault(git_paths[1], set()).add("/" + git_paths[0])
    if refusals:
        flags = []
        if any(path.endswith(".codex/config.toml") for path in refusals):
            flags.append("--allow-tracked-codex-config")
        if any(not path.endswith(".codex/config.toml") for path in refusals):
            flags.append("--allow-tracked-mcp-json")
        raise MigrationError(
            "tracked MCP cleanup requires " + " and ".join(flags) + " for: " + ", ".join(sorted(refusals))
        )
    changed = bool(plans or exclude_plans)
    with casfile.transaction() as txn:
        try:
            for path, existing, rendered in plans:
                _swap_text(path, existing, rendered)
            for path, rules in exclude_plans.items():
                changed = _remove_exclude_rules(path, rules) or changed
            if not unavailable_projects:
                for path in (render_state_path(), legacy_render_state_path(), render_target_marker_path()):
                    try:
                        existing = casfile.read_bytes(path)
                    except casfile.WriteError as exc:
                        raise MigrationError(str(exc)) from exc
                    if existing is not None:
                        casfile.remove(path, existing)
                        changed = True
                activation._atomic_json(cleanup_marker_path(), {"version": CLEANUP_VERSION}, 0o600)
        except Exception as exc:
            _compensate(txn, "shared MCP render cleanup", exc)
    return changed


def _load_legacy_claude_config() -> Optional[dict[str, Any]]:
    path = render_target_path()
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        raise MigrationError(f"cannot inspect rendered Claude config: {exc}") from exc
    if not isinstance(data, dict):
        raise MigrationError(f"Claude config is not an object: {path}")
    return data


def _remove_legacy_claude_entries() -> bool:
    path = render_target_path()
    data = _load_legacy_claude_config()
    if data is None:
        return False
    existing = casfile.read_bytes(path)
    changed = False
    block = data.get("mcpServers")
    if isinstance(block, dict):
        retained = {name: value for name, value in block.items() if not _is_managed(name)}
        if retained != block:
            data["mcpServers"] = retained
            changed = True
    projects = data.get("projects")
    if isinstance(projects, dict):
        for record in projects.values():
            if not isinstance(record, dict):
                continue
            servers = record.get("mcpServers")
            if not isinstance(servers, dict):
                continue
            removed = {name for name in servers if _is_managed(name)}
            if removed:
                record["mcpServers"] = {name: value for name, value in servers.items() if name not in removed}
                changed = True
            disabled = record.get("disabledMcpServers")
            if isinstance(disabled, list):
                retained_disabled = [name for name in disabled if name not in removed]
                if retained_disabled != disabled:
                    record["disabledMcpServers"] = retained_disabled
                    changed = True
    if changed:
        casfile.swap_json(path, existing, data, 0o600)
    return changed


def _remove_legacy_global_codex_entries() -> bool:
    path = codex_global_config_path()
    existing = _read_text(path)
    if existing is None:
        return False
    rendered = _strip_legacy_codex_tables(existing)
    if rendered == existing:
        return False
    _swap_text(path, existing, rendered)
    return True


def _compensate(txn: casfile.Transaction, label: str, exc: BaseException) -> None:
    errors, concurrent = txn.rollback()
    problems = list(errors)
    if concurrent:
        problems.append("concurrent writes left in place for " + ", ".join(concurrent))
    if problems:
        raise MigrationError(f"{label} failed and rollback was incomplete: " + "; ".join(problems)) from exc
    conflict = casfile.concurrent_conflict(exc)
    if conflict is not None:
        raise MigrationError(f"{label} refused: {conflict.path} changed on disk; nothing was written — re-run the command") from exc
    if isinstance(exc, MigrationError):
        raise exc
    raise MigrationError(f"{label} failed: {exc}") from exc


def _purge_migrated_legacy(
    manifest: dict[str, Any], catalog: dict[str, Any]
) -> tuple[dict[str, Any], bool]:
    """Remove only manifest-recorded legacy definitions and secret blocks."""
    if manifest.get("legacyRetained") is False:
        return dict(manifest), False

    definitions = [
        row
        for row in manifest.get("definitions", [])
        if isinstance(row, dict)
    ]
    profile_rows: dict[str, list[dict[str, Any]]] = {}
    secret_rows: dict[str, list[dict[str, Any]]] = {}
    for row in definitions:
        source = row.get("source")
        name = row.get("legacyName")
        if not isinstance(source, str) or not isinstance(name, str):
            raise MigrationError("malformed migration audit definition")
        profile_rows.setdefault(source, []).append(row)
        scope = row.get("scope")
        if scope == "global":
            secret_path = global_secrets_path()
        elif scope == "project" and isinstance(row.get("project"), str):
            secret_path = project_secrets_path(str(row["project"]))
        else:
            raise MigrationError("malformed migration audit definition scope")
        secret_rows.setdefault(secret_path, []).append(row)

    profile_updates: dict[str, tuple[bytes, Optional[dict[str, Any]]]] = {}
    purge_rows: set[int] = set()
    legacy_retained = False
    for path, rows in profile_rows.items():
        original = casfile.read_bytes(path)
        if original is None:
            purge_rows.update(id(row) for row in rows)
            continue
        profile = _load_legacy_profile(path)
        servers = profile["servers"]
        changed = False
        for row in rows:
            name = str(row["legacyName"])
            current = servers.get(name)
            if current is None:
                purge_rows.add(id(row))
                continue
            fingerprint = row.get("legacyFingerprint")
            if not isinstance(fingerprint, str) or not isinstance(current, dict):
                legacy_retained = True
                continue
            try:
                current_entry = _catalog_entry(name, current)
            except MigrationError:
                legacy_retained = True
                continue
            if _legacy_fingerprint(current_entry) != fingerprint:
                legacy_retained = True
                continue
            del servers[name]
            purge_rows.add(id(row))
            changed = True
        if servers:
            legacy_retained = True
        if changed:
            profile_updates[path] = (original, profile if servers else None)

    secret_updates: dict[str, tuple[bytes, Optional[dict[str, Any]]]] = {}
    for path, rows in secret_rows.items():
        original = casfile.read_bytes(path)
        if original is None:
            continue
        try:
            store = load_secrets(path)
        except (OSError, ValueError) as exc:
            raise MigrationError(
                f"cannot read legacy MCP secret store {path}: {exc}"
            ) from exc
        servers = store["servers"]
        changed = False
        for row in rows:
            if id(row) not in purge_rows:
                continue
            name = str(row["legacyName"])
            source_block = servers.get(name)
            if source_block is None:
                continue
            if not source_block:
                del servers[name]
                changed = True
                continue
            entry_id = str(row.get("catalogId") or "")
            entry = catalog.get("entries", {}).get(entry_id)
            if not isinstance(entry, dict):
                raise MigrationError(
                    f"migration audit references missing catalog entry {entry_id!r}"
                )
            target_key = str(entry.get("secretStoreKey") or entry_id)
            target_block = servers.get(target_key)
            if target_block is not None and target_block != source_block:
                raise MigrationError(
                    f"cannot safely purge legacy credentials for {name!r}: "
                    f"stable identity {entry_id!r} has different credentials in {path}"
                )
            servers[target_key] = dict(source_block)
            if target_key != name:
                del servers[name]
            changed = True
        if changed:
            secret_updates[path] = (original, store if servers else None)

    updated = dict(manifest)
    updated["legacyRetained"] = legacy_retained
    updated["legacyPurged"] = True
    manifest_changed = updated != manifest
    changed = bool(profile_updates or secret_updates or manifest_changed)
    if not changed:
        return updated, False
    with casfile.transaction() as txn:
        try:
            for path, (original, profile) in profile_updates.items():
                if profile is None:
                    casfile.remove(path, original)
                else:
                    casfile.swap_json(path, original, profile, 0o644)
            for path, (original, store) in secret_updates.items():
                if store is None:
                    casfile.remove(path, original)
                else:
                    casfile.swap_json(path, original, store, 0o600)
            if manifest_changed:
                activation._atomic_json(migration_path(), updated, 0o600)
        except Exception as exc:
            _compensate(txn, "legacy MCP profile purge", exc)
    return updated, True


def migrate_legacy(
    *,
    allow_tracked_mcp_json: bool = False,
    allow_tracked_codex_config: bool = False,
) -> dict[str, Any]:
    """Migrate legacy definitions, then remove every recorded shared render."""
    with mutation_lock():
        prior_manifest = _load_manifest()
        catalog = load_catalog()
        activations = activation.load_activations()
        if prior_manifest is not None and prior_manifest.get("status") == "complete":
            cleanup_changed = _cleanup_shared_renders(
                activations,
                prior_manifest,
                allow_tracked_mcp_json=allow_tracked_mcp_json,
                allow_tracked_codex_config=allow_tracked_codex_config,
            )
            purged_manifest, purge_changed = _purge_migrated_legacy(
                prior_manifest, catalog
            )
            result = dict(purged_manifest)
            result["changed"] = cleanup_changed or purge_changed
            return result

        legacy = _inventory()
        if not legacy and prior_manifest is None:
            cleanup_changed = _cleanup_shared_renders(
                activations,
                None,
                allow_tracked_mcp_json=allow_tracked_mcp_json,
                allow_tracked_codex_config=allow_tracked_codex_config,
            )
            return {
                "version": MIGRATION_VERSION,
                "status": "not-needed",
                "legacyRetained": True,
                "definitions": [],
                "changed": cleanup_changed,
            }

        used_names = {entry["name"] for entry in catalog["entries"].values()}
        by_definition = {
            _definition_key(entry["name"], entry): entry_id
            for entry_id, entry in catalog["entries"].items()
        }
        prepared_by_source = {
            (row.get("scope"), row.get("project", ""), row.get("legacyName"), row.get("source")): row
            for row in (prior_manifest or {}).get("definitions", [])
            if isinstance(row, dict)
        }
        audit: list[dict[str, Any]] = []
        secret_updates: dict[str, dict[str, Any]] = {}
        for item in sorted(legacy, key=lambda value: (value.name.casefold(), value.scope, value.project, value.source_path)):
            original_key = _definition_key(item.name, item.entry)
            prepared = prepared_by_source.get((item.scope, item.project, item.name, item.source_path))
            if prepared is not None:
                item.consumers = [value for value in prepared.get("consumers", []) if value in {"claude", "codex"}]
            deterministic_id = str(uuid.uuid5(_NAMESPACE, original_key))
            entry_id = str(prepared.get("catalogId")) if prepared is not None else by_definition.get(original_key)
            if entry_id not in catalog["entries"]:
                entry_id = by_definition.get(original_key)
            conflict = bool(prepared and prepared.get("nameConflict"))
            if entry_id is None:
                fingerprint = hashlib.sha256(_canonical(item.entry).encode()).hexdigest()
                prepared_name = prepared.get("catalogName") if prepared is not None else None
                name = str(prepared_name) if isinstance(prepared_name, str) and prepared_name else _unique_name(item.name, fingerprint, used_names)
                conflict = name != item.name
                entry = dict(item.entry)
                entry["name"] = name
                entry_id = deterministic_id
                if entry_id in catalog["entries"] and catalog["entries"][entry_id] != {"id": entry_id, **entry}:
                    raise MigrationError("deterministic migration identity collision")
                entry["id"] = entry_id
                entry["secretStoreKey"] = entry_id
                catalog["entries"][entry_id] = entry
                by_definition[original_key] = entry_id
                used_names.add(name)
            entry = catalog["entries"][entry_id]
            if item.scope == "project" and item.consumers:
                records = activations["projects"].setdefault(item.project, {})
                prior = records.get(entry_id)
                consumers = sorted(set(item.consumers) | set(prior.get("consumers", []) if isinstance(prior, dict) else []))
                records[entry_id] = {"catalogId": entry_id, "consumers": consumers, "enabled": True}
            if item.scope == "project" and entry.get("secretEnvKeys"):
                secret_path = project_secrets_path(item.project)
                if secret_path not in secret_updates:
                    try:
                        secret_updates[secret_path] = load_secrets(secret_path)
                    except (OSError, ValueError) as exc:
                        raise MigrationError(f"cannot read legacy MCP secret store {secret_path}: {exc}") from exc
                store = secret_updates[secret_path]
                source_block = store["servers"].get(item.name)
                target_key = str(entry.get("secretStoreKey") or entry_id)
                target_block = store["servers"].get(target_key)
                if source_block is not None:
                    if target_block is not None and target_block != source_block:
                        raise MigrationError(f"cannot safely map legacy credentials for {item.name!r} to stable identity {entry_id!r} in {secret_path}")
                    store["servers"][target_key] = dict(source_block)
            audit.append({
                "scope": item.scope,
                **({"project": item.project} if item.project else {}),
                "legacyName": item.name,
                "catalogId": entry_id,
                "catalogName": entry["name"],
                "consumers": list(item.consumers),
                "nameConflict": conflict,
                "source": item.source_path,
                "legacyFingerprint": _legacy_fingerprint(item.entry),
            })

        manifest = {
            "version": MIGRATION_VERSION,
            "status": "prepared",
            "legacyRetained": True,
            "definitions": audit,
        }
        with casfile.transaction() as txn:
            try:
                activation._atomic_json(migration_path(), manifest, 0o600)
                save_catalog(catalog)
                for path, store in secret_updates.items():
                    save_secrets(path, store)
                activation.save_activation_store(activations)
                _remove_legacy_claude_entries()
                _remove_legacy_global_codex_entries()
                activation.refresh_runtime(activations)
                manifest["status"] = "complete"
                activation._atomic_json(migration_path(), manifest, 0o600)
            except Exception as exc:
                _compensate(txn, "migration", exc)
        _cleanup_changed = _cleanup_shared_renders(
            activations,
            manifest,
            allow_tracked_mcp_json=allow_tracked_mcp_json,
            allow_tracked_codex_config=allow_tracked_codex_config,
        )
        purged_manifest, _purge_changed = _purge_migrated_legacy(manifest, catalog)
        result = dict(purged_manifest)
        result["changed"] = True
        return result
