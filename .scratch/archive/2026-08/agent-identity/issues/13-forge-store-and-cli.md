# 13 — Forge store, forge.conf, `boxa forge` CLI

Status: done

## Parent

[PRD](../PRD.md) F3; ADR 0032 decision 4.

## What to build

Host-side storage and CLI for forge credentials. A forge store at
`~/.config/boxa/forge/` (0600 files; per forge: token + identity
metadata — username, and host for GitLab) whose values are never
echoed and never appear in argv (hidden prompt paste, secret-store
hygiene per ADRs 0014/0031). A `forge.conf` mirroring `ssh.conf`
semantics: strict parse, per-project sections, explicit global opt-in,
fallback off, byte-preserving writer. A new `boxa forge` CLI mode:
bare = status for the cwd project (gate state, which forges are
configured, token age); `on|off [project|path] [--global]`;
`set github|gitlab` (hidden paste, then verification via `gh api user`
/ `glab api user` printing who authenticated; rotation is the same
command); `unset github|gitlab`. Gate changes warn `boxa stop && boxa`
when a running container is affected. Help text registered alongside
the other modes.

## Acceptance criteria

- [x] `boxa forge set github` stores a pasted token 0600, never echoes
      it, and reports the authenticated login via verification probe
      (probe failure keeps the token with a warning — offline-friendly).
- [x] `forge.conf` roundtrip: per-project on/off, global opt-in,
      project-overrides-global, invalid → off; byte-preservation tests.
- [x] Status output correct for: nothing configured, one forge, both,
      gate off/on/global.
- [x] Values absent from argv (test greps process invocations) and from
      any log output.
- [x] Tests follow `tests/ssh.sh` patterns; pty for interactive parts.
- [x] shellcheck clean.

## Blocked by

None - can start immediately.

## Comments
