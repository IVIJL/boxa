"""Legacy MCP profile -> stable-ID catalog migration (ADR 0021, issue 08)."""

from __future__ import annotations

import hashlib
import json
import os
import tomllib
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional

from . import activation
from .catalog import (
    EXECUTION_MODE,
    READINESS_SUMMARY,
    load_catalog,
    mutation_lock,
    runtime_kind,
    save_catalog,
)
from . import casfile
from .profile import PROFILE_VERSION, config_root, global_profile_path, load_profile
from .providers.claude import render_target_path
from .providers.codex import default_config_path as codex_global_config_path
from .render import WRAPPER_COMMAND, build_render_plan, is_managed_or_legacy
from .secrets import load_secrets, project_secrets_path, save_secrets
from .writer import _strip_boxa_tables, _swap_write


MIGRATION_VERSION = 1
_NAMESPACE = uuid.UUID("eaf81ab8-f607-4ed0-a47a-e3898950acc9")

# ADR 0022 retires ~/.claude/.claude.json as a render target. That upgrade is
# independent of the ADR 0021 legacy-profile migration, so it carries its own
# durable marker: an install whose legacy manifest is already `complete` (or
# that never had legacy profiles at all) must still receive it exactly once.
CLAUDE_RENDER_TARGET = "project-mcp-json"


class MigrationError(RuntimeError):
    pass


def migration_path() -> str:
    return os.path.join(config_root(), "migration-v1.json")


def render_target_marker_path() -> str:
    return os.path.join(config_root(), "claude-render-target.json")


@dataclass
class LegacyDefinition:
    scope: str
    project: str
    name: str
    entry: dict[str, Any]
    source_path: str
    consumers: list[str] = field(default_factory=list)


def _canonical(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _definition_key(name: str, entry: dict[str, Any]) -> str:
    definition = {key: value for key, value in entry.items() if key != "id"}
    return hashlib.sha256(_canonical([name, definition]).encode()).hexdigest()


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


def _load_legacy_profile(path: str) -> dict[str, Any]:
    try:
        profile = load_profile(path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise MigrationError(f"cannot migrate malformed legacy profile {path}: {exc}") from exc
    if profile.get("version") != PROFILE_VERSION or not isinstance(profile.get("servers"), dict):
        raise MigrationError(f"unsupported legacy profile schema in {path}")
    return profile


def _claude_rendered(project: str, rendered_name: str, server: str) -> bool:
    try:
        with open(render_target_path(), encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return False
    except (OSError, ValueError) as exc:
        raise MigrationError(f"cannot inspect rendered Claude config: {exc}") from exc
    record = data.get("projects", {}).get(project, {}) if isinstance(data, dict) else {}
    block = record.get("mcpServers", {}) if isinstance(record, dict) else {}
    value = block.get(rendered_name) if isinstance(block, dict) else None
    disabled = record.get("disabledMcpServers", []) if isinstance(record, dict) else []
    return bool(
        isinstance(value, dict)
        and value.get("command") == WRAPPER_COMMAND
        and value.get("args") == ["--project", project, server]
        and rendered_name not in disabled
    )


def _codex_rendered(project: str, rendered_name: str, server: str) -> bool:
    path = activation.codex_config_path(project)
    try:
        with open(path, "rb") as fh:
            data = tomllib.load(fh)
    except FileNotFoundError:
        return False
    except (OSError, ValueError) as exc:
        raise MigrationError(f"cannot inspect rendered Codex config {path}: {exc}") from exc
    table = data.get("mcp_servers", {}).get(rendered_name) if isinstance(data, dict) else None
    return bool(
        isinstance(table, dict)
        and table.get("command") == WRAPPER_COMMAND
        and table.get("args") == ["--project", project, server]
    )


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

    plans = build_render_plan()
    planned = {
        (entry.scope, entry.project_key, entry.source_name): entry.rendered_name
        for entry in plans.claude.planned
    }
    for path, project in _project_profiles():
        profile = _load_legacy_profile(path)
        for name, value in sorted(profile["servers"].items()):
            if not isinstance(value, dict) or "command" not in value:
                if isinstance(value, dict) and value.get("enabled") is False:
                    continue
                raise MigrationError(f"malformed legacy MCP definition {name!r} in {path}")
            name = str(name)
            consumers: list[str] = []
            rendered = planned.get(("project", project, name))
            if value.get("enabled", True) is not False and rendered:
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


def _has_legacy_claude_entries() -> bool:
    """True when the retired render target still holds Boxa-written entries."""
    data = _load_legacy_claude_config()
    if data is None:
        return False
    block = data.get("mcpServers")
    if isinstance(block, dict) and any(is_managed_or_legacy(name) for name in block):
        return True
    projects = data.get("projects")
    if isinstance(projects, dict):
        for record in projects.values():
            if not isinstance(record, dict):
                continue
            servers = record.get("mcpServers")
            if isinstance(servers, dict) and any(
                is_managed_or_legacy(name) for name in servers
            ):
                return True
    return False


def _remove_legacy_claude_entries() -> None:
    path = render_target_path()
    data = _load_legacy_claude_config()
    if data is None:
        return
    existing = casfile.read_bytes(path)
    changed = False
    block = data.get("mcpServers")
    if isinstance(block, dict):
        retained = {
            name: value for name, value in block.items()
            if not is_managed_or_legacy(name)
        }
        if retained != block:
            data["mcpServers"] = retained
            changed = True
    projects = data.get("projects")
    if isinstance(projects, dict):
        for record in projects.values():
            if not isinstance(record, dict):
                continue
            servers = record.get("mcpServers")
            if isinstance(servers, dict):
                removed = {name for name in servers if is_managed_or_legacy(name)}
                if removed:
                    record["mcpServers"] = {
                        name: value for name, value in servers.items() if name not in removed
                    }
                    changed = True
                disabled = record.get("disabledMcpServers")
                if isinstance(disabled, list):
                    retained_disabled = [name for name in disabled if name not in removed]
                    if retained_disabled != disabled:
                        record["disabledMcpServers"] = retained_disabled
                        changed = True
    # Claude Code owns this file. Rewriting it when nothing was removed would
    # reformat foreign content for no reason, so only write on a real removal —
    # and only while the bytes this purge was derived from still hold.
    if changed:
        casfile.swap_json(path, existing, data, 0o600)


def _remove_legacy_global_codex_entries() -> None:
    path = codex_global_config_path()
    try:
        with open(path, encoding="utf-8", newline="") as fh:
            existing = fh.read()
    except FileNotFoundError:
        return
    stripped = _strip_boxa_tables(existing)
    if stripped != existing:
        _swap_write(path, existing, stripped)


def _render_target_retired() -> bool:
    path = render_target_marker_path()
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.load(fh)
    except FileNotFoundError:
        return False
    except (OSError, ValueError) as exc:
        raise MigrationError(
            f"cannot read Claude render-target marker {path}: {exc}"
        ) from exc
    return isinstance(value, dict) and value.get("target") == CLAUDE_RENDER_TARGET


def _write_render_target_marker() -> None:
    activation._atomic_json(
        render_target_marker_path(),
        {"version": MIGRATION_VERSION, "target": CLAUDE_RENDER_TARGET},
        0o600,
    )


def _batch_consent(
    activations: dict[str, Any],
    claude_projects: list[str],
    allow_tracked_mcp_json: bool,
) -> frozenset[str]:
    """Durable per-Project consent plus this one batch's flag (ADR 0022)."""
    durable_consented = {
        consented_project
        for consented_project, allowed
        in activations.get("trackedMcpJson", {}).items()
        if allowed is True
    }
    return frozenset(
        durable_consented
        | (set(claude_projects) if allow_tracked_mcp_json else set())
    )


def _compensate(
    txn: casfile.Transaction, label: str, exc: BaseException
) -> None:
    """Take back a failed migration batch and report why it failed.

    Restores only paths whose bytes are still Boxa's own, so a foreign edit
    made after Boxa's write is reported rather than erased. Always raises.
    """
    errors, concurrent = txn.rollback()
    problems = list(errors)
    if concurrent:
        problems.append(
            "concurrent writes left in place for " + ", ".join(concurrent)
        )
    if problems:
        raise MigrationError(
            f"{label} failed and rollback was incomplete: "
            + "; ".join(problems)
        ) from exc
    if isinstance(exc, casfile.ConcurrentModification):
        raise MigrationError(
            f"{label} refused: {exc.path} changed on disk while Boxa was "
            "rendering it; nothing was written — re-run the command"
        ) from exc
    raise exc


def _preflight_claude_batch(
    catalog: dict[str, Any],
    activations: dict[str, Any],
    state: dict[str, Any],
    consented: frozenset[str],
    claude_projects: list[str],
) -> None:
    try:
        activation._preflight_claude_lifecycle(
            catalog,
            activations,
            state,
            consented=consented,
            projects=claude_projects,
        )
    except activation.ActivationError as exc:
        raise MigrationError(
            f"{exc}, or re-run 'boxa mcp migrate "
            "--allow-tracked-mcp-json' to authorize this migration batch"
        ) from exc


def _upgrade_claude_render_target(*, allow_tracked_mcp_json: bool = False) -> bool:
    """Retire ~/.claude/.claude.json on an install that already migrated.

    ADR 0022 arrived after the legacy migration shipped, so a manifest that is
    already ``complete`` — or an install that never had legacy profiles — would
    otherwise keep its entries in the retired file while convergence renders the
    same servers into ``.mcp.json``. Idempotent: a durable marker records the
    retirement, and the work itself is a plain re-render.
    """
    if _render_target_retired():
        return False
    catalog = load_catalog()
    activations = activation.load_activations()
    state = activation._load_render_state()
    claude_projects = activation._claude_render_projects(activations, state)
    if not claude_projects and not _has_legacy_claude_entries():
        # Nothing was ever rendered anywhere; leave no marker so a later
        # install that does render is still upgraded exactly once.
        return False
    consented = _batch_consent(activations, claude_projects, allow_tracked_mcp_json)
    _preflight_claude_batch(
        catalog, activations, state, consented, claude_projects
    )
    # Every write below journals into this batch, so compensation restores
    # exactly the bytes Boxa wrote and never a foreign edit made since.
    with casfile.transaction() as txn:
        try:
            _remove_legacy_claude_entries()
            activation.render_claude_activations(
                activations, consented=consented
            )
            # The render records the seeded approval set, so publish the
            # runtime snapshot only after it: convergence must not read a
            # snapshot that still omits a name Boxa has already seeded.
            activation.refresh_runtime(activations)
            _write_render_target_marker()
        except Exception as exc:
            _compensate(txn, "Claude render-target retirement", exc)
    return True


def migrate_legacy(*, allow_tracked_mcp_json: bool = False) -> dict[str, Any]:
    """Migrate once, atomically; legacy source files remain recoverable."""
    with mutation_lock():
        prior_manifest = _load_manifest()
        if prior_manifest is not None and prior_manifest.get("status") == "complete":
            # The legacy migration is done, but the ADR 0022 render-target
            # retirement may still be pending on this upgraded install.
            result = dict(prior_manifest)
            result["changed"] = _upgrade_claude_render_target(
                allow_tracked_mcp_json=allow_tracked_mcp_json
            )
            return result

        # The inventory reads the retired file to learn which legacy servers
        # were actually rendered, so it must run before any retirement.
        legacy = _inventory()
        if not legacy and prior_manifest is None:
            return {
                "version": MIGRATION_VERSION,
                "status": "not-needed",
                "legacyRetained": True,
                "definitions": [],
                "changed": _upgrade_claude_render_target(
                    allow_tracked_mcp_json=allow_tracked_mcp_json
                ),
            }
        catalog = load_catalog()
        activations = activation.load_activations()
        used_names = {entry["name"] for entry in catalog["entries"].values()}
        by_definition = {
            _definition_key(entry["name"], entry): entry_id
            for entry_id, entry in catalog["entries"].items()
        }
        audit: list[dict[str, Any]] = []
        codex_projects: set[str] = set()
        prepared_by_source = {}
        if prior_manifest is not None:
            prepared_by_source = {
                (row.get("scope"), row.get("project", ""), row.get("legacyName"), row.get("source")): row
                for row in prior_manifest.get("definitions", [])
                if isinstance(row, dict)
            }
        secret_updates: dict[str, dict[str, Any]] = {}
        for item in sorted(legacy, key=lambda d: (d.name.casefold(), d.scope, d.project, d.source_path)):
            original_key = _definition_key(item.name, item.entry)
            prepared = prepared_by_source.get((item.scope, item.project, item.name, item.source_path))
            if prepared is not None:
                item.consumers = [
                    value for value in prepared.get("consumers", [])
                    if value in {"claude", "codex"}
                ]
            deterministic_id = str(uuid.uuid5(_NAMESPACE, original_key))
            entry_id = (
                str(prepared.get("catalogId"))
                if prepared is not None
                else by_definition.get(original_key)
            )
            if entry_id not in catalog["entries"]:
                entry_id = by_definition.get(original_key)
            conflict = bool(prepared and prepared.get("nameConflict"))
            if entry_id is None:
                fingerprint = hashlib.sha256(_canonical(item.entry).encode()).hexdigest()
                prepared_name = prepared.get("catalogName") if prepared is not None else None
                name = (
                    str(prepared_name)
                    if isinstance(prepared_name, str) and prepared_name
                    else _unique_name(item.name, fingerprint, used_names)
                )
                conflict = name != item.name
                entry = dict(item.entry)
                entry["name"] = name
                entry_id = deterministic_id
                if entry_id in catalog["entries"] and catalog["entries"][entry_id] != {"id": entry_id, **entry}:
                    raise MigrationError("deterministic migration identity collision")
                entry["id"] = entry_id
                # Catalog runtime credentials for migrated identities are keyed
                # by stable ID, never the legacy display name. The old name
                # block remains recoverable but cannot be inherited by another
                # same-name catalog identity.
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
                if "codex" in consumers:
                    codex_projects.add(item.project)
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
                        raise MigrationError(
                            f"cannot safely map legacy credentials for {item.name!r} "
                            f"to stable identity {entry_id!r} in {secret_path}"
                        )
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
            })

        manifest = {
            "version": MIGRATION_VERSION,
            "status": "prepared",
            "legacyRetained": True,
            "definitions": audit,
        }
        state = activation._load_render_state()
        claude_projects = activation._claude_render_projects(activations, state)
        # Migration is a lifecycle write like any other: it may not touch a
        # tracked .mcp.json or .claude/settings.local.json without consent.
        # It has no single explicitly mutated Project, so — as for a
        # catalog-wide mutation (ADR 0022) — its flag authorizes this batch
        # only and records no new durable Project consent.
        consented = _batch_consent(
            activations, claude_projects, allow_tracked_mcp_json
        )
        _preflight_claude_batch(
            catalog, activations, state, consented, claude_projects
        )
        # Every store, render and marker write below journals into this
        # batch, so compensation is derived from what Boxa actually wrote.
        with casfile.transaction() as txn:
            try:
                # A crash can bypass compensating rollback. Publish the secret-free
                # plan first so retry retains the original rendered-consumer facts
                # and chosen conflict identities even after partial config writes.
                activation._atomic_json(migration_path(), manifest, 0o600)
                save_catalog(catalog)
                for path, store in secret_updates.items():
                    save_secrets(path, store)
                activation.save_activation_store(activations)
                _remove_legacy_claude_entries()
                _remove_legacy_global_codex_entries()
                activation.render_claude_activations(
                    activations, consented=consented
                )
                for project in sorted(codex_projects):
                    activation._render_codex_activation(activations, project, allow_tracked=True)
                # The Claude render is what records the seeded approval set, so the
                # runtime snapshot is published only after it. Publishing earlier
                # would ship a snapshot without `seededApprovals`, and convergence
                # would then treat an already-seeded name as new and re-enable a
                # server the user had removed from the Project approval settings.
                activation.refresh_runtime(activations)
                _write_render_target_marker()
                manifest["status"] = "complete"
                activation._atomic_json(migration_path(), manifest, 0o600)
            except Exception as exc:
                _compensate(txn, "migration", exc)
        result = dict(manifest)
        result["changed"] = True
        return result
