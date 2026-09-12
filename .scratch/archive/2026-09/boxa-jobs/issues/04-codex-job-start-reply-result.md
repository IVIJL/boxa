# 04 — Codex job: `start --codex`, `reply`, result extraction

Status: done

## Parent

ADR 0037 § "Codex job contract"; glossary "Codex job". Measured `codex exec --json` facts (memory `codex-job-manager-measurements`): `thread.started{thread_id}` → `item.*` → terminal `turn.completed{usage}`; `-o FILE` holds the final message; stdin must be `/dev/null`; SIGTERM kills the tree, exits 0, writes no terminal event; `codex exec resume <thread_id> --json PROMPT` continues a thread and rejects `-s`/`-C` (sandbox via `-c sandbox_mode=...`, irrelevant once bypassed).

## What to build

- `start --key K --codex --model M --effort E [--cwd DIR] "prompt"`: model and effort are required (no default from `~/.codex/config.toml`); the Job runs `codex exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -m M -c model_reasoning_effort=E -C <cwd> -o <job>/last.md "<prompt>" </dev/null`, unconditionally bypassing Codex's sandbox and approvals (ADR: the Container is the boundary). The Codex binary is the Container's interactive one for now (runtime snapshot lands in 05).
- The worker tails the event stream: records `thread_id` as soon as `thread.started` appears, and on exit derives the Codex outcome: `turn.completed` present + exit 0 → `done`; exit 0 without terminal event, or `turn.failed`/`error` → `failed` with reason; worker-lost cases keep 02's semantics (terminal event is evidence, not proof → `finished-unknown`).
- `result` for a Codex job adds: thread_id, final message (from `-o`), usage, requested and actually used model/effort (from events where available), Codex version (`codex --version`), and the per-item command list count. Never the full event log.
- `reply <jobId|threadId> --key K --model M --effort E "prompt"`: new Job on the same thread via `codex exec resume`; refused (structured `thread-busy`) while any Job of that thread is non-finished. Thread lock is taken under the Project `flock`.
- Skill-facing contract: one subagent = one thread = one Job at a time; steering means `cancel` then `reply`.

## Acceptance criteria

- [x] Unit tests with recorded event streams (from the measurement runs) cover done / failed-without-terminal / turn.failed / thread id capture.
- [x] Live proof in Container (model `gpt-5.6-luna`, effort low, kept short): start writes a file and returns `done` with the final message; `reply` on the thread recalls the file content; `cancel` mid-run → `cancelled`, no `done`, no survivors.
- [x] Missing `--model` or `--effort` → usage error, nothing started.
- [x] `reply` while the thread's Job runs → `thread-busy`.
- [x] `result` output for a Codex job is one compact JSON object; `log --tail` shows raw events on demand only.

## Blocked by

- `01-job-core-start-wait-result.md`
- `02-ownership-cancel-recovery.md`

## Comments

### 2026-09-12 — implemented natively (Claude), commit `jobs: codex job start/reply …`

**Code.** New `scripts/jobs/codex.py` owns the whole Codex-specific part: the
two argv builders, the event-stream reducer, the outcome rule and the result
extract. `resolve_binary()` is the single binary-resolution seam issue 05
replaces (PATH today, `BOXA_JOB_CODEX_BIN` as the test override). `store.py`
gained `events_path()`/`last_message_path()`; the worker writes a Codex job's
stdout to `events.jsonl`, publishes `threadId` on the record from its
heartbeat tick (≤2 s after `thread.started`), and derives the terminal state
from the stream. `cli.py`'s key lifecycle was factored into one
`_register_job(JobRequest)` so `reply` inherits attach/conflict/`--fresh`/ack
semantics unchanged; the Codex thread lock runs as a `preflight` under the
Project flock, *before* the ack gate and *after* the key check (so a repeated
identical `reply` still attaches, while a genuinely new one is refused).
`recovery.py` re-derives a Codex job's state through the stream too, so a
killed `codex exec` that exited 0 can never be resurrected as `done`.

**Verified codex flag sets (issue 05 needs these).** `codex exec` accepts
`--json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check
-m M -c model_reasoning_effort=E -C DIR -o FILE PROMPT`. `codex exec resume
<thread> …` accepts the same MINUS `-C`/`--cd` and `-s` (`codex exec resume
--help`, codex-cli 0.149.1) — the resume turn therefore gets its cwd from the
worker's child cwd, which is the parent Job's cwd. Event shapes confirmed:
`{"type":"thread.started","thread_id":…}`, `{"type":"turn.completed","usage":{…}}`,
`{"type":"turn.failed","error":{"message":…}}`, `{"type":"error","message":…}`,
and an `item.completed` may carry an `error` ITEM that is only a warning.

**Tests.** `tests/test_jobs_codex.py`, 40 tests, all green; whole suite
`python3 -m unittest discover -s tests` = 863 tests OK; `shellcheck
scripts/job.sh` clean. Fixtures under `tests/fixtures/jobs/` are raw captures
of real runs: `codex-done.jsonl` + `codex-resume-done.jsonl` are one matched
live thread, `codex-killed-no-terminal.jsonl` is the actual stream of the
cancelled proof run, `codex-turn-failed.jsonl`/`codex-error-event.jsonl` come
from a real 400 on a bogus model. CLI-level tests use a fake `codex` shell
script (cat a fixture / sleep), so no test spends money.

**Live proof** (in-Container, `gpt-5.6-luna`, effort low, via `./scripts/job.sh`):

1. `start --key proof04-write --codex … "Create the file /tmp/boxa-jobs-proof04.txt
   containing the word PROOF04 and reply done"` → `done`, exit 0, 8.9 s,
   thread `01a094e8-21fc-7641-beef-44dadd0b0235`, `final: done`,
   `items: agent_message=2 file_change=1`, `usage: in=33767 out=96`; the file
   really contains `PROOF04`.
2. `reply 01a094e8-21fc-… --key proof04-recall … "What word did you write to
   that file? Answer with the word only"` → `done`, 4.2 s, same thread id,
   `final: PROOF04` — thread continuity proven across two Jobs.
3. `start --key proof04-cancel … 'Run the shell command `sleep 200` then reply
   done'`: mid-run `result` already showed
   `thread=01a094e8-6fc8-77c3-bcd0-433d469d6850` and
   `items: agent_message=1 command_execution=1` (mid-run thread capture);
   `cancel` killed pids 93661 93668 93885 93898 → state `cancelled`
   (NOT `done`, although `codex exec` exited 0 with no terminal event), and
   `pgrep -f 'sleep 200'` showed no survivors.
4. `reply` on that thread while its Job ran → `result: thread-busy`, exit 12,
   listing the running jobId; after the `cancel` a `reply` on the same thread
   is accepted again (covered by a test with the fake binary).

**Deviations / notes.**
- `usedModel`/`usedEffort` are `null`: codex-cli 0.149.1 never reports them in
  the stream, and inventing an echo of the request would be a lie. A generic
  probe is in place for the version that does start reporting them.
- `reply` also takes `--env`, `--ack-concurrent`, `--fresh` and
  `--prompt-file`; the ack gate applies to it, so it needs them.
- Item counts are per item *type* and counted by item id, so an item that
  appears as both `item.started` and `item.completed` counts once.
- New exit code 12 = `thread-busy`.

