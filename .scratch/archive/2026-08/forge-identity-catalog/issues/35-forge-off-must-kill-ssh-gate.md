# 35 — `boxa forge off` kills tokens but keeps forwarding persona SSH keys

Status: done
Type: AFK

## Parent

Live verification round 3, 2026-08-26; ADR 0033 decision 3 ("`forge off`
stays as a kill switch that does not delete assignments"), ADR 0034
synthesized SSH gate.

## What happened (live repro)

`boxa forge off easymusic` → "Forge access set to off", then
`boxa stop && boxa` recreated the container — and the start banner still
said "SSH: gate on; per-project ssh-agent running (persona 'vlcak'
keys: …)" and `ssh milohlav@…` succeeded via the forwarded agent. The
kill switch killed only tokens/env; persona SSH keys kept flowing.

Root cause: the synthesized gate (`_boxa::forge_compute_project_ssh_gate`,
lib/forge.sh ~3404) asks only "does the assigned persona have keys?" and
`_boxa::resolve_forge_identity` (lib/forge.sh ~247) ignores
`_BOXA_FORGE_GATE` entirely. On top of that, the `forge on|off` CLI
handler (docker-run.sh, MODE=forge scope block after ~4520) writes
`forge=on|off` into forge.conf but never recomputes ssh.conf or
reconciles the running per-project agent.

## What to build

The kill switch must cover the whole persona, not half of it. The
assignment itself stays untouched (ADR 0033: does not delete
assignments), so `forge on` restores everything without re-assignment.

- **Effective-gate rule:** when the effective forge gate for a project
  resolves to `off`, the synthesized SSH gate for that project is `off`
  — no persona keys are forwarded. The cleanest seam is making the
  gate computation (or `resolve_forge_identity` for gate purposes)
  respect `_BOXA_FORGE_GATE=off`; audit callers of
  `resolve_forge_identity` first — displays that show "persona X is
  assigned (forge off)" must keep working, so do not blindly hide the
  assignment everywhere.
- **`boxa forge off [project]`:** after writing `forge=off`, apply the
  gate change: write ssh.conf project gate off and reconcile the
  running per-project agent (same catalog-lock → registry-lock ordering
  as `_boxa::forge_apply_project_ssh_gate`). Keep the key registry
  content intact so `forge on` can restore symmetrically. Print the
  gate change and the existing container-recreation hint when relevant.
- **`boxa forge on [project]`:** after writing `forge=on`, recompute the
  synthesized gate from the assigned persona
  (`_boxa::forge_apply_project_ssh_gate` with change reporting) so a
  persona with keys goes back to gate on, a keyless persona stays off.
- **`--global` variants:** the same rule applies through the effective
  (project-over-global) resolution: a project with an explicit
  project-level `forge=on|off` keeps its own state; projects falling
  through to the global value follow it. Recompute/reconcile the gates
  of affected known projects (the set from
  `_boxa::forge_known_project_paths` is acceptable).
- **Container start / status paths:** the start banner and
  `boxa forge`/`boxa ssh` status must agree with the effective rule —
  no path may report or apply gate on while the effective forge gate
  is off.
- `boxa ssh on|off` stays the fine-grained manual override for the key
  side only, unchanged in shape.
- UI strings EN.

## Acceptance criteria

- [x] With a keyed persona assigned: `forge off` → recreate → banner
      shows gate off, agent not running / holds no keys, container has
      no forge tokens. `forge off` also reconciles an already-running
      agent without recreate.
- [x] `forge on` afterwards restores gate on with the same persona keys,
      no re-assignment needed.
- [x] Global on/off follows the project-over-global resolution and
      reconciles affected projects.
- [x] Status/banner never contradict the effective rule.
- [x] shellcheck clean (incl. info); shell-suite coverage for the
      off→on round trip incl. running-agent reconcile; pty coverage
      where an interactive path is touched.

## Blocked by

(none)

## Comments

- Round-trip trap to avoid: do NOT route `forge off` through the shared
  apply path in a way that replaces the project's registry entry with
  the (empty) synthesized key set — `forge on` would then restore gate
  on with no keys. `forge off` should write the ssh.conf gate and
  reconcile the agent under the same locks while leaving the registry
  rows intact, so `forge on` restores the original key set.
- Review fixes (a6a2850): `boxa ssh on <project>`/`--pick` now refuse
  (non-zero, EN message pointing to `boxa forge on <project>`) when the
  effective forge gate is off, leaving ssh.conf/agent untouched;
  `_boxa::forge_reconcile_project_ssh_gate` propagates a failed
  `ssh-add -D` per project instead of silently continuing, and the
  global variant keeps iterating remaining projects and reports which
  ones failed; `_boxa::forge_set_gate_locked` rolls forge.conf back
  (and reconciles the agent back) if applying the SSH state fails, so
  `forge on` never leaves ssh.conf "on" with a partial agent.
