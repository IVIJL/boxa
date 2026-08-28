# 11 — Binary SSH gate with per-project agents

Status: done

## Parent

ADR 0034 decisions 7 (gate off/on, project agents); supersedes the
ADR 0032 three-state gate.

## What to build

Collapse the SSH gate to `off`/`on`. `on` means the project gets a
**dedicated per-project ssh-agent** on the host: lazily spawned and
resurrected via the existing env-file + liveness pattern, its own
socket whose directory is bind-mounted into the container at creation
(inode rationale of ADR 0032). Which keys the agent holds comes from
the project's assignment (write-through lands in issue 14; until then
the agent may hold the keys the legacy mode implies).

Legacy `ssh.conf` mode values migrate on first read: `agent` → `on`
with the Agent key, `user` → `on` with the user's previously picked
keys. New conf grammar fails closed on old parsers (accepted one-way
upgrade). `boxa ssh` status reports the binary gate, the project
agent's liveness, and its key fingerprints. Container startup line
follows suit.

The global boxa agent of ADR 0032 stops being the forwarding source;
projects each forward their own agent.

## Acceptance criteria

- [x] Gate resolves per project to off/on; legacy `agent`/`user` values
      map as above with a visible migration note.
- [x] A project with gate on gets its own agent + socket dir mount;
      two projects never share a socket.
- [x] Restarting one project's agent does not disturb another's.
- [x] Status and container startup line show gate state, agent
      liveness, and key fingerprints.
- [x] shellcheck clean (incl. info); pty tests via real
      `python3 -m unittest`.

## Verification (2026-08-25)

Implemented via Codex (MCP session; the MCP tool call itself hit the
30-min idle timeout with no final report/threadId returned, but the
working tree already had the complete diff). Verified directly by the
orchestrator rather than by relaying a Codex report:
- `shellcheck -S style` clean on every changed .sh file.
- `bash tests/ssh.sh`, `tests/forge.sh`, `tests/test_ensure_ssh_gate.sh`,
  `tests/test_ensure_agent_identity.sh` all green.
- `python3 -m unittest tests.test_ssh_gate_pty tests.test_forge_checklist_pty
  tests.test_agent_identity_pty` all green (new pty suite
  `tests/test_ssh_gate_pty.py` covers the legacy-user re-picker path
  through a real pty).
- Reviewed lib/ssh.sh, docker-run.sh, lib/forge.sh diffs directly:
  fail-closed grammar uses a new `gate=` key (old parsers only recognize
  `agent=` and skip it, landing on the secure off default); per-project
  agent identity is a sha256-derived dir with an owner-file guard against
  hash-truncation collisions; Agent key material/storage stays global and
  unchanged, only the per-project agent process/socket is new.

No threadId was captured (MCP session never returned one before the
idle-timeout abort), so there is no Codex thread to resume/reference.

## Blocked by

None — can start immediately.

## Comments
