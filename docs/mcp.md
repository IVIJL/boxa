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
A Project with no `.git` entry at or above it is a supported non-Git Project
and converges normally. If Git metadata exists but Git cannot use it — for
example a linked worktree or submodule whose gitdir is outside the Project
bind mount — the tracked state is unknown, so convergence skips with exit 3
and writes nothing instead of assuming the files are untracked.
Convergence revalidates the snapshot and rendered files immediately before
writing. A newly published snapshot is replanned; a rendered-file change
without a snapshot change is reported as a concurrent host write and left for
the next convergence.

A host lifecycle command publishes its mutation window in the runtime
directory for the whole transaction — from before its first write until after
it republishes the snapshot. Convergence observes that window before planning
and again after writing, and defers ("a host MCP mutation is in progress")
rather than restoring a render the host has just replaced but not yet
published. Observation is read-only; the Container never takes the host
mutation lock, and a Container can never delay a host mutation.

All convergence writes are compensated as one set: any later failure, race, or
deferral restores the exact pre-images, so a Project is never left with a
repaired `.mcp.json` and an unrepaired `.claude/settings.local.json`.

### Concurrent edits are never clobbered

Every write Boxa makes to a rendered or shared file — on the host and inside a
Container alike — goes through one compare-and-swap primitive. The file is
re-read at the last possible moment — after Boxa's temporary file is written and
flushed to disk, immediately before the replace — and compared with the exact
pre-image the rendered content was derived from, including whether the file
existed at all, so deleting it or creating it empty counts as a change. An edit
that lands while Boxa is preparing the new content is therefore refused, not
overwritten. If Claude Code, Git, or you changed it in between, Boxa writes
nothing and says so:

* convergence reports a skip ("concurrent write to the rendered file was
  detected") after a bounded number of retries and repairs it on the next run;
* a host command (`activate`, `deactivate`, `doctor --fix`, `migrate`) aborts
  the whole batch, takes back everything it had already written, and names the
  path that changed — re-run the command to render from fresh bytes;
* `boxa mcp render` refuses with `<path> changed on disk while Boxa was
  rendering it; nothing was written — re-run the command` and exits non-zero.

What remains is the rename itself: the filesystem has no compare-and-swap
rename, so an edit written in the same instant as Boxa's replace can still be
lost. Everything before that instant is covered.

Rollback is equally careful, and checks at exactly the same last moment: it
restores a file only while its bytes are still the ones Boxa wrote, re-read
after the rollback's temporary file is complete and immediately before the
replace, so an edit made after Boxa's write — including one landing while the
rollback is preparing that temporary file — is reported instead of being erased.
The unrestored path is named together with the failure that triggered the
rollback, so you still see why the batch failed. The same single instant, the
replace (or the delete of a file Boxa created), is all that remains uncovered.
`.git/info/exclude` is only ever appended to — a single atomic append, so a Git
or user edit that lands while Boxa is writing survives — and a rollback removes
just Boxa's own ignore line, leaving concurrent Git or user edits untouched; if
the file changed while the undo was computing that removal, Boxa leaves the file
alone and reports it rather than deleting or rewriting the newer content.

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

Migration re-renders the migrated activations and therefore obeys the same
tracked-file rule as every other lifecycle path. It preflights every affected
Project and refuses the whole migration, naming each offending path, when a
tracked `.mcp.json` or `.claude/settings.local.json` would change without
consent. Consent already recorded durably for a Project authorizes it;
otherwise use `boxa mcp migrate --allow-tracked-mcp-json`, which authorizes
that one batch and — like any catalog-wide mutation — records no new durable
per-Project consent.

Retiring `~/.claude/.claude.json` as a render target is a separate upgrade with
its own durable marker, so an install whose legacy migration is already
complete — or that never had legacy profiles at all — still receives it exactly
once. `boxa mcp migrate` removes the Boxa-written entries from that file,
re-renders the existing activations into each Project's `.mcp.json`, and
republishes the runtime snapshot, leaving foreign entries and foreign
formatting untouched. It obeys the same tracked-file rule and the same
`--allow-tracked-mcp-json` batch consent as the legacy migration, and is a
no-op once the marker exists.

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
