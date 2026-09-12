# 04 — Codex job: `start --codex`, `reply`, result extraction

Status: ready-for-agent

## Parent

ADR 0037 § "Codex job contract"; glossary "Codex job". Measured `codex exec --json` facts (memory `codex-job-manager-measurements`): `thread.started{thread_id}` → `item.*` → terminal `turn.completed{usage}`; `-o FILE` holds the final message; stdin must be `/dev/null`; SIGTERM kills the tree, exits 0, writes no terminal event; `codex exec resume <thread_id> --json PROMPT` continues a thread and rejects `-s`/`-C` (sandbox via `-c sandbox_mode=...`, irrelevant once bypassed).

## What to build

- `start --key K --codex --model M --effort E [--cwd DIR] "prompt"`: model and effort are required (no default from `~/.codex/config.toml`); the Job runs `codex exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -m M -c model_reasoning_effort=E -C <cwd> -o <job>/last.md "<prompt>" </dev/null`, unconditionally bypassing Codex's sandbox and approvals (ADR: the Container is the boundary). The Codex binary is the Container's interactive one for now (runtime snapshot lands in 05).
- The worker tails the event stream: records `thread_id` as soon as `thread.started` appears, and on exit derives the Codex outcome: `turn.completed` present + exit 0 → `done`; exit 0 without terminal event, or `turn.failed`/`error` → `failed` with reason; worker-lost cases keep 02's semantics (terminal event is evidence, not proof → `finished-unknown`).
- `result` for a Codex job adds: thread_id, final message (from `-o`), usage, requested and actually used model/effort (from events where available), Codex version (`codex --version`), and the per-item command list count. Never the full event log.
- `reply <jobId|threadId> --key K --model M --effort E "prompt"`: new Job on the same thread via `codex exec resume`; refused (structured `thread-busy`) while any Job of that thread is non-finished. Thread lock is taken under the Project `flock`.
- Skill-facing contract: one subagent = one thread = one Job at a time; steering means `cancel` then `reply`.

## Acceptance criteria

- [ ] Unit tests with recorded event streams (from the measurement runs) cover done / failed-without-terminal / turn.failed / thread id capture.
- [ ] Live proof in Container (model `gpt-5.6-luna`, effort low, kept short): start writes a file and returns `done` with the final message; `reply` on the thread recalls the file content; `cancel` mid-run → `cancelled`, no `done`, no survivors.
- [ ] Missing `--model` or `--effort` → usage error, nothing started.
- [ ] `reply` while the thread's Job runs → `thread-busy`.
- [ ] `result` output for a Codex job is one compact JSON object; `log --tail` shows raw events on demand only.

## Blocked by

- `01-job-core-start-wait-result.md`
- `02-ownership-cancel-recovery.md`

## Comments
