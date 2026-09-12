# 02 — Ownership, cancel, and recovery states

Status: done

## Parent

ADR 0037 §§ "Ownership by subreaper and marker" and "States and honesty". Measured: `kill -pgid` misses a `setsid` escapee; `BOXA_JOB_ID` + `/proc/*/environ` scan finds all descendants even after the worker dies; PID 1 reaps orphans; cgroups read-only.

## What to build

- The worker tracks its process tree: as subreaper, every descendant reparents to it; the worker walks `/proc` parent links to know the tree, which catches children that called `setsid` or cleared their environment. The marker scan is the fallback once the worker is gone.
- `done` now means: main command exited under a live worker *and* no tracked descendant alive. Otherwise `exited-with-survivors`: exit code recorded, not finished, never garbage-collected, counts as running for the concurrency ack (03), moves to terminal only via `cancel` or survivors ending.
- `cancel <jobId>` terminates what Boxa can see (tree if worker alive, marker matches otherwise) with TERM then KILL, verifies by identity (pid + start time), and reports what it killed and what it could not track. Explicit stated limits: processes that cleared the marker after the worker died; anything started through the rootless Docker daemon.
- `orphaned` (worker dead, command alive) detected on any CLI call by worker identity check; `adopt <jobId>` attaches a new worker that only watches the surviving tree and the output files; after it ends, state is `finished-unknown` unless the exit code is known (Codex terminal event in 04 is evidence, not proof).
- Container run id: the entrypoint writes a nonce to `/run/boxa/run-id`; every record stores it. On any CLI call, non-terminal records with a foreign run id become `interrupted`; no auto-resume. Unclear records (unreadable, unknown run id, dead worker without exit) refuse a retry under their key until `cancel` or `adopt`.
- A crash between reservation and spawn leaves a `reserved` record with a dead worker → treated as unclear, not silently retried.

## Acceptance criteria

- [x] Test: child that `setsid`s an escapee → `cancel` kills both and reports them.
- [x] Test: child runs `env -i sleep` → tracked while worker alive; after worker SIGKILL, `cancel` reports it as untrackable, does not claim success.
- [x] Test: worker SIGKILL → state `orphaned`; `adopt` → command completes → `finished-unknown` (no exit code) with outputs intact.
- [x] Test: main command exits while a background child lives → `exited-with-survivors`, `result` lists survivors, `cancel` finishes it.
- [x] Test: foreign run id → `interrupted` on next call; `start` with the same key without `--fresh` returns the interrupted record, never a duplicate run.
- [x] Test: simulated crash after reservation before spawn → key refuses retry until `cancel`.
- [x] Entrypoint writes `/run/boxa/run-id`; shellcheck clean.

## Blocked by

- `01-job-core-start-wait-result.md`

## Comments

2026-09-12 — implemented natively (Codex delegation unavailable for this
feature).

Built: `scripts/jobs/procs.py` (process identity = pid + start time, `/proc`
parent-link tree walk, `BOXA_JOB_ID` marker scan, TERM→KILL with identity
verification both ways, zombies explicitly not survivors) and
`scripts/jobs/recovery.py` (evidence-labelled live set, the lazy
`refresh_states` sweep, `cancel_job`). The worker now waits for the whole tree
(`exited-with-survivors`), keeps a `tree` snapshot on the record, reaps
reparented descendants in the wait thread only, and has a `--watch` adopt mode.
`scripts/boxa-entrypoint.sh` writes the run-id nonce to `/run/boxa/run-id` in
the root phase (0644, before the node drop).

**Cancel mechanism (one, documented):** `cancel` writes the cancel REQUEST
file `<jobdir>/cancel` *first*, then kills what Boxa can see itself. A live
worker notices the file (heartbeat tick), kills its tracked tree as the
subreaper and finalizes the record to `cancelled`; when no worker is left — or
it does not finalize within 10 s — the CLI finalizes the record in its place.
So a killed command is never recorded as `failed`.

Tests: `tests/test_jobs_ownership.py`, 17 tests, `OK` (real processes, not
stubs; 3 consecutive runs of both jobs modules green). Whole Python suite
`python3 -m unittest discover -s tests` → 809 tests `OK` (792 before + 17).
`shellcheck scripts/boxa-entrypoint.sh scripts/job.sh` → clean (no
pre-existing findings either).

In-Container proofs via `scripts/job.sh` (real Project key):

- escapee cancel: `20260912T085544-tb30d4` (`setsid sleep 400 & sleep 400`) →
  tracked pids `61632 sh`, `61633 sleep` (own session/pgid `61633` ≠ command
  pgid `61630`, i.e. a `kill -pgid` miss), `61634 sleep`; `cancel` → `killed:
  61632 61633 61634` + both limit lines, `state: cancelled`, `exit: -15`, `ps`
  shows none of them left.
- orphan/adopt: `20260912T085554-yp7ypz` (`sleep 25; echo
  ORPHAN_ADOPT_PROOF_DONE`) → `kill -9` the worker → `result: orphaned` with
  `survivors: 61705 61706`; `wait` returned `orphaned` immediately (exit 4,
  "adopt or cancel" — it does not sit on an orphan); `adopt` → `running`
  (watch only) → `wait` → `finished-unknown`, `exit: None`, duration 28.4 s,
  `log` → `ORPHAN_ADOPT_PROOF_DONE` (outputs intact).
- survivors: `20260912T085629-bn6wv5` (`sleep 400 & echo hi`) →
  `exited-with-survivors`, `exit: 0`, `survivors: 61792`; a second `start`
  under the same key → `result: unclear` exit 4 (no duplicate run);
  `cancel` → `killed: 61792`, `cancelled`.

Deviation from the acceptance wording: the `env -i` test runs
`sh -c 'env -i sleep 300 & exit 0'`, i.e. the marked shell **exits** before
the worker is killed. With the shell still alive the wiped child is reachable
by walking down from the marker match, so it would be perfectly trackable —
the honest "untrackable" case is exactly the one where no marker and no live
ancestor is left. The test asserts the child is tracked while the worker lives
(`exited-with-survivors`, `result` lists it), then after the worker SIGKILL
that `cancel` reports it under `untrackable`, does NOT list it in `killed`,
leaves it alive, and prints both stated limits; the test kills it by pid in
teardown.

Also proven in passing: issue 01's leftover cross-subagent proof job
`20260912T083811-iausd6` is `done`, exit 0, stdout `SUBAGENT_PROOF_2_DONE`
(criterion (b) of issue 01).

Scope kept to the slice: no concurrency `needs-ack` (03), no state volume
(06), no Codex job. `reply`, `gc`, `runtime` still refuse with exit 7.
