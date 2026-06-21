"""Provider merge + stable import IDs (ADR 0013, issue 03).

This module turns the raw per-provider `Candidate` lists into the merged view
that `boxa mcp import` reports. Two things happen here:

  1. **Stable import IDs.** Every candidate gets an ``importId`` derived only
     from non-secret *identity* metadata (local-plan-mcp.md decision 18). The
     ID is deterministic across runs and never contains a secret value: it is a
     hash of the merge-identity tuple (scope, project key, server name, type,
     argv, and env-variable NAMES) — env/argv *values* that look like secrets
     are already redacted upstream, and env values never enter the model at all.

  2. **Provider merge + conflict detection.** Candidates that describe the same
     logical server are collapsed. Per local-plan-mcp.md decision 19:

       * Same ``name + scope (+ project)`` AND same spec (argv + env key names)
         discovered by multiple providers -> ONE merged candidate that retains
         every contributing provider/source in metadata.
       * Same ``name + scope (+ project)`` but DIFFERENT spec -> a reported
         CONFLICT. The colliding candidates are kept distinct (their import IDs
         differ because argv/env-key-names differ) and each is annotated with a
         conflict marker so an apply step (issue 05) can force the user to
         choose. Nothing is silently merged away.

Why the merge identity excludes ``provider`` and ``source_path``: those are the
very fields that differ when two agents (Claude Code + Codex) both reference the
same server. The logical identity of an import candidate is "this named server,
in this scope, launched this way" — so the import ID and the merge key are built
from that, and the contributing providers/paths are carried as a *list* on the
merged result instead.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Any

from .candidate import Candidate


@dataclass
class MergeSource:
    """One provider's contribution to a merged candidate (non-secret).

    Records which provider discovered the candidate and the config file it came
    from, so a merged result can show every source without losing provenance.
    """

    provider: str
    source_path: str

    def to_dict(self) -> dict[str, Any]:
        return {"provider": self.provider, "sourcePath": self.source_path}


# A missing/empty transport type means the default stdio transport for every
# provider we support (Claude records ``type: "stdio"`` explicitly; Codex's
# documented stdio shape omits it). Normalizing both to the same value here is
# what lets an otherwise-identical server discovered by both agents merge into
# one candidate instead of looking like a spec conflict.
_DEFAULT_TYPE = "stdio"


def _normalized_type(cand: Candidate) -> str:
    t = (cand.type or "").strip().lower()
    return t or _DEFAULT_TYPE


def _identity_tuple(cand: Candidate) -> tuple:
    """Non-secret identity of a candidate used for both merge key and import ID.

    Includes only metadata that is safe to hash/emit (local-plan-mcp.md
    decision 18): scope, project key, server name, NORMALIZED transport type,
    the argv array (already secret-redacted upstream), and the SORTED
    environment-variable NAMES. Deliberately excludes ``provider`` and
    ``source_path`` so the same logical server discovered by different agents
    collapses to one identity.

    Type is normalized (empty/missing -> "stdio", lower-cased) so a Claude entry
    with an explicit ``type: "stdio"`` and a Codex entry that omits it are
    recognized as the same spec rather than reported as a conflict. Env key
    names are sorted so providers listing the same names in a different order
    still match (order is not semantically meaningful for env).
    """
    return (
        cand.source_scope,
        cand.source_project or "",
        cand.name,
        _normalized_type(cand),
        tuple(cand.command.argv),
        tuple(sorted(cand.command.env_keys)),
    )


def _collision_key(cand: Candidate) -> tuple:
    """Key for grouping candidates that occupy the same name+scope slot.

    Two candidates with this same key but a different ``_identity_tuple`` are an
    import conflict (same name+scope, different spec).
    """
    return (cand.source_scope, cand.source_project or "", cand.name)


def compute_import_id(cand: Candidate) -> str:
    """Stable, secret-free import ID for a candidate.

    Deterministic across runs: identical identity metadata yields the same ID.
    Secret-free by construction — it hashes only ``_identity_tuple`` (no env
    values, no auth tokens; argv is already redacted). The ``imp-`` prefix makes
    the value recognizable in tables, JSON, and ``--import-id`` flags.
    """
    parts = _identity_tuple(cand)
    # Use a record separator that cannot appear inside the joined parts so two
    # distinct tuples can never serialize to the same string.
    flat: list[str] = [
        parts[0],  # scope
        parts[1],  # project key
        parts[2],  # name
        parts[3],  # type
    ]
    flat.extend(parts[4])  # argv tokens
    flat.append("\x1e".join(parts[5]))  # env key names (already sorted)
    blob = "\x1f".join(flat).encode("utf-8")
    digest = hashlib.sha256(blob).hexdigest()
    return "imp-" + digest[:12]


@dataclass
class MergedCandidate:
    """A candidate after provider merge: the candidate plus merge metadata.

    Wraps the underlying `Candidate` (the spec/classification stay there) and
    adds the cross-provider view: a stable ``import_id``, every contributing
    ``source`` (provider + path), and a ``conflict`` marker when this slot has
    competing specs.
    """

    candidate: Candidate
    import_id: str
    sources: list[MergeSource] = field(default_factory=list)
    conflict: bool = False
    conflict_with: list[str] = field(default_factory=list)

    @property
    def providers(self) -> list[str]:
        """Distinct contributing providers, in first-seen order."""
        seen: set[str] = set()
        out: list[str] = []
        for s in self.sources:
            if s.provider not in seen:
                seen.add(s.provider)
                out.append(s.provider)
        return out

    def to_dict(self) -> dict[str, Any]:
        base = self.candidate.to_dict()
        base["importId"] = self.import_id
        base["providers"] = self.providers
        base["sources"] = [s.to_dict() for s in self.sources]
        base["conflict"] = self.conflict
        if self.conflict:
            base["conflictWith"] = list(self.conflict_with)
        return base


def merge_candidates(candidates: list[Candidate]) -> list[MergedCandidate]:
    """Merge per-provider candidates into the cross-provider import view.

    Steps:
      1. Group by ``_identity_tuple``. Candidates with identical identity (same
         name+scope+spec, possibly from different providers) collapse to one
         `MergedCandidate`; every contributing provider/source is retained.
      2. Within each name+scope slot, if more than one distinct identity exists
         the specs disagree -> mark every member of that slot as a conflict and
         record the other conflicting import IDs.

    Output order is deterministic: by scope, project key, name, then import ID,
    so two distinct specs sharing a slot have a stable, repeatable ordering.
    """
    # 1. Collapse identical identities.
    by_identity: dict[tuple, MergedCandidate] = {}
    order: list[tuple] = []
    for cand in candidates:
        ident = _identity_tuple(cand)
        source = MergeSource(provider=cand.provider, source_path=cand.source_path)
        existing = by_identity.get(ident)
        if existing is None:
            merged = MergedCandidate(
                candidate=cand,
                import_id=compute_import_id(cand),
                sources=[source],
            )
            by_identity[ident] = merged
            order.append(ident)
        else:
            # Same logical server from another provider/source: keep one
            # candidate, append the source (dedupe exact provider+path repeats).
            if not any(
                s.provider == source.provider and s.source_path == source.source_path
                for s in existing.sources
            ):
                existing.sources.append(source)

    merged_list = [by_identity[i] for i in order]

    # 2. Detect conflicts within each name+scope slot.
    slots: dict[tuple, list[MergedCandidate]] = {}
    for m in merged_list:
        slots.setdefault(_collision_key(m.candidate), []).append(m)
    for members in slots.values():
        if len(members) > 1:
            ids = [m.import_id for m in members]
            for m in members:
                m.conflict = True
                m.conflict_with = [i for i in ids if i != m.import_id]

    merged_list.sort(
        key=lambda m: (
            m.candidate.source_scope,
            m.candidate.source_project or "",
            m.candidate.name,
            m.import_id,
        )
    )
    return merged_list
