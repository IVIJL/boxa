# ADR 0022 — Durable Claude MCP render and approval

- **Status:** accepted
- **Date:** 2026-07-28
- **Revises:** ADR 0021's Claude half of "Consumer rendering"; ADR 0013's
  render-into-agent-config semantics for Claude Code

## Context

ADR 0021 renders Claude Code activations into the Container-visible
`~/.claude/.claude.json`. That file is not Boxa's. Claude Code owns it,
keeps it open across a session, rewrites it on its own schedule, restores it
from its own rotating backups when it considers the file damaged, and shares
it across every Container through a single bind mount. Boxa writes the whole
file too, read-modify-write with an atomic replace. Two independent writers,
no shared lock, one file.

The observed failure is exactly what that topology predicts. An activation
rendered successfully, Boxa's render state recorded it, and some time later
the rendered entries were simply absent from the file. `boxa mcp status`
reported `claude:drift` and `boxa mcp doctor --fix` restored them. Which
writer dropped them could not be established after the fact — Claude Code
rotates only a handful of backups and they had all been recycled.

The forensic answer does not actually matter, because two structural facts
make the loss permanent rather than transient:

- Nothing re-asserts the render. Not Container start, not session start.
  Once the file drifts, it stays drifted until the user runs a host command
  they have no reason to know exists.
- Restarting Claude Code cannot help, since the restart reads the same
  drifted file.

Codex already avoids all of this. Its activations render into the Project's
`.codex/config.toml`, a file Codex reads and never rewrites.

Moving Claude to the Project's `.mcp.json` closes the same gap, but only
halfway. `.mcp.json` is designed as a **shared, committed** file, so Claude
Code deliberately does not trust its servers on sight: it asks the user per
Project and stores the answer back in `.claude.json` under
`enabledMcpjsonServers` / `disabledMcpjsonServers`. The definition would
become durable while the approval that makes it usable stayed in the fragile
file.

## Decision

### Claude renders into the Project's `.mcp.json`

Claude Code activations render into `<project>/.mcp.json` as a derived
artifact, mirroring the Codex rule in ADR 0021. Boxa writes only the keys it
owns and preserves all other content. If the file is otherwise untracked,
Boxa adds it to the repository-local `.git/info/exclude`, never to the shared
`.gitignore`. A tracked `.mcp.json` is not changed without explicit per
mutation consent, for the same reason a tracked Codex config is not.

The rendered entry carries a wrapper command and its arguments only. As in
ADR 0021, no secret value and no environment value is ever written into an
agent config; secrets reach the server through the broker's staged store at
launch. This makes the ignore rule a hygiene measure against machine-specific
content — absolute Project paths, local catalog identity, and a wrapper that
does not exist outside a Boxa Container — not a secret-containment measure.

Boxa stops writing Claude MCP entries to `~/.claude/.claude.json` and removes
the ones it previously wrote there, so exactly one rendered source of truth
exists at any moment.

### Activation is the consent; approval is its delivery

Running `boxa mcp activate` **is** the user's decision to expose that server
in that Project. Claude Code's per-Project approval prompt exists to defend
against a `.mcp.json` that arrived with a cloned repository, which is not the
case for an entry Boxa itself just rendered from the user's own activation.
Boxa therefore delivers that already-given consent instead of asking for it a
second time in another tool: it seeds the rendered name into
`enabledMcpjsonServers` in the Project's `.claude/settings.local.json`.

Seeding is narrow and derived from Boxa's own render state — the exact set of
names Boxa rendered in that run — never from a prefix match against whatever
the file happens to contain. A foreign server named like a Boxa one therefore
has no path to automatic approval. `enableAllProjectMcpServers` is rejected
outright: it would extend trust to servers Boxa did not write and the user
never saw.

Seeding happens **once per name**. A name already seeded is never seeded
again, so a user who disables the server through Claude Code's own controls
stays disabled across every later render. This mirrors the one-time
default-disable decision the legacy profile writer already records.
When a rendered name is retired, Boxa also withdraws the approval that its
seed delivered. Only names recorded in Boxa's previous seeded set are
withdrawn; unrelated approvals remain untouched. A recorded Claude Code user
decision is applied after withdrawal, so an explicit approval or rejection
still wins.

### Foreign servers must be approved by the user, once

A `.mcp.json` server Boxa did not render is never seeded. The user approves it
through Claude Code's own prompt, exactly as the prompt intends. Once that
decision exists, Boxa mirrors it — approval and rejection alike — into the
Project's `.claude/settings.local.json`, so losing `.claude.json` does not
lose the decision and the user is not asked a second time.

Boxa observes and persists these decisions; it never originates them.

### Convergence is the guarantee

Neither a better file nor a narrower approval rule guarantees anything on its
own; both only shrink the window. The guarantee comes from re-asserting the
intended state before the user needs it.

A convergence step reads the secret-free broker runtime snapshot — which
already carries catalog entries and per-Project activations, and now also
publishes each Project's Boxa-seeded approval set — and repairs the rendered
`.mcp.json` and the approval files for the Projects mounted in that Container.
The published set survives Container recreation, while the Container-local
convergence state remains a cache. Convergence runs at Container start and at
shell initialization, and is a no-op when the state already matches.

Convergence never removes a rendered entry that is still present in the
snapshot. It removes only what the snapshot no longer carries, which is to
say only what `boxa mcp deactivate` removed. An activated MCP server is
therefore not lost until the user deactivates or disables it; anything else
that removes it is repaired at the next Container or shell start.

Automatic convergence does not broaden the consent to modify repository
bytes. `.mcp.json` and `.claude/settings.local.json` are one pair of derived
Claude Project files for this purpose. An activation that writes either
tracked file with `--allow-tracked-mcp-json` records durable consent for that
canonical Project in the host activation store and publishes it in the
secret-free runtime snapshot. The flag is one user decision that Boxa may
write its derived Claude files in that tracked repository; it is not a
`.mcp.json`-only exception.

Host rendering classifies both files before any lifecycle write. If either
render would change tracked bytes without consent, the whole multi-Project
batch is refused and the error names every offending path. A byte-identical
tracked file does not block. Whenever Boxa actually writes either untracked
file in a Git Project, including through approval-decision mirroring, it adds
the repository-root-relative path to `.git/info/exclude` and never changes
the shared `.gitignore`.

Status and doctor report the two facts separately. Whether a derived Claude
Project file is tracked is a repository fact, shown in the status payload and as
the CLI `:tracked` marker whenever `.mcp.json` or `settings.local.json` is
tracked. Whether a repair needs consent is the narrower question the preflight
answers, and a tracked file that is already byte-identical needs none. Doctor
fixability follows consent, never the bare tracked fact.

Convergence uses the same tracked classification and durable consent. A
changed tracked file without consent refuses all writes for that Project, so
the render and approval files cannot be half-applied. A byte-identical tracked
file may coexist with repair of the other file. Untracked files written by
convergence receive the same repository-local exclude entries.

Tracked-file consent is scoped to the Project explicitly mutated by the
lifecycle command. Existing durable consent may authorize that Project during
an incidental multi-Project re-render, but a flag supplied for one Project
does not authorize or persist consent for another. Catalog-wide mutations may
use the flag for their current render batch, but record no new durable consent.

Container convergence cannot share the gated host mutation lock. Instead it
revalidates the exact runtime snapshot bytes and both rendered-file pre-images
immediately before writing, retries from a newer snapshot up to a fixed bound,
and skips when a rendered file changed while the snapshot did not. It checks
the snapshot again after writing so a concurrently published host mutation is
replanned before convergence returns.

Comparing snapshots alone cannot close the whole window: a host mutation that
has already written the Project files but has not yet republished the snapshot
is invisible to it, so convergence could plan from the old snapshot, restore
the old render, and still pass its post-check. The host therefore **publishes
its mutation window**, without publishing the lock itself. It holds an
exclusive advisory lock, for the entire transaction, on a read-only marker file
inside the runtime directory Containers already mount. Convergence probes that
lock — shared, non-blocking, released immediately — before planning and again
after writing, and defers when the window is open. Because the window opens
before the first host write and closes only after the snapshot is republished,
every interleaving is caught by either the probe or the snapshot comparison.
The lock lives in an open file description, so a crashed host releases it and
the window can never go stale. The Container only ever reads; it still cannot
reach the gated host store, and a probe the host cannot immediately take is
bounded and then ignored, so a Container can never stall a host mutation.

Residual risk: the probe is deliberately fail-open. On a filesystem without
working advisory locks the window is unobservable and convergence degrades to
the snapshot comparison alone, which is the pre-existing behaviour.

Every convergence write — `.mcp.json`, `settings.local.json`, the
Container-local convergence state, and the repository-local exclude entries —
is compensated as one set. Any failure after the first successful write,
operational or racing, restores the accumulated pre-images, so a Project is
never left half-converged. A pre-image whose bytes changed under convergence is
left alone rather than clobbered, and the skip names it.

A benign not-applicable convergence result, such as no identifiable Container
Project, a missing Project directory, or a pristine installation where the
runtime directory is mounted but the host has never published a snapshot,
exits zero. A snapshot that once existed is different: after any evidence of an
earlier publication — a snapshot file that is present but empty, corrupt or
unreadable, recorded convergence state for the Project, or a boxa-managed
render left in the Project — a missing or unusable snapshot stays an
operational skip. An operational skip such
as invalid input, absent tracked-file consent, or a concurrent-write race
exits `3` and remains visible as a stderr warning under `--quiet`. Hard
failures exit `1`, usage errors exit `2`, and successful convergence,
in-sync state, and nothing-to-do results exit `0`. Container setup and
interactive shell wiring surface nonzero convergence without letting it abort
startup. JSON keeps the full results payload and follows the same exit-code
contract.

## Migration

Boxa-written `boxa-*` entries in `~/.claude/.claude.json` are removed when the
new render target is established, in the same operation, so the two renderers
never coexist. Non-Boxa entries in that file, including servers the user or
another tool added, are left untouched. Existing activations are preserved and
re-rendered to the new target; the user does not re-activate anything.

Retiring that render target is a distinct upgrade from the legacy-profile
migration and therefore carries its own durable marker rather than riding on the
legacy manifest's `complete` status. An install that already migrated, or that
never had legacy profiles, still receives the retirement exactly once: the
Boxa-written entries are removed, the existing activations are re-rendered into
each Project's `.mcp.json`, and the runtime snapshot is republished afterwards so
the seeded approval set it carries is the one the re-render just recorded. The
retirement writes the retired file only when it actually removes something, so
foreign entries keep their bytes. It is idempotent and compensated as one set
like every other lifecycle write.

Migration is a lifecycle write like any other and gets no exemption from the
tracked-file rule. It runs the same preflight over every Project it would
re-render, and refuses the whole batch — naming every offending path — when a
tracked `.mcp.json` or `.claude/settings.local.json` would change without
consent. Durable per-Project consent already recorded in the activation store
authorizes those Projects. Migration has no single explicitly mutated Project,
so, exactly like a catalog-wide mutation, its `--allow-tracked-mcp-json`
authorizes only that one batch and records no new durable consent. A Project
whose directory has vanished still does not block migration.

Earlier Boxa defaults seeded `enableAllProjectMcpServers` in the shared
`~/.claude/settings.json`. Container setup performs a concurrency-safe,
one-shot upgrade migration that removes only that top-level key and preserves
all other settings. A durable marker is written even when the key or file is
absent, so a user who deliberately restores the setting after migration keeps
that choice. Unreadable or invalid JSON is left untouched and reported for a
later retry.

## Consequences

- An activated Claude MCP server survives Claude Code restarts, Container
  recreation, and any third-party rewrite of `~/.claude/.claude.json`.
- Claude and Codex activations gain the same shape: a delimited Boxa-owned
  region in a Project file, a repository-local ignore rule, and explicit
  consent before touching tracked bytes.
- The user is asked to approve a Boxa-rendered server zero times and a foreign
  `.mcp.json` server exactly once.
- A user who disables a Boxa server through Claude Code keeps it disabled; Boxa
  will not re-enable it on the next render.
- Drift becomes self-correcting, so `boxa mcp doctor --fix` returns to being a
  diagnostic escape hatch rather than the only recovery path.
- Boxa now writes one additional Project file, `.claude/settings.local.json`,
  must preserve any unrelated settings the user or Claude Code keeps there,
  and applies the same local-exclude and tracked-write consent policy used for
  `.mcp.json`.
