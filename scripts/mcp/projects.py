"""Boxa-project resolver and enumerator (ADR 0013 amendment, issue 11).

The shared foundation the interactive import wizard (issue 12) and
``boxa mcp add`` (issue 13) both build on. It answers one question for the
shell pickers: *which boxa Projects can a Project-scoped MCP server be applied
to, and what absolute host path keys each one?*

Why this matters (ADR 0013 amendment "A picked boxa Project resolves to its
host path via Claude's project records"):

  * Project-scoped profile entries must be keyed by the **absolute host path**,
    because rendering writes into Claude Code's ``~/.claude.json`` ``projects``
    map, which is keyed by absolute path. A bare sanitized Project NAME is
    insufficient — two host paths can sanitize to the same name (ADR 0005).
  * The boxa Project registry maps exact host paths to their display names.
    Import targets are the path-based intersection of that registry with
    Claude's ``projects`` map. Container-side ``/workspace`` records and other
    Claude records outside the registry are therefore irrelevant.
  * Two registry paths may share a display name. Both remain valid targets and
    their paths disambiguate them in the picker; the ambiguity is also surfaced
    as a diagnostic instead of silently dropping either Project.

Legacy activation marker volume
-------------------------------
The ADR 0013 amendment names ``boxa-<name>-claude`` as the marker, but that
volume is **legacy**: current boxa bind-mounts the host ``~/.claude`` directly
(ADR 0002) and ``docker-run.sh`` treats ``boxa-(.+-)?claude`` volumes as stale
pre-migration state, removing them. An initialized Project today instead always
has the per-project ``boxa-<name>-history`` and ``boxa-<name>-docker``
volumes (``lib/naming.sh`` ``BOXA_PROJECT_VOLUME_SUFFIXES``; created
unconditionally in ``docker-run.sh``). Gating on the obsolete ``-claude`` volume
would return zero targets for every normal install. The activation workflows
that still enumerate from Docker therefore probe the canonical per-project marker
(``boxa-<name>-history``) — the same suffix boxa uses to reverse-derive the
Project list — which faithfully realizes the amendment's intent ("a real boxa
Project that can actually run the server").

Secret-safe: this module only handles directory paths (non-secret) and a docker
volume-existence probe. It never reads agent credentials or MCP env values.
"""

from __future__ import annotations

import os
import re
import subprocess  # noqa: S404 - volume probe genuinely shells out to docker
from dataclasses import dataclass, field
from typing import Mapping, Optional

# Per-project volume name boxa uses as proof a directory is a real,
# initialized Project: ``boxa-<sanitized-basename>-history``. This is one of
# the ``BOXA_PROJECT_VOLUME_SUFFIXES`` in ``lib/naming.sh`` that docker-run.sh
# creates unconditionally for every Project, and the suffix boxa already
# reverse-derives the Project list from. It replaces the amendment's nominal but
# now-obsolete ``-claude`` volume (see the module docstring's "Marker volume").
_PROJECT_VOLUME_PREFIX = "boxa-"
_PROJECT_VOLUME_SUFFIX = "-history"

# ADR 0005 sanitizer: this MUST stay byte-for-byte equivalent to
# ``boxa::sanitize`` in ``lib/naming.sh`` (``tr -cs 'a-zA-Z0-9-' '-' |
# sed 's/^-//;s/-$//'``) so the Python-side volume name matches the one the
# shell actually created. ``tr -cs`` maps every non-LDH character to a dash AND
# squeezes (``-s``) every resulting run of dashes to one — including runs formed
# next to dashes already present in the input (e.g. ``é-app`` -> ``-app``, not
# ``--app``). So substitution alone is not enough; consecutive dashes that meet
# a converted dash must also collapse. Case is preserved (no lower-casing).
_NON_LDH = re.compile(r"[^A-Za-z0-9-]")
_DASH_RUN = re.compile(r"-+")


def sanitize_basename(name: str) -> str:
    """Sanitize a string into a boxa project name (ADR 0005 LDH rule).

    Equivalent to ``boxa::sanitize`` in ``lib/naming.sh``: map every non-LDH
    character to a dash, squeeze every run of dashes (including ones adjacent to
    pre-existing dashes) to a single dash, then strip leading and trailing
    dashes. Case is preserved. Reused here (not reinvented) so the derived
    ``boxa-<name>-history`` volume name matches what docker-run.sh created for
    the Project.
    """
    mapped = _NON_LDH.sub("-", name)
    squeezed = _DASH_RUN.sub("-", mapped)
    return squeezed.strip("-")


def basename_of(path: str) -> str:
    """The trailing path component of an absolute project key.

    Mirrors ``basename`` over the host path: trailing slashes are stripped first
    so ``/work/app/`` and ``/work/app`` yield the same ``app``. Returns the path
    unchanged when it has no separator (already a bare name).
    """
    trimmed = path.rstrip("/") or path
    slash = trimmed.rfind("/")
    return trimmed[slash + 1 :] if slash != -1 else trimmed


def project_volume_name(project_name: str) -> str:
    """The ``boxa-<sanitized-name>-history`` marker volume for a Project name.

    ``project_name`` is the ALREADY-sanitized Project name (the basename run
    through :func:`sanitize_basename`). The volume's existence is the proof the
    directory is a real, initialized boxa Project (ADR 0013 amendment intent;
    see the module docstring's "Marker volume" for why ``-history`` is used
    instead of the amendment's obsolete ``-claude``).
    """
    return f"{_PROJECT_VOLUME_PREFIX}{project_name}{_PROJECT_VOLUME_SUFFIX}"


class VolumeProbe:
    """Probes docker volume existence in the HOST docker daemon.

    Injectable for the same reason issue 09's ``Executor`` is: the real probe
    shells out to ``docker volume inspect``, which is unavailable (and must never
    run) in the unit tests. Tests subclass this and override :meth:`exists` with
    a stub set of known volume names, so no real ``docker`` is ever invoked.

    The default implementation runs ``docker volume inspect <name>`` and treats a
    zero exit as "exists". ``docker_bin`` is overridable so a caller can point at
    ``podman`` or an absolute path; it defaults to ``docker`` on PATH.
    """

    def __init__(self, docker_bin: str = "docker") -> None:
        self.docker_bin = docker_bin

    def exists(self, volume_name: str) -> bool:
        """True when a docker volume with this exact name exists on the host."""
        try:
            proc = subprocess.run(  # noqa: S603 - argv list, no shell, trusted
                [self.docker_bin, "volume", "inspect", volume_name],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        except OSError:
            # docker not installed / not on PATH: treat as "no volume" rather
            # than crashing the enumerator. The caller still gets an empty
            # target set, and the shell front-end surfaces the missing-docker
            # condition separately.
            return False
        return proc.returncode == 0


@dataclass(frozen=True)
class ProjectTarget:
    """One importable boxa Project target (ADR 0013 amendment).

    Carries both the registry display name and the absolute host path
    (``project_key``) that keys the Claude ``projects`` map and the rendered
    Project-scoped profile.
    """

    name: str  # boxa registry display name
    project_key: str  # absolute host path (the render key)

    def to_dict(self) -> dict[str, str]:
        return {"name": self.name, "projectKey": self.project_key}


@dataclass(frozen=True)
class ProjectCollision:
    """Two or more target paths share one registry display name.

    Both paths remain targets because the picker displays their exact host
    paths. The caller also reports the ambiguity in the picker header.
    """

    name: str
    project_keys: list[str]

    def to_dict(self) -> dict[str, object]:
        return {"name": self.name, "projectKeys": list(self.project_keys)}


@dataclass
class ProjectTargets:
    """Result of enumerating importable boxa Project targets.

    ``targets`` are the offered Projects (sorted by name); ``collisions`` are
    name clashes surfaced for disambiguation. Missing Claude records, stale
    paths, and protocol-unsafe keys are retained as diagnostics. All fields are
    secret-free directory metadata.
    """

    targets: list[ProjectTarget] = field(default_factory=list)
    collisions: list[ProjectCollision] = field(default_factory=list)
    missing_claude_records: list[str] = field(default_factory=list)
    stale_projects: list[str] = field(default_factory=list)
    unsafe_project_keys: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, object]:
        return {
            "targets": [t.to_dict() for t in self.targets],
            "collisions": [c.to_dict() for c in self.collisions],
            "missingClaudeRecords": list(self.missing_claude_records),
            "staleProjects": list(self.stale_projects),
            "unsafeProjectKeys": list(self.unsafe_project_keys),
        }


def enumerate_project_targets(
    claude_provider,
    registry_projects: Mapping[str, object],
) -> ProjectTargets:
    """Enumerate import targets by exact registry/Claude path intersection."""
    claude_keys = {str(key) for key in claude_provider.project_keys()}
    by_name: dict[str, list[str]] = {}
    targets: list[ProjectTarget] = []
    missing: list[str] = []
    stale: list[str] = []
    unsafe: list[str] = []
    for project_key, raw_metadata in registry_projects.items():
        if not isinstance(project_key, str) or not project_key.startswith("/"):
            continue
        if not isinstance(raw_metadata, Mapping):
            continue
        raw_name = raw_metadata.get("name")
        if not isinstance(raw_name, str) or not raw_name:
            continue
        if any(ord(char) < 32 or ord(char) == 127 for char in project_key):
            unsafe.append(project_key)
            continue
        if not os.path.isdir(project_key):
            stale.append(project_key)
            continue
        if project_key not in claude_keys:
            missing.append(project_key)
            continue
        targets.append(ProjectTarget(name=raw_name, project_key=project_key))
        by_name.setdefault(raw_name, []).append(project_key)

    collisions = [
        ProjectCollision(name=name, project_keys=sorted(keys))
        for name, keys in by_name.items()
        if len(keys) > 1
    ]

    targets.sort(key=lambda t: (t.name, t.project_key))
    collisions.sort(key=lambda c: c.name)
    return ProjectTargets(
        targets=targets,
        collisions=collisions,
        missing_claude_records=sorted(missing),
        stale_projects=sorted(stale),
        unsafe_project_keys=sorted(unsafe),
    )


def enumerate_volume_project_targets(
    claude_provider,
    probe: Optional[VolumeProbe] = None,
) -> ProjectTargets:
    """Legacy volume-based target set used by activation workflows."""
    probe = probe or VolumeProbe()
    by_name: dict[str, list[str]] = {}
    seen_keys: set[str] = set()
    for raw_key in claude_provider.project_keys():
        key = str(raw_key)
        if key in seen_keys:
            continue
        seen_keys.add(key)
        name = sanitize_basename(basename_of(key))
        if not name:
            continue
        by_name.setdefault(name, []).append(key)

    targets: list[ProjectTarget] = []
    collisions: list[ProjectCollision] = []
    for name, keys in by_name.items():
        if len(keys) > 1:
            collisions.append(ProjectCollision(name=name, project_keys=sorted(keys)))
            continue
        if probe.exists(project_volume_name(name)):
            targets.append(ProjectTarget(name=name, project_key=keys[0]))

    targets.sort(key=lambda target: (target.name, target.project_key))
    collisions.sort(key=lambda collision: collision.name)
    return ProjectTargets(targets=targets, collisions=collisions)
