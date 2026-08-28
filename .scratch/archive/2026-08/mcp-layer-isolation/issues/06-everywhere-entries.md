# 06 — Everywhere entries

Status: done

## Parent

ADR 0029 — Everywhere entries, pending activation, and remote catalog entries.

## What to build

`boxa mcp activate <entry> --everywhere` marks a catalog entry to activate in
every present and future Project; `--no-everywhere` clears the mark (existing
per-Project activations survive as plain ones). End to end:

- marking activates the entry in all currently known Projects: immediately
  where readiness passes or the entry is remote, as pending activation
  (issue 05) where the Boxa is stopped,
- a Project first seen after the mark gains the activation automatically at
  its Container start, through the same pending/readiness path,
- an explicit per-Project deactivation is sticky: it wins over the mark and
  survives re-marking; re-activating that Project is an explicit activate,
- marking an agent-trusted entry warns loudly that agent-identity trust now
  extends to every future Project, and requires the same explicit
  acknowledgement style used for agent-trusted activation today,
- `boxa mcp status` shows the everywhere mark on the entry and the sticky
  opt-outs per Project.

## Acceptance criteria

- [x] Mark propagates to all known Projects (mixed running/stopped) with
      per-Project outcome reported
- [x] A newly created Project's first Container start picks the entry up with
      no per-Project command
- [x] Deactivate in one Project sticks; the mark does not re-add it there
- [x] Agent-trusted everywhere requires explicit acknowledgement and status
      says the trust scope
- [x] `--no-everywhere` stops future propagation without touching existing
      activations

All five covered by unit tests (tests/test_mcp_activation.py,
tests/test_mcp_cli_render_status.py). Live host verification (real multi-Boxa
propagation, real first Container start on a brand-new Project) not done —
deferred to the user per KICKOFF.md.

## Blocked by

05-pending-activation.md.

## Comments

Implemented via Codex (thread 01a02308-55f5-7a60-8345-57a99775a79b), commit
40cb8f5. Design: everywhere mark stored as top-level `activations.json`
`"everywhere"` section (catalog-entry-scoped, versioned/validated like the
rest of the store); sticky opt-out stored as a tombstone record
(`{"catalogId": ..., "optedOut": true}`) in the existing per-Project map so it
survives having no activation record, filtered out of the runtime snapshot;
propagation reuses `enumerate_project_targets()` (the same Project enumerator
`boxa mcp add`/import use) and the existing activate/pending/remote paths, so
remote entries land immediately and readiness-bound entries land pending per
issue 05; `reevaluate_pending()` now also seeds everywhere-marked entries a
Project has no record for yet, which is what makes a brand-new Project's
first Container start (docker-run.sh's existing `reevaluate_pending_mcp`
call) pick the mark up with no per-Project command; agent-trusted
`--everywhere` mirrors the existing mode-apply preview+`--yes`
acknowledgement pattern with a loud "every future Project" warning;
`boxa mcp status` extends the existing effective-list output with the
everywhere mark, per-Project sticky opt-outs, and the agent-trust scope
string.
