# 03 — Concurrency ack

Status: done

## Parent

ADR 0037 § "Job key semantics" (concurrency is never silent); glossary "Concurrency ack".

## What to build

When `start` finds other non-finished Jobs in the Project (`reserved`, `running`, `exited-with-survivors`, `orphaned`, unclear), it refuses with a structured `needs-ack` listing them (jobId, key, start time, first line of the request). Repeating with `--ack-concurrent <id,id>` naming exactly those Jobs starts the new Job and stores the ack in its record; a Job that appeared in between makes the ack stale (`needs-ack` again with the new list). The check and the reservation happen under the Project `flock` from 01, so two simultaneous starts cannot both see an empty Project. With no other Jobs nothing is asked. Attaching to the same key does not need an ack.

## Acceptance criteria

- [x] Test: second `start` with another key → `needs-ack` with the first Job listed; with `--ack-concurrent <id>` it starts and the record holds the ack.
- [x] Test: stale ack (third Job appeared) → `needs-ack` listing both.
- [x] Test: two simultaneous starts in an empty Project → at most one starts without ack, the other gets `needs-ack`.
- [x] Test: `exited-with-survivors` and `orphaned` Jobs count as running for the ack.
- [x] `--help` and `--json` output document the flow for a skill author in ≤ 10 lines.

## Blocked by

- `01-job-core-start-wait-result.md`
- `02-ownership-cancel-recovery.md` (for the survivor/orphan states)

## Comments

2026-09-12 — implemented natively (Codex delegation unavailable for this
feature).

Built: `scripts/jobs/ack.py` — the whole ack decision in one reusable place
(`concurrent_jobs`, `gate`, `parse_ids`), so issue 04's `reply` gates through
the same function. `cmd_start` calls it INSIDE the existing Project `flock`,
after the key attach/conflict branch and after a second
`recovery.refresh_states` (acquiring the lock can take time, and an ack must
be judged against the Project as it is now). The ack is passed through the
spec, and the worker writes `ackConcurrent` into the record; `result --json`
and `start --json` expose it. Refusal: `result: needs-ack`, new exit code 11,
one line per concurrent Job (jobId, key, state, start time, first request
line truncated to 80 chars) plus a `hint` string in JSON that carries the
whole protocol. No reservation happens on a refusal (test asserts the key
stays free).

Documented choices (both in `--help`, the "concurrency ack" section, 10 lines):

- "Running" = `store.RUNNING_STATES` (`reserved`, `running`,
  `exited-with-survivors`, `orphaned`) plus any record that cannot be read
  back (reported as an `unclear` entry rather than silently skipped).
  `interrupted` does NOT count: it is terminal, nothing of it is alive, and it
  already refuses a retry under its own key — charging an ack for dead work
  after every Container restart would train callers to ack blindly. Tested
  both ways.
- `--ack-concurrent` with nothing running is refused (`reason:
  ack-not-needed`) rather than ignored: the caller's picture of the Project is
  out of date either way, and the message says to retry without the flag.
- Attach (same key + same fingerprint) and the finished-result return need no
  ack; `--fresh` is a new run and needs one.

Tests: `tests/test_jobs_ack.py`, 14 tests, `OK`. The simultaneous-start test
uses two real `python3 -m jobs.cli` processes rather than threads (the flock
is per-process, and two threads would also interleave the captured stdout):
exactly one starts, the other gets `needs-ack` listing it. Jobs modules
together (core + ownership + ack) 61 tests `OK`; whole suite
`python3 -m unittest discover -s tests` → 823 tests `OK` (809 before + 14).
`shellcheck scripts/job.sh` → clean.

One pre-existing test adjusted: `test_list_shows_the_projects_jobs` in
`tests/test_jobs_core.py` started a second key while the first Job was still
running, which now correctly needs an ack; it waits for the first Job to
finish instead.

In-Container proof via `scripts/job.sh` (real Project key): `start --key
ack-a -- sleep 120` → `20260912T090629-acr8ix` started; `start --key ack-b --
sleep 120` → `result: needs-ack (1 other job(s) running in this Project)`,
listing `20260912T090629-acr8ix key=ack-a running started=11:06:29 req: sleep
120` plus `repeat with: --ack-concurrent 20260912T090629-acr8ix`, exit 11;
repeated with that flag → started `20260912T090633-joskq6`, and `result
--json` on it shows `"ackConcurrent": ["20260912T090629-acr8ix"]`. Both Jobs
cancelled afterwards (`state: cancelled`, killed 89865 / 89918).

Scope kept to the slice: `reply` still refuses with exit 7 (issue 04 wires it
to `ack.gate`), no Codex thread lock, no state volume (06).
