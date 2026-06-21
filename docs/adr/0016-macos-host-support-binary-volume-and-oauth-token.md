# ADR 0016 — macOS host support: shared binary volume + OAuth-token auth

- **Status:** accepted
- **Date:** 2026-06-13
- **Revises:** ADR 0002 (shared Claude config via bind mount) — for the macOS
  host case only. ADR 0002 is **not** superseded; its bind-mount model still
  governs Linux/WSL2 and most of `~/.claude` on macOS too.

## Context

ADR 0002 settled how a boxa container shares Claude Code with the host: a
direct RW bind mount of host `~/.claude`, so OAuth credentials, settings,
sessions, skills, and plugins are one set of files seen live by host and every
container. A sibling refactor (`1f1adeb`) did the same for the Claude binary,
bind-mounting host `~/.local/share/claude` read-only so every container tracks
the host's installed version. Both decisions assume host and container share
the same OS/ABI — true on Linux and WSL2 (the container runs a Linux ELF and
the host artefacts are Linux too).

The maintainer moved to a **macOS host**, which breaks both assumptions:

**The host Claude binary is Mach-O.** macOS installs Claude Code as a native
Mach-O build under `~/.local/share/claude/versions/`. Bind-mounting that into
the Linux container shadows the container's own Linux ELF, so every `claude`
invocation inside the container dies with `exec format error`. The
host-version-tracking benefit from `1f1adeb` is worthless across an OS/arch
boundary.

**macOS does not keep credentials in a file.** The macOS Claude app stores
OAuth credentials in the **Keychain**, not in `~/.claude/.credentials.json`.
Worse, it actively **deletes** `~/.claude/.credentials.json` on `/login`
(anthropics/claude-code#10039). So the single-shared-file premise that ADR 0002
rests on — "one `.credentials.json`, refreshed in place, seen by all" — cannot
hold on macOS: there is no durable host file to bind-mount, and any file a
container writes can be removed out from under it by a host-side login. There
is no supported file-based credential override (no `CLAUDE_CREDENTIALS_PATH`;
only `CLAUDE_CONFIG_DIR` relocates the whole config dir), so we cannot redirect
the container to a private credential file either.

ADR 0002 had explicitly rejected `setup-token` / `CLAUDE_CODE_OAUTH_TOKEN` as a
substitute, on the belief that it "lacks Max plan privileges (no 1M, downgraded
models)". That claim was re-tested this session and found **wrong for
interactive use**: a token minted by `claude setup-token` was empirically
verified to give full **1M Opus** context in an interactive container session.
The original rejection no longer applies on the host where it is the only
option.

This work also lands alongside two already-shipped macOS fixes of the same
lineage (host-side compatibility for running boxa from a Mac):

- **bash 4+ re-exec guard** (`9df19b2`) — macOS ships bash 3.2, which lacks
  `mapfile` / `declare -A`; `docker-run.sh` re-execs under a bash 4+ found on
  `PATH`.
- **`setup-claude.sh` silent-`find` fix** (`50a82dd`) — skips the
  migration-notice `find` when the relevant `~/.claude` dirs are absent, so it
  no longer emits errors on a fresh Mac.

## Decision

Branch both the binary mount and the auth-token injection on the **host OS**
(`uname -s` = `Darwin`), in `docker-run.sh`. Linux/WSL2 behaviour is unchanged.

### Binary — shared named volume on macOS

On macOS, do **not** bind-mount host `~/.local/share/claude`. Instead mount a
single per-host shared named volume **`boxa-mac-claude-bin`** at
`/home/node/.local/share/claude` (RW):

```sh
if [ "$(uname -s 2>/dev/null || echo Unknown)" = "Darwin" ]; then
    DOCKER_ARGS+=(-v boxa-mac-claude-bin:/home/node/.local/share/claude)
else
    [ -d "$HOME/.local/share/claude" ] && DOCKER_ARGS+=(-v "$HOME/.local/share/claude:/home/node/.local/share/claude:ro")
fi
```

- A **fresh** `boxa-mac-claude-bin` volume auto-populates from the
  image-baked Linux binary on first use (Docker seeds an empty named volume
  from the image content at the mount path), so a clean `boxa build` + start
  yields a working `claude` with no manual binary workaround.
- The volume is **shared across all containers** (single name, not
  per-project — same pattern as `boxa-npm-global`). Running `claude update`
  inside any one container writes the new version into the volume; other
  containers pick it up on their next start. There is no host-side update path
  on macOS — the host's own Claude (Mach-O) is a separate install.

`repair_claude_bin` in `setup-claude.sh` needs **no logic change**: it relinks
`~/.local/bin/claude` to the highest version under
`~/.local/share/claude/versions/` regardless of whether that directory is the
RO host bind mount (Linux/WSL2) or the `boxa-mac-claude-bin` named volume
(macOS) — either way it holds Linux binaries. Only its comment was updated.

### Auth — OAuth token is primary on macOS

`~/.claude` stays a **full RW bind mount** on macOS exactly as on Linux, so
settings, sessions, skills, and plugins remain shared and editable from the
container. No overlay, symlink, or per-container credential file is introduced.
The only change is **where credentials come from**: a long-lived
`CLAUDE_CODE_OAUTH_TOKEN`, passed by `-e`.

The token is read from `~/.config/boxa/claude-token` (0600) when not already
in the environment, then injected with an OS-dependent rule:

```sh
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    if [ "$(uname -s 2>/dev/null || echo Unknown)" = "Darwin" ] || [ ! -f "$HOME/.claude/.credentials.json" ]; then
        DOCKER_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN")
    fi
fi
```

- **macOS** — the token is the **primary, always** auth path. It is injected
  whenever it exists, **regardless** of any stray `.credentials.json` (an
  accidental in-container `/login`, or a leftover the host app would delete
  anyway). Live host↔container credential sharing is impossible here, so the
  token is the only thing authenticating the container fleet.
- **Linux/WSL2** — the token stays a **fallback only**, injected solely when no
  host `.credentials.json` exists. The shared host file (ADR 0002) still wins.

When macOS has no token configured (none in env, no file), both
`install.sh` and the container-start path emit a **non-fatal** hint pointing at
`boxa claude-token`, because on macOS a missing token means the whole
container fleet has no auth (the host login is never shared in).

This is the part that **revises ADR 0002**: `CLAUDE_CODE_OAUTH_TOKEN` is no
longer rejected as a downgraded auth mode — on macOS it is the auth mode, and it
delivers full 1M Opus for interactive use as verified above.

## Consequences

**Positive:**

- boxa runs on a macOS host: the container has a working Linux `claude` and a
  Max-plan-class interactive session (1M Opus), without the host's Mach-O
  binary or Keychain creds leaking in to break either.
- The fix is narrow and OS-gated. Linux/WSL2 is byte-for-byte unchanged: same
  RO binary bind mount, same token-as-fallback rule.
- `~/.claude` stays a full bind mount on macOS too, so settings / sessions /
  skills / plugins are still shared and editable from the container — only the
  credential source differs. No overlay/symlink scheme to maintain.

**Negative / limitations:**

- **Yearly token regeneration.** `claude setup-token` mints a long-lived token
  that expires roughly annually; the user re-runs `boxa claude-token` when it
  lapses. (On Linux/WSL2 the bind-mounted credentials refresh themselves, so
  this chore is macOS-specific.)
- **Host and container are independent sessions, not shared creds.** The host's
  native Claude keeps its own Keychain login; the container fleet authenticates
  with the token. They do not share a single rotating credential the way ADR
  0002 arranged on Linux — a `/login` on one side does not re-authenticate the
  other.
- **Binary updates are container-driven on macOS.** There is no host artefact
  to track; the shared `boxa-mac-claude-bin` volume is advanced only by
  running `claude update` inside a container.
- macOS host support is code-verified but still needs end-to-end confirmation
  on a Mac runtime (see issues under `.scratch/macos-support/`).

## References

- `docker-run.sh` — the `uname -s` = `Darwin` binary-mount branch
  (`boxa-mac-claude-bin`) and the OS-gated `CLAUDE_CODE_OAUTH_TOKEN`
  injection + macOS first-run hint.
- `install.sh` — `setup_claude_token`'s macOS branch (skips the file path,
  points at `boxa claude-token`).
- `scripts/setup-claude.sh` — `repair_claude_bin` (OS-agnostic relink; comment
  only).
- ADR 0002 — shared Claude config via bind mount (revised here for macOS, not
  superseded).
- `1f1adeb` — the sibling refactor that bind-mounted host claude binaries,
  whose assumption this ADR breaks on macOS.
- `9df19b2` — bash 4+ re-exec guard (macOS bash 3.2 lacks `mapfile` /
  `declare -A`).
- `50a82dd` — `setup-claude.sh` silent-`find` fix on missing `~/.claude` dirs.
- anthropics/claude-code#10039 — macOS app deletes
  `~/.claude/.credentials.json` on `/login`.
