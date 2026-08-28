# 08 — Documentation: docs/memory.md + README pointer

Status: done

## Parent

ADR 0020 (issue 07 of this feature).

## What to build

User-facing documentation for the whole memory-limit feature, as
`docs/memory.md` (matching the existing docs/ style), linked from the
README's docs list.

Must cover:

- **Semantics**: Memory limit vs Memory+swap limit, with the behavior
  table from the design session (swap off ← default / small swap
  allowance / unset = silent 2× / unlimited = the original incident).
  State plainly that `memory_swap` is a total, not an amount of swap.
- **Configuration**: `resources.conf` format, precedence chain, the
  derived 65 % default, one-shot `--memory` flag. Exact worked example:
  the `media` project pinned to 5 GiB with 1 GiB swap allowance
  (`memory = 5g`, `memory_swap = 6g` in the `[/abs/path/to/media]`
  section).
- **The warning that matters**: a limit above host/WSL RAM voids the
  protection entirely.
- **VM-level backstop**: per-project limits are caps, not reservations —
  N Projects can still jointly exhaust the VM (this is what the
  joint-exhaustion warning at startup means). Recommend a `.wslconfig`
  cap (`memory=`, `swap=`) as the last-resort complement on WSL2.
- **What happens at the limit**: the kernel picks a victim by its
  `oom_score` heuristic (observed: the largest process; PID 1 survival
  is likely, not guaranteed), the Project keeps running; where the story
  surfaces (`boxa ls` marker,
  `boxa mem`, desktop notification, agent hook message) and what
  `.State.OOMKilled` does and does not mean.
- **Troubleshooting**, one section each:
  - a single process with runaway RSS (the ugrep-style incident)
  - exhausted swap / sluggish VM
  - OOMKilled outer Container
  - nested DinD workload hitting the project limit (aggregate accounting,
    no per-container attribution)
  - how to tell disk I/O saturation from swap thrashing
- **Safe trial**: commands to try the feature harmlessly (tiny limit +
  controlled allocation, mirroring the integration test).

## Acceptance criteria

- [x] `docs/memory.md` exists, README links it
- [x] Semantics table present; the silent-2×-swap footgun called out
- [x] The media/5g worked example is copy-pasteable
- [x] "Limit above host RAM voids protection" warning present
- [x] `.wslconfig` VM-backstop section present, tied to the
      joint-exhaustion warning
- [x] All five troubleshooting sections written
- [x] Terminology matches CONTEXT.md; no invented synonyms

## Blocked by

- `01-memory-limit-at-creation.md` through `06-host-sweep-oom-archive.md`
  (documents their behavior; issue 07 in parallel is fine)

## Comments

- 2026-07-17: Done in commit 49aed5e (`docs: memory limits guide (#08)`).
  `docs/memory.md` written natively; every quoted CLI message/flag verified
  against docker-run.sh, lib/resources.sh, lib/oom-sweep.sh, lib/mem-report.sh,
  scripts/hooks/boxa-memory-context.sh. README docs list links it. Safe-trial
  section mirrors the issue-09 pattern (64m limit, bounded 2x allocation,
  boxa-prefixed name so the sweep archives it) without depending on the
  unmerged test code — the issue-09 branch has no test file yet.
