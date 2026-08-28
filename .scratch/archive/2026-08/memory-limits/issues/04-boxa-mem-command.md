# 04 — `boxa mem` deep-dive command

Status: done

## Parent

None — decisions are recorded in CONTEXT.md (`### Memory`) and will be
captured in ADR 0020 (issue 07 of this feature).

## What to build

New subcommand `boxa mem [project|path]` — the per-project memory
autopsy. With no argument it resolves the Project from the current
directory, mirroring the path-based convention of bare `boxa [path]`.
(`mem`, not `status` — the completions file documents that a top-level
`status` deliberately does not exist, and not `top` — no live refresh.)

For a running Container it shows:

- usage / limit / percentage, swap usage (`memory.swap.current`), and
  the **Memory+swap limit**
- the full `memory.events` (low, high, max, oom, oom_kill)
- top processes by RSS (one `ps` inside the outer PID namespace — it sees
  nested DinD processes too; verified). Label the listing explicitly as
  a **project aggregate**: nested containers cannot be attributed
  individually because the inner rootless dockerd runs without cgroups
  (`CgroupDriver=none`). Never pretend per-nested-container numbers.
- recent entries from the **OOM archive** (`/var/log/boxa/oom/`, written
  by issue 06) — this part must also work for an exited/removed Container
- recommended next commands: one-shot raise (`boxa --memory ...`),
  durable setting (`resources.conf` section), and the docs page

For an exited Container: limits from `docker inspect`, `.State.OOMKilled`
with the honest wording from issue 03, and the OOM archive entries.

Register the subcommand in the dispatcher and in both completion files
(`completions/boxa.bash`, `completions/_boxa`).

## Acceptance criteria

- [x] `boxa mem` inside a project directory resolves that Project;
      explicit name/path arguments work like other boxa commands
      (`_boxa::mem_resolve_target` reuses `boxa::names_from_path`/
      `boxa::names_from_token`)
- [x] Running Container: usage, swap usage, both limits, percentage and
      full `memory.events` are shown (cgroup v2 reads via `docker exec`;
      `max` rendered as unlimited)
- [x] Top-RSS listing is present and labeled as a project aggregate with
      the nested-DinD attribution caveat (one `ps -eo ... --sort=-rss`,
      top 10 rows)
- [x] OOM archive entries appear when present, including for a Container
      that no longer exists (newest-first by kernel timestamp, strict
      filename grammar avoids `api` vs `api-worker` prefix collisions)
- [x] Output ends with concrete raise/diagnose commands (temporary
      `boxa --memory`, durable `resources.conf` section, docs URL)
- [x] Both completion files know the new subcommand (`boxa.bash`
      top_commands + project-name completion; `_boxa` description +
      `_boxa_containers`)
- [x] Unit tests for the pure formatting/resolution helpers; shellcheck
      clean (`tests/mem-report.sh`, 10 cases, no real docker;
      `shellcheck -S info -x` clean on all touched bash files)

## Blocked by

- `01-memory-limit-at-creation.md`

## Comments

2026-07-17 — Implemented by Codex (gpt-5.6) under AFK batch, verified and
committed by Claude wrapper. Commit `be828c2` on branch `issue-04-boxa-mem`
(worktree). Files: new `lib/mem-report.sh` (all logic, `_boxa::mem_*`
helpers with docker-cmd/archive-dir/cwd seams) + `tests/mem-report.sh`;
thin wiring in `docker-run.sh` (dispatcher `mem)` entry, `MODE=mem`
handler calling `_boxa::mem_report`, help line); `completions/boxa.bash`
+ `completions/_boxa`. Exited-Container path uses the ADR 0020 lifetime
wording for `.State.OOMKilled`; removed Containers fall back to
inspect-unavailable notice + OOM archive + a concrete 12g suggestion.
Proof: all 15 `tests/*.sh` suites pass on host env (Codex's sandbox showed
the 4 known WSLg failures + a sandbox-only port-conflict socket denial);
`shellcheck -S info -x` clean; `zsh -n completions/_boxa` clean. No
`boxa status`, no `ls` MEM column (issue 03), no scope extension.
