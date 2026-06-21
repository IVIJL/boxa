"""Host-initiated MCP secret re-stage into running Containers (ADR 0014, issue 17).

A secret VALUE change (an ``import --apply`` / ``add`` that copies a credential,
or a rotation) is captured at Container start by the entrypoint root phase, so a
change made while a Container is already running needs a re-stage. ADR 0014
mandates this be **host-initiated** — a momentary ``docker exec -u 0`` at the
same trust level as starting the Container — NOT a persistent in-container root
watcher (which would reintroduce the residual-root surface ADR 0003 removes).

This module owns the TARGETING decision and drives the re-stage; it never copies
or reads a secret itself. The actual copy is the SAME reusable staging step the
entrypoint uses (``scripts/stage-mcp-secrets.sh`` ->
``mcp.cli stage-secrets`` -> ``mcp.staging``): ``reload`` only invokes it inside
each in-scope running Container via a momentary root exec. Because that script,
run with no arguments, stages a Container's OWN scope from that Container's own
environment (``BOXA_PROJECT_HOST_PATH``, the gated host mount, the private
staged dir), a single bare invocation per Container is least-privilege by
construction:

  * a GLOBAL secret change reaches **every** running boxa Container, and each
    one re-stages only its own scope (global + its own Project) — never another
    Project's secrets;
  * a PROJECT secret change reaches only **that Project's** Container.

The momentary exec leaves no residual root process (it runs the staging step and
exits). SECRET-FREE: nothing here logs a secret VALUE; the staging step it calls
reports scope labels + basenames only.
"""

from __future__ import annotations

import subprocess  # noqa: S404 - reload genuinely shells out to docker exec
from dataclasses import dataclass, field
from typing import Optional

# The in-Container path of the reusable staging front-end (Dockerfile installs
# scripts/stage-mcp-secrets.sh here). Run with no arguments it stages the
# Container's OWN in-scope secrets from the Container's environment — the exact
# same step the entrypoint root phase runs at start.
STAGE_SCRIPT = "/usr/local/bin/stage-mcp-secrets"


class ReloadError(RuntimeError):
    """A reload failure with a user-actionable, SECRET-FREE message."""


@dataclass
class ContainerReload:
    """Outcome of re-staging one Container (SECRET-FREE)."""

    container: str
    ok: bool
    # The staging step's own (secret-free) stdout/stderr, surfaced on failure so
    # the user sees why a re-stage did not land. Empty on success.
    output: str = ""


@dataclass
class ReloadResult:
    """Result of a reload pass across the targeted running Containers.

    ``scope_label`` describes what was reloaded (``global`` or ``project <name>``)
    for the human summary. ``reloaded`` lists every Container the momentary root
    exec ran in; ``not_running`` names a requested Project Container that was not
    running (a no-op, not an error — secrets stage at its next start).
    SECRET-FREE: container names + scope labels only.
    """

    scope_label: str
    reloaded: list[ContainerReload] = field(default_factory=list)
    not_running: list[str] = field(default_factory=list)

    @property
    def any_failed(self) -> bool:
        return any(not c.ok for c in self.reloaded)

    def to_dict(self) -> dict[str, object]:
        return {
            "scope": self.scope_label,
            "reloaded": [
                {"container": c.container, "ok": c.ok} for c in self.reloaded
            ],
            "notRunning": list(self.not_running),
        }


class DockerExec:
    """Lists running boxa Containers and runs the momentary root re-stage.

    Injectable for the same reason ``mcp.install.Executor`` /
    ``mcp.projects.VolumeProbe`` are: the real implementation shells out to
    ``docker``, which is unavailable (and must never run) in the unit tests.
    Tests subclass this and override the two methods with stubs, so targeting is
    exercised without a real ``docker``.

    ``docker_bin`` is overridable so a caller can point at ``podman`` or an
    absolute path; it defaults to ``docker`` on PATH.
    """

    def __init__(self, docker_bin: str = "docker") -> None:
        self.docker_bin = docker_bin

    def running_boxa_containers(self) -> list[str]:
        """Return the names of RUNNING user boxa Project Containers.

        Mirrors the shell front-end's ``_running_boxa_containers``: the
        ``boxa-`` project-name prefix excludes the shared infrastructure
        containers (boxa_traefik, boxa_dns, …) which use an underscore.
        """
        try:
            proc = subprocess.run(  # noqa: S603 - argv list, no shell, trusted
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
            return []
        if proc.returncode != 0:
            return []
        return [line for line in (proc.stdout or "").splitlines() if line.strip()]

    def restage(self, container: str) -> ContainerReload:
        """Momentary ``docker exec -u 0`` of the reusable staging step.

        Runs the staging front-end as root (UID 0) inside the named Container so
        it can read the host 0600 secret files through the gated mount and chown
        the staged copies to ``boxa-mcp`` — exactly as the entrypoint root
        phase does at start. The exec runs the step and exits; no root process
        lingers (ADR 0003). The staged-step output is SECRET-FREE.
        """
        try:
            proc = subprocess.run(  # noqa: S603 - argv list, no shell, trusted
                [self.docker_bin, "exec", "-u", "0", container, STAGE_SCRIPT],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                check=False,
            )
        except OSError as exc:
            return ContainerReload(container=container, ok=False, output=str(exc))
        return ContainerReload(
            container=container,
            ok=proc.returncode == 0,
            output="" if proc.returncode == 0 else (proc.stdout or "").strip(),
        )


def reload_secrets(
    scope: str,
    container_name: Optional[str] = None,
    project_label: Optional[str] = None,
    docker: Optional[DockerExec] = None,
) -> ReloadResult:
    """Re-stage secrets into the in-scope running Container(s).

    Targeting (ADR 0014):

      * ``scope == "global"`` -> re-stage EVERY running boxa Container. Each
        one stages only its own scope (global + its own Project) because the
        staging step reads the Container's own environment, so no Container ever
        receives another Project's secrets.
      * ``scope == "project"`` -> re-stage only ``container_name`` (this
        Project's Container), and only if it is currently running. When it is not
        running this is a no-op recorded in ``not_running`` — the changed secret
        stages at the Container's next start, so this is not an error.

    Every re-stage is a momentary ``docker exec -u 0`` of the SAME staging step
    the entrypoint runs (no second copy of stage logic; no persistent root). The
    ``project_label`` is a display name for the summary only. Returns a
    SECRET-FREE :class:`ReloadResult`.
    """
    docker = docker or DockerExec()
    running = docker.running_boxa_containers()

    if scope == "global":
        result = ReloadResult(scope_label="global")
        for container in running:
            result.reloaded.append(docker.restage(container))
        return result

    if scope == "project":
        if not container_name:
            raise ReloadError("a project reload requires a target container name")
        label = project_label or container_name
        result = ReloadResult(scope_label=f"project {label}")
        if container_name in running:
            result.reloaded.append(docker.restage(container_name))
        else:
            result.not_running.append(container_name)
        return result

    raise ReloadError(f"unknown reload scope {scope!r}")
