# ADR 0020 — Per-project memory limits enforced on the outer Container

- **Status:** accepted
- **Date:** 2026-07-17

## Context

A single runaway process inside one Project (a `ugrep` run with multi-GiB
RSS) took down the entire WSL2 VM — not by an OOM kill, but by dragging the
VM into swap thrashing until it was unusable. The OOM kill, when it finally
came, was the *relief*, not the harm. Worse, the evidence vanished: the
kernel ring buffer is memory-only, and the VM restart that recovered the
host also wiped the only record of what had happened.

Boxa's topology makes this a per-Project problem with a single natural choke
point. Each Project runs as one outer Container holding the agent, its
subprocesses, and a rootless Docker-in-Docker daemon (ADR 0018) whose nested
workloads are the memory consumers users actually run. Nothing bounded any
of it.

Options considered for the enforcement mechanism:

1. **`memory.high` (cgroup v2 throttling).** Conceptually ideal — slows the
   offender before the kill — but unreachable on the verified topology:
   Docker exposes no flag for it, the in-container cgroupfs is mounted `ro`,
   and the cgroup tree lives in the `docker-desktop` distro.
2. **A user-space watcher daemon** (or `earlyoom`/`systemd-oomd`).
   Race-prone, adds a standing process boxa deliberately has none of, and
   `systemd-oomd` needs a systemd-owned unified hierarchy that does not
   exist here; `earlyoom` is global, not per-Project.
3. **VM-level caps only (`.wslconfig memory=`/`swap=`).** Protects the host,
   but one Project can still starve every other Project inside the VM.
4. **A hard cgroup limit on the outer Container** via `docker run --memory`
   / `--memory-swap`. Docker supports it directly; cgroup v2 `memory.max`
   triggers a *local* cgroup OOM, not a global one.

All key behaviors were verified by probes on the target Docker Desktop/WSL2
host during the design session (cgroup v2, cgroupfs driver) — the decisions
below cite those measurements rather than documentation.

## Decision

Every Project gets a hard **Memory limit** and **Memory+swap limit**
(CONTEXT.md `### Memory` terms) enforced on its outer Container's cgroup,
with warnings, an **OOM archive**, and live convergence layered on top — and
no daemon anywhere.

- **The enforcement point is the outer Container's cgroup.** The inner
  rootless dockerd runs with `CgroupDriver=none` (verified), so nested DinD
  workloads count against the outer limit automatically — and, for the same
  reason, per-nested-container attribution is impossible *in principle*.
  Everything inside is a project aggregate, and all reporting says so.
- **The default is derived — 65 % of host MemTotal — and printed at
  startup.** A fixed-GB default is wrong on half of all machines. Printing
  the effective value and its origin (`derived from … host RAM; override in
  ~/.config/boxa/resources.conf`) is what makes imposing a default on
  existing projects acceptable. Limits are **caps, not reservations** — not
  a global budget: N Projects can still jointly exhaust the VM (a shared
  parent cgroup is not reachable under Docker Desktop). Two mitigations —
  not guarantees — cover this: a one-line joint-exhaustion warning at start
  when the sum of running Containers' limits exceeds host MemTotal, and the
  documented `.wslconfig` VM backstop.
- **Swap is off by default: `memory_swap = memory`.** The original incident
  killed the VM by swap thrashing, not by OOM — so the runaway must be
  OOM-killed immediately rather than allowed to swap. Docker footgun,
  measured: `--memory` without `--memory-swap` silently grants 2× memory as
  swap total (`-m 100m` alone → `memory.swap.max = 104857600`). Both flags
  are therefore always passed explicitly.
- **The limit kills a process, not the Project.** On breach, the kernel
  picks an OOM victim by its `oom_score` heuristic — observed on the target
  host as the largest process, with PID 1 surviving and the session and
  DinD databases living on — but that is a heuristic, **not a guarantee**.
  All wording (this ADR, notifications, docs) says "kernel-selected victim
  (observed: largest process)" and never promises PID 1 survival. Docker
  does not expose `memory.oom.group`, so kill-the-whole-cgroup is not an
  available alternative.
- **The kernel log is the source of truth; `.State.OOMKilled` is a lifetime
  flag.** Measured: the flag reads true after a *clean* exit if any OOM kill
  happened during the container's lifetime, and false while the container
  keeps running after a kill. So live truth is the cgroup's
  `memory.events`, and post-mortem detail is the dmesg-fed **OOM archive**:
  host `dmesg` (no sudo) sees container OOM events — the WSL VM shares one
  ring buffer — but a VM restart wipes it, hence each event is copied out to
  a durable archive record at first sighting.
- **`memory.high` is unreachable**, so the 80 %/90 % **Memory warning**
  bands (fire on entering a band, re-arm below it) are the substitute —
  observability in place of throttling, not a workaround pretending to be
  throttling.
- **No daemon.** The kernel enforces the limit with no process of ours
  running. Host-side diagnostics piggyback on the invocation-time sweep
  (the allow-for notification precedent, ADR 0009): any `boxa` invocation
  archives new OOM events and raises the desktop notification. Agent-side,
  a PostToolUse hook (delivery per ADR 0011) reports kills and Memory
  warnings; its silent no-change path measured at ~1.4 ms per tool call.
  This layer is **best-effort and eventual** — it observes; only the cgroup
  enforces.
- **Config lives on the host (`~/.config/boxa/resources.conf`), keyed by
  absolute host path (ADR 0005), never in the project repo.** Sandboxed
  content must not configure its own sandbox: a hostile repo would simply
  raise its own limit. Precedence: one-shot CLI flag > project section >
  global key > derived default.
- **Limit changes converge live via `docker update`** — measured to apply
  `memory.max`/`memory.swap.max` to a running container in place. No
  recreate, and therefore no volume-preservation machinery. The same path
  migrates pre-feature Containers: the sweep converges *all* running
  `boxa-*` Containers to their configured values, with one printed notice
  per change.

## Rationale

- **The outer cgroup is the only point that covers everything at once.** It
  bounds agent subprocesses, the inner dockerd, and every nested workload in
  one number, and it acts with zero dependence on any polling process being
  alive — precisely the failure mode of watcher-based designs.
- **Containment over throughput.** Swap-off trades graceful degradation for
  a fast, local kill, because the measured harm of the alternative (VM-wide
  thrashing) dwarfs the harm of losing one process — which the kernel-side
  design then makes visible instead of silent.
- **Honest observability.** Every reporting surface is built on what was
  actually measured: `memory.events` for live state, dmesg for forensics,
  and wording that matches the kernel's real contract (heuristic victim,
  lifetime flag) rather than the folk model.

## Consequences

**Positive:**

- One runaway Project is OOM-killed at its own limit instead of swap-
  thrashing the whole VM; the Container — and its DinD databases — keep
  running.
- OOM events survive Container removal and VM restarts in the OOM archive,
  fixing the exact evidence loss of the motivating incident.
- Zero standing overhead: no daemon, no polling; costs are paid at
  invocation time and per tool call (~1.4 ms silent path).

**Negative / accepted limitations:**

- **Multi-Project sums are unchecked by construction.** Caps are not
  reservations; N Projects can jointly exhaust the VM. Mitigated — not
  solved — by the sum > MemTotal warning at start and the `.wslconfig`
  backstop. Full admission control was considered and rejected: editing
  `resources.conf` is already an explicit act, and a warning suffices.
- **If the VM dies before any `boxa` invocation sweeps, the OOM event is
  lost** — the no-daemon diagnostics layer is best-effort/eventual, and the
  ring buffer does not survive a restart. Enforcement is unaffected.
- **No per-nested-container attribution, ever.** The inner dockerd runs
  without cgroups, so `boxa mem` can only show a project aggregate and top
  processes by RSS.
- **Agent hook parity depends on Codex managed config supporting
  PostToolUse.** If it does not, Codex degrades to a SessionStart summary
  ("N processes were OOM-killed since your last session"); the asymmetry is
  documented in the hook script header.
- Out of scope by design: PID exhaustion, CPU starvation, and disk/IO
  exhaustion are separate features; a trusted host user can always raise or
  void the limit (a limit above host RAM warns that protection is void, but
  is not refused).

## References

- `docker-run.sh` — `DOCKER_ARGS` (`--memory`/`--memory-swap` on create),
  the convergence sweep (`docker update`), the `boxa ls` MEM column, and
  the `boxa mem` subcommand.
- `lib/resources.sh` — size parsing, `resources.conf` resolution, derived
  default (new).
- `scripts/hooks/` — the agent-side PostToolUse hook (new).
- `/var/log/boxa/oom/` — the OOM archive records written by the host sweep.
- `docs/memory.md` — user-facing semantics, configuration, and
  troubleshooting.
- `CONTEXT.md` `### Memory` — Memory limit, Memory+swap limit, OOM archive,
  Memory warning.
- ADR 0005 — absolute-path keying that `resources.conf` sections reuse.
- ADR 0009 — the invocation-time sweep precedent the OOM sweep piggybacks
  on.
- ADR 0011 — the managed-settings hook delivery the agent hook reuses.
- ADR 0018 — the Docker-in-Docker model whose nested workloads this limit
  must (and does) cover.
