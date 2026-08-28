# 31 — Token verification fails silently when gh/glab is missing on host

Status: done
Type: AFK

## Parent

Live verification round 3, 2026-08-26; follow-up to issue 29 (add a
missing forge token) and ADR 0034 decision 6 (the dashboard explains
itself).

## What happened (live repro)

Adding a GitLab token to an existing persona on a host without glab
installed: `_boxa::forge_probe` (lib/forge.sh ~579) starts with
`command -v glab >/dev/null 2>&1 || return 1`, so the flow printed
only the generic "gitlab token verification failed; the existing token
is unchanged." The user had no way to tell the CLI was missing (vs a
bad token or unreachable host). The github path has the same trap with
`gh`.

## What to build

Detect the missing-CLI case separately and print an actionable
message, at every interactive call site that reports probe failure
(add persona, add-or-rotate token, guided setup, key/token
verification paths — see `_boxa::forge_probe` callers ~1325, ~1696,
~1931, ~2698, ~3937, ~4135):

- Factor a small helper (e.g. `_boxa::forge_require_probe_cli <forge>`)
  that checks `command -v gh` / `command -v glab` and on failure
  prints e.g.: "Token verification needs the glab CLI on this host.
  Install it (e.g. 'sudo apt install glab' or the .deb from
  https://gitlab.com/gitlab-org/cli/-/releases) and retry." (github:
  gh, https://cli.github.com/). Then the caller aborts before the
  paste prompt where possible — do not ask the user to paste a token
  that cannot be verified.
- Prefer checking the CLI up front (before the token prompt) in the
  interactive flows; keep `_boxa::forge_probe` itself quiet for
  non-interactive callers.
- Keep the token unverifiable = not stored rule unchanged.

UI strings EN.

## Acceptance criteria

- [x] With glab absent, the gitlab add/rotate token flow explains the
      missing CLI (with install hint) before asking for the token;
      same for gh on the github path.
- [x] With the CLI present, behavior is unchanged (probe still
      verifies and reports the username).
- [x] shellcheck clean (incl. info); real pty coverage for the
      missing-CLI message (PATH manipulation in the test harness).

## Blocked by

(none)

## Comments
