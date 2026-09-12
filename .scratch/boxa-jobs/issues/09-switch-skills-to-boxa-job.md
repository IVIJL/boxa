# 09 — Switch `/cr`, `/ccode`, `afk-feature-workflow` to `boxa-job`

Status: ready-for-human

## Parent

ADR 0037 § "Consequences"; memory `codex-mcp-priority-over-companion` (to be superseded). The skills live in the user's `~/.claude` tree (mounted into Containers), not in this repo; the user owns model choices.

## What to build

Rewrite the three skills so a subagent runs `boxa-job start --codex --key <feature>/<issue>/<step> --model gpt-5.6-sol --effort <as today>`, then loops `boxa-job wait` (default timeout) until a finished state, then `boxa-job result`, evaluates, and returns the main agent only a summary plus `git diff --stat` and the evidence it needs. The user may override the model in the request ("do it with astra") and the subagent passes it through and states it. `/cr` review threads use `reply` on the same thread. Frugal waiting rules from ADR 0037 are written into the skills verbatim: no commentary between waits, no re-analysis, logs only on demand, no early return. Concurrency ack is passed only when the main agent explicitly asked for parallel work. Memory notes `codex-mcp-priority-over-companion` and `mcp-delegation-via-mcp-tool-works` are updated to the new mechanism.

## Acceptance criteria

- [ ] All three skills reference `boxa-job` and no longer reference `mcp__boxa-codex-delegate__*`.
- [ ] One real `/cr` run and one `/ccode` run on a small change complete through the new path with the main agent receiving only summary + diff stat.
- [ ] Model override by request works and is echoed in the summary.
- [ ] Memory updated.

## Blocked by

- `08-release-gate-two-hour-acceptance.md`

## Comments
