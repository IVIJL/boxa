# AGENTS.md

Shared agent instructions for this repo, read by Claude Code (via the
`@AGENTS.md` import in `CLAUDE.md`) and by Codex. Project conventions and
domain glossary live in `CONTEXT.md`; design decisions in `docs/adr/`.

## Agent skills

### Issue tracker

Issues live as local markdown under `.scratch/<feature>/issues/` — **not**
GitHub Issues, despite the GitHub remote. See `docs/agents/issue-tracker.md`.
At the start of every session, read `.scratch/README.md`; the main agent owns
its live issue lifecycle, including work completed by subagents.
Work sourced from a local issue is incomplete until the main agent updates its
status and dashboard/archive state after the required proof and review.

### AFK batches

Explicitly invoking `afk-feature-workflow` authorizes its per-issue commits;
it never authorizes push. The workflow must close out every completed issue and
archive the feature only after its final whole-feature review is clean.

### Triage labels

Default vocabulary; the triage state is the `Status:` line in each issue
file. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See
`docs/agents/domain.md`.
