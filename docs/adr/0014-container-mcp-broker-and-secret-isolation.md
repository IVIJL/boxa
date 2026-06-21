# ADR 0014 — Container MCP broker and secret isolation

- **Status:** proposed
- **Date:** 2026-05-30
- **Builds on:** ADR 0003 (privileged entrypoint, no sudo / no setuid from inside
  the container), ADR 0010 (Agent-browser host broker pattern), ADR 0013
  (Container MCP profile and rendering)

## Context

ADR 0013 introduced an agent-neutral **MCP profile**, a secret store, render of
`boxa-`-prefixed agent entries that call a `boxa-mcp-run` wrapper, and the
wrapper itself which "loads boxa's canonical MCP profile" inside the
**Container**. Issues 01–13 shipped all of that.

End-to-end testing inside a real **Container** surfaced two gaps that meant a
`boxa`-managed MCP server never actually ran inside the **Container**:

1. **The canonical profile and secret store never reach the Container.**
   `docker-run.sh` bind-mounts `~/.claude` and `~/.codex`, but boxa's own
   config tree `~/.config/boxa` is host-only by design and is not mounted.
   The wrapper resolves the profile at `~/.config/boxa/mcp/profile.json`
   (= `/home/node/.config/boxa/mcp/...` in-container), which does not exist
   there. No `XDG_CONFIG_HOME` is passed in and no startup step seeds it, so
   every `boxa-` MCP server fails to connect. The plan assumed the wrapper
   "loads the canonical profile" without ever specifying how the profile crosses
   the host → container boundary.

2. **Render writes to the wrong file for the Container.** The Container reads
   `~/.claude/.claude.json` (`CLAUDE_CONFIG_DIR=/home/node/.claude`, bind-mounted),
   but on the host `default_config_path()` prefers the host-native `~/.claude.json`,
   so rendered `boxa-` entries land where the Container never reads them.

Beyond fixing reachability, a security requirement was raised: **the agent
(Claude Code / Codex, running as `node`) must not be able to read MCP server
credentials.** Two hard facts constrain the solution:

- Inside the **Container** every process runs as `node` (UID 1000). A process's
  `/proc/<pid>/environ` is mode `0400` owned by its UID, so any `node` process
  can read another `node` process's environment. If an MCP server runs as `node`,
  the agent can steal its API key from `/proc`. **Same-UID isolation is
  impossible** — credentials can only be hidden by running the server under a
  different UID.
- A plain RO bind-mount carries the host's numeric UID (host `user` UID 1000 →
  container `node`), and a `0600` host file is then readable by `node` and *not*
  by any other in-container UID. **A bind-mount cannot grant "readable by the
  server account but not by the agent."**
- ADR 0003 forbids NOPASSWD sudoers entries and setuid bridges and guarantees
  "no path back to root from inside the container." `node` therefore cannot
  switch UID on its own, so it cannot launch a process under a different account.

## Decision

### Profile reaches the Container via a live read-only bind-mount

The **MCP profile** is secret-free (it stores references, not credential
values). It is delivered into the Container by a read-only bind-mount of the
host MCP store, mirroring boxa's established host → container shared-state
pattern (traefik dynamic config, dnsmasq conf, the firewall allowlist, the host
gitignore). Because it is a live mount, `enable` / `disable` / `add` / `import`
of a server take effect for the next agent session with no restart. The mount
is read-only so the Container cannot corrupt host state.

### MCP servers run as a dedicated `boxa-mcp` account behind an always-on broker

Credentials are hidden from the agent by running every **Container MCP server**
under a dedicated unprivileged service account, `boxa-mcp`, distinct from the
agent user `node`. Because `node` cannot change UID (ADR 0003), it cannot start
that process itself. Instead:

- The entrypoint **root phase** starts a long-running **MCP broker** as
  `boxa-mcp` before the `setpriv` drop to `node`. The drop must reset the full
  credential set, not just the UID:
  `setpriv --reuid boxa-mcp --regid boxa-mcp --init-groups … &`. `--reuid`
  alone leaves the broker with root's GID and supplementary groups — for a
  component whose entire purpose is credential isolation, retained root-group
  membership would re-expose group-readable root-owned files and weaken the
  `boxa-mcp`-only boundary. `--regid boxa-mcp --init-groups` sets the
  primary group to `boxa-mcp` and reinitializes supplementary groups from
  `/etc/group` for that account, so the broker holds only `boxa-mcp`'s own
  group memberships. The broker is then owned by `boxa-mcp`, so `node` can
  neither signal nor ptrace it.
- The broker **always runs**, even with an empty profile, so a server added to a
  running Container is serviceable without a restart (the profile is a live
  mount).
- Rendered agent config keeps calling `boxa-mcp-run <server>`, but that command
  is now an **MCP relay**: it runs as `node`, connects to the broker's unix
  socket, names the server it wants, and proxies stdio. The broker validates the
  name against the in-scope profile and **spawns a fresh server process as
  `boxa-mcp` on demand**, injecting that server's secrets as environment. The
  agent only ever sees the stdio tool stream — never the credential.

This is the Agent-browser broker pattern (ADR 0010) applied in-container: cross a
trust boundary without handing the untrusted side the credentials.

### Secrets are delivered by a root-staged private copy

A bind-mount cannot give `boxa-mcp`-only read access (UID-mapping, above), so
secrets are staged instead of mounted into a node-readable path:

- The host secret store is bind-mounted read-only under a **root-only** directory
  (mode `0700`, owned root) that `node` cannot traverse.
- The entrypoint root phase copies the in-scope secrets into a **`boxa-mcp`-private
  tmpfs** (`/run/boxa-mcp/…`, dir `0700` `boxa-mcp`, file `0400` `boxa-mcp`).
  `node` can read neither the source (root-only dir) nor the copy (boxa-mcp-only
  dir). Root can; that is accepted. tmpfs keeps secrets off disk and clears them on
  container stop.
- The broker re-reads the staged secrets file on every spawn, so it is stateless
  between sessions.

The broker's unix socket lives in a node-connectable location separate from the
`0700` secret directory (connecting to the socket exposes no credential, only a
stdio pipe).

### Scope: global + current Project, with least-privilege secret staging

A Container is one **Project**; its effective profile is `global + this Project`
(CONTEXT.md). The broker serves global servers plus this Container's Project
servers, resolved from **Container identity**. Secret staging is least-privilege:
only global secrets and *this* Project's secrets are staged; a Container for
Project A never receives Project B's secrets.

### Render target is the Container-visible config

Discovery and rendering are split: `import` reads the host config via
`default_config_path()` (correct for finding what the user has), but render always
writes `boxa-` entries to the **Container-visible** `~/.claude/.claude.json`,
regardless of whether host `~/.claude.json` exists. This makes the entries appear
in the Container and keeps the host's own Claude config free of container-only
entries (the relay has no broker to reach on the host). Render still touches only
`boxa-`-prefixed keys, so other shared config is untouched. Codex has no drift
(`~/.codex` is mounted whole at the same relative path).

### Live updates: profile via mount, secrets via an explicit `boxa mcp reload`

Profile changes are live via the mount. Secret changes (a value copied by
`import`/`add`, or a rotation) need a re-stage, which requires root. Rather than a
persistent in-container root watcher — which would reintroduce exactly the
residual-root surface ADR 0003 removes — re-staging is **host-initiated**:

- A new host command `boxa mcp reload` re-stages secrets into the running
  in-scope Container(s) via a momentary `docker exec -u 0` (same trust level as
  starting the Container). No `boxa stop` / `start` needed.
- After a secret-writing command, if a relevant Container is running, the CLI
  **detects and prompts**: it reports that secrets were staged on the host and
  that `boxa mcp reload` will load them into the running Container.
- Inherent limit (shared with a full restart): a re-stage affects only
  **subsequently spawned** servers — a running process keeps its environment.
  "Live" means "the next session gets the new secret without a Container restart."

### Trust boundary: the agent, not peer servers (explicit non-goal)

The isolation this ADR buys is **agent → server**: the agent user `node` cannot
read a Container MCP server's credentials. It is **not** server → server. Every
spawned server runs under the **same** `boxa-mcp` UID as the broker and as
every other server, and a secret is delivered the only way an MCP server
consumes one — as an environment variable. Same-UID processes can read each
other's `/proc/<pid>/environ` (the DAC check passes for an equal UID, and Yama
`ptrace_scope` gates only `PTRACE_MODE_ATTACH`, never the `MODE_READ` an
`environ` read uses), so once a secret is in one server's environment a *peer*
`boxa-mcp` server can read it. No amount of staged-file hardening changes this:
unlinking the staged copy protects the file at rest, but the live secret is still
in the running server's `/proc`.

Closing this would require per-server **distinct UIDs** so `/proc/environ` and
ptrace become cross-UID protected — but switching a spawned child to another UID
needs privilege (CAP_SETUID / a setuid helper / root), which **ADR 0003 forbids**
at runtime (the only root phase is container start; by spawn time PID 1 is already
`node`). We therefore **accept** this limitation rather than reintroduce a
privileged runtime path:

- Container MCP servers are tools the user deliberately imported into their own
  profile; they share one trust domain. The primary threat (the *agent* reading
  server secrets, e.g. an agent that runs an untrusted server and then reads its
  token) is what the `boxa-mcp` boundary closes, and it does.
- Peer-server isolation is a deliberate **non-goal** of this slice, documented as
  such here and in the user-facing README MCP section. The cheap in-broker
  mitigations are still applied (the broker strips its own `BOXA_MCP_SECRETS_DIR`
  / socket pointers from each child's environment so it never *volunteers* the
  staged-store path), but they are defense-in-depth, not a guarantee.
- If a future requirement needs true peer isolation, it is a separate decision
  that must revisit ADR 0003 (e.g. a narrowly-scoped privileged spawn helper or
  per-server UID pool) — not folded silently into this broker.

## Considered options

- **Scoped setuid launcher (node → boxa-mcp).** A setuid-to-unprivileged-account
  binary the agent runs. Far less code than a broker, grants no root. Rejected:
  it reintroduces a setuid bridge, softening ADR 0003's "no setuid bridges"
  invariant, which we will not weaken; setuid binaries are also a classic footgun.
- **In-container inotify root watcher for live secrets.** A root daemon that
  re-stages on change. Rejected: a persistent root process is precisely the
  residual-root attack surface ADR 0003 eliminates.
- **Bind-mount the secret store directly.** Rejected: UID-mapping makes a host
  `0600` file readable by `node` and unreadable by `boxa-mcp` — the opposite of
  what is needed.
- **Seed the whole profile by copy at startup.** Rejected for the (secret-free)
  profile: a live RO mount is simpler, has no sync drift, and is the established
  pattern. Copy-staging is used only where ownership semantics force it: secrets.
- **Mount `~/.config/boxa` into the Container.** Rejected: boxa's host
  orchestration config does not belong inside the Container. Only the MCP subset
  crosses, and secrets cross only as a re-permissioned private copy.

## Consequences

- A new `boxa-mcp` Container account is added (Dockerfile), with its own HOME and
  a writable npm/npx cache so on-demand `npx` servers run under it; materialized
  runtime (ADR 0013 `install`) must remain executable by `boxa-mcp`.
- New runtime components: the broker (started in the entrypoint root phase) and the
  relay (the reworked `boxa-mcp-run`). The broker is **agent-neutral** — both the
  Claude Code and Codex relays connect to the same broker.
- The wrapper's behavior shifts from "exec the server directly" (ADR 0013) to
  "relay stdio to the broker"; the rendered command name is unchanged, preserving
  ADR 0013's stable control point.
- **A server's environment comes from its profile/secret store, not the agent
  session.** The old `exec`-the-server wrapper ran as `node` and so *inherited the
  agent session's environment*; a non-secret variable the user `export`ed in the
  session reached the server for free. The broker runs with a deliberately **clean
  environment** (`env -i`, for the same isolation reason it runs under a separate
  UID), and the relay forwards only the server name, project, and cwd — not the
  session env. So a server's configuration must live where boxa can deliver it:
  non-secret values **inline in the profile** (ADR 0013 already copies these from
  the source config at import, precisely so a server starts without the user
  re-exporting them) and credentials in the **secret store**. A server that declares
  a required env key with no value in either place **fails fast as misconfigured**
  rather than silently depending on whatever the current session happened to export.
  Session-env inheritance was an artifact of the exec wrapper that the broker model
  intentionally replaces; "peer-equal" (above) is about access to *resources*
  (workspace, Docker), not inheriting the agent's shell environment.
- Secret rotation requires `boxa mcp reload` (or a restart) to reach a running
  Container; it never auto-propagates to already-running server processes.
- ADR 0003's invariants are preserved unchanged: no NOPASSWD sudoers, no setuid
  bridges, no persistent or residual root inside the Container.
- Credential isolation is **agent → server only**, not server → server (see the
  trust-boundary subsection): peers share the `boxa-mcp` UID and can read each
  other's secrets via `/proc/<pid>/environ`. This is an accepted non-goal,
  documented here and in the README MCP section.
- Spawned servers run as `boxa-mcp`, not as the agent user `node`. So that the
  separate UID does not cost a server its access to the Container, `boxa-mcp` is
  a **peer-equal citizen** of `node` — see the 2026-05-31 update below: the
  workspace is reachable read/write via an idmapped mount, and the rootless Docker
  socket via a Container-internal bridge group, while `node` and `boxa-mcp` stay
  out of each other's private files. Credential isolation (the agent → server
  guarantee above) is unchanged.

## Update 2026-05-31 — the Container MCP server is a peer-equal citizen

The decision above closes the *credential* boundary (the agent cannot read a
server's secrets) but never specified the server's **access to the Container**.
The first implementation (issues 14–17) therefore left `boxa-mcp` with only its
own group, so a spawned server could neither write the workspace (owned by `node`,
UID 1000) nor reach the rootless Docker socket (in `node`'s runtime dir) — and a
review-round comment was briefly mis-documented as "filesystem servers that mutate
the workspace are not supported". **That limitation is retracted.** The intended
model is:

> A Container MCP server is a **peer-equal citizen** of `node`: equally a full,
> sudo-less user of the Container, with the *same practical reach into the
> Container* as the agent. The only asymmetry is privacy — `node` cannot read the
> server's secrets, and (symmetrically) neither identity sees into the other's
> private files unless a resource is *deliberately* shared.

This is a complement to the credential boundary, not a weakening of it: secrets stay
`0400`/`0700` owner-only to `boxa-mcp`, `node`'s home stays owner-only to `node`,
and only explicitly-shared resources cross. Mechanisms, each chosen so the **host is
never touched** (no host-side group, no host permission changes):

- **Bridge group — shared runtime sockets.** A Container-internal system group
  (`boxa-bridge`) created in the Dockerfile **only inside the image** (never on
  the host — the sockets live in `/run`, so the group never reaches host files and
  needs no fixed/host-registered GID). Both `node` and `boxa-mcp` are members.
  The broker socket and the Docker socket live in a neutral `/run` location owned
  with group `boxa-bridge` (`0660`/`0770`), so each identity reaches the shared
  sockets **without being a member of the other's primary group**. This removes the
  previous `node ∈ boxa-mcp` cross-membership: neither account is in the other's
  group anymore; they meet only at the bridge.
- **Docker socket — placed in the shared location.** Rootless `dockerd` (run by
  `node`) is pointed at a bridge-group-readable socket path (or its socket is
  `chgrp boxa-bridge` + `g+rw` immediately after start), and `DOCKER_HOST` /
  `XDG_RUNTIME_DIR` are propagated from the broker into each spawned child. This
  brings **`docker`/`podman`-launcher MCP servers into scope** (npx/uvx/python
  servers were never affected). Accepted trade-off: holding the Docker socket means
  node-level Docker capability, so a server that uses Docker can act through the
  rootless daemon as `node` would — Docker is a deliberately-shared tool.
- **Workspace — per-broker mount namespace with an idmapped remount.** `node` keeps
  the workspace as a plain direct bind-mount in the main namespace — no overhead, no
  change. The broker is started inside its **own mount namespace**
  (`unshare --mount --propagation private`) in which the *same absolute*
  `$PROJECT_PATH` is re-mounted as an **idmapped bind** — using util-linux
  `mount -o X-mount.idmap=u:1000:<boxa-mcp-uid>:1 g:1000:<boxa-mcp-gid>:1`, NOT
  the Docker `--mount …,idmap` field (this environment's Docker rejects it). The MCP
  servers the broker spawns inherit that namespace, so they see `$PROJECT_PATH` with
  the files appearing owned by `boxa-mcp` for **read and write**, while the host
  (and `node`'s view in the main namespace) stay `1000:1000`. Host files, ownership,
  and permissions are **never altered**, and an on-host `chmod`/`chgrp` cannot break
  it. Why this and not the earlier ideas:
  - A single idmapped mount can't serve both identities on one path (one mapping per
    mount); **two mount namespaces** (node's plain mount, the broker's idmapped
    remount of the same path) give each its own mapping — that is the missing piece.
  - The remount runs in the entrypoint **root phase before `exec setpriv … 
    boxa-mcp-broker`**, so there is **no setuid helper and no residual root**
    (unlike a FUSE/`bindfs` path, which would need setuid `fusermount3` or a
    long-lived privileged helper). The namespace is kept alive by the broker running
    as `boxa-mcp`; `node` (no root, no `CAP_SYS_ADMIN`) cannot enter it.
  - `$PROJECT_PATH` stays the **same absolute host path** in both worlds, preserving
    ADR 0004's cwd/session-key parity, so the shared host↔Container session history
    keeps working. The runtime sockets in `/run` (broker socket, Docker socket,
    secret store) live on tmpfs mounts inherited before `unshare`, so they remain
    visible/connectable across the boundary — the relay still reaches the broker.

  Requires kernel ≥ 5.12 (WSL2 6.6 qualifies) and an **idmap-capable filesystem** for
  the source bind: ext4 (the WSL2-native project store) works; a Windows-mounted
  `9p`/`drvfs` project does not. Detected at start; if unavailable the server falls
  back to **read-only** workspace access (reads are free — project files are
  world-readable) rather than touching host metadata, and the downgrade is logged
  (no silent fallback).

Consequences of this update:

- The **host is untouched**: no new host group, no host permission changes. All
  sharing is Container-internal (bridge group in `/run`, idmap at mount time).
- **Mutual invisibility is preserved and slightly strengthened**: dropping
  `node ∈ boxa-mcp` means `node` no longer even nominally shares the service
  account's group; secrets remain owner-only, `node`-home remains owner-only.
- `docker`/`podman`-launcher servers are **supported**; the v1 servers
  (`context7`, `taskmaster-ai`) continue to work unchanged.
- The round-2 README/ADR statement "no workspace writes / filesystem servers
  unsupported" is **withdrawn** in both documents.
- ADR 0003 is still honored: the bridge group, idmap, and Docker-socket placement
  are all set up in the entrypoint **root phase before the `node` drop** or baked
  into the image — no setuid, no NOPASSWD, no persistent/residual root, no runtime
  privilege escalation by `node`.
