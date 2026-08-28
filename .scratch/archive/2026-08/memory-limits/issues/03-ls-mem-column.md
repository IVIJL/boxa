# 03 — MEM column in `boxa ls`

Status: done

## Parent

None — decisions are recorded in CONTEXT.md (`### Memory`) and will be
captured in ADR 0020 (issue 07 of this feature).

## What to build

`boxa ls` gains a MEM column so the user sees memory posture at a glance,
with zero standing overhead (cost is paid only when `ls` runs).

For each **running** Container: current usage / limit and percentage
(e.g. `2.3g/6.5g 35%`), read in one `docker exec` per container
(`memory.current`, `memory.max`, `memory.events` are readable inside —
verified; the container sees its own cgroup as root due to the private
cgroup namespace). If the cgroup `oom_kill` counter is non-zero, append a
marker (e.g. `!oom×3`). A Container without a limit (pre-feature) shows
`no limit`.

For each **exited** Container in the existing "Exited" section: when
`docker inspect .State.OOMKilled` is true, mark it. Semantics caution
(verified on the target host): the flag means "at least one OOM kill
happened during the container's lifetime", **not** "the container died of
OOM" — it reads true even after a clean exit. Word the marker accordingly
(e.g. `oom seen`), and point to `boxa mem` for the story.

Follow the existing table style (manual fixed-width `printf`, no color
helpers exist in the codebase — inline escapes are the precedent).

## Acceptance criteria

- [x] Running Containers show `usage/limit percent`; limitless ones show
      `no limit`
- [x] `oom_kill > 0` on a running Container is visibly marked with the
      count (`!oom×N`)
- [x] Exited Containers with `.State.OOMKilled=true` are marked with
      wording that does not claim the exit was OOM-caused
      (`oom seen during run — see 'boxa mem <project>'`)
- [x] One `docker exec` per running container, none per exited; no
      background process, no polling (exited flags come from ONE batched
      `docker inspect` for the whole section)
- [x] A Container that cannot be probed (race: died mid-ls) degrades to a
      `-` cell, never breaks the table
- [x] Unit tests for the formatting/percentage helper; shellcheck clean
      (clean under `shellcheck -x -S info`; without `-x` docker-run.sh has
      pre-existing SC1091 "not following" infos — unchanged baseline)

## Blocked by

- `01-memory-limit-at-creation.md`

## Comments

2026-07-17 — implemented natively on branch `issue-03-ls-mem`, commit
`6636c4d` (worktree, not pushed). Helpers `_boxa::mem_cell` and
`_boxa::exited_oom_marker` live in `lib/resources.sh` (reuse
`_boxa::format_size`); `list_running_containers()` in docker-run.sh does the
one exec per running container and the batched inspect for exited. MEM is the
LAST table column because the `×` marker is multibyte and would skew printf's
byte-counted padding of later columns. 13 new assertions in
`tests/resources.sh`; all 14 `tests/*.sh` suites pass. Exception note: agent
runs inside the boxa container, so the docker exec/inspect paths were not run
against real Docker — proven via the pure-helper seams per repo pattern
(spec's stated proof standard). The `boxa mem` pointer references issue 04's
command, which lands later in this batch.
