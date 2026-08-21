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
  * ``run_doctor`` — diagnose profile / runtime problems and emit
    concrete repair commands;
  * ``apply_doctor_fixes`` — perform ONLY safe local fixes (create
    missing MCP dirs, repair the wrapper symlink). Never installs packages,
    allows domains, purges runtime, or enables host-only servers.

SECRET-FREE: nothing here ever reads or emits a secret VALUE. The secret store
is touched only to PURGE a server block on an explicit ``--purge`` remove, and
even then only key NAMES are ever reported.
"""

from __future__ import annotations

import os
import json
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
from .launch_profile import WRAPPER_COMMAND, rendered_name
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

    Removes only the Boxa profile entry. Agent-owned configuration is outside
    this legacy profile operation and remains untouched.

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


def run_doctor() -> DoctorReport:
    """Diagnose MCP catalog, activation, launch, and runtime snapshot state."""
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
                    "wrapper refuses to launch MCP servers on the host."
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
                    f"The {WRAPPER_COMMAND!r} wrapper is not on PATH; launch-time "
                    "MCP profiles would fail to start servers."
                ),
                repair=(
                    "Run 'boxa mcp doctor --fix' to repair the wrapper "
                    "symlink, or reinstall boxa so the wrapper is on PATH."
                ),
                fixable=True,
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
    """Apply safe fixes without editing any Project-owned file."""
    result = FixResult()
    failures: list[Finding] = []
    result.actions.extend(_ensure_mcp_dirs())
    if any(f.code == "wrapper-missing" for f in report.findings):
        result.actions.extend(_repair_wrapper_symlink())
    if any(
        finding.code == "catalog-runtime-drift" and finding.fixable
        for finding in report.findings
    ):
        from .catalog import mutation_lock
        try:
            with mutation_lock():
                from .activation import refresh_runtime
                refresh_runtime()
            result.actions.append("refreshed the secret-free MCP runtime snapshot")
        except (OSError, ValueError, RuntimeError) as exc:
            failures.append(
                Finding(
                    SEVERITY_ERROR,
                    "catalog-runtime-fix-failed",
                    f"runtime snapshot repair failed: {exc}",
                    "Run 'boxa mcp doctor --fix' again after fixing the catalog/activation store.",
                )
            )
    result.remaining = failures + list(run_doctor().findings)
    return result


def catalog_project_status(project: str, probe: Optional[object] = None) -> dict[str, Any]:
    """Unified catalog, readiness, activation, mode, and isolation snapshot."""
    from .activation import _entry_activations, canonical_project, load_activations
    from .catalog import degradation_status, load_catalog
    from .catalog_import import catalog_verdicts
    from .classify import classify_candidate
    from .merge import merge_candidates
    from .providers.claude import ClaudeProvider
    from .providers.codex import CodexProvider
    from .readiness import ProjectProbe, ReadinessError, readiness_for_entry

    key = canonical_project(project)
    catalog = load_catalog()
    activations = load_activations()
    records = activations.get("projects", {}).get(key, {})
    rows: list[dict[str, Any]] = []
    local_probe = probe if probe is not None else ProjectProbe()
    for entry_id, entry in sorted(catalog["entries"].items(), key=lambda item: (item[1]["name"].casefold(), item[0])):
        record = records.get(entry_id)
        try:
            ready_report = readiness_for_entry(entry, key, local_probe, secret_name=str(entry.get("secretStoreKey") or entry["name"]))
            readiness = {
                "state": (
                    "no-runtime-readiness"
                    if not ready_report.has_runtime_readiness
                    else "ready" if ready_report.ready else "not-ready"
                ),
                "container": ready_report.container,
                "checks": [check.to_dict() for check in ready_report.checks],
                "hints": list(ready_report.hints),
            }
        except ReadinessError as exc:
            readiness = {"state": "target-stopped", "container": "", "checks": [], "message": str(exc)}
        opted_out = bool(record and record.get("optedOut") is True)
        consumers = (
            list(record.get("consumers", []))
            if isinstance(record, dict) and not opted_out
            else []
        )
        pending = bool(
            record
            and not opted_out
            and record.get("enabled", True) is False
        )
        everywhere = activations.get("everywhere", {}).get(entry_id)
        activation_projects = [
            item["projectKey"]
            for item in _entry_activations(activations, entry_id)
        ]
        rows.append({
            "id": entry_id,
            "name": entry["name"],
            "catalogMember": True,
            "runtimeKind": entry.get("runtimeKind", "remote-http"),
            "readiness": readiness,
            "activation": (
                "opted-out"
                if opted_out
                else "pending"
                if pending
                else "activated"
                if record
                else "inactive"
            ),
            "pendingReason": (
                str(record.get("pendingReason", ""))
                if pending and isinstance(record, dict)
                else ""
            ),
            "consumers": consumers,
            "everywhere": isinstance(everywhere, dict),
            "everywhereConsumers": (
                list(everywhere.get("consumers", []))
                if isinstance(everywhere, dict)
                else []
            ),
            "activationProjects": activation_projects,
            "activationProjectCount": len(activation_projects),
            "optedOut": opted_out,
            "executionMode": entry.get("executionMode", "none"),
            "executionUser": (
                "-" if entry["type"] == "http"
                else "node" if entry["executionMode"] == "agent-trusted"
                else "boxa-mcp"
            ),
            "isolationStatus": (
                "not-applicable"
                if entry["type"] == "http"
                else degradation_status(entry) or "isolated"
            ),
            "agentIdentityTrustScope": (
                "every-project"
                if isinstance(everywhere, dict)
                and entry.get("executionMode") == "agent-trusted"
                else "project"
                if record
                and not opted_out
                and entry.get("executionMode") == "agent-trusted"
                else "none"
            ),
            "degradedSecretIsolationAcknowledged": activations.get("acknowledgements", {}).get(key, {}).get(entry_id) is True,
        })
    inherited_raw = []
    for provider in (ClaudeProvider(), CodexProvider()):
        inherited_raw.extend(provider.discover(
            project_keys=[key], include_global=True, all_projects=False
        ))
    for candidate in inherited_raw:
        classify_candidate(candidate)
    inherited = catalog_verdicts(merge_candidates(inherited_raw), catalog)
    proposals = [
        candidate
        for candidate in inherited
        if candidate.candidate.classification.placement == "container"
        and candidate.catalog_status in {"proposal", "conflict"}
    ]
    return {
        "projectKey": key,
        "entries": rows,
        "everywhereOptOuts": [
            entry_id
            for entry_id, record in sorted(records.items())
            if record.get("optedOut") is True
        ],
        "inheritedCandidates": [candidate.to_dict() for candidate in inherited],
        "importProposalCount": len(proposals),
        "importNudge": (
            f"Found {len(proposals)} importable MCP server(s) in your agent config; "
            "run 'boxa mcp import --project <p>' to review and import."
            if proposals
            else ""
        ),
    }


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
            elif row["readiness"]["state"] not in {"ready", "no-runtime-readiness"}:
                missing = ", ".join(check["label"] for check in row["readiness"]["checks"] if not check["ready"])
                findings.append(Finding(SEVERITY_WARN, "activation-not-ready", f"Activated MCP {row['name']!r} is not ready in Project {project}: {missing}.", f"Run 'boxa mcp install {row['id']} --project {project}', satisfy prerequisites, then re-check readiness."))
            if row["executionMode"] == "agent-trusted" and catalog["entries"][row["id"]].get("secretEnvKeys"):
                findings.append(Finding(SEVERITY_ERROR, "trusted-secrets-forbidden", f"Agent-trusted MCP {row['name']!r} declares forbidden MCP-store secrets.", "Deactivate it and remove the secret contract/value before granting agent trust."))
            if row["isolationStatus"] == "degraded-secret-isolation":
                findings.append(Finding(SEVERITY_WARN, "degraded-secret-isolation", f"MCP server {row['name']!r} in Project {project} has degraded-secret-isolation: node owns the Docker daemon and can inspect its container environment.", "Use a secret-free image or wait for Docker execution and per-server credential isolation."))
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
