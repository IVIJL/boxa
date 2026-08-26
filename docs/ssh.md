# SSH

Boxa controls SSH signing-socket forwarding with the **SSH gate**. Each Project
has one of two states:

- `off` forwards no agent and is the default.
- `on` forwards that Project's dedicated **Project agent**.

A newly created Container in `off` state receives no host agent socket and has
no `SSH_AUTH_SOCK`. When on, the Project agent contains keys added through the
Key picker or restored by legacy migration; separate Projects never share an
agent or socket.

Run these commands on the host:

```bash
boxa ssh                         # Show the effective state for the current Project
boxa ssh off                     # Disable for the current Project
boxa ssh on                      # Enable the current Project
boxa ssh on ~/projects/my-app    # Enable a specific Project
boxa ssh on --global             # Enable the global fallback
boxa ssh off --global            # Disable globally
```

Project choices override the global choice. Boxa stores both in
`~/.config/boxa/ssh.conf`, using absolute host paths for Project sections:

```ini
gate = on

[/home/me/projects/my-app]
gate = off
```

Changes take effect only when the Container is created. If the affected
Container is already running, Boxa prints the required restart command:
`boxa stop && boxa`. Every Container start and attach reports the frozen
reality: the binary gate, Project agent liveness, and key fingerprints.
Changing `ssh.conf` does not change that report
until the Container is recreated.

The **SSH gate** controls only the signing socket. It does not control the
separate [Boxa SSH config](#boxa-ssh-config) mount, and it does not grant network
access to an SSH server. Allow an external server through the
[Allowlist](firewall.md), or use a [Host connection](networking.md#host-connections)
for a service on the host.

## Key picker

`boxa ssh add` opens the consent-first **Key picker** for the current Project
agent. It is available only while the effective gate state is `on`. `boxa ssh
on` opens the same flow when enabling a Project whose agent has no keys.

Before looking in `~/.ssh`, Boxa asks permission. If you decline, the picker
still offers manual path entry. If you consent, candidate discovery uses file
names and file types only; Boxa never opens private key files. It may read the
comment from a matching public `.pub` file to improve the label. You can select
multiple candidates or enter a path manually.

The selected key is loaded by `ssh-add`, which asks for its passphrase when
needed. Boxa first lets `ssh-add` test the key non-interactively. If that
succeeds, the key has no passphrase and Boxa prints a warning with the command
to protect it. Boxa never first loads a user key without this explicit Key
picker action. A legacy migration may re-open the picker during startup.

## Agent key

The **Agent key** remains Boxa's per-installation ed25519 identity. Its private
key stays under `~/.config/boxa/agent-identity/` on the host. The key material
and its existing identity directory are preserved by the binary-gate migration.

The socket, not the private key, is forwarded. During legacy `agent` migration,
Boxa loads the preserved Agent key into the Project agent. If the key has not
been provisioned yet, the Project agent remains empty.

## Security model

A forwarded Project agent socket is full signing authority over **every key
currently loaded in that agent**. Code in the Container cannot read private key bytes,
but it can ask the agent to sign and can therefore authenticate anywhere those
keys and the available network permit. The SSH gate does not filter individual
keys.

Keep the gate `off` where SSH is unnecessary. Add only keys belonging to the
intended principal and protect personal private keys with passphrases.
Boxa never reads private key material; only a user-confirmed Key picker action
first loads user keys.

## Migration and first install

Fresh installs and existing users upgrading from the old always-forwarded
behaviour receive the same one-time prompt to enable the SSH gate globally.
The default answer is **No**. Declining leaves the gate off and records the
choice so Boxa does not ask again. A non-interactive install or update leaves
the gate off without recording a choice, so a later interactive run can ask.

You can change the decision at any time with
`boxa ssh off|on --global` or add a Project override with
`boxa ssh off|on [project|path]`.

Legacy `agent = agent` and `agent = user` values map in memory to `on` on every
read, with a once-per-process visible note; reading does not rewrite the file.
The Agent-key mode seeds the Project agent from the preserved Agent key. User
mode asks the user to reselect the keys previously added through the Key picker.
The canonical `gate = off|on` grammar is written only by an explicit gate
change, and its new key name deliberately makes older parsers fail closed.

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
