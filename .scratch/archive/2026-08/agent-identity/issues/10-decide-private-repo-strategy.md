# 10 — Decide: private GitHub repos strategy (push approval?)

Status: closed
Label: wayfinder:grilling
Assignee: main-session

## Parent

[MAP](../MAP.md) — wayfinder map "Boxa agent identity".

## Question

On GitHub Free, private personal repos have **no branch protection**, and
a collaborator is always read+write — so once the machine user is invited
into a private repo, nothing forge-side keeps it off `main`. The user is
uneasy letting the agent in there without some approval step. Decide the
private-repo stance beyond the interim default from
[04](04-decide-github-model.md) ("don't invite"):

- Keep "don't invite" as the only supported stance?
- **GitHub Pro** (~4 USD/mo on the human account) enables protected
  branches on private repos — recommend as the paid path?
- A **boxa-side push gate** (host-owned approval before `git push` from a
  container reaches a private repo)? Sketch feasibility honestly: the SSH
  agent signs opaquely, so enforcement would need a different seam (e.g.
  a git push wrapper, a proxy remote, or per-repo allow list in boxa) —
  and an in-container agent can bypass in-container wrappers. What is
  actually enforceable from the host?

## Acceptance criteria

- [ ] Resolution comment records the stance and, if a boxa-side gate is
      chosen, its enforcement seam.
- [ ] Map updated.

## Blocked by

None — can start immediately ([04](04-decide-github-model.md) closed).

## Comments

**2026-08-22 — resolution (user + main session)**

Boxa is a product; users differ (some pay Pro, some don't care), so
there is **no single imposed stance — the private-repo posture is a
per-user choice**. Boxa enforces nothing forge-side; onboarding/docs
present a menu of documented options with trade-offs:

1. **Don't invite the machine user into private repos** (default
   recommendation; agent has no access there).
2. **GitHub Pro** on the human account — protected branches work on
   private repos, then inviting is as safe as on public.
3. **Read-only deploy key** for private repos the agent only needs to
   read (git-only, no API/PR; one key per repo).

Rejected: boxa-side push approval via `ssh-add -c` confirm flag — the
prompt fires on every signature (fetch included) and cannot distinguish
a push to `main` from a branch push; too coarse to be the safety story.
Noted as a possible future opt-in hardening, not part of this spec.
