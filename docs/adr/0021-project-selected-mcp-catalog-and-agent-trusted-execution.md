# ADR 0021 — Project-selected MCP catalog and agent-trusted execution

- **Status:** accepted
- **Date:** 2026-07-27
- **Revises:** ADR 0013's global-profile and render semantics; ADR 0014's
  peer-equal Docker capability and unconditional secret-isolation claims

## Context

The current user-wide MCP profile conflates three different facts: a server is
known, its runtime is installed, and every Project should expose it to an agent.
This leaves unrelated MCP tools enabled in Projects that do not need them.

The single `boxa-mcp` execution identity also cannot support a deliberate MCP
such as `codex mcp-server` that must reuse the agent user's mounted ChatGPT login,
private tool state, SSH agent, and rootless Docker. Giving those resources to all
servers would destroy the boundary that protects `node` from a rogue MCP.

Finally, ADR 0014 shares the rootless Docker socket owned by `node` with
`boxa-mcp` while also claiming that the identities cannot reach each other's
private files. Those claims are incompatible: control of that daemon can request
bind mounts of paths readable by `node`. Docker container environment is also
inspectable by the daemon owner, so secrets injected into a Docker-packaged MCP
cannot be hidden from `node` with the current daemon topology.

## Decision

### Catalog, readiness, and activation

Replace the global MCP profile with a host-owned, user-wide **MCP catalog**. A
catalog entry is a prepared definition with a stable internal identity; merely
being in the catalog never renders, starts, or exposes it. A fresh Project has
no active Boxa MCPs.

Runtime availability is **MCP readiness**, evaluated deterministically for one
catalog entry and one running Project. It checks local executable/image state
and declared prerequisites such as credential files, sockets, or `codex login
status`; it does not probe an external service. Installation only prepares the
runtime. It never activates the entry, although an interactive activation flow
may explicitly install, re-check, and then activate it.

An **MCP activation** is the only durable source of truth for exposing one entry
to selected agent consumers in one Project. Activations are host-owned under
Boxa's user configuration and keyed by the canonical absolute Project path.
They are not repository configuration and do not follow a moved directory or a
new clone. Activation requires the target Boxa to be running and ready and never
starts it implicitly.

The initial command model is:

- `boxa mcp catalog` lists prepared definitions;
- `add`, `import`, and `remove` manage catalog definitions;
- `install` prepares a runtime;
- `activate` and `deactivate` manage the current or explicit Project;
- `mode` changes execution mode; and
- `list` shows the effective state of a Project.

Interactive activation selects ready entries and consumers. Non-interactive
activation requires an explicit `--for claude`, `--for codex`, or consumer list.
Import adds definitions only; a wizard may combine import, installation, and
activation only as separately visible steps.

Removing a catalog entry cascades all of its activations. Deactivation and
removal prevent new connections and re-render configs but do not kill an already
connected server; the CLI tells the user to reload or restart affected agents.

A rename or cosmetic metadata update preserves identity and trust. A
runtime-affecting update of an active entry is transactional: every activated
Project must be running and ready for the replacement before the catalog and all
rendered configs change. Removal destroys identity and trust; recreating the
same display name creates a new, default-isolated entry.

### Consumer rendering

Claude Code activations render through its host-owned Project configuration.
Codex officially scopes MCP through `.codex/config.toml` in a trusted repository,
not through a user config table keyed by Project. Boxa therefore keeps its
host-owned activation as source of truth and renders only a clearly delimited
`boxa-*` section into the Project's `.codex/config.toml` as a derived artifact.

If that file is otherwise untracked, Boxa adds it to the repository-local
`.git/info/exclude`, not the shared `.gitignore`. Existing non-Boxa content is
preserved. A tracked `.codex/config.toml` is not changed unless the user passes
`--allow-tracked-codex-config`, because no ignore rule can prevent that edit from
appearing in the working tree. This consent is per mutation and is never stored
or inferred: activation, rename/update, deactivation, and catalog removal each
require the flag when that operation would change tracked Codex bytes. Before a
multi-Project lifecycle mutation writes anything, Boxa validates every affected
Codex render and refuses the whole operation if any tracked change lacks consent.
A runtime-only update whose rendered Codex region is byte-identical does not
require the flag because it does not write the tracked file.

For transactional catalog and activation mutations, the secret-free broker
runtime snapshot is the final commit point. Catalog, activation, secret-store,
and consumer-render writes must all succeed first while concurrent broker
launches continue to authorize against the old snapshot. A failure before the
final atomic runtime replacement restores every pre-image, so replacement
Agent-trusted authority is never transiently published and then rolled back.

### Execution modes

Every catalog entry has one **MCP execution mode**:

- `service-isolated` is the default. The broker runs the server as `boxa-mcp`
  with Project read/write access but without `node` private files, process
  identity, or raw Docker socket. All service-isolated servers still share one
  UID and one credential trust domain; peer-to-peer secret isolation remains
  deferred.
- `agent-trusted` runs the server as `node`. It deliberately receives the same
  private filesystem and socket context as the agent, including the agent-owned
  rootless Docker socket, but starts from a deterministic clean baseline rather
  than inheriting the agent process environment. The baseline fixes HOME, XDG,
  PATH, and known Docker/SSH socket locations and adds only declared non-secret
  environment. Ambient bearer tokens are not inherited.

Trust attaches to the stable catalog identity and applies wherever that entry is
activated. Discovery and import never infer it. Only a host-side command such as
`boxa mcp mode <entry> agent-trusted` can grant it. The interactive command shows
the stable ID, command/image, and exact access and requires confirmation;
intentional host automation may use `--yes`. An in-container agent can consume
but cannot grant Boxa-managed trust.

Execution mode cannot change while any activation exists. An agent-trusted
entry uses credentials already available to `node` and must not declare or
retain values in the MCP secret store; mode change is refused until those secret
contracts and values are removed.

Keep one `boxa-mcp-run` launcher and one broker. The broker validates catalog
identity, Project activation, consumer, and execution mode. It spawns a
service-isolated process or returns a secret-free authorization/launch plan that
the launcher executes as `node` for an agent-trusted entry. The broker is not a
trust root for this privilege transition because it shares the `boxa-mcp` UID
with Service-isolated children: before executing, the launcher independently
loads a dedicated secret-free host runtime snapshot from a fixed node-readable
read-only directory mount, repeats the stable ID/name, exact Project,
activation, consumer, enabled, and mode checks, reconstructs the deterministic
argv/environment/cwd/socket plan, and requires an exact match. Mounting the
directory rather than one file preserves visibility of atomic host updates;
MCP secret stores remain outside this mount. A child that replaces the broker
socket can therefore cause denial of service but cannot authorize new node
code or environment.

### Docker boundary and temporary exception

A service-isolated server no longer receives the raw node-owned Docker socket.
A constrained node-side Docker launch adapter may start a catalog-declared image
with its Project mount, environment, and stdio without mounting the socket into
the server. An MCP that needs arbitrary Docker control during execution must be
agent-trusted.

For compatibility, Docker-packaged service-isolated MCPs may still receive MCP
secrets even though `node`, as daemon owner, can inspect their container
environment. This is a deliberate temporary degradation of the agent-to-server
secret guarantee. `list`, `status`, and `doctor` report
`degraded-secret-isolation`; first activation requires acknowledgement, and
non-interactive activation requires `--accept-degraded-secret-isolation`.

Future per-server isolation must also replace or isolate the Docker execution
and credential path. Separate MCP UIDs alone will not prevent `node` from using
its daemon to inspect container environment.

## Migration

Migration copies all existing global and Project definitions into the catalog.
Former global definitions receive no activations, which intentionally removes
their automatic exposure. Existing Project-scoped definitions retain activation
only in their original Project and only for consumers where they are currently
rendered. Migration does not infer agent trust.

## Consequences

- A catalog can survive host restart, Boxa stop, and container recreation while
  every Project remains opt-in.
- `codex mcp-server` can reuse the mounted ChatGPT login and operate on source and
  Project Docker when explicitly agent-trusted and activated only for Claude.
- Rogue service-isolated MCPs retain Project read/write access but cannot use the
  node Docker socket as a path into `/home/node`.
- Docker-packaged secret-bearing servers remain functional with a prominently
  documented weaker agent-to-secret boundary until the follow-up isolation work.
- Existing host/user MCP entries not owned by Boxa remain untouched.
