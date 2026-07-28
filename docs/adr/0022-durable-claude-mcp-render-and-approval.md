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
already carries both catalog entries and per-Project activations, and is
readable by the Container's agent account — and repairs the rendered
`.mcp.json` and the approval files for the Projects mounted in that Container.
It runs at Container start and at shell initialization, and is a no-op when
the state already matches.

Convergence never removes a rendered entry that is still present in the
snapshot. It removes only what the snapshot no longer carries, which is to
say only what `boxa mcp deactivate` removed. An activated MCP server is
therefore not lost until the user deactivates or disables it; anything else
that removes it is repaired at the next Container or shell start.

Automatic convergence does not broaden the consent to modify repository
bytes. An activation that writes a tracked `.mcp.json` with
`--allow-tracked-mcp-json` records durable consent for that canonical Project
in the host activation store and publishes it in the secret-free runtime
snapshot. Convergence refuses a changed tracked `.mcp.json` unless that
consent is present. It may still repair approval or convergence state when
the tracked file is already byte-identical, because those repairs do not
modify the tracked repository file.

## Migration

Boxa-written `boxa-*` entries in `~/.claude/.claude.json` are removed when the
new render target is established, in the same operation, so the two renderers
never coexist. Non-Boxa entries in that file, including servers the user or
another tool added, are left untouched. Existing activations are preserved and
re-rendered to the new target; the user does not re-activate anything.

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
  and must preserve any unrelated settings the user or Claude Code keeps there.
