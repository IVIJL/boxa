# 01 — Memory limit applied at Container creation

Status: done

## Parent

None — decisions are recorded in CONTEXT.md (`### Memory`) and will be
captured in ADR 0020 (issue 07 of this feature).

## What to build

Every newly created Container gets a **Memory limit** and **Memory+swap
limit** (CONTEXT.md terms) enforced via the outer `docker run`. A new
resources library provides size parsing, config resolution and the derived
default; a new user config file holds overrides.

Config file: `~/.config/boxa/resources.conf`, `key=value`, strict-parsed in
the established `_boxa::load_dns_conf` style (never `source`d, fixed key
allow-list, env-var path seam for tests, lazy cache + reset function).
Sections are keyed by **absolute host path** (the ADR 0005 name-collision
rule — never by sanitized project name). Decision-rich shape from the
design session:

```
# global default (otherwise derived from host RAM)
memory = 6g
memory_swap = 7g

[/home/vlcak/Projekty/media]
memory = 5g
memory_swap = 6g
```

Precedence: CLI flag (issue 02) > project section > global key > derived
default. The derived default is **65 % of host MemTotal**, computed at
Container start.

Swap semantics (verified on the target Docker Desktop/WSL2 host):
`memory_swap` follows Docker semantics — it is a **total**, not an amount
of swap. Default is `memory_swap = memory` (swap off), so a runaway
process is OOM-killed immediately instead of swap-thrashing the WSL VM.
Both `--memory` and `--memory-swap` must **always** be passed explicitly:
leaving `--memory-swap` unset silently grants 2× memory (verified:
`-m 100m` alone → `memory.swap.max = 104857600`).

At startup, print the effective limit and where it came from, with an
override hint, e.g.:
`Memory limit: 6.5g (derived from 10g host RAM; override in ~/.config/boxa/resources.conf)`.

Validation: reject zero, negative, unparseable and sub-6 MiB sizes
(Docker's `--memory` minimum) with a clear error; reject
`memory_swap < memory`; if the effective limit exceeds host RAM, warn
that the protection is void (do not refuse).

Limits are caps, not reservations: when the sum of Memory limits across
running boxa Containers (plus the one being started) exceeds host
MemTotal, print a one-line joint-exhaustion warning pointing at the
`.wslconfig` VM backstop (documented in issue 08).

Nested DinD needs no extra work: the rootless inner dockerd runs with
`CgroupDriver=none` (verified), so all nested workloads count against the
outer Container's limit automatically.

## Acceptance criteria

- [x] Size parser accepts `512m`, `5g`, `6GiB` (case-insensitive, k/m/g,
      optional `iB`/`B` suffix) and returns bytes; rejects `0`, negatives,
      and garbage with a specific error message
- [x] `resources.conf` global keys and `[/abs/path]` sections parse; keys
      outside the allow-list are ignored, file is never `source`d
- [x] Precedence chain resolves correctly (project section > global >
      derived default); covered by unit tests
- [x] Derived default = 65 % of MemTotal when nothing is configured
- [x] `docker run` for a new Container always includes both `--memory` and
      `--memory-swap`; with no `memory_swap` configured the two are equal
      (unit-tested at lib level; real `docker run` not executable from
      inside the boxa container — seams are the proof)
- [x] Startup output states the effective limit and its source
- [x] `memory_swap < memory` and invalid limits abort with a clear error;
      sizes below 6 MiB are rejected; limit > host RAM prints a
      "protection is void" warning
- [x] Sum of running boxa Containers' limits > host MemTotal prints a
      joint-exhaustion warning at start (predicate + sum unit-tested via
      `BOXA_RUNNING_MEMORY_LIMITS_FILE` seam)
- [x] Unit tests in `tests/resources.sh` (repo pattern: plain bash,
      `assert_eq`, PASS/FAIL, exit 1 on failure) pass
- [x] shellcheck clean, including info-level findings (repo invocation
      `shellcheck build.sh install.sh docker-run.sh scripts/*.sh lib/*.sh
      tests/*.sh -S info`; sole remaining finding is pre-existing SC2034
      in untouched `tests/memory-context.sh`, out of scope)

## Blocked by

None — can start immediately.

## Comments

2026-07-17: implemented (Codex sol, finished/verified by Claude finisher).
Commit `fec3f3d` — `lib/resources.sh`, `tests/resources.sh`, `docker-run.sh`.
All 18 unit tests green; full `tests/*.sh` suite green (incl.
`port-conflict.sh` awk-extraction from the modified `docker-run.sh`).
No native fixes needed. CLI-flag seams for issue 02 already present
(`_boxa::resolve_resources <path> [mem] [swap]`).
