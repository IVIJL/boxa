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
  * There is no boxa-side registry of Project -> host path. The authoritative
    source is **Claude's own ``projects`` map**: it stores every absolute path
    Claude has worked with, and because each Project is bind-mounted at its
    literal host path (ADR 0004) that path is valid both on the host and inside
    the Container.
  * Knowing a path is not enough: the target must be a real boxa Project that
    can actually run the server. So the enumerator offers the **intersection** of
    Claude project records with existing boxa per-project volumes, matched by
    the ADR 0005 sanitized basename. A directory Claude knows but boxa has not
    initialized (no volume) is NOT offered.

Marker volume
-------------
The ADR 0013 amendment names ``boxa-<name>-claude`` as the marker, but that
volume is **legacy**: current boxa bind-mounts the host ``~/.claude`` directly
(ADR 0002) and ``docker-run.sh`` treats ``boxa-(.+-)?claude`` volumes as stale
pre-migration state, removing them. An initialized Project today instead always
has the per-project ``boxa-<name>-history`` and ``boxa-<name>-docker``
volumes (``lib/naming.sh`` ``BOXA_PROJECT_VOLUME_SUFFIXES``; created
unconditionally in ``docker-run.sh``). Gating on the obsolete ``-claude`` volume
would return zero targets for every normal install. Per the issue's "match what's
actually there", we therefore probe the canonical per-project marker
(``boxa-<name>-history``) — the same suffix boxa uses to reverse-derive the
Project list — which faithfully realizes the amendment's intent ("a real boxa
Project that can actually run the server").

Two host paths sanitizing to the same volume name are a **collision**: they are
surfaced for explicit disambiguation, never silently merged (mirrors the
``_resolve_project_key`` contract referenced by the amendment).

Secret-safe: this module only handles directory paths (non-secret) and a docker
volume-existence probe. It never reads agent credentials or MCP env values.
"""

from __future__ import annotations

import re
import subprocess  # noqa: S404 - volume probe genuinely shells out to docker
from dataclasses import dataclass, field
from typing import Optional

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

    Carries BOTH the display name (the sanitized Project name, which is also the
    volume/container label) and the absolute host path (``project_key``) that
    keys the Claude ``projects`` map and the rendered Project-scoped profile.
    """

    name: str  # sanitized Project name == boxa label
    project_key: str  # absolute host path (the render key)

    def to_dict(self) -> dict[str, str]:
        return {"name": self.name, "projectKey": self.project_key}


@dataclass(frozen=True)
class ProjectCollision:
    """Two or more Claude project keys sanitize to the same Project name.

    Surfaced for explicit disambiguation rather than guessed at: a bare
    sanitized name maps to one ``boxa-<name>-history`` volume, so two distinct
    host paths sharing that name cannot be told apart by volume existence alone.
    The caller reports the colliding keys so the user resolves it deliberately.
    """

    name: str
    project_keys: list[str]

    def to_dict(self) -> dict[str, object]:
        return {"name": self.name, "projectKeys": list(self.project_keys)}


@dataclass
class ProjectTargets:
    """Result of enumerating importable boxa Project targets.

    ``targets`` are the offered Projects (sorted by name); ``collisions`` are
    name clashes surfaced for disambiguation. Both are secret-free directory
    metadata.
    """

    targets: list[ProjectTarget] = field(default_factory=list)
    collisions: list[ProjectCollision] = field(default_factory=list)

    def to_dict(self) -> dict[str, object]:
        return {
            "targets": [t.to_dict() for t in self.targets],
            "collisions": [c.to_dict() for c in self.collisions],
        }


def enumerate_project_targets(
    claude_provider,
    probe: Optional[VolumeProbe] = None,
) -> ProjectTargets:
    """Enumerate the boxa Projects an MCP server can be applied to.

    The offered set is the **intersection** of Claude's known project records
    (``claude_provider.project_keys()`` — every absolute path Claude tracks) with
    existing ``boxa-<sanitized-basename>-history`` marker volumes. A record
    whose volume does not exist is excluded (Claude knows the directory but boxa
    has not initialized it as a Project). Volume existence is checked through
    ``probe`` so tests never call real ``docker``.

    Basename collisions — two distinct project keys sanitizing to the same name —
    are reported in ``collisions`` and excluded from ``targets``: a single volume
    name cannot disambiguate them, so the user must choose explicitly rather than
    have boxa guess which host path the volume belongs to.

    Returns a :class:`ProjectTargets` with both lists sorted for deterministic
    output.
    """
    probe = probe or VolumeProbe()

    # Group every Claude project key by its sanitized Project name. A name with
    # more than one distinct key is a collision; a name with exactly one key is a
    # resolvable candidate (subject to the volume check below).
    by_name: dict[str, list[str]] = {}
    seen_keys: set[str] = set()
    for raw_key in claude_provider.project_keys():
        key = str(raw_key)
        # De-duplicate identical keys so a doubly-listed record does not look
        # like a self-collision.
        if key in seen_keys:
            continue
        seen_keys.add(key)
        name = sanitize_basename(basename_of(key))
        if not name:
            # A key whose basename sanitizes to empty (e.g. "/" or all-punctuation)
            # has no usable Project name / volume — skip it rather than probe a
            # malformed "boxa--history" volume.
            continue
        by_name.setdefault(name, []).append(key)

    targets: list[ProjectTarget] = []
    collisions: list[ProjectCollision] = []
    for name, keys in by_name.items():
        if len(keys) > 1:
            # Multiple host paths share this sanitized name -> the single
            # boxa-<name>-history volume cannot disambiguate them. Surface for
            # explicit choice; never silently pick one.
            collisions.append(ProjectCollision(name=name, project_keys=sorted(keys)))
            continue
        # Exactly one key for this name: offer it only if the boxa Project
        # volume actually exists (proves the directory is an initialized Project).
        if probe.exists(project_volume_name(name)):
            targets.append(ProjectTarget(name=name, project_key=keys[0]))

    targets.sort(key=lambda t: (t.name, t.project_key))
    collisions.sort(key=lambda c: c.name)
    return ProjectTargets(targets=targets, collisions=collisions)
