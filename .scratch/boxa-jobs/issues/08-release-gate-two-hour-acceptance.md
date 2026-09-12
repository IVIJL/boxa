# 08 — Release gate: two-hour acceptance run and baseline measurements

Status: ready-for-human

## Parent

ADR 0037 § "Consequences" (release gate and baseline measurements).

## What to build

A repeatable acceptance script (under the repo's test tooling, runnable inside a Container by the user) plus a recorded results file in this feature directory. Scenarios, each with its expected state:

1. Codex job whose prompt runs a ~2 h shell command (`sleep` + hash file), model `gpt-5.6-luna`, effort low; during it: `wait` expiry, the waiting subagent ends, a new subagent reconnects by key without a second Job; the result is taken over and the workflow continues. Records the number of `wait` calls, their output volume, and the waiting subagent's tokens/cost separately from Codex's usage where the client exposes them.
2. Duplicate start (same key) during 1 → attach, no second run.
3. Worker crash mid-run → `orphaned` → `adopt` → outcome; cancel with a `setsid` escapee; `env -i` child; inner Docker container started by a Job (limit documented, not claimed).
4. Codex update between two jobs (old keeps running on its copy, new is probed); `npm` update concurrent with the copy → discarded.
5. Container restart mid-run → `interrupted`, no false running/done.
6. Non-zero exit, large stdout (tens of MB), cancel mid-run.

Results are written to `.scratch/boxa-jobs/GATE-<date>.md` and become the baseline the MCP-adapter question is later judged against.

## Acceptance criteria

- [ ] Script exists, documented, runs the short scenarios (3–6) in under 15 minutes.
- [ ] Two-hour run (1–2) completed once on the user's machine with the results file committed; no second Job started by any wait expiry or reconnect.
- [ ] Every scenario's observed state matches the ADR's state table; deviations are recorded as issues, not hidden.
- [ ] Baseline numbers (wait calls, output volume, tokens/cost split) recorded.

## Blocked by

- `03-concurrency-ack.md`
- `05-codex-runtime-snapshot.md`
- `06-state-volume-restart-retention.md`
- `07-retire-codex-delegate-seed-docs.md`

## Comments
