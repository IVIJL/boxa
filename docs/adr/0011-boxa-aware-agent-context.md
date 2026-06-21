# ADR 0011 — Boxa-aware agent context via host-shared skill and container-only identity hook

- **Status:** proposed
- **Date:** 2026-05-20

## Context

LLM coding agents (Claude Code, Codex CLI, and a long tail of others
via the [agentskills.io](https://agentskills.io) standard) run both
**on the host** (driving `boxa` itself) and **inside the
Container** (doing project work). The two contexts behave very
differently:

- On host: `boxa` CLI exists, network is unrestricted, the agent's
  job is to orchestrate containers, allow-for windows, and
  Agent-browser sessions on the user's behalf.
- Inside Container: `boxa` CLI does **not** exist, network is
  default-deny against the **Allowlist** (~15 domains), and the
  agent's job is to recognise boxa-specific failure modes
  ("`curl` to a non-allowlisted host will be rejected — ask the user
  to run `boxa allow <domain>` on host"), use the **Agent-browser**
  CLI through the bridge, and not waste turns trying host-only
  commands.

Without boxa-aware context the agent makes recurring mistakes:
runs `boxa` inside the container and gets "command not found"; reads
a `curl` 503 as a server bug rather than an allowlist deny; tries
`agent-browser connect 9222` despite the auto-connect wrapper
(commit `f9e30fa`); proposes the wrong Chrome session lifecycle
commands. Each of these is solvable by a one-paragraph piece of
context, but only if the agent has the context at the right moment.

The hard sub-problems:

- **Multi-agent.** Claude Code reads `~/.claude/skills/`, Codex reads
  `~/.codex/skills/`, agentskills.io standard is `~/.agents/skills/`.
  Single source must reach all three without `cp`-then-stale-fork.
- **Host/container differentiation must be deterministic.** Agent
  must know "am I on host or inside?" without relying on the user
  saying so or on heuristic CWD parsing.
- **Distribution must survive a fresh install and follow updates.**
  A boxa user who installs from scratch must end up with the
  context in place; an existing user who updates must get any
  refinements. No "you forgot to run extra script after install."
- **Must not overwrite the user's own agent hook configurations.**
  Other boxa users may have private hooks in `~/.claude/settings.json`
  or `~/.codex/config.toml`. We add ours; we never replace theirs.
- **Must not duplicate the upstream `vercel-labs/agent-browser`
  skill.** Two `agent-browser` skills installed at the same level
  produce nondeterministic resolver picking; the upstream skill is
  the canonical source of Agent-browser CLI guidance.

## Decision

A three-layer agent-context stack:

### Layer 1: Container identity file

The container entrypoint (root phase, mirroring its existing
`/etc/gitconfig` staging) writes
`/etc/boxa/identity.json`:

```json
{
  "project": "easyjukebox-eu"
}
```

- Root-owned, world-readable (`0644`), `/etc/boxa/` directory
  created idempotently. Mirrors the existing `/etc/boxa-shared/`
  naming convention (per-container, container-only). Distinct from
  `/etc/boxa-shared/` which is bind-mounted shared state.
- Single field today: `project`. JSON for future extensibility
  (`image_version`, `started_at`, etc., should diagnostic need arise).
- Container hostname is the same value (`boxa-<project>`), but the
  identity file is the canonical source of truth: hostname may be
  repurposed; the file is owned by us.
- **Presence of the file is the signal.** Agents detect "I am
  inside a boxa container" by `test -f /etc/boxa/identity.json`;
  the `project` value is consumed to construct host-side command
  examples.

This is the canonical `Container identity` (CONTEXT.md, § Project /
container).

### Layer 2: Boxa skill (host-shared, multi-agent)

A single skill named `boxa` (not user-invocable; `disable-model-
invocation: false`), source-of-truth at
`<boxa-repo>/skills/boxa/SKILL.md`.

- Installed by `install.sh` (and refreshed by `boxa update`) to
  `~/.agents/skills/boxa/SKILL.md` on the host.
- Symlinks created (idempotently) at:
  - `~/.claude/skills/boxa -> ../../.agents/skills/boxa`
  - `~/.codex/skills/boxa -> ../../.agents/skills/boxa`
- All three locations are bind-mounted into every Container per
  ADR 0002, so containers see the skill automatically without
  per-container provisioning.

Skill body is a **minimal pointer** (~150 lines), structured as:

1. **Identity check.** First instruction reads
   `/etc/boxa/identity.json` and branches host vs container.
2. **Inside container section.** Boundaries (CLI is host-only,
   default-deny network, dev URL bypass), pattern recognition for
   common failures (out-of-allowlist deny), instructions to ask the
   user to run specific `boxa …` commands on host. Points to
   CONTEXT.md and ADRs for depth.
3. **On host section.** Most-used `boxa` CLI surface; project
   lifecycle, allow-for, agent-browser session orchestration; ports
   and HTTPS. Points to `boxa --help` and ADRs.
4. **Agent-browser integration glue.** ~20 lines: auto-connect
   wrapper exists (commit `f9e30fa`), session lifecycle is on host,
   dev URLs bypass proxy. Defers CLI surface entirely to the upstream
   `agent-browser` skill.
5. **Canonical references.** Pointers to CONTEXT.md glossary and
   ADRs 0001, 0007, 0009, 0010, this ADR.

The skill is deliberately not encyclopedic: CONTEXT.md and ADRs are
the canonical knowledge sources; the skill is a navigator to them
plus operational rules. This keeps the skill content lifecycle cost
(per Claude Code docs: "content stays in context across turns")
proportionate to the agent's actual need.

### Layer 3: Container-only context hook

The skill triggers on user phrasing — if the first prompt is
neutral ("run the tests"), the skill may not fire, and the agent
acts without boxa context. To eliminate that first-turn gap,
both Claude Code and Codex run a hook script at session start that
emits container identity context **only when the identity file
exists**.

Hook script: `scripts/hooks/boxa-identity-context.sh`, baked
into the container image. The script guards on identity-file
presence (`[ -f /etc/boxa/identity.json ] || exit 0`), so the
same configuration is a no-op on the host even though config files
are shared.

Hook configuration is installed via each agent's **managed-settings
layer**, not the user-owned config files:

- Claude Code: drop-in JSON at
  `/etc/claude-code/managed-settings.d/50-boxa-identity.json`
  registering a `SessionStart` hook. Claude Code merges managed
  settings additively with `~/.claude/settings.json`.
- Codex CLI: TOML at `/etc/codex/managed_config.toml` registering
  a `SessionStart` hook.

Both `/etc/claude-code/` and `/etc/codex/` are baked into the
container image via `Dockerfile COPY`. They are container-only paths
(distinct from any `/etc/` on the host, even on Linux native, since
the container has its own root filesystem); the host's
Claude/Codex installs are not touched.

The hook output is ~12 lines: identity (project name), the three
boundary facts (host-only CLI, default-deny network, dev URL
bypass), and a pointer to the `boxa` skill for full guidance.
Cost is fixed per session for Claude Code and Codex (`SessionStart`
fires once).

### Upstream agent-browser skill

The upstream `vercel-labs/agent-browser` skill is installed by
`install.sh` (and refreshed by `boxa update`) via:

```sh
npx --yes skills@latest add vercel-labs/agent-browser \
    --skill agent-browser \
    --agent claude-code codex \
    --global \
    --yes
```

The `skills` CLI writes the skill content to
`~/.agents/skills/agent-browser/` and creates per-agent symlinks
(`~/.claude/skills/agent-browser`, `~/.codex/skills/agent-browser`)
to match the same multi-agent layout we use for `boxa`. The
install command **must run on host** because `~/.agents/` is
read-only inside the container per ADR 0002.

The existing project-scope skill at
`<boxa-repo>/.claude/skills/agent-browser/SKILL.md` is **deleted**
once upstream is installed: it duplicated content the upstream skill
covers, and the project-scope location is wrong for a cross-cutting
concern (every container ever spawned needs it, not just boxa repo
sessions). The few boxa-specific paragraphs the local skill
contained (auto-connect wrapper, dev URL bypass, session lifecycle
on host) move into the integration-glue section of the `boxa`
skill.

### Distribution & lifecycle summary

| Concern | Location | Hook |
|---|---|---|
| Container identity file | `/etc/boxa/identity.json` (container) | `scripts/boxa-entrypoint.sh` root phase |
| Boxa skill source | `<boxa-repo>/skills/boxa/SKILL.md` | committed to git |
| Boxa skill install | `~/.agents/skills/boxa/` (host) | `install.sh` + `boxa update` |
| Boxa skill per-agent symlinks | `~/.claude/skills/boxa`, `~/.codex/skills/boxa` (host) | same |
| Upstream agent-browser skill | `~/.agents/skills/agent-browser/` + agent symlinks (host) | `install.sh` + `boxa update` via `npx skills add` |
| Identity hook script | `/usr/local/bin/boxa-identity-context.sh` (container) | image bake via Dockerfile |
| Claude managed-settings fragment | `/etc/claude-code/managed-settings.d/50-boxa-identity.json` (container) | image bake |
| Codex managed-config | `/etc/codex/managed_config.toml` (container) | image bake |

Host install runs once at `install.sh` and refreshes at every
`boxa update`. Container artifacts ride with the image rebuild
cadence. The two cadences are decoupled: skill content (changes
often) is live from host file system; hook + managed configs (rarely
change) are baked.

## Considered options

### Single comprehensive skill vs separate host and container skills

Two skills (`boxa-host` and `boxa-container`) was the first
candidate. Rejected because identity is a deterministic fact, not a
trigger-description match: an agent inside a container asking "how
do I run `ports`?" should learn "ask the user to run
`boxa ports <project>` on host", not "you run `boxa ports`". A
single skill that branches on `/etc/boxa/identity.json`
existence is the correct shape: the agent reads identity once and
follows the right path.

### One large skill that absorbs Agent-browser content

We considered making `boxa` an all-in-one skill with the full
Agent-browser two-gate model inline. Rejected: it would (a) duplicate
the upstream `agent-browser` skill, (b) collide if the user has
upstream installed, (c) inflate the skill's in-context cost beyond
the minimal-pointer ceiling. Splitting concerns — upstream for
Agent-browser CLI guidance, our `boxa` skill for integration glue
— keeps both skills focused.

### Identity file format

- JSON (`{"project": "..."}`) — chosen. `jq` is available image-wide,
  paths with spaces handled cleanly, easy to extend.
- Plain `/etc/boxa/project` with raw text — simpler today, but a
  migration to add `image_version` later breaks any parser written
  against the plain format.

### Identity file path

- `/etc/boxa/identity.json` — chosen. Root-owned, container-only,
  paralle to existing `/etc/boxa-shared/`.
- `~/.config/boxa/identity.json` — rejected. `~/.config/boxa/`
  is already used on host for `allowed-domains.conf` and
  `ssh_config`; container-only data overlapping a host-shared
  per-user config path is confusing.

### Skill registration: user config vs managed-settings

Putting the hook entry in `~/.claude/settings.json` /
`~/.codex/config.toml` would clobber any pre-existing user hook
entries on boxa install. Instead we use each agent's managed-
settings layer (`/etc/claude-code/managed-settings.d/` and
`/etc/codex/managed_config.toml`), which is additive with the user
config by design. The user's private hooks survive.

### Distribution: bake everything into image vs live bind-mount

The skill body lives where users edit it (the boxa repo,
host-side, bind-mounted into containers via `~/.agents/`), so
revisions land without an image rebuild. The hook script and
managed-settings fragments are infrastructure that rarely changes,
and they live at container-only `/etc/` paths that would be hard
to bind-mount cleanly — so they ride the image. Mixed cadence is
intentional: edit-often vs ship-once.

### npx skills add interactive prompts

The upstream `skills` CLI is interactive by default (scope select,
agent prompts, overwrite confirmation, symlink choice). With `-y` /
`--yes` plus explicit `--global --agent claude-code codex --skill
agent-browser`, all prompts are pre-answered and the run is
deterministic for use in `install.sh`. Tested headless multi-agent
install succeeds on host (read-write `~/.agents/`); fails on
container with `EROFS` (read-only `~/.agents/`), which is correct —
install always runs host-side.

## Consequences

**Positive.**

- A fresh boxa install gives every container an agent that knows
  its identity from turn 1, recognises default-deny failures, and
  points at the right host-side commands without dead-end attempts.
- Multi-agent (Claude Code + Codex + future agents via the standard
  `~/.agents/skills/` location) reached with a single host-side
  install path.
- User-owned hook configurations on host are never modified by
  boxa install/update.
- The `boxa` skill stays small (~150 lines) and points at canonical
  knowledge (CONTEXT.md, ADRs), so a refactor of the domain language
  there propagates without skill rewrite.
- Upstream Agent-browser skill carries the Agent-browser CLI surface;
  if vercel-labs ships changes we re-install via `boxa update` and
  pick them up.

**Negative.**

- One more boxa-owned file in each container's `/etc/` namespace
  (`/etc/boxa/identity.json`); one more host-side install step in
  `install.sh` (the `npx skills add` call) which requires `npx` to
  be available on the host.
- The container hook adds one small session-start shell exec and
  emits ~12 lines of static context after the identity guard.
- The `boxa` skill description must remain accurate as the CLI
  surface evolves; routine `boxa <subcommand>` additions don't
  require updates (the skill points to `boxa --help`), but
  semantic changes to allow-for windows or Agent-browser lifecycle
  would.
- A pre-existing boxa user who has manually customised the
  upstream `agent-browser` skill on host would have those changes
  overwritten by the `boxa update` re-install. Acceptable trade —
  if the user has truly forked it they are off the supported path
  anyway; a release note when we ship the auto-refresh suffices.

## Future work

- **Optional `agent-browser` skill audit** in `boxa update` —
  detect that the upstream skill matches a known-good version,
  surface "upstream version X differs from boxa-tested version Y"
  if it diverges materially.
- **`/etc/boxa/identity.json` schema growth** — `image_version`
  and `started_at` are the most likely additions; both inform agent
  diagnostics ("your container is on a stale image, rebuild" /
  "session has been running 14h, expect token-refresh churn").

## References

- ADR 0002 — shared Claude config via bind mount (the constraint
  that makes `~/.claude/`, `~/.codex/`, `~/.agents/` host-shared).
- ADR 0003 — privileged entrypoint as root-phase write authority.
- ADR 0004 — host-path CWD parity (the reason `host_workspace`
  is not in the identity file).
- ADR 0005 — sanitized basename as canonical Project name (what
  goes into `identity.project`).
- ADR 0010 — Agent-browser broker + proxy (cross-referenced by
  the integration-glue section of the `boxa` skill).
- Claude Code docs — Skills:
  <https://code.claude.com/docs/en/skills>
- Claude Code docs — Hooks:
  <https://code.claude.com/docs/en/hooks>
- Upstream skill: <https://github.com/vercel-labs/agent-browser>
- agentskills.io standard: <https://agentskills.io>
- Original session transcript and decision tree:
  `local-plan-boxa-skill.md`.
