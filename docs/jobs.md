# Jobs

A **Job** is a command and its whole process tree run inside a **Container**,
whose lifetime, state, and result belong to the Container and not to the agent,
shell call, or session that started it. A Job outlives the Bash call, the
subagent, and the session; a waiting client can disconnect and a later one
finds the same Job and its result. A **Codex job** is a Job whose command is a
non-interactive Codex run, with a Codex thread later Jobs can continue.

Jobs replace the retired `codex-delegate` MCP entry: current Codex releases no
longer provide the `codex mcp-server` subcommand that entry ran. See
[ADR 0037](adr/0037-container-owned-jobs-replace-codex-mcp-server.md) for the
design and `CONTEXT.md` for the canonical glossary.

`boxa-job` is a Container command. It does not exist on the host, and it
refuses to run without a **Container identity**, because a **Job key** is
scoped to one **Project**.

## Commands

```
boxa-job start   --key K [--fresh] [--cwd DIR] [--env KEY]
                 [--ack-concurrent ID,ID] [--json]
                 [--codex --model M --effort E [--prompt-file PATH]]
                 -- argv | prompt
boxa-job reply   <jobId|threadId> --key K --model M --effort E
                 [--prompt-file PATH] [--env KEY] [--ack-concurrent ID,ID]
                 [--fresh] [--json] [prompt]
boxa-job wait    <jobId> [--timeout SECONDS] [--json]
boxa-job result  <jobId> [--json]
boxa-job list    [--json]
boxa-job cancel  <jobId> [--json]
boxa-job adopt   <jobId> [--json]
boxa-job log     <jobId> [--tail N]
boxa-job runtime [--json] list | refresh | use <version> | use --auto
boxa-job gc      [--older-than DAYS] [--purge] [--dry-run] [--json]
```

- `start` reserves the key, forks a Job worker, and returns the jobId at once.
- `reply` is another turn on an existing Codex thread, as a new Job.
- `wait` blocks in-process for one Job (default 540 s, maximum 570 s).
- `result` gives state, exit code, output paths, and timings.
- `cancel` kills the Job's tree and reports what it could not track.
- `adopt` takes over a Job whose worker died (watch only).
- `log` tails a Job's stdout and stderr, a Codex job's raw events, on demand.
- `runtime` shows, re-checks, or pins the verified **Codex runtime** copy.
- `gc` drops the bulky artefacts of long-finished Jobs; `--purge` drops whole
  records.

`--json` prints one compact object per call. `boxa-job --help` and
`boxa-job <command> --help` are the authoritative surface; this document
follows them.

## States

| State | Meaning |
| --- | --- |
| `reserved` | The key is taken, the command is not spawned yet. |
| `running` | The command is running under a live worker. |
| `done` | The command exited 0 under a live worker and nothing of its tree was left alive. |
| `failed` | The same, with a non-zero exit or, for a Codex job, without a terminal event. |
| `exited-with-survivors` | The command exited and tracked descendants are alive: the exit code is recorded, the Job is not finished. |
| `orphaned` | The worker died and the tree is alive: `adopt` or `cancel`. |
| `finished-unknown` | The command ended after its worker died, so no exit code exists. |
| `cancelled` | Stopped by `cancel`. |
| `interrupted` | A foreign Container run wrote the record, or the worker died before spawning. Never resumed automatically. |

Terminal states are `done`, `failed`, `cancelled`, `interrupted`, and
`finished-unknown`. `exited-with-survivors` and `orphaned` still count as
running for the concurrency ack and are never garbage-collected.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Finished or ok |
| 2 | Usage error |
| 3 | The worker failed |
| 4 | Unknown or unclear Job |
| 5 | Refused (for example `no-verified-runtime`) |
| 6 | Key conflict |
| 10 | `wait` expired while the Job is still running |
| 11 | `needs-ack`: other Jobs are running in this Project |
| 12 | `thread-busy`: that Codex thread already has a running Job |

## Job key, attach, conflict, and --fresh

A **Job key** is a caller-chosen identifier scoped to the Project, naming one
intended piece of work:

- Same key and same request fingerprint (argv or prompt, cwd, environment
  variable names): `start` attaches to the running Job, or returns the finished
  result. Nothing runs twice.
- Same key, different request: `conflict`, exit 6.
- `--fresh` starts a new run only when no Job under that key is unfinished. It
  never creates a concurrent copy of a running Job.
- Any unclear record (dead worker, foreign Container run id, unreadable
  record) refuses a retry under that key with exit 4 until `cancel` or `adopt`
  resolves it.
- A purged record (`gc --purge`) frees its key again.

A key protects against duplicate runs only. Running beside other Jobs is a
separate decision, handled by the ack.

## Concurrency ack

Keys do not lock the checkout, and concurrency is never silent:

1. `start` beside other running Jobs refuses with `needs-ack`, exit 11, and
   lists each running Job (jobId, key, state, start time, first line of the
   request).
2. Repeat the same `start` with `--ack-concurrent <id,id>` naming exactly that
   set, in any order. The Job starts and its record keeps `ackConcurrent`.
3. A Job that appeared or finished in the meantime makes the ack stale:
   another `needs-ack` with the current list arrives, and that one is what to
   ack.
4. With nothing running, no ack is asked for and `--ack-concurrent` is refused
   (`ack-not-needed`). Attaching to the same key and request needs no ack;
   `--fresh` is a run and does need one.
5. "Running" means `reserved`, `running`, `exited-with-survivors`, `orphaned`,
   and any record that cannot be read back. `interrupted` is terminal and does
   not count.

The ack is a traceable decision, not a lock. The orchestrating agent, not a
subagent, decides parallelism and owns write conflicts: one agent on file X and
another on file Y, or a read-only second run. A subagent acks only what the
orchestrator asked for.

## Codex jobs

```sh
boxa-job start --key review-01 --codex --model gpt-5.6 --effort high \
    --cwd /work/my-project "Review the diff of HEAD and report findings."
boxa-job reply <threadId> --key review-02 --model gpt-5.6 --effort high \
    "Now fix the first finding only."
```

- One subagent is one Codex thread is one running Job. `reply` into a thread
  whose Job is unfinished is refused `thread-busy` (exit 12), whatever key it
  uses. Steering is `cancel` and then `reply`: there is no way to inject a
  message into a turn in flight.
- `--model` and `--effort` are required and are never taken from
  `~/.codex/config.toml`. The record keeps what was requested, what the stream
  reported as used, and the Codex version captured at start.
- Long prompts belong in a file (`--prompt-file`). The prompt text is still
  what the request is fingerprinted by, so re-starting the same contract under
  the same key attaches instead of paying for it twice.
- Codex runs with `--dangerously-bypass-approvals-and-sandbox`,
  unconditionally: the Container is the boundary (ADR 0037). There is no
  separate grant or prompt for this.
- `result` prints one compact object: thread id, final message, usage, item
  counts, model and effort, Codex version. The event stream is never part of
  it; `boxa-job log <jobId> --tail N` shows it on demand.
- A Codex job is `done` only with a `turn.completed` event and exit 0. Exit 0
  without a terminal event, which is what a killed `codex exec` looks like, is
  `failed` with reason `no-terminal-event`, never `done`.

## Frugal waiting

Every model turn spent waiting is waste. These rules are the contract for a
skill that waits on a Job:

- Block in-process. `wait` blocks as long as the verified client limit allows,
  minus a margin (default 540 s, maximum 570 s, under the 600 s Bash cap), and
  its internal state checks never involve a model.
- `wait` returning `running` with exit 10 only means "call again". Call it
  again immediately.
- Write no running commentary between waits, and do not re-analyse the request
  between waits. An unchanged run yields only a short status and the jobId: no
  request text, model, paths, or logs repeated.
- Read logs only on demand or for diagnosis, never as a progress display.
- No early return to save tokens. A subagent that returns while its Job runs
  has answered nothing.
- Frugality never hides a problem: `failed`, `orphaned`,
  `exited-with-survivors`, `interrupted`, and `finished-unknown` stay distinct
  in the short output, and each needs a decision.
- On completion, take over the result, evaluate it, and hand the main agent a
  summary with the needed evidence.

## Ownership and its stated limits

While the worker lives it is a child subreaper, so every descendant reparents
to it and the whole tree is walked through `/proc` parent links. That catches a
child that called `setsid` and a child that wiped its environment. Process
identity is always pid plus process start time plus the Container run id (the
nonce the entrypoint writes to `/run/boxa/run-id`), never pid alone.

Every Job's command tree also carries `BOXA_JOB_ID` in its environment, which
is the only evidence left after the worker dies.

Two things are outside this contract, and the CLI says so in its own output:

- A process that cleared the marker after its worker died.
- Anything started through the rootless Docker daemon, which is not a
  descendant and may not be visible in the Container's `/proc`.

So "no owned process found" means "nothing Boxa can see". `cancel` reports what
it killed, what it could only remember from the record, and what it could not
track.

`cancel` writes the cancel request file first, then kills what Boxa can see
itself. A live worker notices the request, kills its tracked tree, and
finalizes the record as `cancelled`; if no worker is left, or it does not
finalize within 10 s, the CLI finalizes the record in its place. A killed
command is therefore never recorded as `failed`.

## Codex runtime snapshots

Interactive `codex` in a Container keeps running from the shared
`boxa-npm-global` volume, so `npm install -g @openai/codex` takes effect at
once. Codex jobs never execute from that mutable volume: they run only from a
verified immutable copy under the shared `boxa-codex-versions` volume.

`start` and `reply` refresh the runtime first, before taking any lock:

1. **Discovery.** The newest Codex version available locally: the npm volume,
   and on Linux also the host's `@openai/codex` package, bind-mounted
   read-only. A host binary is not runnable in a macOS Container, so that
   source is Linux only.
2. **Copy and hash.** A manifest of the source (paths, sizes, mtimes, package
   version) is taken before and after the copy, and every copied file is
   content-hashed against its source. Any difference, which is what a
   concurrent `npm` update looks like, discards the copy and keeps the previous
   runtime. An incomplete or inconsistent copy is never published.
3. **Probe.** The copy's own binary must answer `--version`, and then a real
   run is required, not a help scan: one trivial `codex exec --json` on the
   cheapest configured model followed by a `resume` into its thread, verifying
   `thread.started`, `turn.completed`, `-o`, and thread continuity.
4. **Publish.** Only then is the copy published atomically by rename as
   `<version>/` and marked verified. A publish lock keeps two Containers from
   racing.

A failed probe leaves the previous verified version in use and prints a loud
warning (also `warnings` in `--json`) instead of breaking the next job. With no
verified copy at all, a Codex job is refused `no-verified-runtime` (exit 5)
rather than silently running from the mutable volume.

`boxa-job runtime list` shows the sources found, the verified copies, and which
one is in use. `runtime refresh` performs the snapshot and probe now.
`runtime use <version>` pins a verified copy for rollback, and a pin
short-circuits the refresh entirely; `runtime use --auto` unpins and goes back
to the newest. Pinning an unverified version is refused (`not-verified`).

Published copies are made read-only for `node`. That is a convention the
Container user could undo, not root enforcement. Running jobs finish on their
copy because nothing ever rewrites files under them. The first job after a
Codex update pays one copy and probe; later jobs on the same version take the
fast path.

## State volume and retention

Job state lives in a per-Project named volume mounted at
`~/.local/state/boxa/jobs`, so it survives a Container restart and is removed
with the Project by `boxa remove` or `boxa stop --clean`.

- A Container restart resumes nothing. Every non-terminal record whose
  Container run id is not the current one becomes `interrupted` lazily on the
  next CLI call, with reason `container-restart`; its logs and its key stay.
- `start` and `reply` sweep first: the bulky artefacts (`events.jsonl`,
  `stdout`, `stderr`, `last.md`, the heartbeat, `worker.err`) of terminal Jobs
  older than 14 days are deleted and the Job record is kept, so `result` still
  answers with state, exit code, thread id, and the final message text, and
  says `artefacts: removed by gc`. `log` says why it has nothing to show.
- A Job that is not terminal is never touched at either level,
  `exited-with-survivors` included: its descendants are still writing.
- `gc [--older-than DAYS] [--dry-run] [--json]` runs that sweep by hand.
  `gc --purge` removes whole record directories and frees their keys. Nothing
  purges on its own.

## Environment overrides for tests

Production defaults are the fixed Container paths. These variables exist as
test seams and should never be set in normal use:

| Variable | Overrides |
| --- | --- |
| `BOXA_JOB_PROJECT_KEY` | The Project key a Job is scoped to, instead of the Container identity. |
| `BOXA_JOB_RUN_ID_PATH` | The Container run id file (default `/run/boxa/run-id`). |
| `XDG_STATE_HOME` | The Job state root (`$XDG_STATE_HOME/boxa/jobs`). |
| `BOXA_JOB_CODEX_VERSIONS_DIR` | The verified runtime root (default `/usr/local/share/boxa-codex-versions`). |
| `BOXA_JOB_CODEX_NPM_PKG_DIR` | The npm volume Codex package source. |
| `BOXA_JOB_CODEX_HOST_PKG_DIR` | The host Codex package mount (default `/run/boxa-codex-host-pkg`). |
| `BOXA_JOB_CODEX_BIN` | The Codex binary a Codex job runs, bypassing runtime selection. |
| `BOXA_JOB_PROBE_MODEL` | The model the runtime probe uses. |
| `BOXA_JOB_PROBE_TIMEOUT` | The runtime probe timeout in seconds. |

`BOXA_JOB_ID` is not an override: it is the ownership marker the worker puts
into every Job's command environment.
