# 14 — Persona assignment write-through

Status: done

## Parent

ADR 0034 decisions 2, 7, 11; carries over ADR 0033
assignment-implies-gate-on and guarded remove, re-keyed to personas.

## What to build

Assigning a persona to a project applies the whole bundle: the project
agent holds exactly the persona's keys (one principal, never a mix),
container creation injects the persona's tokens (`GH_TOKEN` /
`GITLAB_TOKEN` / `GITLAB_HOST`) and committer identity (GitHub side
when configured, else GitLab), and both the forge gate and the SSH
gate turn on (assignment is intent; a persona with no keys leaves the
SSH gate off). Replacing a project's persona swaps all of it; `none`
clears it. `forge off` stays a kill switch that does not delete the
assignment. `forge remove` keeps its guard: refuses while the persona
is assigned anywhere or is the default persona, `--force` cleans up.

`forge status` shows per-project resolution: assigned persona (or
default-persona fallback), which forges it covers, and gate states.

## Acceptance criteria

- [x] Assigning persona A over persona B swaps keys, tokens, and
      committer in one step; nothing of B remains.
- [x] A persona lacking a forge leaves that forge unconfigured in the
      box (no stale env), lacking keys leaves the SSH gate off.
- [x] Default persona applies when no explicit assignment; `none`
      overrides it.
- [x] Guarded remove refuses / `--force` cleans assignments and
      default.
- [x] shellcheck clean (incl. info); pty coverage of the flows.

## Blocked by

- 11-binary-ssh-gate-project-agents.md
- 12-persona-storage-and-migration.md

## Comments
