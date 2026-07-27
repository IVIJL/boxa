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
    load_catalog,
    mutation_lock,
    runtime_kind,
    save_catalog,
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


def _entry(m: MergedCandidate) -> dict[str, Any]:
    cand = m.candidate
    env = read_nonsecret_values(cand)
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


def import_definitions(selected: list[MergedCandidate]) -> CatalogImportResult:
    """Add selected definitions only; never install, activate, or render."""
    applicable = [m for m in selected if is_applicable(m)]
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
        if not is_applicable(m):
            result.skipped.append({
                "name": m.candidate.name,
                "importId": m.import_id,
                "reason": not_applicable_reason(m),
            })
    with mutation_lock():
        catalog = load_catalog()
        used = {entry["name"] for entry in catalog["entries"].values()}
        by_definition = {
            _definition(entry): (entry_id, entry)
            for entry_id, entry in catalog["entries"].items()
        }
        for m in applicable:
            proposed = _entry(m)
            definition = _definition(proposed)
            existing = by_definition.get(definition)
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
            by_definition[definition] = (entry_id, proposed)
            result.imported.append(ImportedDefinition(
                m.candidate.name, m.import_id, entry_id, name, True
            ))
        if any(item.changed for item in result.imported):
            save_catalog(catalog)
    return result
