# AGENTS.md

Shared agent instructions for this repo, read by Claude Code (via the
`@AGENTS.md` import in `CLAUDE.md`) and by Codex. Project conventions and
domain glossary live in `CONTEXT.md`; design decisions in `docs/adr/`.

## Agent skills

### Issue tracker

Issues live as local markdown under `.scratch/<feature>/issues/` — **not**
GitHub Issues, despite the GitHub remote. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary; the triage state is the `Status:` line in each issue
file. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See
`docs/agents/domain.md`.
