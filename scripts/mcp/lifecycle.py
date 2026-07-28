"""Day-to-day MCP profile lifecycle: list / enable / disable / remove / doctor.

Issue 08 (ADR 0013, local-plan-mcp.md decisions 20-23). Issues 02-07 built
discovery, classification, apply, the canonical profile, render preview, the
real render write, and the ``boxa-mcp-run`` wrapper. This module adds the
management surface that makes the profile understandable and editable WITHOUT
hand-editing JSON:

  * ``effective_list`` — the effective MCP profile for the current Project
    (global + Project, with a Project entry SHADOWING a global one of the same
    name), plus the broader ``--all`` and ``--inherited`` views;
  * ``set_enabled`` — flip a server's ``enabled`` flag in the scope-correct
    profile (a Project disable of a global server creates a Project-scoped
    disable override; it NEVER mutates the global entry);
  * ``remove_server`` — delete ONLY a boxa-managed profile entry for one
    scope; runtime/secret purge is explicit (``purge=True``), never implicit;
  * ``run_doctor`` — diagnose profile / render / runtime problems and emit
    concrete repair commands;
  * ``apply_doctor_fixes`` — perform ONLY safe local fixes (re-render, create
    missing MCP dirs, repair the wrapper symlink). Never installs packages,
    allows domains, purges runtime, or enables host-only servers.

SECRET-FREE: nothing here ever reads or emits a secret VALUE. The secret store
is touched only to PURGE a server block on an explicit ``--purge`` remove, and
even then only key NAMES are ever reported.
"""

from __future__ import annotations

import os
import json
import shutil
import subprocess
import tomllib
from dataclasses import dataclass, field
from typing import Any, Optional

from . import identity
from .profile import (
    config_root,
    global_profile_path,
    load_profile,
    project_profile_path,
    save_profile,
)
from .render import (
    WRAPPER_COMMAND,
    build_render_plan,
    is_boxa_managed,
    rendered_name,
)
from .secrets import (
    global_secrets_path,
    load_secrets,
    project_secrets_path,
    save_secrets,
)


class LifecycleError(RuntimeError):
    """A lifecycle command failure with a user-actionable, SECRET-FREE message."""


def _runtime_label(argv: list[str]) -> str:
    """Coarse runtime family for the list view's RUNTIME column.

    Derived from argv[0] only (the launcher), never from secret-bearing args.
    Mirrors ``mcp.cli._runtime_label`` but operates on a profile argv array.
    """
    if not argv:
        return "-"
    base = argv[0].rsplit("/", 1)[-1].lower()
    node = {"npx", "npm", "pnpm", "yarn", "bunx", "node"}
    python = {"uvx", "uv", "python", "python3", "pipx"}
    docker = {"docker", "podman"}
    if base in node:
        return "node"
    if base in python:
        return "python"
    if base in docker:
        return "docker"
    return base or "-"


# -- effective list -----------------------------------------------------------


@dataclass
class ProfileEntry:
    """One profile server in the effective view (SECRET-FREE).

    ``status`` is ``enabled``/``disabled``; ``shadowed`` marks a global entry a
    Project entry of the same name overrides for the current Project. ``runtime``
    is a coarse launcher family; ``env_keys``/``secret_env_keys`` are NAMES only.
    """

    name: str
    scope: str  # "global" or "project"
    project_key: str  # "" for global
    enabled: bool
    runtime: str
    env_keys: list[str] = field(default_factory=list)
    secret_env_keys: list[str] = field(default_factory=list)
    source_provider: str = ""
    import_id: str = ""
    shadowed: bool = False

    @property
    def status(self) -> str:
        return "enabled" if self.enabled else "disabled"

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "name": self.name,
            "scope": self.scope,
            "status": self.status,
            "enabled": self.enabled,
            "runtime": self.runtime,
            "renderedName": rendered_name(self.name),
            # NAMES only — values live 0600 in the secret store, never here.
            "envKeys": list(self.env_keys),
            "secretEnvKeys": list(self.secret_env_keys),
            "shadowed": self.shadowed,
        }
        if self.project_key:
            out["project"] = self.project_key
        if self.source_provider:
            out["sourceProvider"] = self.source_provider
        if self.import_id:
            out["importId"] = self.import_id
        return out


def _entries_from_profile(
    path: str, scope: str, project_key: str
) -> list[ProfileEntry]:
    """Read one profile file into ProfileEntry rows (SECRET-FREE).

    A malformed profile raises ``LifecycleError`` rather than silently dropping
    state — the caller surfaces it as a doctor finding / command error.
    """
    try:
        profile = load_profile(path)
    except (OSError, ValueError, RuntimeError) as exc:
        raise LifecycleError(f"cannot read MCP profile {path}: {exc}") from exc
    servers = profile.get("servers", {})
    if not isinstance(servers, dict):
        return []
    out: list[ProfileEntry] = []
    for name in sorted(servers):
        spec = servers[name]
        if not isinstance(spec, dict):
            continue
        command = spec.get("command")
        argv = command.get("argv") if isinstance(command, dict) else None
        argv = [str(a) for a in argv] if isinstance(argv, list) else []
        env_keys = spec.get("envKeys")
        secret_env_keys = spec.get("secretEnvKeys")
        source = spec.get("source")
        out.append(
            ProfileEntry(
                name=str(name),
                scope=scope,
                project_key=project_key,
                enabled=spec.get("enabled") is not False,
                runtime=_runtime_label(argv),
                env_keys=[str(k) for k in env_keys]
                if isinstance(env_keys, list)
                else [],
                secret_env_keys=[str(k) for k in secret_env_keys]
                if isinstance(secret_env_keys, list)
                else [],
                source_provider=str(source.get("provider", ""))
                if isinstance(source, dict)
                else "",
                import_id=str(source.get("importId", ""))
                if isinstance(source, dict)
                else "",
            )
        )
    return out


def _project_key_recorded(path: str) -> str:
    """The full project key a project profile recorded at apply time, or "".

    The profile FILENAME is a sanitized+hashed label; the absolute key lives in
    the ``projectKey`` field. Non-secret identity only.
    """
    try:
        profile = load_profile(path)
    except (OSError, ValueError):
        return ""
    key = profile.get("projectKey")
    return key if isinstance(key, str) and key else ""


def collect_global_entries() -> list[ProfileEntry]:
    """Every server in the global profile."""
    return _entries_from_profile(global_profile_path(), "global", "")


def collect_project_entries(
    project_keys: Optional[list[str]] = None,
) -> list[ProfileEntry]:
    """Project profile servers for the given keys, or every project profile.

    When ``project_keys`` is given, only those projects' profiles are read
    (their full key carried through for the shadow check / render). With no
    keys, every project profile file under the projects directory is scanned so
    ``--all`` can show the full project surface.
    """
    root = config_root()
    out: list[ProfileEntry] = []
    if project_keys:
        for key in project_keys:
            out.extend(
                _entries_from_profile(project_profile_path(key), "project", key)
            )
        return out

    projects_dir = os.path.join(root, "projects")
    if not os.path.isdir(projects_dir):
        return out
    for filename in sorted(os.listdir(projects_dir)):
        # Project PROFILE files only — the parallel ``*.secrets.json`` store is
        # owner-only credential state and must never be read here.
        if not filename.endswith(".json") or filename.endswith(".secrets.json"):
            continue
        path = os.path.join(projects_dir, filename)
        # Prefer the recorded full key (so the row's project label and any later
        # render carry a resolvable key); fall back to the file label.
        key = _project_key_recorded(path) or filename[:-5]
        out.extend(_entries_from_profile(path, "project", key))
    return out


@dataclass
class EffectiveList:
    """The effective profile list result (SECRET-FREE), for text + JSON paths."""

    entries: list[ProfileEntry] = field(default_factory=list)
    scope_label: str = ""  # how the view was scoped, for the human summary

    def to_dict(self) -> dict[str, Any]:
        return {
            "scope": self.scope_label,
            "servers": [e.to_dict() for e in self.entries],
        }


def effective_list(
    project_keys: Optional[list[str]] = None,
    all_projects: bool = False,
) -> EffectiveList:
    """Build the effective MCP profile view.

    Default (``project_keys`` set, ``all_projects`` False): the effective
    profile for those Project(s) — global entries PLUS the Project entries, with
    a Project entry SHADOWING a global entry of the same name (the global row is
    kept and marked ``shadowed`` so the user sees what the Project overrode, per
    decision 22/29).

    ``all_projects``: global plus EVERY project profile, no shadowing collapse
    (each project's entries are shown in full) — the broad ``--all`` view.
    """
    globals_ = collect_global_entries()

    if all_projects:
        projects = collect_project_entries(None)
        return EffectiveList(
            entries=globals_ + projects, scope_label="all"
        )

    projects = collect_project_entries(project_keys)
    # Names a Project entry provides shadow the same-named global entry for that
    # Project's effective view.
    project_names = {e.name for e in projects}
    for g in globals_:
        if g.name in project_names:
            g.shadowed = True
    label = (
        "project: " + ", ".join(project_keys)
        if project_keys
        else "current project"
    )
    return EffectiveList(entries=globals_ + projects, scope_label=label)


# -- enable / disable ----------------------------------------------------------


@dataclass
class ToggleResult:
    """Outcome of an enable/disable (SECRET-FREE)."""

    name: str
    scope: str
    project_key: str
    enabled: bool
    created_override: bool  # True when a Project disable created a new override
    no_op: bool  # True when the flag was already in the requested state

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "name": self.name,
            "scope": self.scope,
            "enabled": self.enabled,
            "createdOverride": self.created_override,
            "noOp": self.no_op,
        }
        if self.project_key:
            out["project"] = self.project_key
        if self.created_override:
            # A project-only disable of a global server is enforced for Claude
            # (project record shadow) but NOT for Codex (no per-project MCP
            # scope). Machine consumers can branch on this.
            out["codexEnforced"] = False
        return out


def _global_disable_override_entry(name: str) -> dict[str, Any]:
    """A minimal Project-scoped DISABLE override for a global server.

    A Project disable of a server that exists only globally must NOT mutate the
    global entry (decision 20: a Project disable disables a global server only
    for that Project). We instead record a tiny disabled stub in the Project
    profile; render's per-scope shadowing then keeps the server out of THAT
    project while leaving it enabled everywhere else. SECRET-FREE: no command or
    env is copied — this is a pure override marker.
    """
    return {
        "name": name,
        "enabled": False,
        "source": {"provider": "boxa", "importId": "override"},
    }


def set_enabled(
    name: str,
    scope: str,
    project_key: Optional[str],
    enabled: bool,
) -> ToggleResult:
    """Flip a server's ``enabled`` flag in the scope-correct profile.

    Rules (decision 20):

      * ``scope == "global"``: toggle the global profile entry; the server must
        exist globally or it is an error.
      * ``scope == "project"`` + an existing Project entry: toggle it.
      * ``scope == "project"`` + NO Project entry but a global entry exists, and
        ``enabled`` is False: create a Project-scoped DISABLE OVERRIDE so the
        server is disabled for THIS project only — the global entry is left
        untouched. Re-enabling for the project then removes that override.
      * Otherwise (no such server in scope): an error.

    Auto-render is the caller's job (the shell front-end), so this only mutates
    profile state and returns a secret-free outcome.
    """
    if scope == "global":
        path = global_profile_path()
        profile = load_profile(path)
        servers = profile.setdefault("servers", {})
        spec = servers.get(name)
        if not isinstance(spec, dict):
            raise LifecycleError(
                f"no global MCP server named {name!r} in the boxa profile. "
                "List servers with 'boxa mcp list --all'."
            )
        current = spec.get("enabled") is not False
        if current == enabled:
            return ToggleResult(name, "global", "", enabled, False, no_op=True)
        if enabled:
            # Re-enabling: drop the flag so the entry returns to the default
            # (enabled) shape rather than carrying a redundant ``enabled: true``.
            spec.pop("enabled", None)
        else:
            spec["enabled"] = False
        save_profile(path, profile)
        return ToggleResult(name, "global", "", enabled, False, no_op=False)

    if scope != "project" or not project_key:
        raise LifecycleError("project scope requires a project key")

    path = project_profile_path(project_key)
    profile = load_profile(path)
    servers = profile.setdefault("servers", {})
    spec = servers.get(name)

    if isinstance(spec, dict):
        current = spec.get("enabled") is not False
        if current == enabled:
            return ToggleResult(
                name, "project", project_key, enabled, False, no_op=True
            )
        # If this entry is a pure disable OVERRIDE (no command of its own) and we
        # are re-enabling it, drop the override entirely so the global entry
        # shows through again for this project.
        is_override = "command" not in spec
        if enabled and is_override:
            del servers[name]
            profile["projectKey"] = project_key
            save_profile(path, profile)
            return ToggleResult(
                name, "project", project_key, True, False, no_op=False
            )
        if enabled:
            spec.pop("enabled", None)
        else:
            spec["enabled"] = False
        profile["projectKey"] = project_key
        save_profile(path, profile)
        return ToggleResult(
            name, "project", project_key, enabled, False, no_op=False
        )

    # No Project entry. A Project DISABLE of a global server is allowed via an
    # override; a Project ENABLE with nothing to enable is an error.
    if enabled:
        raise LifecycleError(
            f"no project MCP server named {name!r} for {project_key!r}. "
            f"Nothing to enable. (A global server is enabled via "
            f"'boxa mcp enable {name} --global'.)"
        )
    global_has = _global_has_server(name)
    if not global_has:
        raise LifecycleError(
            f"no MCP server named {name!r} found globally or for "
            f"{project_key!r}; nothing to disable."
        )
    servers[name] = _global_disable_override_entry(name)
    profile["projectKey"] = project_key
    save_profile(path, profile)
    return ToggleResult(
        name, "project", project_key, False, created_override=True, no_op=False
    )


def _global_has_server(name: str) -> bool:
    profile = load_profile(global_profile_path())
    servers = profile.get("servers", {})
    return isinstance(servers, dict) and isinstance(servers.get(name), dict)


# -- remove --------------------------------------------------------------------


@dataclass
class RemoveResult:
    """Outcome of a remove (SECRET-FREE)."""

    name: str
    scope: str
    project_key: str
    removed: bool
    purged_secret_keys: list[str] = field(default_factory=list)
    secrets_purged: bool = False

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "name": self.name,
            "scope": self.scope,
            "removed": self.removed,
            # NAMES only.
            "purgedSecretKeys": list(self.purged_secret_keys),
            "secretsPurged": self.secrets_purged,
        }
        if self.project_key:
            out["project"] = self.project_key
        return out


def server_has_secrets(
    name: str, scope: str, project_key: Optional[str]
) -> list[str]:
    """Return the secret KEY NAMES stored for a server in its scope, or [].

    Used to tell the caller whether a remove would orphan a secret block (so it
    can require confirmation / ``--purge``). NEVER returns values.
    """
    s_path = (
        project_secrets_path(project_key)
        if scope == "project" and project_key
        else global_secrets_path()
    )
    if not os.path.isfile(s_path):
        return []
    try:
        store = load_secrets(s_path)
    except (OSError, ValueError):
        return []
    block = store.get("servers", {}).get(name)
    if not isinstance(block, dict):
        return []
    return sorted(str(k) for k in block)


def remove_server(
    name: str,
    scope: str,
    project_key: Optional[str],
    purge: bool = False,
) -> RemoveResult:
    """Remove a boxa-managed profile entry for ONE scope.

    Removes ONLY the boxa profile entry — it never touches inherited/manual
    agent config (that is owned by the agent, and re-render only ever rewrites
    ``boxa-`` entries, so dropping the profile entry then re-rendering cleanly
    removes the rendered ``boxa-`` entry too). The agent's own non-boxa MCP
    entries are out of boxa's reach entirely.

    Secret purge is NOT implicit: a server's copied secret block is deleted only
    when ``purge=True``. Without it, the secret block is LEFT in place (the
    caller is expected to have required confirmation or ``--purge`` first). A
    Project remove purges only that Project's secret block; global secrets are
    never touched by a Project operation (decision 25).
    """
    if scope == "project":
        if not project_key:
            raise LifecycleError("project scope requires a project key")
        path = project_profile_path(project_key)
    elif scope == "global":
        path = global_profile_path()
    else:
        raise LifecycleError(f"unknown scope {scope!r}")

    profile = load_profile(path)
    servers = profile.get("servers", {})
    entry_present = isinstance(servers, dict) and name in servers

    if not entry_present:
        # The profile entry is gone. With --purge we still let the caller reach
        # any ORPHANED scoped secret block (e.g. a prior non-purge remove that
        # followed the CLI's "re-run with --purge" advice). Without --purge there
        # is genuinely nothing to do, so it stays an error.
        if not purge:
            where = f"project {project_key}" if scope == "project" else "global"
            raise LifecycleError(
                f"no boxa MCP server named {name!r} in the {where} profile; "
                "nothing to remove. (boxa remove only deletes boxa-managed "
                "profile entries, never inherited/manual agent config.)"
            )
        orphan_keys = _purge_server_secrets(name, scope, project_key)
        if not orphan_keys:
            where = f"project {project_key}" if scope == "project" else "global"
            raise LifecycleError(
                f"no boxa MCP server named {name!r} in the {where} profile "
                "and no orphaned secrets to purge; nothing to remove."
            )
        # The profile entry was already gone (removed=False), but we cleaned up
        # the orphaned secret block — a successful, idempotent purge.
        return RemoveResult(
            name=name,
            scope=scope,
            project_key=project_key or "",
            removed=False,
            purged_secret_keys=orphan_keys,
            secrets_purged=True,
        )

    result = RemoveResult(
        name=name, scope=scope, project_key=project_key or "", removed=True
    )
    # Purge the secret block FIRST, before deleting the profile entry. If the
    # secret store is unreadable, the purge raises and the profile entry is left
    # intact — so re-running 'remove --purge' after repairing the store can still
    # find the server and complete the purge, rather than orphaning credentials
    # the user can no longer reach through the command.
    if purge:
        purged = _purge_server_secrets(name, scope, project_key)
        result.purged_secret_keys = purged
        result.secrets_purged = True

    del servers[name]
    save_profile(path, profile)
    return result


def _purge_server_secrets(
    name: str, scope: str, project_key: Optional[str]
) -> list[str]:
    """Delete a server's secret block from its scoped store; return key NAMES.

    Returns the names of the keys removed (never values). A Project purge only
    touches the Project store; the global store is untouched, and vice versa.
    """
    s_path = (
        project_secrets_path(project_key)
        if scope == "project" and project_key
        else global_secrets_path()
    )
    if not os.path.isfile(s_path):
        return []
    try:
        store = load_secrets(s_path)
    except (OSError, ValueError) as exc:
        # A purge is a credential-DELETION operation. If the store cannot be read
        # we must NOT report success while the secret block stays on disk — that
        # would be a false "secrets purged" for a security-relevant action. Fail
        # loudly so the user fixes the store and re-runs (the profile entry was
        # already removed; re-running --purge after repair completes the purge).
        raise LifecycleError(
            f"cannot purge secrets: scoped secret store is unreadable: "
            f"{s_path}: {exc}"
        ) from exc
    block = store.get("servers", {}).get(name)
    if not isinstance(block, dict):
        return []
    keys = sorted(str(k) for k in block)
    del store["servers"][name]
    save_secrets(s_path, store)
    return keys


# -- doctor --------------------------------------------------------------------

# Severity ordering for a deterministic, readable report.
SEVERITY_ERROR = "error"
SEVERITY_WARN = "warning"
SEVERITY_INFO = "info"


@dataclass
class Finding:
    """One doctor finding (SECRET-FREE).

    ``repair`` is a concrete command (or short instruction) the user can run;
    ``fixable`` marks whether ``doctor --fix`` can safely resolve it locally.
    """

    severity: str
    code: str
    message: str
    repair: str = ""
    fixable: bool = False
    project: Optional[str] = None

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "severity": self.severity,
            "code": self.code,
            "message": self.message,
            "fixable": self.fixable,
        }
        if self.repair:
            out["repair"] = self.repair
        if self.project is not None:
            out["project"] = self.project
        return out


@dataclass
class DoctorReport:
    """The full doctor result (SECRET-FREE)."""

    inside_container: bool
    findings: list[Finding] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not any(f.severity == SEVERITY_ERROR for f in self.findings)

    def to_dict(self) -> dict[str, Any]:
        return {
            "insideContainer": self.inside_container,
            "ok": self.ok,
            "findings": [f.to_dict() for f in self.findings],
        }


def _wrapper_on_path() -> Optional[str]:
    """Resolve the ``boxa-mcp-run`` wrapper on PATH, or None.

    Used by doctor to verify rendered agent entries (which call the wrapper)
    will actually find it at launch.
    """
    path_env = os.environ.get("PATH", "")
    for directory in path_env.split(os.pathsep):
        if not directory:
            continue
        candidate = os.path.join(directory, WRAPPER_COMMAND)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _profile_validity_findings() -> list[Finding]:
    """Check every profile JSON file parses (decision 23: profile validity)."""
    findings: list[Finding] = []
    paths = [global_profile_path()]
    projects_dir = os.path.join(config_root(), "projects")
    if os.path.isdir(projects_dir):
        for filename in sorted(os.listdir(projects_dir)):
            if not filename.endswith(".json") or filename.endswith(
                ".secrets.json"
            ):
                continue
            paths.append(os.path.join(projects_dir, filename))
    for path in paths:
        if not os.path.isfile(path):
            continue
        try:
            load_profile(path)
        except (OSError, ValueError, RuntimeError) as exc:
            findings.append(
                Finding(
                    severity=SEVERITY_ERROR,
                    code="profile-malformed",
                    message=f"MCP profile is malformed: {path}: {exc}",
                    repair=(
                        f"Fix or remove the malformed profile file: {path}"
                    ),
                    fixable=False,
                )
            )
    return findings


def _render_drift_findings(plan) -> list[Finding]:
    """Compare planned boxa-managed entries against what is rendered.

    Drift = the set of boxa-managed names ALREADY in an agent config differs
    from the set the current profile would render. Reported as a warning with a
    re-render repair, which ``--fix`` can perform safely.
    """
    from collections import Counter

    findings: list[Finding] = []
    for agent_plan in (plan.claude, plan.codex):
        if not agent_plan.supported:
            findings.append(
                Finding(
                    severity=SEVERITY_INFO,
                    code="render-unsupported",
                    message=(
                        f"{agent_plan.agent} render is unsupported here: "
                        f"{agent_plan.unsupported_reason}"
                    ),
                    repair="",
                    fixable=False,
                )
            )
            continue

        # Compare as MULTISETS keyed by rendered name AND placement (scope +
        # project record), not by name alone. Two cases this guards:
        #   * a project disable override adds a SECOND planned entry with the
        #     same rendered name as the global one but a different record;
        #   * a project server re-scoped from one project to another keeps the
        #     same rendered name but moves records.
        # A name-only comparison would call both "already rendered" and skip the
        # re-render, leaving Claude config wrong. Placement keys catch them.
        #
        # Claude exposes per-record placement; Codex has a SINGLE global table
        # (no project records), so its existing entries are all global and the
        # planned set is global-only — a name multiset is exact there.
        if agent_plan.agent == "claude-code":
            planned_counts = Counter(
                _claude_placement_key(e.rendered_name, e.scope, e.project_key)
                for e in agent_plan.planned
            )
            existing_counts = Counter(
                _claude_existing_placement_keys(agent_plan.config_path)
            )
        else:
            planned_counts = Counter(e.rendered_name for e in agent_plan.planned)
            existing_counts = Counter(agent_plan.managed_existing)

        if planned_counts != existing_counts:
            missing = sorted(
                _drift_label(k) for k in (planned_counts - existing_counts).elements()
            )
            stale = sorted(
                _drift_label(k) for k in (existing_counts - planned_counts).elements()
            )
            detail_parts = []
            if missing:
                detail_parts.append(f"not yet rendered: {', '.join(missing)}")
            if stale:
                detail_parts.append(f"stale rendered: {', '.join(stale)}")
            findings.append(
                Finding(
                    severity=SEVERITY_WARN,
                    code="render-drift",
                    message=(
                        f"{agent_plan.agent} rendered boxa- entries are out of "
                        f"sync with the profile ({'; '.join(detail_parts)})."
                    ),
                    repair="boxa mcp render",
                    fixable=True,
                )
            )
    return findings


def _claude_placement_key(name: str, scope: str, project_key: str) -> str:
    """Stable placement key for a Claude boxa entry: name @ record location."""
    if scope == "project" and project_key:
        return f"{name}@project:{project_key}"
    return f"{name}@global"


def _drift_label(key) -> str:
    """Human-readable label for a drift element (name, or name@placement)."""
    return str(key)


def _claude_existing_placement_keys(config_path: str) -> list[str]:
    """Placement keys for the boxa-managed entries already in Claude config.

    Reads the top-level ``mcpServers`` block (global placement) and every
    project record's ``mcpServers`` block (project placement, keyed by the record
    key), returning a placement key per boxa-managed entry. READ-ONLY; any
    IO/parse error degrades to an empty list (the validity check already flags a
    malformed profile, and a malformed AGENT config is surfaced as drift simply
    by yielding no existing entries).
    """
    import json as _json

    if not os.path.isfile(config_path):
        return []
    try:
        with open(config_path, "r", encoding="utf-8") as fh:
            data = _json.load(fh)
    except (OSError, ValueError):
        return []
    if not isinstance(data, dict):
        return []
    keys: list[str] = []
    block = data.get("mcpServers")
    if isinstance(block, dict):
        for n in block:
            if is_boxa_managed(str(n)):
                keys.append(_claude_placement_key(str(n), "global", ""))
    projects = data.get("projects")
    if isinstance(projects, dict):
        for record_key, record in projects.items():
            if not isinstance(record, dict):
                continue
            pblock = record.get("mcpServers")
            if isinstance(pblock, dict):
                for n in pblock:
                    if is_boxa_managed(str(n)):
                        keys.append(
                            _claude_placement_key(
                                str(n), "project", str(record_key)
                            )
                        )
    return keys


def _missing_env_findings(plan) -> list[Finding]:
    """Flag enabled servers whose required env NAMES have no resolvable value.

    Mirrors the wrapper's resolution rule (decision 23: required env exists)
    WITHOUT reading any secret value: a key resolves if it is in the current
    environment, OR carried as a non-secret value in the profile, OR present in
    the scoped secret store. We only ever check for PRESENCE, never read a value.
    Names only in the finding.
    """
    findings: list[Finding] = []
    for srv in plan.renderable_servers:
        missing = _missing_env_keys(srv)
        if missing:
            findings.append(
                Finding(
                    severity=SEVERITY_WARN,
                    code="missing-env",
                    message=(
                        f"MCP server {srv.name!r} "
                        f"({srv.scope}) is missing env value(s): "
                        f"{', '.join(missing)} (values never shown)."
                    ),
                    repair=(
                        "Set the variable(s) in the environment or re-import the "
                        "server so boxa copies the credential into its 0600 "
                        "secret store."
                    ),
                    fixable=False,
                )
            )
    return findings


def _missing_env_keys(srv) -> list[str]:
    """Names of a profile server's declared env keys with no resolvable value.

    PRESENCE-ONLY: never reads a secret value. A key is satisfied when it is in
    ``os.environ``, recorded as a non-secret value in the profile ``env`` map,
    or present (by name) in the scoped secret store.
    """
    path = (
        project_profile_path(srv.project_key)
        if srv.scope == "project" and srv.project_key
        else global_profile_path()
    )
    try:
        profile = load_profile(path)
    except (OSError, ValueError):
        return []
    spec = profile.get("servers", {}).get(srv.name)
    if not isinstance(spec, dict):
        return []
    env_keys = spec.get("envKeys")
    secret_env_keys = spec.get("secretEnvKeys")
    env_keys = [str(k) for k in env_keys] if isinstance(env_keys, list) else []
    secret_keys = (
        {str(k) for k in secret_env_keys}
        if isinstance(secret_env_keys, list)
        else set()
    )
    all_keys = list(dict.fromkeys([*env_keys, *sorted(secret_keys)]))
    if not all_keys:
        return []
    profile_env = spec.get("env")
    profile_env = profile_env if isinstance(profile_env, dict) else {}

    s_path = (
        project_secrets_path(srv.project_key)
        if srv.scope == "project" and srv.project_key
        else global_secrets_path()
    )
    stored_keys: set[str] = set()
    if os.path.isfile(s_path):
        try:
            store = load_secrets(s_path)
            block = store.get("servers", {}).get(srv.name)
            if isinstance(block, dict):
                stored_keys = {str(k) for k in block}
        except (OSError, ValueError):
            stored_keys = set()

    missing: list[str] = []
    for key in all_keys:
        if key in os.environ:
            continue
        if key in profile_env:
            continue
        if key in stored_keys:
            continue
        missing.append(key)
    return missing


def _server_launcher(srv) -> str:
    """The launch command (argv[0]) for a renderable profile server, or "".

    Reads NAMES/command shape only from the scope-correct profile (no secrets).
    """
    path = (
        project_profile_path(srv.project_key)
        if srv.scope == "project" and srv.project_key
        else global_profile_path()
    )
    try:
        profile = load_profile(path)
    except (OSError, ValueError):
        return ""
    spec = profile.get("servers", {}).get(srv.name)
    if not isinstance(spec, dict):
        return ""
    command = spec.get("command")
    argv = command.get("argv") if isinstance(command, dict) else None
    if isinstance(argv, list) and argv:
        return str(argv[0])
    return ""


def _missing_launcher_findings(plan) -> list[Finding]:
    """Flag enabled servers whose launch command (argv[0]) is not on PATH.

    Decision 23: doctor should verify the runtime command exists or is
    launchable. A relative/bare command is resolved via ``shutil.which``; an
    absolute path is checked for existence + executability. A missing launcher
    is a warning (the runtime may be installable later via 'boxa mcp install',
    a future slice), not a hard error — but it must be visible so a server that
    will fail at launch is not declared healthy. NEVER installs anything.
    """
    findings: list[Finding] = []
    for srv in plan.renderable_servers:
        launcher = _server_launcher(srv)
        if not launcher:
            continue
        if os.path.isabs(launcher):
            available = os.path.isfile(launcher) and os.access(launcher, os.X_OK)
        else:
            available = shutil.which(launcher) is not None
        if not available:
            findings.append(
                Finding(
                    severity=SEVERITY_WARN,
                    code="missing-launcher",
                    message=(
                        f"MCP server {srv.name!r} ({srv.scope}) launch command "
                        f"{launcher!r} is not available on PATH; the wrapper "
                        "would fail to launch it."
                    ),
                    repair=(
                        f"Install {launcher!r} in the Container (add it to the "
                        "Dockerfile), or materialize the server runtime once "
                        "'boxa mcp install' is available."
                    ),
                    fixable=False,
                )
            )
    return findings


def run_doctor() -> DoctorReport:
    """Diagnose MCP profile / render / runtime problems (READ-ONLY, SECRET-FREE).

    Checks (decision 23): host vs Container context, wrapper availability,
    canonical profile validity, render drift (profile vs rendered config),
    and required env presence. Never reads or emits a secret value, never
    installs anything, never writes any config.
    """
    inside = identity.inside_container()
    report = DoctorReport(inside_container=inside)

    # ADR 0021 catalog diagnostics.  Keep these alongside the legacy checks
    # during the one-way migration window; catalog state is the authoritative
    # operating path and each finding names its boundary explicitly.
    report.findings.extend(_catalog_doctor_findings())

    # Context check.
    if not inside:
        report.findings.append(
            Finding(
                severity=SEVERITY_INFO,
                code="not-in-container",
                message=(
                    "Not running inside a boxa Container; the boxa-mcp-run "
                    "wrapper refuses to launch MCP servers on the host. Render "
                    "and profile checks still apply."
                ),
                repair="Start an agent inside a boxa Container to launch MCP "
                "servers.",
                fixable=False,
            )
        )

    # Wrapper availability.
    if _wrapper_on_path() is None:
        report.findings.append(
            Finding(
                severity=SEVERITY_WARN if inside else SEVERITY_INFO,
                code="wrapper-missing",
                message=(
                    f"The {WRAPPER_COMMAND!r} wrapper is not on PATH; rendered "
                    "agent entries call it and would fail to launch."
                ),
                repair=(
                    "Run 'boxa mcp doctor --fix' to repair the wrapper "
                    "symlink, or reinstall boxa so the wrapper is on PATH."
                ),
                fixable=True,
            )
        )

    # A completed one-way migration deliberately retains legacy profiles only
    # for recovery. They must never become an authoritative render source again.
    migrated = False
    try:
        from .migration import migration_path
        with open(migration_path(), encoding="utf-8") as fh:
            migrated = json.load(fh).get("status") == "complete"
    except (OSError, ValueError, AttributeError):
        pass
    if migrated:
        return report

    # Profile validity. A malformed profile blocks render drift / env checks for
    # that file, so collect those findings and skip the plan-based checks if any
    # profile cannot be read (build_render_plan would also raise).
    validity = _profile_validity_findings()
    report.findings.extend(validity)
    if any(f.code == "profile-malformed" for f in validity):
        return report

    plan = build_render_plan(None)
    report.findings.extend(_render_drift_findings(plan))
    report.findings.extend(_missing_env_findings(plan))
    report.findings.extend(_missing_launcher_findings(plan))

    # Skipped (non-renderable) profile servers are an actionable info finding.
    for srv in plan.skipped:
        report.findings.append(
            Finding(
                severity=SEVERITY_WARN,
                code="server-skipped",
                message=(
                    f"MCP server {srv.name!r} cannot be rendered: "
                    f"{srv.skip_reason}"
                ),
                repair="Re-import the server for its project so boxa records a "
                "resolvable project key.",
                fixable=False,
            )
        )

    return report


# -- doctor --fix --------------------------------------------------------------


@dataclass
class FixResult:
    """Outcome of a doctor --fix run (SECRET-FREE)."""

    actions: list[str] = field(default_factory=list)
    remaining: list[Finding] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "actions": list(self.actions),
            "remaining": [f.to_dict() for f in self.remaining],
        }


def _ensure_mcp_dirs() -> list[str]:
    """Create missing boxa MCP config directories (safe local fix).

    Returns a list of human-readable action descriptions. Idempotent: an
    existing tree yields no actions.
    """
    actions: list[str] = []
    root = config_root()
    projects_dir = os.path.join(root, "projects")
    for directory in (root, projects_dir):
        if not os.path.isdir(directory):
            os.makedirs(directory, exist_ok=True)
            actions.append(f"created missing directory {directory}")
    return actions


def _repair_wrapper_symlink() -> list[str]:
    """Repair the ``boxa-mcp-run`` wrapper symlink IF a target is known.

    The wrapper is shipped as ``scripts/mcp-run.sh``; the install step normally
    symlinks it onto PATH. ``--fix`` can recreate that symlink in a writable
    PATH directory when the wrapper is missing, but it NEVER installs packages
    or modifies anything outside re-creating the symlink. When no writable PATH
    dir or no shipped wrapper is found, it reports nothing rather than guessing.
    """
    if _wrapper_on_path() is not None:
        return []
    # The shipped wrapper script lives alongside this package: scripts/mcp-run.sh.
    pkg_dir = os.path.dirname(os.path.abspath(__file__))
    scripts_dir = os.path.dirname(pkg_dir)
    wrapper_src = os.path.join(scripts_dir, "mcp-run.sh")
    if not os.path.isfile(wrapper_src):
        return []
    # The wrapper is invoked as a command, so it MUST be executable. A source-tree
    # checkout can lose the executable bit (e.g. extracted from a non-mode-aware
    # archive), which would leave the symlink unusable and make ``_wrapper_on_path``
    # still fail its X_OK check — so the "repair" would falsely report success.
    # Ensure the bit before linking so the fix is real.
    if not os.access(wrapper_src, os.X_OK):
        try:
            mode = os.stat(wrapper_src).st_mode
            os.chmod(wrapper_src, mode | 0o111)
        except OSError:
            return []
    # Prefer a writable, boxa-owned PATH dir. ``~/.local/bin`` is the
    # conventional user bin dir and is on PATH in boxa Containers.
    home = os.path.expanduser("~")
    target_dir = os.path.join(home, ".local", "bin")
    try:
        os.makedirs(target_dir, exist_ok=True)
    except OSError:
        return []
    link = os.path.join(target_dir, WRAPPER_COMMAND)
    try:
        if os.path.islink(link) or os.path.exists(link):
            os.unlink(link)
        os.symlink(wrapper_src, link)
    except OSError:
        return []
    # Sanity-check the linked wrapper is now actually launchable; if not, the
    # repair did not really fix anything and should not claim it did.
    if not (os.path.isfile(link) and os.access(link, os.X_OK)):
        return []
    return [f"linked {WRAPPER_COMMAND} -> {wrapper_src} in {target_dir}"]


def apply_doctor_fixes(report: DoctorReport) -> FixResult:
    """Apply ONLY safe local fixes for a doctor report (decision 23).

    Safe fixes: create missing MCP directories, repair the wrapper symlink, and
    re-render when render drift is detected. NEVER installs packages, allows
    domains, purges runtime, or enables host-only servers. Findings that are not
    safely fixable are returned in ``remaining`` so the user still sees them.
    """
    result = FixResult()
    render_failures: list[Finding] = []

    # 1. Always ensure the config dirs exist (cheap, idempotent).
    result.actions.extend(_ensure_mcp_dirs())

    # 2. Repair the wrapper symlink if a wrapper finding is present.
    if any(f.code == "wrapper-missing" for f in report.findings):
        result.actions.extend(_repair_wrapper_symlink())

    # 3. Re-render when drift was detected. This rewrites only boxa- entries.
    if any(
        f.code == "render-drift" and f.fixable for f in report.findings
    ):
        from .writer import RenderWriteError, write_plan

        plan = build_render_plan(None)
        try:
            written = write_plan(plan.claude, plan.codex)
            result.actions.append(
                "re-rendered boxa-managed entries into: "
                + (", ".join(written) if written else "no agents")
            )
        except RenderWriteError as exc:
            render_failures.append(
                Finding(
                    severity=SEVERITY_ERROR,
                    code="render-failed",
                    message=f"re-render failed: {exc}",
                    repair="Inspect the agent config and re-run "
                    "'boxa mcp render'.",
                    fixable=False,
                )
            )

    # Catalog activation renders and the secret-free runtime snapshot are
    # derived state. Repairing them is safe, but a tracked consumer config is
    # an explicit repository mutation and therefore never enters this branch.
    catalog_codes = {f.code for f in report.findings if f.fixable}
    # These repairs rewrite the very Project files and runtime snapshot an
    # in-Container convergence reads, so take the same host mutation lock every
    # other lifecycle write takes. That also publishes the mutation window
    # convergence observes, so a repair cannot be half-observed (ADR 0022).
    from .catalog import mutation_lock
    with mutation_lock():
        _apply_catalog_doctor_fixes(
            report, result, render_failures, catalog_codes
        )
    # Re-run doctor to capture what remains after the fixes, so the user sees the
    # honest post-fix state (e.g. a still-missing env var, or a wrapper we could
    # not relink). A render write that hard-failed is surfaced on top of the
    # fresh report so it is never lost.
    after = run_doctor()
    result.remaining = render_failures + list(after.findings)
    return result


def _apply_catalog_doctor_fixes(
    report: DoctorReport,
    result: FixResult,
    render_failures: list[Finding],
    catalog_codes: set[str],
) -> None:
    if "catalog-runtime-drift" in catalog_codes:
        try:
            from .activation import refresh_runtime
            refresh_runtime()
            result.actions.append("refreshed the secret-free MCP runtime snapshot")
        except (OSError, ValueError, RuntimeError) as exc:
            render_failures.append(Finding(SEVERITY_ERROR, "catalog-runtime-fix-failed", f"runtime snapshot repair failed: {exc}", "Run 'boxa mcp doctor --fix' again after fixing the catalog/activation store."))
    claude_projects = {
        finding.project for finding in report.findings
        if finding.code == "catalog-claude-render-drift"
        and finding.fixable
        and finding.project
    }
    if claude_projects:
        try:
            from .activation import render_claude_activations
            render_claude_activations(projects=claude_projects)
            result.actions.append("restored Claude Code activation renders")
        except (OSError, ValueError, RuntimeError) as exc:
            render_failures.append(Finding(SEVERITY_ERROR, "catalog-render-fix-failed", f"Claude render repair failed: {exc}", "Inspect the Claude config and re-run 'boxa mcp doctor --fix'."))
        else:
            try:
                from .activation import refresh_runtime
                refresh_runtime()
                runtime_action = (
                    "refreshed the secret-free MCP runtime snapshot"
                )
                if runtime_action not in result.actions:
                    result.actions.append(runtime_action)
            except (OSError, ValueError, RuntimeError) as exc:
                render_failures.append(Finding(SEVERITY_ERROR, "catalog-runtime-fix-failed", f"runtime snapshot repair failed after Claude render: {exc}", "Run 'boxa mcp doctor --fix' again after fixing the catalog/activation store."))
    if "catalog-codex-render-drift" in catalog_codes:
        try:
            from .activation import _render_codex_activation, load_activations
            data = load_activations()
            for project, records in data.get("projects", {}).items():
                if any("codex" in record.get("consumers", []) for record in records.values()):
                    _render_codex_activation(data, project, allow_tracked=False)
            result.actions.append("restored untracked Codex activation renders")
        except (OSError, ValueError, RuntimeError) as exc:
            render_failures.append(Finding(SEVERITY_ERROR, "catalog-render-fix-failed", f"Codex render repair failed: {exc}", "Inspect the Codex config and re-run 'boxa mcp doctor --fix'."))


def _catalog_render_state(
    project: str,
    entry_id: str,
    entry: dict[str, Any],
    consumer: str,
    claude_status: Optional[object] = None,
    claude_status_unknown: bool = False,
) -> tuple[str, bool, bool]:
    """Return (state, tracked, requires_consent) for one derived consumer record.

    ``tracked`` is the repository fact reported by status/doctor JSON and the
    CLI ``:tracked`` marker. ``requires_consent`` is the narrower fixability
    question: a tracked companion file that is already byte-identical does not
    block ``doctor --fix`` (ADR 0022), so the two must not be collapsed.
    """
    from .activation import claude_config_path, codex_config_path

    name = rendered_name(str(entry["name"]))
    expected_args = ["--catalog-id", entry_id, "--consumer", consumer, "--project", project, entry["name"]]
    if consumer == "claude":
        path = claude_config_path(project)
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
            value = data.get("mcpServers", {}).get(name)
        except (OSError, ValueError, AttributeError):
            value = None
        tracked = bool(
            claude_status is not None
            and (
                getattr(claude_status, "mcp_json_tracked", False)
                or getattr(claude_status, "settings_tracked", False)
            )
        )
        requires_consent = claude_status_unknown or bool(
            claude_status is not None
            and getattr(claude_status, "requires_consent", False)
        )
        approval_drift = bool(
            claude_status is not None
            and name in getattr(
                claude_status, "settings_changed_names", frozenset()
            )
        )
        ok = (
            isinstance(value, dict)
            and value.get("command") == WRAPPER_COMMAND
            and value.get("args") == expected_args
            and not approval_drift
        )
        return ("rendered" if ok else "drift"), tracked, requires_consent

    path = codex_config_path(project)
    try:
        with open(path, "rb") as fh:
            data = tomllib.load(fh)
        value = data.get("mcp_servers", {}).get(name)
    except (OSError, ValueError, AttributeError):
        value = None
    from .activation import git_metadata_path

    try:
        relative = os.path.relpath(path, project)
        returncode = subprocess.run(
            ["git", "-C", project, "ls-files", "--error-unmatch", "--", relative],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        ).returncode
    except OSError:
        returncode = None
    if returncode == 0:
        tracked = True
    elif returncode == 1:
        tracked = False
    else:
        # Only a definitive "not tracked" answer may unlock an automatic
        # rewrite. An inspection failure with Git metadata present (unusable
        # gitdir, damaged repository) stays consent-gated; a Project with no
        # Git metadata at all is genuinely untracked.
        tracked = git_metadata_path(project) is not None
    ok = isinstance(value, dict) and value.get("command") == WRAPPER_COMMAND and value.get("args") == expected_args
    # Codex has no in-sync exemption: a tracked config always needs consent.
    return ("rendered" if ok else "drift"), tracked, tracked


def catalog_project_status(project: str, probe: Optional[object] = None) -> dict[str, Any]:
    """Unified catalog -> readiness -> activation -> render -> mode snapshot."""
    from . import activation
    from .activation import canonical_project, load_activations
    from .catalog import degradation_status, load_catalog
    from .readiness import ProjectProbe, ReadinessError, readiness_for_entry

    key = canonical_project(project)
    catalog = load_catalog()
    activations = load_activations()
    records = activations.get("projects", {}).get(key, {})
    rows: list[dict[str, Any]] = []
    local_probe = probe if probe is not None else ProjectProbe()
    claude_status = None
    claude_status_unknown = False
    if any(
        "claude" in record.get("consumers", [])
        for record in records.values()
        if isinstance(record, dict)
    ):
        try:
            claude_status = activation.claude_render_status(
                key,
                activations=activations,
                catalog=catalog,
            )
        except (OSError, activation.ActivationError):
            # Unknown tracked state must not read as "untracked, safe to fix".
            claude_status_unknown = True
    for entry_id, entry in sorted(catalog["entries"].items(), key=lambda item: (item[1]["name"].casefold(), item[0])):
        record = records.get(entry_id)
        try:
            ready_report = readiness_for_entry(entry, key, local_probe, secret_name=str(entry.get("secretStoreKey") or entry["name"]))
            readiness = {
                "state": "ready" if ready_report.ready else "not-ready",
                "container": ready_report.container,
                "checks": [check.to_dict() for check in ready_report.checks],
            }
        except ReadinessError as exc:
            readiness = {"state": "target-stopped", "container": "", "checks": [], "message": str(exc)}
        consumers = list(record.get("consumers", [])) if isinstance(record, dict) else []
        renders = {}
        tracked_codex = False
        tracked_claude = False
        consent_required: dict[str, bool] = {}
        for consumer in consumers:
            state, is_tracked, needs_consent = _catalog_render_state(
                key,
                entry_id,
                entry,
                consumer,
                claude_status,
                claude_status_unknown=claude_status_unknown,
            )
            renders[consumer] = state
            consent_required[consumer] = needs_consent
            if consumer == "codex":
                tracked_codex = tracked_codex or is_tracked
            elif consumer == "claude":
                tracked_claude = tracked_claude or is_tracked
        rows.append({
            "id": entry_id,
            "name": entry["name"],
            "catalogMember": True,
            "runtimeKind": entry["runtimeKind"],
            "readiness": readiness,
            "activation": "activated" if record and record.get("enabled", True) else "inactive",
            "consumers": consumers,
            "renders": renders,
            "executionMode": entry["executionMode"],
            "executionUser": "node" if entry["executionMode"] == "agent-trusted" else "boxa-mcp",
            "isolationStatus": degradation_status(entry) or "isolated",
            "degradedSecretIsolationAcknowledged": activations.get("acknowledgements", {}).get(key, {}).get(entry_id) is True,
            "trackedCodexConfig": tracked_codex,
            "trackedMcpJson": tracked_claude,
            # Tracked is the repository fact; consent is the fixability
            # question, and an in-sync tracked file needs none (ADR 0022).
            "renderRequiresConsent": consent_required,
        })
    return {"projectKey": key, "entries": rows}


def _catalog_doctor_findings(probe: Optional[object] = None) -> list[Finding]:
    """Catalog/activation diagnostics; never includes env values."""
    from .activation import load_activations, runtime_path
    from .catalog import CatalogError, _stored_secret_keys, catalog_path, load_catalog
    findings: list[Finding] = []
    try:
        catalog = load_catalog()
    except CatalogError as exc:
        message = str(exc)
        if "agent-trusted" in message and "secret env keys" in message:
            return [Finding(SEVERITY_ERROR, "trusted-secrets-forbidden", "The MCP catalog contains an agent-trusted entry with a forbidden MCP secret contract.", "Remove the secret contract and retained MCP-store value before granting agent trust; doctor --fix will not change trust or credentials.")]
        return [Finding(SEVERITY_ERROR, "catalog-malformed", f"MCP catalog is malformed: {message}", f"Repair the host-owned catalog at {catalog_path()}.")]
    try:
        activations = load_activations()
    except (OSError, ValueError, RuntimeError) as exc:
        return [Finding(SEVERITY_ERROR, "activations-malformed", f"MCP activation store is malformed: {exc}", "Repair the host-owned activation store; doctor will not infer activations or trust.")]

    # Trust belongs to catalog identity, not activation.  Check every trusted
    # definition (including inactive entries) and reveal only the presence bit:
    # no secret key name, value, or store path enters a finding.
    for entry_id, entry in catalog["entries"].items():
        if entry.get("executionMode") != "agent-trusted":
            continue
        try:
            retained = bool(_stored_secret_keys(entry))
        except (OSError, ValueError):
            findings.append(Finding(
                SEVERITY_ERROR,
                "trusted-secret-store-unreadable",
                f"Cannot verify retained MCP secrets for agent-trusted entry {entry['name']!r} ({entry_id}).",
                "Repair the MCP secret store, then remove retained values before using agent trust; doctor --fix will not inspect or change credentials.",
                False,
            ))
            continue
        if retained:
            findings.append(Finding(
                SEVERITY_ERROR,
                "trusted-secrets-forbidden",
                f"Agent-trusted MCP {entry['name']!r} ({entry_id}) retains forbidden MCP-store values.",
                "Remove all retained MCP-store values for this stable catalog identity before using agent trust; doctor --fix will not change credentials or trust.",
                False,
            ))

    for project, records in activations.get("projects", {}).items():
        for entry_id in records:
            if entry_id not in catalog["entries"]:
                findings.append(Finding(SEVERITY_ERROR, "stale-activation-reference", f"Project {project} has an activation for missing catalog id {entry_id}.", "Deactivate/remove the stale host-owned record explicitly; doctor --fix will not guess.", False))
        try:
            status = catalog_project_status(project, probe)
        except (OSError, ValueError, RuntimeError) as exc:
            findings.append(Finding(SEVERITY_ERROR, "catalog-status-failed", f"Cannot inspect MCP status for Project {project}: {exc}", "Repair the catalog/activation stores."))
            continue
        for row in status["entries"]:
            if row["activation"] != "activated":
                continue
            if row["readiness"]["state"] == "target-stopped":
                findings.append(Finding(SEVERITY_WARN, "activation-target-stopped", f"Activated MCP {row['name']!r} targets stopped Project {project}; readiness cannot be evaluated.", f"Start the Project, then run 'boxa mcp readiness {row['id']} --project {project}'."))
            elif row["readiness"]["state"] != "ready":
                missing = ", ".join(check["label"] for check in row["readiness"]["checks"] if not check["ready"])
                findings.append(Finding(SEVERITY_WARN, "activation-not-ready", f"Activated MCP {row['name']!r} is not ready in Project {project}: {missing}.", f"Run 'boxa mcp install {row['id']} --project {project}', satisfy prerequisites, then re-check readiness."))
            if row["executionMode"] == "agent-trusted" and catalog["entries"][row["id"]].get("secretEnvKeys"):
                findings.append(Finding(SEVERITY_ERROR, "trusted-secrets-forbidden", f"Agent-trusted MCP {row['name']!r} declares forbidden MCP-store secrets.", "Deactivate it and remove the secret contract/value before granting agent trust."))
            if row["isolationStatus"] == "degraded-secret-isolation":
                findings.append(Finding(SEVERITY_WARN, "degraded-secret-isolation", f"MCP server {row['name']!r} in Project {project} has degraded-secret-isolation: node owns the Docker daemon and can inspect its container environment.", "Use a secret-free image or wait for Docker execution and per-server credential isolation."))
            for consumer, render_state in row["renders"].items():
                if render_state == "rendered":
                    continue
                # Fixability follows consent, not the bare tracked fact: a
                # tracked companion file that is already byte-identical must
                # not block 'doctor --fix'.
                needs_consent = bool(
                    row.get("renderRequiresConsent", {}).get(consumer)
                )
                code = f"catalog-{consumer}-render-drift"
                flag = (
                    "--allow-tracked-codex-config"
                    if consumer == "codex"
                    else "--allow-tracked-mcp-json"
                )
                repair = (
                    f"Re-run activation with {flag} after reviewing the repository change."
                    if needs_consent else "boxa mcp doctor --fix"
                )
                tracked_label = "Codex config" if consumer == "codex" else ".mcp.json"
                findings.append(Finding(SEVERITY_WARN, code, f"{consumer} render drift for activated MCP {row['name']!r} in Project {project}." + (f" The {tracked_label} is tracked." if needs_consent else ""), repair, not needs_consent, project))

    from .activation import runtime_payload
    expected = runtime_payload(activations, catalog)
    try:
        with open(runtime_path(), encoding="utf-8") as fh:
            actual = json.load(fh)
    except (OSError, ValueError):
        actual = None
    if actual != expected:
        findings.append(Finding(SEVERITY_WARN, "catalog-runtime-drift", "The secret-free MCP runtime snapshot is missing or out of sync with catalog activations.", "boxa mcp doctor --fix", True))
    return findings
