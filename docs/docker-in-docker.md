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

Docker images and containers are stored in a per-project named volume
(`boxa-<project>-docker`), so they survive container restarts without
re-pulling images. Volumes persist across `boxa stop` but can be cleaned with
`boxa stop --clean` or `boxa remove`.

## Graceful shutdown

The container uses `boxa-entrypoint.sh` as PID 1, which traps `SIGTERM` and
gracefully stops all inner DinD containers before exiting. This prevents
database corruption on `boxa stop` or host reboot.

The shutdown chain: host Docker → `SIGTERM` → entrypoint trap → `docker stop`
inner containers → inner processes flush/shutdown → entrypoint exits.
Additionally, `boxa stop` runs a pre-stop hook that explicitly stops inner
containers before sending `SIGTERM` to the entrypoint (belt-and-suspenders).

The container uses `--stop-timeout 45` to allow sufficient time for inner
containers with databases to shut down cleanly.

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

## See also

- [ADR 0003](adr/0003-privileged-entrypoint-no-sudo-in-container.md) — privileged
  entrypoint instead of in-container sudo.
- [ADR 0018](adr/0018-local-first-no-prebuilt-image.md) — local-first: no
  prebuilt registry image.
