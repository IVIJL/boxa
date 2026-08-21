# MCP servers

Boxa separates four facts:

1. The user-wide **MCP catalog** knows a definition.
2. Its runtime and prerequisites are **ready** in one running Project.
3. A host-owned **MCP activation** selects consumers for that Project.
4. A new Container agent session receives the selection at launch.

Catalog membership never installs, starts, activates, or exposes a server. A
fresh Project therefore has no active Boxa MCP servers merely because the
catalog is full; only entries explicitly marked everywhere are inherited.

## Normal workflow

```bash
boxa mcp catalog
boxa mcp add context7 -- npx -y @upstash/context7-mcp@latest
boxa mcp install context7 --project /work/my-project
boxa mcp readiness context7 --project /work/my-project
boxa mcp activate context7 --project /work/my-project --for claude,codex
boxa mcp status --project /work/my-project
```

Interactive activation offers catalog and consumer pickers and may offer the
separate install step. Non-interactive activation requires `--for claude`,
`--for codex`, or `--for claude,codex`. Neither readiness nor activation starts
a stopped Boxa.

`boxa mcp activate <entry> --everywhere --for <consumers>` durably selects an
entry for every present and future Project. Known running Projects activate it
after readiness passes; stopped Projects keep it pending until Container start.
Use `boxa mcp activate <entry> --no-everywhere` to stop future inheritance
without changing existing activations.

`boxa mcp deactivate <entry> --project <path>` removes that Project's
activation. The resulting sticky opt-out wins over an everywhere mark until an
explicit per-Project activate clears it. `boxa mcp remove <entry>` destroys the
stable catalog identity and cascades all activations. Both affect new agent
sessions; they cannot terminate a server connection already held by a running
agent. Restart the affected agent to drop that connection.

## Persistence and Project identity

The catalog, activations, acknowledgements, and secrets are host-owned state
under the user's Boxa configuration. They survive host restarts, `boxa down`,
and Container recreation. Installed npm runtime lives in the persistent
npm-global prefix; Docker images live in the Project's persistent rootless
Docker state.

An activation is keyed by the canonical absolute host path. Moving a directory
or creating another clone produces a different Project key and does not inherit
activation. Catalog entries remain available for explicit activation there.

## Launch-time consumer profiles

No MCP configuration is written into a Project or shared agent file. The
host-owned activation store and the secret-free runtime snapshot mounted
read-only at `/run/boxa-mcp-runtime` are the only current artifacts.

Container-only launch wrappers derive the complete Project profile for every
invocation:

- Claude receives inline `--strict-mcp-config` and `--mcp-config` arguments.
- Codex receives `-c mcp_servers.*` overrides and disables inherited shared
  servers that are not activated for the Project.

This keeps host Claude and host Codex free of Container-only Boxa servers and
prevents host MCP definitions from leaking into Container sessions. Activation
changes become visible in a new agent session. An unreadable runtime snapshot
starts the agent with no MCP servers and a warning rather than blocking it.

## Execution identity

`service-isolated` is the default. The server runs as `boxa-mcp`, can read and
write the Project, but cannot read the `node` user's private files or raw
rootless Docker socket. Service-isolated servers currently share one UID and
one credential trust domain.

`agent-trusted` runs as the concrete Container user `node` after explicit host
authorization for the stable catalog identity. It can use the agent user's
mounted private state, SSH/Docker sockets, and existing credentials, but
receives a deterministic clean environment rather than ambient bearer tokens.
It cannot use Boxa MCP-store secrets.

Only the host can grant this mode:

```bash
boxa mcp mode codex-delegate agent-trusted
boxa mcp mode codex-delegate agent-trusted --yes  # non-interactive
```

Mode cannot change while an activation exists, and import/discovery never
infers trust.

Marking an `agent-trusted` entry everywhere extends agent-identity trust to
every future Project. Boxa prints that scope explicitly and requires interactive
confirmation or `--yes` for non-interactive use.

### Trusted Codex delegation

Codex login belongs to the host-mounted `node` context. Readiness runs local
`codex login status` inside the running Container and performs no network login.

```bash
boxa mcp add codex-delegate -- codex mcp-server
boxa mcp mode codex-delegate agent-trusted
boxa mcp readiness codex-delegate --project /work/my-project
boxa mcp activate codex-delegate --project /work/my-project --for claude
```

Fresh installs and `boxa update` offer to seed this catalog definition and trust
grant once. Projects activate it explicitly unless the user deliberately marks
it everywhere with the future-Project trust acknowledgement. Codex
self-activation is refused.

## Docker limitation

A service-isolated Docker MCP uses a constrained node-side adapter for its
catalog-declared image, Project mount, declared environment, and stdio. The raw
Docker socket is not mounted into the server.

Because `node` owns the daemon, it can currently inspect secrets injected into
a Docker container's environment. Status and doctor show
`degraded-secret-isolation`; first activation requires acknowledgement or
`--accept-degraded-secret-isolation` non-interactively.

## Import and migration

`boxa mcp import` discovers inherited Claude/Codex definitions without writing.
`--apply` imports selected definitions into the catalog only; it never installs,
activates, copies credential values, or grants trust.

`boxa mcp migrate` performs the one-time legacy catalog migration and retires
shared-file artifacts from the superseded design. Global definitions enter the
catalog without activations. Project definitions retain only consumers for
which a recorded Boxa artifact existed. Legacy source profiles remain
recoverable and migration never infers `agent-trusted`.

The cleanup uses legacy render state to remove only recorded Boxa content from
Project `.mcp.json`, `.claude/settings.local.json`, `.codex/config.toml`, and
repository-local `.git/info/exclude`. Non-Boxa content remains untouched. The
cleanup is transactional and idempotent, removes obsolete render state after
success, and runs automatically during `boxa update`.

Tracked Project files require one-shot cleanup consent:

```bash
boxa mcp migrate --allow-tracked-mcp-json
boxa mcp migrate --allow-tracked-codex-config
boxa mcp migrate --allow-tracked-mcp-json --allow-tracked-codex-config
```

Without the matching flag migration refuses the edit and names every tracked
file. The flags apply only to that cleanup run and are not stored as durable
Project consent.

Container setup also removes the old Boxa-managed
`enableAllProjectMcpServers` default once while preserving unrelated Claude
settings. A durable marker protects later deliberate user choices.

## Diagnosis

```bash
boxa mcp list --project /work/my-project
boxa mcp status --project /work/my-project --json
boxa mcp doctor
boxa mcp doctor --fix
```

List/status distinguishes catalog membership, readiness, activation, everywhere
marks and sticky Project opt-outs, selected consumers, execution mode/concrete
account, agent-identity trust scope, and isolation. Doctor detects
stopped targets, missing prerequisites, stale activation references, forbidden
agent-trusted secrets, runtime-snapshot drift, and degraded Docker isolation.
Output contains no secret values.

`doctor --fix` may create Boxa-owned directories, repair the launcher link, and
refresh the secret-free runtime snapshot. It never installs, starts a Boxa,
activates, grants trust, accepts degraded isolation, or edits a Project file.
