"""Apply selected import candidates into boxa profile state (issue 05).

This is the first write path behind ``boxa mcp import --apply``. Given the
merged candidates from discovery and an explicit selection, it:

  1. validates that every selected candidate is APPLICABLE — v1 imports only
     ``container`` candidates; ``host-only`` cannot be applied, and ``unknown``
     / ``excluded`` are visible but not applied by default;
  2. writes an agent-neutral, secret-free entry into the scope-correct profile
     (`mcp.profile`) — global source -> global profile, project source ->
     Project profile, preserving inherited scope;
  3. copies any inherited SECRET env VALUES into the scope-correct secret store
     (`mcp.secrets`, mode 0600) so the server works without credential re-entry;
  4. returns a SECRET-FREE summary (names of copied keys only) for both the
     text and JSON output paths.

No Claude Code or Codex config is touched (render is issue 06). Selection
itself (TTY picker vs ``--server`` / ``--import-id``) is resolved by the caller
(`mcp.cli`); this module receives already-chosen `MergedCandidate`s.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any, Optional

from .merge import MergedCandidate
from .profile import (
    build_server_entry,
    load_profile,
    profile_path,
    save_profile,
)
from .secrets import (
    read_server_secrets,
    restore_server_secrets,
    secrets_path,
    store_server_secrets,
)
from .source_values import read_nonsecret_values, read_secret_values

# Only this placement can be applied in v1 (ADR 0013: Container MCP only).
APPLICABLE_PLACEMENT = "container"

# Valid override scopes (ADR 0013 amendment: interactive scope override).
_OVERRIDE_SCOPES = ("global", "project")

# Placeholder the providers substitute for an argv token that carries a
# credential (see ``mcp.providers.claude._REDACTED``). Such a token cannot be
# stored verbatim in the profile — it would later run literally instead of the
# real value. Importing a credential-in-argv server is out of scope for v1
# (the secret store copies env values, not argv tokens), so these candidates
# are skipped with a clear reason rather than silently broken.
_REDACTED_TOKEN = "<redacted>"


def has_redacted_argv(m: MergedCandidate) -> bool:
    """True when the candidate's argv carries a redacted credential placeholder.

    Checks for the placeholder ANYWHERE inside each token, not just as a whole
    token: the provider redacts both a standalone token (``<redacted>``) and the
    value side of an inline flag (``--token=<redacted>``). A plain ``in argv``
    membership test would miss the inline form and let a broken command through.
    """
    return any(_REDACTED_TOKEN in tok for tok in m.candidate.command.argv)


def is_applicable(m: MergedCandidate) -> bool:
    """True when a candidate may be applied in v1.

    Two gates: Container placement only (ADR 0013), AND no redacted argv token
    (a credential-in-argv server cannot be stored without persisting a broken
    placeholder command).
    """
    if m.candidate.classification.placement != APPLICABLE_PLACEMENT:
        return False
    return not has_redacted_argv(m)


def not_applicable_reason(m: MergedCandidate) -> str:
    """Human-readable reason a candidate cannot be applied (secret-free)."""
    placement = m.candidate.classification.placement
    if placement == "host-only":
        return "host-only servers cannot be applied in v1"
    if placement == "excluded":
        return "remote/hosted connector; not importable as a Container MCP server"
    if placement == "unknown":
        return "placement unknown; not applied by default (needs confirmation)"
    if placement == APPLICABLE_PLACEMENT and has_redacted_argv(m):
        return (
            "command passes a credential as an argv argument; "
            "argv-secret import is not supported in v1"
        )
    return f"placement {placement!r} is not applicable"


@dataclass
class AppliedServer:
    """Outcome of applying one candidate (SECRET-FREE)."""

    name: str
    import_id: str
    scope: str
    project_key: str  # "" for global
    profile_path: str
    copied_secret_keys: list[str] = field(default_factory=list)
    secrets_path: str = ""  # set only when secret keys were copied

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "name": self.name,
            "importId": self.import_id,
            "scope": self.scope,
            "profilePath": self.profile_path,
            # NAMES only — values live 0600 in the secret store, never here.
            "copiedSecretKeys": list(self.copied_secret_keys),
        }
        if self.project_key:
            out["project"] = self.project_key
        if self.copied_secret_keys:
            out["secretsPath"] = self.secrets_path
        return out


@dataclass
class ApplyResult:
    """Result of an apply run (SECRET-FREE) for text/JSON rendering."""

    applied: list[AppliedServer] = field(default_factory=list)
    skipped: list[dict[str, str]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "applied": [a.to_dict() for a in self.applied],
            "skipped": list(self.skipped),
        }


class MissingSecretsError(ValueError):
    """A candidate's expected secret values could not be recovered.

    Raised (and turned into a skip by ``apply_selection``) when a candidate
    declares ``secret_env_keys`` but the source config can no longer supply a
    value for one of them — for example the source file moved, was edited, or
    the env key was removed. Writing the profile anyway would record a server
    that promises secrets the secret store does not hold, leaving render/run
    broken. The candidate carries the missing key NAMES only (never values).
    """

    def __init__(self, server_name: str, missing: list[str]) -> None:
        self.server_name = server_name
        self.missing = list(missing)
        super().__init__(
            f"{server_name!r}: could not recover secret value(s) for "
            f"{', '.join(missing)} from the source config"
        )


class ApplyConflictError(ValueError):
    """Two selected applicable candidates target the same profile slot.

    Raised before any write so a conflicting selection (e.g. ``--all-applicable``
    over a name+scope conflict pair, or two import IDs for the same name+scope)
    never silently overwrites one entry with another. The caller surfaces the
    message and the colliding import IDs so the user can pick exactly one.
    """


@dataclass(frozen=True)
class ScopeOverride:
    """An explicit apply target that overrides a candidate's inherited scope.

    ADR 0013 amendment ("Import keeps inherited scope by default, but offers an
    interactive override"): the apply wizard may redirect a server to a scope
    other than the one it was discovered in. Two valid shapes:

      * ``scope="global"`` -> write the global profile + global secret store,
        regardless of the candidate's source scope. ``project_key`` is ignored.
      * ``scope="project"`` + a non-empty absolute ``project_key`` -> write that
        Project's profile + that Project's secret store. The key is the absolute
        host path (the render key), resolved by the project picker / resolver
        (``mcp.projects``), never a bare sanitized name.

    No override (``None`` passed to the apply functions) preserves today's
    inherited-scope behavior byte-for-byte. Validated at construction so a
    malformed override fails before any write.
    """

    scope: str
    project_key: str = ""

    def __post_init__(self) -> None:
        if self.scope not in _OVERRIDE_SCOPES:
            raise ValueError(
                f"invalid override scope {self.scope!r}; "
                f"expected one of {_OVERRIDE_SCOPES}"
            )
        if self.scope == "project":
            if not self.project_key:
                raise ValueError(
                    "a project-scope override requires an absolute project key"
                )
            # The key must be an ABSOLUTE host path: render uses it verbatim as
            # the Claude `projects` map key, which Claude keys by absolute path
            # (ADR 0004). A relative value (e.g. a bare display name like "App")
            # would write a Project profile that render can never match to a real
            # Claude record, silently failing to apply the server. Reject it here
            # so the wizard / `add` picker can only pass a resolved absolute key.
            if not os.path.isabs(self.project_key):
                raise ValueError(
                    "a project-scope override requires an ABSOLUTE project key "
                    f"(got {self.project_key!r}); pass the resolved host path, "
                    "not a bare Project name"
                )


def _effective_scope(
    m: MergedCandidate, override: Optional[ScopeOverride]
) -> tuple[str, str]:
    """Resolve the (scope, project_key) an apply will actually write.

    With no override, the candidate's inherited scope/project is preserved
    exactly (project_key is "" for global). With an override, the chosen scope
    wins: global drops any project key; project carries the override's absolute
    key. This single resolver is used for the slot key, the profile path, and the
    secret store path so all three stay consistent.
    """
    cand = m.candidate
    if override is None:
        return (cand.source_scope, cand.source_project or "")
    if override.scope == "global":
        return ("global", "")
    return ("project", override.project_key)


def _slot_key(
    m: MergedCandidate, override: Optional[ScopeOverride] = None
) -> tuple[str, str, str]:
    """The profile slot a candidate would occupy: (scope, project key, name).

    Computed from the EFFECTIVE scope (post-override) so the slot-conflict guard
    fires when two selected candidates collide on the same target after their
    scopes are overridden — not just on their inherited scopes.
    """
    scope, project_key = _effective_scope(m, override)
    return (scope, project_key, m.candidate.name)


def apply_candidate(
    m: MergedCandidate, override: Optional[ScopeOverride] = None
) -> AppliedServer:
    """Apply one applicable candidate to the scope-correct profile + secrets.

    With no override, preserves inherited scope: a global source writes the
    global profile; a project source writes the Project profile keyed by the
    source project. With a ``ScopeOverride``, the CHOSEN scope wins instead
    (ADR 0013 amendment): ``global`` writes the global profile + global secret
    store; ``project`` + an absolute key writes that Project's profile + that
    Project's secret store. Either way, any flagged secret env VALUES are copied
    into the secret store matching the EFFECTIVE scope, so a project->global
    switch lands the credential in the global store (and vice versa). Returns a
    secret-free outcome.
    """
    cand = m.candidate
    scope, project_key = _effective_scope(m, override)

    # 1. Secret VALUES (in memory only) for the names flagged secret. Every
    #    declared secret key MUST resolve to a value, or we refuse to write an
    #    entry the secret store cannot back.
    secret_values = read_secret_values(cand)
    missing = [k for k in cand.command.secret_env_keys if k not in secret_values]
    if missing:
        raise MissingSecretsError(cand.name, sorted(missing))
    copied_keys = sorted(secret_values)

    applied = AppliedServer(
        name=cand.name,
        import_id=m.import_id,
        scope=scope,
        project_key=project_key,
        profile_path=profile_path(scope, project_key or None),
        copied_secret_keys=copied_keys,
    )

    # 2. LOAD + validate the profile BEFORE touching the secret store. A
    #    malformed existing profile raises here, so we never persist credentials
    #    for a server we then fail to import. Building the entry now also keeps
    #    all secret-free profile work ahead of the secret write.
    profile = load_profile(applied.profile_path)
    # Record the ORIGINAL (full) project key in the project profile. The profile
    # FILENAME is a sanitized+hashed label from which the absolute key is not
    # recoverable; render needs the real key so the rendered wrapper call carries
    # ``--project <full-key>`` and the wrapper can resolve the matching profile /
    # secret store at launch (otherwise it would re-hash the label and miss).
    # Non-secret identity (an absolute path); never written for global scope.
    if scope == "project" and project_key:
        profile["projectKey"] = project_key
    # Carry over NON-secret env values the source set inline (e.g. BASE_URL) so
    # the wrapper, which requires every declared env name at launch, can start the
    # server without the user re-exporting them. Secret values stay out of the
    # profile and live only in the 0600 store (handled below).
    nonsecret_values = read_nonsecret_values(cand)
    profile["servers"][cand.name] = build_server_entry(
        name=cand.name,
        argv=cand.command.argv,
        env_keys=cand.command.env_keys,
        secret_env_keys=cand.command.secret_env_keys,
        type_=cand.type,
        source_provider=cand.provider,
        import_id=m.import_id,
        env=nonsecret_values,
    )

    # 3. Persist secrets, then commit the profile. Always call store: with
    #    values it replaces the block; with none it PURGES any stale block left
    #    by an earlier import (replace semantics). The profile is committed last;
    #    if its save fails, the secret block is rolled back to its PRIOR state
    #    (not merely deleted) so a re-import that fails leaves the existing
    #    server's credentials intact rather than wiping them.
    s_path = secrets_path(scope, project_key or None)
    prior_block = read_server_secrets(s_path, cand.name)
    store_server_secrets(s_path, cand.name, secret_values)
    if secret_values:
        applied.secrets_path = s_path
    try:
        save_profile(applied.profile_path, profile)
    except Exception:
        # Restore the prior secret block to keep store and profile consistent.
        restore_server_secrets(s_path, cand.name, prior_block)
        raise

    return applied


def apply_selection(
    selected: list[MergedCandidate],
    overrides: Optional[dict[str, ScopeOverride]] = None,
) -> ApplyResult:
    """Apply a list of already-chosen candidates; skip the non-applicable ones.

    Applicable (``container``) candidates are written; everything else is
    recorded in ``skipped`` with a reason so the caller's summary stays honest
    rather than silently dropping a selection the user made.

    ``overrides`` is an optional ``import_id -> ScopeOverride`` map (ADR 0013
    amendment). A candidate listed there is applied to the overridden scope
    instead of its inherited one; a candidate absent from the map keeps its
    inherited scope (byte-for-byte the previous behavior). Passing ``None`` /
    an empty map preserves the inherited scope for everything.

    Raises ``ApplyConflictError`` BEFORE writing anything if two applicable
    selected candidates would occupy the same EFFECTIVE profile slot (same
    name+scope+project AFTER any override). Writing both would overwrite one
    entry while reporting both as applied; refusing keeps the profile consistent
    with the selection. The guard uses the post-override slot so a conflict
    introduced by overriding two servers onto the same target is still caught.
    """
    overrides = overrides or {}

    # Pre-flight: reject same-slot collisions among the applicable selection,
    # using the EFFECTIVE (post-override) slot for each candidate.
    by_slot: dict[tuple[str, str, str], list[MergedCandidate]] = {}
    for m in selected:
        if is_applicable(m):
            by_slot.setdefault(
                _slot_key(m, overrides.get(m.import_id)), []
            ).append(m)
    for (scope, project, name), members in by_slot.items():
        if len(members) > 1:
            ids = ", ".join(mm.import_id for mm in members)
            where = f"{scope}:{project}" if project else scope
            raise ApplyConflictError(
                f"selection has {len(members)} candidates for {name!r} in "
                f"scope {where}; they would overwrite each other. "
                f"Choose exactly one with --import-id ({ids})."
            )

    result = ApplyResult()
    for m in selected:
        if not is_applicable(m):
            result.skipped.append(
                {
                    "name": m.candidate.name,
                    "importId": m.import_id,
                    "reason": not_applicable_reason(m),
                }
            )
            continue
        try:
            result.applied.append(
                apply_candidate(m, overrides.get(m.import_id))
            )
        except MissingSecretsError as exc:
            # Could not recover the promised secret(s): skip rather than write a
            # profile entry the secret store cannot back. Names only — never
            # values — in the reason.
            result.skipped.append(
                {
                    "name": m.candidate.name,
                    "importId": m.import_id,
                    "reason": (
                        "could not recover secret value(s) for "
                        f"{', '.join(exc.missing)}; not applied"
                    ),
                }
            )
    return result
