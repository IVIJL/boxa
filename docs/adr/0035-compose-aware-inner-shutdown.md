# ADR 0035 — Compose-aware inner shutdown

- **Status:** accepted
- **Date:** 2026-08-27

## Context

Boxa currently stops every running **Inner container** through one flat
`docker stop` operation. That ignores Compose dependency order, misses already
stopped containers, and leaves container records in the Project's persistent
Docker volume. A later `boxa up` therefore exposes stale `Exited` containers,
and concurrently stopping dependencies can make otherwise fast application
shutdowns consume the full timeout.

## Decision

Explicit `boxa stop <project>` and `boxa stop --all` perform a Compose-aware
teardown before stopping each outer **Container**. They discover all inner
containers, including stopped ones, and group Compose-managed containers by
project name, working directory, and config files. Compose projects are brought
down concurrently with `docker compose down --remove-orphans`, preserving each
service's configured shutdown grace period. Unmanaged inner containers are
gracefully stopped and removed concurrently. Images and volumes are preserved.
The existing explicit `boxa stop --clean <project>` behavior remains the
exception and removes the Project's Docker data after shutdown.

After the first teardown pass, Boxa sweeps remaining inner containers and
verifies that `docker ps -a` is empty. Missing Compose metadata or config files
degrade with a visible warning to graceful stop plus removal. If cleanup cannot
be completed or verified, Boxa still stops and removes every requested outer
Container, but the command returns non-zero after the batch finishes.

The outer stop uses the Container's configured stop timeout instead of
overriding it with fifteen seconds. PID 1 remains a simpler emergency fallback:
on direct SIGTERM it stops running inner containers concurrently but does not
attempt Compose discovery or removal.

## Consequences

`boxa stop` removes inner container writable layers and Compose-owned networks;
the next `docker compose up` recreates them while reusing preserved volumes and
images. Compose projects retain their dependency-aware shutdown semantics, and
parallelism remains between independent Compose projects, unmanaged containers,
and outer Boxa Containers.
