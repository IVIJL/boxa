# 08 — Import wizard project targets: name-collision purge hides real projects, path-blind proof admits non-projects

Status: done

## Parent

Live-test finding (#mcp-host-resync, d75eb07): the wizard's project
picker offered `/home/vlcak` (not a project) and did NOT offer
`easyjukebox_api` (a real initialized project). Predates the
multi-select change — d75eb07 only changed picker mode, not contents.

## Root cause (confirmed)

`enumerate_project_targets` (`scripts/mcp/projects.py:202-261`) builds
targets from Claude project-record keys grouped by SANITIZED BASENAME,
drops any name with >1 key as a collision (`projects.py:247-253`), and
admits the rest if a `boxa-<name>-history` volume exists
(`projects.py:256`) — a name-only, path-blind proof.

Two systemic failures on a real host config (55 records, 24/30 names
colliding):

1. Every project ever opened inside a boxa Container has a
   `/workspace/<name>` twin record in the shared `~/.claude` config.
   `/home/vlcak/Projekty/easyjukebox_api` + `/workspace/easyjukebox-api`
   → same sanitized name → collision → the REAL project is dropped.
   The collision note goes to stderr right before fzf takes over the
   terminal and repaints it, so the user never sees why.
2. `/home/vlcak` is a legitimate Claude record (created by running
   claude in $HOME); basename `vlcak` matches the existing
   `boxa-vlcak-history` volume by name, so a home directory is offered
   as a project.

## What to build

Make the import wizard's target enumeration path-based, consistent
with the activation picker's source of truth:

- A target = a project present in the boxa project registry
  (`~/.config/boxa/projects.json`, the same registry
  `_cmd_activation_project_targets` / `scripts/mcp/cli.py:3354-3395`
  already uses) whose exact host path ALSO has a Claude project
  record. Match records by exact path, not by sanitized basename.
- Container-side `/workspace/<name>` records therefore stop mattering
  (no registry entry with that path) — no collision purge needed for
  them. Keep a collision/ambiguity guard only where two REGISTRY paths
  genuinely map to the same display name; such cases show both with
  disambiguating paths instead of being dropped.
- `/home/vlcak`-style records disappear automatically (not in the
  registry) — the history-volume name heuristic is no longer the
  admission test. Keep any volume check only if the registry alone is
  insufficient; do not reintroduce name-based matching.
- Surface enumeration diagnostics where the user can see them: any
  dropped/ambiguous candidates go into the picker header (or are
  printed via /dev/tty before the numbered fallback), not to stderr
  that fzf immediately paints over.
- `project-targets-json` reflects the same enumeration (used by
  tests/tools); non-interactive selectors and the activation picker
  are untouched.

## Acceptance criteria

- [x] Enumeration test with a Claude config containing: a real host
      project (registry + Claude record), its `/workspace/<name>`
      twin, and a `$HOME` record with a name-matching history volume →
      targets contain exactly the real project; the twin causes no
      collision; `$HOME` is absent (mirrors the live host shape:
      easyjukebox_api offered, /home/vlcak not).
- [x] Two genuinely distinct registry projects with the same display
      name are both offered, disambiguated by path (test).
- [x] Wizard picker (fzf and numbered fallback) shows the same target
      set; diagnostics visible in header/fallback output, nothing
      lost to pre-fzf stderr (picker test).
- [x] Activation picker behavior unchanged (existing tests green).
- [x] Tests green (`python3 -m unittest discover -s tests -q`),
      `tests/picker.sh` green, shellcheck clean incl. info-level.

## Blocked by

None. Independent of 07.

## Comments

- 2026-08-21: Filed from live run 2. The "known to Claude AND has a
  history volume" heuristic (issue 11 of the parent feature) does not
  survive real configs where every project has a container-side twin
  record.
