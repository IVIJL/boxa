# 34 — `boxa ssh on` falls into the legacy key picker instead of pointing at personas

Status: done
Type: AFK

## Parent

Live verification round 3, 2026-08-26; ADR 0034 (keys belong to
personas; the per-project agent forwards only persona keys).

## What happened (live repro)

With a keyless persona assigned, `boxa ssh on` enabled the gate and
then (docker-run.sh ~4365 → `_boxa::ssh_add_project_keys_if_agent_unready`,
lib/ssh.sh ~1346) hit the reapply status 2 branch and dropped the user
into the legacy interactive key picker (`_boxa::ssh_add_keys`). The
user expected: on/off is a plain toggle; if anything is missing, the
tool should talk about personas, not raw keys.

## What to build

- `boxa ssh on` (project scope): keep enabling the gate and keep the
  registry reapply for the running agent, but NEVER open the legacy
  key picker. Two follow-up cases, decided by the user 2026-08-26:
  - No persona assigned to the project: launch the existing persona
    assignment flow (`_boxa::forge_use`) with the current project
    preselected as the target, so the user picks/creates a persona
    right there (the add-persona checklist is reachable from it). If
    the user cancels, the gate stays on and a short note explains
    nothing will be forwarded until a persona with keys is assigned.
  - Persona assigned but it has no attached keys: print an
    explanation naming the persona (e.g. "Gate is on, but persona
    'vlcak' has no attached SSH keys, so nothing will be forwarded.
    Attach keys in 'boxa forge' (Attach an SSH key).") and exit 0 —
    the gate change itself succeeded.
- New interactive project multiselect: `boxa ssh on --pick` and
  `boxa ssh off --pick` open a multiselect over known projects (reuse
  the picker style of `_boxa::forge_project_picker`) and apply the
  gate to every selected project, printing the same per-project
  result lines and container-recreation hints as the single-target
  form. `--pick` conflicts with a positional target and with
  `--global` (usage error).
- Audit other reachable paths into `_boxa::ssh_add_keys` from the
  non-legacy world (e.g. lib/ssh.sh ~1076) and give them the same
  treatment; the legacy picker may remain only in explicitly legacy
  flows (migration).
- `boxa ssh off` and `boxa ssh` (status) unchanged.
- UI strings EN.

## Acceptance criteria

- [x] `boxa ssh on` with no assigned persona launches the persona
      assignment flow with the project preselected; cancel leaves the
      gate on with a note. A keyless persona prints the
      persona-oriented guidance. No key picker anywhere.
- [x] `boxa ssh on --pick` / `off --pick` multiselect known projects
      and apply the gate per selection with per-project output;
      usage errors on --pick combined with a target or --global.
- [x] `boxa ssh on` with a persona that has keys still reapplies them
      into the running agent as today.
- [x] Legacy picker unreachable outside explicitly legacy flows.
- [x] shellcheck clean (incl. info); real pty coverage for the
      keyless-persona and no-persona `ssh on` paths.

## Blocked by

33 (touches the same registry/reconcile area; land after it).

## Comments
