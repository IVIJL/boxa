# 09 — Switch `/cr`, `/ccode`, `afk-feature-workflow` to `boxa-job`

Status: done

## Parent

ADR 0037 § "Consequences"; memory `codex-mcp-priority-over-companion` (to be superseded). The skills live in the user's `~/.claude` tree (mounted into Containers), not in this repo; the user owns model choices.

## What to build

Rewrite the three skills so a subagent runs `boxa-job start --codex --key <feature>/<issue>/<step> --model gpt-5.6-sol --effort <as today>`, then loops `boxa-job wait` (default timeout) until a finished state, then `boxa-job result`, evaluates, and returns the main agent only a summary plus `git diff --stat` and the evidence it needs. The user may override the model in the request ("do it with astra") and the subagent passes it through and states it. `/cr` review threads use `reply` on the same thread. Frugal waiting rules from ADR 0037 are written into the skills verbatim: no commentary between waits, no re-analysis, logs only on demand, no early return. Concurrency ack is passed only when the main agent explicitly asked for parallel work. Memory notes `codex-mcp-priority-over-companion` and `mcp-delegation-via-mcp-tool-works` are updated to the new mechanism.

## Acceptance criteria

- [x] All three skills reference `boxa-job` and no longer reference `mcp__boxa-codex-delegate__*`.
- [x] One real `/cr` run and one `/ccode` run on a small change complete through the new path with the main agent receiving only summary + diff stat.
- [x] Model override by request works and is echoed in the summary.
- [x] Memory updated.

## Blocked by

- `08-release-gate-two-hour-acceptance.md`

## Comments

### 2026-09-12 — done on the host (Prompt B session)

**Skills rewritten** in `~/.claude`: `commands/cr.md`, `skills/ccode/SKILL.md`,
`skills/afk-feature-workflow/SKILL.md` (backend + final-review sections; the
rest of the AFK skill untouched). All three now describe `boxa-job start
--codex --key <feature>/<issue>/<step> --model gpt-5.6-sol --effort medium
--cwd … --prompt-file … --json`, the `wait` loop (exit 10 = call again, Bash
timeout 600000), `result`, `reply` on the same thread for re-review, the host
variant (`docker exec -u node -w <repo> boxa-<project>` prefix), and the ADR
0037 frugal-waiting rules verbatim. Effort `medium` = what
`~/.codex/config.toml` gave the MCP path before. `grep mcp__boxa-codex-delegate`
over the three files: 0 hits. Concurrency ack only on explicit orchestrator
request (written into each skill).

**Real runs through the new path** (host session, Container `boxa-boxa`, a
two-hour gate Job running beside them, ack explicitly authorized):

- `/ccode` on a small change (the "Release gate" section of `docs/jobs.md`),
  with the user-style override `--model gpt-5.6-luna --effort low`: Job
  `20260912T180720-za1ur1`, thread `01a096cd-6fdf-72e2-98bb-b46fecbd581b`,
  1 wait call, `done`; the main agent received only the summary (jobId,
  threadId, model `gpt-5.6-luna` echoed, changed file + one sentence, proof
  pass, no deviations) and read `git diff --stat` itself.
- `/cr` on the working tree (store.py fix, gate script, docs): review Job
  `20260912T180916-7k36l2` on thread `01a096cf-32c0-7bf2-85e9-d4d5b8322a8a`
  (gpt-5.6-sol, 1 wait), two `reply` re-review Jobs (`…-aegnct`, `…-5ncjbl`)
  on the same thread. Each shell returned only verdict + findings + ids.
  Findings fixed by the main session; commit left to the user.

**Memory updated:** `codex-mcp-priority-over-companion` and
`mcp-delegation-via-mcp-tool-works` rewritten to the Job mechanism (index
lines in `MEMORY.md` too).

Left for the user: `boxa mcp remove codex-delegate` (after this closeout; the
doctor/status notice keeps pointing at it until then).
