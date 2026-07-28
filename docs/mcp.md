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

The catalog, activations, tracked-render consents, acknowledgements, and
secrets are host-owned state under the user's Boxa configuration. They survive
host restarts, `boxa down`, and Container recreation. Installed npm runtime
lives in the persistent npm-global prefix; Docker images live in the Project's
persistent rootless Docker state. Agent config and the Container runtime
snapshot are derived and can be restored with `boxa mcp doctor --fix`.

An activation is keyed by the canonical absolute host path. Moving a directory
or creating a new clone produces another Project key and intentionally does not
inherit activation. Catalog entries remain available for an explicit new
activation.

## Consumers

Claude Code is rendered into the Project's `.mcp.json`; Codex uses the
Project's `.codex/config.toml` with a delimited managed region. The host
activation remains authoritative, and Boxa preserves all non-Boxa content.
For Git Projects it adds each otherwise-untracked render target to
`.git/info/exclude`, never `.gitignore`. Tracked `.mcp.json` and
`.claude/settings.local.json` writes share `--allow-tracked-mcp-json`: the
decision means Boxa may write its derived Claude Project files in that tracked
repository. A tracked Codex config requires
`--allow-tracked-codex-config`. The Claude flag grants and records durable
consent only for the Project explicitly targeted by that lifecycle command;
it does not authorize another Project included in an incidental re-render.
If any changed Claude Project file lacks consent, the complete multi-Project
render batch is refused before the first write. An already byte-identical
tracked file does not require consent.

For Claude Code, activation also seeds the rendered server name once into
`.claude/settings.local.json`. Boxa preserves unrelated Project settings and
does not seed that name again after the user disables it. Deactivation
withdraws the approval delivered by that seed and retires the seed so a later
reactivation delivers approval again. User-created approvals and unrelated
settings remain untouched. Decisions Claude Code records for Project servers,
including foreign ones, are mirrored there as approval or rejection and win
over withdrawal; unanswered servers remain unanswered.

Deactivation, removal, or a runtime-affecting update re-renders selected
consumers atomically. Restart/reload an already-running Claude or Codex session
to drop an old connection or pick up a changed definition.

## Container convergence

At every Container start and interactive shell initialization, Boxa reads the
node-readable, secret-free runtime snapshot and re-asserts the Project's
`.mcp.json` entries and Claude approval state. Missing or hand-edited Boxa
definitions are repaired, while foreign servers and unrelated settings remain
untouched. Approval follows the same one-time seeding and recorded-decision
rules as activation, so convergence does not re-enable a server the user
disabled. The snapshot publishes the durable per-Project Boxa-seeded approval
set; Container-local convergence state is only a cache, so recreation cannot
lose the information needed to withdraw a retired approval.

Convergence removes only a Boxa-owned entry that is no longer activated for
Claude in the snapshot. A missing, empty, malformed, or unreadable snapshot is
a reported no-op and never means that all entries should be removed. When the
render, approval, and local convergence state already match, no file is
rewritten.

If `.mcp.json` or `.claude/settings.local.json` is tracked and its rendered
bytes need to change, convergence refuses all writes for that Project unless
a host activation previously recorded durable consent through
`--allow-tracked-mcp-json`. This is a whole-Project refusal: convergence does
not update `.mcp.json` while declining its approval companion, or vice versa.
An already in-sync tracked file does not block repair of the other file.
When convergence writes either untracked file in a Git Project, it adds the
repository-root-relative path to `.git/info/exclude`.
Convergence revalidates the snapshot and rendered files immediately before
writing. A newly published snapshot is replanned; a rendered-file change
without a snapshot change is reported as a concurrent host write and left for
the next convergence.

The convergence command exits `0` after convergence, an in-sync check, or a
benign nothing-to-do result such as no Container Project. It exits `3` when an
operational condition prevented repair and prints the skip reason as a warning
on stderr even with `--quiet`; callers should surface that warning without
aborting Container setup or interactive shell startup. Exit `1` is a hard
failure and exit `2` is a usage error. JSON output retains the
`{"results": [...]}` shape and returns the same status code.

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

Container setup also removes the old Boxa-seeded
`enableAllProjectMcpServers` setting once without replacing unrelated Claude
settings. A durable migration marker ensures a later deliberate user choice is
not removed again.

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
