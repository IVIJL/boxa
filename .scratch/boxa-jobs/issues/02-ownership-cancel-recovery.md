# 02 — Ownership, cancel, and recovery states

Status: ready-for-agent

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

- [ ] Test: child that `setsid`s an escapee → `cancel` kills both and reports them.
- [ ] Test: child runs `env -i sleep` → tracked while worker alive; after worker SIGKILL, `cancel` reports it as untrackable, does not claim success.
- [ ] Test: worker SIGKILL → state `orphaned`; `adopt` → command completes → `finished-unknown` (no exit code) with outputs intact.
- [ ] Test: main command exits while a background child lives → `exited-with-survivors`, `result` lists survivors, `cancel` finishes it.
- [ ] Test: foreign run id → `interrupted` on next call; `start` with the same key without `--fresh` returns the interrupted record, never a duplicate run.
- [ ] Test: simulated crash after reservation before spawn → key refuses retry until `cancel`.
- [ ] Entrypoint writes `/run/boxa/run-id`; shellcheck clean.

## Blocked by

- `01-job-core-start-wait-result.md`

## Comments
