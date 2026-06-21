# Issue tracker: Local Markdown

Issues and PRDs for this repo live as **markdown files under `.scratch/`**.

> ⚠️ This repo has a GitHub remote (`github.com/IVIJL/boxa`), but issues
> are **NOT** tracked on GitHub Issues. Never run `gh issue create` / `gh
> issue list` for project work. Commit messages that cite "issue 15", "issue
> 21", etc. refer to the local files below, not GitHub issue numbers.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The PRD (if any) is `.scratch/<feature-slug>/PRD.md`
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
- Triage state is the `Status:` line near the top (see `triage-labels.md`
  for the role strings)
- Comments and conversation history append at the bottom under `## Comments`

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/issues/` (creating the
directory if needed), numbered after the existing issues in that feature.
If the right feature directory is ambiguous, ask the user.

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path
or the `<feature>/<NN>` reference directly.
