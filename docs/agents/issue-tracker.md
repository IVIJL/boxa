# Issue tracker: Local Markdown

Issues, specs, PRDs and decision records for this repo are **versioned markdown
files under `.scratch/`**. Only `.scratch/tmp/` is ignored and disposable.
Read `.scratch/README.md` at the start of every agent session. It is the live
dashboard and the source of truth for lifecycle operations.

> ⚠️ This repo has a GitHub remote (`github.com/IVIJL/boxa`), but issues
> are **NOT** tracked on GitHub Issues. Never run `gh issue create` / `gh
> issue list` for project work. Commit messages that cite "issue 15", "issue
> 21", etc. refer to the local files below, not GitHub issue numbers.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- A `/to-spec` artifact is `.scratch/<feature-slug>/spec.md`; a `/to-prd`
  artifact is `.scratch/<feature-slug>/PRD.md`. Preserve the producer's name
  and normally keep only one planning source per feature.
- Implementation issues are `.scratch/<feature-slug>/issues/<NN>-<slug>.md`,
  numbered from `01`
- Each issue file follows this shape:
  ```markdown
  # NN — Title

  Status: ready-for-agent

  ## Parent

  ADR reference, or "None — …" when the area is not covered by an ADR.

  ## What to build

  End-to-end behaviour of this vertical slice (no stale file paths).

  ## Acceptance criteria

  - [ ] …

  ## Blocked by

  Reference to the blocking issue file, or "None — can start immediately."

  ## Comments
  ```
- Triage state is the `Status:` or `**Status:**` field near the top (see
  `triage-labels.md` for the role strings). Preserve the file's existing form
  when updating it.
- Comments and conversation history append at the bottom under `## Comments`
- `.scratch/archive/` contains versioned completed features and is excluded
  from open-issue discovery.
- `.scratch/cancelled/` preserves versioned rejected or retired work and its
  reason; it is excluded from open-issue discovery.
- `.scratch/tmp/` contains ignored logs, dumps, generated data, one-off scripts
  and transient handoffs. Promote useful conclusions into a versioned feature
  artifact before deleting the temporary source.

## Live lifecycle

The **main agent** owns these transitions, including when a subagent performs
the implementation:

1. Before implementation, set the selected issue to `in-progress` and update
   its feature row in `.scratch/README.md`.
2. After implementation plus the workflow's required proof and review are
   complete, check only acceptance criteria actually proven, set the issue to
   `done`, and update the dashboard in the same turn.
3. When every issue in a feature is terminal and no follow-up remains, move the
   complete feature directory to `.scratch/archive/<YYYY-MM>/` and update the
   dashboard. The move is part of completion, not later housekeeping.
4. When work is abandoned by an explicit decision, record the reason and move
   it to `.scratch/cancelled/`.

Do not infer completion from a commit alone. Verify the issue's acceptance
criteria or an explicit superseding decision before applying a terminal state.

For an explicit AFK batch, keep the feature **Active** throughout the batch.
Each verified slice becomes `done`, but archive the feature only after the one
final whole-feature review is clean and any in-scope review follow-ups are done.

## When a skill says "publish to the issue tracker"

Route the artifact by type, creating the feature directory when needed:

- `/to-spec` → `.scratch/<feature-slug>/spec.md`
- `/to-prd` → `.scratch/<feature-slug>/PRD.md`
- implementation ticket →
  `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered after existing
  tickets
- research/decision evidence → a clearly named markdown file within the
  feature directory

Add or update the feature row in `.scratch/README.md`. If the right feature
directory is ambiguous, ask the user.

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path
or the `<feature>/<NN>` reference directly.

## Wayfinding operations

Used by `/wayfinder`. A map has one child file per decision ticket.

- **Map:** `.scratch/<effort>/map.md`.
- **Child ticket:** `.scratch/<effort>/issues/<NN>-<slug>.md`, numbered from
  `01`, with a `Type:` field (`research`, `prototype`, `grilling` or `task`)
  and a `Status:` field (`claimed` or `resolved`).
- **Blocking:** a `Blocked by: NN, NN` field. A ticket is unblocked when every
  listed ticket is `resolved`.
- **Frontier:** open, unblocked and unclaimed children; lowest number wins.
- **Claim:** set `Status: claimed` before starting work.
- **Resolve:** append the answer under `## Answer`, set `Status: resolved`, and
  add a gist plus link to the map's Decisions-so-far section.
