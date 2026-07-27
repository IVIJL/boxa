"""Deterministic per-catalog-entry, per-Project MCP readiness (ADR 0021)."""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass, field
from typing import Any, Optional

from .catalog import CatalogError, load_catalog, resolve_entry, update_entry
from .install import _docker_image_from_argv, _npm_binary_name, _parse_npx
from .docker_adapter import DockerAdapterError, parse_declared_run
from .secrets import project_secrets_path, read_server_secrets


class ReadinessError(RuntimeError):
    pass


@dataclass(frozen=True)
class Check:
    kind: str
    label: str
    ready: bool
    detail: str = ""

    def to_dict(self) -> dict[str, Any]:
        value: dict[str, Any] = {
            "kind": self.kind,
            "label": self.label,
            "ready": self.ready,
        }
        if self.detail:
            value["detail"] = self.detail
        return value


@dataclass
class ReadinessReport:
    entry: dict[str, Any]
    project_key: str
    container: str
    checks: list[Check] = field(default_factory=list)

    @property
    def ready(self) -> bool:
        return bool(self.container) and all(check.ready for check in self.checks)

    @property
    def missing(self) -> list[Check]:
        return [check for check in self.checks if not check.ready]

    def to_dict(self) -> dict[str, Any]:
        return {
            "entry": self.entry,
            "projectKey": self.project_key,
            "container": self.container,
            "ready": self.ready,
            "checks": [check.to_dict() for check in self.checks],
            "missing": [check.to_dict() for check in self.missing],
        }


@dataclass
class InstallReport:
    entry: dict[str, Any]
    project_key: str
    container: str
    actions: list[str]
    readiness: ReadinessReport

    def to_dict(self) -> dict[str, Any]:
        return {
            "entry": self.entry,
            "projectKey": self.project_key,
            "container": self.container,
            "actions": self.actions,
            "readiness": self.readiness.to_dict(),
            "activated": False,
        }


class ProjectProbe:
    """Docker-backed local probe; all methods are replaceable in unit tests."""

    def __init__(self, docker_bin: str = "docker") -> None:
        self.docker_bin = docker_bin

    def _run(
        self, container: str, argv: list[str], *, user: str
    ) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(
                [self.docker_bin, "exec", "-u", user, container, *argv],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
        except OSError as exc:
            raise ReadinessError(f"cannot run local readiness probe: {exc}") from exc

    def find_running(self, project_key: str) -> Optional[str]:
        try:
            result = subprocess.run(
                [
                    self.docker_bin,
                    "ps",
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
            return None
        for container in (result.stdout or "").splitlines():
            inspect = subprocess.run(
                [
                    self.docker_bin,
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
            marker = f"BOXA_PROJECT_HOST_PATH={project_key}"
            if inspect.returncode == 0 and marker in (inspect.stdout or "").splitlines():
                return container
        return None

    def command_path(self, container: str, command: str, user: str) -> Optional[str]:
        result = self._run(
            container,
            ["sh", "-c", 'command -v -- "$1"', "sh", command],
            user=user,
        )
        return (result.stdout or "").strip().splitlines()[0] if result.returncode == 0 else None

    def path_is(self, container: str, path: str, kind: str, user: str) -> bool:
        flag = {"file": "-f", "socket": "-S"}[kind]
        return self._run(container, ["test", flag, path], user=user).returncode == 0

    def credential_present(
        self,
        container: str,
        project_key: str,
        server_name: str,
        key: str,
        user: str,
    ) -> bool:
        """Check the Project-scoped store in-process; never return its value."""
        block = read_server_secrets(project_secrets_path(project_key), server_name)
        return bool(block and block.get(key))

    def image_exists(self, container: str, engine: str, image: str) -> bool:
        return self._run(
            container, [engine, "image", "inspect", image], user="node"
        ).returncode == 0

    def codex_logged_in(self, container: str) -> bool:
        return self._run(
            container, ["codex", "login", "status"], user="node"
        ).returncode == 0

    def install_npm(self, container: str, package: str) -> None:
        result = self._run(
            container, ["npm", "install", "-g", package], user="node"
        )
        if result.returncode != 0:
            raise ReadinessError(
                f"npm materialization failed (exit {result.returncode}): "
                f"{(result.stdout or '').strip()}"
            )

    def pull_image(self, container: str, engine: str, image: str) -> None:
        result = self._run(container, [engine, "pull", image], user="node")
        if result.returncode != 0:
            raise ReadinessError(
                f"image pull failed (exit {result.returncode}): "
                f"{(result.stdout or '').strip()}"
            )


def _execution_user(entry: dict[str, Any]) -> str:
    return "node" if entry.get("executionMode") == "agent-trusted" else "boxa-mcp"


def _runtime_check(entry: dict[str, Any], container: str, probe: ProjectProbe) -> Check:
    argv = entry["command"]["argv"]
    kind = entry["runtimeKind"]
    user = _execution_user(entry)
    if kind == "docker":
        engine = os.path.basename(argv[0]).lower()
        if entry.get("executionMode") == "service-isolated":
            try:
                image, _command = parse_declared_run(argv)
            except DockerAdapterError as exc:
                return Check(
                    "runtime",
                    "constrained Docker launch policy",
                    False,
                    str(exc),
                )
        else:
            image = _docker_image_from_argv(argv)
        if not image:
            return Check("runtime", "Docker image declaration", False, "command has no image")
        ready = probe.image_exists(container, engine, image)
        return Check("runtime", f"Docker image {image}", ready, "available locally" if ready else "missing locally")
    if kind == "node" and os.path.basename(argv[0]).lower() in {"npx", "bunx"}:
        spec = _parse_npx(argv)
        binary = spec.binary if spec else ""
        return Check(
            "runtime",
            f"materialized npm executable {binary or '<unknown>'}",
            False,
            "not materialized (fetch-on-launch catalog command)",
        )
    ready = bool(probe.command_path(container, argv[0], user))
    return Check("runtime", f"executable {argv[0]}", ready, "available locally" if ready else "missing locally")


def readiness(
    token: str,
    project_key: str,
    probe: Optional[ProjectProbe] = None,
) -> ReadinessReport:
    """Evaluate only local runtime/prerequisite state; never contact a service."""
    try:
        _entry_id, entry = resolve_entry(load_catalog(), token)
    except CatalogError as exc:
        raise ReadinessError(str(exc)) from exc
    return readiness_for_entry(
        entry,
        project_key,
        probe,
        secret_name=str(entry.get("secretStoreKey") or entry["name"]),
    )


def readiness_for_entry(
    entry: dict[str, Any],
    project_key: str,
    probe: Optional[ProjectProbe] = None,
    *,
    secret_name: Optional[str] = None,
) -> ReadinessReport:
    """Evaluate a supplied replacement definition without publishing it.

    Catalog lifecycle preflight uses this seam so every activated Project can
    prove the proposed runtime before any host-owned state changes.
    """
    probe = probe or ProjectProbe()
    container = probe.find_running(project_key)
    if not container:
        raise ReadinessError(
            f"target Boxa for {project_key} is not running; readiness never starts it implicitly"
        )
    checks = [_runtime_check(entry, container, probe)]
    user = _execution_user(entry)
    prerequisites = entry.get("prerequisites", {})
    for path in prerequisites.get("files", []):
        checks.append(Check("file", path, probe.path_is(container, path, "file", user), "declared file"))
    for path in prerequisites.get("sockets", []):
        checks.append(Check("socket", path, probe.path_is(container, path, "socket", user), "declared socket"))
    declared_env = set(entry.get("env", {}))
    credential_keys = sorted(
        (
            set(entry.get("envKeys", []))
            | set(entry.get("secretEnvKeys", []))
            | set(prerequisites.get("credentials", []))
        )
        - declared_env
    )
    for key in credential_keys:
        if entry.get("executionMode") == "agent-trusted":
            # Agent-trusted launches never read the MCP secret store or inherit
            # ambient values. A non-secret variable must have an explicit value
            # in catalog env (already removed from credential_keys above).
            checks.append(
                Check("credential", key, False, "not explicitly declared")
            )
        else:
            # Only the key and presence bit cross the probe boundary; never the value.
            present = probe.credential_present(
                container, project_key, secret_name or entry["name"], key, user
            )
            checks.append(Check("credential", key, present, "present" if present else "missing"))
    for local_probe in prerequisites.get("probes", []):
        if local_probe == "codex-login-status":
            checks.append(Check("credential", "Codex login", probe.codex_logged_in(container), "local codex login status"))
    return ReadinessReport(dict(entry), project_key, container, checks)


def install(
    token: str,
    project_key: str,
    probe: Optional[ProjectProbe] = None,
) -> InstallReport:
    """Prepare runtime in an already-running Project; never activate or render."""
    try:
        _entry_id, entry = resolve_entry(load_catalog(), token)
    except CatalogError as exc:
        raise ReadinessError(str(exc)) from exc
    probe = probe or ProjectProbe()
    container = probe.find_running(project_key)
    if not container:
        raise ReadinessError(
            f"target Boxa for {project_key} is not running; install never starts it implicitly"
        )
    argv = entry["command"]["argv"]
    actions: list[str] = []
    kind = entry["runtimeKind"]
    if kind == "node" and os.path.basename(argv[0]).lower() in {"npx", "bunx"}:
        spec = _parse_npx(argv)
        if spec is None:
            raise ReadinessError(f"cannot determine npm package for {entry['name']!r}")
        probe.install_npm(container, spec.package)
        resolved = probe.command_path(container, spec.binary, _execution_user(entry))
        if not resolved:
            raise ReadinessError(
                f"installed npm package {spec.package!r}, but executable {spec.binary!r} is missing"
            )
        entry = update_entry(entry["id"], argv=[resolved, *spec.binary_args])
        actions.append(f"materialized npm package {spec.package!r} in persistent npm-global")
    elif kind == "docker":
        engine = os.path.basename(argv[0]).lower()
        if entry.get("executionMode") == "service-isolated":
            try:
                image, _command = parse_declared_run(argv)
            except DockerAdapterError as exc:
                raise ReadinessError(str(exc)) from exc
        else:
            image = _docker_image_from_argv(argv)
        if not image:
            raise ReadinessError(f"cannot determine Docker image for {entry['name']!r}")
        probe.pull_image(container, engine, image)
        actions.append(f"pulled image {image!r} into Project Docker storage")
    else:
        actions.append("runtime is a direct local command; nothing to install")
    report = readiness(entry["id"], project_key, probe)
    return InstallReport(dict(entry), project_key, container, actions, report)
