# 09 — Warm hook: documentation

Status: done

## Parent

None — closing slice of the warm-hook design (issues 07/08).

## What to build

- `docs/keep-awake.md`: rewrite the pre-shutdown stop section to describe
  the warm hook — why direct `wsl.exe` spawning cannot work during a
  Windows shutdown (`0xC0000142`, no new processes in an ending session),
  the pre-spawned child + stdin trigger, the lifecycle rule (armed while
  boxa containers run: `boxa up` arms, last `boxa stop` disarms,
  `no-boxes` self-exit guards stale spawns so the WSL VM is never pinned
  idle), and the unchanged 45 s budget. Document the fallback + its
  limits, and that deployment happens via `boxa update` → automatic
  `keep-awake refresh`.
- `keep-awake/README.md`: short warm-hook paragraph in the component
  overview.
- `CONTEXT.md`: add "warm hook" to the glossary; adjust any wording that
  still implies the shutdown stop spawns `wsl.exe` on demand.

## Acceptance criteria

- [x] Docs match the implemented behaviour of issues 07/08 (verify against
      the merged code, not this issue's wording, before writing).
- [x] No stale references to spawning the stop command directly at
      shutdown remain in docs.

## Blocked by

`.scratch/presleep-stop/issues/08-warm-hook-arm-wiring.md`.

## Comments
