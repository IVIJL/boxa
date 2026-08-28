# 13 — keep-awake client hook in boxa-managed Claude config + status check

Status: done

## Parent

Follow-up to issues 10–12. `boxa keep-awake enable` today ships only the
transport (daemon + autostart + Host connection + tray); nothing sends
busy/idle, so without a manually wired hook the daemon never inhibits
sleep. The prototype relied on a hand-installed `agent-awake.sh` hook —
this slice makes the client side part of boxa's managed Claude config so
"enable" is genuinely one command.

## What to build

- **New managed hook `config/claude/hooks/agent-awake.sh`** (POSIX sh,
  modelled on `../reference/agent-awake-client.sh` but targeting the
  Host connection): busy = `GET
  http://127.0.0.1:17777/v1/busy/claude?ttl=900&session=<id>`, idle =
  `GET http://127.0.0.1:17777/v1/idle/claude?session=<id>`; session id
  from `BOXA_PROJECT_NAME` (fallback `default`). **Silent fast no-op
  when the daemon is unreachable** (`curl -fsS -m 1 … || true`, exit 0
  always) — the hook is present in every container and simply does
  nothing until keep-awake is enabled; no conditional install/uninstall
  at enable/disable time, idempotence for free.
- **Hook wiring in `config/claude/settings.json`**: busy heartbeat on
  `UserPromptSubmit` and `PreToolUse` (append to existing arrays, keep
  the notify hooks), idle on `Stop`. Follow the existing entry shape.
- **Existing containers**: seeding in `scripts/setup-claude.sh` only
  copies files that don't exist yet, so extend its settings-migration
  path to idempotently add the agent-awake entries (and the hook file)
  to an already-present `settings.json` without duplicating them on
  re-runs and without clobbering user customisations.
- **`boxa keep-awake status`** gains a client-signal line: hook file +
  settings entries present in the managed defaults, daemon reachable →
  "signal path OK"; otherwise say what is missing. Report-only, no
  repair.
- Docs: `docs/keep-awake.md` "Example activity hook" section becomes a
  description of the built-in hook (example stays only for third-party
  agents).

Constraints: match surrounding style; shellcheck clean incl.
info-level; hook must never block or slow the agent (max 1 s timeout,
always exit 0); no Go changes; do not touch `dotfiles/`.

## Acceptance criteria

- [x] Hook script exists in `config/claude/hooks/`, busy/idle/v1 paths
      correct, always exits 0 and stays silent when the daemon is down
      (unit-tested).
- [x] `config/claude/settings.json` wires busy on
      UserPromptSubmit/PreToolUse and idle on Stop while preserving the
      existing notify hooks (validated in tests).
- [x] Settings migration adds the entries + hook file to a pre-existing
      container config idempotently — running it twice yields no
      duplicates (mock-tested).
- [x] `boxa keep-awake status` reports the client-signal state
      (mock-tested in `tests/keep-awake.sh`).
- [x] `shellcheck` clean on changed/added scripts; existing suites
      green.

## Blocked by

None — builds on landed issues 10–12.

## Comments

- Live end-to-end check (hook in a running box → daemon holder visible
  in `/v1/status`) is a host-side manual step after `enable`.

- 2026-07-31: done, commit 0615337 — built-in agent-awake.sh hook wired into
  managed settings.json + idempotent setup-claude.sh migration + keep-awake
  status client-signal line; tests/keep-awake.sh (123 pass) and
  tests/connect-host.sh (regression, all pass) green, shellcheck clean,
  settings.json valid JSON. Live host e2e still a manual step.
