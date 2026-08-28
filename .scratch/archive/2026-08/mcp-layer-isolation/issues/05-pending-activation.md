# 05 — Pending activation for stopped Boxas

Status: done

## Parent

ADR 0029 — Everywhere entries, pending activation, and remote catalog entries.

## What to build

`boxa mcp activate` against a stopped Boxa records the activation as pending
instead of failing. End to end:

- activation store and runtime snapshot represent the pending state; both
  wrappers exclude pending activations from injected sessions,
- at the next Container start (the hook where convergence ran), readiness for
  each pending activation of that Project re-evaluates: pass → activation
  becomes effective for new sessions; fail → stays pending, start prints a
  warning with the reason,
- `boxa mcp status` shows pending activations distinctly, with the blocking
  readiness reason after a failed attempt,
- remote entries never enter pending (issue 04 behaviour takes precedence),
- deactivating a pending activation simply removes it.

The invariant "a session only ever sees a readiness-passed server" must hold
throughout.

## Acceptance criteria

- [x] Activate on a stopped Boxa succeeds with output naming the pending state
- [x] After starting that Boxa with prerequisites present, a new session has
      the server without further commands
- [x] With a failing prerequisite, Container start warns, status names the
      reason, sessions do not see the server
- [x] Running-Boxa activation behaviour is unchanged (immediate readiness,
      immediate effect)

All four covered by unit tests exercising the real code paths (activate →
pending record → `reevaluate_pending` pass/fail → status/wrapper exclusion)
with fake Docker/readiness probes. Live verification against a real stopped
Boxa and an actual Container restart is deferred to the user.

## Blocked by

01-claude-launch-wrapper.md (pending-aware snapshot consumed by wrappers;
02 picks the shared derivation up automatically).

## Comments
