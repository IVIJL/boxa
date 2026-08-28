# 05 — SSH gate write-through + divergence warning

Status: done

## Parent

ADR 0033, Decision 2, 3; ADR 0026 (SSH gate), ADR 0032.

## What to build

Assigning an identity to a project also writes that project's SSH gate:
kind `mine` → `user`, kinds `agent`/`other` → `agent`. The `user`-mode
Key-picker consent flow stays exactly as is (write-through selects the
mode, never loads keys silently). `boxa ssh` remains a manual override;
when the SSH gate diverges from what the assigned identity implies,
`boxa ssh` and forge status print a one-line warning naming both sides.
Existing gate-change semantics (takes effect at container creation,
stop/start hint) unchanged.

## Acceptance criteria

- [x] `forge use` with an `agent`-kind identity sets the project's SSH
      gate to `agent`; with `mine` sets `user` (already done in the
      04 slice, `_boxa::forge_assign_identity`)
- [x] Manual `boxa ssh` override afterwards works and produces the
      divergence warning in both `boxa ssh` and forge status (warning
      logic extracted into shared `_boxa::forge_ssh_gate_divergence_warnings`,
      called from both `_boxa::ssh_status` and `_boxa::forge_status`)
- [x] No key material is read or loaded by the write-through itself
- [x] pty-tested where interactive; shellcheck clean incl. info-level
      (no new interactive surface in this slice — pure status output;
      shellcheck -S info clean on lib/forge.sh, lib/ssh.sh, tests/forge.sh)

## Blocked by

04-forge-use-and-default.md

## Comments
