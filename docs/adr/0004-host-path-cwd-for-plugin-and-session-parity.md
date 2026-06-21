# ADR 0004 — Use host's absolute project path as container CWD

- **Status:** accepted
- **Date:** 2026-05-04
- **Builds on:** ADR 0002 (shared ~/.claude bind mount), ADR 0003 (privileged entrypoint)

## Context

After ADR 0002, OAuth credentials, skills, settings, and CLAUDE.md are shared
host↔container via direct bind mount of `~/.claude`. But two state types
remained per-CWD-keyed and therefore split between environments:

1. **Project-scoped plugins** match by `projectPath` (literal string ==
   CWD). Container CWD `/workspace/<X>` ≠ host CWD `/home/<user>/.../<X>` →
   no activation.
2. **Sessions** are stored under `.claude/sessions/<encoded-cwd>/`. Different
   CWD encodings → host and container have separate session histories per
   project, cannot `/resume` cross-environment.

The original `/workspace/<name>` mount path was chosen to follow devcontainer
convention. But Cursor/VS Code devcontainer.json supports `${localWorkspaceFolder}`
substitution, so we are not actually constrained to `/workspace/`.

Alternatives considered:

- **Per-container plugin/session overlay** — keep `/workspace/<name>`, copy
  registries to per-container volume with path rewriting. Rejected: defeats
  the point of variant B (live cross-env state) and adds maintenance surface
  as Claude evolves new state types.
- **Modify Claude Code to do realpath comparison** — out of our control.
- **Shell wrapper that translates paths** — fragile, hides reality.

## Decision

Mount the project at the host's **literal** absolute path inside the
container, and default the shell CWD to that path. Both `docker-run.sh` and
the devcontainer.json files use this layout.

For paths under the host user's home (e.g. `/home/<host-user>/Projekty/X`)
we cannot mount through a `/home/<host-user> → /home/node` symlink: the
kernel canonicalises `getcwd(2)` through `..`-walk, so a process running in
the container would see `/home/node/Projekty/X` regardless of how it `cd`'d
in. Node.js's `process.cwd()` (which Claude Code uses to key plugin/session
state) goes through `getcwd(2)`, so a symlink-mediated parent breaks the
parity Phase 2 is meant to deliver.

Instead, the entrypoint creates `$HOST_HOME` as a **real directory** whose
contents mirror `/home/node` via per-entry symlinks
(`/home/<host-user>/.claude → /home/node/.claude`, etc.). Project mounts
land as real subdirs (`/home/<host-user>/Projekty/X`) alongside that mirror,
so their canonical paths match the host. The plugin registry's absolute
paths (`/home/<host-user>/.claude/...`) still resolve via the `.claude`
symlink, satisfying ADR 0002.

`/workspace/<name>` is preserved as a symlink alias pointing at the real
project mount, so any external script or muscle memory referencing
`/workspace/X` continues to work.

## Consequences

**Positive:**

- Project-scoped plugins activate in containers identically to on host.
- `/resume` lists sessions from any environment for the same project (one
  shared history per project).
- Container CWD matches host CWD — less cognitive split, paths look the same.
- Portable across users: derived from `$HOME` at runtime, no per-user config.

**Negative:**

- `/workspace/<name>` is no longer the canonical container project path —
  it's a backwards-compat symlink. Users hardcoding `/workspace` in shell
  scripts continue to work, but new docs/scripts should reference
  `$BOXA_PROJECT_HOST_PATH` env var or the host path directly.
- Container shell prompt now shows the host path (e.g.
  `/home/user/Projekty/boxa`) instead of `/workspace/boxa`. Slight loss
  of "I'm in a container" visual cue.
- Statusline / chezmoi prompt configs that detect container by CWD prefix
  (`/workspace/*`) need a different signal (e.g. `[ -f /.dockerenv ]` or
  the `$BOXA_PROJECT_NAME` env var).
- VS Code debugger configs (`.vscode/launch.json`) use `${workspaceFolder}`
  instead of literal `/workspace` so source mapping stays portable.

## References

- `scripts/boxa-entrypoint.sh` creates `$HOST_HOME` as a real dir with
  per-entry symlinks mirroring `/home/node`.
- `docker-run.sh` mounts the project at literal `$PROJECT_PATH` and uses
  `-w "$PROJECT_PATH"` for the exec entrypoint.
- `docker-run.sh:url_encode_path` percent-encodes the host path before
  embedding it in `vscode-remote://attached-container+...` URIs (handles
  spaces and diacritics).
- `.devcontainer/devcontainer.json` and `.devcontainer/cursor/devcontainer.json`
  use `${localWorkspaceFolder}` for both `workspaceMount` and
  `workspaceFolder`. `devcontainer-standalone.json` keeps the legacy
  `/workspace` volume mount because it serves the fresh-clone workflow with
  no host bind mount.
- `scripts/setup-claude.sh` creates the `/workspace/<name>` compat symlink
  and pre-trusts both paths in `.claude.json`.
- `scripts/migrate-to-bindmount.sh --translate-keys` rewrote old
  `-workspace-<name>` session/project subdirs to host-path encoding so
  pre-Phase-2 sessions remained visible to `/resume`. *(One-time migration,
  removed after the pre-release cutover.)*
