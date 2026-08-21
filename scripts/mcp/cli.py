"""JSON/text entry point for `boxa mcp` (ADR 0013, issues 01-02).

The shell dispatcher `scripts/mcp-cli.sh` owns arg parsing and process flow; it
shells out to this module for both the machine-readable `--json` paths and the
human-readable candidate tables so the candidate-model serialization and
rendering live in one place (the Python core). Invoked as:

    python3 -m mcp.cli import-json        [--project <key> ...] [--all] [--no-global]
    python3 -m mcp.cli import-text        [--project <key> ...] [--all] [--no-global]
    python3 -m mcp.cli list-inherited-json [--project <key> ...] [--all] [--no-global]

with `scripts/` on PYTHONPATH so `import mcp` resolves to this package.

Issue 02 wires the Claude Code provider into discovery. Scope:

  * default: global config + the project keys passed via `--project`
    (the dispatcher resolves the current Project to its Claude record key);
  * `--all`: every known Claude project record;
  * `--no-global`: skip the top-level global `mcpServers` block.

Read-only and secret-safe: no field carries a secret value, so JSON and text
output can be emitted directly without a redaction pass.
"""

from __future__ import annotations

import io
import json
import os
import shlex
import subprocess  # noqa: S404 - the Boxa Project registry is Docker-backed
import sys
from typing import Optional

from . import casfile, import_result, inherited_list_result, onboarding, seed, trusted
from .activation import (
    ActivationError,
    _entry_activations,
    activate_everywhere,
    clear_everywhere,
    load_activations,
    preflight_activate as preflight_catalog,
    reevaluate_pending,
    remove_catalog_entry,
    update_catalog_entry,
)
from .activation import (
    activate as activate_catalog,
)
from .activation import (
    deactivate as deactivate_catalog,
)
from .add import AddError, add_server
from .apply import (
    ApplyConflictError,
    ScopeOverride,
    is_applicable,
)
from .candidate import Candidate
from .catalog import (
    CATALOG_VERSION,
    CatalogError,
    definition_changes_from_spec,
    isolation_status,
)
from .catalog import (
    add_entry as catalog_add_entry,
)
from .catalog import (
    add_remote_entry as catalog_add_remote_entry,
)
from .catalog import (
    entries_sorted as catalog_entries_sorted,
)
from .catalog import (
    load_catalog as catalog_load,
)
from .catalog import (
    mode_preview as catalog_mode_preview,
)
from .catalog import mutation_lock as catalog_mutation_lock
from .catalog import (
    resolve_entry as catalog_resolve,
)
from .catalog import (
    set_execution_mode as catalog_set_execution_mode,
)
from .catalog_import import (
    CatalogImportConflictError,
    catalog_verdicts,
    destination_scope_overrides,
    import_definitions,
)
from .classify import classify_candidate
from .identity import NotInsideContainerError
from .install import (
    BlockedNetworkError,
    InstallError,
    InstallResult,
    UnsupportedRuntimeError,
    install_server,
)
from .launch_profile import (
    LaunchProfileError,
    claude_launch_profile,
    codex_launch_profile,
)
from .lifecycle import (
    DoctorReport,
    EffectiveList,
    FixResult,
    LifecycleError,
    RemoveResult,
    ToggleResult,
    apply_doctor_fixes,
    catalog_project_status,
    effective_list,
    remove_server,
    run_doctor,
    server_has_secrets,
    set_enabled,
)
from .merge import MergedCandidate, merge_candidates
from .migration import MigrationError, migrate_legacy
from .projects import (
    VolumeProbe,
    basename_of,
    enumerate_project_targets,
    enumerate_volume_project_targets,
    sanitize_basename,
)
from .providers import ClaudeProvider, CodexProvider
from .readiness import (
    ReadinessError,
)
from .readiness import (
    install as install_catalog_entry,
)
from .readiness import (
    readiness as catalog_readiness,
)
from .runner import RunnerError
from .runner import run as runner_run
from .secrets import (
    global_secrets_path,
    project_secrets_path,
    read_header_secrets,
    read_server_secrets,
    store_header_secret,
    store_server_secret,
)


def _emit(payload: dict) -> int:
    json.dump(payload, sys.stdout, indent=2, sort_keys=False)
    sys.stdout.write("\n")
    return 0


def _emit_secret_scopes(scopes: list[tuple[str, str]]) -> None:
    """Write the SECRET-FREE scopes a write copied a secret VALUE into.

    Issue 17 detection-prompt plumbing. When the host shell front-end sets
    ``BOXA_MCP_SCOPES_OUT`` to a file path, an ``apply`` / ``add`` that copies
    a secret VALUE writes the affected scopes there (one ``global`` or
    ``project<TAB><absolute-key>`` line each, de-duplicated), so the front-end
    can decide whether a running Container needs ``boxa mcp reload``. The file
    is host-side plumbing and carries scope labels + project KEYS only — never an
    env-key NAME or a secret VALUE. When the env var is unset (the normal direct
    invocation), nothing is written.

    Best-effort: a write failure must never fail the user's apply/add, so any
    OSError is swallowed (the prompt is an advisory, not a correctness gate).
    """
    out_path = os.environ.get("BOXA_MCP_SCOPES_OUT")
    if not out_path:
        return
    seen: set[tuple[str, str]] = set()
    lines: list[str] = []
    for scope, project_key in scopes:
        key = (scope, project_key)
        if key in seen:
            continue
        seen.add(key)
        if scope == "project" and project_key:
            lines.append(f"project\t{project_key}")
        else:
            lines.append("global")
    try:
        with open(out_path, "w", encoding="utf-8") as fh:
            for line in lines:
                fh.write(line + "\n")
    except OSError:
        pass


class _Scope:
    def __init__(self) -> None:
        self.project_keys: list[str] = []
        self.all_projects: bool = False
        self.include_global: bool = True
        self.server_names: list[str] = []


def _parse_scope(argv: list[str]) -> Optional[_Scope]:
    """Parse the shared scope flags. Returns None on a parse error."""
    scope = _Scope()
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--all":
            scope.all_projects = True
        elif arg == "--no-global":
            scope.include_global = False
        elif arg == "--project":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --project requires a value\n")
                return None
            scope.project_keys.append(argv[i])
        elif arg == "--server":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --server requires a value\n")
                return None
            scope.server_names.append(argv[i])
        else:
            sys.stderr.write(f"mcp.cli: unknown argument {arg!r}\n")
            return None
        i += 1
    return scope


def _discover(
    scope: _Scope,
    *,
    scope_overrides: dict[str, ScopeOverride] | None = None,
    target_project: str = "",
) -> list[MergedCandidate]:
    """Collect candidates from ALL import providers and merge them.

    Each provider normalizes its own config into `Candidate`s; the shared
    `merge_candidates` step (issue 03) then collapses identical candidates
    discovered by multiple providers into one result, flags same-name/same-scope
    spec disagreements as conflicts, and assigns every result a stable, secret-
    free ``importId``. The Codex provider is conservative — it contributes
    nothing (cleanly) when no supported Codex MCP config exists.
    """
    raw: list[Candidate] = []
    raw.extend(
        ClaudeProvider().discover(
            project_keys=scope.project_keys,
            include_global=scope.include_global,
            all_projects=scope.all_projects,
        )
    )
    raw.extend(
        CodexProvider().discover(
            project_keys=scope.project_keys,
            include_global=scope.include_global,
            all_projects=scope.all_projects,
        )
    )
    # Evidence-based classification (issue 04). Providers leave non-excluded
    # candidates as ``unknown``; the classifier assigns the real placement /
    # confidence / reasons here, before merge, so the identity-merge step and
    # both output paths (text + JSON) all see the classified result.
    for cand in raw:
        classify_candidate(cand)
    merged = merge_candidates(raw)
    merged = catalog_verdicts(
        merged,
        scope_overrides=destination_scope_overrides(
            merged,
            scope.project_keys,
            scope_overrides=scope_overrides,
            target_project=target_project,
        ),
    )
    if scope.server_names:
        wanted = set(scope.server_names)
        merged = [item for item in merged if item.candidate.name in wanted]
    return merged


def _render_text(merged: list[MergedCandidate]) -> int:
    """Human-readable discovery report (no secret values, names only).

    Each line group covers one merged candidate: its stable ``importId``, every
    contributing provider/source, the (redacted) command shape and env key
    NAMES, and — when present — a conflict marker pointing at the colliding
    import IDs so the user can pick one with ``--import-id`` once apply exists.
    """
    if not merged:
        sys.stdout.write("No Inherited MCP servers detected in the selected scope.\n")
        sys.stdout.write(
            "\nDry-run only: no MCP profile or agent config was modified.\n"
        )
        sys.stdout.write("Next: boxa mcp import --apply            (interactive)\n")
        return 0

    # v1 supports Container MCP servers only (ADR 0013). After classification,
    # only ``container`` candidates are actually importable; ``host-only`` and
    # ``unknown`` are detected and shown for visibility but are NOT importable
    # in v1, and ``excluded`` (unsupported remote/hosted connectors) cannot be
    # imported. The summary must reflect that split rather than calling every
    # non-excluded candidate importable.
    def _placement(m: MergedCandidate) -> str:
        return m.candidate.classification.placement

    container = [m for m in merged if _placement(m) == "container"]
    host_only = [m for m in merged if _placement(m) == "host-only"]
    unknown = [m for m in merged if _placement(m) == "unknown"]
    excluded = [m for m in merged if _placement(m) == "excluded"]
    conflicts = [m for m in merged if m.conflict]
    new = [m for m in merged if m.catalog_status == "proposal"]
    changed = [m for m in merged if m.catalog_status == "changed"]
    in_sync = [m for m in merged if m.catalog_status == "in-sync"]

    summary = (
        f"Discovered {len(merged)} Inherited MCP server(s) "
        f"({len(container)} importable (container)"
    )
    if host_only:
        summary += f", {len(host_only)} host-only"
    if unknown:
        summary += f", {len(unknown)} unknown"
    if excluded:
        summary += f", {len(excluded)} excluded"
    if conflicts:
        summary += f", {len(conflicts)} in conflict"
    summary += "):\n"
    sys.stdout.write(summary)

    if new:
        sys.stdout.write("\nNew\n")
    if not new and changed:
        sys.stdout.write("\nNew\n  (none)\n")

    for m in merged:
        if m.catalog_status in {"changed", "in-sync"}:
            continue
        cand = m.candidate
        scope_label = cand.source_scope
        if cand.source_project:
            scope_label = f"{scope_label} ({cand.source_project})"
        sys.stdout.write("\n")
        sys.stdout.write(f"  {cand.name}\n")
        sys.stdout.write(f"    import id: {m.import_id}\n")
        sys.stdout.write(f"    providers: {', '.join(m.providers)}\n")
        sys.stdout.write(f"    scope    : {scope_label}\n")
        for src in m.sources:
            sys.stdout.write(f"    source   : {src.provider} -> {src.source_path}\n")
        sys.stdout.write(f"    type     : {cand.type or 'stdio'}\n")
        if cand.command.argv:
            sys.stdout.write(f"    command  : {' '.join(cand.command.argv)}\n")
        if cand.url:
            sys.stdout.write(f"    url      : {cand.url}\n")
        if cand.command.env_keys:
            # NAMES only — never the values.
            sys.stdout.write(
                f"    env keys : {', '.join(cand.command.env_keys)}\n"
            )
        if cand.command.secret_env_keys:
            sys.stdout.write(
                "    secrets  : "
                f"{', '.join(cand.command.secret_env_keys)} (values not shown)\n"
            )
        if cand.type == "http" and cand.headers:
            sys.stdout.write(f"    headers  : {', '.join(cand.headers)}\n")
        if cand.type == "http" and cand.secret_header_keys:
            sys.stdout.write(
                "    secret headers: "
                f"{', '.join(cand.secret_header_keys)} (values not shown)\n"
            )
        if m.conflict:
            sys.stdout.write(
                "    conflict : same name+scope as a different spec; "
                f"choose by import id ({', '.join(m.conflict_with)})\n"
            )
        if m.catalog_status == "already-cataloged":
            sys.stdout.write(
                f"    catalog  : already in catalog as {m.catalog_name} ({m.catalog_id})\n"
            )
        elif m.catalog_status == "conflict":
            sys.stdout.write(
                f"    catalog  : conflicts with {m.catalog_name} ({m.catalog_id})\n"
            )
            for difference in m.catalog_diff:
                sys.stdout.write(
                    f"    diff     : {difference['field']}: "
                    f"catalog={difference['catalog']!r} candidate={difference['candidate']!r}\n"
                )
        # Classification (issue 04): placement + confidence for every candidate,
        # plus the evidence reasons that justify it. Secret-safe — reasons only
        # ever name env keys, never their values.
        cls = cand.classification
        confidence = f"/{cls.confidence}" if cls.confidence else ""
        sys.stdout.write(f"    placement: {cls.placement}{confidence}\n")
        for reason in cls.reasons:
            sys.stdout.write(f"    reason   : {reason}\n")
    if changed:
        sys.stdout.write("\nChanged (reimport)\n")
        for m in changed:
            sys.stdout.write(f"\n  {m.candidate.name}\n")
            sys.stdout.write(f"    import id: {m.import_id}\n")
            sys.stdout.write(
                f"    catalog  : {m.catalog_name} ({m.catalog_id})\n"
            )
            for difference in m.catalog_diff:
                sys.stdout.write(
                    f"    diff     : {difference['field']}: "
                    f"catalog={difference['catalog']!r} "
                    f"candidate={difference['candidate']!r}\n"
                )
    if in_sync:
        sys.stdout.write(
            f"\n{len(in_sync)} entries in sync with host configs.\n"
        )
    sys.stdout.write("\nDry-run only: no MCP profile or agent config was modified.\n")
    sys.stdout.write("Next: boxa mcp import --apply            (interactive)\n")
    if merged:
        sys.stdout.write(
            f"      boxa mcp import --apply --server {merged[0].candidate.name}\n"
        )
    return 0


def _runtime_label(cand: Candidate) -> str:
    """Coarse runtime family for the inherited table's RUNTIME column.

    Derived from argv[0] only (the launcher), never from secret-bearing args.
    """
    if not cand.command.argv:
        return "-"
    base = cand.command.argv[0].rsplit("/", 1)[-1].lower()
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


def _render_inherited_table(merged: list[MergedCandidate]) -> int:
    """Readable table of Inherited MCP candidates (issue 04 list --inherited).

    Columns: NAME, PROVIDER, SCOPE, STATUS (placement/confidence, plus a
    ``(conflict)`` marker when the merge step flagged competing specs in the
    same name+scope slot), RUNTIME, SOURCE (plan question 22). The PROVIDER and
    SOURCE columns preserve the full merged provenance: every contributing
    provider and every config path are shown, not just the first, so a server
    discovered by both Claude Code and Codex is not silently reduced to one.

    Secret-safe: every column is derived from non-secret identity metadata —
    env-variable values never appear; SOURCE shows the config file path(s) the
    candidate was discovered in.
    """
    if not merged:
        sys.stdout.write(
            "No Inherited MCP servers detected in the selected scope.\n"
        )
        return 0

    any_conflict = any(m.conflict for m in merged)

    rows: list[tuple[str, str, str, str, str, str]] = []
    for m in merged:
        cand = m.candidate
        scope_label = cand.source_scope
        if cand.source_project:
            scope_label = f"{scope_label}:{cand.source_project.rsplit('/', 1)[-1]}"
        cls = cand.classification
        status = cls.placement
        if cls.confidence:
            status = f"{cls.placement}/{cls.confidence}"
        # A conflict means another candidate shares this name+scope with a
        # different spec; the user must choose between import IDs (issue 05).
        # The import text and JSON views already expose this — keep the table
        # honest about it too rather than showing two identical-looking rows.
        if m.conflict:
            status = f"{status} (conflict)"
        if m.catalog_status == "already-cataloged":
            status = f"{status} (already in catalog)"
        elif m.catalog_status == "conflict":
            status = f"{status} (catalog conflict)"
        # Preserve all merged sources, not just the first: a server discovered
        # by multiple providers carries one source per provider/path.
        sources = (
            "; ".join(f"{s.provider}:{s.source_path}" for s in m.sources)
            or cand.source_path
        )
        rows.append(
            (
                cand.name,
                ", ".join(m.providers),
                scope_label,
                status,
                _runtime_label(cand),
                sources,
            )
        )

    headers = ("NAME", "PROVIDER", "SCOPE", "STATUS", "RUNTIME", "SOURCE")
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def _fmt(cells: tuple[str, ...]) -> str:
        return "  ".join(cell.ljust(widths[i]) for i, cell in enumerate(cells)).rstrip()

    sys.stdout.write(_fmt(headers) + "\n")
    for row in rows:
        sys.stdout.write(_fmt(row) + "\n")
    if any_conflict:
        sys.stdout.write(
            "\nA (conflict) row shares its name+scope with a different spec; "
            "use the import view's import IDs to choose between them.\n"
        )
    sys.stdout.write(
        "\nInherited MCP servers only (read-only); no profile was written.\n"
    )
    return 0


class _Selection:
    """Parsed apply selection flags layered on top of the scope flags.

    ``--server <name>`` and ``--import-id <id>`` are repeatable and choose which
    discovered candidates to apply. ``--all-applicable`` selects every applicable
    (``container``) candidate — used by the shell dispatcher after an interactive
    multi-select picker has already confirmed the choice with the user.
    """

    def __init__(self) -> None:
        self.scope = _Scope()
        self.servers: list[str] = []
        self.import_ids: list[str] = []
        self.all_applicable: bool = False
        self.all_changed: bool = False
        self.reimport: bool = False
        self.force_host_only: bool = False
        self.catalog_conflicts: dict[str, str] = {}
        self.catalog_conflict_default: str = ""
        # ADR 0013 amendment (issue 12): per-server scope overrides keyed by
        # import id, set only by the interactive apply wizard. Empty otherwise,
        # so the non-interactive path preserves inherited scope byte-for-byte.
        self.overrides: dict[str, ScopeOverride] = {}
        # Interactive import-wizard follow-up activations. Each tuple is
        # (consumer set, absolute Project key); non-interactive callers never
        # emit this private plumbing flag.
        self.wizard_activations: dict[str, list[tuple[str, str]]] = {}


def _parse_selection(argv: list[str]) -> Optional[_Selection]:
    sel = _Selection()
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--all":
            sel.scope.all_projects = True
        elif arg == "--no-global":
            sel.scope.include_global = False
        elif arg == "--all-applicable":
            sel.all_applicable = True
        elif arg == "--all-changed":
            sel.all_changed = True
            sel.reimport = True
        elif arg == "--reimport":
            sel.reimport = True
        elif arg == "--force":
            sel.force_host_only = True
        elif arg == "--catalog-conflict":
            if i + 2 >= len(argv):
                sys.stderr.write(
                    "mcp.cli: --catalog-conflict requires <import-id> <update|skip>\n"
                )
                return None
            import_id, resolution = argv[i + 1:i + 3]
            if resolution not in {"update", "skip"}:
                sys.stderr.write(
                    "mcp.cli: --catalog-conflict resolution must be update or skip\n"
                )
                return None
            sel.catalog_conflicts[import_id] = resolution
            i += 2
        elif arg == "--conflict":
            i += 1
            if i >= len(argv) or argv[i] not in {"update", "skip"}:
                sys.stderr.write(
                    "mcp.cli: --conflict requires update or skip\n"
                )
                return None
            sel.catalog_conflict_default = argv[i]
        elif arg == "--project":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --project requires a value\n")
                return None
            sel.scope.project_keys.append(argv[i])
        elif arg == "--server":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --server requires a value\n")
                return None
            sel.servers.append(argv[i])
        elif arg == "--import-id":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --import-id requires a value\n")
                return None
            sel.import_ids.append(argv[i])
        elif arg == "--override":
            # Per-server scope override emitted by the apply wizard. Shape:
            #   --override <import-id> global
            #   --override <import-id> project <absolute-project-key>
            # The import id selects which candidate is overridden; an override
            # for a candidate that is not also in the selection is a no-op (the
            # wizard always pairs --override with the matching --import-id).
            if i + 2 >= len(argv):
                sys.stderr.write(
                    "mcp.cli: --override requires <import-id> <scope> "
                    "[<project-key>]\n"
                )
                return None
            iid = argv[i + 1]
            ov_scope = argv[i + 2]
            consumed = 2
            project_key = ""
            if ov_scope == "project":
                if i + 3 >= len(argv):
                    sys.stderr.write(
                        "mcp.cli: --override <id> project requires a "
                        "project key\n"
                    )
                    return None
                project_key = argv[i + 3]
                consumed = 3
            try:
                sel.overrides[iid] = ScopeOverride(
                    scope=ov_scope, project_key=project_key
                )
            except ValueError as exc:
                sys.stderr.write(f"mcp.cli: invalid --override: {exc}\n")
                return None
            i += consumed
        elif arg == "--wizard-activation":
            if i + 3 >= len(argv):
                sys.stderr.write(
                    "mcp.cli: --wizard-activation requires "
                    "<import-id> <consumer> <project-key>\n"
                )
                return None
            iid, consumer, project_key = argv[i + 1:i + 4]
            if consumer not in {"claude", "codex", "claude,codex"}:
                sys.stderr.write(
                    "mcp.cli: --wizard-activation consumer must be "
                    "claude, codex, or claude,codex\n"
                )
                return None
            if not os.path.isabs(project_key):
                sys.stderr.write(
                    "mcp.cli: --wizard-activation requires an absolute "
                    "project key\n"
                )
                return None
            self_activations = sel.wizard_activations.setdefault(iid, [])
            self_activations.append((consumer, os.path.realpath(project_key)))
            i += 3
        else:
            sys.stderr.write(f"mcp.cli: unknown argument {arg!r}\n")
            return None
        i += 1
    return sel


def _resolve_selection(
    merged: list[MergedCandidate], sel: _Selection
) -> Optional[list[MergedCandidate]]:
    """Turn selection flags into the concrete candidates to apply.

    Resolution rules (local-plan-mcp.md decision 18):

      * ``--import-id <id>`` picks an exact candidate; an unknown ID is an error.
      * ``--server <name>`` picks by name but FAILS on ambiguity (two candidates
        share the name, e.g. a conflict or a global+project pair) and tells the
        user to disambiguate with ``--import-id``.
      * ``--all-applicable`` picks every applicable candidate (post-picker path).
      * No selection at all is an error here — the shell dispatcher only calls
        the Python apply path once it has a selection (picker or flags), and a
        non-interactive apply without selection is rejected upstream.

    Returns None (after writing a message to stderr) on any selection error.
    """
    chosen: dict[str, MergedCandidate] = {}

    by_id = {m.import_id: m for m in merged}
    for iid in sel.import_ids:
        m = by_id.get(iid)
        if m is None:
            sys.stderr.write(f"mcp.cli: no candidate with import id {iid!r}\n")
            return None
        if m.catalog_status in {"changed", "in-sync"} and not sel.reimport:
            sys.stderr.write(
                f"mcp.cli: import id {iid!r} is already cataloged; pass "
                "--reimport to select it\n"
            )
            return None
        chosen[m.import_id] = m

    for name in sel.servers:
        matches = [m for m in merged if m.candidate.name == name]
        if not matches:
            sys.stderr.write(f"mcp.cli: no candidate named {name!r}\n")
            return None
        if len(matches) > 1:
            ids = ", ".join(m.import_id for m in matches)
            sys.stderr.write(
                f"mcp.cli: server name {name!r} is ambiguous "
                f"({len(matches)} candidates); choose one with --import-id "
                f"({ids})\n"
            )
            return None
        match = matches[0]
        if match.catalog_status in {"changed", "in-sync"} and not sel.reimport:
            sys.stderr.write(
                f"mcp.cli: server {name!r} is already cataloged; pass --reimport "
                "to select it\n"
            )
            return None
        chosen[match.import_id] = match

    if sel.all_applicable:
        for m in merged:
            if is_applicable(m) and m.catalog_status == "proposal":
                chosen[m.import_id] = m

    if sel.all_changed:
        for m in merged:
            if is_applicable(m) and m.catalog_status == "changed":
                chosen[m.import_id] = m

    if not chosen:
        if sel.all_changed:
            return []
        sys.stderr.write(
            "mcp.cli: no candidates selected; pass --server <name>, "
            "--import-id <id>, --all-applicable, or --all-changed\n"
        )
        return None

    unknown_activations = set(sel.wizard_activations) - set(chosen)
    if unknown_activations:
        unknown = sorted(unknown_activations)[0]
        sys.stderr.write(
            f"mcp.cli: wizard activation references unselected import id {unknown!r}\n"
        )
        return None

    # Preserve discovery order for a stable, repeatable summary.
    return [m for m in merged if m.import_id in chosen]


def _apply_wizard_activations(
    result, sel: _Selection
) -> tuple[list[dict[str, object]], bool]:
    """Activate imported wizard selections and preserve every Project outcome."""
    imported = {item.import_id: item for item in result.imported}
    outcomes: list[dict[str, object]] = []
    failed = False
    for import_id, requests in sel.wizard_activations.items():
        item = imported.get(import_id)
        if item is None:
            continue
        try:
            _entry_id, entry = catalog_resolve(catalog_load(), item.catalog_id)
        except (CatalogError, OSError, ValueError) as exc:
            failed = True
            for consumer, project in requests:
                outcomes.append({
                    "outcome": "failed",
                    "projectKey": project,
                    "entry": {
                        "id": item.catalog_id,
                        "name": getattr(item, "catalog_name", item.catalog_id),
                    },
                    "consumers": consumer.split(","),
                    "error": str(exc),
                })
            continue

        accept_degraded = False
        if isolation_status(entry) == "degraded-secret-isolation":
            consent = _wizard_degradation_consent(str(entry["name"]))
            if consent is not True:
                reason = (
                    "degraded-secret-isolation confirmation was declined"
                    if consent is False
                    else "degraded-secret-isolation requires interactive confirmation"
                )
                for consumer, project in requests:
                    outcomes.append({
                        "outcome": "skipped",
                        "projectKey": project,
                        "reason": reason,
                        "next": (
                            "boxa mcp activate "
                            f"{shlex.quote(str(entry['name']))} --project "
                            f"{shlex.quote(project)} --for {consumer} "
                            "--accept-degraded-secret-isolation"
                        ),
                    })
                continue
            accept_degraded = True

        for consumer, project in requests:
            consumers = consumer.split(",")
            try:
                preflight_catalog(
                    item.catalog_id,
                    project,
                    consumers,
                    accept_degraded_secret_isolation=accept_degraded,
                )
                activation = activate_catalog(
                    item.catalog_id,
                    project,
                    consumers,
                    accept_degraded_secret_isolation=accept_degraded,
                )
            except Exception as exc:
                failed = True
                outcomes.append({
                    "outcome": "failed",
                    "projectKey": project,
                    "entry": dict(entry),
                    "consumers": consumers,
                    "error": str(exc),
                })
                continue
            payload = activation.to_dict()
            payload["outcome"] = "pending" if activation.pending else "activated"
            outcomes.append(payload)
    return outcomes, failed


def _open_controlling_terminal() -> io.TextIOWrapper:
    """Open the controlling terminal for line-oriented reads and writes."""
    return io.TextIOWrapper(
        io.FileIO(os.open("/dev/tty", os.O_RDWR), mode="r+", closefd=True),
        encoding="utf-8",
        write_through=True,
    )


def _controlling_terminal_usable() -> bool:
    """Return whether the process can open its controlling terminal."""
    try:
        with _open_controlling_terminal():
            pass
    except OSError:
        return False
    return True


def _wizard_degradation_consent(entry_name: str) -> Optional[bool]:
    """Prompt once for a wizard entry; None means no interactive terminal."""
    if not _controlling_terminal_usable():
        return None
    try:
        with _open_controlling_terminal() as tty:
            tty.write(
                "WARNING: degraded-secret-isolation: node owns the Docker "
                "daemon and can inspect this server's container environment.\n"
            )
            tty.write(
                f"Accept this temporary secret-isolation limitation for "
                f"{entry_name!r}? [y/N] "
            )
            tty.flush()
            reply = tty.readline().strip()
    except OSError:
        return None
    return reply.lower() in {"y", "yes"}


def _render_wizard_activation_outcomes(
    activations: list[dict[str, object]],
) -> None:
    """Render every completed, skipped, and failed wizard activation."""
    for activation in activations:
        outcome = activation.get("outcome")
        project_key = str(activation["projectKey"])
        if outcome == "failed":
            entry = activation["entry"]
            assert isinstance(entry, dict)
            consumers = activation["consumers"]
            assert isinstance(consumers, list)
            sys.stderr.write(
                f"Failed MCP activation {entry['name']!r} for "
                f"{', '.join(consumers)} in Project {project_key}: "
                f"{activation['error']}.\n"
            )
            continue
        if outcome == "skipped":
            sys.stdout.write(
                f"Skipped MCP activation for Project {project_key}: "
                f"{activation['reason']}.\n"
            )
            sys.stdout.write(f"Next: {activation['next']}\n")
            continue
        entry = activation["entry"]
        assert isinstance(entry, dict)
        consumers = activation["consumers"]
        assert isinstance(consumers, list)
        if activation.get("pending"):
            sys.stdout.write(
                f"Pending MCP catalog activation {entry['name']!r} for "
                f"{', '.join(consumers)} in Project {project_key}.\n"
            )
            sys.stdout.write(
                "Readiness will be re-evaluated at the next Container "
                f"start: {activation['pendingReason']}.\n"
            )
            sys.stdout.write(
                "Next: boxa mcp readiness "
                f"{shlex.quote(str(entry['name']))} --project "
                f"{shlex.quote(project_key)}\n"
            )
        else:
            sys.stdout.write(
                f"Activated MCP catalog entry {entry['name']!r} for "
                f"{', '.join(consumers)} in Project {project_key}.\n"
            )
            sys.stdout.write(
                "The launch-time MCP profile is ready; start a new agent "
                "session to connect.\n"
            )


def _secret_consent(
    kind: str, name: str, source_path: str, rotation: bool
) -> bool:
    """Ask one default-no takeover question without ever displaying a value."""
    noun = "secret header" if kind == "header" else "secret environment variable"
    if rotation:
        prompt = (
            f"Stored value for {noun} {name!r} differs — update from "
            f"{source_path}? [y/N] "
        )
    else:
        prompt = (
            f"Take over the value of {noun} {name!r} from {source_path} into "
            "the host-only secret store? [y/N] "
        )
    try:
        with _open_controlling_terminal() as tty:
            tty.write(prompt)
            tty.flush()
            reply = tty.readline().strip()
    except OSError:
        return False
    return reply.lower() in {"y", "yes"}


def _apply_payload(merged: list[MergedCandidate], sel: _Selection) -> dict:
    selected = _resolve_selection(merged, sel)
    if selected is None:
        return {"error": "selection"}
    try:
        resolutions = dict(sel.catalog_conflicts)
        if sel.catalog_conflict_default:
            for candidate in selected:
                if candidate.catalog_status == "conflict":
                    resolutions.setdefault(
                        candidate.import_id, sel.catalog_conflict_default
                    )
        result = import_definitions(
            selected,
            catalog_conflicts=resolutions,
            force_host_only=sel.force_host_only,
            secret_consent=None,
            scope_overrides=destination_scope_overrides(
                selected, sel.scope.project_keys, scope_overrides=sel.overrides
            ),
        )
    except (
        ApplyConflictError, CatalogImportConflictError, CatalogError,
        ActivationError, OSError, ValueError,
    ) as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return {"error": "conflict"}
    _emit_secret_scopes(result.secret_scopes)
    payload = result.to_dict()
    if sel.wizard_activations:
        activations, activation_failed = _apply_wizard_activations(result, sel)
        payload["activations"] = activations
        if activation_failed:
            payload["activationFailed"] = True
    return payload


def _render_apply_text(merged: list[MergedCandidate], sel: _Selection) -> int:
    """Human-readable apply summary. SECRET-FREE: copied secret KEY NAMES only.

    Reports each applied server, its scope and profile path, and exactly which
    env keys were copied into the boxa secret store — never their values. Any
    non-applicable selection (host-only / unknown / excluded) is listed as
    skipped with a reason so the user is never left wondering why a choice did
    nothing.
    """
    selected = _resolve_selection(merged, sel)
    if selected is None:
        return 2
    try:
        resolutions = dict(sel.catalog_conflicts)
        if sel.catalog_conflict_default:
            for candidate in selected:
                if candidate.catalog_status == "conflict":
                    resolutions.setdefault(
                        candidate.import_id, sel.catalog_conflict_default
                    )
        result = import_definitions(
            selected,
            catalog_conflicts=resolutions,
            force_host_only=sel.force_host_only,
            secret_consent=(
                _secret_consent if _controlling_terminal_usable() else None
            ),
            scope_overrides=destination_scope_overrides(
                selected, sel.scope.project_keys, scope_overrides=sel.overrides
            ),
        )
    except (
        ApplyConflictError, CatalogImportConflictError, CatalogError,
        ActivationError, OSError, ValueError,
    ) as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 2

    _emit_secret_scopes(result.secret_scopes)
    activations, activation_failed = _apply_wizard_activations(result, sel)
    if not result.imported and not result.skipped:
        sys.stdout.write("No definitions imported.\n")
        return 0

    for a in result.imported:
        sys.stdout.write(f"Imported definition {a.name}\n")
        sys.stdout.write(f"  import id: {a.import_id}\n")
        sys.stdout.write(f"  catalog  : {a.catalog_name} ({a.catalog_id})\n")
        sys.stdout.write(f"  changed  : {'yes' if a.changed else 'no (in sync)'}\n")

    for s in result.skipped:
        sys.stdout.write(
            f"Skipped {s['name']} ({s['importId']}): {s['reason']}\n"
        )

    for item in result.skipped_secrets:
        sys.stdout.write(
            f"Skipped credential values for {item['name']}: "
            f"{', '.join(item['keys'])}\n"
        )
    if result.skipped_secrets:
        sys.stdout.write("Next: boxa mcp secret set\n")
    if result.taken_secrets:
        sys.stdout.write(
            "Credential values were moved into the host-only secret store. "
            "Consider removing their plaintext copies from the host config.\n"
        )

    if activations:
        sys.stdout.write("\n")
        _render_wizard_activation_outcomes(activations)
    else:
        sys.stdout.write(
            "\nCatalog definitions updated only. Nothing was installed, "
            "activated, or rendered.\n"
        )
    imported = {item.import_id: item for item in result.imported}
    selected_by_id = {item.import_id: item for item in selected}
    skipped_secret_keys = {
        str(item["name"]): set(item["keys"])
        for item in result.skipped_secrets
    }
    if len(imported) == 1 and not activations:
        imported_item = next(iter(imported.values()))
        candidate = selected_by_id[imported_item.import_id].candidate
        if candidate.type != "http":
            sys.stdout.write(
                "Next: boxa mcp install "
                f"{shlex.quote(imported_item.catalog_name)}\n"
            )
            sys.stdout.write(
                "Then: boxa mcp activate "
                f"{shlex.quote(imported_item.catalog_name)} "
                "--project <path> --for claude|codex\n"
            )
        else:
            missing_headers = [
                header for header in candidate.secret_header_keys
                if header in skipped_secret_keys.get(
                    imported_item.catalog_name, set()
                )
            ]
            for header in missing_headers:
                sys.stdout.write(
                    "Next: boxa mcp secret set "
                    f"{shlex.quote(imported_item.catalog_name)} "
                    f"{shlex.quote(header)}\n"
                )
            sys.stdout.write(
                f"{'Then' if missing_headers else 'Next'}: "
                "boxa mcp activate "
                f"{shlex.quote(imported_item.catalog_name)} "
                "--project <path> --for claude|codex\n"
            )
    elif imported and not activations:
        sys.stdout.write("Next: boxa mcp catalog\n")
    return 1 if activation_failed else 0


def _cmd_import_activate(argv: list[str], as_json: bool) -> int:
    """Import selected catalog definitions, check readiness, then activate."""
    project = ""
    consumers: list[str] = []
    selection_argv: list[str] = []
    yes = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--target-project":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --target-project requires a value\n")
                return 2
            project = argv[i]
        elif arg == "--for":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --for requires a consumer\n")
                return 2
            consumers.extend(value for value in argv[i].split(",") if value)
        elif arg == "--yes":
            yes = True
        else:
            selection_argv.append(arg)
        i += 1
    if not project or not consumers:
        sys.stderr.write(
            "mcp.cli: import activation requires --target-project <path> "
            "and --for claude, codex, or both\n"
        )
        return 2
    sel = _parse_selection(selection_argv)
    if sel is None:
        return 2
    selected = _resolve_selection(
        _discover(
            sel.scope,
            scope_overrides=sel.overrides,
            target_project=project,
        ),
        sel,
    )
    if selected is None:
        return 2
    try:
        resolutions = dict(sel.catalog_conflicts)
        if sel.catalog_conflict_default:
            for candidate in selected:
                if candidate.catalog_status == "conflict":
                    resolutions.setdefault(
                        candidate.import_id, sel.catalog_conflict_default
                    )
        imported = import_definitions(
            selected,
            catalog_conflicts=resolutions,
            force_host_only=sel.force_host_only,
            secret_consent=(
                _secret_consent
                if not as_json and _controlling_terminal_usable()
                else None
            ),
            scope_overrides=destination_scope_overrides(
                selected,
                sel.scope.project_keys,
                scope_overrides=sel.overrides,
                target_project=project,
            ),
        )
    except (CatalogImportConflictError, CatalogError, ActivationError) as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1

    _emit_secret_scopes(imported.secret_scopes)
    flow: list[dict[str, object]] = []
    for item in imported.imported:
        readiness_payload: dict[str, object]
        try:
            report = catalog_readiness(item.catalog_id, os.path.realpath(project))
            readiness_payload = report.to_dict()
        except ReadinessError as exc:
            readiness_payload = {"ready": False, "error": str(exc)}
        try:
            activation = activate_catalog(
                item.catalog_id,
                os.path.realpath(project),
                consumers,
            )
        except ActivationError as exc:
            sys.stderr.write(f"mcp.cli: {exc}\n")
            return 1
        flow.append({
            "catalogId": item.catalog_id,
            "catalogName": item.catalog_name,
            "readiness": readiness_payload,
            "activation": activation.to_dict(),
        })
    payload = {
        "accepted": yes,
        "import": imported.to_dict(),
        "flow": flow,
    }
    if as_json:
        return _emit(payload)
    for step in flow:
        activation = step["activation"]
        assert isinstance(activation, dict)
        state = "pending" if activation.get("pending") else "activated"
        sys.stdout.write(
            f"Imported, checked readiness, and {state} "
            f"{step['catalogName']} for Project {activation['projectKey']}.\n"
        )
    for skipped in imported.skipped:
        sys.stdout.write(
            f"Skipped {skipped['name']} ({skipped['importId']}): {skipped['reason']}\n"
        )
    return 0


def _render_applicable_list(merged: list[MergedCandidate]) -> int:
    """Emit one applicable candidate per line for the shell's TTY picker.

    Format: ``<import_id>\\t<name>\\t<scope>``. Applicable means ``container``
    placement (the only thing v1 can apply). SECRET-FREE — identity metadata
    only. Non-applicable candidates are intentionally omitted so the picker can
    never offer a host-only/unknown choice.
    """
    for m in merged:
        if (
            not is_applicable(m)
            or m.catalog_status in {"already-cataloged", "conflict"}
        ):
            continue
        scope = m.candidate.source_scope
        if m.candidate.source_project:
            scope = f"{scope}:{m.candidate.source_project}"
        sys.stdout.write(f"{m.import_id}\t{m.candidate.name}\t{scope}\n")
    return 0


def _render_applicable_wizard(merged: list[MergedCandidate]) -> int:
    """Emit applicable candidates for the interactive apply WIZARD (issue 12).

    Richer than ``list-applicable``: each line carries the source project KEY so
    the wizard's project picker can pre-highlight the server's source Project
    when its (inherited or overridden) scope is project. SECRET-FREE — identity
    and directory metadata only.

    Format (unit-separator-delimited, one applicable candidate per line)::

        <import_id>\\x1f<name>\\x1f<source_scope>\\x1f<source_project_key>

    ``source_scope`` is the bare scope (``global`` / ``project``) WITHOUT the
    project suffix (the key follows in its own column). ``source_project_key`` is
    the absolute host path the candidate was discovered in, or empty for a global
    source. ``container`` candidates use the original four-column shape;
    host-only candidates add placement and reason columns so the wizard can
    require an explicit force confirmation. Unknown/excluded candidates stay
    report-only.
    """
    separator = "\x1f"

    def display_field(value: object) -> str:
        return "".join(
            " " if ord(char) < 32 or ord(char) == 127 else char
            for char in str(value)
        )

    for m in merged:
        placement = m.candidate.classification.placement
        if placement not in {"container", "host-only"} or m.catalog_status == "already-cataloged":
            continue
        project_key = m.candidate.source_project or ""
        if any(ord(char) < 32 or ord(char) == 127 for char in project_key):
            sys.stderr.write(
                "Skipping MCP import candidate "
                f"{display_field(m.candidate.name)!r}: source Project key "
                "contains an ASCII protocol delimiter.\n"
            )
            continue
        if m.catalog_status == "proposal" and placement == "container":
            sys.stdout.write(
                separator.join((
                    m.import_id,
                    display_field(m.candidate.name),
                    m.candidate.source_scope,
                    project_key,
                )) + "\n"
            )
            continue
        reason = "; ".join(m.candidate.classification.reasons)
        if m.catalog_status == "changed":
            reason = json.dumps(
                m.catalog_diff, sort_keys=True, separators=(",", ":")
            )
        sys.stdout.write(
            separator.join((
                m.import_id,
                display_field(m.candidate.name),
                m.candidate.source_scope,
                project_key,
                m.catalog_status,
                placement,
                display_field(reason),
            )) + "\n"
        )
    return 0


def _render_effective_table(result: EffectiveList) -> int:
    """Readable effective MCP profile table (issue 08 `boxa mcp list`).

    Columns: NAME, SCOPE, STATUS, PLACEMENT, RUNTIME, SOURCE (decision 22). A
    Project entry shadowing a same-named global entry is marked on the global
    row. SECRET-FREE: every column is non-secret identity; env values never
    appear. PLACEMENT is ``container`` for every boxa profile entry (v1 only
    stores Container MCP servers).
    """
    if not result.entries:
        sys.stdout.write(
            "No boxa MCP profile servers. Import inherited servers with "
            "'boxa mcp import --apply' first.\n"
        )
        return 0

    rows: list[tuple[str, str, str, str, str, str]] = []
    for e in result.entries:
        scope_label = e.scope
        if e.project_key:
            scope_label = f"{e.scope}:{e.project_key.rsplit('/', 1)[-1]}"
        status = e.status
        if e.shadowed:
            status = f"{status} (shadowed)"
        source = e.source_provider or "-"
        rows.append(
            (
                e.name,
                scope_label,
                status,
                "container",
                e.runtime,
                source,
            )
        )

    headers = ("NAME", "SCOPE", "STATUS", "PLACEMENT", "RUNTIME", "SOURCE")
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def _fmt(cells: tuple[str, ...]) -> str:
        return "  ".join(
            cell.ljust(widths[i]) for i, cell in enumerate(cells)
        ).rstrip()

    sys.stdout.write(_fmt(headers) + "\n")
    for row in rows:
        sys.stdout.write(_fmt(row) + "\n")
    if any(e.shadowed for e in result.entries):
        sys.stdout.write(
            "\nA (shadowed) global entry is overridden by a Project entry of the "
            "same name for the current Project.\n"
        )
    return 0


def _render_toggle_text(result: ToggleResult, enabled: bool) -> int:
    """Human-readable enable/disable summary (SECRET-FREE)."""
    verb = "enabled" if enabled else "disabled"
    scope_label = result.scope
    if result.project_key:
        scope_label = f"{result.scope} ({result.project_key})"
    if result.no_op:
        sys.stdout.write(
            f"MCP server {result.name!r} is already {verb} in the {scope_label} "
            "profile; no change.\n"
        )
        return 0
    if result.created_override:
        sys.stdout.write(
            f"Disabled MCP server {result.name!r} for the {scope_label} profile "
            "via a Project override; the global entry is unchanged and still "
            "available in other projects.\n"
        )
        # Codex has no per-project MCP namespace, so a project-only disable of a
        # globally-rendered server cannot be enforced for Codex (it stays offered
        # in the single global Codex table). Claude enforces it via the project
        # record shadow. Be honest about the Codex limitation rather than imply a
        # complete disable.
        sys.stdout.write(
            "  note: this Project disable is enforced for Claude Code only; "
            "Codex has no per-project MCP scope, so the server remains offered "
            "in Codex. Use 'boxa mcp disable {name} --global' to disable it "
            "everywhere.\n".format(name=result.name)
        )
    else:
        sys.stdout.write(
            f"{verb.capitalize()} MCP server {result.name!r} in the "
            f"{scope_label} profile.\n"
        )
    return 0


def _render_remove_text(result: RemoveResult) -> int:
    """Human-readable remove summary (SECRET-FREE)."""
    scope_label = result.scope
    if result.project_key:
        scope_label = f"{result.scope} ({result.project_key})"
    if result.removed:
        sys.stdout.write(
            f"Removed boxa MCP server {result.name!r} from the {scope_label} "
            "profile.\n"
        )
    else:
        # The profile entry was already gone; this run only cleaned up an
        # orphaned scoped secret block.
        sys.stdout.write(
            f"No {scope_label} profile entry for {result.name!r} (already "
            "removed); cleaned up its orphaned secrets.\n"
        )
    if result.secrets_purged:
        if result.purged_secret_keys:
            sys.stdout.write(
                "Purged scoped secret store keys: "
                f"{', '.join(result.purged_secret_keys)} (values not shown).\n"
            )
        else:
            sys.stdout.write("No scoped secrets to purge.\n")
    else:
        sys.stdout.write(
            "Left any scoped secrets in place (pass --purge to delete them).\n"
        )
    sys.stdout.write(
        "Inherited/manual agent MCP entries were not touched.\n"
    )
    return 0


_SEVERITY_TAG = {"error": "ERROR", "warning": "WARN ", "info": "INFO "}


def _render_doctor_text(report: DoctorReport) -> int:
    """Human-readable doctor report (SECRET-FREE).

    Lists each finding with its severity, message, and a concrete repair
    command. Exit code is 1 when any ERROR finding is present, else 0.
    """
    where = "inside a boxa Container" if report.inside_container else "on the host"
    sys.stdout.write(f"boxa mcp doctor ({where}):\n")
    if not report.findings:
        sys.stdout.write("  All checks passed. No problems detected.\n")
        return 0
    for f in report.findings:
        tag = _SEVERITY_TAG.get(f.severity, f.severity.upper())
        sys.stdout.write(f"  [{tag}] {f.message}\n")
        if f.repair:
            sys.stdout.write(f"          repair: {f.repair}\n")
    fixable = [f for f in report.findings if f.fixable]
    if fixable:
        sys.stdout.write(
            "\nSome problems can be fixed safely with 'boxa mcp doctor --fix'.\n"
        )
    return 0 if report.ok else 1


def _render_fix_text(result: FixResult) -> int:
    """Human-readable doctor --fix summary (SECRET-FREE)."""
    if result.actions:
        sys.stdout.write("Applied safe fixes:\n")
        for action in result.actions:
            sys.stdout.write(f"  - {action}\n")
    else:
        sys.stdout.write("No safe fixes were needed.\n")
    if result.remaining:
        sys.stdout.write("\nRemaining problems (not safely auto-fixable):\n")
        for f in result.remaining:
            tag = _SEVERITY_TAG.get(f.severity, f.severity.upper())
            sys.stdout.write(f"  [{tag}] {f.message}\n")
            if f.repair:
                sys.stdout.write(f"          repair: {f.repair}\n")
    has_error = any(f.severity == "error" for f in result.remaining)
    return 1 if has_error else 0


class _LifecycleScope:
    """Scope flags for the lifecycle commands: optional --project, --global."""

    def __init__(self) -> None:
        self.project_key: Optional[str] = None
        self.is_global: bool = False
        self.purge: bool = False
        self.positional: list[str] = []


def _parse_lifecycle_scope(argv: list[str]) -> Optional[_LifecycleScope]:
    """Parse enable/disable/remove flags. Returns None on a parse error."""
    out = _LifecycleScope()
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--global":
            out.is_global = True
        elif arg == "--purge":
            out.purge = True
        elif arg == "--project":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --project requires a value\n")
                return None
            out.project_key = argv[i]
        elif arg.startswith("--project="):
            value = arg[len("--project="):]
            if not value:
                sys.stderr.write("mcp.cli: --project requires a non-empty value\n")
                return None
            out.project_key = value
        elif arg.startswith("-"):
            sys.stderr.write(f"mcp.cli: unknown argument {arg!r}\n")
            return None
        else:
            out.positional.append(arg)
        i += 1
    return out


def _resolve_lifecycle_scope(
    scope: _LifecycleScope,
) -> Optional[tuple[str, Optional[str]]]:
    """Map the parsed flags to (scope, project_key), or None on conflict.

    ``--global`` selects global scope; a ``--project <key>`` selects project
    scope keyed by that FULL project key (the shell dispatcher resolves the
    token to a Claude record key before invoking). They are mutually exclusive.
    With neither, default to global scope (a bare 'enable foo' targets the
    global profile, matching how a global import lands).
    """
    if scope.is_global and scope.project_key:
        sys.stderr.write(
            "mcp.cli: --global and --project are mutually exclusive\n"
        )
        return None
    if scope.project_key:
        return ("project", scope.project_key)
    return ("global", None)


def _cmd_list(argv: list[str], as_json: bool) -> int:
    """`boxa mcp list` effective view. Scope flags reuse the shared parser."""
    scope = _parse_scope(argv)
    if scope is None:
        return 2
    try:
        result = effective_list(
            project_keys=scope.project_keys or None,
            all_projects=scope.all_projects,
        )
    except LifecycleError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        return _emit(result.to_dict())
    return _render_effective_table(result)


def _cmd_toggle(argv: list[str], enabled: bool, as_json: bool) -> int:
    """`boxa mcp enable|disable <name>` profile-state toggle."""
    scope = _parse_lifecycle_scope(argv)
    if scope is None:
        return 2
    if len(scope.positional) != 1:
        sys.stderr.write(
            "mcp.cli: enable/disable take exactly one server name\n"
        )
        return 2
    resolved = _resolve_lifecycle_scope(scope)
    if resolved is None:
        return 2
    scope_name, project_key = resolved
    name = scope.positional[0]
    try:
        result = set_enabled(name, scope_name, project_key, enabled)
    except LifecycleError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        return _emit(result.to_dict())
    return _render_toggle_text(result, enabled)


def _cmd_remove(argv: list[str], as_json: bool) -> int:
    """`boxa mcp remove <name>` profile-entry removal (purge opt-in)."""
    scope = _parse_lifecycle_scope(argv)
    if scope is None:
        return 2
    if len(scope.positional) != 1:
        sys.stderr.write("mcp.cli: remove takes exactly one server name\n")
        return 2
    resolved = _resolve_lifecycle_scope(scope)
    if resolved is None:
        return 2
    scope_name, project_key = resolved
    name = scope.positional[0]
    try:
        result = remove_server(name, scope_name, project_key, purge=scope.purge)
    except LifecycleError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        return _emit(result.to_dict())
    return _render_remove_text(result)


def _cmd_remove_secret_check(argv: list[str]) -> int:
    """Report whether a remove target has scoped secrets (one key NAME per line).

    Used by the shell dispatcher to decide whether to prompt for confirmation
    before a non-purge remove would orphan a secret block. SECRET-FREE: prints
    key NAMES only, never values. Output is empty when there are no secrets.
    """
    scope = _parse_lifecycle_scope(argv)
    if scope is None:
        return 2
    if len(scope.positional) != 1:
        sys.stderr.write("mcp.cli: remove-secret-check takes one server name\n")
        return 2
    resolved = _resolve_lifecycle_scope(scope)
    if resolved is None:
        return 2
    scope_name, project_key = resolved
    for key in server_has_secrets(scope.positional[0], scope_name, project_key):
        sys.stdout.write(key + "\n")
    return 0


def _cmd_doctor(argv: list[str], as_json: bool) -> int:
    """`boxa mcp doctor [--fix]` diagnostics."""
    do_fix = False
    rest: list[str] = []
    for arg in argv:
        if arg == "--fix":
            do_fix = True
        else:
            rest.append(arg)
    if rest:
        sys.stderr.write(
            f"mcp.cli: unexpected argument(s) for doctor: {' '.join(rest)}\n"
        )
        return 2
    report = run_doctor()
    if do_fix:
        fix = apply_doctor_fixes(report)
        if as_json:
            _emit(fix.to_dict())
            return 1 if any(f.severity == "error" for f in fix.remaining) else 0
        return _render_fix_text(fix)
    if as_json:
        _emit(report.to_dict())
        return 0 if report.ok else 1
    return _render_doctor_text(report)


def _render_install_text(result: InstallResult) -> int:
    """Human-readable install summary (SECRET-FREE).

    Reports the runtime family, the actions taken (commands run, profile
    rewrite), and the launcher the profile now records. Install never touches a
    secret value, so the only thing surfaced from a sub-command is its own
    (non-secret) package-manager output, already folded into the actions.
    """
    scope_label = result.scope
    if result.project_key:
        scope_label = f"{result.scope} ({result.project_key})"
    if result.already_materialized:
        sys.stdout.write(
            f"MCP server {result.name!r} ({scope_label}) needs no materialization "
            f"({result.runtime} runtime).\n"
        )
    else:
        sys.stdout.write(
            f"Materialized MCP server {result.name!r} ({scope_label}, "
            f"{result.runtime} runtime).\n"
        )
    for action in result.actions:
        sys.stdout.write(f"  - {action}\n")
    if result.installed_command:
        sys.stdout.write(f"  launch command: {result.installed_command}\n")
    sys.stdout.write("\nProfile updated.\n")
    sys.stdout.write("Next: boxa mcp migrate\n")
    return 0


def _cmd_install(argv: list[str], as_json: bool) -> int:
    """`boxa mcp install <server>` materialization core.

    Accepts ``[--global | --project <full-project-key>] [--exec-prefix <cmd>]
    <server>``. The CANONICAL PROFILE lives on the host and is read/rewritten
    here in process; the runtime install COMMANDS run wherever ``--exec-prefix``
    points. The host shell front-end passes ``--exec-prefix`` as a shell-quoted
    ``docker exec -u node <container>`` so ``npm install -g`` / ``docker pull``
    run inside the target Container while the profile update lands on the host
    (the host ``~/.config/boxa`` is NOT bind-mounted into Containers, so the
    profile cannot be updated from inside one). The Allow-for window
    orchestration and container targeting also live in the shell front-end.
    """
    import shlex

    exec_prefix: list[str] = []
    rest: list[str] = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--exec-prefix":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --exec-prefix requires a value\n")
                return 2
            exec_prefix = shlex.split(argv[i])
        elif arg.startswith("--exec-prefix="):
            exec_prefix = shlex.split(arg[len("--exec-prefix="):])
        else:
            rest.append(arg)
        i += 1

    scope = _parse_lifecycle_scope(rest)
    if scope is None:
        return 2
    if scope.purge:
        sys.stderr.write("mcp.cli: install does not accept --purge\n")
        return 2
    if len(scope.positional) != 1:
        sys.stderr.write("mcp.cli: install takes exactly one server name\n")
        return 2
    resolved = _resolve_lifecycle_scope(scope)
    if resolved is None:
        return 2
    scope_name, project_key = resolved
    name = scope.positional[0]
    from .install import Executor

    executor = Executor(exec_prefix) if exec_prefix else None
    try:
        result = install_server(name, scope_name, project_key, executor=executor)
    except BlockedNetworkError as exc:
        # Blocked-network failures get a distinct exit code (4) so the shell
        # front-end can tell "needs domains allowed / rerun" apart from a generic
        # failure and present the Allow-for / boxa blocked guidance.
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 4
    except UnsupportedRuntimeError as exc:
        # Not retryable (needs a runtime tool / dedicated volume). Exit code 5
        # distinguishes it from a transient failure.
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 5
    except InstallError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        return _emit(result.to_dict())
    return _render_install_text(result)


def _run_wrapper(argv: list[str]) -> int:
    """Parse the wrapper args and launch the named server (never returns on OK).

    Accepts ``[--project <full-project-key>] <server>``; the ``--project`` form
    matches what the render path emits for a Project-scoped entry. Container
    identity, resolution, env validation, and exec live in ``mcp.runner``;
    failures map to clear, SECRET-FREE stderr messages and a non-zero exit.
    """
    project_key: Optional[str] = None
    catalog_id: Optional[str] = None
    consumer: Optional[str] = None
    server: Optional[str] = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--project":
            i += 1
            if i >= len(argv):
                sys.stderr.write("boxa-mcp-run: --project requires a value\n")
                return 2
            project_key = argv[i]
        elif arg.startswith("--project="):
            project_key = arg[len("--project="):]
        elif arg == "--catalog-id":
            i += 1
            if i >= len(argv):
                sys.stderr.write("boxa-mcp-run: --catalog-id requires a value\n")
                return 2
            catalog_id = argv[i]
        elif arg == "--consumer":
            i += 1
            if i >= len(argv):
                sys.stderr.write("boxa-mcp-run: --consumer requires a value\n")
                return 2
            consumer = argv[i]
        elif arg.startswith("-"):
            sys.stderr.write(f"boxa-mcp-run: unknown flag {arg!r}\n")
            return 2
        elif server is None:
            server = arg
        else:
            sys.stderr.write(
                f"boxa-mcp-run: unexpected extra argument {arg!r}\n"
            )
            return 2
        i += 1

    if not server:
        sys.stderr.write(
            "boxa-mcp-run: missing server name\n"
            "Usage: boxa-mcp-run [--project <project-key>] <server>\n"
        )
        return 2

    try:
        if catalog_id is None and consumer is None:
            return runner_run(server, project_key)
        return runner_run(
            server, project_key, catalog_id=catalog_id, consumer=consumer
        )
    except NotInsideContainerError as exc:
        sys.stderr.write(f"boxa-mcp-run: {exc}\n")
        return 3
    except RunnerError as exc:
        sys.stderr.write(f"boxa-mcp-run: {exc}\n")
        return 1


def _resolve_owner(token: str) -> Optional[tuple[int, int]]:
    """Resolve an owner token (name or uid) to a (uid, gid) pair, or None.

    Accepts a user NAME (looked up via ``pwd``, taking its primary GID) or a
    numeric uid (its gid is taken from the passwd entry when present, else equal
    to the uid). Returns None and writes a SECRET-FREE error to stderr when the
    account does not exist, so a typo never silently leaves staged files
    root-owned (which node could not read either, but would defeat the broker).
    """
    import pwd

    try:
        entry = pwd.getpwnam(token)
        return (entry.pw_uid, entry.pw_gid)
    except KeyError:
        pass
    if token.isdigit():
        uid = int(token)
        try:
            entry = pwd.getpwuid(uid)
            return (uid, entry.pw_gid)
        except KeyError:
            return (uid, uid)
    sys.stderr.write(f"mcp.cli: stage-secrets: unknown owner {token!r}\n")
    return None


def _cmd_stage_secrets(argv: list[str], as_json: bool) -> int:
    """`stage-secrets`: root-side secret staging into the private store (issue 16).

    Args: ``--source <dir> --dest <dir> [--project <key>] [--owner <user|uid>]``.
    SECRET-FREE: reports scope labels + staged basenames + counts only, never an
    env-key NAME or a secret VALUE.
    """
    from .staging import stage_secrets

    source = ""
    dest = ""
    project_key: Optional[str] = None
    owner: Optional[str] = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--source":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: stage-secrets: --source requires a value\n")
                return 2
            source = argv[i]
        elif arg == "--dest":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: stage-secrets: --dest requires a value\n")
                return 2
            dest = argv[i]
        elif arg == "--project":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: stage-secrets: --project requires a value\n")
                return 2
            project_key = argv[i] or None
        elif arg == "--owner":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: stage-secrets: --owner requires a value\n")
                return 2
            owner = argv[i]
        else:
            sys.stderr.write(f"mcp.cli: stage-secrets: unknown argument {arg!r}\n")
            return 2
        i += 1

    if not source or not dest:
        sys.stderr.write(
            "mcp.cli: stage-secrets requires --source <dir> and --dest <dir>\n"
        )
        return 2

    owner_uid: Optional[int] = None
    owner_gid: Optional[int] = None
    if owner:
        resolved_owner = _resolve_owner(owner)
        if resolved_owner is None:
            return 2
        owner_uid, owner_gid = resolved_owner

    # A missing source root is not an error: a host without any imported MCP
    # secrets simply has nothing to stage (the broker then reports missing env
    # for a secret-declaring server). Stage nothing rather than fail container
    # start.
    if not os.path.isdir(source):
        sys.stdout.write(
            f"No MCP secret store at {source}; nothing to stage.\n"
        )
        return 0

    try:
        result = stage_secrets(
            source,
            dest,
            project_key=project_key,
            owner_uid=owner_uid,
            owner_gid=owner_gid,
        )
    except OSError as exc:
        # Names/paths only — staging never surfaces a secret value.
        sys.stderr.write(f"mcp.cli: stage-secrets: {exc}\n")
        return 1

    if as_json:
        return _emit(result.to_dict())

    if result.staged:
        for label, basename in result.staged:
            sys.stdout.write(f"Staged {label} secrets -> {basename}\n")
    else:
        sys.stdout.write("No in-scope MCP secret stores to stage.\n")
    if result.removed_stale:
        sys.stdout.write(
            f"Removed {len(result.removed_stale)} stale staged file(s).\n"
        )
    return 0


def _cmd_add(argv: list[str], as_json: bool) -> int:
    """`add-{json,text}`: record a new Boxa MCP server from a command spec.

    Args, in order: ``<scope-flag> <name> -- <command spec...>`` where the
    scope flag is ``--global`` or ``--project <abs-key>`` (the shell front-end
    has ALREADY resolved the scope to an explicit decision — this core never
    defaults a scope). The command spec after ``--`` is the literal launch
    command. The spec is parsed, classified, and written to the scope-correct
    profile + secret store. SECRET-FREE output (copied KEY NAMES only).
    """
    scope = ""
    project_key = ""
    name = ""
    spec: list[str] = []
    i = 0
    saw_dashdash = False
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            saw_dashdash = True
            spec = argv[i + 1:]
            break
        if arg == "--global":
            scope = "global"
        elif arg == "--project":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: add --project requires a value\n")
                return 2
            scope = "project"
            project_key = argv[i]
        elif arg.startswith("--project="):
            scope = "project"
            project_key = arg[len("--project="):]
        elif arg.startswith("-"):
            sys.stderr.write(f"mcp.cli: add: unknown flag {arg!r}\n")
            return 2
        elif not name:
            name = arg
        else:
            sys.stderr.write(
                f"mcp.cli: add takes one server name before '--' (got {arg!r})\n"
            )
            return 2
        i += 1

    if not name:
        sys.stderr.write("mcp.cli: add requires a server name\n")
        return 2
    if not scope:
        sys.stderr.write("mcp.cli: add requires a resolved scope (--global/--project)\n")
        return 2
    if not saw_dashdash or not spec:
        sys.stderr.write(
            "mcp.cli: add requires a command spec after '--'\n"
        )
        return 2

    try:
        override = ScopeOverride(scope=scope, project_key=project_key)
    except ValueError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 2

    try:
        result = add_server(name, spec, override)
    except AddError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 2

    # Issue 17: an add that copied an inline secret VALUE may need a
    # `boxa mcp reload` to reach a running Container; tell the host front-end
    # which scope (labels/keys only, never a secret value).
    if result.copied_secret_keys:
        _emit_secret_scopes([(result.scope, result.project_key)])

    if as_json:
        return _emit(result.to_dict())

    scope_label = result.scope
    if result.project_key:
        scope_label = f"{result.scope} ({result.project_key})"
    sys.stdout.write(f"Added {result.name}\n")
    sys.stdout.write(f"  scope    : {scope_label}\n")
    sys.stdout.write(f"  placement: {result.placement}\n")
    sys.stdout.write(f"  command  : {' '.join(result.argv)}\n")
    sys.stdout.write(f"  profile  : {result.profile_path}\n")
    if result.copied_secret_keys:
        sys.stdout.write(
            "  secrets  : stored "
            f"{', '.join(result.copied_secret_keys)} to {result.secrets_path} "
            "(values not shown)\n"
        )
    else:
        sys.stdout.write("  secrets  : none stored\n")
    sys.stdout.write("\nProfile updated.\n")
    sys.stdout.write("Next: boxa mcp migrate\n")
    return 0


def _catalog_payload() -> dict[str, object]:
    entries = catalog_entries_sorted()
    activations = load_activations()
    for entry in entries:
        entry["isolationStatus"] = isolation_status(entry)
        if entry.get("secretHeaderKeys"):
            stored = read_header_secrets(
                global_secrets_path(), str(entry["id"])
            ) or {}
            missing = any(
                not stored.get(str(name).casefold())
                for name in entry["secretHeaderKeys"]
            )
            if missing:
                entry["readiness"] = {"summary": "secret-value-missing"}
        projects = _entry_activations(activations, str(entry["id"]))
        entry["activationEverywhere"] = str(entry["id"]) in activations["everywhere"]
        entry["activationProjects"] = [row["projectKey"] for row in projects]
        entry["activationProjectCount"] = len(projects)
    return {"version": CATALOG_VERSION, "entries": entries}


def _render_catalog_text(
    entries: list[dict[str, object]], *, verbose: bool = False
) -> int:
    if not entries:
        sys.stdout.write("MCP catalog is empty. Catalog membership does not activate tools.\n")
        return 0
    headers = (
        "NAME", "ID", "MODE", "RUNTIME", "ACTIVATIONS", "ISOLATION", "READINESS"
    )
    rows = [
        (
            str(entry["name"]),
            str(entry["id"]),
            str(entry.get("executionMode", "none")),
            str(entry.get("runtimeKind", "remote-http")),
            (
                "everywhere"
                if entry["activationEverywhere"]
                else f"{entry['activationProjectCount']} projects"
                if entry["activationProjectCount"]
                else "-"
            ),
            isolation_status(entry),
            str(entry["readiness"]["summary"]),  # type: ignore[index]
        )
        for entry in entries
    ]
    widths = [len(value) for value in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))
    sys.stdout.write(
        "  ".join(value.ljust(widths[index]) for index, value in enumerate(headers))
        + "\n"
    )
    for row in rows:
        sys.stdout.write(
            "  ".join(value.ljust(widths[index]) for index, value in enumerate(row)).rstrip()
            + "\n"
        )
    if verbose:
        for entry in entries:
            projects = entry["activationProjects"]
            scope = "everywhere" if entry["activationEverywhere"] else "project-scoped"
            project_text = ", ".join(str(value) for value in projects) if projects else "-"
            sys.stdout.write(
                f"Activations for {entry['name']} ({scope}): {project_text}\n"
            )
    sys.stdout.write("Catalog membership does not activate or start an MCP server.\n")
    return 0


def _cmd_catalog(argv: list[str], as_json: bool) -> int:
    if any(arg != "--verbose" for arg in argv) or argv.count("--verbose") > 1:
        sys.stderr.write("mcp.cli: catalog takes only --verbose\n")
        return 2
    try:
        payload = _catalog_payload()
    except CatalogError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        return _emit(payload)
    return _render_catalog_text(  # type: ignore[arg-type]
        payload["entries"], verbose="--verbose" in argv
    )


def _cmd_catalog_picker(argv: list[str]) -> int:
    if argv:
        sys.stderr.write("mcp.cli: catalog-picker takes no arguments\n")
        return 2
    try:
        entries = catalog_entries_sorted()
    except CatalogError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    for entry in entries:
        sys.stdout.write(f"{entry['id']}\t{entry['name']}\n")
    return 0


def _cmd_catalog_update_picker(argv: list[str]) -> int:
    if argv:
        sys.stderr.write("mcp.cli: catalog-update-picker takes no arguments\n")
        return 2
    try:
        entries = catalog_entries_sorted()
    except CatalogError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    for entry in entries:
        sys.stdout.write(
            f"{entry['id']}\t{entry['name']}\t{entry.get('type', 'stdio')}\n"
        )
    return 0


def _missing_secrets(
    project_key: str, token: Optional[str] = None
) -> list[tuple[dict, str, str]]:
    entries = catalog_entries_sorted()
    if token is not None:
        _entry_id, selected = catalog_resolve(catalog_load(), token)
        entries = [selected]
    missing: list[tuple[dict, str, str]] = []
    for entry in entries:
        if entry.get("type") == "http":
            stored = read_header_secrets(
                global_secrets_path(), str(entry["id"])
            ) or {}
            present = {
                str(name).casefold() for name, value in stored.items() if value
            }
            for header in entry.get("secretHeaderKeys", []):
                if str(header).casefold() not in present:
                    missing.append((entry, "header", str(header)))
            continue
        stored_env = read_server_secrets(
            project_secrets_path(project_key),
            str(entry.get("secretStoreKey") or entry["name"]),
        ) or {}
        for key in entry.get("secretEnvKeys", []):
            if not stored_env.get(str(key)):
                missing.append((entry, "environment", str(key)))
    return missing


def _cmd_secret_missing_entry_picker(argv: list[str]) -> int:
    if argv:
        sys.stderr.write(
            "mcp.cli: secret-missing-entry-picker takes no arguments\n"
        )
        return 2
    try:
        rows = _missing_secrets(os.path.realpath(os.getcwd()))
    except (CatalogError, OSError, ValueError) as exc:
        sys.stderr.write(f"mcp.cli: cannot list missing secrets: {exc}\n")
        return 1
    seen: set[str] = set()
    for entry, kind, _key in rows:
        entry_id = str(entry["id"])
        if entry_id not in seen:
            sys.stdout.write(f"{entry_id}\t{entry['name']}\t{kind}\n")
            seen.add(entry_id)
    return 0


def _cmd_secret_missing_key_picker(argv: list[str]) -> int:
    if len(argv) != 1:
        sys.stderr.write(
            "mcp.cli: secret-missing-key-picker requires one catalog entry\n"
        )
        return 2
    try:
        rows = _missing_secrets(os.path.realpath(os.getcwd()), argv[0])
    except (CatalogError, OSError, ValueError) as exc:
        sys.stderr.write(f"mcp.cli: cannot list missing secrets: {exc}\n")
        return 1
    for _entry, kind, key in rows:
        sys.stdout.write(f"{key}\t{kind}\n")
    return 0


def _cmd_catalog_resolve(argv: list[str]) -> int:
    if len(argv) != 1:
        return 2
    try:
        entry_id, entry = catalog_resolve(catalog_load(), argv[0])
    except CatalogError:
        return 1
    return _emit({"id": entry_id, "name": entry["name"]})


def _cmd_catalog_mode_preview(argv: list[str], as_json: bool) -> int:
    if len(argv) != 2:
        sys.stderr.write("mcp.cli: mode requires <entry> <execution-mode>\n")
        return 2
    try:
        preview = catalog_mode_preview(argv[0], argv[1])
    except CatalogError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 2
    if as_json:
        return _emit({"version": CATALOG_VERSION, "preview": preview})
    sys.stdout.write("MCP execution mode change preview:\n")
    sys.stdout.write(f"  name       : {preview['name']}\n")
    sys.stdout.write(f"  stable id  : {preview['id']}\n")
    sys.stdout.write(f"  current    : {preview['currentMode']}\n")
    sys.stdout.write(f"  requested  : {preview['requestedMode']}\n")
    sys.stdout.write(
        "  command    : " + " ".join(str(v) for v in preview["command"]) + "\n"
    )
    sys.stdout.write(f"  runtime    : {preview['runtimeKind']}\n")
    if preview.get("image"):
        sys.stdout.write(f"  image      : {preview['image']}\n")
    sys.stdout.write("  access boundary:\n")
    for item in preview["access"]:
        sys.stdout.write(f"    - {item}\n")
    return 0


def _cmd_catalog_mode_apply(argv: list[str], as_json: bool) -> int:
    if len(argv) != 3 or argv[2] != "--yes":
        sys.stderr.write(
            "mcp.cli: mode apply requires <entry> <execution-mode> --yes\n"
        )
        return 2
    try:
        preview = catalog_mode_preview(argv[0], argv[1])
        entry = catalog_set_execution_mode(argv[0], argv[1])
    except (CatalogError, ActivationError, ValueError) as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 2
    if as_json:
        return _emit(
            {"version": CATALOG_VERSION, "preview": preview, "entry": entry}
        )
    sys.stdout.write(
        f"MCP catalog entry {entry['name']!r} now uses "
        f"{entry['executionMode']} ({entry['id']}).\n"
    )
    return 0


def _parse_catalog_mutation(argv: list[str], command: str) -> Optional[tuple[str, list[str]]]:
    if not argv:
        sys.stderr.write(f"mcp.cli: {command} requires an entry name or id\n")
        return None
    if "--" in argv:
        marker = argv.index("--")
        before, spec = argv[:marker], argv[marker + 1:]
    else:
        before, spec = argv, []
    if len(before) != 1:
        sys.stderr.write(f"mcp.cli: {command} takes exactly one entry name or id\n")
        return None
    return before[0], spec


def _parse_header_assignment(value: str) -> tuple[str, str]:
    if "=" in value:
        name, header_value = value.split("=", 1)
    elif ":" in value:
        name, header_value = value.split(":", 1)
        header_value = header_value.lstrip(" ")
    else:
        raise CatalogError(
            "--header requires NAME=VALUE or 'NAME: VALUE'"
        )
    return name, header_value


def _cmd_catalog_add(argv: list[str], as_json: bool) -> int:
    if not argv:
        sys.stderr.write("mcp.cli: catalog add requires an entry name\n")
        return 2
    name = argv[0]
    rest = argv[1:]
    url: Optional[str] = None
    headers: dict[str, str] = {}
    secret_header_keys: list[str] = []
    if "--" in rest:
        marker = rest.index("--")
        options, spec = rest[:marker], rest[marker + 1:]
    else:
        options, spec = rest, []
    i = 0
    try:
        while i < len(options):
            option = options[i]
            if option not in {"--url", "--header", "--secret-header-key"} or i + 1 >= len(options):
                raise CatalogError(
                    "catalog add accepts --url <http(s)-url>, --header "
                    "<name=value>, and --secret-header-key <name>"
                )
            value = options[i + 1]
            if option == "--url":
                if url is not None:
                    raise CatalogError("catalog add accepts --url only once")
                url = value
            elif option == "--header":
                header_name, header_value = _parse_header_assignment(value)
                headers[header_name] = header_value
            else:
                secret_header_keys.append(value)
            i += 2
    except CatalogError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 2
    if spec and options:
        sys.stderr.write(
            "mcp.cli: command catalog entries do not accept remote header options\n"
        )
        return 2
    if (url is None and not spec) or (url is not None and spec):
        sys.stderr.write(
            "mcp.cli: catalog add requires either --url <http(s)-url> "
            "or a command spec after '--'\n"
        )
        return 2
    try:
        entry = (
            catalog_add_remote_entry(
                name,
                url,
                headers=headers,
                secret_header_keys=secret_header_keys,
            )
            if url is not None
            else catalog_add_entry(name, spec)
        )
    except CatalogError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 2
    if as_json:
        return _emit({"version": CATALOG_VERSION, "entry": entry})
    sys.stdout.write(f"Added MCP catalog entry {entry['name']!r}.\n")
    sys.stdout.write(f"  id       : {entry['id']}\n")
    if entry["type"] == "http":
        sys.stdout.write(f"  url      : {entry['url']}\n")
        sys.stdout.write("  readiness: no runtime readiness\n")
        sys.stdout.write(
            "Next: boxa mcp activate "
            f"{shlex.quote(str(entry['name']))} --project <path> "
            "--for claude|codex\n"
        )
    else:
        sys.stdout.write(f"  mode     : {entry['executionMode']}\n")
        sys.stdout.write(f"  runtime  : {entry['runtimeKind']}\n")
        sys.stdout.write(
            "Next: boxa mcp install "
            f"{shlex.quote(str(entry['name']))} --project <path>\n"
        )
    sys.stdout.write("Catalog membership does not activate or start the server.\n")
    return 0


def _cmd_catalog_remove(argv: list[str], as_json: bool) -> int:
    parsed = _parse_catalog_mutation(argv, "catalog remove")
    if parsed is None:
        return 2
    token, spec = parsed
    if spec:
        sys.stderr.write("mcp.cli: catalog remove does not accept a command spec\n")
        return 2
    try:
        result = remove_catalog_entry(token)
    except (CatalogError, ActivationError) as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 2
    if as_json:
        payload = result.to_dict()
        payload["version"] = CATALOG_VERSION
        payload["reloadRequired"] = bool(result.affected)
        return _emit(payload)
    sys.stdout.write(
        f"Removed MCP catalog entry {result.entry['name']!r} ({result.entry['id']}); "
        "its stable identity is destroyed.\n"
    )
    for affected in result.affected:
        consumers = ", ".join(affected["consumers"])
        sys.stdout.write(
            f"  removed activation: {affected['projectKey']} ({consumers})\n"
        )
    if result.affected:
        sys.stdout.write(
            "The launch-time profile was updated. New launches are blocked; "
            "already-connected servers were not terminated. Reload/restart the "
            "named agents to drop live connections.\n"
        )
    sys.stdout.write("Inherited/manual agent MCP entries were not touched.\n")
    return 0


def _cmd_catalog_update(argv: list[str], as_json: bool) -> int:
    if not argv:
        sys.stderr.write("mcp.cli: catalog update requires an entry name or id\n")
        return 2
    token = argv[0]
    rest = argv[1:]
    if "--" in rest:
        marker = rest.index("--")
        options, spec = rest[:marker], rest[marker + 1:]
    else:
        options, spec = rest, []
    changes: dict[str, object] = {}
    headers: Optional[dict[str, str]] = None
    secret_header_keys: Optional[list[str]] = None
    i = 0
    while i < len(options):
        option = options[i]
        if option in {"--clear-headers", "--clear-secret-header-keys"}:
            if option == "--clear-headers":
                headers = {}
            else:
                secret_header_keys = []
            i += 1
            continue
        if option not in {
            "--name", "--description", "--url", "--header",
            "--secret-header-key",
        } or i + 1 >= len(options):
            sys.stderr.write(
                "mcp.cli: catalog update accepts --name <name>, "
                "--description <text>, --url <http(s)-url>, --header "
                "<name=value>, --secret-header-key <name>, clear-header "
                "flags, and an optional command spec after '--'\n"
            )
            return 2
        value = options[i + 1]
        if option == "--header":
            if headers is None:
                headers = {}
            try:
                header_name, header_value = _parse_header_assignment(value)
            except CatalogError as exc:
                sys.stderr.write(f"mcp.cli: {exc}\n")
                return 2
            headers[header_name] = header_value
        elif option == "--secret-header-key":
            if secret_header_keys is None:
                secret_header_keys = []
            secret_header_keys.append(value)
        else:
            changes[option[2:]] = value
        i += 2
    if headers is not None:
        changes["headers"] = headers
    if secret_header_keys is not None:
        changes["secretHeaderKeys"] = secret_header_keys
    try:
        _entry_id, current = catalog_resolve(catalog_load(), token)
        if spec:
            changes.update(
                definition_changes_from_spec(
                    str(changes.get("name", current["name"])), spec
                )
            )
        if not changes:
            raise CatalogError("catalog update requires at least one change")
        result = update_catalog_entry(
            token,
            changes,
        )
    except (CatalogError, ActivationError) as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        payload = result.to_dict()
        payload["version"] = CATALOG_VERSION
        payload["reloadRequired"] = bool(result.affected)
        payload["liveConnectionsTerminated"] = False
        return _emit(payload)
    kind = "runtime-affecting" if result.runtime_affecting else "cosmetic"
    previous_secret_headers = {
        str(header).casefold() for header in current.get("secretHeaderKeys", [])
    }
    new_secret_headers = [
        str(header)
        for header in result.entry.get("secretHeaderKeys", [])
        if str(header).casefold() not in previous_secret_headers
    ]
    sys.stdout.write(
        f"Updated MCP catalog entry {result.entry['name']!r} "
        f"({result.entry['id']}); {kind} update.\n"
    )
    for affected in result.affected:
        sys.stdout.write(
            f"  affected: {affected['projectKey']} "
            f"({', '.join(affected['consumers'])})\n"
        )
    for header in new_secret_headers:
        sys.stdout.write(
            "Next: boxa mcp secret set "
            f"{shlex.quote(str(result.entry['name']))} "
            f"{shlex.quote(header)}\n"
        )
    if new_secret_headers and not result.affected:
        sys.stdout.write("Then: boxa mcp reload\n")
    if result.affected:
        sys.stdout.write(
            "The runtime snapshot was switched transactionally. "
            "Already-connected servers were not terminated; reload/restart the "
            "named agents to use the updated definition.\n"
        )
    return 0


def _parse_activation(
    argv: list[str], command: str
) -> Optional[tuple[str, str, list[str], bool]]:
    token: Optional[str] = None
    project: Optional[str] = None
    consumers: list[str] = []
    accept_degraded = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--project":
            i += 1
            if i >= len(argv):
                sys.stderr.write(f"mcp.cli: {command} --project requires a value\n")
                return None
            project = argv[i]
        elif arg == "--for":
            i += 1
            if i >= len(argv):
                sys.stderr.write(f"mcp.cli: {command} --for requires a consumer\n")
                return None
            consumers.extend(value for value in argv[i].split(",") if value)
        elif arg == "--accept-degraded-secret-isolation":
            accept_degraded = True
        elif arg.startswith("-"):
            sys.stderr.write(f"mcp.cli: unknown {command} argument {arg!r}\n")
            return None
        elif token is None:
            token = arg
        else:
            sys.stderr.write(f"mcp.cli: {command} takes exactly one entry name or id\n")
            return None
        i += 1
    if not token or not project:
        sys.stderr.write(f"mcp.cli: {command} requires <entry> --project <absolute-path>\n")
        return None
    return token, project, consumers, accept_degraded


def _cmd_activate(argv: list[str], as_json: bool) -> int:
    token: Optional[str] = None
    projects: list[str] = []
    consumers: list[str] = []
    accept_degraded = False
    everywhere = False
    no_everywhere = False
    yes = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--project":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: activate --project requires a value\n")
                return 2
            projects.append(argv[i])
        elif arg == "--for":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: activate --for requires a consumer\n")
                return 2
            consumers.extend(value for value in argv[i].split(",") if value)
        elif arg == "--accept-degraded-secret-isolation":
            accept_degraded = True
        elif arg == "--everywhere":
            everywhere = True
        elif arg == "--no-everywhere":
            no_everywhere = True
        elif arg == "--yes":
            yes = True
        elif arg.startswith("-"):
            sys.stderr.write(f"mcp.cli: unknown activate argument {arg!r}\n")
            return 2
        elif token is None:
            token = arg
        else:
            sys.stderr.write("mcp.cli: activate takes exactly one entry name or id\n")
            return 2
        i += 1
    if not token:
        sys.stderr.write("mcp.cli: activate requires <entry>\n")
        return 2
    if everywhere and no_everywhere:
        sys.stderr.write("mcp.cli: activate accepts only one of --everywhere and --no-everywhere\n")
        return 2
    if (everywhere or no_everywhere) and projects:
        sys.stderr.write("mcp.cli: --everywhere/--no-everywhere cannot be combined with --project\n")
        return 2
    if not everywhere and not no_everywhere and not projects:
        sys.stderr.write("mcp.cli: activate requires --project <absolute-path> or --everywhere\n")
        return 2
    if no_everywhere and (consumers or accept_degraded or yes):
        sys.stderr.write("mcp.cli: --no-everywhere accepts no activation or acknowledgement flags\n")
        return 2
    if not no_everywhere and not consumers:
        sys.stderr.write("mcp.cli: non-interactive activation requires --for claude, codex, or both\n")
        return 2
    try:
        if no_everywhere:
            result = clear_everywhere(token)
        elif everywhere:
            result = activate_everywhere(
                token,
                consumers,
                ClaudeProvider(),
                VolumeProbe(),
                accept_degraded_secret_isolation=accept_degraded,
                accept_agent_trust_everywhere=yes,
            )
        else:
            if yes:
                sys.stderr.write("mcp.cli: per-Project activation does not accept --yes\n")
                return 2
            for project in projects:
                try:
                    preflight_catalog(
                        token,
                        project,
                        consumers,
                        accept_degraded_secret_isolation=accept_degraded,
                    )
                except (ActivationError, CatalogError) as exc:
                    sys.stderr.write(
                        f"mcp.cli: activation preflight failed for Project "
                        f"{project}: {exc}\n"
                    )
                    return 1
            results = []
            for project in projects:
                try:
                    result = activate_catalog(
                        token,
                        project,
                        consumers,
                        accept_degraded_secret_isolation=accept_degraded,
                    )
                except Exception as exc:
                    if as_json:
                        _emit({
                            "results": [item.to_dict() for item in results],
                            "failed": {"projectKey": project, "error": str(exc)},
                        })
                        return 1
                    for completed in results:
                        outcome = "pending" if completed.pending else "activated"
                        sys.stdout.write(
                            f"{outcome:<10} {completed.project_key}\n"
                        )
                    sys.stderr.write(f"failed     {project}: {exc}\n")
                    return 1
                results.append(result)
    except (ActivationError, CatalogError) as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if not no_everywhere and not everywhere:
        if as_json:
            if len(results) == 1:
                return _emit(results[0].to_dict())
            return _emit({"results": [item.to_dict() for item in results]})
        for result in results:
            if result.pending:
                sys.stdout.write(
                    f"Pending MCP catalog activation {result.entry['name']!r} for "
                    f"{', '.join(result.consumers)} in Project {result.project_key}.\n"
                )
                sys.stdout.write(
                    "Readiness will be re-evaluated at the next Container start: "
                    f"{result.pending_reason}.\n"
                )
                sys.stdout.write(
                    "Next: boxa mcp readiness "
                    f"{shlex.quote(str(result.entry['name']))} "
                    f"--project {shlex.quote(result.project_key)}\n"
                )
            else:
                sys.stdout.write(
                    f"Activated MCP catalog entry {result.entry['name']!r} for "
                    f"{', '.join(result.consumers)} in Project {result.project_key}.\n"
                )
                sys.stdout.write(
                    "The launch-time MCP profile is ready; start a new agent "
                    "session to connect.\n"
                )
        return 0
    if as_json:
        return _emit(result.to_dict())
    if no_everywhere:
        state = "Cleared" if result.changed else "Already clear"
        sys.stdout.write(
            f"{state}: MCP catalog entry {result.entry['name']!r} is not marked everywhere.\n"
        )
        sys.stdout.write(
            "Existing per-Project activations and sticky opt-outs are unchanged.\n"
        )
        return 0
    if everywhere:
        sys.stdout.write(
            f"Marked MCP catalog entry {result.entry['name']!r} everywhere for "
            f"{', '.join(result.consumers)}; future Projects inherit it at "
            "their first Container start.\n"
        )
        if result.entry.get("executionMode") == "agent-trusted":
            sys.stdout.write(
                "WARNING: agent-identity trust now extends to every present "
                "and future Project.\n"
            )
        for outcome in result.projects:
            detail = f": {outcome.reason}" if outcome.reason else ""
            sys.stdout.write(
                f"  {outcome.outcome:10} {outcome.project_key}{detail}\n"
            )
        return 0
    return 0


def _cmd_activation_agent_trusted(argv: list[str]) -> int:
    if len(argv) != 1:
        sys.stderr.write("mcp.cli: activation-agent-trusted requires one entry\n")
        return 2
    try:
        _entry_id, entry = catalog_resolve(catalog_load(), argv[0])
    except CatalogError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    sys.stdout.write(
        "true\n" if entry.get("executionMode") == "agent-trusted" else "false\n"
    )
    return 0


def _cmd_reevaluate_pending(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] != "--project":
        sys.stderr.write(
            "mcp.cli: reevaluate-pending requires --project <absolute-path>\n"
        )
        return 2
    try:
        result = reevaluate_pending(argv[1])
    except (ActivationError, CatalogError, OSError, ValueError) as exc:
        sys.stderr.write(f"mcp.cli: pending activation re-evaluation failed: {exc}\n")
        return 1
    for attempt in result.attempts:
        if attempt.ready:
            sys.stdout.write(
                f"Activated pending MCP catalog entry {attempt.entry['name']!r}; "
                "new agent sessions can connect.\n"
            )
        else:
            sys.stderr.write(
                f"boxa: WARNING: MCP catalog entry {attempt.entry['name']!r} "
                f"remains pending: {attempt.reason}.\n"
            )
    return 0


def _cmd_activation_degradation(argv: list[str], as_json: bool) -> int:
    parsed = _parse_activation(argv, "activation-degradation")
    if parsed is None:
        return 2
    token, _project, consumers, accept_degraded = parsed
    if consumers or accept_degraded:
        sys.stderr.write("mcp.cli: activation-degradation accepts only entry and Project\n")
        return 2
    try:
        _entry_id, entry = catalog_resolve(catalog_load(), token)
    except CatalogError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    status = isolation_status(entry)
    if as_json:
        return _emit({"isolationStatus": status})
    sys.stdout.write(status + "\n")
    return 0


def _cmd_readiness(argv: list[str], as_json: bool) -> int:
    parsed = _parse_activation(argv, "readiness")
    if parsed is None:
        return 2
    token, project, consumers, accept_degraded = parsed
    if consumers or accept_degraded:
        sys.stderr.write("mcp.cli: readiness does not accept activation flags\n")
        return 2
    try:
        report = catalog_readiness(token, os.path.realpath(project))
    except ReadinessError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        _emit(report.to_dict())
    else:
        if not report.ready:
            sys.stdout.write(
                f"MCP catalog entry {report.entry['name']!r} is not ready for "
                f"Project {report.project_key}.\n"
            )
        elif not report.has_runtime_readiness:
            sys.stdout.write(
                f"MCP catalog entry {report.entry['name']!r} has no runtime "
                f"readiness for Project {report.project_key}.\n"
            )
        else:
            state = "ready" if report.ready else "not ready"
            sys.stdout.write(
                f"MCP catalog entry {report.entry['name']!r} is {state} for "
                f"Project {report.project_key}.\n"
            )
        for check in report.checks:
            marker = "ok" if check.ready else "missing"
            detail = (
                f" ({check.detail})"
                if not check.ready and check.kind == "secret-header"
                else ""
            )
            sys.stdout.write(
                f"  {marker:7} {check.kind}: {check.label}{detail}\n"
            )
        for hint in report.hints:
            sys.stdout.write(f"  hint   : {hint}\n")
    return 0 if report.ready else 1


def _cmd_secret_set(argv: list[str], as_json: bool) -> int:
    """Store one declared secret value read exclusively from stdin."""
    if len(argv) != 2:
        sys.stderr.write(
            "mcp.cli: secret set requires one catalog entry and header name\n"
        )
        return 2
    token, requested_header = argv
    value = sys.stdin.readline()
    if value.endswith("\n"):
        value = value[:-1]
    if not value or any(char in value for char in ("\r", "\n", "\x00")):
        sys.stderr.write("mcp.cli: secret header value must be one non-empty line\n")
        return 2
    try:
        with catalog_mutation_lock():
            _entry_id, entry = catalog_resolve(catalog_load(), token)
            if as_json and entry.get("type") != "http":
                raise CatalogError("secret headers apply only to http catalog entries")
            declared_headers = {
                str(name).casefold(): str(name)
                for name in entry.get("secretHeaderKeys", [])
            }
            header_name = declared_headers.get(requested_header.casefold())
            declared_env = {
                str(name): str(name) for name in entry.get("secretEnvKeys", [])
            }
            env_name = declared_env.get(requested_header)
            if header_name is not None and entry.get("type") == "http":
                store_header_secret(
                    global_secrets_path(), str(entry["id"]), header_name, value
                )
                kind = "header"
                stored_name = header_name
                secret_scopes = [("global", "")]
            elif env_name is not None and entry.get("type") != "http":
                project_key = os.path.realpath(os.getcwd())
                store_server_secret(
                    project_secrets_path(project_key),
                    str(entry.get("secretStoreKey") or entry["name"]),
                    env_name,
                    value,
                )
                kind = "environment"
                stored_name = env_name
                secret_scopes = [("project", project_key)]
            else:
                if entry.get("type") == "http":
                    raise CatalogError(
                        f"header {requested_header!r} is not declared in "
                        "secretHeaderKeys"
                    )
                raise CatalogError(
                    f"secret key {requested_header!r} is not declared on this entry"
                )
    except (CatalogError, OSError, ValueError) as exc:
        sys.stderr.write(f"mcp.cli: cannot store secret header value: {exc}\n")
        return 1
    _emit_secret_scopes(secret_scopes)
    if as_json:
        if kind == "header":
            return _emit({
                "entry": {"id": entry["id"], "name": entry["name"]},
                "header": stored_name,
                "stored": True,
            })
        return _emit({
            "entry": {"id": entry["id"], "name": entry["name"]},
            "environment": stored_name,
            "stored": True,
        })
    noun = "header" if kind == "header" else "environment variable"
    sys.stdout.write(
        f"Stored secret value for {noun} {stored_name!r} on MCP catalog "
        f"entry {entry['name']!r}.\n"
    )
    return 0


def _cmd_guided_secret_header(argv: list[str]) -> int:
    """Declare and store one HTTP secret header as one compensated mutation."""
    if len(argv) != 2:
        sys.stderr.write(
            "mcp.cli: guided secret header requires one catalog entry and "
            "header name\n"
        )
        return 2
    token, requested_header = argv
    value = sys.stdin.readline()
    if value.endswith("\n"):
        value = value[:-1]
    if not value or any(char in value for char in ("\r", "\n", "\x00")):
        sys.stderr.write("mcp.cli: secret header value must be one non-empty line\n")
        return 2
    try:
        with catalog_mutation_lock(), casfile.transaction() as txn:
            try:
                entry_id, current = catalog_resolve(catalog_load(), token)
                if current.get("type") != "http":
                    raise CatalogError(
                        "secret headers apply only to http catalog entries"
                    )
                declared = list(current.get("secretHeaderKeys", []))
                if requested_header.casefold() not in {
                    str(name).casefold() for name in declared
                }:
                    declared.append(requested_header)
                store_header_secret(
                    global_secrets_path(), entry_id, requested_header, value
                )
                if declared != current.get("secretHeaderKeys", []):
                    updated = update_catalog_entry(
                        entry_id, {"secretHeaderKeys": declared}
                    ).entry
                else:
                    updated = current
            except Exception:
                txn.rollback()
                raise
    except (CatalogError, ActivationError, OSError, ValueError) as exc:
        sys.stderr.write(f"mcp.cli: cannot add secret header: {exc}\n")
        return 1
    _emit_secret_scopes([("global", "")])
    sys.stdout.write(
        f"Stored secret header {requested_header!r} for "
        f"MCP catalog entry {updated['name']!r}.\n"
    )
    return 0


def _cmd_catalog_install(argv: list[str], as_json: bool) -> int:
    parsed = _parse_activation(argv, "install")
    if parsed is None:
        return 2
    token, project, consumers, accept_degraded = parsed
    if consumers or accept_degraded:
        sys.stderr.write("mcp.cli: install does not accept activation flags\n")
        return 2
    try:
        report = install_catalog_entry(token, os.path.realpath(project))
    except ReadinessError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        return _emit(report.to_dict())
    sys.stdout.write(
        f"Prepared MCP catalog entry {report.entry['name']!r} for "
        f"Project {report.project_key}.\n"
    )
    for action in report.actions:
        sys.stdout.write(f"  {action}\n")
    state = "ready" if report.readiness.ready else "not ready"
    sys.stdout.write(f"Readiness after install: {state}. No activation or agent config changed.\n")
    for check in report.readiness.missing:
        sys.stdout.write(f"  missing {check.kind}: {check.label}\n")
    if report.readiness.ready:
        sys.stdout.write(
            "Next: boxa mcp activate "
            f"{shlex.quote(str(report.entry['name']))} "
            f"--project {shlex.quote(report.project_key)} --for claude|codex\n"
        )
    else:
        sys.stdout.write(
            "Next: boxa mcp readiness "
            f"{shlex.quote(str(report.entry['name']))} "
            f"--project {shlex.quote(report.project_key)}\n"
        )
    return 0 if report.readiness.ready else 1


def _cmd_deactivate(argv: list[str], as_json: bool) -> int:
    parsed = _parse_activation(argv, "deactivate")
    if parsed is None:
        return 2
    token, project, consumers, accept_degraded = parsed
    if accept_degraded:
        sys.stderr.write("mcp.cli: deactivate does not accept degradation acknowledgement\n")
        return 2
    if consumers:
        sys.stderr.write("mcp.cli: deactivate does not accept --for; it removes the activation\n")
        return 2
    try:
        result = deactivate_catalog(token, project)
    except (ActivationError, CatalogError) as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        payload = result.to_dict()
        payload["reloadRequired"] = bool(result.consumers)
        payload["liveConnectionsTerminated"] = False
        return _emit(payload)
    sys.stdout.write(
        f"Deactivated MCP catalog entry {result.entry['name']!r} in Project {result.project_key}.\n"
    )
    sys.stdout.write(
        "The launch-time profile was updated. New launches are blocked; an already-connected "
        "server was not terminated. Reload/restart affected agents"
        + (f" ({', '.join(result.consumers)})" if result.consumers else "")
        + " to drop that live connection.\n"
    )
    return 0


def _cmd_catalog_effective_list(argv: list[str], as_json: bool) -> int:
    if len(argv) != 2 or argv[0] != "--project":
        sys.stderr.write("mcp.cli: catalog effective list requires --project <absolute-path>\n")
        return 2
    try:
        status = catalog_project_status(argv[1])
        entries = status["entries"]
        legacy = effective_list(project_keys=[os.path.realpath(argv[1])])
    except (ActivationError, CatalogError, LifecycleError) as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        return _emit({
            "projectKey": status["projectKey"],
            "catalogEntries": entries,
            "everywhereOptOuts": status["everywhereOptOuts"],
            "inheritedCandidates": status["inheritedCandidates"],
            "importProposalCount": status["importProposalCount"],
            "importNudge": status["importNudge"],
            "legacyProfile": legacy.to_dict(),
        })
    if not entries:
        sys.stdout.write("No MCP catalog entries are available; this Project has no activations.\n")
    else:
        headers = (
            "NAME",
            "CATALOG",
            "READINESS",
            "ACTIVATION",
            "EVERYWHERE",
            "PROJECTS",
            "CONSUMERS",
            "MODE / USER",
            "TRUST SCOPE",
            "ISOLATION",
        )
        rows = [
            (
                e["name"],
                "member",
                e["readiness"]["state"],
                e["activation"],
                "yes" if e["everywhere"] else "no",
                "everywhere" if e["everywhere"] else str(e["activationProjectCount"]),
                ",".join(e["consumers"] or e["everywhereConsumers"]) or "-",
                f"{e['executionMode']} / {e['executionUser']}",
                e["agentIdentityTrustScope"],
                e["isolationStatus"],
            )
            for e in entries
        ]
        widths = [max(len(headers[i]), *(len(str(row[i])) for row in rows)) for i in range(len(headers))]
        sys.stdout.write("  ".join(headers[i].ljust(widths[i]) for i in range(len(headers))) + "\n")
        for row in rows:
            sys.stdout.write("  ".join(str(row[i]).ljust(widths[i]) for i in range(len(headers))).rstrip() + "\n")
        for entry in entries:
            for check in entry["readiness"].get("checks", []):
                if check.get("kind") == "secret-header" and not check.get("ready"):
                    sys.stdout.write(
                        f"Reason for {entry['name']}: secret value missing for "
                        f"header {check['label']}.\n"
                    )
            for hint in entry["readiness"].get("hints", []):
                sys.stdout.write(f"Hint for {entry['name']}: {hint}\n")
            if entry["activation"] == "pending":
                reason = entry.get("pendingReason") or entry["readiness"].get(
                    "message", "readiness has not passed"
                )
                sys.stdout.write(f"Pending {entry['name']}: {reason}\n")
            if (
                entry["everywhere"]
                and entry["executionMode"] == "agent-trusted"
            ):
                sys.stdout.write(
                    f"WARNING: {entry['name']} extends agent-identity trust to "
                    "every present and future Project.\n"
                )
    if legacy.entries:
        sys.stdout.write(
            "\nLegacy MCP profile entries (superseded by the catalog; "
            "run 'boxa mcp migrate'):\n"
        )
        _render_effective_table(legacy)
    if status["importNudge"]:
        sys.stdout.write(f"\n{status['importNudge']}\n")
    for candidate in status["inheritedCandidates"]:
        if candidate["catalogStatus"] == "already-cataloged":
            sys.stdout.write(
                f"Inherited {candidate['name']}: already in catalog as "
                f"{candidate['catalogName']} ({candidate['catalogId']}).\n"
            )
    return 0


def _render_reload_text(result) -> int:
    """Human-readable `boxa mcp reload` summary (SECRET-FREE).

    Reports which running Containers were re-staged for the resolved scope, and
    names a requested Project Container that was not running (a no-op: the
    changed secret stages at its next start). Exit code is 1 when any re-stage
    failed, so a scripted reload sees the failure.
    """
    if not result.reloaded and not result.not_running:
        sys.stdout.write(
            "No running boxa Container in scope; nothing to reload. "
            "Changed secrets will be staged at the next Container start.\n"
        )
        return 0
    for c in result.reloaded:
        if c.ok:
            sys.stdout.write(
                f"Re-staged MCP secrets into running Container {c.container!r} "
                f"({result.scope_label} scope).\n"
            )
        else:
            sys.stdout.write(
                f"Failed to re-stage MCP secrets into {c.container!r}: "
                f"{c.output or 'unknown error'}\n"
            )
    for name in result.not_running:
        sys.stdout.write(
            f"Container {name!r} is not running; nothing to reload "
            "(secrets stage at its next start).\n"
        )
    if result.reloaded:
        sys.stdout.write(
            "\nThe broker re-reads staged secrets per spawn, so the NEXT MCP "
            "server session in each Container uses the new value. A server "
            "already running keeps its environment (same limit as a restart).\n"
        )
    return 1 if result.any_failed else 0


def _cmd_reload(argv: list[str], as_json: bool) -> int:
    """`boxa mcp reload`: re-stage secrets into running in-scope Container(s).

    Args: ``--scope <global|project> [--container <name>] [--project-label <l>]
    [--docker-bin <path>]``. The host shell front-end resolves the scope and (for
    a Project) the target Container name + display label before invoking; this
    core owns only the targeting + the momentary ``docker exec -u 0`` of the
    reusable staging step (``mcp.reload``). SECRET-FREE: container names + scope
    labels only.
    """
    from .reload import DockerExec, ReloadError, reload_secrets

    scope = ""
    container = ""
    project_label = ""
    docker_bin = "docker"
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--scope":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: reload: --scope requires a value\n")
                return 2
            scope = argv[i]
        elif arg == "--container":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: reload: --container requires a value\n")
                return 2
            container = argv[i]
        elif arg == "--project-label":
            i += 1
            if i >= len(argv):
                sys.stderr.write(
                    "mcp.cli: reload: --project-label requires a value\n"
                )
                return 2
            project_label = argv[i]
        elif arg == "--docker-bin":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: reload: --docker-bin requires a value\n")
                return 2
            docker_bin = argv[i]
        else:
            sys.stderr.write(f"mcp.cli: reload: unknown argument {arg!r}\n")
            return 2
        i += 1

    if scope not in ("global", "project"):
        sys.stderr.write(
            "mcp.cli: reload requires --scope global|project\n"
        )
        return 2
    if scope == "project" and not container:
        sys.stderr.write(
            "mcp.cli: reload --scope project requires --container <name>\n"
        )
        return 2

    try:
        result = reload_secrets(
            scope,
            container_name=container or None,
            project_label=project_label or None,
            docker=DockerExec(docker_bin=docker_bin),
        )
    except ReloadError as exc:
        sys.stderr.write(f"mcp.cli: reload: {exc}\n")
        return 2

    if as_json:
        _emit(result.to_dict())
        return 1 if result.any_failed else 0
    return _render_reload_text(result)


def _cmd_project_targets(argv: list[str], as_json: bool) -> int:
    """`project-targets-{json,text}`: enumerate importable boxa Project targets.

    The machine-readable enumerator the import wizard / `mcp add` pickers drive:
    the union of existing boxa registry paths and host-valid legacy Project
    paths from Claude's records. Output is secret-free directory metadata.
    """
    diagnostics = False
    volume_based = False
    for arg in argv:
        if arg == "--diagnostics" and not as_json:
            diagnostics = True
        elif arg == "--volume-based" and not as_json:
            volume_based = True
        else:
            sys.stderr.write(f"mcp.cli: unknown argument {arg!r}\n")
            return 2

    if volume_based:
        result = enumerate_volume_project_targets(ClaudeProvider(), VolumeProbe())
    else:
        config_home = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
            os.path.expanduser("~"), ".config"
        )
        registry_path = os.path.join(config_home, "boxa", "projects.json")
        try:
            with open(registry_path, encoding="utf-8") as fh:
                registry = json.load(fh)
        except (OSError, ValueError):
            registry = {}
        projects = registry.get("projects") if isinstance(registry, dict) else None
        registry_projects = projects if isinstance(projects, dict) else {}
        result = enumerate_project_targets(
            ClaudeProvider(), registry_projects, VolumeProbe()
        )
    if as_json:
        return _emit(result.to_dict())

    if not result.targets:
        if volume_based:
            sys.stdout.write(
                "No importable boxa Projects found. A Project must be known to "
                "Claude AND have an initialized boxa-<name>-history volume.\n"
            )
        else:
            sys.stdout.write(
                "No importable boxa Projects found. A Project must have an "
                "existing registered path, or an existing host path with an "
                "initialized boxa-<name>-history volume.\n"
            )
    for t in result.targets:
        # Tab-separated so the shell picker can split name from absolute path.
        display_name = "".join(
            " " if ord(char) < 32 or ord(char) == 127 else char
            for char in t.name
        )
        sys.stdout.write(f"{display_name}\t{t.project_key}\n")
    if volume_based:
        for collision in result.collisions:
            sys.stderr.write(
                f"mcp.cli: project name {collision.name!r} is ambiguous "
                f"({len(collision.project_keys)} host paths sanitize to it): "
                f"{', '.join(collision.project_keys)}\n"
            )
    elif diagnostics:
        for collision in result.collisions:
            sys.stdout.write(
                f"Ambiguous Project name {collision.name!r}; paths shown for "
                f"disambiguation: {', '.join(collision.project_keys)}\n"
            )
        for project_key in result.stale_projects:
            sys.stdout.write(
                "Skipped stale Project because its path is not an "
                f"existing directory: {project_key!r}\n"
            )
        for project_key in result.unsafe_project_keys:
            sys.stdout.write(
                "Skipped Project because its path contains an ASCII "
                f"protocol delimiter: {project_key!r}\n"
            )
        for project_key in result.excluded_home:
            sys.stdout.write(
                "Skipped Claude project record because the home directory is "
                f"never an import destination: {project_key!r}\n"
            )
    return 0


def _cmd_activation_project_targets(argv: list[str], as_json: bool) -> int:
    current = ""
    i = 0
    while i < len(argv):
        if argv[i] != "--current" or i + 1 >= len(argv):
            sys.stderr.write(
                "mcp.cli: activation Project targets require --current <path>\n"
            )
            return 2
        current = argv[i + 1]
        i += 2

    config_home = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config"
    )
    registry_path = os.path.join(config_home, "boxa", "projects.json")
    known: list[str] = []
    try:
        with open(registry_path, encoding="utf-8") as fh:
            registry = json.load(fh)
    except (OSError, ValueError):
        registry = {}
    projects = registry.get("projects") if isinstance(registry, dict) else None
    if isinstance(projects, dict):
        known.extend(
            os.path.realpath(path)
            for path, metadata in projects.items()
            if isinstance(path, str)
            and os.path.isabs(path)
            and isinstance(metadata, dict)
        )
    try:
        containers = subprocess.run(  # noqa: S603 - fixed Docker argv
            [
                "docker",
                "ps",
                "-a",
                "--filter",
                "name=^boxa-",
                "--format",
                "{{.Names}}",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
    except OSError:
        containers = None
    for container in (containers.stdout or "").splitlines() if containers else []:
        inspected = subprocess.run(  # noqa: S603 - Docker-provided container name
            [
                "docker",
                "inspect",
                "-f",
                "{{range .Config.Env}}{{println .}}{{end}}",
                container,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if inspected.returncode != 0:
            continue
        prefix = "BOXA_PROJECT_HOST_PATH="
        for line in (inspected.stdout or "").splitlines():
            if line.startswith(prefix) and line != prefix:
                known.append(os.path.realpath(line[len(prefix):]))
                break
    if current:
        current = os.path.realpath(current)
        current_name = sanitize_basename(basename_of(current))
        known = [
            path for path in known
            if sanitize_basename(basename_of(path)) != current_name
        ]
        known.append(current)

    class _KnownProjects:
        def project_keys(self) -> list[str]:
            return known

    result = enumerate_volume_project_targets(_KnownProjects(), VolumeProbe())
    if as_json:
        return _emit(result.to_dict())
    for target in result.targets:
        sys.stdout.write(f"{target.name}\t{target.project_key}\n")
    for collision in result.collisions:
        sys.stderr.write(
            f"mcp.cli: project name {collision.name!r} is ambiguous "
            f"({len(collision.project_keys)} Project paths): "
            f"{', '.join(collision.project_keys)}\n"
        )
    return 0


def _cmd_claude_launch_profile(argv: list[str]) -> int:
    """Emit only Claude's inline strict MCP config for its launch wrapper."""
    if argv:
        return 2
    try:
        profile = claude_launch_profile()
    except (LaunchProfileError, trusted.TrustedAuthorizationError):
        # The launch wrapper owns the one user-visible warning and fallback.
        return 1
    json.dump(profile, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


def _cmd_codex_launch_profile(argv: list[str]) -> int:
    """Emit Codex's launch-time MCP overrides, one per output line."""
    if argv:
        return 2
    try:
        overrides = codex_launch_profile()
    except (LaunchProfileError, trusted.TrustedAuthorizationError):
        # The launch wrapper owns the one user-visible warning and fallback.
        return 1
    for override in overrides:
        sys.stdout.write(f"{override}\n")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        sys.stderr.write("mcp.cli: missing command\n")
        return 2
    command = argv[0]
    rest = argv[1:]

    if command == "claude-launch-profile":
        return _cmd_claude_launch_profile(rest)
    if command == "codex-launch-profile":
        return _cmd_codex_launch_profile(rest)
    if command == "import-json":
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        return _emit(import_result(_discover(scope)))
    if command == "import-text":
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        return _render_text(_discover(scope))
    if command == "list-inherited-text":
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        return _render_inherited_table(_discover(scope))
    if command == "list-inherited-json":
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        return _emit(inherited_list_result(_discover(scope)))
    if command == "apply-json":
        sel = _parse_selection(rest)
        if sel is None:
            return 2
        merged = _discover(sel.scope, scope_overrides=sel.overrides)
        payload = _apply_payload(merged, sel)
        if payload.get("error") in ("selection", "conflict"):
            return 2
        _emit(payload)
        return 1 if payload.get("activationFailed") else 0
    if command == "apply-text":
        sel = _parse_selection(rest)
        if sel is None:
            return 2
        merged = _discover(sel.scope, scope_overrides=sel.overrides)
        return _render_apply_text(merged, sel)
    if command == "import-activate-json":
        return _cmd_import_activate(rest, as_json=True)
    if command == "import-activate-text":
        return _cmd_import_activate(rest, as_json=False)
    if command == "list-applicable":
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        return _render_applicable_list(_discover(scope))
    if command == "list-applicable-wizard":
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        return _render_applicable_wizard(_discover(scope))
    if command == "list-json":
        return _cmd_list(rest, as_json=True)
    if command == "list-text":
        return _cmd_list(rest, as_json=False)
    if command == "catalog-json":
        return _cmd_catalog(rest, as_json=True)
    if command == "catalog-text":
        return _cmd_catalog(rest, as_json=False)
    if command == "catalog-picker":
        return _cmd_catalog_picker(rest)
    if command == "catalog-update-picker":
        return _cmd_catalog_update_picker(rest)
    if command == "secret-missing-entry-picker":
        return _cmd_secret_missing_entry_picker(rest)
    if command == "secret-missing-key-picker":
        return _cmd_secret_missing_key_picker(rest)
    if command == "catalog-resolve":
        return _cmd_catalog_resolve(rest)
    if command == "catalog-mode-preview-json":
        return _cmd_catalog_mode_preview(rest, as_json=True)
    if command == "catalog-mode-preview-text":
        return _cmd_catalog_mode_preview(rest, as_json=False)
    if command == "catalog-mode-apply-json":
        return _cmd_catalog_mode_apply(rest, as_json=True)
    if command == "catalog-mode-apply-text":
        return _cmd_catalog_mode_apply(rest, as_json=False)
    if command == "catalog-add-json":
        return _cmd_catalog_add(rest, as_json=True)
    if command == "catalog-add-text":
        return _cmd_catalog_add(rest, as_json=False)
    if command == "catalog-remove-json":
        return _cmd_catalog_remove(rest, as_json=True)
    if command == "catalog-remove-text":
        return _cmd_catalog_remove(rest, as_json=False)
    if command == "catalog-update-json":
        return _cmd_catalog_update(rest, as_json=True)
    if command == "catalog-update-text":
        return _cmd_catalog_update(rest, as_json=False)
    if command == "activate-json":
        return _cmd_activate(rest, as_json=True)
    if command == "activate-text":
        return _cmd_activate(rest, as_json=False)
    if command == "activation-degradation-text":
        return _cmd_activation_degradation(rest, as_json=False)
    if command == "activation-degradation-json":
        return _cmd_activation_degradation(rest, as_json=True)
    if command == "activation-agent-trusted-text":
        return _cmd_activation_agent_trusted(rest)
    if command == "reevaluate-pending":
        return _cmd_reevaluate_pending(rest)
    if command == "readiness-json":
        return _cmd_readiness(rest, as_json=True)
    if command == "readiness-text":
        return _cmd_readiness(rest, as_json=False)
    if command == "secret-set-json":
        return _cmd_secret_set(rest, as_json=True)
    if command == "secret-set-text":
        return _cmd_secret_set(rest, as_json=False)
    if command == "guided-secret-header-text":
        return _cmd_guided_secret_header(rest)
    if command == "catalog-install-json":
        return _cmd_catalog_install(rest, as_json=True)
    if command == "catalog-install-text":
        return _cmd_catalog_install(rest, as_json=False)
    if command == "deactivate-json":
        return _cmd_deactivate(rest, as_json=True)
    if command == "deactivate-text":
        return _cmd_deactivate(rest, as_json=False)
    if command == "catalog-effective-list-json":
        return _cmd_catalog_effective_list(rest, as_json=True)
    if command == "catalog-effective-list-text":
        return _cmd_catalog_effective_list(rest, as_json=False)
    if command == "enable-json":
        return _cmd_toggle(rest, enabled=True, as_json=True)
    if command == "enable-text":
        return _cmd_toggle(rest, enabled=True, as_json=False)
    if command == "disable-json":
        return _cmd_toggle(rest, enabled=False, as_json=True)
    if command == "disable-text":
        return _cmd_toggle(rest, enabled=False, as_json=False)
    if command == "remove-json":
        return _cmd_remove(rest, as_json=True)
    if command == "remove-text":
        return _cmd_remove(rest, as_json=False)
    if command == "remove-secret-check":
        return _cmd_remove_secret_check(rest)
    if command == "doctor-json":
        return _cmd_doctor(rest, as_json=True)
    if command == "doctor-text":
        return _cmd_doctor(rest, as_json=False)
    if command == "install-json":
        return _cmd_install(rest, as_json=True)
    if command == "install-text":
        return _cmd_install(rest, as_json=False)
    if command == "add-json":
        return _cmd_add(rest, as_json=True)
    if command == "add-text":
        return _cmd_add(rest, as_json=False)
    if command == "run":
        # The boxa-mcp-run wrapper core. Args: [--project <key>] <server>.
        return _run_wrapper(rest)
    if command == "stage-secrets":
        # Root-side secret staging (issue 16). Args:
        #   --source <gated-mount-mcp-dir> --dest <boxa-mcp-private-dir>
        #   [--project <full-project-key>] [--owner <user-or-uid>]
        # Copies the in-scope (global + this Project) secret stores out of the
        # read-only host mount into the boxa-mcp-private staged dir as 0400
        # files owned by boxa-mcp. Run as root from the entrypoint (and issue
        # 17's reload). SECRET-FREE output (scope labels + basenames only).
        return _cmd_stage_secrets(rest, as_json=False)
    if command == "project-keys":
        # Emit known Claude project record keys, one per line. These are
        # directory paths (Claude's own map keys) — not secret. Used by the
        # shell dispatcher to resolve a bare `--project <name>` token.
        for key in ClaudeProvider().project_keys():
            sys.stdout.write(key + "\n")
        return 0
    if command == "reload-json":
        return _cmd_reload(rest, as_json=True)
    if command == "reload-text":
        return _cmd_reload(rest, as_json=False)
    if command == "project-targets-json":
        return _cmd_project_targets(rest, as_json=True)
    if command == "project-targets-text":
        return _cmd_project_targets(rest, as_json=False)
    if command == "activation-project-targets-json":
        return _cmd_activation_project_targets(rest, as_json=True)
    if command == "activation-project-targets-text":
        return _cmd_activation_project_targets(rest, as_json=False)
    if command in ("migrate-json", "migrate-text"):
        allow_tracked_mcp_json = False
        allow_tracked_codex_config = False
        for arg in rest:
            if arg == "--allow-tracked-mcp-json":
                allow_tracked_mcp_json = True
                continue
            if arg == "--allow-tracked-codex-config":
                allow_tracked_codex_config = True
                continue
            sys.stderr.write(
                "mcp.cli: migrate takes only --allow-tracked-mcp-json "
                "and --allow-tracked-codex-config\n"
            )
            return 2
        try:
            result = migrate_legacy(
                allow_tracked_mcp_json=allow_tracked_mcp_json,
                allow_tracked_codex_config=allow_tracked_codex_config,
            )
        except (MigrationError, ActivationError, CatalogError, OSError, ValueError) as exc:
            sys.stderr.write(f"mcp.cli: {exc}\n")
            return 2
        if command == "migrate-json":
            return _emit(result)
        count = len(result.get("definitions", []))
        global_count = sum(
            1
            for row in result.get("definitions", [])
            if isinstance(row, dict) and row.get("scope") == "global"
        )
        state = "completed" if result.get("changed") else "already complete"
        retained = result.get("retainedLegacyEntries", [])
        retained_detail = "; ".join(
            f"{row['name']} ({row['reason']})"
            for row in retained
            if isinstance(row, dict)
            and isinstance(row.get("name"), str)
            and isinstance(row.get("reason"), str)
        )
        detail = (
            "No legacy entries required migration or purging."
            if result.get("status") == "not-needed"
            else f"Retained legacy entries: {retained_detail}."
            if result.get("legacyRetained")
            else "Migrated legacy entries were purged from the legacy profile store."
        )
        sys.stdout.write(
            f"Legacy MCP migration {state}: {count} definition(s); "
            f"global activations: {global_count}. {detail}\n"
        )
        sys.stdout.write("Next: boxa mcp status\n")
        return 0
    if command == "onboarding-status":
        # One-time MCP onboarding eligibility (issue 10). The install/update
        # shell hook reads this to decide whether to offer the import wizard.
        if rest:
            sys.stderr.write(
                "mcp.cli: onboarding-status takes no arguments\n"
            )
            return 2
        return onboarding.emit_status(sys.stdout)
    if command == "onboarding-text":
        # Emit one onboarding text block: offer / followup / reminder.
        if len(rest) != 1:
            sys.stderr.write(
                "mcp.cli: onboarding-text takes exactly one of "
                "offer|followup|reminder\n"
            )
            return 2
        rc = onboarding.emit_text(sys.stdout, rest[0])
        if rc is None:
            sys.stderr.write(
                f"mcp.cli: unknown onboarding text block {rest[0]!r} "
                "(offer|followup|reminder)\n"
            )
            return 2
        return rc
    if command == "onboarding-mark-seen":
        # Record that onboarding was seen (suppresses future prompts). The
        # optional decision label is informational only.
        decision = rest[0] if rest else onboarding.DECISION_NOOP
        if len(rest) > 1:
            sys.stderr.write(
                "mcp.cli: onboarding-mark-seen takes at most one decision "
                "label\n"
            )
            return 2
        onboarding.mark_seen(decision)
        return 0

    if command == "onboarding-rearm":
        # Clear the one-time seen/dismissed marker so onboarding can be offered
        # again. Used by `boxa doctor --fix mcp-onboarding` to genuinely
        # re-trigger a previously dismissed offer (the user asked for it).
        if rest:
            sys.stderr.write("mcp.cli: onboarding-rearm takes no arguments\n")
            return 2
        onboarding.rearm()
        return 0

    if command == "seed-codex-delegate-status":
        # One-time codex-delegate seed eligibility. The install/update shell
        # hook reads this to decide whether to offer the seeded entry.
        if rest:
            sys.stderr.write(
                "mcp.cli: seed-codex-delegate-status takes no arguments\n"
            )
            return 2
        return seed.emit_status(sys.stdout)
    if command == "seed-codex-delegate-text":
        # Emit one seed text block: offer / followup / reminder.
        if len(rest) != 1:
            sys.stderr.write(
                "mcp.cli: seed-codex-delegate-text takes exactly one of "
                "offer|followup|reminder\n"
            )
            return 2
        rc = seed.emit_text(sys.stdout, rest[0])
        if rc is None:
            sys.stderr.write(
                f"mcp.cli: unknown seed text block {rest[0]!r} "
                "(offer|followup|reminder)\n"
            )
            return 2
        return rc
    if command == "seed-codex-delegate-apply":
        # Add the codex-delegate entry and grant agent-trusted mode. Host-only
        # (the grant path refuses inside a Container) and gated on --yes: the
        # shell hook passes it only after the interactive access-boundary
        # confirmation, mirroring `catalog-mode-apply`.
        if rest != ["--yes"]:
            sys.stderr.write(
                "mcp.cli: seed-codex-delegate-apply requires --yes\n"
            )
            return 2
        try:
            entry = seed.apply()
        except (CatalogError, ValueError) as exc:
            sys.stderr.write(f"mcp.cli: {exc}\n")
            return 2
        sys.stdout.write(
            f"MCP catalog entry {entry['name']!r} is ready as "
            f"{entry['executionMode']} ({entry['id']}).\n"
        )
        return 0
    if command == "seed-codex-delegate-mark-seen":
        # Record the seed decision (suppresses future prompts). The optional
        # decision label is informational only.
        decision = rest[0] if rest else seed.DECISION_NOOP
        if len(rest) > 1:
            sys.stderr.write(
                "mcp.cli: seed-codex-delegate-mark-seen takes at most one "
                "decision label\n"
            )
            return 2
        seed.mark_seen(decision)
        return 0
    if command == "seed-codex-delegate-rearm":
        # Clear the seed marker so the one-time offer can fire again.
        if rest:
            sys.stderr.write(
                "mcp.cli: seed-codex-delegate-rearm takes no arguments\n"
            )
            return 2
        seed.rearm()
        return 0

    sys.stderr.write(f"mcp.cli: unknown command {command!r}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
