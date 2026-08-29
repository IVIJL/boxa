# 01 — Keep the Awake lease during long-running agent work

Status: ready-for-human

## Parent

ADR 0023 defines the Host connection used by keep-awake. The existing
shell-aware Stop fix in commit `fb47c3d` remains valid but covers a different
failure mode.

## What to build

Diagnose and fix the observed case where a host slept while an AFK agent was
still executing work. A managed agent must keep a live **Awake lease** for the
whole duration of active work, including one foreground tool, MCP delegation,
or subagent operation that lasts longer than the lease TTL without producing
another ordinary activity event.

First distinguish lease expiry from a stopped daemon, broken autostart, an
unreachable Host connection, or an incorrect activity/stop transition. Preserve
the safety property that a crashed or abandoned agent cannot inhibit sleep
forever. This work concerns active-work sleep inhibition only; it must not
restore the cancelled pre-sleep Container-stop or power-event behavior.

## Acceptance criteria

- [x] The 2026-08-25 incident has a reproducible case or captured event, daemon,
      reachability, and lease evidence sufficient to identify its failure mode.
      (See Diagnosis: host forensics + container-side live verification.)
- [x] A regression test fails when one active foreground operation outlives the
      current lease TTL without another ordinary activity event.
      (`tests/keep-awake.sh` heartbeat scenarios; reverting the refresher makes
      them fail.)
- [x] While that operation remains active, the daemon continues reporting a
      live holder and the host sleep inhibitor remains engaged.
      (Refresher heartbeat every 90 s; Go fake-clock manager tests.)
- [x] Normal completion releases the holder promptly; loss of the agent,
      heartbeat, or connection expires it within a documented bounded time.
      (Idle → 120 s server-side grace; crash/heartbeat loss ≤ one TTL;
      documented in `docs/keep-awake.md`.)
- [x] Existing project-scoped sessions, background-shell Stop handling, WSL
      reachability, and native Linux/macOS behavior do not regress.
      (Full `tests/keep-awake.sh` suite and Go tests green after the change.)
- [ ] Automated proof uses accelerated or fake time (done), and the issue
      records a live Windows/WSL soak procedure longer than the production TTL
      (recorded below) — promotion to `done` waits for that soak to pass.

## Blocked by

None — diagnosis can start immediately. Implementation must wait until the
failure mode and the AFK versus human live-verification boundary are frozen.

## Diagnosis (2026-08-29)

Failure mode of the 2026-08-25 incident is identified. Two independent
evidence sets agree.

**Host-side forensics (Codex, from Windows power logs and keep-awake.log,
reported by the user):**

- 11:58:29 monitor off; keep-awake blocked sleep 46m49s of the following
  48m07s.
- 12:46:18 the issue-04 subagent finished. 12:46:36 Windows slept, reason
  `System Idle`. 12:46:37 the orchestrator tried to spawn issue 07 — one
  second after the sleep. 13:27:05 manual wake by power button.
- `keep-awake.exe` ran continuously since 6:06 without a crash; Windows
  registered its SYSTEM power request and honored it 97 % of the observed
  window; no `powercfg` override ignores it.

**Container-side live verification (this box, 2026-08-29):**

- Relay path works: `GET http://127.0.0.1:17777/v1/status` answers from the
  Container; holder `claude/boxa` refreshes on every PreToolUse.
- `agent-awake.sh idle` (the Stop hook body) drops the daemon to
  `activeHolders: []`, `isInhibited: false` within one second. Release is
  immediate and total — no grace period.
- Hook registration (`settings.json`): busy fires only on `UserPromptSubmit`
  and `PreToolUse`; nothing fires during an in-flight tool call.
- TTL expiry semantics confirmed: a lease with `ttl=60` and no refresh
  disappeared at TTL while "work" continued (synthetic `probe` holder).

**Conclusion.** All Claude agents and subagents share one holder
`claude/boxa`. The Stop hook releases it the moment a turn ends even though
orchestration continues with the next subagent; the shell-snapshot guard
(`fb47c3d`) recognizes only background shells. Because the host's own idle
timeout had long expired, Windows slept inside the ~18 s gap between the
issue-04 subagent finishing and the orchestrator's next tool call. Ruled
out: daemon crash, broken autostart, unreachable relay, and (for this
incident) TTL expiry.

**Second latent mode (confirmed, not the 8/25 trigger):** one in-flight
operation longer than 15 min (MCP_TOOL_TIMEOUT allows 2 h Codex calls)
produces no busy event, so the lease expires mid-operation. The original
issue hypothesis describes this mode; it still needs fixing.

**Observability gap:** the daemon logs only startup and errors — no lease
acquire/refresh/release/expiry or inhibit transitions. Transition logging
should land with the fix.

**Candidate fixes (design not yet frozen):**

1. Idle linger — Stop-idle converts the holder to a short grace TTL
   (e.g. 120–180 s) instead of instant release. Covers every inter-turn and
   inter-subagent gap without tracking subagents; keeps the bounded-expiry
   safety property. Client-only variant: hook sends `busy?ttl=<grace>`;
   daemon variant: `/v1/idle` applies the grace server-side.
2. In-flight heartbeat — PreToolUse records an in-flight marker and starts a
   refresher tied to the live claude PID; PostToolUse clears it. Covers the
   longer-than-TTL single-operation mode.
3. Per-subagent holders (Codex suggestion) — heavier; note the 18 s gap was
   *between* turns, so per-subagent leases alone would not have closed it.

## Frozen design (2026-08-29)

User decision: linger is server-side. Two mechanisms, no hook-event
registration changes, no per-subagent holders.

1. **Server-side idle linger.** New daemon flag `-idle-grace` (default
   120 s; `0` restores legacy instant release). `Registry.Idle` on an
   existing holder sets `expires = now + grace` instead of deleting it; on an
   absent holder it stays a no-op and never creates a lease. Status shape is
   unchanged; the linger shows up as a small `remainingTTLSeconds`.
2. **Turn-scoped heartbeat in `agent-awake.sh`.** Busy actions
   (UserPromptSubmit, PreToolUse) write a per-claude-PID state file and
   ensure one detached refresher process. The refresher re-sends
   `busy?ttl=900` every `BOXA_AWAKE_REFRESH_INTERVAL` (default 300 s) while
   its owning claude PID is alive and the state is busy, reusing the
   existing candidate-address send logic. Stop with idle detection kills the
   refresher, then sends idle (daemon lingers); Stop with the
   shell-snapshot busy detection leaves the refresher running, which also
   closes the long-background-shell hole. Claude crash stops refresh via
   the PID check; the lease then expires within one TTL. State under
   `/tmp`, creation raced via a lock, POSIX sh, no jq.
3. **Daemon transition logging.** Log holder added, idle→linger, holder
   expired, and inhibitor acquired/released. Do not log per-refresh.
4. **Tests.** Go fake-clock coverage for linger in registry, manager, and
   httpapi (still inhibited during grace, released after; grace 0 instant;
   idle on absent holder no-op). `tests/keep-awake.sh`: regression proving a
   foreground operation outliving a short TTL keeps the lease via the
   refresher; Stop kills the refresher; dead claude PID stops refresh;
   existing scenarios stay green. Shellcheck clean including info level.
5. **Docs.** `docs/keep-awake.md` and `keep-awake/README.md`: linger
   semantics, heartbeat, and the bounded-expiry guarantees table.

Bounded-expiry safety after the change: crashed agent ≤ TTL (refresher PID
check), abandoned session ≤ grace after Stop, kill −9 of everything ≤ TTL.

## Implementation record (2026-08-29)

Implemented per the frozen design (Codex sol via MCP, threads
`01a04c21-e082-7ac0-a0c5-d1453eb1723d`, `01a04c3a-f14c-7ee3-8122-9fa03f1a8f57`,
`01a04c46-85f3-7a80-a3da-b31fab905a20`; review thread
`01a04c36-67f8-7172-9890-b24882326e79`, clean after two fix rounds). Deltas
against the frozen design, all review-driven:

- Refresher interval default is 90 s (not 300 s) so a surviving refresher
  re-arms the shared holder before a foreign Stop's 120 s grace expires; the
  guarantee assumes `-idle-grace` ≥ the heartbeat interval (documented, not
  enforced).
- Stop writes state before the group-kill and the refresher re-checks state
  before each send; a request already on the wire remains possible and is
  bounded by one TTL.
- Spawn lock records its owner and reclaims dead-owner or aged (>1 min)
  ownerless locks.
- Observability beyond the frozen design: client `refresher.log` (lifecycle +
  failure/recovery transitions incl. initial failure with tried addresses),
  `src=hook|refresher-<pid>` on busy requests, daemon logs refreshes of an
  existing holder at most once per holder per 5 min.

## Live container verification (2026-08-29, after host refresh + box restart)

Functional pass from a live box against the refreshed daemon; found and fixed
two defects the automated suite had masked (uncommitted on top of `5360a16`):

- **Owner detection never matched the live Claude.** Claude Code now installs
  as a versioned binary (`~/.local/share/claude/versions/2.1.245`, comm
  `2.1.245`), so the comm==`claude` owner walk found nothing: no refresher ever
  spawned, and the `fb47c3d` shell-snapshot guard was silently dead too. Fixed
  in `config/claude/hooks/agent-awake.sh` — a process is Claude when comm or
  argv[0] basename is `claude`, or argv[0] matches `/claude/versions/[^/]+$`
  (version-independent). The test ps stub's `owned` tree now uses the
  versioned layout, so reverting the fix fails the heartbeat scenarios.
- **Test-suite leakage into the live machine.** Early hook scenarios ran with
  the real `ps` and the default state dir, so a suite run inside a live
  session wrote flapping transitions into the real `refresher.log` and leaked
  a refresher that inherited test env (after TMPROOT cleanup it heartbeated
  the real daemon as `claude/sample-project`). Fixed by exporting
  `BOXA_AWAKE_STATE_DIR` + `BOXA_PS_COMMAND=false` before the first hook
  invocation in `tests/keep-awake.sh`.

Verified live after the fixes (shellcheck clean, 265 tests green 3×):

- Daemon linger: synthetic `probe` holder shows `remainingTTLSeconds: 120`
  after idle instead of vanishing — the refreshed host binary is live.
- Refresher lifecycle across turns: start → `exit reason=state-idle` on Stop
  → new start on the next turn, recorded in the live `refresher.log`.
- 200 s silent background soak: holder at 822 s remaining (≈700 without a
  heartbeat), state `shell` — Stop kept the refresher alive for the running
  background shell and the heartbeat refreshed the lease with no failures.

Note: a refresher survives a bare SIGTERM until its current 90 s sleep ends
(POSIX sh runs traps after the foreground child exits); `stop_refresher`
group-kills, so the production Stop path is unaffected.

## Live soak procedure (required before `done`)

1. On the host: `boxa keep-awake refresh` (rebuilds the daemon with
   `-idle-grace` + transition logging and reinstalls the managed hook), then
   `boxa keep-awake status`.
2. Set the Windows sleep-after-idle timer to 10 minutes for the soak.
3. In a boxa container, run one Claude session with a single foreground
   operation longer than 20 minutes that emits no further activity events
   (e.g. one Codex MCP delegation), hands off keyboard/mouse for the whole
   window.
4. Pass criteria: the host never sleeps during the operation;
   `keep-awake.log` shows periodic `holder refreshed … src="refresher-<pid>"`
   lines and no unexpected `holder expired`; after the final Stop the holder
   lingers ≤120 s and the host may sleep afterwards; the container's
   `/tmp/boxa-agent-awake/<pid>/refresher.log` shows start and a clean exit
   reason.

## Comments

- Evidence: the archived Forge identity AFK handoff records that the host slept
  once after approximately 41 minutes while issue 07 was still running and
  explicitly leaves keep-awake for investigation.
- The existing Activity hook refreshes a 15-minute lease on ordinary activity
  events. A long foreground operation with no further event may therefore
  outlive its lease; this is the leading hypothesis, not yet a conclusion.
- Commit `fb47c3d` keeps the lease during a live background shell after Claude's
  Stop event. The later incident occurred after that fix and must not be closed
  as a duplicate without evidence.
