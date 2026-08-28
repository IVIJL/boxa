# 27 — Persona add: kind-aware SSH key choice; Agent key mislabeled and wrongly offered for Mine

Status: done
Type: AFK

## Parent

Live verification round 2, 2026-08-26; ADR 0034 decisions 1 and 6.
Root cause of the persona `vlcak` repeatedly getting the wrong key
even after the issue 19 fix.

## What happened (live repro)

`_boxa::forge_add_ssh_choice` (lib/forge.sh ~2350) offers, for every
persona kind, in this order: "Attach this machine's Agent key"
(default, cursor on it) / "Finish without an SSH key" / "Attach
existing SSH keys". The user created a kind=Mine persona, read "this
machine's Agent key" as "my keys in my home on this machine", accepted
the default, and got Boxa's generated `agent-identity/id_ed25519`
attached instead of their `~/.ssh` keys. Twice. The kind choice has no
influence on the offer, and the label is actively misleading — the
same "agent" naming collision issue 23 fixed elsewhere.

## What to build

Make the SSH choice step kind-aware (user decision, 2026-08-26):

- **kind=mine:** never offer the Agent key. Options, in order:
  1. "Attach all host SSH keys (~/.ssh)" — default; attaches every
     discovered valid keypair from `~/.ssh` (same discovery as
     `_boxa::forge_pick_existing_persona_keys`, path references only,
     never copy key material),
  2. "Choose which host keys to attach" — runs the existing picker,
     which MUST keep its "Enter a key path manually" first option so a
     key living outside `~/.ssh` can be attached by path (user
     requirement, 2026-08-26),
  3. "Finish without an SSH key".
- **kind=agent (and other non-mine kinds):** the generated key stays
  offered but renamed so it cannot be read as the host user's keys,
  e.g. "Attach Boxa's generated agent key (agent-identity)". Keep the
  existing-keys and without options.
- Sweep any other user-facing string still calling the generated key
  "this machine's" key.

The per-key verification loop and account guidance in
`_boxa::forge_add_one_locked` must keep working for the multi-key
"all host keys" result. UI strings EN.

## Acceptance criteria

- [x] kind=mine never sees or receives the agent-identity key from
      the add flow; default path attaches all `~/.ssh` keys as path
      references.
- [x] "Choose which" runs the existing `~/.ssh` picker, including the
      manual-path option for keys outside `~/.ssh`.
- [x] Non-mine kinds get the renamed, unambiguous generated-key label.
- [x] No user-facing string calls the generated key "this machine's"
      key.
- [x] shellcheck clean (incl. info); real pty coverage for the
      kind=mine default flow (multi-key attach) and for the renamed
      label.

## Blocked by

(none)

## Comments

- Review fix (2026-08-26): kind=mine "all host keys" default no longer
  aborts persona creation when `~/.ssh` has no valid keypair — it now
  prints an English notice and falls through to registering the
  persona with its verified token and no SSH key. Real pty regression
  test added in `tests/test_forge_checklist_pty.py`. Commit c1ef7a1.
