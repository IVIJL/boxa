# 12 — Persona storage rebuild and catalog migration

Status: done

## Parent

ADR 0034 decisions 1–3 (persona entity, one-per-project, storage);
supersedes ADR 0033 decisions 1–3 storage shape.

## What to build

Replace the per-forge identity files with **persona** files: one
`key=value` file per persona (0600) holding the user-chosen name, kind
label, key references, and per-forge fields (GitHub token/username,
GitLab host/token/username — at most one token per forge). `forge.conf`
per-project sections collapse to a single `identity = <name> | none`
key; the global default becomes one **default persona**. Old parsers
fail closed on the new grammar.

Migration runs eagerly on the first forge command: existing per-forge
identities sharing a kind are offered as an interactive merge into one
persona (prompted name); others convert 1:1 with a prompted name.
Existing per-project per-forge assignments and per-forge defaults
convert to the single-persona form; a project whose two forge slots
pointed to identities that did NOT merge asks the user which persona
wins. `forge list` renders personas (name, kind, forges configured,
token age, key fingerprints).

## Acceptance criteria

- [x] Persona CRUD round-trips through the store; validation rejects
      duplicate names and malformed fields.
- [x] Migration converts a mixed pre-persona store (merge offer, 1:1
      conversion, assignment/default conversion, conflict prompt) —
      covered by pty tests.
- [x] `forge list` and `forge status` speak persona vocabulary.
- [x] shellcheck clean (incl. info).

## Blocked by

None — can start immediately (parallel with issue 11).

## Comments
