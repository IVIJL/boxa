"""Agent-specific render preview for boxa-managed MCP entries (issue 06).

This is the READ-ONLY render preview behind ``boxa mcp render --dry-run``. It
computes exactly what boxa WOULD write into the Claude Code and Codex agent
config trees from the canonical MCP profile (`mcp.profile`), without mutating
those configs. The real write path (and the `boxa-mcp-run` wrapper itself)
lands in issue 07.

What this slice guarantees (ADR 0013, decisions 16/21/26/27):

  * Rendered MCP server names use a ``boxa-`` prefix (e.g. ``boxa-context7``)
    so they never collide with inherited/manual agent entries.
  * Rendered entries call the boxa WRAPPER command (``boxa-mcp-run <server>``)
    rather than the raw MCP command, so boxa keeps a stable control point and
    can later swap ``npx`` for a persistent binary without rewriting agent
    config.
  * Rendered entries carry NO secret env values. They reference env-variable
    NAMES only (the wrapper reads the scoped secret store at runtime). The
    preview only ever emits names.
  * Ownership is explicit: boxa owns only ``boxa-``-prefixed entries. The
    preview distinguishes which existing agent entries are boxa-managed from
    which are inherited/manual, and a re-render would replace ONLY boxa's own
    entries and never touch inherited/manual ones.

Codex rendering is implemented only against the verified config shape the Codex
import provider (`mcp.providers.codex`) already reads: a TOML
``[mcp_servers.<name>]`` table with ``command`` / ``args`` / ``env``. When no
TOML parser is available (so boxa cannot reliably read the existing Codex
config to compute ownership), the Codex plan reports rendering as UNSUPPORTED
rather than guessing — it never fabricates a config shape.

CRITICAL: nothing here writes a Claude Code or Codex config file. Every path is
read-only; the only file reads are the agent config trees (to classify existing
entries as managed vs inherited) and the boxa profile JSON.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Any, Optional

from .profile import config_root, load_profile
from .providers import codex as codex_provider
from .providers.claude import render_target_path as claude_render_target_path

# The boxa-managed name prefix. An agent MCP entry whose name starts with this
# is owned by boxa; anything else is inherited/manual and must never be
# rewritten by a render (ADR 0013 decision 16).
BOXA_PREFIX = "boxa-"

# The wrapper command rendered into agent config. Agent entries call this, never
# the raw MCP command (ADR 0013 decision 27). The wrapper script itself is built
# in issue 07; render only PLANS the call.
WRAPPER_COMMAND = "boxa-mcp-run"


def rendered_name(server_name: str) -> str:
    """The boxa-prefixed agent entry name for a profile server."""
    return f"{BOXA_PREFIX}{server_name}"


def is_boxa_managed(entry_name: str) -> bool:
    """True when an existing agent entry name is one boxa owns (re-renderable)."""
    return entry_name.startswith(BOXA_PREFIX)


# Legacy managed prefix from before the devbox->boxa rename. A render strips
# these stale entries (they invoke the removed ``devbox-mcp-run`` wrapper) so
# each server is re-rendered under its current ``boxa-`` name. One-time cutover
# helper -- remove this and its uses once every install has migrated (see
# scripts/migrate-from-devbox.sh).
LEGACY_MANAGED_PREFIX = "devbox-"


def is_managed_or_legacy(entry_name: str) -> bool:
    """True for entries a render may strip: the current ``boxa-`` prefix plus the
    legacy ``devbox-`` prefix pruned during the one-time rename cutover."""
    return entry_name.startswith(BOXA_PREFIX) or entry_name.startswith(
        LEGACY_MANAGED_PREFIX
    )


@dataclass
class ProfileServer:
    """One enabled profile server, with the scope it came from.

    ``renderable`` is False for a server we cannot emit a launchable agent entry
    for; ``skip_reason`` then explains why. The only such case today is a LEGACY
    project profile scanned without a recorded ``projectKey``: its filename is a
    sanitized+hashed label the wrapper cannot reverse into a profile path, so a
    rendered ``--project <label>`` entry would parse fine yet fail to launch. We
    skip it (with a clear, actionable reason) rather than write a broken entry.
    """

    name: str
    scope: str  # "global" or "project"
    project_key: str  # "" for global
    env_keys: list[str] = field(default_factory=list)
    secret_env_keys: list[str] = field(default_factory=list)
    renderable: bool = True
    skip_reason: str = ""
    # A Project-scoped DISABLE OVERRIDE for a server that is ENABLED globally
    # (issue 08). The override carries no command of its own; it exists only to
    # SHADOW the global ``boxa-<name>`` entry inside its project's Claude
    # record so the otherwise-global server is not offered there. The rendered
    # entry still calls the wrapper with ``--project <key>``; the wrapper resolves
    # the project profile, finds ``enabled: false``, and refuses — which is the
    # enforcement. Never set for global servers.
    disabled_override: bool = False


@dataclass
class PlannedEntry:
    """A single planned agent config entry for one profile server (SECRET-FREE).

    ``argv`` is the WRAPPER invocation (``boxa-mcp-run <server>``), never the
    raw MCP command. ``env_keys`` / ``secret_env_keys`` are NAMES only — the
    wrapper reads values from the scoped secret store at runtime, so no value is
    ever rendered into agent config.
    """

    rendered_name: str
    source_name: str
    scope: str
    project_key: str
    argv: list[str]
    env_keys: list[str] = field(default_factory=list)
    secret_env_keys: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "renderedName": self.rendered_name,
            "sourceName": self.source_name,
            "scope": self.scope,
            "command": list(self.argv),
            # NAMES only — values live 0600 in the secret store, never here.
            "envKeys": list(self.env_keys),
            "secretEnvKeys": list(self.secret_env_keys),
        }
        if self.project_key:
            out["project"] = self.project_key
        return out


@dataclass
class AgentPlan:
    """The planned render outcome for one agent (Claude Code or Codex).

    ``supported`` is False only when boxa cannot reliably render for this agent
    (e.g. Codex with no TOML parser available); ``unsupported_reason`` then
    explains why and ``planned`` is empty. ``managed_existing`` and
    ``inherited_existing`` are the names of entries ALREADY in the agent config,
    split by ownership, so the preview can show what a re-render would replace
    versus leave untouched.
    """

    agent: str
    config_path: str
    supported: bool = True
    unsupported_reason: str = ""
    planned: list[PlannedEntry] = field(default_factory=list)
    managed_existing: list[str] = field(default_factory=list)
    inherited_existing: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "agent": self.agent,
            "configPath": self.config_path,
            "supported": self.supported,
        }
        if not self.supported:
            out["unsupportedReason"] = self.unsupported_reason
            return out
        out["planned"] = [p.to_dict() for p in self.planned]
        out["existing"] = {
            "boxaManaged": list(self.managed_existing),
            "inherited": list(self.inherited_existing),
        }
        return out


def _disambiguated_names(servers: list[ProfileServer]) -> dict[int, str]:
    """Resolve a unique rendered NAME per profile server, by list index.

    A global server and a project server can share the same source name and
    therefore the same bare ``boxa-<name>`` rendering, even though
    ``apply_selection`` treats them as distinct profile slots (different scope).
    Two identical rendered names would collide in the agent config and leave the
    wrapper unable to tell which scoped server to launch.

    Per ADR 0013 decision 19, a Project entry gets a Project-specific rendered
    name only when it WOULD collide: the bare ``boxa-<name>`` is kept when it
    is unique, and a colliding project entry becomes
    ``boxa-<name>-<project-label>``. Global entries always keep the bare name
    so they stay stable. The wrapper argument passed alongside still carries the
    original source name plus scope so issue 07 can launch the right slot.
    """
    # Count how many servers want each bare rendered name. A Project DISABLE
    # OVERRIDE is excluded from the count and ALWAYS keeps the bare name: it must
    # SHADOW the global ``boxa-<name>`` entry inside its project's Claude
    # record (same name, different record location), so disambiguating it would
    # defeat the override entirely.
    bare_counts: dict[str, int] = {}
    for srv in servers:
        if srv.disabled_override:
            continue
        bare_counts[rendered_name(srv.name)] = bare_counts.get(
            rendered_name(srv.name), 0
        ) + 1

    names: dict[int, str] = {}
    used: set[str] = set()
    for idx, srv in enumerate(servers):
        bare = rendered_name(srv.name)
        if srv.disabled_override:
            names[idx] = bare
            continue
        if bare_counts.get(bare, 0) <= 1:
            names[idx] = bare
            used.add(bare)
            continue
        # Collision: keep the bare name for the global entry, disambiguate the
        # project entry with its (non-secret) project label.
        if srv.scope != "project" or not srv.project_key:
            candidate = bare
        else:
            label = srv.project_key.rsplit("/", 1)[-1]
            candidate = f"{bare}-{label}"
        # Guard against a still-duplicate candidate (two project entries with the
        # same name+label) by appending a numeric suffix.
        unique = candidate
        n = 2
        while unique in used:
            unique = f"{candidate}-{n}"
            n += 1
        names[idx] = unique
        used.add(unique)
    return names


def _planned_entries(servers: list[ProfileServer]) -> list[PlannedEntry]:
    """Build the planned agent entries (same for every agent's wrapper call).

    The rendered command is the wrapper invocation; the raw MCP argv from the
    profile is deliberately NOT emitted into agent config — the wrapper resolves
    and launches it at runtime from the canonical profile. Rendered names are
    disambiguated across scopes so a global+project name clash does not produce
    two colliding agent entries.

    Non-renderable servers (e.g. a legacy project profile with no recoverable
    key) are EXCLUDED here: emitting a wrapper entry for one would write config
    that parses but cannot launch. They are surfaced separately via the plan's
    skipped list, never as a planned entry.
    """
    renderables = [s for s in servers if s.renderable]
    resolved = _disambiguated_names(renderables)
    planned: list[PlannedEntry] = []
    for idx, srv in enumerate(renderables):
        # The wrapper argv must uniquely identify WHICH scoped profile slot to
        # launch, or a global+project name clash (or two same-basename projects)
        # would leave the wrapper unable to tell the slots apart. A bare global
        # server keeps the canonical ``boxa-mcp-run <name>`` form (ADR 0013
        # decision 27); a Project-scoped server is qualified with its FULL,
        # already-unique project key (an absolute path for explicit
        # ``--project`` scans, or the hashed profile-file label for scanned
        # profiles — never a bare basename, which two projects can share). This
        # is non-secret identity only. Issue 07 owns the wrapper's flag parsing.
        if srv.scope == "project" and srv.project_key:
            wrapper_argv = [WRAPPER_COMMAND, "--project", srv.project_key, srv.name]
        else:
            wrapper_argv = [WRAPPER_COMMAND, srv.name]
        planned.append(
            PlannedEntry(
                rendered_name=resolved[idx],
                source_name=srv.name,
                scope=srv.scope,
                project_key=srv.project_key,
                argv=wrapper_argv,
                env_keys=list(srv.env_keys),
                secret_env_keys=list(srv.secret_env_keys),
            )
        )
    return planned


def _profile_servers_from(
    path: str,
    scope: str,
    project_key: str,
    renderable: bool = True,
    skip_reason: str = "",
    disabled_override_names: Optional[set[str]] = None,
) -> list[ProfileServer]:
    """Load one profile file and return its enabled servers as ProfileServers.

    A server is considered enabled unless it carries an explicit ``"enabled":
    false`` flag. Reads NAMES only — no secret value is ever in the profile, so
    nothing to redact here.

    ``renderable``/``skip_reason`` mark a whole profile whose servers cannot be
    rendered into a launchable agent entry (see ``ProfileServer``); the flags are
    stamped onto every server the file yields.

    ``disabled_override_names`` (project scope only) is the set of names that are
    a Project DISABLE OVERRIDE of an ENABLED global server: a disabled,
    command-less stub written by ``boxa mcp disable <name> --project <p>``.
    These are normally dropped (disabled), but for these names we EMIT a
    ``disabled_override`` ProfileServer so render can shadow the global
    ``boxa-<name>`` entry in this project's Claude record (the wrapper then
    refuses to launch it for the project — that is the enforcement).
    """
    profile = load_profile(path)
    out: list[ProfileServer] = []
    servers = profile.get("servers", {})
    if not isinstance(servers, dict):
        return out
    overrides = disabled_override_names or set()
    for name in sorted(servers):
        spec = servers[name]
        if not isinstance(spec, dict):
            continue
        if spec.get("enabled") is False:
            # A disabled project stub that overrides an enabled global server is
            # emitted as a shadow (so the global entry is suppressed in this
            # project); every other disabled server is simply not rendered.
            if scope == "project" and name in overrides and "command" not in spec:
                out.append(
                    ProfileServer(
                        name=str(name),
                        scope=scope,
                        project_key=project_key,
                        renderable=renderable,
                        skip_reason=skip_reason,
                        disabled_override=True,
                    )
                )
            continue
        env_keys = spec.get("envKeys")
        secret_env_keys = spec.get("secretEnvKeys")
        out.append(
            ProfileServer(
                name=str(name),
                scope=scope,
                project_key=project_key,
                env_keys=[str(k) for k in env_keys] if isinstance(env_keys, list) else [],
                secret_env_keys=(
                    [str(k) for k in secret_env_keys]
                    if isinstance(secret_env_keys, list)
                    else []
                ),
                renderable=renderable,
                skip_reason=skip_reason,
            )
        )
    return out


def _project_key_for_profile(filename: str, projects_dir: str) -> str:
    """Best-effort project label for a project profile file.

    The profile filename is a sanitized + hashed basename (see
    `mcp.profile._sanitize_project`); the original absolute project key is not
    recoverable from it. The filename (without the ``.json`` suffix) is a stable,
    non-secret label, which is what the preview shows for the project scope.
    """
    _ = projects_dir
    return filename[:-5] if filename.endswith(".json") else filename


def collect_profile_servers(project_keys: Optional[list[str]] = None) -> list[ProfileServer]:
    """Enumerate every enabled profile server across global + project scopes.

    Global profile servers come first, then project profile servers ordered by
    profile filename for a deterministic preview. When ``project_keys`` is given,
    only those projects' profiles are read; otherwise every project profile file
    under the projects directory is scanned (a render preview should show the
    full boxa-managed surface, not just one project).
    """
    root = config_root()
    servers: list[ProfileServer] = []

    servers.extend(
        _profile_servers_from(os.path.join(root, "profile.json"), "global", "")
    )
    # Names of ENABLED global servers: a Project disable override only matters
    # (needs to shadow) when the same name is actually offered globally.
    enabled_global = {s.name for s in servers if s.scope == "global"}

    projects_dir = os.path.join(root, "projects")
    if project_keys:
        from .profile import project_profile_path

        for key in project_keys:
            path = project_profile_path(key)
            servers.extend(
                _profile_servers_from(
                    path, "project", key,
                    disabled_override_names=enabled_global,
                )
            )
        return servers

    if os.path.isdir(projects_dir):
        for filename in sorted(os.listdir(projects_dir)):
            # Project PROFILE files only — the parallel ``*.secrets.json`` store
            # is owner-only credential state and must never be read by render.
            if not filename.endswith(".json") or filename.endswith(".secrets.json"):
                continue
            path = os.path.join(projects_dir, filename)
            # Use the ORIGINAL project key the profile recorded at apply time: the
            # rendered wrapper call must carry the FULL key so the wrapper can
            # locate the matching profile/secrets at launch. The filename is a
            # sanitized+hashed label the wrapper would re-hash into a different,
            # non-existent path — so it is NOT a usable fallback. A legacy profile
            # written before the key was recorded is therefore SKIPPED as
            # non-renderable (with an actionable reason) rather than rendered into
            # a wrapper entry that parses but cannot launch.
            key = _project_key_from_profile(path)
            if key:
                servers.extend(
                    _profile_servers_from(
                        path, "project", key,
                        disabled_override_names=enabled_global,
                    )
                )
            else:
                label = _project_key_for_profile(filename, projects_dir)
                servers.extend(
                    _profile_servers_from(
                        path,
                        "project",
                        label,
                        renderable=False,
                        skip_reason=(
                            "legacy project profile has no recorded projectKey; "
                            "re-import the server(s) for this project so boxa "
                            "records the full key and can render a launchable "
                            "wrapper entry"
                        ),
                    )
                )

    return servers


def _project_key_from_profile(path: str) -> str:
    """Read the original project key a project profile recorded, or "".

    Apply stores the full absolute project key under ``projectKey`` so render can
    emit a wrapper call the wrapper can resolve. Any read/parse error or missing
    field degrades to "" so the caller falls back to the filename label rather
    than raising. Non-secret identity only.
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return ""
    if not isinstance(data, dict):
        return ""
    key = data.get("projectKey")
    return key if isinstance(key, str) and key else ""


def _read_existing_agent_names_claude(config_path: str) -> list[str]:
    """Names of MCP entries already present in Claude Code config (READ-ONLY).

    Reads both the global ``mcpServers`` block and every project record's
    ``mcpServers`` block, since a re-render's ownership check spans the whole
    file. Any read/parse error degrades to an empty list — the preview then
    simply shows no existing entries, never an exception and never a write.
    """
    if not os.path.isfile(config_path):
        return []
    try:
        with open(config_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    if not isinstance(data, dict):
        return []
    names: list[str] = []
    block = data.get("mcpServers")
    if isinstance(block, dict):
        names.extend(str(n) for n in block)
    projects = data.get("projects")
    if isinstance(projects, dict):
        for record in projects.values():
            if isinstance(record, dict):
                pblock = record.get("mcpServers")
                if isinstance(pblock, dict):
                    names.extend(str(n) for n in pblock)
    return names


def _read_existing_agent_names_codex(config_path: str) -> Optional[list[str]]:
    """Names of MCP entries already present in Codex config (READ-ONLY).

    Returns ``None`` when boxa cannot reliably read Codex config (no TOML
    parser available) so the caller can mark Codex rendering UNSUPPORTED rather
    than guess at an empty config. Otherwise returns the ``[mcp_servers.<name>]``
    table names (possibly empty). Read-only; any IO/parse error degrades to an
    empty list.
    """
    if codex_provider._toml is None:  # noqa: SLF001 - reuse the provider's parser
        return None
    if not os.path.isfile(config_path):
        return []
    try:
        with open(config_path, "rb") as fh:
            data = codex_provider._toml.load(fh)  # noqa: SLF001
    except (OSError, ValueError):
        return []
    if not isinstance(data, dict):
        return []
    table = data.get(codex_provider._MCP_TABLE)  # noqa: SLF001
    if not isinstance(table, dict):
        return []
    return [str(n) for n in table]


def _split_ownership(existing: list[str]) -> tuple[list[str], list[str]]:
    """Split existing agent entry names into (render-owned, inherited/manual).

    Render-owned = the current ``boxa-`` prefix PLUS the legacy ``devbox-``
    prefix, so the dry-run preview matches the writer, which strips both during
    the one-time rename cutover."""
    managed = sorted(n for n in existing if is_managed_or_legacy(n))
    inherited = sorted(n for n in existing if not is_managed_or_legacy(n))
    return managed, inherited


def build_claude_plan(
    servers: list[ProfileServer], config_path: Optional[str] = None
) -> AgentPlan:
    """Render plan for Claude Code against its verified config shape.

    Claude Code's config (``~/.claude/.claude.json``, or the
    ``CLAUDE_CONFIG_DIR`` form inside a Container) keys MCP entries by name under
    a ``mcpServers`` object — the same shape the Claude import provider reads.
    Render is supported for Claude in all cases (no parser dependency).

    When ``config_path`` is None the target is ``render_target_path()`` — the
    Container-visible ``~/.claude/.claude.json`` the agent actually reads (ADR
    0014), NOT the host-native discovery ``default_config_path``. The injectable
    ``config_path`` is kept for tests. Discovery (``import``) still reads the
    host config; only render is retargeted.
    """
    path = config_path or claude_render_target_path()
    plan = AgentPlan(agent="claude-code", config_path=path)
    plan.planned = _planned_entries(servers)
    managed, inherited = _split_ownership(_read_existing_agent_names_claude(path))
    plan.managed_existing = managed
    plan.inherited_existing = inherited
    return plan


def build_codex_plan(
    servers: list[ProfileServer], config_path: Optional[str] = None
) -> AgentPlan:
    """Render plan for Codex against its verified config shape, or unsupported.

    Codex MCP config is the TOML ``[mcp_servers.<name>]`` table the Codex import
    provider already reads. When no TOML parser is available boxa cannot read
    the existing config to compute ownership, so rather than guess, the plan is
    marked UNSUPPORTED with a clear reason (ADR 0013: never fabricate a shape).
    """
    path = config_path or codex_provider.default_config_path()
    plan = AgentPlan(agent="codex", config_path=path)
    existing = _read_existing_agent_names_codex(path)
    if existing is None:
        plan.supported = False
        plan.unsupported_reason = (
            "Codex rendering unsupported here: no TOML parser available to read "
            f"{path} (install Python 3.11+ or 'tomli'). Not guessing the config "
            "shape."
        )
        return plan
    # Codex has a SINGLE global ``[mcp_servers]`` table and no per-project MCP
    # namespace (verified schema). A project-scoped server therefore has no
    # scoped Codex target — writing it globally would offer it (and let the
    # wrapper load its project credentials) in every Codex session, breaking the
    # source-scope isolation ADR 0013 mandates. So Codex renders GLOBAL-scoped
    # servers only; project-scoped ones are excluded here (and from the write),
    # keeping the preview and the real write consistent. Claude keeps them via
    # its project records.
    global_servers = [
        s for s in servers if not (s.scope == "project" and s.project_key)
    ]
    plan.planned = _planned_entries(global_servers)
    managed, inherited = _split_ownership(existing)
    plan.managed_existing = managed
    plan.inherited_existing = inherited
    return plan


@dataclass
class RenderPlan:
    """The full dry-run render plan: shared profile servers + per-agent plans.

    ``servers`` is every profile server scanned; ``skipped`` is the subset that
    could NOT be rendered into a launchable agent entry (and so was excluded from
    every agent plan), kept so both the preview and the write summary can report
    what was left out and why.
    """

    servers: list[ProfileServer]
    claude: AgentPlan
    codex: AgentPlan

    @property
    def renderable_servers(self) -> list[ProfileServer]:
        """Servers actually rendered into the agent plans."""
        return [s for s in self.servers if s.renderable]

    @property
    def skipped(self) -> list[ProfileServer]:
        """Servers excluded from rendering (e.g. legacy profiles, no key)."""
        return [s for s in self.servers if not s.renderable]

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "dryRun": True,
            "wrapperCommand": WRAPPER_COMMAND,
            "prefix": BOXA_PREFIX,
            "profileServers": [
                {
                    "name": s.name,
                    "scope": s.scope,
                    **({"project": s.project_key} if s.project_key else {}),
                }
                for s in self.renderable_servers
            ],
            "agents": [self.claude.to_dict(), self.codex.to_dict()],
        }
        skipped = self.skipped
        if skipped:
            out["skipped"] = [
                {
                    "name": s.name,
                    "scope": s.scope,
                    **({"project": s.project_key} if s.project_key else {}),
                    "reason": s.skip_reason,
                }
                for s in skipped
            ]
        return out


def build_render_plan(project_keys: Optional[list[str]] = None) -> RenderPlan:
    """Build the full dry-run render plan from the canonical profile.

    READ-ONLY: reads the boxa profile JSON and the agent config trees only;
    writes nothing under ``~/.claude`` or ``~/.codex`` (or the boxa state).
    """
    servers = collect_profile_servers(project_keys)
    return RenderPlan(
        servers=servers,
        claude=build_claude_plan(servers),
        codex=build_codex_plan(servers),
    )
