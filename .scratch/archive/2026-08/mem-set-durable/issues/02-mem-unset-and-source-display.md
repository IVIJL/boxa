# 02 — boxa mem unset + limit source display

Status: done

## Parent

ADR 0020 — per-project memory limits. Completes the CLI config surface
started in issue 01 and improves discoverability of the config path.

## What to build

The removal side and the discoverability side of durable limits:

- `boxa mem unset [project|path]` — removes the project's `memory` and
  `memory_swap` entries from `~/.config/boxa/resources.conf`; a section
  left empty is removed entirely. `boxa mem unset --global` removes the
  global keys. Everything else in the file is preserved (shared writer
  from issue 01). Unsetting a scope that has no entry says so and exits
  cleanly.
- After a successful unset the live-convergence path applies the now-
  effective limits (global or derived fallback) to the running Container,
  with the standard notice.
- `boxa mem` diagnostics gain the resolution story: the effective
  **Memory limit** and **Memory+swap limit** each display their source —
  CLI flag / project config / global config / derived — plus a one-line
  hint that `boxa mem set` changes it durably. This is the
  discoverability fix: the diagnostics screen teaches the config surface.
- The one-shot override convergence notice recommends `boxa mem set …`
  instead of pointing at the raw config file path.

## Acceptance criteria

- [x] `mem unset` removes the scope's entries and any emptied section,
      preserves the rest of the file, and handles the no-entry case with
      a clear message
- [x] Post-unset convergence applies the fallback limits to a running
      Container with the standard notice (unit-tested; live convergence
      against a running Container is deferred host verification)
- [x] `boxa mem` shows the source of both effective limits and the
      `boxa mem set` hint
- [x] One-shot override notice recommends `boxa mem set` (no raw config
      path)
- [x] `docs/memory.md` and shell completions updated for `unset`
- [x] Unit tests cover unset round-trips (scope removal, empty-section
      cleanup, preservation, no-entry) and the source display;
      `shellcheck` clean (including info-level)

## Blocked by

`01-mem-set.md` — shares the resources.conf writer.

## Comments
- Review fix (9a0cdc0): project unset now resolves the post-removal effective memory/memory_swap pair (global -> derived) and rejects the unset when the inherited pair is invalid, naming the section and leaving resources.conf byte-identical.
- Review fix (fe25030): mem unset now computes the joint-exhaustion warning from the resulting effective limits (project unset exposing larger global, global unset exposing derived) before the convergence sweep, reusing the mem set helpers with running/stopped target semantics.
- Review fix (fe25030): mem report distinguishes a genuinely missing absolute project path from a _boxa::resolve_resources failure and surfaces the underlying resolver error (invalid configured size, unavailable host RAM).
