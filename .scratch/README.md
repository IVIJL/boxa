# Local work dashboard

Read this file at the start of every agent session. It is the live index for
local PRDs, issues and handoffs; GitHub Issues is not used for Boxa work.

## Dashboard

### Active

None.

### Planned

| Feature | Artifact | Next action | Last reviewed |
| ------- | -------- | ----------- | ------------- |
| Keep-awake during long-running agent work | `keep-awake-long-running-agent/issues/01-long-running-agent-awake-lease.md` | Diagnose the 2026-08-25 sleep incident, capture lease/reachability evidence, then freeze the fix or split follow-up implementation and live-verification slices. | 2026-08-28 |
| Forge access broker | `forge-access-broker/NOTES.md` | Grill the `glab`, `gh` and Git transport threat model, then decide whether to create a PRD. | 2026-08-28 |
| Memory-pressure livelock | `memory-pressure-livelock/PRD.md` | Grill the PRD and validate nested-cgroup feasibility before splitting it into issues. | 2026-08-28 |

### Waiting for human

None.

### Cancelled

| Feature | Record | Reason |
| ------- | ------ | ------ |
| Pre-sleep Container stop, including macOS | `cancelled/presleep-stop/CANCELLED.md` | The power-event approach was unreliable and the implementation was removed. |

### Archive

Completed feature bundles live under `archive/<YYYY-MM>/`. They are historical
evidence, not open work, and agents exclude them from issue discovery.

## Workflow

The main agent owns this dashboard and issue status even when a subagent does
the implementation.

1. New work gets a stable `.scratch/<feature-slug>/` directory and a dashboard
   row with one concrete next action.
2. Starting an issue means setting `Status: in-progress` and moving its feature
   row to **Active**.
3. Completion means finishing the workflow's proof and review, checking only
   acceptance criteria actually proven, setting `Status: done`, and updating
   this dashboard in the same turn.
4. When every issue is terminal and no follow-up remains, move the whole feature
   to `archive/<YYYY-MM>/` immediately and remove its active/planned row.
5. An explicitly abandoned feature moves to `cancelled/` with a short decision
   record. Cancelled work is preserved to prevent the same dead end from being
   rediscovered.
6. A transient handoff needed by another Boxa session goes in
   `.scratch/tmp/handoffs/`, which is visible through the shared Project mount.
   Promote future work into a versioned feature note, spec or PRD.

## Workflow integrations

- `afk-feature-workflow` keeps the feature Active, closes each verified issue
  in its slice commit, runs one final whole-feature review, then archives the
  feature in a final closeout commit. Explicit invocation authorizes those
  commits, never push.
- `ccode` uses the runtime's delegation backend (Claude → Codex MCP, Codex →
  native Codex subagent). Issue-backed work becomes `in-progress` and stays
  Active because `ccode` does not review or commit.
- `/cr` / `review-fix-commit` finishes issue-backed `ccode` work: after clean
  review and proof it updates the issue/dashboard, archives a completed feature,
  and includes that closeout in its authorized commit.

## Temporary workspace

`.scratch/tmp/` is the only ignored subtree. Put disposable logs, dumps,
generated datasets, screenshots, one-off scripts and transient handoffs there.
Store no secrets, even in ignored files. Everything outside `tmp/` is part of
the versioned local tracker; accepted architectural decisions still belong in
`docs/adr/`.
