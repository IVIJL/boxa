# 01 — Job core: start / wait / result / list for a plain command

Status: ready-for-agent

## Parent

ADR 0037 (`docs/adr/0037-container-owned-jobs-replace-codex-mcp-server.md`), glossary `CONTEXT.md` § Jobs. Measured facts: memory `codex-job-manager-measurements` (a 40-line worker prototype proved setsid + subreaper + file output + heartbeat + atomic result survive the end of the Bash call and of a subagent).

## What to build

A Container command `boxa-job` (Python package under the Boxa scripts tree, shell front-end in the same shape as `boxa-mcp-run`: baked into the image with a repo-checkout fallback so it runs from the mounted repo without an image rebuild) that owns a plain command as a Job:

- `start --key K [--env KEY]... [--json] -- <argv>` reserves the key, forks a Job worker, and returns jobId + state at once. The worker (`setsid`, `PR_SET_CHILD_SUBREAPER`) spawns the command with `BOXA_JOB_ID` in its environment, stdout/stderr to files, a heartbeat file, and records the exit code atomically (temp + rename). Reservation is the worker's own write: full identity (worker pid + start time + Container run id, see 02 for the run id; use a placeholder until then) to a temp file published with `link()` — complete record or nothing.
- Worker environment is the fixed baseline the agent-trusted MCP launcher builds (`HOME`, `PATH`, XDG dirs, `DOCKER_HOST`, `SSH_AUTH_SOCK` when present) plus variables named with `--env KEY` (values taken from the caller, only names persisted).
- Key semantics scoped to the Project (Project key from Container identity): same key + same request fingerprint (argv, cwd, env names) → attach to the running Job or return the finished result; same key + different fingerprint → conflict (non-zero, structured); `--fresh` → new run only when no Job under that key is non-finished.
- Registration (check + reserve) runs under one short Project-level `flock`; the lock is never held during the work.
- `wait <jobId> [--timeout S]` blocks in-process (default 540 s, cap under the Bash 600 s limit) and returns a short structured status on expiry (`running`, jobId, heartbeat age) — no request text, paths, or logs repeated. `result <jobId>` returns state, exit code, paths, timings. `list` shows the Project's Jobs. `log <jobId> --tail N` on demand.
- States in this slice: `reserved → running → done | failed`. `done` requires the command exited under a live worker and no tracked descendant alive (tree tracking itself lands in 02; here: wait for the direct child, mark the rest as 02).
- State directory: `$XDG_STATE_HOME/boxa/jobs/<project-key-hash>/<jobId>/` (volume in 06).
- ADR 0037 status → accepted with this slice.

## Acceptance criteria

- [ ] Unit tests (pytest, same layout as `scripts/mcp` tests) cover reservation atomicity, key attach/return/conflict/`--fresh`, wait timeout output shape, env baseline + `--env`.
- [ ] In-Container proof: `start` a `sleep 30 && echo X` Job from a Bash tool call that ends; a later `wait` from a new shell returns `done` with exit 0 and stdout `X`.
- [ ] In-Container proof: a Job started by a subagent that returns immediately is still running afterwards and completes.
- [ ] Two simultaneous `start` with the same key produce one Job (one attaches).
- [ ] `wait` on an unchanged run prints ≤ 5 short lines / one compact JSON object.
- [ ] `boxa-job --help` documents every command; shellcheck clean on the front-end.
- [ ] ADR 0037 `Status: accepted`.

## Blocked by

None — can start immediately.

## Comments
