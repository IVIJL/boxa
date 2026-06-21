# ADR 0002 — Share Claude Code config via host bind mount instead of per-container volume

- **Status:** accepted
- **Date:** 2026-05-03
- **Supersedes:** the architecture captured in `d364a16` ("shared Claude volume with per-project workspace paths for 1M context")

## Context

Boxa containers and the host both run Claude Code under the same Anthropic
Max plan. To get 1M context and avoid daily re-logins, every instance must
share OAuth credentials. The previous architecture (`d364a16`, 2026-04-04) did
this by:

1. Mounting a shared named volume `boxa-claude` at `/home/node/.claude` per
   container (per-container state, but shared OAuth credentials volume — same
   volume name across all projects).
2. Bind-mounting the host's `~/.claude` separately at `/home/node/.claude-host`.
3. `setup-claude.sh` creating a symlink from the container's
   `.claude/.credentials.json` → `.claude-host/.credentials.json` at every start.
4. Relying on Claude Code's `.credentials.lock` for cross-instance refresh
   coordination.

This worked under happy-path reads. It broke under a class of failures we hit
repeatedly:

**Atomic rename detaches the symlink.** Claude Code refreshes OAuth tokens
via the canonical `write tmp + rename(2)` pattern. `rename(2)` operates on
the directory entry, not the file content — it replaces the symlink with a
brand-new regular file in the container's per-container volume. The host file
stays untouched. From that moment, host and container hold divergent
credentials. Anthropic invalidates the previous refresh token whenever a new
one is issued, so within minutes both sides 401.

**`ln -sf` at next container start makes it worse.** Even if the container
held the only valid refreshed creds, `setup-claude.sh`'s `ln -sf` blindly
replaces the regular file with a symlink to the (stale) host file. Recovery
requires manual `/login` on host **and** manual symlink restoration in every
running container — a state the user hit on every rebuild.

**No env var rescue exists.** Per Anthropic's official auth docs, only
`CLAUDE_CONFIG_DIR` overrides the credentials path; no separate
`CLAUDE_CREDENTIALS_PATH` exists. File-level Docker bind mounts have the same
problem (rename detaches the bind mount). `setup-token` /
`CLAUDE_CODE_OAUTH_TOKEN` lacks Max plan privileges (no 1M, downgraded
models), so it is not a substitute.

The alternatives we considered:

- **A — Merge-aware `setup-claude.sh` + SessionStart hook.** Detect "container
  has newer creds than host" before relinking, propagate, then symlink. Plus
  a hook to re-establish symlink on session start. Pragmatic but only fixes
  the rebuild boundary; mid-session refreshes (every ~1h per instance) still
  desync.
- **C — Hybrid: bind-mount host `~/.claude` + per-container overlays for
  state subdirs** (`sessions/`, `history.jsonl`, `file-history/`). Cleaner
  isolation, but every new path Claude starts writing to could break it; the
  overlay set must be maintained as Claude Code evolves.
- **D — `apiKeyHelper` script** returning a token from a custom broker.
  Process-based, no file races. Rejected: returns an API key, not an OAuth
  token, and would not preserve Max plan entitlements.

## Decision

Bind-mount host `~/.claude` directly to `/home/node/.claude` (RW). Drop the
`boxa-claude` named volume and the `.claude-host` sidecar mount. Eliminate
all symlink and copy logic for credentials and shared state from
`setup-claude.sh`.

Per-project session and history isolation continues to be enforced by the
unique workspace mount path (`/workspace/<projectname>`), which gives each
project a distinct CWD and therefore a distinct entry under
`.claude/projects/<encoded-cwd>/`. Host's CWD for the same project lives at
its real path on the host (e.g. `~/Projekty/boxa`), so host and container
hold separate per-project entries even though the parent dir is shared. This
is intentional: cross-environment session merging is not desired.

`setup-claude.sh` still seeds boxa-specific defaults (`settings.json`,
`statusline-info.sh`, `hooks/`) from `/etc/claude-defaults/`, but only when
the host file is missing — so existing host configs are never overwritten,
and a fresh-install user (no prior `~/.claude/` on host) still gets working
notification hooks and statusline.

`CLAUDE_CONFIG_DIR=/home/node/.claude` remains set explicitly for clarity,
even though it now matches Claude's default search path under the bind mount.

## Consequences

**Positive:**

- OAuth refresh from any instance is immediately visible to every other
  instance. No stale refresh token, no 401 cycles, no manual symlink repair
  after rebuild. The atomic rename now happens inside the bind-mounted dir,
  and every consumer of the same file sees the new dentry on next read.
- Single backing file = no merge logic, no race conditions to defend against,
  no SessionStart hook surface to maintain.
- Operational simplification: one fewer named volume per container
  (`boxa-claude` deleted), one fewer mount (`.claude-host` retired). Auto-
  cleanup of the obsolete `boxa-claude` volume mirrors the pattern from
  `1f1adeb` for `boxa-claude-bin`.
- Skills, plugins, CLAUDE.md, settings.json now share live with host with no
  rsync step. Host-side edits propagate instantly.

**Negative:**

- `settings.json` is shared host↔container. Any container-only behavioral
  toggle (e.g. `skipDangerousModePermissionPrompt`) cannot live there
  anymore — it would also activate on host. The user accepts this:
  `--dangerously-skip-permissions` is controlled per invocation via the
  `ccdd` alias, not via settings.
- `sessions/`, `history.jsonl`, `file-history/` are shared across all
  instances. **No data corruption** (POSIX `O_APPEND` writes < `PIPE_BUF`
  are atomic, separate session files don't collide), but a UX leak: pressing
  ↑ on host may surface prompts typed inside a container, and `/resume` may
  list sessions from another instance. Acceptable; per-project isolation
  (the original concern that drove `d364a16`) is preserved by unique
  workspace paths.
- Container's `.claude.json` lives at `/home/node/.claude/.claude.json` while
  host's lives at `~/.claude.json` (one directory up — Claude Code's legacy
  location when no `CLAUDE_CONFIG_DIR` is set on host). They remain
  separate. Onboarding state and project-trust cache do not sync between
  host and container, but each side maintains its own consistent state.
- Multiple concurrent containers writing `.claude.json` use last-writer-wins.
  Claude itself maintains rolling backups under `.claude/backups/`, so a lost
  metadata update is recoverable.
- Pre-existing root-owned garbage at `~/.claude/.claude.json` (artifact from
  an old container run) must be removed before migration; otherwise the
  container (running as `node`, UID 1000) cannot write its `.claude.json`.
  One-time `sudo rm` during migration.

## Followup considerations (added 2026-05-03 after Codex review)

**Plugin paths require HOST_HOME compatibility symlink.**
Claude plugin registries (`~/.claude/plugins/installed_plugins.json`,
`known_marketplaces.json`) persist absolute paths rooted in the host home
(`/home/<host-user>/.claude/plugins/cache/...`). With the bind mount, those
paths still reference the host user's home, which doesn't exist inside the
container. The compatibility symlink `$HOST_HOME -> /home/node` is created
by the privileged entrypoint at container start (see ADR 0003 — earlier
designs placed it in `setup-claude.sh` via `sudo`, which was rejected
because `setup-claude.sh` runs without a TTY and the sudo prompt would
abort startup). Caveat: plugins installed from inside a container persist
`/home/node/...` paths which are broken on the host. Practical guidance:
install plugins on host, containers consume them.

**Project-scoped plugins do not activate inside containers.** Project-scoped
plugin entries store `projectPath: /home/<host-user>/Projekty/<X>`. The
container CWD is `/workspace/<X>`, so the literal-path comparison fails. This
is acceptable for variant B; cross-environment project plugin activation is
out of scope for this layout.

**Hard cutover with one-shot migration script.** No dual-mode in
`setup-claude.sh` — the script `scripts/migrate-to-bindmount.sh`
(invokable as `boxa migrate`) merges all pre-migration Claude volumes
(`boxa-claude` and any per-project `boxa-<name>-claude`) into host
`~/.claude/` before users rebuild. The merge is two-pass: settings, hooks,
sessions etc. use `rsync --ignore-existing` so host customisations win,
but `.credentials.json` uses `rsync -u` (newer mtime wins) — without that,
the very token refresh this ADR is fixing would be discarded if it
happened to land in the volume after the host file's mtime. To prevent
accidental data loss, `docker-run.sh` refuses to start a new container
while any matching volume still exists, instructing the user to run
`boxa migrate` first.

> **Pre-release cleanup:** this one-time migration (`migrate-to-bindmount.sh`,
> `boxa migrate`) and the start-time hard gate were removed once every install
> had completed the cutover. Fresh installs use the bind-mount layout directly;
> the design rationale is retained here as history.

**Container privilege model.** The bind-mount layout itself does not need
root inside the container, but the container does need a root setup
phase for unrelated reasons (firewall, IDE volume ownership, plus the
host-home symlink described above). That root phase moved out of
`setup-claude.sh` and into a privileged entrypoint that drops to `node`
via `runuser` before any user-mode code runs. See ADR 0003 for details.

## References

- `docker-run.sh` — mount setup (search for `CLAUDE_CONFIG_DIR`).
- `scripts/setup-claude.sh` — simplified seed-only logic.
- `1f1adeb` — sibling refactor that bind-mounted host claude binaries
  (`~/.local/share/claude`) for the same "shared host artefact" reason.
- Anthropic Claude Code authentication docs:
  <https://code.claude.com/docs/en/authentication.md>
- Atomic-rename / symlink incompatibility: POSIX `rename(2)` operates on
  directory entries, not inode contents — replacing a symlink with a regular
  file in a single atomic step. This is universal behaviour for any "careful
  writer" (editors, configs, databases), not a Claude Code quirk.
