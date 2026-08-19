# SSH

Boxa controls SSH agent forwarding with the **SSH gate**. The gate is off by
default: a newly created Container receives no host agent socket and has no
`SSH_AUTH_SOCK`. Enable it only for Projects that need SSH signing.

Run these commands on the host:

```bash
boxa ssh                         # Show the effective state for the current Project
boxa ssh on                      # Enable for the current Project
boxa ssh off                     # Disable for the current Project
boxa ssh on ~/projects/my-app    # Enable for a specific Project
boxa ssh on --global             # Enable globally
boxa ssh off --global            # Disable globally
```

Project choices override the global choice. Boxa stores both in
`~/.config/boxa/ssh.conf`, using absolute host paths for Project sections:

```ini
agent = off

[/home/me/projects/my-app]
agent = on
```

Changes take effect only when the Container is created. If the affected
Container is already running, Boxa prints the required restart command:
`boxa stop && boxa`. Every Container start also reports whether SSH is not
forwarded, forwarded with the agent's key names, or enabled but unavailable or
empty.

The **SSH gate** controls only the signing socket. It does not control the
separate [Boxa SSH config](#boxa-ssh-config) mount, and it does not grant network
access to an SSH server. Allow an external server through the
[Allowlist](firewall.md), or use a [Host connection](networking.md#host-connections)
for a service on the host.

## Key picker

`boxa ssh add` opens the consent-first **Key picker**. `boxa ssh on` opens the
same flow when the host agent is not running or contains no keys.

Before looking in `~/.ssh`, Boxa asks permission. If you decline, the picker
still offers manual path entry. If you consent, candidate discovery uses file
names and file types only; Boxa never opens private key files. It may read the
comment from a matching public `.pub` file to improve the label. You can select
multiple candidates or enter a path manually.

The selected key is loaded by `ssh-add`, which asks for its passphrase when
needed. Boxa first lets `ssh-add` test the key non-interactively. If that
succeeds, the key has no passphrase and Boxa prints a warning with the command
to protect it. Boxa never loads a key without this explicit Key picker action
and never invokes `ssh-add` during Container creation.

## Security model

A forwarded agent socket is full signing authority over **every key currently
loaded in that agent**. Code in the Container cannot read the private key bytes,
but it can ask the agent to sign and can therefore authenticate anywhere those
keys and the available network permit. The SSH gate does not filter individual
keys.

Keep the gate off where SSH is unnecessary, load only the keys you intend to
expose, and protect private keys with passphrases. Boxa never reads private key
material and never calls `ssh-add` on its own; only a user-confirmed Key picker
action causes a load.

## Migration and first install

Fresh installs and existing users upgrading from the old always-forwarded
behaviour receive the same one-time prompt to enable the SSH gate globally.
The default answer is **No**. Declining leaves the gate off and records the
choice so Boxa does not ask again. A non-interactive install or update leaves
the gate off without recording a choice, so a later interactive run can ask.

You can change the decision at any time with `boxa ssh on|off --global` or add
a Project override with `boxa ssh on|off [project|path]`.

## Boxa SSH config

The **Boxa SSH config** contains host aliases, addresses, and usernames without
granting signing authority or exposing the full host SSH config:

```bash
boxa ssh-config                # Show current config
boxa ssh-config add            # Add a host interactively
boxa ssh-config edit           # Open in $EDITOR
```

It is stored at `~/.config/boxa/ssh_config`. When present, Boxa mounts it
read-only by default, independently of the SSH gate. Remember to allow an
external host in the [firewall](firewall.md) (`boxa allow example.com`).

## Full host SSH config

To mount the full host `~/.ssh/config` and `~/.ssh/known_hosts` instead of the
Boxa SSH config:

```bash
boxa --ssh-config              # Current Project
boxa --ssh-config ~/project    # Specific Project
```

This flag also takes effect only at Container creation. For a running
Container, use `boxa stop && boxa --ssh-config`.

Attaching with Cursor or VS Code does not change the SSH gate chosen when Boxa
created the Container. See [Editors](editors.md) for the supported attach
flows.

## Persistent SSH agent on WSL2 (host setup)

By default, `ssh-agent` dies when you close your terminal. To keep it running
across all terminals, install `keychain` on the **host** (not inside Boxa):

```bash
sudo apt install keychain
```

Add to your host `~/.zshrc` (or `~/.bashrc`):

```zsh
eval $(keychain --eval --quiet --agents ssh)
```

Add to `~/.ssh/config` (a private file, not in any public repo):

```sshconfig
Host *
    AddKeysToAgent yes
```

This starts one host `ssh-agent` per boot, shared across terminals. Host
OpenSSH adds a key on first use and prompts for its passphrase once per boot.
This host setup does not enable the SSH gate or make Boxa load a key.

### Alternative approaches

| Method | Needs systemd? | Extra install? | Complexity |
|---|---|---|---|
| `keychain` (recommended) | No | `keychain` pkg | Low |
| systemd user service | Yes (`systemd=true` in `wsl.conf`) | None | Low |
| Fixed socket path in `.zshrc` | No | None | Low |
| npiperelay (Windows agent bridge) | No | `socat` + `npiperelay.exe` | Medium |

## See also

- [ADR 0026](adr/0026-ssh-gate-opt-in-agent-forwarding.md) — decision and trust
  model for the SSH gate.
- [CONTEXT.md](../CONTEXT.md#ssh) — canonical **SSH gate**, **Key picker**, and
  **Boxa SSH config** terminology.
- [Networking](networking.md) — network gates used to reach an SSH endpoint.
- [Editors](editors.md) — Cursor and VS Code attach flows.
