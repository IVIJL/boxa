# 32 — Add-token failure says "the existing token is unchanged" when none exists

Status: done
Type: AFK

## Parent

Live verification round 3, 2026-08-26; follow-up to issue 29.

## What happened (live repro)

Adding a GitLab token to a GitHub-only persona, verification failed
and `_boxa::forge_dashboard_rotate_token_locked` (lib/forge.sh ~4135
error branch) printed "gitlab token verification failed; the existing
token is unchanged." — but on the add path there is no existing gitlab
token, so the copy is wrong and confusing.

## What to build

The locked function already knows whether the forge had a token
(loaded persona state). Split the failure copy:

- Rotate path (token existed): keep the current message.
- Add path (no token for that forge yet): e.g. "gitlab token
  verification failed; no token was added to persona X."

Same for github. UI strings EN.

## Acceptance criteria

- [x] Failed add prints the no-token-added copy; failed rotate keeps
      the unchanged-token copy.
- [x] shellcheck clean (incl. info); pty coverage for the add-failure
      message.

## Blocked by

(none)

## Comments
