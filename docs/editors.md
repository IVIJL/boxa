# Editor support

Boxa is built on the [Dev Containers](https://containers.dev) standard, so any
editor that speaks `devcontainer.json` can attach to a running box.

| Editor | Status |
|--------|--------|
| VS Code | Supported |
| Cursor | Supported |
| Zed | Planned (SSH remote — see [ROADMAP](../ROADMAP.md)) |

## VS Code / Cursor

Both attach the same way and forward your SSH agent automatically via the Dev
Containers extension.

### This repository (boxa itself)

Open this folder in Cursor / VS Code, then run **Dev Containers: Reopen in
Container**. It picks up `.devcontainer/devcontainer.json` automatically.

### Any other project

You can drive a project's box entirely from the CLI:

```bash
boxa cursor [name]             # Open Cursor attached to a running box
boxa code [name]               # Open VS Code attached to a running box
```

To make a project reopen in a boxa container directly from the editor, add a
minimal `.devcontainer/devcontainer.json` to it. Reference the boxa image you
already built locally with `boxa build` — `ivijl/boxa:latest`. This is **not** a
registry pull: boxa is local-first (no prebuilt registry image, see
[ADR 0018](adr/0018-local-first-no-prebuilt-image.md)); you build the image once
from a Dockerfile you can read, then every project reuses that local tag. (This
is exactly what boxa's own `.devcontainer/cursor/devcontainer.json` does.)

```jsonc
{
  "name": "Boxa",
  "image": "ivijl/boxa:latest",
  "runArgs": [
    "--security-opt", "seccomp=unconfined",
    "--security-opt", "apparmor=unconfined",
    "--security-opt", "systempaths=unconfined",
    "--cap-add=SYS_ADMIN",
    "--cap-add=NET_ADMIN",
    "--cap-add=NET_RAW",
    "--device=/dev/net/tun",
    "--device=/dev/fuse"
  ],
  "remoteUser": "node",
  "workspaceFolder": "/workspace"
}
```

See `devcontainer-standalone.json` in the repo for the full reference config the
CLI uses, including the mounts and the `postStartCommand` that brings up the
firewall, rootless Docker, and chezmoi.

## Zed (planned)

[Zed](https://zed.dev/) remote support is on the [roadmap](../ROADMAP.md): Zed
would connect into a running container over SSH (Zed's remote-development mode),
the same way Cursor / VS Code attach today via Dev Containers. The
agent-forwarding and [SSH config](ssh.md) plumbing boxa already exposes is the
foundation for it.

## See also

- [SSH](ssh.md) — agent forwarding and host config, used by both attach flows.
- [Docker-in-Docker](docker-in-docker.md) — why boxa builds locally rather than
  pulling a prebuilt image.
