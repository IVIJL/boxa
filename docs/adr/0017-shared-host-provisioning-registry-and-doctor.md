# ADR 0017 — Shared host-provisioning registry and `boxa doctor`

- **Status:** accepted
- **Date:** 2026-06-15

## Context

Boxa provisions host-side state through three entry points that have grown
apart:

- **`install.sh`** — the canonical first-time setup. Its `main()` runs an
  ordered list of steps: install git/keychain/xhost, configure ssh-agent, clone
  the repo, install mkcert, set up the allow-for host state, the agent-browser
  OS user / helpers / upstream skill / allowlist example, the boxa agent
  skill, MCP onboarding, the `boxa` symlink, shell completions, the Claude
  token, and the Docker checks.
- **`boxa update`** — re-pulls the repo and is *meant* to bring an existing
  install forward. Some of its checks run on every invocation (a chain of
  `ensure-*.sh --quiet-if-noop` self-heals: allow-for host state, agent-browser
  helpers/host-state, upstream skill, boxa skill, resolver drop-in). Others —
  shell completions and MCP onboarding — sit **behind the
  `BOXA_UPDATE_PULLED=1` gate**, i.e. they only run when `git pull` actually
  brought changes, alongside migrations and the image rebuild.
- There is **no `boxa doctor`** at all (only `boxa mcp doctor`, a subcommand
  for MCP profiles).

This produced a concrete failure, observed on a fresh **macOS** install: the
first install did not complete every step, and `boxa update` only "caught"
the remaining ones while successive `git pull`s kept bringing repo changes that
ran the gated block. Once the repo reached *"Already up to date"*, the gated
block (completions, MCP onboarding, migrations, rebuild) stopped running
entirely, and several install steps had **no `update`-side counterpart in the
first place**:

- `install_mkcert` (the mkcert **binary**) — no self-heal anywhere.
- `setup_agent_allowlist_example` — no `ensure-*` script exists at all.
- `setup_completions`, `setup_mcp_onboarding` — present in `update` but only
  behind the pull-changes gate.
- The prerequisites (`git`, Docker daemon, Docker group membership, the `boxa`
  symlink) — never re-checked.

The root cause is structural: each entry point carries **its own list** of what
to do, and the lists were kept in sync by hand. They drifted. A user with a
partially-provisioned host has no single, repeatable command that repairs it
independently of whether the repo changed.

## Decision

Make the **set of host-provisioning steps a single shared registry**, and add a
third entry point — `boxa doctor` — that runs it on demand.

### 1. One registry, three entry points

A new `lib/provisioning.sh` holds the registry as **declarative data**: an
ordered list of provisioning steps, each a triple `(id | script | category)`,
plus a dispatch function (e.g. `boxa::run_provisioning <mode> [step…]`). The
backing scripts stay the existing `ensure-<concern>.sh` files. Two missing ones
are added so the registry is complete:

- `ensure-mkcert.sh` — the mkcert binary (today inline in `install.sh`).
- `ensure-agent-allowlist-example.sh` — the allowlist example file (today inline
  in `install.sh`).

`install.sh`, the `boxa update` self-heal block, and `boxa doctor` all
source `lib/provisioning.sh` and drive the *same* list. No entry point owns
steps the others cannot run. This is the invariant that prevents the drift
above: a fresh install and an upgraded one converge on the same provisioned
state by construction, not by hand-maintained parallel lists.

### 2. Three step categories

Each step is classified in the registry by **whether it ever depended on a user
choice** — this, not "importance", decides how `doctor` treats it:

- **Unconditional step** (category A) — always performed; cheap, idempotent, no
  downside (the `boxa` symlink, completions, the boxa agent skill, the
  mkcert binary, allow-for host state, agent-browser helpers/host-state/upstream
  skill/allowlist example). Repaired silently.
- **Elective step** (category B) — gated on a past user choice with an opt-out
  or seen/dismissed marker (the HTTPS upgrade, MCP onboarding, the Claude
  token). The user may have deliberately declined it.
- **Environment prerequisite** (category C) — an external precondition boxa
  cannot reliably repair itself: a running Docker daemon, Docker group
  membership taking effect (needs re-login), a missing `git` (needs the package
  manager). Diagnosed, never silently mutated.

### 3. `boxa doctor`

`boxa doctor` runs the **whole registry independently of any repo change** —
this is the repeatable repair path the system lacked.

- **`boxa doctor`** (default) — repairs every **Unconditional step**
  silently; **reports** every missing **Elective step** and **Environment
  prerequisite** (with the exact command to fix each). It asks for **sudo only
  at the moment a step needs it**; run non-interactively without sudo, a
  sudo-requiring step degrades to a reported prerequisite rather than failing.
- **`boxa doctor --fix`** — additionally repairs **Elective steps**.
- **`boxa doctor --fix <step> […]`** — repairs only the named step(s); the
  step ids come from the registry, which is also what `doctor`'s report prints
  back as ready-to-run commands.

There is deliberately **no read-only/`--check` mode**: anything Unconditional is
immutable-and-mandatory, so the default already just fixes it. Reporting an
Elective step does require an internal "is-provisioned?" probe, but that is an
implementation detail of the step, not a user-facing mode.

`doctor`-specific diagnostics beyond the install/update registry can be appended
later as further registry steps, since every step is idempotent.

### 4. `boxa update` becomes fully self-healing for category A

The `BOXA_UPDATE_PULLED=1` gate is **narrowed to migrations and the image
rebuild** — the only things that genuinely make sense only after a real pull.
`completions` and `mcp-onboarding` move out of the gate into the always-run
self-heal chain (the whole of category A), so `boxa update` repairs a
partial install even when the repo is already up to date. MCP onboarding's
seen/dismissed marker keeps it quiet under `--quiet-if-noop`, so this does not
re-prompt.

## Consequences

**Positive:**

- A single, repeatable `boxa doctor` repairs a partially-provisioned host
  regardless of repo state — directly fixing the macOS fresh-install symptom.
- Install / update / doctor can no longer diverge: they share one declarative
  registry, so adding a future provisioning step wires all three at once.
- `boxa update` is now genuinely self-healing for all unconditional steps, not
  only when a pull brought changes.
- The A/B/C taxonomy gives a deterministic, reviewable rule for "fix silently
  vs report vs diagnose" instead of per-step ad-hoc judgement.

**Negative / limitations:**

- The inline `install.sh` step bodies for mkcert and the allowlist example move
  into `ensure-*` scripts; `install.sh` shrinks to "source the registry, run
  it" and loses some of its self-contained readability.
- `doctor` mutating by default (repairing category A) is mildly surprising for a
  command named "doctor"; this is intentional (immutable+mandatory steps have no
  reason to wait for a flag) and documented here and in `CONTEXT.md`.
- Each `ensure-*` script must expose a non-mutating "is-provisioned?" probe for
  the Elective report path; a step whose probe disagrees with its repair logic
  would mis-report, so probe and repair must share one internal predicate.
- Category boundaries can shift as features evolve (e.g. a step that becomes
  prompt-gated moves A→B); the registry is the single place to change it, but it
  is a judgement call that needs to stay accurate.

## References

- `lib/provisioning.sh` — the declarative registry `(id | script | category)`
  and the shared dispatch function (new).
- `scripts/ensure-mkcert.sh`, `scripts/ensure-agent-allowlist-example.sh` — the
  two steps extracted from `install.sh` so the registry is complete (new).
- `install.sh` — `main()` reworked to drive the registry instead of its own
  ordered step list.
- `docker-run.sh` — `boxa doctor` entry point; the `update` block with
  `completions` + `mcp-onboarding` moved out of the `BOXA_UPDATE_PULLED=1`
  gate.
- `CONTEXT.md` — "Host provisioning" language (provisioning step, unconditional
  / elective / environment-prerequisite, doctor).
- ADR 0005 — project naming; `migrate-*.sh --check` established the
  report-without-mutate convention this builds on.
- ADR 0016 — macOS host support; the fresh-Mac install that surfaced the drift.
