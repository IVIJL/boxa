# 23 — Messaging: "Project agent" naming and assignment consequences

Status: done

## Parent

Live verification 2026-08-26; ADR 0034 decisions 2 and 6.

## What happened (live repro)

`SSH: gate on; Project agent running (keys: SHA256:…)` was read as
"the agent persona is running" — the user believed a foreign persona's
key appeared in their project. "Agent" collides between the ssh-agent
process and the agent-kind persona. Separately, the assignment message
does not make it clear that assigning a persona forwards its SSH keys
into the project when the gate is on.

## What to build

Rename user-facing mentions of the per-project ssh-agent so they can't
be read as a persona: e.g. `per-project ssh-agent running (persona
'vlcak' keys: SHA256:…)` — naming the owning persona next to the
fingerprints removes the ambiguity. Extend the assignment confirmation
to state the consequence explicitly, e.g. `Persona 'vlcak' assigned to
…; its SSH keys will be forwarded into this project's ssh-agent (gate
on).` Sweep other messages using bare "agent" for the process. UI
strings EN.

## Acceptance criteria

- [x] No user-facing string can read the ssh-agent process as a
      persona; the owning persona is named where keys are listed.
- [x] Assignment output states that the persona's keys will be
      forwarded (when gate on) / not (when off).
- [x] shellcheck clean (incl. info); test coverage for the new
      strings.

## Blocked by

(none)

## Comments
