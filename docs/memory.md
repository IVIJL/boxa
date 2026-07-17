# Memory limits

Every boxa Project runs under a hard **Memory limit** and **Memory+swap
limit**, enforced on its outer container's cgroup. Everything inside counts
against it — the agent, its subprocesses, and every nested Docker-in-Docker
workload. When the limit is reached the kernel kills a victim process it
selects inside the container (observed: the largest one); the container itself
keeps running. There is no boxa daemon anywhere: the kernel enforces the
limit, and boxa's warnings and records piggyback on normal `boxa` invocations.

Why this exists: a single runaway process (a `ugrep` run with multi-GiB RSS)
once dragged the entire WSL2 VM into swap thrashing until it was unusable —
and the VM restart that recovered the host wiped the only evidence of what
happened. The limit turns that into a fast, local, *recorded* kill inside one
Project. Design rationale:
[ADR 0020](adr/0020-per-project-memory-limits.md).

## Semantics: Memory limit vs Memory+swap limit

- **Memory limit** — the hard ceiling on the Project's RAM use.
- **Memory+swap limit** — the **total** RAM-plus-swap the container may
  consume. It is *not* an amount of swap: `memory_swap = 6g` with
  `memory = 5g` grants exactly 1 GiB of swap, not 6.

How the two combine:

| Configuration | Effect |
|---|---|
| `memory_swap = memory` (**boxa default**) | Swap off. A breach OOM-kills a victim immediately — no thrashing. |
| `memory_swap > memory` | Swap allowance of exactly the difference. The Project can spill that much to swap before the kill. |
| `--memory` without `--memory-swap` (raw Docker) | **Silent footgun:** Docker grants 2× the memory value as the swap total. Measured: `docker run -m 100m` alone → `memory.swap.max = 104857600` (another 100 MiB of swap you never asked for). |
| No limits at all | Unlimited — the original incident. One process can take the whole VM into swap thrashing. |

Boxa always passes **both** `--memory` and `--memory-swap` explicitly, so the
silent-2× footgun cannot happen through boxa. It matters when you run raw
`docker run -m …` yourself, or when reasoning about other tooling.

Swap is off by default on purpose: the motivating incident harmed the host by
swap thrashing, not by the OOM kill — the kill was the relief. A runaway must
die at its limit, immediately.

## Configuration

Limits live on the **host** in `~/.config/boxa/resources.conf`, keyed by the
project's absolute host path — never in the project repo. Sandboxed content
must not configure its own sandbox; a hostile repo would simply raise its own
limit.

The file accepts only `memory` and `memory_swap` keys (globally or under an
`[/absolute/path]` section), `#` comments, and Docker-style sizes: `512m`,
`5g`, `6GiB` — binary multiples, case-insensitive, minimum 6 MiB (Docker
refuses less). It is parsed, never sourced.

```ini
# Global default for every Project without its own section
memory = 8g

[/abs/path/to/media]
memory = 5g
memory_swap = 6g   # 5 GiB RAM + 1 GiB swap allowance (total, not amount)
```

The `[/abs/path/to/media]` section pins the `media` project to a 5 GiB Memory
limit with a 1 GiB swap allowance — remember `memory_swap` is a total, so the
allowance is the difference.

### Precedence

For each of the two values independently, highest wins:

1. One-shot CLI flag: `boxa --memory 4g ~/app` (and `--memory-swap SIZE`)
2. Project section in `resources.conf`
3. Global key in `resources.conf`
4. Derived default: **65 % of host RAM** (`MemTotal`)

If nothing sets `memory_swap`, it equals the Memory limit (swap off).
`memory_swap` below `memory` is rejected.

Every start prints the effective value and where it came from:

```
Memory limit: 6.5g (derived from 10g host RAM; override in ~/.config/boxa/resources.conf)
```

A one-shot flag prints `(CLI flag; one-shot only; set
~/.config/boxa/resources.conf for a durable setting)` instead — the flag
applies to this invocation and is not remembered.

### Changes apply live

Any `boxa` invocation converges running containers to their configured limits
via `docker update` — no restart, no recreate, volumes untouched. Each change
prints one notice:

```
Memory limits updated for boxa-media: memory 8g -> 5g; memory+swap unlimited -> 6g.
```

Lowering a limit below the container's *current* usage additionally warns:

```
WARNING: boxa-media currently uses 5.6g, above its new 5g Memory limit; an immediate OOM kill may follow.
```

This same path migrates pre-feature containers that were created without
limits.

## The warning that matters

A Memory limit **above host RAM voids the protection entirely** — the VM will
swap-thrash before the cgroup limit is ever reached, which is exactly the
original incident. Boxa warns but does not refuse (the host user is trusted):

```
WARNING: Memory limit exceeds host RAM; protection is void.
```

If you see this, lower the limit below host RAM or accept that this Project is
effectively unlimited.

## VM-level backstop (.wslconfig)

Per-project limits are **caps, not reservations**. There is no global budget:
N Projects with individually sane limits can still *jointly* exhaust the VM.
When starting a container would push the sum of running containers' Memory
limits above host RAM, boxa warns once:

```
WARNING: Running boxa Containers can jointly exhaust host RAM; use the .wslconfig VM backstop.
```

The warning is a mitigation, not a guarantee. On WSL2, the last-resort
complement is a VM-level cap in `%UserProfile%\.wslconfig` on Windows:

```ini
[wsl2]
memory=12GB   # cap the WSL2 VM's RAM
swap=8GB      # cap (or 0 to disable) the VM's swap file
```

Apply with `wsl --shutdown` (stops everything running in WSL) and restart.
This bounds the whole VM so that even a joint exhaustion cannot take down
Windows itself.

## What happens at the limit

When the Project's memory usage hits its Memory limit (with swap off — the
default — or its Memory+swap limit otherwise), the kernel OOM-kills a
**kernel-selected victim** inside the container. The victim is chosen by the
kernel's `oom_score` heuristic — observed on the target host to be the largest
process, with PID 1 surviving and the session and DinD databases living on —
but that is a heuristic, **not a guarantee**. The victim is not necessarily
the command you just ran; it may be a background process or a nested Docker
workload. The container keeps running.

Where the story surfaces:

- **`boxa ls`** — the `MEM` column shows `usage/limit percent` (for example
  `1.2g/6.5g 18%`) and appends a `!oom×N` marker when OOM kills happened
  during the container's lifetime. Exited containers whose lifetime flag is
  set are marked `oom seen during run — see 'boxa mem <project>'`.
- **`boxa mem [project|path]`** — the deep dive: live usage against both
  limits, the cgroup's `memory.events` counters (`oom_kill` is the
  authoritative per-Project kill count), top processes by RSS as a **project
  aggregate** (nested DinD containers cannot be attributed individually — see
  troubleshooting below), the most recent **OOM archive** entries, and
  concrete recovery commands (one-shot raise, durable `resources.conf` edit).
- **Desktop notification** — the first `boxa` invocation after the event
  raises one: *"Project media hit its 5 GiB memory limit. Killed by the
  kernel: ugrep, 4.6 GiB RSS. The project keeps running."*
- **Agent hook message** — inside the container, a PostToolUse hook (Claude
  Code and Codex) tells the agent at the next tool call that a process was
  OOM-killed, with the victim's name and RSS, and warns it not to retry the
  killed work as-is. The same hook raises a **Memory warning** when usage
  enters the 80 % or 90 % band of the Memory limit — once per band entry,
  re-arming only after usage falls back below 75 %, so hovering at a threshold
  warns once, not continuously.
- **The OOM archive** — a durable per-event record under `/var/log/boxa/oom/`
  (one file per event, named `<container>-<kernel-timestamp>.log`), written by
  the sweep that runs detached alongside every `boxa` invocation. It carries
  the project name, the Memory limit in force, the kernel-selected victim and
  its RSS, and the kernel timestamp — so the evidence survives container
  removal *and* a VM restart, which the kernel ring buffer does not.

Two honest caveats:

- **`.State.OOMKilled` is a lifetime flag.** `docker inspect` reads it `true`
  if *any* OOM kill happened during the container's lifetime — even after a
  clean exit — and `false` while the container keeps running after a kill. It
  does **not** mean "the container died of OOM". Live truth is the cgroup's
  `memory.events`; post-mortem detail is the OOM archive.
- **The warning/archive layer is best-effort and eventual.** There is no
  daemon: events are archived by the next `boxa` invocation. If the VM dies
  before any invocation sweeps, that event is lost (the ring buffer does not
  survive a restart). Enforcement is unaffected — only the reporting is
  eventual.

## Troubleshooting

### No OOM archive entries appear

The best-effort/eventual archive and desktop notification require the host
`dmesg` command to read the kernel log. Run `dmesg` as the same unprivileged
host user that runs boxa. If it fails with `Operation not permitted`, check
`kernel.dmesg_restrict`; a value of `1` blocks the sweep on native Linux.
Boxa deliberately leaves its cutoff untouched when `dmesg` fails so a later
sweep with readable access can still archive the old kernel-selected victim.

This path is verified on WSL2/Docker Desktop, where host `dmesg` exposes the
shared Linux VM ring buffer. macOS Docker Desktop does not expose its Linux
VM kernel log through host `dmesg`, so it gets no OOM archive entries or
desktop OOM notifications. The live surfaces remain available on either
kind of host: `boxa ls`, `boxa mem`, and the agent hook read cgroup files and
`docker inspect` rather than the kernel log.

### A single process with runaway RSS

The ugrep-style incident: one process grows without bound until it hits the
Memory limit and the kernel kills it. You will see the desktop notification
and (for an agent) the hook message naming the victim and its RSS; `boxa mem
<project>` shows the archive record and the `oom_kill` count.

If the process legitimately needs more memory, raise the limit — the running
container converges live, no restart:

```bash
# One shot, this invocation only:
boxa --memory 12g /abs/path/to/project
```

```ini
# Durable: ~/.config/boxa/resources.conf
[/abs/path/to/project]
memory = 12g
```

If it does not legitimately need more, the limit did its job: the kill was
local to the Project and the host never noticed. Do not retry the killed work
unchanged — at the same limit it will likely be killed again.

### Exhausted swap / sluggish VM

If you granted a swap allowance (`memory_swap > memory`), a Project sitting at
its Memory limit spills into swap up to the allowance — and swapping is disk
I/O, so the Project (and, under a large allowance, the VM) gets sluggish
*before* any kill happens. Check `boxa mem <project>`: `Swap usage` near the
allowance plus memory usage at the limit means the Project is living in swap.

Fixes: remove the allowance (`memory_swap = memory` — the default) so the
runaway is killed immediately instead of thrashing, or raise `memory` so the
working set fits in RAM. Keep swap allowances small (the worked example grants
1 GiB); a large allowance recreates the original incident in slow motion.
Also cap the VM's own swap file via `.wslconfig` `swap=` (see the backstop
section above).

### OOMKilled outer container

`boxa ls` shows an exited container marked `oom seen during run`, or `docker
inspect` shows `.State.OOMKilled: true`. Read that flag correctly: it is a
**lifetime flag** — at least one OOM kill happened while the container ran. It
does *not* say the container died of OOM; it reads `true` even after a clean
`boxa stop`. `boxa mem <project>` on an exited container prints exactly this
distinction, plus the archived events.

To find out what actually happened: check the OOM archive entries in `boxa mem
<project>` for what was killed and when, and the container's exit code
separately. PID 1 surviving a kill is the observed behavior, not a guarantee —
if the kernel's heuristic ever selects PID 1 or the kill cascades, the
container itself can die. If the archive shows repeated kills before the exit,
raise the limit; if there are no archived events near the exit, the OOM flag
is likely old history and the exit had another cause.

### Nested DinD workload hitting the project limit

Nested Docker workloads (your `docker compose` databases, builds, test
runners) count against the Project's limit **in aggregate**. The inner
rootless dockerd runs without cgroups (`CgroupDriver=none`), so
per-nested-container attribution is impossible *in principle* — no tool can
tell you "postgres used 2 GiB of it"; `docker stats` inside the container
shows no memory accounting either.

Symptoms: a nested database or build dies unexpectedly; the hook/notification
names a victim like `postgres` you did not start directly. Diagnose with
`boxa mem <project>` — the top-processes list is sorted by RSS across
everything in the container, nested workloads included, so the heavy nested
process is visible there even though it cannot be attributed to a specific
nested container.

Fixes: bound the nested workload itself (compose `mem_limit`, JVM `-Xmx`,
`--max-old-space-size`, …) so a runaway dies inside its own bounds first, or
raise the Project's limit to fit the aggregate working set.

### Disk I/O saturation vs swap thrashing

Both look like "everything is slow". To tell them apart:

- With the default (swap off), a Project **cannot** swap-thrash: `boxa mem`
  will show `Swap usage: 0`. Slowness then is real I/O load or CPU, not swap.
- With a swap allowance, check `boxa mem <project>`: swap usage near the
  allowance while memory sits at the limit means swap thrashing — fix per the
  exhausted-swap section above.
- At the VM level, run `vmstat 1` in any WSL shell and watch the `si`/`so`
  columns (swap-in/swap-out): sustained non-zero values mean the *VM* is
  swapping (check `.wslconfig` `swap=` and the joint-exhaustion warning);
  zero `si`/`so` with high `wa` (I/O wait) means genuine disk I/O saturation —
  look for the I/O-heavy process instead of touching memory limits.

## Safe trial

Try the whole pipeline harmlessly — tiny limit, bounded allocation, no real
Project involved. The container name starts with `boxa-`, so the sweep treats
it like a Project (the same pattern the repo's opt-in integration test uses):

```bash
# 1. A throwaway container with a 64 MiB Memory limit, swap off,
#    allocating a bounded ~128 MiB (2x the limit, then stops):
docker run --name boxa-oom-trial -m 64m --memory-swap 64m alpine \
    sh -c 'head -c 128m /dev/zero | tail'
# -> killed at ~64 MiB; the host never noticed.

# 2. The kernel recorded it (memcg OOM, visible in the shared WSL kernel log):
dmesg | grep -i 'oom-kill' | tail -n 2

# 3. Any boxa invocation sweeps the event into the OOM archive and raises
#    the desktop notification:
boxa ls
ls /var/log/boxa/oom/          # boxa-oom-trial-<timestamp>.log

# 4. The deep dive shows the lifetime flag semantics and the archive entry:
boxa mem oom-trial

# 5. Clean up (keep the container until after step 3 - the sweep needs it
#    to resolve the name):
docker rm boxa-oom-trial
rm /var/log/boxa/oom/boxa-oom-trial-*.log   # optional: drop the trial record
```

Safety properties: the limit is 64 MiB, the allocation is bounded to 128 MiB
by `head -c`, swap is off, and nothing outside the throwaway container is
touched.
