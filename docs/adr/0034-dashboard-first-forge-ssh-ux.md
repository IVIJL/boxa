# ADR 0034 — Persona catalog and dashboard-first forge/SSH UX

- **Status:** accepted
- **Date:** 2026-08-25
- **Extends:** ADR 0033 (catalog/assignment pattern, migration asks
  kind, guarded remove, multi-machine key attachment), ADR 0006 (picker
  conventions), ADR 0017 (provisioning registry)
- **Supersedes:** ADR 0033 decisions 1–3 (per-forge identity entity,
  per-forge assignment and defaults) and the per-forge identity file
  naming of decision 4; ADR 0032 decision 2 (three-state SSH gate) and
  its posture checklists; the ADR 0026 "one global agent, keys held
  only in memory" consent design (the ADR 0026 invariants themselves
  stand)

## Context

Live verification of the ADR 0033 catalog stopped on UX findings, and
two follow-up design sessions pinned the causes. The linear setup
checklist asks posture questions (own account / machine account /
PAT-only) whose answers are already implied by what the user attaches;
the three-state SSH gate (`off`/`agent`/`user`) forces a mode choice
that really means "whose keys does this project get"; and the single
global boxa agent is empty by default with keys held only in memory, so
every host restart silently drops them and the user re-runs
`boxa ssh add` per project — the top recurring pain point. ssh-agent
offers every loaded key to every client, so selectivity cannot come
from filtering one shared agent; it can only come from more agents.

Grilling the fixes went one level deeper than the first redesign pass:
the per-forge identity entity of ADR 0033 ("one identity = one account
on one forge", one assignment per forge per project) kept resurfacing
as the source of confusing questions. What the user actually assigns to
a project is a principal — "the agent", "me", "the company" — with
everything that principal has configured. That observation changes the
catalog entity itself, which the first pass had explicitly tried to
avoid.

## Decision

1. **The catalog entity is the persona.** A **persona** is a named
   credential bundle owned by one principal: its SSH keys plus at most
   one token per forge (GitHub token, GitLab host+token), with `kind`
   (`mine`/`agent`/`other`) kept as a descriptive label. Names are
   user-chosen (`agent`, `milos`, `gaia`…) — ADR 0033 rejected chosen
   names because `<forge>:<username>` was collision-free, but a persona
   spans forges, so derivation is gone and the name is the ID.

2. **A project has at most one persona — whole.** Assignment replaces
   the project's previous persona completely: the project gets exactly
   what the persona has configured, and nothing of what it lacks. The
   ADR 0033 per-forge combination (GitHub → agent, GitLab → mine in one
   project) is deliberately dropped: taking one forge away from the
   agent is done forge-side (remove its project membership on GitLab),
   not by splitting the assignment. One user-wide **default persona**
   replaces the per-forge defaults; the explicit per-project `none`
   override stays.

3. **Storage: one file per persona.** `~/.config/boxa/forge/identities/
   <name>` (0600, same `key=value` grammar) holds kind, key
   references, and the per-forge token/host/username fields. The
   ADR 0033 per-forge identity files migrate: entries sharing a kind
   are offered as a merge into one persona (`github:agent` +
   `gitlab:<host>:agent` → persona `agent`), otherwise converted 1:1
   with a prompted name. `forge.conf` per-project sections collapse to
   one `identity = <name> | none` key; the global default likewise.
   Old parsers fail closed on the new grammar — the same accepted
   one-way upgrade as ADR 0033.

4. **Dashboard-first surface.** `boxa forge` and `forge setup` open the
   same state view: personas (kind, keys with fingerprints, which
   forges are configured, token ages), assignments per project, and
   what is missing — with actions offered from that context. The linear
   checklist survives only as the "add a persona" action. Dashboard,
   setup, the doctor wizard, and migration share one set of flow
   components; there is no third UI.

5. **The posture picker is removed.** Registering a persona means
   naming it, answering one label question ("whose account is this?"),
   pasting a token per forge it should cover, and optionally attaching
   SSH keys. PAT-only is not a posture but the natural consequence of a
   persona with no attached key.

6. **Transport policy: SSH signs git, the token drives the API.** An
   attached SSH key is the primary git transport; the token is mandatory
   alongside it because `gh`/`glab` (PRs, MRs, issues) need it. No HTTPS
   remote rewriting, no ssh-add destination constraints (noted as
   possible future hardening only). Non-forge git hosts (Forgejo, plain
   servers) are ordinary SSH servers outside the catalog.

7. **The SSH gate collapses to off/on.** What `on` forwards is the
   assigned persona's keys, not a mode. Old modes map cleanly: `agent`
   = on with an agent-kind persona, `user` = on with a mine-kind
   persona. Each project with the gate on gets a **dedicated
   per-project ssh-agent** on the host — its own socket (directory
   bind-mounted into the box, per the ADR 0032 inode rationale),
   holding exactly the assigned persona's keys, ~1–2 MB RAM each. Never
   a load/unload dance on a shared agent. Because a project has one
   persona, every offered key belongs to one principal and plain ssh
   try-in-order authentication is correct — no generated ssh config, no
   per-host key mapping.

8. **A persona may own several keys.** New `ssh-keygen` into the agent
   identity dir or takeover of an existing key; the flow surfaces the
   GitHub caveat that one auth key authenticates exactly one account.

9. **Key registry with lazy silent re-add.** Added keys are remembered
   forever as paths (never private material, preserving the ADR 0026
   invariant). Re-add is lazy: a project agent is re-populated from the
   registry when that project's container starts, not in one sweep
   after a host restart. A passphrase-protected key therefore costs one
   prompt per project at its first start after a restart — never ten
   prompts at once — and passphrase-less Agent keys restore silently.
   Boxa never handles the passphrase itself (no askpass helper, no
   keyring); `ssh-add` prompts. Enabling the gate on a project with no
   assigned persona offers the assignment/add flow inline instead of
   failing to a manual `boxa ssh add`.

10. **Multiselect assignment is persona-first.** The picker offers
    personas (never bare keys); picking one leads to a multi-select of
    projects. Confirming assigns that persona to every selected project
    — overwriting any previous assignment — and flips the gates, in one
    run. All pickers in the forge/ssh flows carry their question and
    context in the fzf `--header` (ADR 0006; fzf hides text printed
    before launch).

11. **Committer identity follows the persona.** The synthesized
    committer derives from the assigned persona's GitHub side when
    configured, otherwise its GitLab side — the ADR 0033 decision 8
    rule, re-keyed to personas.

## Considered options

- **Keep the per-forge identity entity, fix only presentation** — the
  first redesign pass tried exactly this ("storage rebuild: none") and
  the deeper grill broke it: per-forge assignment kept generating
  questions ("which forge?", mixed-owner warnings) about distinctions
  the user does not think in. Rejected.
- **Hybrid personas to recover the per-forge mix** — unrepresentable by
  design; mixing principals in one agent breaks the try-in-order
  correctness argument and the "who is the agent here?" answer.
  Forge-side membership removal covers the real need.
- **Keep the three-state gate, improve wording** — rejected: the mode
  duplicates information the catalog already holds (whose persona is
  assigned), and every divergence between the two needed warning text.
- **Per-client filtering on one shared agent** — impossible: the agent
  protocol offers all keys to every client; selectivity requires
  separate agents.
- **Generated ssh config with per-host key mapping** — rejected: made
  unnecessary by one-persona-per-project; would reintroduce a file to
  explain, sync, and debug.
- **OS keyring for passphrases** — rejected: lazy per-project prompts
  are acceptable; a keyring adds a platform-specific dependency and a
  place where secrets outlive intent.
- **Batch askpass (prompt once, feed every project agent in one run)** —
  rejected for now: boxa would transiently hold the passphrase,
  softening the "only ssh-add sees secrets" line; lazy re-add already
  reduces the cost to one prompt per actually-started project. Possible
  future opt-in if it ever hurts.

## Consequences

- Host restart stops being a silent SSH outage: registry re-add
  restores project agents without user action, at most one passphrase
  prompt per started project.
- The fleet gains one small ssh-agent process per enabled project;
  lifecycle (lazy spawn, resurrection) follows the existing `lib/ssh.sh`
  pattern from ADR 0032.
- The identity store and `forge.conf` grammar from the ADR 0033
  implementation batch are rebuilt (persona files, single `identity=`
  key) with an interactive merge migration; that batch's catalog
  mechanics (guarded remove, assignment-implies-gate-on, multi-machine
  key attachment, kind asked during migration) carry over re-keyed to
  personas.
- `ssh.conf` mode values `agent`/`user` become legacy input for
  migration to off/on + persona assignment; old parsers fail closed on
  new confs.
- The ADR 0032 posture checklists reduce to: one add-persona flow plus
  one kind label question.
- CONTEXT.md reworks **Forge identity** into the persona definition and
  gains **Key registry** and **Project agent**; **SSH gate** and
  **Identity kind** are reworded; the `agent`/`user` gate states leave
  the glossary.
