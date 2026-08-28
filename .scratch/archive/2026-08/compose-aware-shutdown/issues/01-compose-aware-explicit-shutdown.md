# 01 — Compose-aware explicit shutdown

Status: done

## Parent

ADR 0035 — Compose-aware inner shutdown.

## What to build

Deliver the happy-path tracer bullet for explicit Project shutdown. Before an
outer Container stops, a dedicated in-Container shutdown helper discovers all
Inner containers, including stopped ones, and groups Compose-managed workloads
by Compose project name, working directory, and complete config-file set.

Independent Compose projects are brought down concurrently with dependency-aware
Compose semantics and orphan removal. Boxa does not override service shutdown
grace periods. Unmanaged inner containers are gracefully stopped and removed in
parallel with those projects. A final sweep removes remaining container records
and verifies an empty inner container list. The helper is used by named stop,
explicit stop-all, and the interactive stop-all happy paths, while preserving
the existing parallelism between outer Containers.

Normal output identifies logical Compose projects and unmanaged containers
without relaying routine Compose noise. Update the user documentation to explain
that explicit Boxa stop now matches Compose down semantics: container writable
layers and Compose-owned networks are recreated later, while images, bind mounts,
and volumes remain unless the user explicitly requests clean data removal.

## Acceptance criteria

- [ ] Discovery includes running and exited Inner containers and groups each
      Compose project by name, working directory, and all config files.
- [ ] Independent Compose projects shut down concurrently through Compose with
      dependency ordering and orphan removal; Boxa supplies no Compose timeout.
- [ ] Unmanaged inner containers receive a graceful stop and are then removed,
      concurrently with Compose projects.
- [ ] Named stop, explicit stop-all, and interactive stop-all all invoke the same
      shutdown behavior while outer Containers retain batch parallelism.
- [ ] A successful shutdown leaves inner `docker ps -a` empty and prints concise
      project-level progress rather than routine Compose output.
- [ ] Images, named volumes, anonymous volumes, and bind-mounted data are not
      explicitly removed; the existing clean-data option remains the exception.
- [ ] Fast shell tests cover discovery, grouping, parallel launch, unmanaged
      cleanup, final sweep, output, and all explicit stop entry points.
- [ ] An opt-in real-Docker test proves reverse dependency shutdown order, an
      empty inner container list, and named-volume persistence across teardown;
      without its opt-in gate or a reachable suitable daemon it skips loudly.
- [ ] The integration proof runs against a disposable isolated daemon or
      Container, never sweeps the caller's Docker daemon, and removes only its
      own uniquely named resources on success, failure, or interruption.
- [ ] Every changed shell script passes `shellcheck` including informational
      findings, apart from documented false positives.

## Blocked by

None — can start immediately.

## Comments
