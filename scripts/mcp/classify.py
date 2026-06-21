"""Evidence-based MCP candidate classifier (ADR 0013, issue 04).

This is the single place that turns a discovered `Candidate` into a placement
decision. Providers (issue 02-03) only normalize config into the candidate
shape; they classify nothing except the one thing they can be certain about
from the transport alone — a Claude hosted/remote connector is ``excluded``.
Everything else arrives here as ``unknown`` and this module assigns the real
placement, confidence, and human-readable reasons.

Design (local-plan-mcp.md core question 9 + ADR 0013 "import via
classification"):

  * Placement separates *where it should run* from *how confident* boxa is:
      - placement ∈ {container, host-only, unknown, excluded};
      - confidence ∈ {high, medium, low}.
  * Classification is evidence-based, never name-based. The evidence is the
    command family (npx/uvx/python/docker/absolute binary), the argv tokens,
    referenced environment-variable NAMES, absolute host paths, Windows/WSL2
    path markers, and desktop/browser/clipboard/OS indicators.
  * The classifier is read-only and secret-safe: it inspects argv tokens and
    env-variable NAMES only (values never enter the candidate model), and it
    reports required/secret env key NAMES, never values.

Why a separate module instead of classifying in each provider: the same
command means the same thing regardless of which agent config it came from, so
the evidence rules belong in one provider-neutral place that the merge pipeline
runs over every candidate. It also keeps providers small and the rules unit
testable in isolation.
"""

from __future__ import annotations

import re
from typing import Optional

from .candidate import Candidate, Classification

# --- Command families --------------------------------------------------------
# Package launchers that resolve (or can be installed) inside the Container.
# These are the families ADR 0013 calls out as container-friendly: npx (npm),
# uvx/python (Python), and docker (rootless DinD).
_NODE_LAUNCHERS = {"npx", "npm", "pnpm", "yarn", "bunx", "node"}
_PYTHON_LAUNCHERS = {"uvx", "uv", "python", "python3", "pipx"}
_DOCKER_LAUNCHERS = {"docker", "podman"}

# Versioned Python interpreters such as ``python3.11`` / ``python3.12`` are
# common in inherited configs; the bare-name set above would miss them, so a
# minor-version suffix on ``python``/``python3`` is matched structurally too.
_VERSIONED_PYTHON_RE = re.compile(r"^python(?:[23](?:\.\d+)*)?$")


def _container_family(command: str) -> str:
    """Coarse container-friendly family for a launcher, or "" if none.

    Matches the launcher BASENAME (case-insensitive) against the node, python,
    and docker families, accepting versioned Python interpreters
    (``python3.11``). Returns "node" / "python" / "docker", or "" when the
    command is not a recognized container-friendly launcher.
    """
    base = command.rsplit("/", 1)[-1].lower()
    if base in _NODE_LAUNCHERS:
        return "node"
    if base in _PYTHON_LAUNCHERS or _VERSIONED_PYTHON_RE.match(base):
        return "python"
    if base in _DOCKER_LAUNCHERS:
        return "docker"
    return ""

# --- Host-only resource indicators -------------------------------------------
# Substrings (matched case-insensitively against argv tokens and env-var names)
# that mark a server as needing host OS / desktop / browser / clipboard state
# the Container intentionally cannot see (ADR 0013 context; plan question 9).
# These are deliberately high-signal: a hit moves placement to host-only.
_DESKTOP_INDICATORS = (
    "clipboard",
    "applescript",
    "desktop",
    "screenshot",
    "screencapture",
    "keystroke",
    "keyboard",
    "automator",
    "xdotool",
    "wmctrl",
    "notify-send",
    "osascript",
    "powershell",
    "pwsh",
)

# Browser-automation indicators. These overlap with the Agent-browser model
# (ADR 0010) and need a real browser/desktop the Container does not own, so
# they are host-only, not container. `browser-tools` itself is explicitly out
# of the first import wave (plan slice list).
_BROWSER_INDICATORS = (
    "browser-tools",
    "puppeteer",
    "playwright",
    "browsermcp",
    "browser-mcp",
    "chrome-devtools",
)

# Display / GUI environment variables a server needs a host desktop for.
_DISPLAY_ENV_NAMES = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY")

# Environment variables that point at a host-side credential agent, socket, or
# keyring the Container intentionally does not share (ADR 0013: host credential
# stores and host-only sockets are outside the Container boundary). A server
# that depends on one of these needs host state and is host-only, not a
# Container MCP server. Matched by exact NAME (names only — values never enter
# the model).
_HOST_RESOURCE_ENV_NAMES = (
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
    "GPG_AGENT_INFO",
    "DBUS_SESSION_BUS_ADDRESS",
    "XDG_RUNTIME_DIR",
    "GNOME_KEYRING_CONTROL",
    "GNOME_KEYRING_PID",
    "DOCKER_HOST",
)

# --- Windows / WSL2 path indicators ------------------------------------------
# A drive-letter path (``C:\...`` / ``C:/...``) or a WSL interop path
# (``/mnt/c/...``) refers to the Windows host filesystem, which is the wrong OS
# boundary inside the Container (ADR 0013 context). Detected structurally so a
# legitimate Linux path is never mistaken for a Windows one.
_WINDOWS_DRIVE_RE = re.compile(r"^[A-Za-z]:[\\/]")
_WSL_MOUNT_RE = re.compile(r"^/mnt/[a-z](?:/|$)")
_UNC_PATH_RE = re.compile(r"^\\\\")  # \\server\share
_WINDOWS_INTEROP_MARKERS = (".exe", "wsl.exe", "cmd.exe", "explorer.exe")


def _path_fragments(token: str) -> list[str]:
    """Split one argv token into candidate path fragments.

    Many CLIs embed a path inside a larger option token rather than passing it
    as a standalone argument, e.g. ``--root=/home/alice/data``,
    ``--path=C:\\Users\\alice``, or a docker bind mount
    ``--mount=type=bind,src=/home/alice:/data``. A naive "does the whole token
    start with a path" check misses all of these and lets a host-dependent
    server fall through to container/high.

    To catch them, the token itself is returned plus every fragment obtained by
    splitting on the delimiters that separate option keys from values and
    sub-values: ``=``, ``,``, and ``:``. Splitting on ``:`` also exposes the
    source side of a ``src:dst`` mount and a Windows ``C:\\...`` drive (the
    drive-letter regex re-anchors on the fragment). Each fragment is then run
    through the same path detectors. This is a read-only, name/argv-only scan;
    no secret value is involved (argv is already redacted upstream).
    """
    frags = {token}
    for part in re.split(r"[=,]", token):
        part = part.strip()
        if not part:
            continue
        frags.add(part)
        # Attached short-option forms glue the value onto a single-letter flag
        # with no separator, e.g. ``-v/home/alice:/data`` or ``-C/home/alice``.
        # Strip a leading ``-X`` so the embedded path fragment is visible to the
        # path detectors. Only single-letter short options are unglued; a long
        # ``--flag`` keeps its value via the ``=`` split above.
        m = re.match(r"^-([A-Za-z])(.+)$", part)
        if m:
            frags.add(m.group(2).strip())
    return [f for f in frags if f]


# Absolute roots that map to the mounted Project / agent workdir inside the
# Container. An absolute path under one of these is NOT a host-only signal — it
# resolves to the SAME content inside the Container (ADR 0013 / plan question 9:
# only host paths *outside the mounted Project* are host-only).
#
# Deliberately narrow: this list holds only the roots boxa actually maps for
# every Container. ``/workspace`` is the WORKDIR and the legacy project-mount
# alias (docker-run.sh), and ``/home/node`` is the agent home whose dotfiles
# are bind-mounted. The CURRENT project is mounted at its host path, which is
# handled per-candidate via ``project_root`` (the Claude project key), not here.
#
# Everything else — generic roots like /app, /src, /code, and system roots like
# /tmp, /etc, /opt, /usr, /var — is NOT exempted: those paths either are not a
# boxa convention or exist in the Container with DIFFERENT content than the
# host, so a server reading them would silently see different files. They are
# surfaced as host-only/manual-confirm instead.
_CONTAINER_INTERNAL_ROOTS = (
    "/workspace",
    "/workspaces",
    "/home/node",
    "/home/boxa",
)


def _path_source_side(frag: str) -> str:
    """The host-facing side of a path fragment.

    A docker-style mount fragment is ``source:destination`` (e.g.
    ``/home/alice:/data`` or a named volume ``cache:/data``). Only the SOURCE
    (left of the first ``:``) can be a host path; the destination is always
    container-side, so classifying on the destination would misflag a perfectly
    container-internal mount target. URLs (``scheme://...``) and Windows drives
    (``C:\\...``) keep their colon and are returned unchanged — they are handled
    by the URL skip and the Windows detector respectively.
    """
    if "://" in frag or _WINDOWS_DRIVE_RE.match(frag):
        return frag
    return frag.split(":", 1)[0]


def _is_windows_path(token: str) -> bool:
    """True when an argv token (or an embedded fragment) is a Windows path.

    Catches both standalone tokens and inline option forms such as
    ``--path=C:\\Users\\alice`` by checking every path fragment of the token.
    """
    for frag in _path_fragments(token):
        if _WINDOWS_DRIVE_RE.match(frag):
            return True
        if _UNC_PATH_RE.match(frag):
            return True
        if _WSL_MOUNT_RE.match(frag):
            return True
        lowered = frag.lower()
        if any(lowered.endswith(m) or lowered == m for m in _WINDOWS_INTEROP_MARKERS):
            return True
    return False


def _is_absolute_host_path(token: str, project_root: Optional[str] = None) -> bool:
    """True when a token carries an absolute host path OUTSIDE the Container.

    Absolute paths are a host-only signal because the file may not exist at the
    same location inside the Container (ADR 0013 / plan question 9 — only host
    paths *outside the mounted Project* are host-only). Refinements so a valid
    container/project-scoped path is not misflagged:

      * inline option forms (``--root=/home/alice/data``) and bind mounts
        (``--mount=type=bind,src=/home/alice:/data``) are caught by scanning
        every ``=``/``,`` fragment of the token;
      * for a ``source:destination`` mount fragment only the SOURCE side is
        considered — the destination (``cache:/data``, ``vol:/app``) is always
        container-internal;
      * absolute paths under a known container-internal root (``/app``,
        ``/workspace``, ``/home/node``, ``/tmp``, ...) are NOT host-only;
      * absolute paths under the candidate's own mounted Project root
        (``project_root``, e.g. the Claude project key ``/home/alice/app``) are
        NOT host-only — they are inside the mounted Project and visible in the
        Container;
      * ``/mnt/...`` Windows interop paths are handled by `_is_windows_path`;
      * URL authorities (``//host/...``) and a bare ``/`` are not host paths.
    """
    exempt_roots = list(_CONTAINER_INTERNAL_ROOTS)
    if project_root:
        # The Project mount makes paths under the project root container-visible
        # (plan question 9: only host paths *outside the mounted Project* are
        # host-only). The Claude project key is an absolute host path, so a
        # server argument under it is a project-local path, not host-only.
        exempt_roots.append(project_root.rstrip("/"))
    for frag in _path_fragments(token):
        side = _path_source_side(frag)
        if not side.startswith("/"):
            continue
        if side.startswith("//"):
            continue  # URL authority (``//host/...``), not a host file path
        if _WSL_MOUNT_RE.match(side):
            continue  # handled as a Windows path elsewhere
        if len(side) <= 1:
            continue  # bare ``/`` is not host-specific evidence
        normalized = side.rstrip("/")
        if any(
            normalized == root or normalized.startswith(root + "/")
            for root in exempt_roots
        ):
            continue  # resolves inside the Container, not host-only
        return True
    return False


# Standard system binary directories present in (almost) every Linux container
# with the same well-known interpreters/launchers. An absolute launcher under
# one of these (e.g. /usr/bin/python3) resolves to the same binary inside the
# Container, so it is NOT a host-only signal — unlike a host-specific launcher
# path such as /opt/homebrew/bin/npx or /home/alice/.local/bin/uvx.
_STANDARD_BIN_DIRS = (
    "/usr/local/bin/",
    "/usr/bin/",
    "/bin/",
    "/usr/local/sbin/",
    "/usr/sbin/",
    "/sbin/",
)


def _is_standard_bin_path(command: str) -> bool:
    """True when an absolute launcher path lives in a standard system bin dir."""
    return any(command.startswith(prefix) for prefix in _STANDARD_BIN_DIRS)


def _launcher_family(command: str) -> str:
    """Map the argv[0] command to a coarse family label for reasons text."""
    fam = _container_family(command)
    if fam == "node":
        return "npx/npm"
    if fam == "python":
        return "python/uv"
    if fam == "docker":
        return "docker"
    return "absolute-binary"


def _scan_indicators(haystacks: list[str], indicators: tuple[str, ...]) -> list[str]:
    """Return the subset of `indicators` found (case-insensitive) in any token."""
    found: list[str] = []
    lowered = [h.lower() for h in haystacks]
    for ind in indicators:
        if any(ind in h for h in lowered):
            found.append(ind)
    return found


def classify(candidate: Candidate) -> Classification:
    """Classify one candidate from evidence; return a fresh Classification.

    Does not mutate the candidate. Order of decision (strongest signal first):

      1. Already excluded (remote/hosted connector) -> keep as-is. Providers
         own that decision because it is certain from the transport alone.
      2. Windows/WSL2 host path -> host-only (high). Wrong OS boundary.
      3. Desktop/browser/clipboard/OS indicator -> host-only (high). Needs host
         state the Container cannot see.
      4. Display env (DISPLAY/WAYLAND) -> host-only (medium). Needs a GUI.
      5. Absolute host path in argv -> host-only (medium). The path may not
         exist in the Container; surfaced for user confirmation.
      6. Container-friendly launcher (npx/uvx/python/docker) with none of the
         above -> container. high when the spec is self-contained; medium when
         it carries required env (still container, but needs env wired up).
      7. Anything else (unknown command family, no clear signal) -> unknown
         (low). Needs manual confirmation or a dry-run probe (future slice).
    """
    cls = candidate.classification
    # 1. Respect a provider-assigned exclusion (remote/hosted connectors).
    if cls.placement == "excluded":
        return Classification(
            placement="excluded",
            confidence=cls.confidence or "high",
            reasons=list(cls.reasons) or ["unsupported remote/hosted connector"],
        )

    argv = list(candidate.command.argv)
    env_keys = list(candidate.command.env_keys)
    secret_env_keys = list(candidate.command.secret_env_keys)
    command = argv[0] if argv else ""
    rest = argv[1:]

    reasons: list[str] = []

    # 2. Windows / WSL2 path -> wrong OS boundary.
    win_hits = [t for t in argv if _is_windows_path(t)]
    if win_hits:
        reasons.append(
            "Windows/WSL2 host path or interop binary "
            f"({', '.join(win_hits[:3])}); refers to the wrong OS boundary "
            "inside the Container"
        )
        return Classification(
            placement="host-only", confidence="high", reasons=reasons
        )

    # 3. Desktop / browser / clipboard / OS indicators -> needs host state.
    scan_tokens = argv + env_keys
    desktop_hits = _scan_indicators(scan_tokens, _DESKTOP_INDICATORS)
    browser_hits = _scan_indicators(scan_tokens, _BROWSER_INDICATORS)
    if desktop_hits or browser_hits:
        hits = desktop_hits + browser_hits
        reasons.append(
            "desktop/browser/clipboard/OS indicator "
            f"({', '.join(hits[:3])}); needs host state the Container "
            "cannot see"
        )
        return Classification(
            placement="host-only", confidence="high", reasons=reasons
        )

    # 3b. Host credential agent / socket / keyring env -> host state only.
    host_res_hits = [
        k for k in env_keys if k.upper() in _HOST_RESOURCE_ENV_NAMES
    ]
    if host_res_hits:
        reasons.append(
            "references a host credential agent / socket "
            f"({', '.join(host_res_hits)}); that host resource is not shared "
            "into the Container"
        )
        return Classification(
            placement="host-only", confidence="high", reasons=reasons
        )

    # 4. GUI display env -> needs a host desktop session.
    display_hits = [k for k in env_keys if k.upper() in _DISPLAY_ENV_NAMES]
    if display_hits:
        reasons.append(
            f"references a display environment ({', '.join(display_hits)}); "
            "needs a host GUI session"
        )
        return Classification(
            placement="host-only", confidence="medium", reasons=reasons
        )

    # 5. Absolute host path argument -> may not exist in the Container.
    # Skip the launcher itself (argv[0]) — an absolute interpreter path like
    # /usr/bin/python3 is normal and resolves inside the Container.
    project_root = candidate.source_project
    host_paths = [
        t for t in rest if _is_absolute_host_path(t, project_root=project_root)
    ]
    if host_paths:
        reasons.append(
            "absolute host path in arguments "
            f"({', '.join(host_paths[:3])}); may not exist inside the "
            "Container — confirm before importing"
        )
        return Classification(
            placement="host-only", confidence="medium", reasons=reasons
        )

    # 5b. Absolute launcher path outside the Container -> host-only. A
    # container-friendly BASENAME (npx/uvx/...) is not enough if the launcher is
    # an absolute HOST path such as /opt/homebrew/bin/npx (macOS host) or
    # /home/alice/.local/bin/uvx: that exact path likely does not exist inside
    # the Container, so executing the inherited command as-is would fail. It is
    # surfaced for manual confirmation rather than reported as importable.
    # Standard system bin dirs (/usr/bin, /bin, ...) are exempt — an absolute
    # /usr/bin/python3 resolves to the same interpreter inside the Container.
    # A launcher UNDER the mounted Project or a boxa-mapped root is also
    # exempt (e.g. a project-local /home/alice/app/.venv/bin/python or
    # .../node_modules/.bin/server) — `_is_absolute_host_path` already applies
    # the container-internal and project-root exemptions, so reuse it here so
    # the launcher check stays consistent with the argument check.
    if (
        command.startswith("/")
        and not _is_standard_bin_path(command)
        and _is_absolute_host_path(command, project_root=project_root)
    ):
        reasons.append(
            f"absolute host launcher path ({command}); the binary likely does "
            "not exist at that path inside the Container — confirm before "
            "importing"
        )
        return Classification(
            placement="host-only", confidence="medium", reasons=reasons
        )

    # 6. Container-resolvable launcher, no host-only signal -> container.
    # Two ways to qualify:
    #   * a known container-friendly BASENAME (npx/uvx/python/docker/...),
    #     whether bare or behind any container-resolvable absolute path; or
    #   * an absolute launcher located UNDER the mounted Project or a
    #     boxa-mapped root (a project venv / node_modules launcher), which we
    #     KNOW exists in the Container because that tree is mounted — even when
    #     the basename is an unrecognized runtime.
    #
    # Deliberately NOT here: an absolute launcher under a standard system bin
    # dir whose basename is unknown (e.g. /usr/bin/custom-mcp). The path form is
    # plausible but boxa cannot know that exact host-installed binary exists
    # in the Container, so it falls through to the `unknown` manual-confirmation
    # branch rather than being reported as importable.
    is_known_family = bool(_container_family(command))
    is_project_local_abs = (
        command.startswith("/")
        and not _is_standard_bin_path(command)
        # 5b already returned host-only for absolute launchers OUTSIDE the
        # Container, so a non-standard-bin absolute command still here lives
        # under the project mount or a boxa-mapped root.
    )
    if is_known_family or is_project_local_abs:
        if is_known_family:
            family = _launcher_family(command)
            reasons.append(f"{family} launcher resolvable inside the Container")
        else:
            reasons.append(
                "project-local absolute launcher under the mounted Project "
                f"({command})"
            )
        reasons.append("no host-path, Windows, or desktop indicators")
        if env_keys:
            # Still a container candidate, but it needs env wired up; surface
            # the required/secret key NAMES (never values) so apply (issue 05)
            # can prompt for them.
            reasons.append(
                "requires environment variables: " + ", ".join(env_keys)
            )
            if secret_env_keys:
                reasons.append(
                    "secret environment variables (values not shown): "
                    + ", ".join(secret_env_keys)
                )
            confidence = "medium"
        else:
            confidence = "high"
        return Classification(
            placement="container", confidence=confidence, reasons=reasons
        )

    # 7. No clear signal -> unknown, needs manual confirmation.
    if command:
        reasons.append(
            f"unrecognized command family ({_launcher_family(command)}); "
            "cannot classify without manual confirmation or a dry-run probe"
        )
    else:
        reasons.append("no launch command found; cannot classify")
    return Classification(placement="unknown", confidence="low", reasons=reasons)


def classify_candidate(candidate: Candidate) -> Candidate:
    """Return the candidate with its classification replaced in place.

    Mutates and returns the same object (the merge pipeline reuses identity by
    object), keeping the candidate's spec untouched and only updating the
    placement/confidence/reasons.
    """
    candidate.classification = classify(candidate)
    return candidate
