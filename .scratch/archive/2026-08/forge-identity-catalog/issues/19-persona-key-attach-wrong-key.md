# 19 — P1: persona key attach stores the agent-identity key instead of the chosen host keys

Status: done

## Parent

Live verification 2026-08-26 of ADR 0034 (issues 15/16 flows).

## What happened (live repro)

During "add a persona" the user chose to attach existing SSH keys from
`~/.ssh` (host has `id_rsa` and `id_rsa_gitlab`). The resulting persona
file contains neither; instead it holds boxa's own per-installation
agent identity key:

    key=/home/vlcak/.config/boxa/agent-identity/id_ed25519

That key then got forwarded into the project agent on container start.
The user's two chosen keys were never attached at all.

## What to build

Diagnose first (real pty repro, no stubs on the consent/prompt seams),
then fix: adopt-existing must register exactly the keys the user picked
(paths under `~/.ssh`, private material never read or copied), and the
agent-identity key must be attached only when the user explicitly picks
generate-new/agent-key, never as a silent default or fallback.

Related: the two long-standing pty timeouts cover exactly these flows
(`test_adopt_existing_registers_path_without_touching_private_key`,
`test_generate_new_configures_agent_usage_with_real_picker`). Stop
excusing them as pre-existing noise: investigate them as part of this
issue — they may be hangs/failures of the same broken flow. They must
finish and pass.

## Acceptance criteria

- [x] Adopt-existing attaches exactly the user-picked `~/.ssh` keys
      (path references, private key files untouched).
- [x] The agent-identity key is attached only on explicit choice.
- [x] Both pty tests above run to completion and pass (no timeout).
- [x] shellcheck clean (incl. info).

## Blocked by

(none)

## Comments
