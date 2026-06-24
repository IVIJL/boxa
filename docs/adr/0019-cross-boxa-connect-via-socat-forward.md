# ADR 0019 — Cross-boxa connections via per-source socat forward

- **Status:** accepted
- **Date:** 2026-06-24

## Context

A common multi-project workflow is one box's app talking to another box's
service: `web` reaching the Postgres or API that lives in `api`. Boxa already
runs every container on the shared `devproxy` network (ADR 0007 builds the local
DNS + Traefik routing on top of it), so a process running **directly** in box
`web` can reach `boxa-api:<port>` by container name with no extra setup —
verified: `devproxy` peers resolve via the Docker embedded DNS and the firewall
accepts the whole `devproxy` /24 (`init-firewall.sh` derives `HOST_NETWORK` from
the default-route gateway and `ACCEPT`s it in both directions).

That direct path is **not** enough, because the workload users actually run is
not the box's main process — it is **Docker-in-Docker** (ADR 0018, the
"install nothing" model). Inner compose containers sit on their own nested
rootless-dockerd network, are **not** attached to `devproxy`, and therefore
cannot resolve `boxa-api` at all. The thing that needs to reach across boxes is
exactly the thing that can't.

Options considered for closing that gap:

1. **Attach inner containers to `devproxy`.** Requires every project's compose
   file to opt into an external boxa-managed network, leaks boxa's topology into
   user compose files, and breaks the clean nesting boundary DinD gives us.
2. **Document `boxa-api:<port>` and tell users to wire it themselves.** Only
   works for the box's main process, not inner containers — i.e. not the real
   use case — and offers no discovery, no persistence, no status.
3. **A managed forward owned by the source box.** A small relay inside the
   source box that inner containers can dial through a stable local address.

## Decision

`boxa connect` installs a **per-source `socat` TCP forward inside the source
box** and persists it so it survives restarts.

- `boxa connect <target> <port> [local-port] [--from source]` runs, inside the
  source container, `socat TCP-LISTEN:<local-port>,bind=127.0.0.1,fork
  TCP:boxa-<target>:<port>`. The listener bridges the source box's loopback to
  the target box over `devproxy`.
- **Inner containers consume it at `10.0.2.2:<local-port>`** — the
  rootless-dockerd (slirp4netns) gateway address, which from an inner container
  routes to the source box's own loopback where `socat` listens. The source
  box's main shell can use `localhost:<local-port>` directly.
- **Local ports are auto-allocated from 15000–15999**, deterministically from a
  checksum of `source:target:port`, so re-running `boxa connect` for the same
  pair is idempotent and returns the same port. An explicit `local-port`
  overrides allocation.
- **Only published TCP ports are connectable.** The interactive picker discovers
  targets by reading inner `docker ps` `ports:` mappings in the target box;
  services reachable only on the target's internal compose network are not
  offered. The forward points at the target's published host port,
  `boxa-<target>:<host-port>`.
- **Forwards are persisted and self-healing.** Each source box's connections
  live in `~/.config/boxa/connect/<source>.tsv`; `start_boxa_connections`
  replays them on container start, so connections survive `boxa stop` / restart.
- **`boxa connections`** lists every forward with a live `STATUS`: `up`
  (listener holds the local port), `down` (source running, no listener — a dead
  forward), or `stopped` (source box not running).

## Rationale

- **It targets the actual use case.** The gap is inner-container → other-box, and
  a source-side forward with a stable `10.0.2.2:<port>` address is the only
  option that serves it without dragging boxa's network into user compose files.
- **The trust/topology boundary stays put.** No inner container joins
  `devproxy`; the forward is an explicit, user-initiated relay owned by the
  source box, consistent with the DinD isolation of ADR 0018.
- **Idempotent and durable by construction.** Deterministic port allocation plus
  TSV persistence and start-time replay mean `boxa connect` is safe to re-run and
  connections do not silently evaporate on restart.

## Consequences

**Positive:**

- Inner compose services in one box can reach published services in another via
  a stable `10.0.2.2:<local-port>` with no compose-file changes.
- Connections are discoverable (`boxa connect` picker), inspectable
  (`boxa connections`), and persistent across restarts.

**Negative / limitations:**

- **Only published (`ports:`) TCP services** are connectable; a service exposed
  only on the target's internal compose network is invisible to the picker.
- Each forward is a long-lived `socat` process inside the source box; a target
  that is down leaves the forward `down` until the target returns (the listener
  itself stays up).
- The 15000–15999 pool caps a single source box at 1000 simultaneous forwards
  (far beyond any realistic need).

## References

- `docker-run.sh` — `MODE=connect` / `MODE=connections` handlers;
  `start_container_connection` (the `socat` invocation),
  `discover_published_tcp_services`, `allocate_connection_port` (15000–15999),
  `start_boxa_connections` (start-time replay).
- `docs/networking.md` — "Cross-boxa connections" user-facing section.
- `docs/docker-in-docker.md` — the nested-network boundary this ADR bridges.
- ADR 0007 — local DNS + `devproxy` routing this builds on.
- ADR 0018 — the Docker-in-Docker "install nothing" model that creates the gap.
