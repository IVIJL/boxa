# ADR 0037 — Container-owned Jobs replace `codex mcp-server`

- **Status:** proposed
- **Date:** 2026-09-12
- **Revises:** ADR 0021's `codex-delegate` catalog seed (`codex mcp-server`)

## Context

Codex CLI 0.149.1 deprecated and 0.154.0 removed `codex mcp-server`, the two-tool
MCP wrapper the `codex-delegate` catalog entry ran. Every Container's Codex
delegation died at once (`CONNECTION_CLOSED`) because the shared
`boxa-npm-global` volume carried the host update into all Containers. OpenAI's
replacement, the Codex plugin for Claude Code, bounds one status wait to a few
minutes and can move a run to the background. The working hypothesis for the
August failures (not reproduced) is that a subagent read "started in the
background" as done and returned, and the run died with it; the MCP path was
adopted to avoid that. The synchronous MCP call kept the run alive only for as
long as the connection lasted; that is a property of that implementation, not
of MCP.

Three timeouts overlap here and none may limit the work: the agent's one wait
call (Bash 600 s, MCP client-configured), the whole Codex run, and any long
command inside it. Measurements on 2026-09-12 (see memory
`codex-job-manager-measurements`) established: `codex exec --json` yields a
thread id and a terminal `turn.completed`; `codex exec resume <thread>`
continues a thread; SIGTERM kills the whole tree but writes no terminal event;
a detached worker (`setsid` + `PR_SET_CHILD_SUBREAPER`, output to files)
survives the end of the Bash call and of the subagent; killing the worker
leaves the command running with its exit code lost; `kill -pgid` misses a
child that called `setsid` itself while an environment marker plus a
`/proc/*/environ` scan finds every descendant; a 14-minute shell command
inside `codex exec` completes without the tool timing out; PID 1 reaps
orphans; cgroups are read-only in the Container.

## Decision

**Boxa owns long work as Jobs.** A Job (see `CONTEXT.md`) is a command run by a
Job worker inside the Container, with state and result on disk, independent of
whoever waits for it. Codex delegation is a Codex job: the same worker running
`codex exec --json` plus a thread id and a result extractor. There is one
mechanism for Codex runs and for long plain commands, not two.

**CLI first, no MCP.** `boxa-job` is a Container command baked into the image,
with `--json` output: `start`, `wait`, `result`, `log --tail`, `cancel`,
`adopt`, `list`, `reply` (Codex only), `gc`, `runtime`. Agents call it from their shell tool;
`wait` blocks up to a caller-bounded time (default under the Bash 600 s cap)
and returns `running` on expiry, which only means "call again".

**Frugal waiting.** Every model turn spent waiting is waste, so `wait` blocks
in-process as long as the verified client limit allows, minus a margin, and
its internal state checks never involve a model. An unchanged run yields only
a short structured status and the jobId: no request text, model, paths, or
logs repeated. Frugality never hides a problem: `failed`, `orphaned`,
`exited-with-survivors`, `interrupted`, and `finished-unknown` stay distinct
in that short output. The waiting skill writes no running commentary, does not
re-analyse the request between waits, and reads logs only on demand or for
diagnosis; on completion it takes over the result, evaluates it, and hands the
main agent a summary with the needed evidence. No early return to save
tokens. An MCP adapter
over the same core may come later if measurement shows a benefit; the catalog
entry `codex-delegate` and its seed are retired.

**Ownership by subreaper and marker, with stated limits.** The worker is a
child subreaper, so while it lives every descendant reparents to it and is
tracked by walking `/proc` parent links; that catches a child that called
`setsid` or cleared its environment. Every Job's command tree also carries
`BOXA_JOB_ID` in its environment, which is the only evidence left after the
worker dies. Process identity is pid plus start time plus the Container run id
(a nonce the entrypoint writes to `/run/boxa/run-id`), never pid alone. Two
things are outside this contract and the CLI says so in its output: a process
that cleared the marker after its worker died, and anything started through
the rootless Docker daemon, which is not a descendant and may not be visible in
the Container's `/proc`. "No owned process found" therefore means "nothing Boxa
can see", and `cancel` reports what it killed and what it could not track.

**States and honesty.** `reserved → running → done | failed | cancelled |
interrupted`, plus `exited-with-survivors` (command exited, tracked
descendants alive), `orphaned` (worker dead, command alive) and
`finished-unknown` (command ended after its worker died; Codex's terminal event
is evidence, not proof of a clean exit). The worker itself reserves the key:
it writes its full identity to a temporary file and publishes it with
`link()`, which either atomically creates the complete record or fails because
the key exists. There is never an empty or partial reservation; a leftover
temporary file is garbage, not a Job. Any unclear state (dead worker, unknown
Container run id, unreadable record) refuses a retry under the same key until
`cancel` or `adopt`. `done` requires the main command to have exited under a
live worker *and* no tracked descendant left alive: the worker waits for the
whole tree, not just the command. If descendants are still running after the
main command exited, the Job is `exited-with-survivors`: the exit code is
recorded, but the state is not a finished Job. It still counts as running for
the concurrency ack, is never garbage-collected, and only `cancel` (or the
survivors ending) moves it to a terminal state. After a Container restart every non-terminal
state (`reserved`, `running`, `orphaned`) whose run id is not the current one
is marked `interrupted` lazily on the next CLI call; there is no auto-resume.

**Job key semantics.** `start` requires a key scoped to the Project. Same key
and same request fingerprint: attach to the running Job or return the finished
result. Same key, different request: conflict. `--fresh` starts a new run only
when no Job with that key is running or in an unclear state; it never creates
a concurrent copy. A Codex thread has at most one running Job: `reply` into a
thread with a running Job is refused whatever the key. Keys do not lock the
checkout, but concurrency is never silent: when other Jobs are running in the
Project, `start` refuses with `needs-ack` and lists them (id, key, start time,
first line of the request). The caller repeats the call with
`--ack-concurrent <ids>` naming exactly those Jobs; a Job that appeared in the
meantime needs a fresh ack, and the ack is stored in the new Job's record.
"Running" for this purpose means every non-finished state: `reserved`,
`running`, `exited-with-survivors`, `orphaned`, and any unclear record. The
check and the new Job's reservation happen under one short Project-level lock
(a `flock` in the state directory held for the registration only, never for
the work), so two simultaneous starts cannot both see an empty Project. The
Codex thread lock is taken under the same lock. The
orchestrating agent, not a subagent, decides parallelism (file X versus file Y,
a read-only second run) and owns write conflicts; the ack makes that decision
explicit and traceable. Worktree isolation is a later option.

**Codex job contract.** Model and effort are required parameters (skills hard
code them, the user overrides by request); the record stores requested and
actually used values and the exact Codex runtime version. Codex jobs run with
`--dangerously-bypass-approvals-and-sandbox`, unconditionally. The run gets
everything `node` can reach in the Container: the mounted `~/.codex` and
`~/.claude` trees, the Project bind, the SSH agent socket when the gate is on,
the rootless Docker daemon, and the network the allowlist permits. That is
Boxa's model, not a per-feature choice: the Container is the one boundary, and
using Boxa is accepting that agents inside it run without a second sandbox,
exactly as Claude already does there. Codex's inner sandbox would block the
Docker socket delegated work needs, and approvals have nobody to answer them.
No separate grant or prompt exists for this.

**Worker environment.** The worker does not inherit the caller's environment.
It builds the same fixed baseline the agent-trusted MCP launcher uses
(`HOME`, `PATH`, XDG dirs, `DOCKER_HOST`, `SSH_AUTH_SOCK` when present) and
adds only variables the caller names with `--env KEY`; values are never written
to disk, only names.

**Codex runtime.** Interactive `codex` in a Container keeps working exactly as
today: the launch wrapper runs the version in the shared `boxa-npm-global`
volume, so `npm install -g @openai/codex` inside any Container takes effect at
once. Codex jobs never execute from that mutable volume. At `boxa-job start`
Boxa looks for the newest Codex version available locally (the volume, and on
Linux also the host's `@openai/codex` package, since a host binary is not
runnable in a macOS Container). A version found is not yet a version used: it
is copied into a temporary directory under the shared `boxa-codex-versions`
volume from a source proven consistent: a manifest of the source (paths,
sizes, mtimes, package version) is taken before and after the copy and the
copied files are content-hashed against the source; any difference, which is
what a concurrent `npm` update looks like, discards the copy and keeps the
previous runtime. An incomplete or inconsistent copy is never published. The copy is then checked (Linux binary
present and answering `--version`) and probed with a real run, not a help
scan: one trivial `codex exec --json` on the cheapest configured model
followed by a `resume` into its thread, verifying `thread.started`,
`turn.completed`, `-o`, and thread continuity. Only then is it published
atomically by rename as `<version>/` and marked verified. A
publish lock keeps two Containers from racing; a failed probe leaves the
previous verified version in use and prints a loud warning instead of
breaking the next job, which is the failure this ADR started from. `boxa-job
runtime list|use <version>` shows and pins the verified version for rollback.
Published copies are made read-only for `node`; that is a convention the
Container user could undo, not root enforcement, and v1 accepts that. Running
jobs finish on their copy because nothing ever rewrites files under them.
Updating therefore stays as it is today, no Container restart and no download
at start; the cost is one copy and probe per new version, on the first job
after an update. The image keeps baking Codex as the
seed that fills an empty `boxa-npm-global` volume.

**State and retention.** Job state lives in a per-Project named volume (the
existing `BOXA_VOL_*` pattern), removed with the Project. Bulky logs
(`events.jsonl`, stdout, stderr) are garbage-collected automatically after 14
days on `start`; the Job record stays until a manual `gc --purge`; active Jobs
are never touched.

## Considered options

- **Codex plugin for Claude Code.** Backgrounds runs after a bounded wait; a
  subagent cannot be trusted to keep waiting. Rejected.
- **Own thin stdio MCP bridge over `codex exec`.** Fixes the missing command
  but keeps the run's lifetime tied to the MCP connection and adds catalog,
  activation, and trust plumbing for one client. Deferred.
- **Codex Python SDK with pinned runtime.** Stable per its docs but adds a
  dependency and goes through the experimental app server; `codex exec` is the
  documented automation path and sits behind the same interface. Deferred.
- **Pin Codex in the Dockerfile only.** Ineffective while the runtime lives in
  a volume that shadows the image. Rejected.
- **Running jobs straight from the npm volume or a live bind of the host
  package.** `npm` rewrites files in place while a job is mid-run and Codex
  spawns helpers from that path. Rejected for jobs in favour of immutable
  per-version copies; kept for interactive use, where the user drives updates.
- **Snapshot once at Container start.** Immutable too, but a new version would
  need a Container restart, worse than today's `npm install` flow. Rejected for
  the lazy copy at job start.
- **Per-Project checkout lock.** Safe but blocks the deliberate parallelism
  the orchestrator wants (one agent on file X, another on file Y, or a
  read-only second run). Rejected for an explicit, id-bound acknowledgement.
- **Silent concurrency with an informational list.** Keeps parallelism but a
  subagent can overlook the list. Rejected for the ack.

## Consequences

- Skills `/cr`, `/ccode`, and `afk-feature-workflow` change from one
  synchronous MCP call to `start` plus a `wait` loop inside the subagent; the
  main agent still receives only the summary and diff.
- Release gate before switching skills: a two-hour Job with a long command
  inside Codex, wait expiry, subagent exit and reconnect mid-run, duplicate
  start, worker crash, cancel with a `setsid` escapee, Container restart. The
  15-minute measurement is a first proof, not the gate.
- Concurrent Jobs in one checkout remain possible by the user's decision,
  gated by the id-bound ack rather than a lock; the reviewer's position that
  only a lock or separate worktrees give a real guarantee is recorded here,
  and worktrees remain the upgrade path if the risk materializes.
- Release gate additions from review: a command that clears its environment
  (`env -i`), a Job that starts an inner Docker container, a host or in-box
  Codex update between two jobs (old version keeps running, new one is
  probed), an `npm` update running concurrently with the runtime copy (copy
  discarded), and a crash between reservation and spawn.
- The two-hour gate also measures and records as the baseline: the number of
  `wait` calls and the volume of their output; tokens and cost of the waiting
  Claude subagent separately from the working Codex run, where the client
  exposes them; that neither wait expiry nor reconnect starts a second Job;
  and that the final result is taken over and the workflow continues
  correctly. The MCP adapter is reconsidered against that measured waiting
  overhead, not before.
- Codex's native long-command handling stays the default inside a Codex job;
  routing long commands through `boxa-job` from inside Codex is added only if
  the gate fails.
- macOS branch (versions copied only from the npm volume, no host source) is deferred work under
  `.scratch/mac/`.
