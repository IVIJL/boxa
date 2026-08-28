# 11 — Agent key, dedicated agent, gate state `agent`

Status: done

## Parent

[PRD](../PRD.md) F1+F2 core; ADR 0032 decisions 1–2.

## What to build

The spine of the agent identity: boxa can generate the per-installation
Agent key (ed25519, `~/.config/boxa/`, 0600, no passphrase, comment
`boxa-agent@<hostname>`), run a dedicated boxa-owned ssh-agent for it
(lazily spawned `ssh-agent -a` at a fixed socket path inside a
boxa-owned directory, env-file + liveness resurrection following the
existing user-agent pattern, key loaded on demand; no systemd), and
forward it into containers. The SSH gate config gains a third value:
`off | agent | user`, where the legacy value `on` parses as `user`
(strict parser and byte-preserving writer keep their guarantees).
Container creation picks the socket by gate state: `user` mounts the
host agent as today, `agent` mounts the dedicated agent's socket
**directory** (socket re-creation changes inodes) and exposes the
socket as `SSH_AUTH_SOCK`. `boxa ssh` status renders the three states
and, in `agent` state, the Agent key fingerprint (or "no key yet").

## Acceptance criteria

- [x] `agent` state end-to-end: with the gate set to `agent` for a
      project, a created container's `ssh-add -l` lists exactly the
      Agent key and nothing else.
- [x] Legacy `on` in existing `ssh.conf` behaves as `user`; invalid
      values still fall back to `off`.
- [x] Agent survives socket-directory persistence and is resurrected
      after being killed (liveness check), per the existing pattern.
- [x] Key generation is idempotent and never overwrites an existing key.
- [x] Tests extend `tests/ssh.sh` patterns: conf roundtrip for all three
      values, byte-preservation, mount decision, fingerprint rendering.
- [x] shellcheck clean (including info-level).

## Blocked by

None - can start immediately.

## Comments
