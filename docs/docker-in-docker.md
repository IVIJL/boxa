# Docker-in-Docker (rootless)

Every boxa container includes a **full rootless Docker daemon**. It starts
automatically on container launch and supports `docker build`, `docker run`, and
`docker compose`. This is what lets you "install nothing, anywhere": venvs,
Vite, npm, Postgres and the like all run in nested throwaway containers, so
neither the host nor the box itself gets polluted.

```bash
# Inside boxa:
docker run hello-world
docker compose up -d
docker build -t myapp .
```

## How it works

Docker runs as the `node` user via `dockerd-rootless.sh` — **no `--privileged`
flag, no host socket mounting**. The daemon uses `fuse-overlayfs` as the storage
driver and `slirp4netns` for networking.

**Security:** the container runs with `seccomp=unconfined`,
`apparmor=unconfined`, `systempaths=unconfined`, and `CAP_SYS_ADMIN` (all
required by rootless Docker for user namespaces and sysctl access). Devices
`/dev/net/tun` and `/dev/fuse` are exposed for networking and storage. The
container is **not** privileged — an escape would require a kernel exploit.

The image itself is **built locally from a Dockerfile you can read** — there is
no prebuilt registry image to pull, no opaque binary blob, and no supply-chain
surface beyond the upstream `node:22-trixie` base that boxa audits and pins. See
[ADR 0018](adr/0018-local-first-no-prebuilt-image.md) for the local-first
rationale.

## Docker data persistence

Docker data is stored in a per-project named volume (`boxa-<project>-docker`).
Images, Compose volumes, anonymous volumes, and bind-mounted data persist across
`boxa stop`. Use `boxa stop --clean` or `boxa remove` when the Project's Docker
data should be removed explicitly.

## UID and GID mapping

The inner daemon uses an identity subordinate-ID map with a hole at `U`, the
actual runtime UID of the Container's `node` user. The entrypoint regenerates
both `/etc/subuid` and `/etc/subgid` on every start; Project Compose files do
not participate in the mapping.

| Mapping | Subordinate ranges | Host owner for inner UID `N` |
| ------- | ------------------ | ---------------------------- |
| Old fixed map | `node:100000:65536` | `100000 + N - 1` |
| Identity map | `node:1:(U-1)` and `node:(U+1):(65536-U)` | `N` below `U`; `N+1` at or above `U` |

Inner container root is separate from those ranges and maps to host UID `U`,
not host root. Consequently inner UID `U` maps to `U+1`. The ranges deliberately
contain neither host UID 0 nor `U`; for `U=1`, the empty first range is omitted.

The per-Project Docker volume carries a `.boxa-subid-map` stamp. On the first
start after upgrading from the old fixed map, Boxa detects an unstamped,
non-empty data-root and remaps UID and GID ownership throughout it before
starting the daemon. Progress and final counts are printed, and the stamp is
written only after success. If the walk fails, an old owner cannot be
represented, or the stamp is unknown, the daemon refuses to start and directs
the user to run `boxa stop --clean <project>` on the host. A fresh empty volume
is stamped without a walk.

The data-root remains `/home/node/.local/share/docker` in the
`boxa-<project>-docker` volume. Moving it onto the Container's overlay rootfs
would introduce nested overlayfs and has been observed to fail with `EINVAL`.

## Graceful shutdown

Explicit `boxa stop` discovers running and exited inner containers before it
stops the outer Container. Each Compose project is brought down with Compose's
dependency ordering, its configured service grace periods, and orphan removal.
Unmanaged inner containers are gracefully stopped and removed in parallel.
This recreates container writable layers and Compose-owned networks on the next
`docker compose up`; it does not explicitly remove images, bind mounts, named
volumes, or anonymous volumes.

The container also uses `boxa-entrypoint.sh` as PID 1, which traps `SIGTERM` and
provides a deliberately simpler emergency fallback when the outer Container
receives a direct signal. It discovers only currently running inner containers,
starts their graceful stops concurrently, and waits best-effort for all of them.
It does not inspect Compose metadata or remove containers, networks, or volumes,
so stopped container records remain for the next start.

The outer Container is configured with `--stop-timeout 45`. Normal `boxa stop`
uses that configured deadline rather than shortening it; direct Docker or
`SIGTERM` shutdown remains bounded by the same outer deadline even if an inner
stop fails or stalls.

## Windows shutdown hook

When Windows shuts down or restarts, WSL2 is terminated abruptly without sending
`SIGTERM` to processes inside. This causes containers to exit with code 255
instead of a clean shutdown.

To fix this, install the Windows shutdown hook that stops all Docker containers
**before** WSL2 terminates:

```powershell
# Run as Administrator in PowerShell
powershell -ExecutionPolicy Bypass -File scripts\windows\install-shutdown-hook.ps1
```

This registers a shutdown script via the Windows registry (works on Home edition
without `gpedit.msc`). The script runs automatically during shutdown, stops all
running containers in parallel with a 15s timeout, and logs to
`C:\Scripts\boxa\shutdown.log`.

To uninstall:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\uninstall-shutdown-hook.ps1
```

## Reaching another box from an inner container

Inner containers run on their own nested network and cannot resolve other
boxes on `devproxy` directly. To let an inner compose service reach a published
TCP port in *another* box, use `boxa connect` and dial `10.0.2.2:<local-port>`
from the inner container. See
[Cross-boxa connections](networking.md#cross-boxa-connections).

## See also

- [Cross-boxa connections](networking.md#cross-boxa-connections) — reach a TCP
  service in another box from an inner container.
- [ADR 0003](adr/0003-privileged-entrypoint-no-sudo-in-container.md) — privileged
  entrypoint instead of in-container sudo.
- [ADR 0018](adr/0018-local-first-no-prebuilt-image.md) — local-first: no
  prebuilt registry image.
