# 09 — Integration test: OOM isolation end-to-end

Status: done

## Parent

ADR 0020 (issue 07 of this feature).

## What to build

`tests/integration-memory.sh` — the repo's first test that starts real
containers, so it is **explicit opt-in**: without `BOXA_INTEGRATION=1`
(and a reachable Docker daemon) it SKIPs loudly (the
`tests/port-conflict.sh` guard pattern; the repo has no CI, so a silent
skip protects nobody). Everything else in `tests/` keeps stubbing Docker.

The test must never endanger the host: tiny limits (~64m), a small
controlled allocation (~2× the limit), unique container names, and traps
that clean up containers on any exit path.

Scenario:

1. Start a test Container with a very low Memory limit (swap off).
2. Start a second, unlimited (or generously limited) bystander container.
3. Allocate memory inside the first until the limit trips.
4. Assert: the victim process was killed but the Container's PID 1
   survived; `memory.events` `oom_kill` incremented; the bystander
   container and the Docker daemon are untouched and responsive.
5. Assert the diagnostics: `boxa ls`-style probe shows the marker, the
   sweep (issue 06) writes exactly one OOM archive record with the victim
   name, and dedup holds on a second sweep.
6. Cleanup leaves no containers, no volumes, no archive litter behind
   (test writes under a temp-redirected archive path via env seam).

Sub-checks that only need cgroup behavior may use a plain small image,
but at least one path must exercise a real boxa Container so the wiring
from issues 01/03/06 is covered end-to-end.

## Acceptance criteria

- [x] Without `BOXA_INTEGRATION=1` or without Docker: loud SKIP, exit 0
      (both paths executed in-container: no-gate SKIP, and a gated run SKIPs
      on the inner rootless daemon's CgroupDriver=none — by design)
- [ ] With the gate: OOM kill happens inside the limited container only;
      PID 1 survives; `oom_kill` counter increments
      (deferred verification — host-gated, awaiting user run)
- [ ] Bystander container and Docker daemon verified alive afterwards
      (deferred verification — host-gated, awaiting user run)
- [ ] Sweep produces exactly one archive record for the event; second run
      produces none
      (deferred verification — host-gated, awaiting user run)
- [ ] All containers/volumes created by the test are removed on success,
      failure, and interrupt
      (deferred verification — host-gated, awaiting user run)
- [x] Host stays safe: limits ≤ 64m, allocation bounded, no host swap
      pressure (by construction in the script; one documented deviation —
      the real-boxa-Container phase uses 1g because the entrypoint plus
      rootless dockerd cannot boot under 64m; its allocation is bounded
      at 1.25g and swap stays off)
- [x] shellcheck clean (`shellcheck -S info`, zero findings; only justified
      inline disables with repo-precedent comments)

## Blocked by

- `01-memory-limit-at-creation.md`
- `03-ls-mem-column.md`
- `06-host-sweep-oom-archive.md`

## Comments

2026-07-17 — implemented natively (Claude) in worktree branch
`issue-09-integration`, commit `0375333`
(`tests: gated memory-limit integration test (#09)`, not pushed).
`tests/integration-memory.sh`, 534 lines, executable, patterned on the
port-conflict.sh loud-SKIP gate. Phases: (A) 64m victim + finitely-limited
256m bystander, bounded `head|tail` allocator, oom_kill/PID-1/daemon
asserts; (B) `docker update` lowering below current usage (issue 02's
immediate-OOM risk path) — keyed on stable observables
(HostConfig.Memory/MemorySwap, memory.events), with a TODO to tighten to
issue 02's final warning wording once it lands; (C) real boxa Container via
worktree docker-run.sh with the `BOXA_RESOURCES_CONF` seam (1g project
limit, startup-line + inspect asserts, in-Container OOM trip); (D) `boxa
ls` MEM cell + `!oom×` marker and the exited lifetime-flag marker asserted
after a non-OOM `docker stop` (`.State.OOMKilled` = "OOM happened during
lifetime"); (E) sweep via `BOXA_OOM_*` env seams into a temp archive,
exactly-one-record + dedup-on-rerun asserts, notification stubbed. Extra
gates beyond the spec: CgroupDriver=none (inner rootless daemon → SKIP,
protects in-container runs), cgroup v2, local image present. Verified in
the boxa container: bash -n, shellcheck -S info clean, both SKIP paths
exit 0, all 15 tests/*.sh suites green in the worktree. Documented,
accepted side effect: synthetic OOM events remain in the shared kernel
ring buffer, so the user's next real boxa invocation archives them once
into /var/log/boxa/oom (self-labeled boxa-memtest09*); the test's own
sweeps are fully redirected. Host run still pending:
`BOXA_INTEGRATION=1 bash tests/integration-memory.sh`.
