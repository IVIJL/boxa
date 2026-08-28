# PRD — Memory-pressure livelock: bounded inner dockerd, df removal, containment strategy

Status: needs-triage (draft — to be grilled in a follow-up session before
splitting into issues)

## Problem Statement

When an agent inside a boxa Container violates the no-build rule and runs a
Docker build (or any operation that makes the inner rootless dockerd walk its
large store), the Container enters a memory livelock instead of a clean OOM
kill: memory fills to the cgroup ceiling, the kernel reclaims page cache,
memory fills again, in a loop that never triggers the OOM killer. The
Container becomes unresponsive (docker exec times out over vsock, `boxa stop`
blocks), drags the WSL2 VM down with it, and eventually dies entirely. The
user's `boxa mem set` limit does not protect against this, contradicting the
promise of ADR 0020.

Measured reproduction (Codex diagnosis session, 2026-08-27, real
`boxa-boxa` box):

- Outer cgroup `memory.max` 8153067520 (~7.59 GiB), `memory.swap.max` 0.
- Inner rootless dockerd RSS grew ~1.1 GiB → 6.68 GiB with **0 running
  containers and 6 images**; growth was almost entirely private anonymous
  memory (Go heap).
- `memory.events.local`: `max=785939`, `oom=0`, `oom_kill=0` — the kernel
  hit the ceiling ~786k times and reclaimed successfully every time, so the
  OOM killer never fired. This is the livelock mechanism.
- The trigger was reproduced with an unbounded `docker system df` against
  the persistent inner store: 8.5 GiB fuse-overlayfs, ~214k files, ~23.5k
  directories. The build path invokes exactly this (`build.sh` runs
  `timeout 5 docker system df` for cache reporting), and a client-side
  `timeout 5` does **not** cancel the daemon-side scan.

## Solution

Three-layer response, ordered by cost and certainty, with an explicit
decision gate between layers:

1. **Kill the measured trigger (cheap, certain).** Bound the inner dockerd's
   Go heap with a derived `GOMEMLIMIT`, and remove the unbounded
   `docker system df` call from the build path. Verified by A/B measurement
   against the reproduction before anything else is built.
2. **Contain the hog, save the session (medium, preferred containment).**
   Place the inner dockerd (and therefore all builds and inner workloads it
   spawns) in a nested cgroup with its own `memory.max` well below the outer
   ceiling. When a build blows up, the kernel OOM-kills inside that scope —
   dockerd or the build process dies, the agent session survives. Because
   dockerd's growth is anonymous memory and swap is 0, reclaim inside the
   nested scope runs out of reclaimable pages quickly, so the nested OOM
   actually fires (unlike the outer cgroup, where the huge file-scan page
   cache kept reclaim "succeeding").
3. **Bounded-time last resort (expensive, only if 1+2 prove insufficient).**
   An external watchdog (`boxa-memory-guard`) outside the Project cgroup
   that detects sustained thrash (high `memory.current/max` ratio + rapidly
   rising `memory.events.local:max` + PSI `full`) and stops the offending
   outer Container within bounded time, persisting a diagnostic snapshot
   first. This does not save the box — it converts "an hour of WSL-wide
   thrash, then death with no evidence" into "clean stop in bounded time
   with evidence".

Why this order: layer 1 removes the only *measured* trigger and is
verifiable in a day. Layer 2 changes the failure mode from "box dies" to
"build dies" — strictly better UX for rule-violating agents, and no standing
process. Layer 3 conflicts with an explicit ADR 0020 rejection (option 2,
"user-space watcher daemon: race-prone, adds a standing process boxa
deliberately has none of") and must supersede that reasoning if built, so it
is gated on evidence that layers 1+2 leave a real residual failure class.

Independent of the layers, ADR 0020 gets a correction: `memory.max` is a
final ceiling enforced by reclaim, not a guarantee of a prompt kill; when
direct reclaim keeps making progress (cache-heavy workloads) the cgroup
livelocks at the ceiling instead of OOM-killing.

## User Stories

1. As a boxa user, I want a runaway inner-Docker operation to be killed by
   the kernel inside its own bounds, so that my agent session and terminal
   survive the incident.
2. As a boxa user, I want `boxa mem set` limits to produce a prompt, local
   kill instead of a VM-wide thrash, so that the limit actually protects the
   rest of my machine.
3. As a boxa user, I want the inner dockerd's memory to stay bounded during
   store-walking operations (df, image inspection, builds), so that a big
   persistent store cannot balloon the daemon to the box ceiling.
4. As a boxa user, I want the build path to stop invoking unbounded
   daemon-side store scans, so that cache reporting can never wedge the box.
5. As a boxa user, I want `boxa stop` to keep working while a box is under
   memory pressure, so that I can recover without Docker Desktop surgery.
6. As a boxa user, I want the WSL2 VM and the Docker control plane to remain
   responsive while one box misbehaves, so that other Projects keep working.
7. As an agent inside a box, I want a rule-violating build to fail fast with
   a clear daemon-side error, so that I can report the violation instead of
   silently killing the session I run in.
8. As a boxa user, I want the effective dockerd memory bound logged at
   daemon startup, so that I can verify what limit a box is running with.
9. As a boxa user, I want to override the derived dockerd memory bound per
   box when a legitimate heavy workload needs it, so that the safety default
   does not block real work.
10. As a boxa user, I want a diagnostic record to survive a memory incident
    (which cgroup, dockerd RSS, memory.events, PSI), so that the evidence no
    longer vanishes with the VM restart — the original ADR 0020 complaint.
11. As a boxa user, I want incidents killed by the nested dockerd limit to
    be distinguishable from kernel OOM kills of the whole box, so that
    diagnosis starts from the right failure class.
12. As a boxa user, I want persistent volumes (inner Docker store included)
    to survive any emergency kill, so that recovery is a restart, not a
    rebuild.
13. As a boxa user, I want normal workloads (compose up/down, test runs,
    legitimate inner containers) to run without false kills under the new
    bounds, so that the fix does not trade a livelock for flaky sessions.
14. As a maintainer, I want an isolated, opt-in reproduction harness for the
    livelock (never against a real Project volume), so that the fix and any
    future regression can be verified deterministically.
15. As a maintainer, I want ADR 0020 amended with the measured
    reclaim-livelock semantics, so that future memory work starts from
    correct kernel behavior assumptions.
16. As a boxa user, I want the emergency watchdog (if layer 3 is built) to
    stop a thrashing box within a bounded time even when docker exec into it
    no longer responds, so that the failure never again requires killing the
    whole WSL VM.
17. As a maintainer, I want the watchdog (if built) to run with its own
    small hard memory limit, no swap and no network, so that the safety net
    cannot itself become a resource or security liability.

## Implementation Decisions

- **Layer 1a — GOMEMLIMIT on inner dockerd.** The rootless dockerd startup
  script derives `GOMEMLIMIT` from the outer cgroup's `memory.max` at
  daemon start: default ~35% of the ceiling, clamped to [1 GiB, 2 GiB]
  (a 4 GiB box lands around 1.5 GiB). `BOXA_DOCKERD_GOMEMLIMIT` overrides
  the derivation. The effective value is logged at startup. GOMEMLIMIT is a
  soft limit: when the live heap genuinely exceeds it, dockerd degrades to
  GC thrash (CPU) instead of memory growth — accepted, strictly better than
  the livelock. No GOGC changes in the first pass; only after the A/B
  measurement shows GOMEMLIMIT alone is insufficient.
- **Layer 1b — remove `docker system df` from the build path.** The build
  cache report either goes away or is replaced by a bounded client-side
  source (e.g. buildx/buildkit disk-usage queries known to stream, or
  filesystem-level sizing of the store directory with a real timeout).
  Decision rule: no call in the normal build path may trigger an unbounded
  daemon-side store walk; client-side timeouts are not an accepted
  mitigation (measured: the daemon keeps scanning after the client gives
  up).
- **Layer 2 — nested cgroup for the inner dockerd.** The dockerd startup
  path places the daemon in a dedicated cgroup scope below the Container's
  root with `memory.max` a fraction of the outer ceiling (starting point:
  ~50%, exact split to be grilled) and swap 0. Everything dockerd spawns
  (buildkit, inner containers) inherits the scope. Open questions to grill:
  (a) whether the in-container cgroupfs is writable enough under rootless
  Docker Desktop/WSL2 to create the scope (ADR 0020 measured the cgroup
  tree `ro` from *outside* flags; delegation inside the container is a
  different path and needs a probe); (b) whether inner workloads that
  legitimately need most of the box's memory (test suites in inner
  containers) make a 50% split too tight, and whether the split should
  follow `boxa mem set`.
- **Layer 3 — external guard (decision-gated, default: not built).**
  Only if the A/B evidence after layers 1+2 shows a remaining livelock
  class. Trigger policy as proposed: `memory.current >= 90%` of max AND
  (rapidly rising `memory.events.local:max` OR sustained PSI `full`);
  actions: persist diagnostic snapshot → `docker stop` the outer Container
  → `docker kill` on stop timeout; record the event separately from kernel
  OOM kills. Placement follows the keep-awake sidecar precedent (a small
  container on the devproxy network with host Docker socket access), with
  its own hard memory limit, no swap, no network beyond the Docker socket.
  Building it requires amending ADR 0020's option-2 rejection with the new
  evidence (memory.max does not guarantee a prompt kill), not silently
  contradicting it.
- **ADR 0020 amendment.** Add the measured semantics: `memory.max` enforces
  by reclaim; `memory.events.local` `max` counting without `oom` events is
  the livelock signature; a prompt kill is only guaranteed when reclaim
  cannot make progress (anonymous-dominant usage with swap off). Cite the
  2026-08-27 measurements.
- **Diagnostics.** Whatever layers land, a memory incident leaves a record
  naming the cgroup, dockerd RSS, `memory.events.local` counters and PSI at
  detection time. Where the record lives (host-side file vs. Log Cache) to
  be decided during grilling.
- **Explicitly not a fix:** wrapping daemon-triggering CLI calls in
  `timeout` (measured ineffective), raising `boxa mem set` (feeds the
  livelock), enabling swap (turns reclaim livelock into swap thrash — the
  pre-ADR-0020 failure mode).

## Testing Decisions

- Good tests here assert external behavior at the highest existing seams:
  the dockerd startup script's environment derivation (unit-testable pure
  bash: ceiling in → GOMEMLIMIT out, clamps, override, log line), the build
  path's absence of unbounded daemon scans (static/behavioral check of the
  build script), and — for the reproduction harness — observable cgroup
  counters, not implementation internals.
- Seams, highest-first:
  - `scripts/start-rootless-docker.sh` — derivation logic extracted so the
    ceiling→GOMEMLIMIT mapping and the nested-scope setup are testable
    without a running daemon (same style as the existing bash unit suites
    under `tests/`).
  - `build.sh` — assert the cache-report step produces bounded output and
    never invokes `docker system df` (grep-level guard test plus a
    behavioral run where feasible on host).
  - Reproduction harness — **opt-in, host-only, manual**: builds a synthetic
    inner store (many small files) in a throwaway volume, never the user's
    real `boxa-boxa-docker` volume, and never runs inside a box (no-build
    rule; OOM risk is the very subject). Not part of the normal suite;
    documented alongside the existing host-verification checklists.
- Prior art: bash unit suites `tests/resources.sh`, `tests/mem-report.sh`,
  `tests/oom-sweep.sh` (memory-limit parsing and reporting), and the
  ADR 0020 probe-based verification pattern for anything that depends on
  Docker Desktop/WSL2 cgroup topology (probe on the real host, record the
  result in the ADR, don't fake it in CI).
- Acceptance for the whole feature (from the measured repro): before the
  fix the harness reproduces the livelock; after layer 1 the same harness
  keeps dockerd RSS near the GOMEMLIMIT bound and WSL/Docker control plane
  stay responsive; after layer 2 an over-limit build dies inside the nested
  scope while the agent session survives; normal builds and compose down
  produce no false kills; existing memory/OOM suites stay green.

## Out of Scope

- Enforcing the no-build-inside-box rule itself (hooks/policy preventing
  agents from running builds) — this PRD makes violations survivable, not
  impossible.
- `memory.high`-based throttling on the outer Container (re-litigated and
  still rejected: unreachable topology per ADR 0020, and throttling would
  deepen the livelock).
- Enabling swap for boxes.
- Generic host-level protection (`.wslconfig`, earlyoom, systemd-oomd) —
  per-Project containment is the boxa contract.
- Shrinking or garbage-collecting the 8.5 GiB inner store (separate
  housekeeping concern; relevant only as harness input here).

## Further Notes

- Origin: live incident 2026-08-27 — the boxa-boxa box died twice by memory
  livelock during Codex delegation sessions; diagnosis and the measured
  reproduction are Codex's, the layering/ordering and the nested-cgroup
  alternative are the session's assessment. To be grilled before splitting
  into issues (`/grill-with-docs`, then `/to-issues`).
- Key tension to grill: layer 3 directly contradicts ADR 0020's rejection
  of watcher daemons. Either the new evidence justifies superseding that
  decision, or layers 1+2 must be shown sufficient and layer 3 dropped.
- Second tension: nested-cgroup writability under rootless DinD on Docker
  Desktop/WSL2 is unverified — needs a host probe before layer 2 is
  committed to.
- The livelock explains why `boxa mem set` "nefunguje" here: the limit was
  respected the whole time (785939 ceiling hits), but reclaim success meant
  the enforcement never escalated to a kill.
