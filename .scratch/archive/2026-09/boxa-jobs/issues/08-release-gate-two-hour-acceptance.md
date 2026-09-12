# 08 — Release gate: two-hour acceptance run and baseline measurements

Status: done

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

- [x] Script exists, documented, runs the short scenarios (3–6) in under 15 minutes.
- [x] Two-hour run (1–2) completed once on the user's machine with the results file committed; no second Job started by any wait expiry or reconnect.
- [x] Every scenario's observed state matches the ADR's state table; deviations are recorded as issues, not hidden.
- [x] Baseline numbers (wait calls, output volume, tokens/cost split) recorded.

## Blocked by

- `03-concurrency-ack.md`
- `05-codex-runtime-snapshot.md`
- `06-state-volume-restart-retention.md`
- `07-retire-codex-delegate-seed-docs.md`

## Comments

### 2026-09-12 — done on the host (Prompt B session)

**Script:** `tests/jobs_gate.py` (`short`, `long start|attach|report`),
documented in `docs/jobs.md` § "Release gate". Runs inside the Container
against the real `boxa-job`; results in `GATE-2026-09-12.md` in this
directory (short section = the final script version, wall clock 91 s;
17 PASS). Reviewed through the new `/cr` path (three Codex rounds, all
findings fixed, see issue 09).

**Short scenarios (3–6), all PASS:** worker crash → `orphaned` → `adopt` →
`finished-unknown` with the command's output kept; cancel kills a `setsid`
escapee and an `env -i` child under a live worker; an `env -i` child of a
crashed worker and an inner Docker container are the two stated limits and
the CLI states them in its cancel output (the container survived the cancel,
as documented); Codex update between two jobs (old job finished on
`0.154.0/`, new one on `0.154.1/`, both probed and verified) and an `npm`
update concurrent with the copy (`0.154.2` discarded with the warning
"source changed during the copy", `0.154.1` stayed in use, no `.snapshot-*`
leak); non-zero exit → `failed` 3; 30 MB stdout → `done`, `log --tail` fine;
cancel mid-run → `cancelled`; duplicate start → `attached`, same id; same key
other request → `conflict` 6. Scenario 5 (restart → `interrupted`) is the
host proof in issue 06, not drivable from inside.

**Two-hour run (1–2), 5 PASS:** Job `20260912T180012-oed9g6`, gpt-5.6-luna
low, `sleep 7200 && sha256sum <1 MiB fixture>` inside Codex; `done`, exit 0,
`turn.completed`, 120.3 min, digest correct, exactly one Job under the key.
Waiting subagent 1 made 3 `wait` calls (1637 s, 288 B, 21 101 tokens) and
ended on purpose; subagent 2 reconnected with `long attach` (`attached`, same
jobId) and made 11 calls (5517 s, 4 249 B incl. the 3 269 B final result,
25 463 tokens). 14 waits in total, 1 268 B of running-status output; no
expiry or reconnect started a second Job. Codex side: 740 722 input tokens
(679 168 cached), 2 528 output. Beside it, `/ccode`, `/cr` (3 Jobs) and three
short gate runs ran with `--ack-concurrent` without disturbing it.

**Observed deviations / notes (recorded, none hidden):**
- The runtime refresh runs before the concurrency check, so a start that
  is then refused `needs-ack` has already copied and probed a new version;
  the acked retry takes the fast path (`runtimeProbed: false`). One probe per
  version either way, but a refused start pays it, and each probe fires the
  user's Codex Stop-hook notification twice (exec + resume).
- A live cancel records the signal exit (`exitCode: -15`) with state
  `cancelled`; docs only promise "never `failed`". Consistent, just noting.
- Codex's native handling of a 2 h foreground command cost ~740k input
  tokens (92 % cached) on luna: it keeps polling its own command. ADR 0037
  says routing long commands through `boxa-job` from inside Codex is added
  only if the gate fails; it passed, so this stays a measured baseline for
  that later decision.
- The full unittest run (953 tests) still shows the pre-existing
  `test_ssh_gate_pty…retries_whole_bundle` failure under load; it passes
  alone (handoff note stands).
