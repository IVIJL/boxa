# 03 — Concurrency ack

Status: ready-for-agent

## Parent

ADR 0037 § "Job key semantics" (concurrency is never silent); glossary "Concurrency ack".

## What to build

When `start` finds other non-finished Jobs in the Project (`reserved`, `running`, `exited-with-survivors`, `orphaned`, unclear), it refuses with a structured `needs-ack` listing them (jobId, key, start time, first line of the request). Repeating with `--ack-concurrent <id,id>` naming exactly those Jobs starts the new Job and stores the ack in its record; a Job that appeared in between makes the ack stale (`needs-ack` again with the new list). The check and the reservation happen under the Project `flock` from 01, so two simultaneous starts cannot both see an empty Project. With no other Jobs nothing is asked. Attaching to the same key does not need an ack.

## Acceptance criteria

- [ ] Test: second `start` with another key → `needs-ack` with the first Job listed; with `--ack-concurrent <id>` it starts and the record holds the ack.
- [ ] Test: stale ack (third Job appeared) → `needs-ack` listing both.
- [ ] Test: two simultaneous starts in an empty Project → at most one starts without ack, the other gets `needs-ack`.
- [ ] Test: `exited-with-survivors` and `orphaned` Jobs count as running for the ack.
- [ ] `--help` and `--json` output document the flow for a skill author in ≤ 10 lines.

## Blocked by

- `01-job-core-start-wait-result.md`
- `02-ownership-cancel-recovery.md` (for the survivor/orphan states)

## Comments
