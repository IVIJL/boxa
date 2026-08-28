# 15 — Persona registration without the posture picker

Status: done

## Parent

ADR 0034 decisions 5–6; supersedes the ADR 0032 posture checklists.

## What to build

`forge add` registers a persona: choose a name, answer the single kind
label question ("whose account is this?"), then per forge the persona
should cover: paste a token (verified via `gh api user` / `glab api
user`, expected-username check kept) and optionally attach SSH keys
(verified via `ssh -T`). PAT-only is implicit — a persona with no
attached key simply has no SSH side; no posture menu anywhere. The
transport story is narrated, not asked: SSH key = git transport, token
= API/CLI (mandatory alongside a key). Guidance for creating a machine
user / service account survives as inline help within the flow, not as
a branching checklist. ADR 0031 consent-first import remains the path
for adopting host gh/glab tokens; ADR 0033 multi-machine "attach this
machine's key to an existing account" stays offered.

## Acceptance criteria

- [x] One add flow covers mine/agent/other; the only kind-specific
      artifact is the label.
- [x] Token-only, key-only-rejected (token mandatory), and token+key
      registrations all round-trip and verify.
- [x] No posture picker remains anywhere in the codebase.
- [x] Every picker screen carries its question in the fzf header
      (issue 09 convention).
- [x] shellcheck clean (incl. info); pty coverage.

## Blocked by

- 12-persona-storage-and-migration.md

## Comments
