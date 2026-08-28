# Handoff: per-project memory limits (boxa)

## FEATURE COMPLETE (2026-07-17)

All 9 issues implemented + Codex review loop clean after 12 rounds
(18 findings fixed, all committed on main; range `387b56b..HEAD`,
25 commits, NOT pushed). Remaining for the user:
1. Host verification: `BOXA_INTEGRATION=1 bash tests/integration-memory.sh`
   (gated; in-container it SKIPs loudly). Covers phases A–E incl. real
   boxa Container, OOM trip, `boxa ls` marker, sweep/archive.
2. Rebuild the image (Dockerfile bakes the new memory hook) and push
   when satisfied.

Date: 2026-07-16. Grill-with-docs session finished; design locked, issues
published, **zero implementation yet**. Next session = implement.

## Design-review pass (2026-07-17, Codex gpt-5.6) — already applied

Full review + accept/reject disposition: `codex-review.md` (same dir).
Spec updates are folded into the issues — do not re-apply, do not
re-litigate the rejected items listed there. Highlights: 6 MiB floor +
sum>MemTotal joint-exhaustion warning (01), all-running-Containers
convergence sweep + lower-below-usage OOM warning (02), swap usage in
`boxa mem` (04), victim wording (06), OOM-victim-is-heuristic wording +
mitigations bullet (07), `.wslconfig` VM backstop in docs (08).
**Batch order change: implement issue 07 (ADR) FIRST.**

## Where everything lives

- **Issues (the spec):** `.scratch/memory-limits/issues/01–09` — all
  `ready-for-agent`, dependency-ordered. Read them; do not re-derive the
  design. Decisions AND the empirical measurements backing them are
  embedded there (issue 07 = ADR 0020 content).
- **Glossary:** CONTEXT.md gained `### Memory` (Memory limit, Memory+swap
  limit, OOM archive, Memory warning) + 3 relationship bullets. Use these
  terms; "memory pressure" is banned (PSI collision).
- **Uncommitted:** CONTEXT.md edit + the whole `.scratch/memory-limits/`
  dir sit in the working tree. User commits on explicit word only
  ("commitni") — never auto-commit.

## What was verified on the user's actual host (don't re-litigate)

All confirmed by probes the user ran on the WSL2/Docker Desktop host or
measured inside the boxa container this session; details sit in the
issues. Headlines: cgroup v2 + cgroupfs; `--memory-swap = memory` →
`memory.swap.max = 0` works (swap accounting present); `--memory` alone
silently grants 2× swap; OOM kills the largest process and PID 1
survives; `.State.OOMKilled` = "an OOM happened during lifetime" (true
even after clean exit), NOT "died of OOM"; host `dmesg` (no sudo) sees
container OOM events — shared WSL VM ring buffer, wiped on VM restart;
`docker update` changes limits on a running container in place; inner
rootless dockerd has `CgroupDriver=none` → DinD counts against the outer
limit automatically, per-nested attribution impossible; in-container
cgroupfs is `ro` but `memory.current/max/events` readable; silent hook
path ≈ 1.4 ms.

## Codebase map (line numbers as of commit 13c7511, may drift)

`docker-run.sh`: dispatcher `case` :1823 (sets `MODE`, handlers are
`if [ "$MODE" = ... ]` blocks below); `DOCKER_ARGS` :3704–3939; project
`docker run` :3976; `boxa ls` table `list_running_containers()` :1623;
allow-for notification sweep trigger :1800–1816 (the pattern issue 06
extends); `stop` :2872 (always `docker rm`; volumes survive by name).
Config parser pattern to copy: `_boxa::load_dns_conf` in
`lib/naming.sh:56` (strict key=value, never sourced, env seam, lazy
cache). Tests: plain bash `tests/X.sh` for `lib/X.sh`, `assert_eq`,
PASS/FAIL; no CI; docker-run.sh is NOT source-safe — extract functions
via awk (`tests/port-conflict.sh` precedent). Hook precedent: ADR 0011,
`managed-settings/claude-code/` + `managed-settings/codex/managed_config.toml`,
one shared script `scripts/hooks/boxa-identity-context.sh`.

## Gotchas for the implementer

- This agent session runs INSIDE the boxa container for project "boxa".
  Host-side behavior (docker run flags, sweeps, toasts) can't be executed
  here — ask the user to run host probes/commands, or test via the
  gated integration test on their machine.
- `boxa status` doesn't exist and must not be created (completions file
  documents this); the new command is `boxa mem`, plus a MEM column in
  `boxa ls`.
- Only open verification: whether Codex managed config supports
  PostToolUse (issue 05 contains the agreed fallback — handle within that
  issue, no user decision needed).
- shellcheck everything including info-level; user reviews via `/cr`
  before any commit.

## Suggested skills

- `afk-feature-workflow` — if the user wants the whole batch run AFK over
  `.scratch/memory-limits/issues/` (issues were written for this).
- `tdd` — issues 01/05/06 are test-first shaped (parsers, band/dedup
  logic, dmesg fixtures).
- `cr` — review loop before the user's commit word.
- `boxa` — if container/host boundary questions come up mid-work.
