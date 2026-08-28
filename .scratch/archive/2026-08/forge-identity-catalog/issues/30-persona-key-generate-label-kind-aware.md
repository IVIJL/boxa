# 30 — "Generate a new Agent key" label is wrong for persona keys

Status: done
Type: AFK

## Parent

Live verification round 3, 2026-08-26; follow-up to issue 27 (the
"Agent key" wording is reserved for Boxa's generated agent-identity
key).

## What happened (live repro)

Managing keys of a kind=mine persona, the menu offered "Generate a new
Agent key" (`_boxa::forge_keys`, lib/forge.sh ~3172). The user found
this confusing: "Agent key" reads as Boxa's agent-identity key, but
`_boxa::forge_generate_persona_key` (~2958) actually generates a fresh
key dedicated to THIS persona (stored per identity). For a mine
persona the label is doubly wrong — it suggests attaching the machine
agent key, the exact confusion issue 27 removed from the add flow.

## What to build

Make the generate action kind-aware and stop calling persona keys
"Agent key":

- Load the persona kind in `_boxa::forge_keys` (persona is already
  loaded there) and pick the label:
  - kind=agent: "Generate a new SSH key for this agent persona"
  - mine/other: "Generate a new SSH key for this persona"
- Align related messaging on the generate path (e.g. the success line
  in `_boxa::forge_generate_persona_key`) so it says the key belongs
  to the persona, not "Agent key". Do NOT touch the genuine
  agent-identity wording elsewhere (e.g. the add-flow option renamed
  in issue 27, `_boxa::ssh_agent_key_path` docs).
- UI strings EN.

## Acceptance criteria

- [x] Key menu shows the kind-aware generate label; no "Agent key"
      wording remains on the persona key generate path.
- [x] Generated-key success message names the persona.
- [x] Agent-identity wording elsewhere (add flow, ssh gate) unchanged.
- [x] shellcheck clean (incl. info); real pty coverage for both label
      variants; existing tests matching the old label updated.

## Blocked by

(none)

## Comments
