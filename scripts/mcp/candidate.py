"""Provider-neutral MCP candidate model (ADR 0013 + local-plan-mcp.md slice 1).

This is the single place where the shape of an *import candidate* lives. Every
later import provider (Claude Code, Codex, and future Cursor/PI/`.mcp.json`
sources) normalizes its discovered records into this shape, and every command
that emits `--json` serializes from here. Keeping the shape in one module means
provider merge (issue 03) and classification (issue 04) reuse it instead of
re-deriving an ad-hoc dict.

Terminology follows CONTEXT.md § MCP: a discovered, not-yet-trusted server is
an "Inherited MCP server"; a candidate is the normalized record describing one
such server as a possible entry for an MCP profile.

Secret-safety rule (ADR 0013, decisions 25-26): this model never carries
secret *values*. `Command.env_keys` and `Command.secret_env_keys` are
environment-variable *names* only. Serialization here can therefore be emitted
to logs, tables, and JSON without redaction passes, because no value ever
enters the model.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional

# Schema version for the candidate / result JSON envelope. Bump when the
# serialized shape changes so later migrations (issue 02+) can branch on it.
# Matches the spirit of the profile `version` field in local-plan-mcp.md
# decision 24.
#
# v1 (issues 01-02): bare candidate entries (provider/sourcePath/sourceScope/
#                    sourceProject/name/type/command/classification).
# v2 (issue 03):     merged candidate entries — each now also carries the
#                    cross-provider merge fields ``importId``, ``providers``,
#                    ``sources``, and ``conflict`` (+ ``conflictWith`` when in
#                    conflict). Consumers branching on the version can tell the
#                    merged shape apart from the original bare shape.
SCHEMA_VERSION = 2

# Allowed classification placements (local-plan-mcp.md core question 9).
# A candidate's placement separates *where it should run* from *how confident*
# boxa is about that. This slice does not classify anything yet, so callers
# leave placement as "unknown"; the constant set is defined now so providers
# and the classifier (issue 04) share one vocabulary.
PLACEMENTS = ("container", "host-only", "unknown", "excluded")

# Allowed classification confidences (local-plan-mcp.md core question 9).
CONFIDENCES = ("high", "medium", "low")


@dataclass
class Command:
    """How an Inherited/Boxa MCP server is launched.

    Stored as an `argv` array (never a shell string) per local-plan-mcp.md
    decision 24. Env is split into:

      * `env_keys`      — names of all environment variables the server
                          references, secret or not.
      * `secret_env_keys` — subset of `env_keys` whose *values* are sensitive
                          (API keys, tokens). Names only — values never live
                          in this model.
    """

    argv: list[str] = field(default_factory=list)
    env_keys: list[str] = field(default_factory=list)
    secret_env_keys: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "argv": list(self.argv),
            "envKeys": list(self.env_keys),
            "secretEnvKeys": list(self.secret_env_keys),
        }


@dataclass
class Classification:
    """Placement decision plus its confidence and supporting reasons.

    `placement` is one of PLACEMENTS, `confidence` is one of CONFIDENCES (or
    None when unclassified), and `reasons` is a human-readable evidence list
    (local-plan-mcp.md core question 9). This slice produces no classification,
    so the default is an unknown placement with no confidence and no reasons.
    """

    placement: str = "unknown"
    confidence: Optional[str] = None
    reasons: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        if self.placement not in PLACEMENTS:
            raise ValueError(
                f"invalid placement {self.placement!r}; "
                f"expected one of {PLACEMENTS}"
            )
        if self.confidence is not None and self.confidence not in CONFIDENCES:
            raise ValueError(
                f"invalid confidence {self.confidence!r}; "
                f"expected one of {CONFIDENCES} or None"
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "placement": self.placement,
            "confidence": self.confidence,
            "reasons": list(self.reasons),
        }


@dataclass
class Candidate:
    """One normalized Inherited MCP server candidate (ADR 0013).

    Fields are exactly those required by ADR 0013 and local-plan-mcp.md
    slice 1 ("Candidate shape should include"):

      * provider      — import provider that discovered it (e.g. "claude-code",
                        "codex").
      * source_path   — absolute path of the agent config file it came from.
      * source_scope  — "global" or "project" (where the inherited server was
                        configured).
      * source_project — project key when source_scope is "project"; None for
                        global.
      * name          — the server name as it appears in the source config.
      * type          — transport/type as reported by the source (e.g. "stdio");
                        None when the source does not specify one.
      * command       — Command (argv + env key names + secret env key names).
      * classification — Classification (placement / confidence / reasons).
    """

    provider: str
    source_path: str
    source_scope: str
    name: str
    source_project: Optional[str] = None
    type: Optional[str] = None
    command: Command = field(default_factory=Command)
    classification: Classification = field(default_factory=Classification)

    def to_dict(self) -> dict[str, Any]:
        return {
            "provider": self.provider,
            "sourcePath": self.source_path,
            "sourceScope": self.source_scope,
            "sourceProject": self.source_project,
            "name": self.name,
            "type": self.type,
            "command": self.command.to_dict(),
            "classification": self.classification.to_dict(),
        }


def _merged_dicts(candidates: Optional[list[Any]]) -> list[dict[str, Any]]:
    """Serialize candidates as schema-v2 (merged) entries, always.

    The envelope advertises ``SCHEMA_VERSION`` (v2 carries the cross-provider
    merge fields ``importId``/``providers``/``sources``/``conflict``). To keep
    the serialized shape consistent with the advertised version regardless of
    caller, bare `Candidate`s are coerced through the merge step here so they
    gain those fields; objects that are already merged (anything exposing the
    merge-aware ``to_dict`` via an ``import_id`` attribute) serialize as-is.

    `mcp.merge` is imported lazily to avoid a circular import (`merge` imports
    this module for the `Candidate` type).
    """
    cands = candidates or []
    if not cands:
        return []
    # Already-merged candidates carry an ``import_id`` attribute.
    if all(hasattr(c, "import_id") for c in cands):
        return [c.to_dict() for c in cands]
    if all(isinstance(c, Candidate) for c in cands):
        from .merge import merge_candidates

        return [m.to_dict() for m in merge_candidates(list(cands))]
    # Mixed/unknown input: trust each element's own ``to_dict`` (back-compat).
    return [c.to_dict() for c in cands]


def import_result(candidates: Optional[list[Any]] = None) -> dict[str, Any]:
    """Build the `boxa mcp import --json` envelope.

    Stable contract from the very first slice: a versioned object with a
    `candidates` array. As of issue 03 (schema v2) each element is a merged
    candidate carrying ``importId``, ``providers``, ``sources``, and a
    ``conflict`` marker. Bare `Candidate`s passed here are coerced through the
    merge step so the serialized shape always matches the advertised version.
    """

    return {
        "version": SCHEMA_VERSION,
        "candidates": _merged_dicts(candidates),
    }


def inherited_list_result(
    candidates: Optional[list[Any]] = None,
) -> dict[str, Any]:
    """Build the `boxa mcp list --inherited --json` envelope.

    `list --inherited` reports detected Inherited MCP servers (local-plan-mcp.md
    decision 22). Same schema-v2 merged-candidate element shape as import; bare
    `Candidate`s are coerced through the merge step so the entries always carry
    the advertised v2 fields.
    """

    return {
        "version": SCHEMA_VERSION,
        "inherited": _merged_dicts(candidates),
    }
