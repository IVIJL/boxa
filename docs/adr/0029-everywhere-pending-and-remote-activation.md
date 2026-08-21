# ADR 0029 — Everywhere entries, pending activation, and remote catalog entries

- **Status:** accepted
- **Date:** 2026-08-20
- **Revises:** the activation invariants of ADR 0021 ("activation requires a
  running Boxa"; "never carries over to another Project")

## Context

With sessions reading only the MCP profile (ADR 0028), two real usages need
first-class answers: hosted HTTP connectors (a colleague's Dozzle server was
`excluded` by import and only worked via `claude mcp add -s user`, a scope the
strict wrapper no longer reads) and "I want this server in every project"
(the same `-s user` expectation). Activation also used to require the target
Boxa to be running, which makes any multi-project operation useless when most
boxes are stopped.

## Decision

Three additions to the catalog/activation model:

- **Remote MCP catalog entries** (`http`) carry a URL instead of a command.
  Nothing runs in the Container, so they have no execution mode and no runtime
  readiness; the Allowlist is their gate. Import stops excluding `type=http`
  candidates.
- **Everywhere entries**: `boxa mcp activate <entry> --everywhere` marks the
  entry to activate in all present and future Projects; a per-Project
  deactivation is sticky and wins. We rejected the one-shot `--all-projects`
  loop: a durable, inspectable mark beats a moment-in-time sweep nobody can
  reconstruct later.
- **Pending activation**: activating against a stopped Boxa records the
  activation; readiness re-evaluates at the next Container start and either
  makes it effective or reports why not. Sessions never see a pending
  activation, so the "only verified servers reach a session" invariant moves
  in time but does not weaken. Remote entries skip pending entirely.

## Consequences

- An everywhere-marked agent-trusted entry extends the agent-identity trust to
  every future Project automatically; activation and status must say so
  loudly.
- New Projects gain servers without a per-Project command for the first time;
  this is confined to entries the user explicitly marked.
