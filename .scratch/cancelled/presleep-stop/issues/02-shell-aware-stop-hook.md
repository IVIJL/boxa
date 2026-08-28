# 02 — Shell-aware Stop hook: keep the awake lease while background shells run

Status: done

## Parent

None — extends the agent activity hook shipped with the keep-awake
feature (docs/keep-awake.md, "activity hook").

## What to build

Today the Claude Stop hook (`agent-awake.sh idle`) releases the awake
lease immediately when the agent's turn ends. If the agent left a
background Bash task running (Claude Code `run_in_background`), the
machine can idle-sleep — and with this feature, pre-sleep stop would
kill the box — while the script is still working. Verified live: a
running background task exists as a **child process of the `claude`
process**, spawned via `zsh -c 'source ~/.claude/shell-snapshots/
snapshot-zsh-….sh …'`; the `shell-snapshots/snapshot-` argument
signature is a reliable marker, and the process disappears when the
task finishes.

Change the Stop action in `agent-awake.sh`: before signalling, walk up
the process tree to the owning `claude` ancestor and count its live
shell-snapshot children (excluding the hook's own process chain). If
any exist, send `busy` (normal TTL) instead of `idle`; otherwise send
`idle` as today. When the background task later completes and the
agent is re-invoked, the next Stop re-evaluates — the chain closes
itself. The detection must be cheap (a `ps`/`/proc` walk, no polling
loop), silent on failure (fall back to today's `idle` if the tree
cannot be read), and must work both inside a Container and on a plain
host — the hook runs on whatever machine `claude` runs on.

## Acceptance criteria

- [x] Stop with a live background shell-snapshot child sends `busy`
      and the daemon keeps the lease (verifiable via `/v1/status`).
- [x] Stop with no background shells sends `idle` exactly as before.
- [x] Detection failure (unreadable /proc, unexpected tree) degrades
      to `idle`, never blocks, never delays the hook beyond the
      existing 1s curl budget by more than ~100 ms.
- [x] Works inside a boxa Container and on the host; POSIX sh, no
      bashisms; shellcheck clean.
- [x] Tests cover: bg shell present, absent, self-exclusion (the
      hook's own shell must not count as a running task).

## Comments

Implemented via a single `ps -eo pid=,ppid=,comm=,args=` snapshot walked in
awk (POSIX sh, no bashisms), gated behind `BOXA_PS_COMMAND` for test
injection, matching the existing platform-detection fixture pattern. Any
failure (missing ps, malformed tree, hook's own claude ancestor not found)
falls back to `idle`. Fixed one test hygiene issue post-delegation: the new
Stop tests needed `env -u BOXA_PROJECT_NAME` (like the pre-existing idle
test) since a boxa Container always exports `BOXA_PROJECT_NAME`, which was
leaking into the "default session" assertions.

## Blocked by

None — can start immediately.
