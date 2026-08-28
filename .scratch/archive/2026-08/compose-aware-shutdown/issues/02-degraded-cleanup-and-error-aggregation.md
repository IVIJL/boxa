# 02 — Degraded cleanup and fleet-wide error aggregation

Status: done

## Parent

ADR 0035 — Compose-aware inner shutdown.

## What to build

Extend explicit Project shutdown through its degraded paths without letting one
broken inner daemon strand the rest of a stop batch. When Compose metadata is
inconsistent, a referenced working directory or config file is unusable, or
Compose down fails, Boxa identifies the affected Compose project, warns clearly,
and falls back to graceful container stop followed by removal. Dependency order
is explicitly not promised in this degraded path.

After all shutdown jobs finish, Boxa sweeps leftovers and verifies the inner
container list. An unreachable inner Docker daemon or a non-empty final list is
a cleanup failure. Named stop, explicit stop-all, and interactive stop-all still
finish stopping and removing every requested outer Container, then return a
non-zero result after the batch if any inner cleanup could not be completed or
verified. Successful fallback cleanup may return success but must retain its
visible degradation warning.

## Acceptance criteria

- [ ] Missing, unreadable, or inconsistent Compose identity inputs and failed
      Compose teardown produce a project-specific warning and graceful
      stop-plus-removal fallback.
- [ ] A fallback that removes every Inner container succeeds with a warning;
      dependency-aware ordering is not claimed for that project.
- [ ] An unreachable inner daemon, failed removal, or non-empty final container
      list is recorded as an inner cleanup failure.
- [ ] Every requested outer Container is still stopped and removed even when
      one or more inner cleanups fail.
- [ ] Named stop, explicit stop-all, and interactive stop-all return non-zero
      after completing their work when any requested Project has an unresolved
      inner cleanup failure.
- [ ] Multiple outer Containers continue preparing and stopping concurrently;
      failure status is aggregated only after all jobs have been waited for.
- [ ] Completion messages and notifications do not falsely describe a failed
      cleanup batch as fully successful.
- [ ] Fast shell tests cover each degraded trigger, successful fallback,
      unresolved leftovers, daemon outage, multi-Container partial failure, and
      consistent exit behavior across every explicit stop entry point.
- [ ] Every changed shell script passes `shellcheck` including informational
      findings, apart from documented false positives.

## Blocked by

- `01-compose-aware-explicit-shutdown.md`

## Comments
