# 02 — No-arg pickers for `mcp secret set` and a guided secret-header flow in `mcp update`

Status: done

## Parent

None — pure CLI UX layer over existing catalog/secret commands; model
and flags stay as-is (grill 2026-08-21 trimmed the original full-menu
idea as gold-plating). Complements issue 01: 01 covers host-sourced
entries, this covers hand-authored ones (`boxa mcp add --url ...`).

## What to build

- `boxa mcp secret set` with no arguments (TTY) → picker of entries
  that have a declared secret key (header or env) with no stored value
  — exactly the entries whose readiness shows "secret value missing".
  If the picked entry has multiple missing keys, pick the key too; then
  flow into the existing hidden value prompt. The prompt states the
  expected format: the full header value, typically `Bearer <token>`,
  no quotes.
- `boxa mcp update` with no entry argument (TTY) → picker over catalog
  entries; after selection, offer ONE guided action for http entries:
  "add secret (auth) header" — prompt for the header name with default
  `Authorization` (enter accepts default), declare it as a secret
  header key, then chain DIRECTLY into the hidden value prompt (same
  storage as `secret set`). One flow instead of two commands.
  All other changes (URL, rename, description, command, plain headers)
  stay flag-only — no menu.
- Every flow ends with the existing `Next:` hints (activate / reload)
  where applicable.
- Non-interactive invocations (no TTY, or `--json`) keep today's exact
  behavior and error messages — the interactive layer never triggers.

## Acceptance criteria

- [x] `boxa mcp secret set` (no args, TTY) lists only entries with
      missing secret values; entry (and key, when several) selection
      flows into the hidden prompt; readiness flips ready after.
- [x] `boxa mcp update` (no args, TTY) picks an entry and the guided
      secret-header flow declares the key and stores the value without
      the user typing any flag; `Authorization` default applies on
      plain enter.
- [x] The guided flow stores via the same host-only path as
      `secret set`; the value never appears in stdout/argv/`--json`
      (tests assert absence).
- [x] `q`/empty cancel at any step changes nothing.
- [x] No TTY / `--json` → today's exact behavior and messages.
- [x] Tests green (`python3 -m unittest discover -s tests -q`),
      `tests/picker.sh` covers the new picker paths, shellcheck clean
      incl. info-level.

## Blocked by

None — independent of 01.

## Comments

- 2026-08-21: Filed from live-testing feedback (#mcp-remote-auth): user
  did not know whether the token belongs in `update`, whether to use a
  colon or quotes, and where `Bearer` goes.
- 2026-08-21: Grill trimmed scope to the two pickers + guided secret
  flow; full per-type update menu rejected as gold-plating.
