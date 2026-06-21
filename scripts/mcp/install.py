"""Materialize an existing MCP profile entry into persistent runtime (issue 09).

Import (issue 05) preserves the inherited launch command by default, e.g.
``npx -y @upstash/context7-mcp@latest``. This module is the optional
materialization step ADR 0013 ("Preserve imported commands by default;
materialize optionally") describes: ``boxa mcp install <server>`` installs the
server's runtime into a persistent boxa location and rewrites the canonical
profile entry to launch the materialized command, so the wrapper later launches
the persistent binary instead of re-fetching the package on every start.

What this module owns (runs INSIDE a Container, where the runtime lives):

  * resolve a profile entry in the scope-correct profile (global or project),
    refusing unknown / disabled / host-only / excluded / non-Container servers
    with a clear, SECRET-FREE message;
  * classify the runtime family from ``argv[0]`` (npm/npx, docker, python/uv);
  * for npm/npx: install the package into the EXISTING persistent npm-global
    prefix when safe, then rewrite the profile command to the materialized
    binary and mark the entry ``materialized``;
  * for docker: pull the image into the Project-scoped rootless Docker state
    (image-backed servers stay Project-scoped per ADR 0013) and mark it
    materialized without rewriting the launch command (``docker run`` already
    references the now-local image);
  * for python/uv: report clearly that a clean persistent location / dedicated
    MCP runtime volume is needed before proceeding, rather than smuggling state
    into an unrelated mount (ADR 0013);
  * on a BLOCKED network failure, point the user at ``boxa blocked`` and show
    the exact rerun command (the firewall workflow ADR 0013 mandates).

The Allow-for window orchestration (open before / close after the attempt,
``--keep-window``, container targeting / picker) is HOST-side and lives in the
shell front-end ``scripts/mcp-cli.sh`` — the ``boxa`` CLI runs on the host,
not in the Container, so it cannot run here.

SECRET-FREE: nothing here reads or emits a secret VALUE. The profile carries env
NAMES only; install never touches the 0600 secret store.
"""

from __future__ import annotations

import os
import shlex
import subprocess  # noqa: S404 - install genuinely shells out to npm/docker
from dataclasses import dataclass, field
from typing import Any, Optional

from .profile import (
    global_profile_path,
    load_profile,
    project_profile_path,
    save_profile,
)

# Runtime families derived from argv[0] (the launcher). Mirrors the coarse
# labels the list views use, but install only branches on these three.
_NODE_LAUNCHERS = {"npx", "npm", "pnpm", "yarn", "bunx", "bun", "node"}
_PYTHON_LAUNCHERS = {"uvx", "uv", "python", "python3", "pipx"}
_DOCKER_LAUNCHERS = {"docker", "podman"}

# A run-from-package launcher (``npx``/``bunx``) fetches the package on every
# start; materializing it replaces that with a persistent global install. A bare
# ``node``/``npm`` invocation is already pointing at something local, so there is
# nothing to fetch — install treats it as already materialized.
_NODE_FETCH_LAUNCHERS = {"npx", "bunx"}

# Other fetch-on-launch Node forms use a launcher + subcommand: ``pnpm dlx``,
# ``yarn dlx``, ``npm exec``, ``bun x``. These ALSO re-download on every start,
# so they must NOT be reported as already-materialized. v1 does not auto-rewrite
# them (the package/binary extraction differs per launcher); install reports a
# clear "convert to npx first" message rather than falsely claiming success.
_NODE_DLX_SUBCOMMANDS = {
    "pnpm": {"dlx", "exec"},
    "yarn": {"dlx"},
    "npm": {"exec"},
    "bun": {"x"},
}

# Substrings that, in a failed install's combined output, signal the boxa
# firewall denied a network destination (default-deny, ADR 0001) rather than a
# genuine package error. Lower-cased before matching. Kept deliberately broad:
# a false positive only adds the (correct) "open an Allow-for window" hint.
_BLOCKED_SIGNATURES = (
    "could not resolve host",
    "getaddrinfo",
    "network is unreachable",
    "connection refused",
    "connection reset",
    "connection timed out",
    "etimedout",
    "econnrefused",
    "econnreset",
    "enotfound",
    "eai_again",
    "temporary failure in name resolution",
    "request to https",  # npm: "request to https://… failed, reason: …"
    "fetch failed",
    "tls handshake",
    "i/o timeout",  # docker: "dial tcp … i/o timeout"
    "proxyconnect",  # docker: blocked registry behind the firewall
)


class InstallError(RuntimeError):
    """An install failure with a user-actionable, SECRET-FREE message."""


class UnsupportedRuntimeError(InstallError):
    """The server's runtime family cannot be materialized in v1.

    Distinct from a hard failure so the CLI can present it as a clear "not
    supported yet / needs a dedicated runtime volume" message rather than an
    error the user might retry.
    """


class BlockedNetworkError(InstallError):
    """The install attempt failed on what looks like a blocked network access.

    Carries the exact rerun command so the CLI can point the user at
    ``boxa blocked`` and the trusted-domain review workflow (ADR 0013).
    """

    def __init__(self, message: str, rerun_command: str) -> None:
        super().__init__(message)
        self.rerun_command = rerun_command


@dataclass
class RunResult:
    """Outcome of one shelled-out command (returncode + combined output)."""

    returncode: int
    output: str


class Executor:
    """Runs install commands and resolves binaries in the TARGET runtime.

    The canonical MCP profile lives on the HOST (``~/.config/boxa/mcp``); the
    npm/Docker RUNTIME lives inside a boxa **Container**. So ``install_server``
    reads and rewrites the profile in-process on the host, but every command
    that touches the runtime — ``npm install -g``, ``docker pull``, and the
    post-install ``which`` probe — must execute inside the Container. This
    executor is the seam for that: a ``command_prefix`` (e.g.
    ``["docker", "exec", "-u", "node", "<container>"]``) is prepended to every
    command and ``which`` probe, so the host driver runs them in the Container.

    With an empty prefix the executor runs locally — used when install runs
    directly inside a Container, and by the unit tests' stub subclass (which
    overrides the methods entirely so nothing is ever shelled out for real).
    """

    def __init__(self, command_prefix: Optional[list[str]] = None) -> None:
        self.command_prefix = list(command_prefix or [])

    def run(self, argv: list[str]) -> RunResult:
        """Run a command in the target runtime, capturing combined output."""
        full = [*self.command_prefix, *argv]
        try:
            proc = subprocess.run(  # noqa: S603 - argv list, no shell, trusted
                full,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
        except OSError as exc:
            return RunResult(returncode=127, output=str(exc))
        return RunResult(returncode=proc.returncode, output=proc.stdout or "")

    def which(self, name: str) -> Optional[str]:
        """Resolve a command's absolute path in the target runtime, or None.

        Runs ``command -v <name>`` in the runtime (POSIX, works inside the
        Container's shell) rather than the host's ``shutil.which`` — the binary
        that matters is the one on the Container's PATH, not the host's.
        """
        result = self.run(["sh", "-c", f"command -v {shlex.quote(name)}"])
        if result.returncode != 0:
            return None
        path = result.output.strip().splitlines()
        return path[0] if path and path[0].startswith("/") else (
            path[0] if path else None
        )


@dataclass
class InstallResult:
    """Outcome of a materialization (SECRET-FREE)."""

    name: str
    scope: str
    project_key: str
    runtime: str
    materialized: bool  # True when the profile entry was (re)materialized
    already_materialized: bool = False  # True when nothing needed doing
    profile_path: str = ""
    # The launcher command the profile now records (argv[0]); informational.
    installed_command: str = ""
    # Human-readable actions taken (commands run, profile rewrite), names only.
    actions: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "name": self.name,
            "scope": self.scope,
            "runtime": self.runtime,
            "materialized": self.materialized,
            "alreadyMaterialized": self.already_materialized,
            "profilePath": self.profile_path,
            "installedCommand": self.installed_command,
            "actions": list(self.actions),
        }
        if self.project_key:
            out["project"] = self.project_key
        return out


def _runtime_family(argv: list[str]) -> str:
    """Coarse runtime family for the launcher argv[0], or "" when unknown."""
    if not argv:
        return ""
    base = os.path.basename(str(argv[0])).lower()
    if base in _NODE_LAUNCHERS:
        return "node"
    if base in _PYTHON_LAUNCHERS:
        return "python"
    if base in _DOCKER_LAUNCHERS:
        return "docker"
    return ""


def _profile_path_for(scope: str, project_key: Optional[str]) -> str:
    if scope == "project":
        if not project_key:
            raise InstallError("project scope requires a project key")
        return project_profile_path(project_key)
    if scope == "global":
        return global_profile_path()
    raise InstallError(f"unknown scope {scope!r}")


def _load_target_spec(
    path: str, name: str, scope: str, project_key: Optional[str]
) -> dict:
    """Load and validate one profile server for install, or raise InstallError.

    Refuses (with clear, SECRET-FREE messages) every case ADR 0013 / issue 09
    require: an unreadable profile, an unknown server, a disabled server, a pure
    project disable-override (no command of its own), and a non-Container
    placement recorded on the entry. Returns the validated spec.
    """
    where = f"project {project_key}" if scope == "project" else "global"
    try:
        profile = load_profile(path)
    except (OSError, ValueError) as exc:
        raise InstallError(f"cannot read the {where} MCP profile: {exc}") from exc

    servers = profile.get("servers")
    if not isinstance(servers, dict):
        raise InstallError(
            f"malformed MCP profile ('servers' missing or not an object): {path}"
        )

    spec = servers.get(name)
    if not isinstance(spec, dict):
        known = sorted(n for n in servers if isinstance(servers[n], dict))
        hint = f" Known servers: {', '.join(known)}." if known else ""
        raise InstallError(
            f"no boxa MCP server named {name!r} in the {where} profile.{hint} "
            "Import or add a server first ('boxa mcp import --apply')."
        )

    if spec.get("enabled") is False:
        raise InstallError(
            f"MCP server {name!r} is disabled in the {where} profile; enable it "
            f"with 'boxa mcp enable {name}' before installing."
        )

    # A Project DISABLE OVERRIDE carries no command of its own — there is nothing
    # to materialize (ADR 0013 / issue 08 override shape).
    command = spec.get("command")
    if "command" not in spec or not isinstance(command, dict):
        raise InstallError(
            f"MCP server {name!r} in the {where} profile has no launch command "
            "to materialize (it may be a project disable override)."
        )

    # ADR 0013: v1 materializes Container MCP servers only. A host-only/excluded
    # entry should never reach the profile (apply refuses them), but if a future
    # provider records a placement, honour it defensively.
    placement = spec.get("placement")
    if isinstance(placement, str) and placement not in ("", "container"):
        raise InstallError(
            f"MCP server {name!r} is classified {placement!r}; only Container MCP "
            "servers can be materialized in this version."
        )
    return spec


def _scan_for_blocked(output: str) -> bool:
    """True when a failed command's output looks like a blocked network access."""
    low = output.lower()
    return any(sig in low for sig in _BLOCKED_SIGNATURES)


def _rerun_command(name: str, scope: str, project_key: Optional[str]) -> str:
    """The exact ``boxa mcp install`` command to rerun after allowing domains."""
    if scope == "project" and project_key:
        return f"boxa mcp install {name} --project {project_key}"
    return f"boxa mcp install {name} --global"


def _raise_for_failure(
    result: RunResult,
    *,
    name: str,
    scope: str,
    project_key: Optional[str],
    runtime: str,
) -> None:
    """Map a non-zero command result to a Blocked or generic InstallError.

    A blocked-network signature points the user at ``boxa blocked`` and the
    rerun command (ADR 0013 firewall workflow); anything else is a generic
    install failure carrying the command's own output. The package-manager
    output is not a boxa secret, so it is safe to surface.
    """
    rerun = _rerun_command(name, scope, project_key)
    snippet = result.output.strip()
    if _scan_for_blocked(result.output):
        raise BlockedNetworkError(
            f"installing {name!r} failed on a blocked network access "
            f"(exit {result.returncode}). The boxa firewall is default-deny: "
            "the install tried to reach a destination that is not on the "
            "Allowlist.\n"
            "Review the blocked destinations and allow the trusted ones:\n"
            "  boxa blocked\n"
            "Then rerun the install (or open an Allow-for window first):\n"
            f"  {rerun}\n"
            f"  {rerun} --allow-for 15\n"
            + (f"\nCommand output:\n{snippet}" if snippet else ""),
            rerun_command=rerun,
        )
    raise InstallError(
        f"installing {name!r} failed (exit {result.returncode}, runtime "
        f"{runtime}).\n"
        + (f"Command output:\n{snippet}" if snippet else "No output captured.")
    )


# -- npm / npx ----------------------------------------------------------------


@dataclass
class _NpxSpec:
    """Parsed npx/bunx launch: the package to install + how to launch it.

    ``package`` is the npm package to ``npm install -g``. ``binary`` is the
    executable name the materialized command should run, and ``binary_args`` are
    the arguments to pass it. Two npx forms:

      * IMPLICIT (``npx -y pkg arg1``): the package IS the run target, so the
        binary name is derived from the package and the trailing tokens are its
        args. ``explicit_binary`` is False (the real bin name may differ from the
        package name, so we must verify it on PATH).
      * EXPLICIT-PACKAGE (``npx -p pkg some-bin --flag``): the package and the
        executable are DIFFERENT. ``binary`` is the named executable verbatim and
        ``binary_args`` follow it. ``explicit_binary`` is True — the launch
        target is exactly what the user named, not a guess.
    """

    package: str
    binary: str
    binary_args: list[str]
    explicit_binary: bool


def _parse_npx(argv: list[str]) -> Optional[_NpxSpec]:
    """Parse an ``npx``/``bunx`` launch argv into an _NpxSpec, or None.

    Returns None when no package can be identified (e.g. ``npx`` with only
    flags). Distinguishes the implicit form from the ``-p/--package`` explicit
    form so a server launched as ``npx -p pkg bin --flag`` materializes to
    ``bin --flag`` (the named executable), not a guessed package binary.
    """
    i = 1  # skip argv[0] launcher
    n = len(argv)
    explicit_package: Optional[str] = None
    while i < n:
        tok = str(argv[i])
        if tok in ("-y", "--yes", "--prefer-online", "--prefer-offline"):
            i += 1
            continue
        if tok in ("-p", "--package"):
            if i + 1 >= n:
                return None
            explicit_package = str(argv[i + 1])
            i += 2
            continue
        if tok.startswith("--package="):
            explicit_package = tok[len("--package="):]
            i += 1
            continue
        if tok.startswith("-"):
            # An unrecognized flag — skip it (no value consumed; npx boolean
            # flags dominate, and a value flag we do not know is rare here).
            i += 1
            continue
        # First positional token.
        if explicit_package is not None:
            # Explicit-package form: this positional is the EXECUTABLE to run,
            # which is distinct from the package. Launch it verbatim.
            return _NpxSpec(
                package=explicit_package,
                binary=tok,
                binary_args=[str(a) for a in argv[i + 1 :]],
                explicit_binary=True,
            )
        # Implicit form: the positional IS the package and the run target.
        return _NpxSpec(
            package=tok,
            binary=_npm_binary_name(tok),
            binary_args=[str(a) for a in argv[i + 1 :]],
            explicit_binary=False,
        )
    # Reached the end with a -p package but no executable positional: npx would
    # run the package's own bin, so treat it like the implicit form.
    if explicit_package is not None:
        return _NpxSpec(
            package=explicit_package,
            binary=_npm_binary_name(explicit_package),
            binary_args=[],
            explicit_binary=False,
        )
    return None


def _npm_binary_name(package_spec: str) -> str:
    """Derive the on-PATH binary name an npm package installs.

    Best-effort: strip a leading scope (``@scope/``) and any ``@version`` suffix,
    leaving the bare package name, which is the binary name for the common case
    (``@upstash/context7-mcp@latest`` -> ``context7-mcp``). When the real bin
    name differs, the wrapper's launch would fail clearly and the user can rerun;
    install never claims a binary exists without verifying it on PATH below.
    """
    spec = package_spec
    if spec.startswith("@"):
        # Scoped: @scope/name@version -> name@version, then drop the version.
        slash = spec.find("/")
        if slash != -1:
            spec = spec[slash + 1 :]
    # Drop a trailing @version (not the scope's @, already removed above).
    at = spec.find("@")
    if at > 0:
        spec = spec[:at]
    return spec


def _install_node(
    argv: list[str], executor: Executor, result: InstallResult, name: str,
    scope: str, project_key: Optional[str],
) -> list[str]:
    """Materialize an npx/bunx server into the persistent npm-global prefix.

    Installs the package with ``npm install -g`` (which lands in the existing
    ``boxa-npm-global`` persistent prefix inside the Container) and rewrites the
    profile command to launch the now-on-PATH binary directly. Returns the new
    argv to store, or raises InstallError / BlockedNetworkError on failure.

    A non-fetching node launcher (a bare ``node`` / ``npm run`` style command)
    has nothing to fetch, so it is reported already-materialized and the command
    is left unchanged.
    """
    launcher = os.path.basename(str(argv[0])).lower()
    # A fetch-on-launch launcher + subcommand form (``pnpm dlx``, ``yarn dlx``,
    # ``npm exec``, ``bun x``) re-downloads every start, so it is NOT already
    # materialized — but v1 does not auto-rewrite it. Refuse with a clear message
    # rather than falsely report success.
    dlx_subs = _NODE_DLX_SUBCOMMANDS.get(launcher)
    if dlx_subs and len(argv) > 1 and str(argv[1]) in dlx_subs:
        raise UnsupportedRuntimeError(
            f"MCP server {name!r} uses {launcher} {argv[1]} (a fetch-on-launch "
            "form) which boxa cannot auto-materialize yet. Re-import or add the "
            "server with an 'npx -y <package>' command, then install it. The "
            "server still launches via its current command."
        )
    if launcher not in _NODE_FETCH_LAUNCHERS:
        result.already_materialized = True
        result.actions.append(
            f"launcher {launcher!r} runs a local command already; nothing to "
            "fetch or materialize"
        )
        return list(argv)

    spec = _parse_npx(argv)
    if spec is None:
        raise InstallError(
            f"could not determine the npm package to install from the {name!r} "
            f"launch command ({' '.join(argv)})."
        )

    if executor.which("npm") is None:
        raise UnsupportedRuntimeError(
            "npm is not available in this Container; add Node.js to the "
            "Dockerfile so npm-global materialization is possible."
        )

    install_argv = ["npm", "install", "-g", spec.package]
    result.actions.append(f"running: {' '.join(install_argv)}")
    run = executor.run(install_argv)
    if run.returncode != 0:
        _raise_for_failure(
            run, name=name, scope=scope, project_key=project_key, runtime="node"
        )

    resolved = executor.which(spec.binary)
    if not resolved:
        if spec.explicit_binary:
            # ``npx -p pkg bin`` named an executable that is not on PATH after
            # installing the package. Do not rewrite to a command that will not
            # launch; keep the working npx command and report it honestly.
            raise InstallError(
                f"installed {spec.package!r}, but its named executable "
                f"{spec.binary!r} is not on PATH afterward. The profile command "
                "was left unchanged so the server still launches via npx."
            )
        # Implicit form: the package's real bin name differs from our guess. Keep
        # the working npx command rather than write a broken one.
        raise InstallError(
            f"installed {spec.package!r}, but could not find its executable "
            f"{spec.binary!r} on PATH afterward. The profile command was left "
            "unchanged so the server still launches via npx. If the binary has a "
            "different name, materialization is not applied automatically yet."
        )

    result.actions.append(f"resolved binary {spec.binary!r} -> {resolved}")
    # Launch the resolved binary with the original arguments preserved.
    return [resolved, *spec.binary_args]


# -- docker -------------------------------------------------------------------


# ``docker run`` option flags that take a SEPARATE value token, so the image
# scanner skips the flag AND its value. Kept broad to cover common MCP launch
# commands (``--platform``, ``--entrypoint``, …). An unknown value-taking flag
# not listed here would be treated as boolean and its value mistaken for the
# image — but ``docker pull`` of a wrong reference then fails VISIBLY (it is not
# a silent corruption), and the user can adjust the imported command.
_DOCKER_VALUE_FLAGS = {
    "-e", "--env", "--env-file",
    "-v", "--volume", "--mount",
    "-p", "--publish", "--expose",
    "--name", "--hostname", "-h",
    "-w", "--workdir",
    "--network", "--net", "--ip", "--add-host", "--dns",
    "-u", "--user",
    "--platform", "--entrypoint",
    "-l", "--label", "--label-file",
    "--device", "--cap-add", "--cap-drop",
    "--memory", "-m", "--cpus", "--restart", "--pull",
    "--health-cmd", "--log-driver", "--security-opt",
}


def _docker_image_from_argv(argv: list[str]) -> Optional[str]:
    """Extract the image reference from a ``docker run`` launch argv.

    ``docker run -i --rm -e FOO ghcr.io/org/img:tag mcp`` -> ``ghcr.io/org/img:tag``.
    The image is the first positional token after ``run`` and its option flags;
    known value-taking flags (``_DOCKER_VALUE_FLAGS``, e.g. ``-e``, ``-v``,
    ``--platform``, ``--entrypoint``) are skipped together with their value.
    Returns None when no image is found.
    """
    n = len(argv)
    # Find the ``run`` subcommand.
    i = 1
    while i < n and str(argv[i]) != "run":
        i += 1
    if i >= n:
        return None
    i += 1  # skip ``run``
    while i < n:
        tok = str(argv[i])
        if tok in _DOCKER_VALUE_FLAGS:
            i += 2  # skip the flag and its value
            continue
        if "=" in tok and tok.startswith("-"):
            i += 1  # inline-value flag (e.g. --env=FOO=bar, --platform=linux/amd64)
            continue
        if tok.startswith("-"):
            i += 1  # boolean flag (e.g. -i, --rm)
            continue
        return tok  # first positional == image
    return None


def _install_docker(
    argv: list[str], executor: Executor, result: InstallResult, name: str,
    scope: str, project_key: Optional[str],
) -> list[str]:
    """Materialize a docker-backed server by pulling its image into local state.

    Docker-backed MCP servers are Project-scoped (ADR 0013 decision 15): image
    state lives in the per-project rootless Docker volume and does not generalize
    across projects. A GLOBAL Docker install is therefore REFUSED — pulling into
    one project's Docker state then marking a global entry materialized would
    leave the image missing for every other project that inherits the global
    server. The user must install it per project instead.

    For a project install, ``docker pull`` lands the image in that project's
    Docker state. The launch command is NOT rewritten — ``docker run <image>``
    already references the now-local image. Returns the unchanged argv, or raises.
    """
    if scope != "project" or not project_key:
        raise UnsupportedRuntimeError(
            f"MCP server {name!r} is Docker-backed; image state is Project-scoped "
            "(ADR 0013), so it cannot be materialized globally. Install it for a "
            f"specific Project: 'boxa mcp install {name} --project <name-or-path>'."
        )
    # Use the SAME container engine the launch command names (docker or podman),
    # so the image lands in the engine that ``<engine> run`` will look in. Pulling
    # with docker while the command runs podman would leave podman without the
    # image even though the profile is marked materialized.
    engine = os.path.basename(str(argv[0])).lower()
    image = _docker_image_from_argv(argv)
    if not image:
        raise InstallError(
            f"could not determine the container image from the {name!r} launch "
            f"command ({' '.join(argv)})."
        )
    if executor.which(engine) is None:
        raise UnsupportedRuntimeError(
            f"{engine} is not available in this Container; rootless Docker (DinD) "
            "must be running to materialize a container-backed MCP server."
        )
    pull_argv = [engine, "pull", image]
    result.actions.append(f"running: {' '.join(pull_argv)}")
    run = executor.run(pull_argv)
    if run.returncode != 0:
        _raise_for_failure(
            run, name=name, scope=scope, project_key=project_key, runtime="docker"
        )
    result.actions.append(
        f"pulled image {image!r} into Project-scoped {engine} state"
    )
    return list(argv)


# -- orchestration ------------------------------------------------------------


def install_server(
    name: str,
    scope: str,
    project_key: Optional[str] = None,
    executor: Optional[Executor] = None,
) -> InstallResult:
    """Materialize one profile server's runtime and update the canonical profile.

    The canonical profile lives on the HOST and is read/rewritten here in
    process; the runtime install COMMANDS run wherever ``executor`` points
    (inside the target Container when the host driver passes a ``docker exec``
    command prefix). Resolves the scope-correct profile entry, refuses anything
    that is not an enabled Container MCP server with a launch command, dispatches
    on the runtime family, runs the install through ``executor``, and — on
    success — rewrites the profile command to the materialized launcher and marks
    the entry ``materialized``. Returns a SECRET-FREE outcome.

    Raises:
      * ``UnsupportedRuntimeError`` for python/uv (needs a clean persistent
        location / dedicated MCP runtime volume), a global Docker install
        (image state is Project-scoped), or a missing runtime tool;
      * ``BlockedNetworkError`` when the install fails on a blocked destination;
      * ``InstallError`` for any other resolution / install failure.
    """
    exec_ = executor or Executor()
    path = _profile_path_for(scope, project_key)
    spec = _load_target_spec(path, name, scope, project_key)

    command = spec.get("command")
    argv_raw = command.get("argv") if isinstance(command, dict) else None
    argv = [str(a) for a in argv_raw] if isinstance(argv_raw, list) else []
    if not argv:
        raise InstallError(
            f"MCP server {name!r} has an empty launch command; nothing to "
            "materialize."
        )

    family = _runtime_family(argv)
    result = InstallResult(
        name=name,
        scope=scope,
        project_key=project_key or "",
        runtime=family or "unknown",
        materialized=False,
        profile_path=path,
    )

    if family == "node":
        new_argv = _install_node(argv, exec_, result, name, scope, project_key)
    elif family == "docker":
        new_argv = _install_docker(argv, exec_, result, name, scope, project_key)
    elif family == "python":
        # ADR 0013: Python/uv has no clean shared persistent location yet. Rather
        # than smuggle state into an unrelated mount, refuse and explain that a
        # dedicated MCP runtime volume is needed first.
        raise UnsupportedRuntimeError(
            f"MCP server {name!r} uses a Python/uv runtime ({argv[0]!r}). "
            "Boxa has no clean persistent location for uv/Python MCP installs "
            "yet; a dedicated MCP runtime volume is needed before this can be "
            "materialized. The server still launches via its imported command. "
            "Tracked as future work in ADR 0013."
        )
    else:
        raise UnsupportedRuntimeError(
            f"MCP server {name!r} uses an unrecognized runtime ({argv[0]!r}); "
            "only npm/npx (node) and Docker-backed servers can be materialized "
            "in this version."
        )

    # Persist the (possibly rewritten) command and the materialized marker. We
    # reload the profile to write back so a concurrent edit during a long
    # network install is not clobbered by a stale in-memory copy.
    profile = load_profile(path)
    servers = profile.get("servers")
    if not isinstance(servers, dict) or not isinstance(servers.get(name), dict):
        raise InstallError(
            f"MCP server {name!r} disappeared from the profile during install; "
            "nothing was rewritten."
        )
    entry = servers[name]
    if new_argv != argv:
        entry["command"] = {"argv": list(new_argv)}
        result.actions.append(
            f"rewrote profile launch command to: {' '.join(new_argv)}"
        )
    entry["materialized"] = True
    save_profile(path, profile)

    result.materialized = True
    result.installed_command = new_argv[0] if new_argv else ""
    return result
