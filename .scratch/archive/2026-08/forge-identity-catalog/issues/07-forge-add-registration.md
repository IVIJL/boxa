# 07 — `forge add`: kind-based registration checklists

Status: done

## Parent

ADR 0033, Decision 2, 7; ADR 0032 Decision 6 (verified checklists).

## What to build

`boxa forge add` registers a new identity by running the appropriate
checklist for its kind, producing an identity file in the catalog. The
three-posture checklists that guided setup already has (own account /
machine user / PAT-only, GitHub and GitLab variants) become these
registration flows: own-account posture → kind `mine`, machine/service
account → kind `agent`, additional accounts → kind `other`; PAT-only
registers a token-only identity. The machine-user path grows a branch
for multi-machine reality: "attach this machine's Agent key to an
EXISTING machine user" (add key + mint this machine's own PAT) next to
"create a new machine user". SSH and token verification steps stay
(probe reports who the Agent key authenticates as; token probe reports
the account) and the verified username feeds the derived identity ID.

## Acceptance criteria

- [x] `forge add` walks forge → kind/posture → checklist → verified
      identity file appears in `forge list`
- [x] Existing-machine-user branch skips account creation and verifies
      the freshly attached key
- [x] Registering a second identity for the same forge coexists with
      the first (distinct IDs)
- [x] Mismatch between verified username and an entered one is surfaced
- [x] Interactive flows pty-tested; shellcheck clean incl. info-level

## Blocked by

01-identity-store-and-list.md

## Comments
