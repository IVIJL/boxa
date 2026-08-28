# 02 — Live limit convergence via docker update

Status: done

## Parent

None — decisions are recorded in CONTEXT.md (`### Memory`) and will be
captured in ADR 0020 (issue 07 of this feature).

## What to build

A **Memory limit** change never requires recreating a Container
(CONTEXT.md relationship). When a `boxa` invocation touches an existing
Container (the running-attach path and the exited-restart path), compare
the live limits (`docker inspect` `HostConfig.Memory`/`MemorySwap`)
against the currently effective configured values; when they differ,
converge with `docker update --memory ... --memory-swap ...` and tell the
user what changed. Verified on the target host: `docker update` applies
`memory.max`/`memory.swap.max` to a running container in place.

This is also the migration path: pre-existing Containers created before
this feature (no limit set) receive their limit on the next `boxa`
invocation — with a visible one-line notice, never silently. No recreate,
no volume handling, no plan output needed.

Convergence must reach ALL running boxa Containers, not only the one the
invocation touches: on any `boxa` invocation, sweep the running `boxa-*`
Containers, compare live limits against each project's currently
effective configured values, and `docker update` only those that differ —
one printed notice per changed Container, silence when everything
matches. (Without this, a running Container of another project keeps its
old/no limit until explicitly touched.)

When convergence lowers a limit below the Container's current usage,
still apply it but warn that an immediate OOM kill may follow.

Add a one-shot CLI override flag (e.g. `--memory <size>`, optionally
`--memory-swap <size>`) at the top of the precedence chain. It applies to
the current invocation only (via `docker run` on create or `docker update`
on an existing Container) and is not persisted; the message should point
to `resources.conf` for a durable setting.

Always pass both values together to `docker update` (Docker requires
memory-swap alongside memory when both are constrained).

## Acceptance criteria

- [x] Changing `resources.conf` and re-running `boxa` on a running
      Container applies the new limit without stop/recreate; volumes and
      the running session are untouched
- [x] A pre-feature Container with no limit gets the effective limit via
      `docker update` on next invocation, with a printed notice
- [x] `--memory` flag overrides config for this invocation only and is
      not persisted; output points to the durable mechanism
- [x] Invalid flag values reuse issue 01 validation and abort clearly
      (`_boxa::parse_size` stderr message, exit 1)
- [x] When live and configured limits already match, nothing is printed
      and no `docker update` runs
- [x] Any boxa invocation converges other running boxa Containers too
      (sweep): a running pre-feature Container of a different project
      gets the limit without being touched, with a per-Container notice
- [x] Lowering a limit below current usage still applies it and prints an
      immediate-OOM-kill warning
- [x] Unit tests cover the convergence decision (extraction pattern from
      `tests/port-conflict.sh` if the logic lives in `docker-run.sh`)
- [x] shellcheck clean (`shellcheck -S info -x` on docker-run.sh,
      lib/resources.sh, tests/resource-convergence.sh)

## Blocked by

- `01-memory-limit-at-creation.md`

## Comments

Done in commit `3dd3890` (implemented by Codex, verified natively).

- Decision logic lives in `lib/resources.sh`
  (`_boxa::plan_resource_convergence`, `_boxa::format_live_limit`) —
  pure, no docker — so unit tests source the lib directly; the
  awk-extraction pattern from `tests/port-conflict.sh` was not needed.
  Tests: `tests/resource-convergence.sh` (12 assertions, all green).
- Glue in `docker-run.sh`: `_boxa::converge_container_resources`
  (touched-Container paths: running-attach by dir/name, exited-restart,
  picker), `_boxa::sweep_running_resource_limits` (synchronous
  invocation-time sweep next to the OOM sweep — synchronous because
  notices must be visible), `_boxa::container_project_path`
  (`docker inspect` Config.Env `BOXA_PROJECT_HOST_PATH`), usage read via
  `BOXA_MEMORY_USAGE_FILE` test seam / cgroup `memory.current`.
- `docker update` always receives `--memory` and `--memory-swap`
  together.
- Exception: a real `docker update` against a live Docker daemon cannot
  be executed from inside this agent's Container — the seams + unit
  tests over the decision layer are the proof; `docker update` in-place
  behavior itself was verified on the target host during design
  (recorded in this spec).
