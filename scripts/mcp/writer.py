"""Real render write path for Claude Code and Codex config (ADR 0013, issue 07).

Issue 06 built the read-only ``mcp.render`` PREVIEW. This module is the WRITE
counterpart behind ``boxa mcp render`` (no ``--dry-run``): it takes the same
``AgentPlan`` objects and actually writes the boxa-managed entries into the
Claude Code and Codex config trees.

Contract (ADR 0013 decisions 16/26/27):

  * boxa owns ONLY ``boxa-``-prefixed entries. A render removes every stale
    ``boxa-`` entry and writes the current planned ones; inherited/manual
    entries are NEVER touched.
  * The write is IDEMPOTENT — rendering the same plan twice yields the same
    file content.
  * Agent entries call the WRAPPER (``boxa-mcp-run ...``), never the raw MCP
    command, and carry NO secret values (the wrapper reads the secret store at
    runtime).
  * Writes are atomic (temp file + ``os.replace``) and preserve every other
    (non-boxa) key.

Claude Code stores MCP entries as a JSON ``mcpServers`` object; we parse the
whole file, surgically replace only boxa-owned entries, and re-serialize.
Codex stores them as TOML ``[mcp_servers.<name>]`` tables; Python ships a TOML
*reader* (``tomllib``) but no writer, so to preserve the rest of the user's
TOML formatting verbatim we edit the file TEXTUALLY: drop existing
``[mcp_servers.boxa-*]`` blocks and append freshly-serialized ones, leaving
all other tables byte-for-byte unchanged.
"""

from __future__ import annotations

import json
import os
import re
from typing import Any

from .providers import codex as codex_provider
from .providers.claude import default_config_path as claude_default_config_path
from .profile import config_root
from .render import BOXA_PREFIX, AgentPlan, PlannedEntry, is_managed_or_legacy


class RenderWriteError(RuntimeError):
    """A render write failure with an actionable message."""


def _atomic_write(path: str, text: str) -> None:
    """Write ``text`` to ``path`` atomically (temp file + replace).

    The agent config is non-secret (wrapper calls + env NAMES only), so default
    permissions are fine — unlike the secret store, which forces 0600.
    """
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


# -- Claude Code (JSON) -------------------------------------------------------

_CLAUDE_RENDER_STATE_VERSION = 1


def _claude_render_state_path() -> str:
    """Boxa-owned state for one-time Claude MCP default-disable decisions."""
    return os.path.join(config_root(), "claude-render-state.json")


def _load_claude_render_state() -> dict[str, Any]:
    """Load render state, degrading safely when absent or malformed."""
    path = _claude_render_state_path()
    if not os.path.isfile(path):
        return {"version": _CLAUDE_RENDER_STATE_VERSION, "projects": {}}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {"version": _CLAUDE_RENDER_STATE_VERSION, "projects": {}}
    if not isinstance(data, dict) or not isinstance(data.get("projects"), dict):
        return {"version": _CLAUDE_RENDER_STATE_VERSION, "projects": {}}
    return data


def _save_claude_render_state(state: dict[str, Any]) -> None:
    """Persist the non-secret per-project rendered-name set atomically."""
    _atomic_write(
        _claude_render_state_path(),
        json.dumps(state, indent=2, sort_keys=False) + "\n",
    )


def _string_list(value: Any) -> list[str]:
    """Return string members from a JSON array, preserving their order."""
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str)]


def _apply_claude_default_disabled(
    projects: dict[str, Any],
    planned: list[PlannedEntry],
) -> dict[str, Any]:
    """Default newly rendered boxa MCP servers to disabled per project.

    Claude Code stores its `/mcp` Enable/Disable toggle in each project record's
    ``disabledMcpServers`` array. Boxa records which rendered names each
    project has already seen in a separate non-secret state file:

      * a newly seen name is appended to ``disabledMcpServers``;
      * a previously seen name is left alone, preserving the user's `/mcp`
        choice across later renders;
      * a removed boxa server is removed from the array and from render state,
        so re-adding it later is treated as new and defaults to disabled again.

    Global entries apply to every existing Claude project record. Project-scoped
    entries apply only to their own record (which the writer creates below when
    necessary).
    """
    state = _load_claude_render_state()
    raw_seen = state.get("projects")
    seen_by_project = raw_seen if isinstance(raw_seen, dict) else {}

    global_names = {
        entry.rendered_name
        for entry in planned
        if not (entry.scope == "project" and entry.project_key)
    }
    project_names: dict[str, set[str]] = {}
    for entry in planned:
        if entry.scope == "project" and entry.project_key:
            project_names.setdefault(entry.project_key, set()).add(
                entry.rendered_name
            )

    project_keys = set(projects) | set(project_names) | set(seen_by_project)
    next_seen: dict[str, list[str]] = {}

    for project_key in sorted(project_keys):
        record = projects.get(project_key)
        if not isinstance(record, dict):
            if project_key not in project_names:
                continue
            record = {}
            projects[project_key] = record

        current = global_names | project_names.get(project_key, set())
        previous = set(_string_list(seen_by_project.get(project_key)))
        newly_rendered = current - previous
        removed = previous - current

        disabled = _string_list(record.get("disabledMcpServers"))
        disabled = [name for name in disabled if name not in removed]
        disabled_set = set(disabled)
        for name in sorted(newly_rendered):
            if name not in disabled_set:
                disabled.append(name)
                disabled_set.add(name)

        if disabled or "disabledMcpServers" in record:
            record["disabledMcpServers"] = disabled
        if current:
            next_seen[project_key] = sorted(current)

    return {
        "version": _CLAUDE_RENDER_STATE_VERSION,
        "projects": next_seen,
    }


def _strip_boxa_from_claude_file(path: str) -> None:
    """Strip ONLY ``boxa-``-prefixed entries from a Claude config at ``path``.

    Migration cleanup (ADR 0014). Render now targets the Container-visible
    ``~/.claude/.claude.json`` (config-dir form), but a user who ran the previous
    render path has ``boxa-`` entries in the host-native ``~/.claude.json``.
    Left behind, host Claude Code keeps offering container-only relay commands
    that cannot reach the broker. This removes those orphans from the OTHER file,
    touching only ``boxa-``-owned keys (top-level and per-project), leaving all
    inherited/manual entries and every other key byte-for-byte unchanged. A
    no-op when the file is absent, unreadable, not an object, or has no
    ``boxa-`` entries (so it never rewrites a clean file).
    """
    if not os.path.isfile(path):
        return
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        # Never let a stale/unparseable host file break the real render write.
        return
    if not isinstance(data, dict):
        return

    changed = False

    block = data.get("mcpServers")
    if isinstance(block, dict):
        kept = {n: v for n, v in block.items() if not is_managed_or_legacy(n)}
        if len(kept) != len(block):
            data["mcpServers"] = kept
            changed = True

    projects = data.get("projects")
    if isinstance(projects, dict):
        for record in projects.values():
            if not isinstance(record, dict):
                continue
            proj_block = record.get("mcpServers")
            if not isinstance(proj_block, dict):
                continue
            kept = {n: v for n, v in proj_block.items() if not is_managed_or_legacy(n)}
            if len(kept) != len(proj_block):
                record["mcpServers"] = kept
                changed = True

    if changed:
        _atomic_write(path, json.dumps(data, indent=2, sort_keys=False) + "\n")


def _claude_entry(entry: PlannedEntry) -> dict[str, Any]:
    """Build the Claude Code MCP entry for a planned wrapper call (SECRET-FREE).

    The wrapper argv is split into ``command`` + ``args`` (Claude's verified
    shape). No env is emitted: the wrapper resolves env at runtime from the
    scoped secret store / environment, so agent config carries names only via
    the profile, never values here.
    """
    argv = list(entry.argv)
    return {
        "type": "stdio",
        "command": argv[0],
        "args": argv[1:],
    }


def write_claude(plan: AgentPlan) -> None:
    """Write boxa-managed entries into Claude Code's config (idempotent).

    Reads the existing ``.claude.json`` (or starts an empty doc), removes every
    ``boxa-`` entry from the top-level ``mcpServers`` block AND from each
    project record's ``mcpServers`` block (so a stale entry written under either
    is cleaned up), then writes each planned entry back at its SOURCE SCOPE:

      * a GLOBAL planned entry goes into the top-level ``mcpServers`` block, where
        Claude offers it in every project;
      * a PROJECT planned entry goes into ``projects[<project_key>].mcpServers``
        for its own project record, so Claude offers it ONLY in that project.

    Routing project entries to their project record (rather than promoting them
    to the global block) preserves the source scope ADR 0013 mandates: it keeps a
    project's MCP server — and the project-scoped credentials the wrapper resolves
    for it — from being invocable while working in a DIFFERENT project. The
    wrapper's ``--project`` flag only selects which boxa profile/secret store to
    launch; it does not constrain WHICH Claude project the entry is offered in, so
    the placement here is what enforces scope. Inherited/manual entries are
    preserved unchanged.
    """
    path = plan.config_path
    data: dict[str, Any]
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError) as exc:
            raise RenderWriteError(
                f"cannot read Claude Code config to render into: {path}: {exc}"
            ) from exc
        if not isinstance(data, dict):
            raise RenderWriteError(
                f"Claude Code config is not a JSON object: {path}"
            )
    else:
        data = {}

    # Strip stale boxa-managed entries from the top-level block and from every
    # project record, owning only what we prefixed.
    block = data.get("mcpServers")
    if not isinstance(block, dict):
        block = {}
    block = {n: v for n, v in block.items() if not is_managed_or_legacy(n)}

    projects = data.get("projects")
    if not isinstance(projects, dict):
        projects = {}
    for record in projects.values():
        if isinstance(record, dict) and isinstance(
            record.get("mcpServers"), dict
        ):
            record["mcpServers"] = {
                n: v
                for n, v in record["mcpServers"].items()
                if not is_managed_or_legacy(n)
            }

    # Write each planned entry back at its source scope (sorted for
    # deterministic, idempotent output).
    for entry in sorted(plan.planned, key=lambda e: e.rendered_name):
        rendered = _claude_entry(entry)
        if entry.scope == "project" and entry.project_key:
            record = projects.get(entry.project_key)
            if not isinstance(record, dict):
                # Create the project record so a project-scoped server is offered
                # in its project even if Claude has not seen the project yet.
                record = {}
                projects[entry.project_key] = record
            proj_block = record.get("mcpServers")
            if not isinstance(proj_block, dict):
                proj_block = {}
            proj_block[entry.rendered_name] = rendered
            record["mcpServers"] = proj_block
        else:
            block[entry.rendered_name] = rendered

    # Claude's native `/mcp` panel can enable a configured-but-disabled server
    # during the current session. Apply the disabled default only once per
    # rendered name and project, then preserve that native user choice.
    claude_render_state = _apply_claude_default_disabled(projects, plan.planned)

    if block:
        data["mcpServers"] = block
    elif "mcpServers" in data:
        # Keep the file tidy: drop an emptied block we now fully own.
        data["mcpServers"] = {}

    if projects:
        data["projects"] = projects

    _atomic_write(path, json.dumps(data, indent=2, sort_keys=False) + "\n")
    _save_claude_render_state(claude_render_state)

    # Migration cleanup (ADR 0014): render now targets the Container-visible
    # config-dir form, but a previous render left ``boxa-`` entries in the
    # host-native ``~/.claude.json`` that discovery prefers. Strip those orphans
    # from that OTHER file so host Claude Code stops offering dead relay commands.
    # Only runs when the host-native discovery path differs from the file we just
    # wrote (the in-Container case where they coincide skips this; the file was
    # already fully rewritten above).
    host_native = claude_default_config_path()
    if os.path.abspath(host_native) != os.path.abspath(path):
        _strip_boxa_from_claude_file(host_native)


# -- Codex (TOML) -------------------------------------------------------------

# Matches an ``[mcp_servers.<name>]`` table HEADER line in any of the three
# forms a name can take, so we can excise the boxa-owned tables textually
# without disturbing the rest of the file:
#   * bare dotted     ``[mcp_servers.boxa-foo]``      -> group ``bare``
#   * quoted segment  ``[mcp_servers."boxa-foo.bar"]``-> group ``dquoted``
#                       (what the writer emits for names needing quoting)
#   * whole-key quoted ``["mcp_servers.boxa-foo"]``   -> group ``quoted``
#                       (a form a user might have hand-written; recognized so we
#                        still own it, even though the writer never emits it)
# The quoted segments accept a TOML basic-string body: any run of escaped pairs
# (``\\`` followed by any char, e.g. ``\"`` or ``\n``) or non-quote/non-backslash
# chars. Without the ``\\.`` alternative a name containing an escaped quote
# (which ``_codex_table_header`` legitimately emits, e.g.
# ``[mcp_servers."boxa-weird\"name"]``) would not match, so a re-render would
# fail to strip the prior table and append a duplicate — breaking idempotency.
_TABLE_HEADER = re.compile(
    r"""^\s*\[\s*
        (?:
            mcp_servers\s*\.\s*"(?P<dquoted>(?:\\.|[^"\\])+)"
            |
            mcp_servers\s*\.\s*(?P<bare>[A-Za-z0-9_.\-]+)
            |
            "mcp_servers\.(?P<quoted>(?:\\.|[^"\\])+)"
        )
        \s*\]\s*(?:\#.*)?$""",
    re.VERBOSE,
)
# Any other table header (``[something]`` or ``[[array.of.tables]]``) ends the
# current table's body when we are scanning a boxa table to drop. TOML permits
# a trailing comment on a header line (``[manual] # keep``); the optional
# ``#...`` tail must be allowed here, or a commented manual header right after a
# stale boxa table would not be recognized as a header and that manual table
# would be swept into the boxa body and deleted (violating "manual entries are
# never touched").
_ANY_HEADER = re.compile(r"^\s*\[\[?[^\]]+\]\]?\s*(?:#.*)?$")


def _toml_escape(value: str) -> str:
    """Escape a string for a TOML basic string literal."""
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )


def _codex_table_header(name: str) -> str:
    """Build the ``[mcp_servers.<name>]`` header line for a boxa table.

    A bare-key name (``A-Za-z0-9_-``, which the usual ``boxa-<source>`` is)
    uses the dotted ``[mcp_servers.<name>]`` form. A name needing quoting (e.g. a
    source name with a dot) uses ``[mcp_servers."<name>"]`` — the dotted-key form
    where ONLY the final segment is quoted, so the entry still nests under the
    ``mcp_servers`` table. (The whole-key-quoted ``["mcp_servers.<name>"]`` form
    is NOT equivalent: TOML reads it as a single top-level key literally named
    ``mcp_servers.<name>``, not as a nested table.) ``_strip_boxa_tables`` must
    recognize this exact form so a re-render excises the prior table instead of
    appending a duplicate — that is what keeps render idempotent for every name.
    """
    if re.fullmatch(r"[A-Za-z0-9_\-]+", name):
        return f"[mcp_servers.{name}]"
    return f'[mcp_servers."{_toml_escape(name)}"]'


def _codex_table(entry: PlannedEntry) -> str:
    """Serialize one boxa-managed Codex ``[mcp_servers.<name>]`` table.

    Emits ``command`` + ``args`` for the wrapper call (SECRET-FREE; no env). The
    args array is always emitted (possibly empty) so the table shape is stable
    and idempotent.
    """
    argv = list(entry.argv)
    command = argv[0]
    args = argv[1:]
    args_items = ", ".join(f'"{_toml_escape(a)}"' for a in args)
    return (
        f"{_codex_table_header(entry.rendered_name)}\n"
        f'command = "{_toml_escape(command)}"\n'
        f"args = [{args_items}]\n"
    )


def _strip_boxa_tables(text: str) -> str:
    """Remove every ``[mcp_servers.boxa-*]`` table block from TOML text.

    Walks the file line by line. When a ``[mcp_servers.<name>]`` header for a
    boxa-owned name is hit, that header and its body (up to the next table
    header or EOF) are dropped. Every other line — comments, blank lines, and
    all non-boxa tables — is preserved verbatim so the user's formatting
    survives a render.
    """
    out: list[str] = []
    lines = text.splitlines(keepends=True)
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        m = _TABLE_HEADER.match(line)
        name = None
        if m:
            name = m.group("dquoted") or m.group("bare") or m.group("quoted")
        if name is not None and is_managed_or_legacy(name):
            # Drop this boxa table: skip its header and body until the next
            # table header (any [..] / [[..]]) or EOF.
            i += 1
            while i < n and not _ANY_HEADER.match(lines[i]):
                i += 1
            continue
        out.append(line)
        i += 1
    return "".join(out)


def write_codex(plan: AgentPlan) -> None:
    """Write boxa-managed entries into Codex's TOML config (idempotent).

    Preserves the rest of the user's config verbatim by editing the file as
    text: strip existing ``[mcp_servers.boxa-*]`` tables, then append the
    current planned tables (sorted for deterministic output). When the plan is
    unsupported (no TOML parser to read the existing config for ownership), the
    write is refused rather than guessing at a config shape.

    Only GLOBAL-scoped entries are written. Codex's verified schema has a SINGLE
    global ``[mcp_servers]`` table and no per-project MCP namespace, so a
    project-scoped server cannot be confined to its project here — writing it
    would offer it (and let the wrapper load its project-scoped credentials) in
    every Codex session, violating the source-scope isolation ADR 0013 mandates.
    Unlike Claude (where project entries land in the project record), there is no
    project-scoped Codex target, so project entries are SKIPPED for Codex; any
    stale boxa project table is still stripped. The wrapper's ``--project``
    flag only selects which boxa profile/secrets to load, not where Codex
    offers the entry, so it cannot substitute for real scoping here.
    """
    if not plan.supported:
        raise RenderWriteError(
            f"cannot render Codex config: {plan.unsupported_reason}"
        )

    path = plan.config_path
    existing = ""
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                existing = fh.read()
        except OSError as exc:
            raise RenderWriteError(
                f"cannot read Codex config to render into: {path}: {exc}"
            ) from exc

    stripped = _strip_boxa_tables(existing)

    # ``build_codex_plan`` already excludes project-scoped servers (no scoped
    # Codex target), so ``plan.planned`` is global-only. Defense-in-depth: filter
    # again so a hand-built plan can never promote a project entry into Codex's
    # global table.
    global_entries = [
        entry
        for entry in plan.planned
        if not (entry.scope == "project" and entry.project_key)
    ]
    tables = [
        _codex_table(entry)
        for entry in sorted(global_entries, key=lambda e: e.rendered_name)
    ]

    parts: list[str] = []
    base = stripped.rstrip("\n")
    if base:
        parts.append(base + "\n")
    if tables:
        if parts:
            parts.append("\n")  # one blank line before the boxa block
        parts.append("\n".join(tables))

    result = "".join(parts)
    if result and not result.endswith("\n"):
        result += "\n"
    _atomic_write(path, result)


# -- orchestration ------------------------------------------------------------


def write_plan(claude: AgentPlan, codex: AgentPlan) -> list[str]:
    """Write both agents' plans; return the list of agents actually written.

    Claude Code is always writable. Codex is written when supported; an
    unsupported Codex plan (no TOML parser) is SKIPPED here rather than failing
    the whole render — the preview already surfaced the unsupported status, and
    a missing parser must not block rendering the agent we CAN write.
    """
    written: list[str] = []
    write_claude(claude)
    written.append(claude.agent)
    if codex.supported:
        write_codex(codex)
        written.append(codex.agent)
    return written


def _has_toml_writer_dependency() -> bool:
    """Whether a TOML reader is available (Codex render needs to read for owns).

    Kept as a tiny helper so callers and tests can reason about the Codex path
    without reaching into the provider module directly.
    """
    return codex_provider._toml is not None  # noqa: SLF001


# Re-exported for callers that only need the prefix constant.
__all__ = [
    "BOXA_PREFIX",
    "RenderWriteError",
    "write_claude",
    "write_codex",
    "write_plan",
]
