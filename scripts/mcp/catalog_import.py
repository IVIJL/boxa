"""Definition-only import into the MCP catalog (ADR 0021, issue 08)."""

from __future__ import annotations

import hashlib
import json
import os
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable

from . import casfile
from .activation import update_catalog_entry
from .apply import (
    ScopeOverride,
    _effective_scope,
    is_applicable,
    not_applicable_reason,
)
from .catalog import (
    EXECUTION_MODE,
    READINESS_SUMMARY,
    REMOTE_READINESS_SUMMARY,
    load_catalog,
    mutation_lock,
    runtime_kind,
    save_catalog,
    updated_catalog_entry,
)
from .merge import MergedCandidate
from .secrets import (
    global_secrets_path,
    read_header_secrets,
    read_server_secrets,
    secrets_path,
    store_header_secrets,
    store_server_secrets,
)
from .source_values import (
    read_nonsecret_values,
    read_secret_header_values,
    read_secret_values,
)


class CatalogImportConflictError(ValueError):
    pass


def destination_scope_overrides(
    selected: list[MergedCandidate],
    project_keys: list[str],
    *,
    scope_overrides: dict[str, ScopeOverride] | None = None,
    target_project: str = "",
) -> dict[str, ScopeOverride]:
    """Resolve each stdio credential store exactly as readiness and broker do."""
    overrides = dict(scope_overrides or {})
    invocation_project = os.path.realpath(
        target_project
        or (project_keys[0] if len(project_keys) == 1 else os.getcwd())
    )
    for merged in selected:
        if merged.import_id in overrides or merged.candidate.type == "http":
            continue
        project_key = (
            invocation_project
            if target_project or merged.candidate.source_scope == "global"
            else merged.candidate.source_project
        )
        if project_key:
            overrides[merged.import_id] = ScopeOverride(
                scope="project", project_key=os.path.realpath(project_key)
            )
    return overrides


@dataclass
class ImportedDefinition:
    name: str
    import_id: str
    catalog_id: str
    catalog_name: str
    changed: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "importId": self.import_id,
            "catalogId": self.catalog_id,
            "catalogName": self.catalog_name,
            "changed": self.changed,
        }


@dataclass
class CatalogImportResult:
    imported: list[ImportedDefinition] = field(default_factory=list)
    skipped: list[dict[str, str]] = field(default_factory=list)
    skipped_secrets: list[dict[str, Any]] = field(default_factory=list)
    taken_secrets: list[dict[str, Any]] = field(default_factory=list)
    secret_scopes: list[tuple[str, str]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        payload = {
            "definitionOnly": True,
            "imported": [item.to_dict() for item in self.imported],
            "skipped": self.skipped,
            "skippedSecrets": self.skipped_secrets,
            "takenSecrets": self.taken_secrets,
        }
        if self.skipped_secrets:
            payload["next"] = ["boxa mcp secret set"]
        return payload


SecretConsent = Callable[[str, str, str, bool], bool]


def _import_identity(m: MergedCandidate) -> str:
    """Stable source-slot identity, independent of host-carried definition."""
    cand = m.candidate
    payload = "\x1f".join((
        cand.source_scope,
        cand.source_project or "",
        cand.name,
    )).encode("utf-8")
    return "src-" + hashlib.sha256(payload).hexdigest()[:16]


def _entry(
    m: MergedCandidate, *, include_source_values: bool = True
) -> dict[str, Any]:
    cand = m.candidate
    if (cand.type or "").strip().lower() == "http":
        return {
            "name": cand.name,
            "type": "http",
            "url": cand.url,
            "headers": dict(sorted(cand.headers.items())),
            "secretHeaderKeys": sorted(
                set(cand.secret_header_keys), key=str.casefold
            ),
            "readiness": {"summary": REMOTE_READINESS_SUMMARY},
            "importIdentity": _import_identity(m),
        }
    env = read_nonsecret_values(cand) if include_source_values else {}
    entry: dict[str, Any] = {
        "name": cand.name,
        "type": cand.type or "stdio",
        "executionMode": EXECUTION_MODE,
        "runtimeKind": runtime_kind(cand.command.argv),
        "readiness": {"summary": READINESS_SUMMARY},
        "command": {"argv": list(cand.command.argv)},
        "envKeys": sorted(set(cand.command.env_keys)),
        "secretEnvKeys": sorted(set(cand.command.secret_env_keys)),
        "importIdentity": _import_identity(m),
    }
    if env:
        entry["env"] = dict(sorted(env.items()))
    return entry


def _definition(entry: dict[str, Any]) -> str:
    value = {key: item for key, item in entry.items() if key not in {"id", "name"}}
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _dedup_key(entry: dict[str, Any]) -> tuple[str, object]:
    """Catalog identity for discovery dedup: command/args or remote URL."""
    if entry.get("type") == "http":
        return (
            "http",
            (
                entry.get("url"),
                tuple(sorted(entry.get("headers", {}).items())),
                tuple(
                    sorted(entry.get("secretHeaderKeys", []), key=str.casefold)
                ),
            ),
        )
    return ("stdio", tuple(entry.get("command", {}).get("argv", [])))


def _safe_diff(current: dict[str, Any], proposed: dict[str, Any]) -> list[dict[str, Any]]:
    """Return a secret-free definition diff for an inherited name collision."""
    fields = (
        "type", "url", "headers", "secretHeaderKeys", "command", "envKeys",
        "secretEnvKeys", "runtimeKind", "env",
    )
    return [
        {"field": field, "catalog": current.get(field), "candidate": proposed.get(field)}
        for field in fields
        if current.get(field) != proposed.get(field)
    ]


def _matched_update(
    catalog: dict[str, Any], merged: MergedCandidate, entry_id: str
) -> dict[str, Any]:
    """Build the exact normalized replacement the apply path will publish."""
    _resolved, updated = updated_catalog_entry(
        catalog, entry_id, {"definition": _entry(merged)}
    )
    return updated


def _stdio_secret_paths(
    merged: MergedCandidate, override: ScopeOverride | None
) -> list[tuple[str, str, str]]:
    """Resolve stores exactly as Project readiness does for catalog stdio."""
    scope, project = _effective_scope(merged, override)
    return [(
        secrets_path(scope, project or None),
        scope,
        project,
    )]


def _secret_changes(
    merged: MergedCandidate,
    entry: dict[str, Any],
    override: ScopeOverride | None = None,
) -> list[str]:
    """Return secret key names whose host values differ from the private store."""
    cand = merged.candidate
    changed: list[str] = []
    if entry.get("type") == "http":
        try:
            stored = read_header_secrets(
                global_secrets_path(), str(entry["id"])
            ) or {}
        except (OSError, ValueError):
            stored = {}
        for name, value in read_secret_header_values(cand).items():
            if stored.get(name.casefold()) != value:
                changed.append(name)
        return changed
    store_key = str(entry.get("secretStoreKey") or entry["name"])
    for name, value in read_secret_values(cand).items():
        if any(
            _stored_server_value(path, store_key, name) != value
            for path, _scope, _project in _stdio_secret_paths(
                merged, override
            )
        ):
            changed.append(name)
    return changed


def _stored_server_value(path: str, store_key: str, name: str) -> str | None:
    try:
        return (read_server_secrets(path, store_key) or {}).get(name)
    except (OSError, ValueError):
        return None


def catalog_verdicts(
    candidates: list[MergedCandidate],
    catalog: dict[str, Any] | None = None,
    *,
    scope_overrides: dict[str, ScopeOverride] | None = None,
) -> list[MergedCandidate]:
    """Annotate discovery with catalog dedup/conflict verdicts; never execute it."""
    data = catalog if catalog is not None else load_catalog()
    by_definition = {
        _dedup_key(entry): (entry_id, entry)
        for entry_id, entry in data["entries"].items()
    }
    by_name = {
        entry["name"]: (entry_id, entry)
        for entry_id, entry in data["entries"].items()
    }
    by_import_identity = {
        entry.get("importIdentity"): (entry_id, entry)
        for entry_id, entry in data["entries"].items()
        if entry.get("importIdentity")
    }
    for merged in candidates:
        merged.catalog_status = "proposal"
        merged.catalog_id = ""
        merged.catalog_name = ""
        merged.catalog_diff = []
        proposed = _entry(merged)
        matched = by_import_identity.get(_import_identity(merged))
        if matched is None:
            legacy_name_match = by_name.get(merged.candidate.name)
            if (
                legacy_name_match is not None
                and not legacy_name_match[1].get("importIdentity")
            ):
                matched = legacy_name_match
        if matched is not None:
            entry_id, entry = matched
            updated = _matched_update(data, merged, entry_id)
            comparable = dict(updated)
            if "importIdentity" not in entry:
                comparable.pop("importIdentity", None)
            secret_changes = _secret_changes(
                merged, entry, (scope_overrides or {}).get(merged.import_id)
            )
            merged.catalog_status = (
                "in-sync" if comparable == entry and not secret_changes else "changed"
            )
            merged.catalog_id = entry_id
            merged.catalog_name = entry["name"]
            merged.catalog_diff = _safe_diff(entry, updated)
            if secret_changes:
                merged.catalog_diff.append({
                    "field": "secretValues",
                    "catalog": "stored values",
                    "candidate": "host values differ",
                    "keys": sorted(secret_changes, key=str.casefold),
                })
            continue
        identical = by_definition.get(_dedup_key(proposed))
        if identical is not None:
            entry_id, entry = identical
            merged.catalog_status = "already-cataloged"
            merged.catalog_id = entry_id
            merged.catalog_name = entry["name"]
            continue
        collision = by_name.get(merged.candidate.name)
        if collision is not None:
            entry_id, entry = collision
            merged.catalog_status = "conflict"
            merged.catalog_id = entry_id
            merged.catalog_name = entry["name"]
            merged.catalog_diff = _safe_diff(entry, proposed)
            continue
    return candidates


def _takeover_values(
    merged: MergedCandidate,
    entry: dict[str, Any],
    consent: SecretConsent | None,
    result: CatalogImportResult,
    override: ScopeOverride | None = None,
) -> bool:
    """Apply consented secret values and retain declined stored peers."""
    cand = merged.candidate
    changed = False
    skipped: list[str] = []
    taken: list[str] = []
    if entry.get("type") == "http":
        path = global_secrets_path()
        entry_id = str(entry["id"])
        stored = read_header_secrets(path, entry_id) or {}
        declared = {str(name).casefold() for name in entry.get("secretHeaderKeys", [])}
        replacement = {key: value for key, value in stored.items() if key in declared}
        host_values = read_secret_header_values(cand)
        for name, value in host_values.items():
            folded = name.casefold()
            if not value:
                if name not in skipped:
                    skipped.append(name)
                continue
            old = stored.get(folded)
            if old == value:
                continue
            if consent is not None and consent("header", name, cand.source_path, old is not None):
                replacement[folded] = value
                taken.append(name)
                changed = True
            else:
                skipped.append(name)
        for name in entry.get("secretHeaderKeys", []):
            if (
                str(name).casefold() not in stored
                and str(name) not in host_values
                and str(name) not in skipped
            ):
                skipped.append(str(name))
        if replacement != stored:
            store_header_secrets(path, entry_id, replacement)
            changed = True
    else:
        store_key = str(entry.get("secretStoreKey") or entry["name"])
        stores = []
        for path, scope, project in _stdio_secret_paths(merged, override):
            stores.append((
                path,
                scope,
                project,
                read_server_secrets(path, store_key) or {},
            ))
        declared = set(entry.get("secretEnvKeys", []))
        host_values = read_secret_values(cand)
        for name, value in host_values.items():
            if not value:
                if name not in skipped:
                    skipped.append(name)
                continue
            differing = [stored for _path, _scope, _project, stored in stores
                          if stored.get(name) != value]
            if not differing:
                continue
            rotation = any(stored.get(name) is not None for stored in differing)
            if consent is not None and consent(
                "environment", name, cand.source_path, rotation
            ):
                taken.append(name)
                changed = True
            else:
                skipped.append(name)
        for name in entry.get("secretEnvKeys", []):
            if (
                any(name not in stored for _path, _scope, _project, stored in stores)
                and name not in host_values
                and name not in skipped
            ):
                skipped.append(name)
        taken_set = set(taken)
        for path, _scope, _project, stored in stores:
            replacement = {
                key: value for key, value in stored.items() if key in declared
            }
            replacement.update(
                (name, value) for name, value in host_values.items()
                if name in taken_set
            )
            if replacement != stored:
                store_server_secrets(path, store_key, replacement)
                changed = True
    if skipped:
        result.skipped_secrets.append({"name": entry["name"], "keys": skipped})
    if taken:
        result.taken_secrets.append({"name": entry["name"], "keys": taken})
        if entry.get("type") == "http":
            result.secret_scopes.append(("global", ""))
        else:
            result.secret_scopes.extend(
                (scope, project)
                for _path, scope, project in _stdio_secret_paths(
                    merged, override
                )
            )
    return changed


def _unique_name(name: str, definition: str, used: set[str]) -> str:
    if name not in used:
        return name
    digest = hashlib.sha256(definition.encode()).hexdigest()[:8]
    candidate = f"{name}-imported-{digest}"
    suffix = 2
    while candidate in used:
        candidate = f"{name}-imported-{digest}-{suffix}"
        suffix += 1
    return candidate


def import_definitions(
    selected: list[MergedCandidate],
    *,
    catalog_conflicts: dict[str, str] | None = None,
    force_host_only: bool = False,
    secret_consent: SecretConsent | None = None,
    scope_overrides: dict[str, ScopeOverride] | None = None,
) -> CatalogImportResult:
    """Add selected definitions only; never install, activate, or render."""
    catalog_conflicts = catalog_conflicts or {}
    scope_overrides = scope_overrides or {}
    catalog_verdicts(selected, scope_overrides=scope_overrides)

    def importable(merged: MergedCandidate) -> bool:
        return is_applicable(merged) or (
            force_host_only
            and merged.candidate.classification.placement == "host-only"
        )

    applicable = [m for m in selected if importable(m)]
    slots: dict[tuple[str, str], list[MergedCandidate]] = {}
    for m in applicable:
        slots.setdefault((m.candidate.source_scope, m.candidate.source_project or ""), []).append(m)
    for members in slots.values():
        names: dict[str, list[MergedCandidate]] = {}
        for member in members:
            names.setdefault(member.candidate.name, []).append(member)
        for name, conflicts in names.items():
            if len(conflicts) > 1:
                raise CatalogImportConflictError(
                    f"selected inherited definitions named {name!r} conflict; choose exactly one import ID"
                )

    result = CatalogImportResult()
    for m in selected:
        if not importable(m):
            result.skipped.append({
                "name": m.candidate.name,
                "importId": m.import_id,
                "reason": not_applicable_reason(m),
            })
    resolved: list[MergedCandidate] = []
    for m in applicable:
        if m.catalog_status != "conflict":
            resolved.append(m)
            continue
        resolution = catalog_conflicts.get(m.import_id)
        if resolution == "skip":
            result.skipped.append({
                "name": m.candidate.name,
                "importId": m.import_id,
                "reason": "catalog conflict skipped by explicit choice",
            })
            continue
        if resolution != "update":
            raise CatalogImportConflictError(
                f"inherited definition {m.candidate.name!r} conflicts with "
                "the same-named catalog entry; choose update or skip"
            )
        resolved.append(m)
    applicable = resolved
    with mutation_lock():
        catalog = load_catalog()
        used = {entry["name"] for entry in catalog["entries"].values()}
        by_definition = {
            _dedup_key(entry): (entry_id, entry)
            for entry_id, entry in catalog["entries"].items()
        }
        for m in applicable:
            proposed = _entry(m)
            if m.catalog_status == "in-sync":
                current = catalog["entries"][m.catalog_id]
                if "importIdentity" not in current:
                    current = dict(current)
                    current["importIdentity"] = proposed["importIdentity"]
                    catalog["entries"][m.catalog_id] = current
                    save_catalog(catalog)
                result.imported.append(ImportedDefinition(
                    m.candidate.name,
                    m.import_id,
                    m.catalog_id,
                    current["name"],
                    False,
                ))
                continue
            if m.catalog_status == "changed" or (
                m.catalog_status == "conflict"
                and catalog_conflicts.get(m.import_id) == "update"
            ):
                entry_id = m.catalog_id
                current = catalog["entries"][entry_id]
                proposed["id"] = entry_id
                proposed["name"] = current["name"]
                with casfile.transaction() as txn:
                    try:
                        secret_changed = _takeover_values(
                            m,
                            proposed,
                            secret_consent,
                            result,
                            scope_overrides.get(m.import_id),
                        )
                        update = update_catalog_entry(
                            entry_id, {"definition": proposed}
                        )
                    except Exception:
                        txn.rollback()
                        raise
                catalog = load_catalog()
                result.imported.append(ImportedDefinition(
                    m.candidate.name,
                    m.import_id,
                    entry_id,
                    current["name"],
                    secret_changed or update.entry != current,
                ))
                continue
            definition = _definition(proposed)
            dedup_key = _dedup_key(proposed)
            existing = by_definition.get(dedup_key)
            if existing is not None:
                entry_id, entry = existing
                result.imported.append(ImportedDefinition(
                    m.candidate.name, m.import_id, entry_id, entry["name"], False
                ))
                continue
            name = _unique_name(m.candidate.name, definition, used)
            proposed["name"] = name
            entry_id = str(uuid.uuid4())
            proposed["id"] = entry_id
            with casfile.transaction() as txn:
                try:
                    _takeover_values(
                        m,
                        proposed,
                        secret_consent,
                        result,
                        scope_overrides.get(m.import_id),
                    )
                    catalog["entries"][entry_id] = proposed
                    save_catalog(catalog)
                except Exception:
                    txn.rollback()
                    raise
            used.add(name)
            by_definition[dedup_key] = (entry_id, proposed)
            result.imported.append(ImportedDefinition(
                m.candidate.name, m.import_id, entry_id, name, True
            ))
    return result
