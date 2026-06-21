# SSH

Private SSH keys are **never** mounted into the container. Instead, boxa uses
SSH **agent forwarding** — only the agent socket is shared, so the container can
request signatures but never reads the key material.

Inside the container, verify with `ssh-add -l` (it should list your keys).

Host `~/.ssh/config` and `~/.ssh/known_hosts` are **not mounted by default**, to
avoid leaking server addresses and usernames. GitHub SSH host keys are
pre-populated in the image, so `git push`/`pull` works out of the box.

## Boxa SSH config

To configure SSH hosts for use inside boxa without exposing your full host
config:

```bash
boxa ssh-config                # Show current config
boxa ssh-config add            # Add a host interactively
boxa ssh-config edit           # Open in $EDITOR
```

The config is stored in `~/.config/boxa/ssh_config` and is automatically
mounted into every container. Remember to also allow the domain in the
[firewall](firewall.md) (`boxa allow example.com`).

## Full host SSH config

To temporarily mount your full host `~/.ssh/config` and `~/.ssh/known_hosts`:

```bash
boxa --ssh-config              # Mount with host SSH config
boxa --ssh-config ~/project    # Specific project with host SSH config
```

This flag only takes effect on container creation. For a running container:
`boxa stop && boxa --ssh-config`.

**Cursor / VS Code** handle SSH agent forwarding automatically via the Dev
Containers extension.

## Persistent SSH agent on WSL2 (host setup)

By default, `ssh-agent` dies when you close your terminal. To keep it running
across all terminals, install `keychain` on the **host** (not inside boxa):

```bash
sudo apt install keychain
```

Add to your host `~/.zshrc` (or `~/.bashrc`):

```zsh
eval $(keychain --eval --quiet --agents ssh)
```

Add to `~/.ssh/config` (a private file, not in any public repo):

```
Host *
    AddKeysToAgent yes
```

This starts one `ssh-agent` per boot, shared across all terminals. Keys are
added automatically on first SSH use (the passphrase is prompted once per boot).
No key names are exposed in your shell config.

### Alternative approaches

| Method | Needs systemd? | Extra install? | Complexity |
|---|---|---|---|
| `keychain` (recommended) | No | `keychain` pkg | Low |
| systemd user service | Yes (`systemd=true` in `wsl.conf`) | None | Low |
| Fixed socket path in `.zshrc` | No | None | Low |
| npiperelay (Windows agent bridge) | No | `socat` + `npiperelay.exe` | Medium |

## See also

- [Networking](networking.md) — allow the host's domain in the firewall before
  reaching it over SSH.
- [Editors](editors.md) — Cursor / VS Code forward the agent automatically.
