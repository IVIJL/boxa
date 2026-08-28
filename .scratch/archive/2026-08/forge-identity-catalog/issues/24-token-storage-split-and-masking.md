# 24 — Tokens out of the persona file; mask tokens in any output

Status: done

## Parent

Live verification 2026-08-26; ADR 0034 decision 3 (storage).

## What happened (live repro)

`cat ~/.config/boxa/forge/identities/vlcak` printed the full GitHub
token (`github_token=gho_…`) — the persona file is the natural thing
to cat when debugging, so full tokens leak into transcripts and
screenshots.

## What to build

Move token values out of the persona file into separate 0600 files
(e.g. `~/.config/boxa/forge/tokens/<persona>.<forge>`), with the
persona file keeping metadata only (created_at, username, host) — cat
of a persona file must never reveal a secret. Bump the persona file
grammar version and migrate existing files on first write (old parsers
fail closed, same one-way rule as ADR 0034 decision 3). Additionally,
whenever boxa itself prints a token (diagnostics, doctor, errors),
print a mask (`gho_PMhq…eZn`), never the full value.

## Acceptance criteria

- [x] Persona files contain no token values; tokens live in separate
      0600 files; existing personas migrate one-way.
- [x] All boxa output paths mask tokens.
- [x] Forge CLI/API operations still work with the relocated tokens.
- [x] shellcheck clean (incl. info); test coverage incl. migration.

## Blocked by

(none)

## Comments
