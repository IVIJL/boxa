# ADR 0026 — SSH gate: agent forwarding becomes opt-in; boxa never loads keys

- **Status:** accepted
- **Date:** 2026-08-19
- **Builds on:** ADR 0017 (provisioning registry — the one-time prompt), ADR 0006 (picker conventions), ADR 0020 (per-project conf grammar)

## Context

Until now boxa forwarded the host SSH agent socket into every container
unconditionally, and went further: at container creation it would revive
or start an agent and auto-run `ssh-add` to load the user's default keys.
An agent inside a box could therefore sign with any host key — including
passphrase-less production keys the user never intended to expose. This
made SSH the only capability in boxa without a gate, contradicting the
system-wide pattern (Allowlist, Host connection, Agent-browser allowlist,
MCP activation: all opt-in, default-deny, host-owned). A real incident —
an agent using a passphrase-less key to reach production — triggered the
change.

## Decision

SSH agent forwarding becomes the **SSH gate**: off by default, enabled
globally or per project via `boxa ssh on` (durable in
`~/.config/boxa/ssh.conf`, same never-sourced INI grammar as
`resources.conf`; project section overrides global; effective at
container creation only). Every container start prints the effective
state — forwarded (with key names from `ssh-add -l`) or not, plus the
enable command.

Boxa never loads keys into the agent and never reads private key
material. The auto-`ssh-add` is removed entirely. Keys enter the agent
only through the **Key picker** (`boxa ssh on` / `boxa ssh add`):
explicit consent before listing `~/.ssh`, candidate discovery by
filename only, manual path entry as fallback, and the actual load done
by `ssh-add` itself. Passphrase-less keys are detected behaviourally (a
non-interactive `ssh-add` attempt succeeding) and warned about, without
boxa ever opening the key file.

Existing users get a one-time provisioning prompt (Elective step,
ADR 0017) on first run after upgrade — default **No** — instead of a
silent break or a silent grandfathering-in of the old always-on
behaviour.

## Considered options

- **Keep default-on, add visibility + opt-out** — smaller change, but
  leaves the insecure default for every new user and keeps SSH the odd
  one out among boxa's gates. Rejected.
- **Per-key forwarding filter** — the agent protocol offers all keys on
  the socket; filtering needs a host-side proxy agent per container
  (extra daemon or a dependency like `ssh-agent-filter`). Deferred; the
  CLI (`boxa ssh on`, `keys=` in `ssh.conf`) is shaped so a `--keys`
  filter can be added without breaking changes.

## Consequences

- `git push`/`pull` over SSH stops working out of the box until the user
  runs `boxa ssh on` — the startup line and the upgrade prompt carry
  that cost visibly.
- The **Boxa SSH config** mount (`~/.config/boxa/ssh_config`) stays
  ungated: it carries addresses/usernames only, no signing capability.
- `docs/ssh.md` no longer claims forwarding is harmless; it documents
  the gate and the fact that a forwarded socket is full signing power
  over every key in the agent.
