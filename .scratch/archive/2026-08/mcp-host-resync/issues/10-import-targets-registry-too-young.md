# 10 — Import project targets collapsed to 2: registry is too young to be the sole source

Status: done

## Parent

Third live failure (#mcp-host-resync, 7e8a74f): the import wizard's
project picker now shows only 2 projects; before batch 3 it showed all
but one (plus a bogus `/home/vlcak`).

## Root cause (confirmed from code + git history)

Issue 08 made `enumerate_project_targets`
(`scripts/mcp/projects.py:201`) registry-only: a target must be in
`~/.config/boxa/projects.json` AND have an exact-path Claude record
(`projects.py:226`). But the registry write was introduced only in
374dd25 (2026-08-21, same day) and happens lazily on `boxa start`
(`docker-run.sh:3036`). On the live host the registry therefore
contains only the projects started since today's deploy (~2), and
every other real project falls into `missing_claude_records`/absent —
the picker collapsed exactly as reported. The claude-record
intersection additionally drops any registry project never opened by
host-side claude.

Timeline check: round 2 ran on d75eb07 (old volume enumeration → all
projects minus collision victims, plus `/home/vlcak`); round 3 ran on
7e8a74f (registry-only → 2). Both observations match.

## What to build

Union of two sources, replacing both bad admission tests:

1. **Registry source** (as today): entries of
   `~/.config/boxa/projects.json` whose path is an existing directory.
   DROP the exact-path Claude-record requirement (`projects.py:226-228`)
   — being a registered boxa Project is sufficient; a host-side Claude
   record proves nothing for import destinations.
2. **Legacy volume source** (covers projects not yet re-started since
   the registry landed): Claude project-record keys that are absolute
   paths, exist as directories ON THE HOST (this kills
   `/workspace/<name>` twins — no basename-collision purge needed),
   are not exactly `$HOME` (a home directory is never offered; emit a
   visible diagnostic when excluded), and whose ADR 0005 sanitized
   basename has a `boxa-<name>-history` volume.

Dedupe by path (registry wins for display name). Same-name different
paths: keep both, disambiguated by path (existing collision shape).
Diagnostics (excluded $HOME, stale registry dirs, unsafe keys) stay
visible in the picker header as built in batch 3.
`project-targets-json` reflects the same union. Activation picker
(volume-based, `enumerate_volume_project_targets`) stays untouched.

## Acceptance criteria

- [x] Live-host-shaped test: registry with 2 fresh projects + Claude
      records for 8 older host projects (with history volumes) +
      `/workspace` twins + a `$HOME` record with matching volume →
      targets = 10 real projects; no `/home/vlcak`; twins inert.
- [x] Registry project with no Claude record at all is offered
      (regression against the 08 intersection).
- [x] `$HOME` exclusion emits a visible diagnostic (header/fallback).
- [x] Activation picker behavior unchanged (existing tests green).
- [x] Tests green (`python3 -m unittest discover -s tests -q`),
      `tests/picker.sh` green, shellcheck clean incl. info-level.

## Blocked by

None. Independent of 09.

## Comments

- 2026-08-21: Filed from live run 3. Issue 08's spec error: it demanded
  the registry ∩ Claude-record intersection without checking when the
  registry gets populated. The registry becomes authoritative over
  time; until then the volume heuristic (path-verified) must back it.
