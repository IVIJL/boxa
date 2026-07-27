"""Constrained node-side launcher for service-isolated Docker MCP servers."""

from __future__ import annotations

import os
from typing import Any, Optional


class DockerAdapterError(RuntimeError):
    pass


_BOOLEAN_FLAGS = {"-i", "--interactive", "--rm"}
_ENV_FLAGS = {"-e", "--env"}


def parse_declared_run(argv: list[str]) -> tuple[str, list[str]]:
    """Return image + image command from a deliberately tiny Docker grammar.

    Catalog definitions may declare only ``docker run``, stdio/removal flags,
    and environment declarations.  Environment values are reconstructed from
    catalog metadata/secret staging, never trusted from the original argv.
    Everything capable of changing mounts, namespaces, privileges, devices,
    capabilities, daemon selection, or networking is rejected.
    """
    if len(argv) < 3 or os.path.basename(argv[0]).lower() != "docker" or argv[1] != "run":
        raise DockerAdapterError("Docker MCP command must be 'docker run <image>'")
    i = 2
    while i < len(argv):
        value = argv[i]
        if value in _BOOLEAN_FLAGS:
            i += 1
            continue
        if value in _ENV_FLAGS:
            i += 2
            if i > len(argv):
                raise DockerAdapterError("Docker MCP environment flag is missing its value")
            continue
        if value.startswith("-e=") or value.startswith("--env="):
            i += 1
            continue
        if value.startswith("-"):
            raise DockerAdapterError(
                "Docker MCP option before the image is outside the constrained Docker launch policy"
            )
        image = value
        if not image or image.startswith("-"):
            raise DockerAdapterError("Docker MCP image is invalid")
        return image, list(argv[i + 1 :])
    raise DockerAdapterError("Docker MCP command has no image")


def project_cwd(project: str, requested_cwd: Optional[str]) -> str:
    project = os.path.realpath(project)
    if requested_cwd:
        candidate = os.path.realpath(requested_cwd)
        try:
            if os.path.commonpath((project, candidate)) == project:
                return candidate
        except ValueError:
            pass
    return project


def build_plan(
    entry: dict[str, Any], catalog_id: str, consumer: str, project: str,
    requested_cwd: Optional[str], environment: dict[str, str],
) -> dict[str, Any]:
    if entry.get("executionMode") != "service-isolated" or entry.get("runtimeKind") != "docker":
        raise DockerAdapterError("entry is not a service-isolated Docker MCP")
    if not os.path.isabs(project) or "," in project or "\x00" in project:
        raise DockerAdapterError(
            "Project path cannot be represented safely in a Docker mount"
        )
    source = entry.get("command", {}).get("argv")
    if not isinstance(source, list) or any(not isinstance(v, str) for v in source):
        raise DockerAdapterError("Docker MCP command is malformed")
    image, command = parse_declared_run(source)
    declared = set(entry.get("envKeys", [])) | set(entry.get("secretEnvKeys", []))
    if set(environment) != declared:
        raise DockerAdapterError("Docker MCP plan environment keys differ from the catalog declaration")
    cwd = project_cwd(project, requested_cwd)
    if "," in cwd or "\x00" in cwd:
        cwd = project
    argv = [
        "docker", "run", "--rm", "-i", "--pull=never",
        "--mount", f"type=bind,src={project},dst={project}",
        "--workdir", cwd,
    ]
    for key in sorted(environment):
        argv.extend(["--env", f"{key}={environment[key]}"])
    argv.append(image)
    argv.extend(command)
    return {
        "executionMode": "service-isolated",
        "adapter": "docker",
        "catalogId": catalog_id,
        "consumer": consumer,
        "project": project,
        "image": image,
        "command": command,
        "environment": dict(environment),
        "argv": argv,
        "cwd": project,
    }


def validate_plan_shape(
    plan: dict[str, Any], entry: dict[str, Any], catalog_id: str, consumer: str,
    project: str, requested_cwd: Optional[str],
) -> dict[str, Any]:
    env = plan.get("environment")
    if not isinstance(env, dict) or any(
        not isinstance(k, str) or not isinstance(v, str) for k, v in env.items()
    ):
        raise DockerAdapterError("Docker MCP plan environment is malformed")
    secret_keys = set(entry.get("secretEnvKeys", []))
    catalog_env = entry.get("env", {})
    if not isinstance(catalog_env, dict):
        raise DockerAdapterError("Docker MCP catalog environment is malformed")
    for key, value in env.items():
        if key not in secret_keys and catalog_env.get(key) != value:
            raise DockerAdapterError(
                "Docker MCP non-secret environment differs from host-owned catalog state"
            )
    expected = build_plan(entry, catalog_id, consumer, project, requested_cwd, env)
    if plan != expected:
        raise DockerAdapterError("Docker MCP launch plan does not match host-owned catalog state")
    return expected
