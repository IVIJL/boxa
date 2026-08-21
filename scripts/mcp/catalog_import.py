"""Definition-only import into the MCP catalog (ADR 0021, issue 08)."""

from __future__ import annotations

import hashlib
import json
import uuid
from dataclasses import dataclass, field
from typing import Any

from .apply import is_applicable, not_applicable_reason
from .catalog import (
    EXECUTION_MODE,
    READINESS_SUMMARY,
    REMOTE_READINESS_SUMMARY,
    load_catalog,
    mutation_lock,
    runtime_kind,
    save_catalog,
    update_entry,
)
from .merge import MergedCandidate
from .source_values import read_nonsecret_values


class CatalogImportConflictError(ValueError):
    pass


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

    def to_dict(self) -> dict[str, Any]:
        return {
            "definitionOnly": True,
            "imported": [item.to_dict() for item in self.imported],
            "skipped": self.skipped,
        }


def _entry(
    m: MergedCandidate, *, include_source_values: bool = True
) -> dict[str, Any]:
    cand = m.candidate
    if (cand.type or "").strip().lower() == "http":
        return {
            "name": cand.name,
            "type": "http",
            "url": cand.url,
            "readiness": {"summary": REMOTE_READINESS_SUMMARY},
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
        return ("http", entry.get("url"))
    return ("stdio", tuple(entry.get("command", {}).get("argv", [])))


def _safe_diff(current: dict[str, Any], proposed: dict[str, Any]) -> list[dict[str, Any]]:
    """Return a secret-free definition diff for an inherited name collision."""
    fields = ("type", "url", "command", "envKeys", "secretEnvKeys", "runtimeKind")
    return [
        {"field": field, "catalog": current.get(field), "candidate": proposed.get(field)}
        for field in fields
        if current.get(field) != proposed.get(field)
    ]


def catalog_verdicts(
    candidates: list[MergedCandidate],
    catalog: dict[str, Any] | None = None,
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
    for merged in candidates:
        merged.catalog_status = "proposal"
        merged.catalog_id = ""
        merged.catalog_name = ""
        merged.catalog_diff = []
        proposed = _entry(merged, include_source_values=False)
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
) -> CatalogImportResult:
    """Add selected definitions only; never install, activate, or render."""
    catalog_conflicts = catalog_conflicts or {}
    catalog_verdicts(selected)

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
        proposed = _entry(m)
        updated = update_entry(m.catalog_id, definition=proposed)
        result.imported.append(ImportedDefinition(
            m.candidate.name,
            m.import_id,
            updated["id"],
            updated["name"],
            True,
        ))
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
            catalog["entries"][entry_id] = proposed
            used.add(name)
            by_definition[dedup_key] = (entry_id, proposed)
            result.imported.append(ImportedDefinition(
                m.candidate.name, m.import_id, entry_id, name, True
            ))
        if any(item.changed for item in result.imported):
            save_catalog(catalog)
    return result
