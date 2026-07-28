# MCP servers

Boxa separates four facts that older MCP setups often conflate:

1. The user-wide **MCP catalog** knows a definition.
2. Its runtime and local prerequisites are **ready** in one running Project.
3. A host-owned **MCP activation** exposes it to selected consumers in that Project.
4. Claude Code or Codex contains the matching derived render.

Catalog membership never installs, starts, activates, or exposes a server. A
fresh Project therefore has an empty MCP profile even when the catalog is full.

## Normal workflow

```bash
boxa mcp catalog
boxa mcp add context7 -- npx -y @upstash/context7-mcp@latest
boxa mcp install context7 --project /work/my-project
boxa mcp readiness context7 --project /work/my-project
boxa mcp activate context7 --project /work/my-project --for claude,codex
boxa mcp status --project /work/my-project
```

Interactive `activate` offers catalog and consumer pickers and may offer the
separate install step. Non-interactive activation requires `--for claude`,
`--for codex`, or `--for claude,codex`. Installation never activates. Neither
readiness nor activation starts a stopped Boxa.

`boxa mcp deactivate <entry> --project <path>` removes that Project's
activation. `boxa mcp remove <entry>` destroys the stable catalog identity and
cascades all of its activations. Both block new connections and re-render
consumers, but cannot terminate a process to which an agent is already
connected; reload or restart the affected agent.

## Persistence and Project identity

The catalog, activations, acknowledgements, and secrets are host-owned state
under the user's Boxa configuration. They survive host restarts, `boxa down`,
and Container recreation. Installed npm runtime lives in the persistent
npm-global prefix; Docker images live in the Project's persistent rootless
Docker state. Agent config and the Container runtime snapshot are derived and
can be restored with `boxa mcp doctor --fix`.

An activation is keyed by the canonical absolute host path. Moving a directory
or creating a new clone produces another Project key and intentionally does not
inherit activation. Catalog entries remain available for an explicit new
activation.

## Consumers

Claude Code is rendered into the Project's `.mcp.json`; Codex uses the
Project's `.codex/config.toml` with a delimited managed region. The host
activation remains authoritative, and Boxa preserves all non-Boxa content.
For Git Projects it adds either otherwise-untracked render target to
`.git/info/exclude`, never `.gitignore`. A tracked `.mcp.json` requires
`--allow-tracked-mcp-json`; a tracked Codex config requires
`--allow-tracked-codex-config`. Doctor will not edit either tracked file
without that authorization.

For Claude Code, activation also seeds the rendered server name once into
`.claude/settings.local.json`. Boxa preserves unrelated Project settings and
does not seed that name again after the user disables it; deactivation retires
the seed so a later reactivation delivers approval again.

Deactivation, removal, or a runtime-affecting update re-renders selected
consumers atomically. Restart/reload an already-running Claude or Codex session
to drop an old connection or pick up a changed definition.

## Execution identity

`service-isolated` is the default. The server runs as `boxa-mcp`, can read and
write the Project, but cannot read the `node` user's private files or raw
rootless Docker socket. Service-isolated servers currently share one UID and
one credential trust domain; isolation between individual servers is deferred.

`agent-trusted` is the CLI/canonical mode name: the catalog identity is
explicitly authorized across the node-trusted access boundary and runs as the
concrete Container user `node`. “Node-trusted” describes that access boundary,
not a second CLI mode. It can
use the agent user's mounted private state, SSH/Docker sockets, and existing
credentials, but receives a deterministic clean environment rather than the
launching agent's ambient bearer tokens. It cannot use Boxa MCP-store secrets.
Trust follows the stable catalog identity wherever it is later activated.

Only this host-side flow can grant it:

```bash
# On the host, after reviewing stable ID, command and access preview:
boxa mcp mode codex-delegate agent-trusted
# Non-interactive host automation must state confirmation:
boxa mcp mode codex-delegate agent-trusted --yes
```

An in-Container agent may consume an existing grant but cannot create one.
Mode cannot change while any activation exists, and import/discovery never
infers trust.

### Trusted Codex delegation

Codex login belongs to the host-mounted `node` context. Prepare and verify it
on the host/normal Codex surface first; readiness runs local `codex login
status` inside the target running Container and performs no network login.

```bash
boxa mcp add codex-delegate -- codex mcp-server
boxa mcp mode codex-delegate agent-trusted       # host-only confirmation
boxa mcp readiness codex-delegate --project /work/my-project
boxa mcp activate codex-delegate --project /work/my-project --for claude
```

`codex mcp-server` delegation is deliberately Claude-only; Boxa refuses Codex
self-activation. At launch the node-side launcher independently revalidates the
stable ID, exact Project, activation, consumer, enabled state, execution mode,
argv/environment/cwd, and socket plan against a secret-free read-only runtime
snapshot. A forged broker response cannot expand authority.

## Docker limitation

A service-isolated Docker MCP uses a constrained node-side adapter for its
catalog-declared image, Project mount, declared environment, and stdio. The raw
Docker socket is not mounted into the server. A server needing arbitrary Docker
control must be `agent-trusted`.

There is one temporary degradation: because `node` owns the daemon, it can
inspect secrets injected into a Docker container's environment. Status and
doctor show `degraded-secret-isolation`; the first activation requires an
acknowledgement, or `--accept-degraded-secret-isolation` non-interactively.
Separate MCP UIDs alone cannot fix this. Stronger Docker execution plus
per-server credential isolation remains deferred.

## Import and migration

`boxa mcp import` discovers inherited Claude/Codex definitions without writing.
`--apply` imports selected definitions into the catalog only; it never installs,
activates, renders, copies credential values, or grants trust.

`boxa mcp migrate` performs the one-time legacy migration. Global definitions
enter the catalog with no activations. Existing Project definitions retain only
the original Project and consumers where a Boxa render actually existed.
Legacy source files remain recoverable, and migration never infers
`agent-trusted`.

## Diagnosis

```bash
boxa mcp list --project /work/my-project
boxa mcp status --project /work/my-project --json
boxa mcp doctor
boxa mcp doctor --fix
```

List/status distinguishes catalog membership, readiness checks, activation,
consumer render state, execution mode/concrete account, and isolation. Doctor
also detects stopped targets, missing runtime/prerequisites, stale activation
references, forbidden agent-trusted secrets, render/runtime-snapshot drift, and
the Docker degradation. Output contains no secret values.

`doctor --fix` is deliberately narrow: it may create Boxa-owned directories,
repair the launcher link, refresh the secret-free runtime snapshot, and restore
derived untracked Claude or Codex renders. It never installs, starts a Boxa,
activates, grants trust, accepts degraded isolation, or edits a tracked
`.mcp.json` or Codex config without explicit authorization.
