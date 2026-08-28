# 29 — No path to add a GitLab (or GitHub) token to an existing persona

Status: done
Type: AFK

## Parent

Live verification round 3, 2026-08-26; ADR 0034 (persona = credential
bundle covering both forges).

## What happened (live repro)

The user has a working GitHub-only persona and wants to add GitLab to
it. No interactive path exists:

- "Add a persona" rejects the existing name
  (`_boxa::forge_add_name`, lib/forge.sh ~2361: "already exists").
- "Rotate a token" (`_boxa::forge_dashboard_rotate_token`,
  lib/forge.sh ~4134) offers only forges that already have a token;
  with a GitHub-only persona it silently forces forge=github.

The persona grammar already stores both forges in one file, and
`_boxa::forge_dashboard_rotate_token_locked` (~4077) already handles
the add case end to end: it prompts for the GitLab host when unset
(~4093), probes the token, and writes the persona with both sections.
Only the outer picker blocks it.

## What to build

Extend the dashboard token action so a missing forge can be added:

- Rename the dashboard action label 'Rotate a token' to
  'Add or rotate a token' (update the menu and any pty tests that
  match menu items by index or label).
- In `_boxa::forge_dashboard_rotate_token`, always offer both forges
  for the picked persona: existing ones labeled for rotation (e.g.
  "GitHub — rotate the existing token"), missing ones labeled as add
  (e.g. "GitLab — add a token"). If the persona has no token at all,
  keep the current error.
- Before the paste prompt, print the mint guidance from issue 28
  (`_boxa::forge_token_mint_guidance`) for the selected forge/host and
  the persona's kind, so the add path explains where to get the token.
- Success message distinguishes added vs rotated (e.g. "gitlab token
  configured for persona X" vs "... rotated ...").
- No SSH key changes in this flow; keys are persona-level and
  forge-agnostic.

UI strings EN.

## Acceptance criteria

- [x] A GitHub-only persona can gain a verified GitLab token (incl.
      host prompt) from the dashboard, and vice versa.
- [x] Mint guidance for the selected forge/kind prints before the
      paste prompt in the add path.
- [x] Existing rotate behavior unchanged; personas with no token still
      error.
- [x] shellcheck clean (incl. info); real pty coverage for the add
      path and the renamed menu label; existing pty tests updated.

## Blocked by

(none)

## Comments
