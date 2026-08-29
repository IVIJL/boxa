# 01 — Keep the Awake lease during long-running agent work

Status: needs-triage

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

- [ ] The 2026-08-25 incident has a reproducible case or captured event, daemon,
      reachability, and lease evidence sufficient to identify its failure mode.
- [ ] A regression test fails when one active foreground operation outlives the
      current lease TTL without another ordinary activity event.
- [ ] While that operation remains active, the daemon continues reporting a
      live holder and the host sleep inhibitor remains engaged.
- [ ] Normal completion releases the holder promptly; loss of the agent,
      heartbeat, or connection expires it within a documented bounded time.
- [ ] Existing project-scoped sessions, background-shell Stop handling, WSL
      reachability, and native Linux/macOS behavior do not regress.
- [ ] Automated proof uses accelerated or fake time, and the issue records a
      live Windows/WSL soak procedure longer than the production TTL before it
      is promoted to `done`.

## Blocked by

None — diagnosis can start immediately. Implementation must wait until the
failure mode and the AFK versus human live-verification boundary are frozen.

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
