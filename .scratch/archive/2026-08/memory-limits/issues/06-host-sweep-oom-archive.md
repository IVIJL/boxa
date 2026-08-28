# 06 — Host sweep: OOM archive + desktop notification

Status: done

## Parent

None — decisions are recorded in CONTEXT.md (`### Memory`, **OOM
archive**) and will be captured in ADR 0020 (issue 07 of this feature).

## What to build

The host-side reader of the same kernel truth: a sweep, piggybacked on
`boxa` invocations exactly like the existing allow-for notification sweep
(fire-and-forget `detach_bg`, single-digit ms when idle, no daemon), that
scans the kernel log for memcg OOM kills belonging to boxa Containers and
turns them into a durable **OOM archive** record plus a desktop
notification.

Verified foundations: the WSL2 kernel ring buffer is shared — host
`dmesg` (no sudo) sees OOM events from containers running in the
`docker-desktop` distro, with `oom_memcg=/docker/<id>` and
`task=<name> ... anon-rss:<kB>` for correlation and forensics.

- Correlate `oom_memcg` container IDs to `boxa-*` containers; ignore
  non-boxa kills.
- **dmesg is the source, the archive is the record**: the ring buffer is
  memory-only and a VM restart wipes it (this is exactly what happened to
  the original incident's evidence), so copy each event out at first
  sighting to `/var/log/boxa/oom/<container>-<timestamp>.log` containing:
  project name, event time, the limit in force, victim process + RSS, and
  the recommended diagnostic command (`boxa mem <project>`).
- Dedup via a state file remembering the last-seen kernel timestamp;
  handle the timestamp going backwards (VM restarted → ring buffer reset).
- Deliver a desktop notification through the existing
  deliver-allow-for-notification backends (WSL2 toast with click-to-open
  pointing at the archive record, notify-send on Linux, macOS best
  effort). Example wording: "Project media hit its 5 GiB memory limit.
  Killed by the kernel: ugrep, 3.8 GiB RSS. The project keeps running."
  (dmesg names the actual victim — never phrase it as "largest process";
  victim selection is a kernel heuristic, see issue 07.)
- Known, accepted gap (document, don't hide): if the VM dies before any
  boxa invocation sweeps, the event is lost.

## Acceptance criteria

- [x] Any `boxa` invocation after an OOM kill in a boxa Container writes
      exactly one archive record and raises exactly one notification for
      it; repeated invocations do not re-notify
- [x] Archive record contains project, time, limit, victim + RSS, and a
      next-step command
- [x] OOM kills from non-boxa containers or host processes are ignored
- [x] VM-restart timestamp reset does not produce duplicate or missed
      notifications for new events
- [x] Idle cost is one detached fork + a cheap scan; no persistent
      process
- [x] Sweep logic covered by unit tests with canned dmesg fixtures;
      shellcheck clean

## Blocked by

- `01-memory-limit-at-creation.md` (memcg OOM only happens once limits
  exist; archive records the limit in force)

## Comments

2026-07-17 (agent, worktree agent-abcdf4bd8bae6af32, commit 2266daa):
Implemented via Codex delegation. `lib/oom-sweep.sh` (parsing, correlation,
dedup, archive formatting) + `scripts/sweep-oom-events.sh` (detached worker)
+ thin `detach_bg` trigger in docker-run.sh next to the allow-for sweep;
notification reuses deliver-allow-for-notification.sh backends; provisioning
of writable /var/log/boxa/oom added to ensure-allow-for-host-state.sh.
26 unit tests on canned dmesg fixtures pass; shellcheck -S info clean on all
touched files. Criteria verified by unit tests with seams only — no live
host OOM exercised (runtime-blocked by issue 01; limit read via `docker
inspect` at event time, "unknown" if container gone). Accepted gap per spec:
VM death before any sweep loses the event.
