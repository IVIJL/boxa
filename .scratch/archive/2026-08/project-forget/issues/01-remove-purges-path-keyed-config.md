# 01 — boxa remove purges the project's path-keyed config

Status: done

## Parent

None — project data removal predates the ADRs; touches state owned by
ADR 0020 (projects.json usage), ADR 0026/0032/0034 (ssh.conf, SSH key
registry, forge.conf).

## What to build

`boxa remove <project>` currently deletes only Docker volumes, Traefik
route yamls, HTTPS artifacts and agent-browser archives. The project
keeps haunting every picker and the forge dashboard because its
path-keyed state survives: the entry in `projects.json`, and the
`[/abs/path]` sections in `forge.conf`, `ssh.conf` and the SSH key
registry (all of which feed `_boxa::forge_known_project_paths`).

A second failure mode: `remove_project_data` treats "no volumes" as an
error (exit 1), and the interactive picker builds its list solely from
`list_projects_with_volumes`. A project whose Container never left
volumes behind (e.g. a temp box) but which still lives in the config
stores is therefore invisible to the picker and fails when named
explicitly — exactly the state that motivated this issue.

Extend `boxa remove` so a removed project also disappears from those
four stores, and so partial state never aborts the removal:

- Resolve the removal target to its absolute path(s) via
  `projects.json`. The target may be a project *name* or an absolute
  *path* (a `/`-prefixed argument): a path is used directly (its name
  derived via `projects.json`, falling back to the sanitized form) and
  sidesteps name ambiguity entirely. For a name with several registered
  paths, list them and ask which to purge (or purge all on explicit
  confirm); if none maps, skip config purge with a note.
- Missing stores are normal, not errors. Removal succeeds when at least
  one store actually held something for the target (volumes, route
  yamls, HTTPS artifacts, agent-browser archives, `projects.json`
  entry, forge/ssh/registry sections). Print per-store notes for what
  was found vs. absent. Exit non-zero only when the target matches
  nothing anywhere ("nothing to remove for <target>").
- The interactive picker offers the union of: projects with volumes,
  projects registered in `projects.json`, and `[/abs/path]` sections in
  `forge.conf`/`ssh.conf`/SSH key registry that have no registry entry
  (shown by path). Config-only leftovers are thus selectable.
- Delete the project's entry from `projects.json` and its sections from
  `forge.conf`, `ssh.conf` and the SSH key registry, using the existing
  strict rewrite helpers (never sourcing, unrelated bytes preserved,
  registry/catalog locks held).
- Reconcile a live per-project ssh-agent for the purged path (drop keys,
  same as the forge kill-switch path) so nothing stays forwarded for a
  project that no longer exists.
- The interactive "* Remove all" flow purges config for every removed
  project the same way.
- Real-world motivator: a temp dir opened once by an agent in a box
  (`/tmp/boxa-leak-control.*`) stayed in all pickers forever with a
  persona assigned.

## Acceptance criteria

- [x] After `boxa remove <name>`, the project's path appears in none of:
      `projects.json`, `forge.conf` sections, `ssh.conf` sections, SSH
      key registry sections.
- [x] `boxa forge` dashboard and the ssh/forge pickers no longer list
      the removed project.
- [x] Ambiguous name→path mapping prompts instead of guessing; missing
      mapping skips the purge with a printed note and still removes
      volumes.
- [x] `boxa remove` on a project with config entries but no volumes
      succeeds, purges the config, and reports the absent volumes as a
      note — never "No volumes … exit 1".
- [x] `boxa remove /abs/path` works as a target and purges that path's
      config plus the mapped name's volumes/routes/HTTPS/archives.
- [x] The interactive picker lists config-only projects (no volumes)
      alongside volume-backed ones; "* Remove all" covers both.
- [x] Exit non-zero only when the target exists in no store at all.
- [x] Unrelated sections in every rewritten file survive byte-for-byte
      (existing rewrite-helper guarantees hold).
- [x] A running per-project agent for the purged path ends up empty.
- [x] Existing remove behaviour (volumes, routes, HTTPS, agent-browser
      archives, legacy volume names) is unchanged.
- [x] Tests cover the purge in the style of the existing bash suites
      (tests for remove + forge/ssh conf rewrites).

## Blocked by

None — can start immediately.

## Comments
