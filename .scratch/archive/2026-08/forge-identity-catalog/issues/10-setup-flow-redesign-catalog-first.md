# 10 — Setup flow redesign: catalog-first, key-centric mental model

Status: superseded — design vygrilován 2026-08-25, závazná rozhodnutí
a pipeline v ../HANDOFF-ux-redesign.md (nová session: ADR 0034 → /to-issues)

## Parent

Live-verification feedback (2026-08-25); ADR 0032/0033. Design work —
needs a grill/decision with Miloš before implementation.

## Problem (user's words, condensed)

The flow asks "configure GitHub or GitLab?" before showing what already
exists. There is ONE Agent SSH key used for GitHub, GitLab and any SSH
server, so a per-forge entry question is confusing. Expected flow per
the user: show the catalog (keys/identities) first → multiselect where
to use them (forges/projects) → then prepare gh/glab CLI in the box
(token side), with the SSH-agent side explained as already covering
ssh login/push/pull.

## Direction to evaluate

- `forge setup` opens with a status screen: Agent key fingerprint, what
  it authenticates as per forge (SSH probes), existing catalog
  identities, existing assignments — then offers actions from there.
- Frame the forge question as "which ACCOUNT (token) to set up", never
  as "which key" — the key is installation-global by design (ADR 0032).
- Consider merging the per-forge checklists behind one entry that
  handles both forges in sequence with shared context.
- Keep ADR 0033 invariants: identity binds SSH side + token, no
  half-identities; assignment flow (`forge use`) already does
  identity picker → multi-project picker and may be the pattern to
  surface here.

## Acceptance criteria

- [ ] Design agreed with Miloš (grill), captured as ADR amendment.
- [ ] Implemented per agreed design with pty coverage.
