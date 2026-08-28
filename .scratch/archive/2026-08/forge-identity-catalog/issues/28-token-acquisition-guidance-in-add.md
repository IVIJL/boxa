# 28 — Persona add: token step gives no guidance on where to get a token

Status: done
Type: AFK

## Parent

Live verification round 3, 2026-08-26; ADR 0034 decision 6 (the
dashboard/wizard explains itself).

## What happened (live repro)

Creating an agent-kind persona, the wizard asked for the mandatory
token ("Paste github token:") with no hint where to obtain one. The
guided setup path has mint-token steps with URLs
(`_boxa::forge_step` calls around lib/forge.sh:2119 and :2140, GitLab
:2233/:2255), but `_boxa::forge_add_one_locked` calls
`_boxa::forge_token_choice` (lib/forge.sh ~2465) without printing any
acquisition guidance first.

## What to build

Before the token choice in the persona add flow, print concise
kind-aware guidance (reuse or factor the existing guided-setup
strings/URLs — do not duplicate divergent copies):

- github: mint URL (classic PAT with repo scope,
  https://github.com/settings/tokens/new?scopes=repo) and, for
  kind=agent, a note that the token must belong to the separate
  automation account (signup URL) — the "Import the host CLI token"
  option only fits when the host CLI is logged in as that account.
- gitlab: the corresponding existing mint guidance for the given host.

Keep the choice itself unchanged (paste / import / etc.). UI strings
EN.

## Acceptance criteria

- [x] Persona add prints where to obtain the token (with URL) before
      the token prompt, for github and gitlab.
- [x] kind=agent guidance mentions the separate automation account and
      when host-CLI import is appropriate.
- [x] Guidance strings are shared with (or factored from) the guided
      setup path, not duplicated copies.
- [x] shellcheck clean (incl. info); real pty coverage for the new
      guidance in the add flow.

## Blocked by

(none)

## Comments
