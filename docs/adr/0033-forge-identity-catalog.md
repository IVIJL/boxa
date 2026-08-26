# ADR 0033 — Forge identity catalog with per-project assignment

- **Status:** accepted (decisions 1–3 — per-forge identity entity,
  per-forge assignment and defaults — and the per-forge identity file
  naming of decision 4 superseded by ADR 0034 personas; the catalog
  mechanics stand)
- **Date:** 2026-08-25
- **Extends:** ADR 0032 (per-installation agent identity), ADR 0026 (SSH
  gate); pattern borrowed from the MCP catalog/activation split
  (ADR 0013 lineage)

## Context

ADR 0032 shipped one global credential per forge plus a per-project
on/off gate. Real use immediately wants more: one project running
entirely under the user's own logins while another runs under the
machine user; a work GitLab under a service account next to a personal
GitHub under a machine user; and multiple computers sharing one GitHub
machine user because the ToS allow exactly one free machine account per
person — so the "new machine, new machine account" assumption of a
per-installation identity does not survive contact with GitHub.

The MCP subsystem already solved the same shape: a user-wide catalog of
definitions, explicit per-project activation, and an interactive
multi-project picker. Forge access gets the same split, without copying
the MCP file formats — forge already owns a store and a per-project
conf.

## Decision

1. **Forge identity is the catalog entity.** One identity = one account
   on one forge, binding BOTH sides of authentication: which SSH key
   signs and whose token (plus committer identity) enters the box.
   Half-identities (push as the machine user, comment as the human) are
   unrepresentable by design. Identity ID is derived, not chosen:
   `github:<username>` / `gitlab:<host>:<username>`.

2. **Three identity kinds.** `mine` (the user's own account: SSH side is
   the user-agent forwarding of ADR 0026 `user` mode; token is a PAT on
   the user's account or an ADR 0031 consented import), `agent` (machine
   user / service account whose SSH key is the Agent key), `other`
   (additional accounts, e.g. corporate — mechanically like `agent`).
   The ADR 0032 three-posture checklists become the registration flows
   for these kinds.

3. **Assignment is per project per forge.** A project picks at most one
   identity per forge (GitHub → agent, GitLab → mine is a supported
   combination), with a user-selectable **global default identity per
   forge** as fallback and an explicit per-project `none` override.
   Assigning writes through to the single SSH gate from all SSH-capable
   identities resolved for that project: any `agent`/`other` identity
   selects `agent`, and `user` is selected only when all are `mine`.
   Token-only identities do not participate. A mixed result warns which
   forge loses SSH authentication; `boxa ssh` remains a manual override
   and status warns when the two diverge. The Key-picker
   consent flow of `user` mode is untouched. Assignment also turns the
   project's forge gate `on` (assignment is intent); `forge off` stays
   as a kill switch that does not delete assignments.

4. **Storage extends the existing forge store — no new JSON aparatus.**
   Identities live as one file each under
   `~/.config/boxa/forge/identities/<id>` (0600, same `key=value`
   format as today's credentials plus `kind=` and `auth=ssh|token`).
   Assignments and defaults
   live in `forge.conf`: per-project sections gain `github = <id>` /
   `gitlab = <id>` (or `none`), the global scope gains the default-
   identity keys, `forge = on|off` keeps its meaning. The strict parser
   grows these keys; a conf written by this version is invalid to older
   boxa versions (their parser fails closed to gate off), which is the
   accepted one-way upgrade.

5. **Command surface.** `boxa forge add` (register an identity — runs
   the kind checklist), `list`, `use [<id>]` (assignment; with no args:
   identity picker + MCP-style multi-project picker, current project as
   default), `default <id>`, `remove <id>`, and `status` (also as an
   alias of the bare `forge`). `remove` refuses while the identity is
   assigned anywhere or is a default, listing the users; `--force`
   removes and cleans assignments. `forge setup` stays as the onboarding
   wrapper (add → offer default → offer use for the current project) and
   remains what doctor invokes.

6. **Migration is eager and asks once.** On the first forge command, the
   pre-catalog credential files `~/.config/boxa/forge/github|gitlab`
   convert to identities and become the global defaults. `kind` is not
   derivable from stored data, so migration asks one interactive
   question per credential (machine user vs. own account) — kind drives
   the SSH write-through, so a silent wrong guess is expensive.

7. **Multi-machine: attach keys, never sync them.** Private keys never
   leave their machine. Each installation keeps its own Agent key and
   attaches it to the SAME machine user (forge accounts accept many SSH
   keys); each machine mints its own PAT under that account, revocable
   per machine. The catalog is not synchronized — an identity record is
   name + host, no secret, so a new machine simply registers it again;
   the `add` checklist offers "attach this machine's key to an existing
   machine user" alongside "create one". Users and companies remain free
   to create additional accounts; one shared machine account is just the
   floor that works on GitHub Free.

8. **Committer identity follows the assignment.** The synthesized
   committer (`<user>@users.noreply.github.com` / `<user>@<gitlab
   host>`) is now derived per project from the assigned identity. A
   project with identities for both forges takes the synthesized committer
   identity deterministically from GitHub; a GitLab-only project uses its
   GitLab identity. A per-identity `email=` override is a non-goal until
   someone needs it.

## Considered options

- **Second catalog in JSON à la MCP (`forge-catalog.json` +
  `forge-activations.json`)** — rejected: duplicates infrastructure the
  forge store and forge.conf already provide; MCP contributes the
  pattern and the picker UX, not the file format.
- **User-chosen identity names** — rejected: `<forge>:<username>` is
  collision-free and needs no rename story; kind is shown as a label.
- **SSH gate left independent of assignment** — rejected: it recreates
  the exact failure the identity binds against (agent token with the
  user's key, or vice versa). Write-through with a visible manual
  override keeps both safety and escape hatch.
- **Catalog sync across machines** — rejected: the only shareable part
  carries no secret and re-registration is a two-minute checklist;
  syncing would add a transport and a trust question for near-zero win.
- **Silent `kind` guess during migration** — rejected: one lifetime
  prompt beats a wrong SSH mode written to every project.
- **`activate`/`deactivate` verb naming (MCP parity)** — rejected:
  assignment is exclusive (one identity per forge per project), not a
  set; `use` reads correctly.

## Consequences

- "Project A fully mine, project B fully agent" becomes a first-class,
  two-command setup, and the answer to "who is the agent here?" is per
  project, not global.
- forge.conf becomes the single per-project source for gate + identity;
  the parser change makes new confs fail closed on old versions.
- `forge status` grows per-project assignment output on top of the
  SSH/token authenticates-as lines.
- The ADR 0032 global-credential flow survives only as the migration
  input; its checklists live on as the `add` registration flows.
- New glossary terms (Forge identity, Identity kind, Identity
  assignment, Default identity) enter CONTEXT.md with the
  implementation batch.
