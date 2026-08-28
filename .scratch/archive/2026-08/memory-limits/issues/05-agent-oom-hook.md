# 05 — In-container agent hook: OOM push + Memory warnings

Status: done

## Parent

None — decisions are recorded in CONTEXT.md (`### Memory`, **Memory
warning**) and will be captured in ADR 0020 (issue 07 of this feature).

## What to build

A PostToolUse hook inside the Container that tells the agent, at the
moment it matters, that an OOM kill happened or that memory is running
out — so the agent's next decision isn't "retry the thing that just got
killed". Matcher is `*` (any tool — a leak can come from any command, and
the victim may not even be the command the agent just ran).

Silent path (every tool call): read `/sys/fs/cgroup/memory.events` and
`memory.current`/`memory.max` (readable inside; verified), compare the
`oom_kill` counter and the usage band against a state file, exit silently
when nothing changed. Measured budget for this path: ~1.4 ms per call.

Speak-up paths:

1. **Counter delta** → pull the victim's details from `dmesg` (readable
   inside the Container; verified — kernel logs
   `Memory cgroup out of memory: Killed process ... (name) ... anon-rss:...`)
   and inject an honest message: a process in this project was OOM-killed
   (name, RSS, when), it is not necessarily the tool's own command, the
   project keeps running, don't retry as-is, and how to raise the limit.
   The counter delta is the natural dedup key — a kill is reported exactly
   once.
2. **Memory warning bands** (CONTEXT.md term): warn on crossing into the
   80 % band and the 90 % band; re-arm only after usage falls back below
   ~75 %, so a project hovering at a threshold warns once, not
   continuously.

Registration: Claude Code via the boxa-managed settings the same way the
ADR 0011 identity hook is delivered (one script, per-agent registration).
Codex: verify whether Codex managed config supports PostToolUse; if it
does, register there too; if not, fall back — within this issue — to a
SessionStart summary ("since your last session, N processes were
OOM-killed in this project"), and note the asymmetry in the hook script
header.

## Acceptance criteria

- [x] Hook registered for Claude Code with matcher `*`; a normal tool
      call with no OOM and no band change produces zero output
      (`managed-settings/claude-code/51-boxa-memory.json`; silent path
      verified in fixtures AND against this Container's real cgroup files,
      measured ~1.15 ms avg — under the 1.4 ms budget)
- [x] An OOM kill in the Container produces exactly one agent-visible
      message containing victim name, RSS, the limit, and raise guidance;
      wording does not claim the agent's own command was the victim
      (counter-delta dedup tested end-to-end with a real-format dmesg
      fixture; a real in-Container OOM kill was NOT triggered — this
      Container currently has `memory.max = max`, so the kill path is
      exercised via the `BOXA_MEMHOOK_DMESG_FILE`/cgroup-dir seams; live
      kill covered by the gated integration test, issue 09)
- [x] Crossing 80 % / 90 % produces one warning per band entry; hovering
      around a threshold does not repeat; dropping below ~75 % re-arms
      (unit hysteresis table + end-to-end bounce sequence in
      `tests/memory-context.sh`)
- [x] State survives across tool calls within a session and does not leak
      between different Containers (state file on the container-private
      rootfs at `/tmp/boxa-memory-hook.<user>.state` — not a bind mount;
      persistence across invocations tested; cross-Container isolation is
      by construction of the path, not by a test)
- [x] Codex either registered (if PostToolUse supported) or the
      SessionStart fallback implemented; the choice is documented in the
      script header (PostToolUse IS supported: codex-cli 0.144.5 config
      schema enumerates PostToolUse in its hook-event enum with the same
      HookHandlerConfig shape as the working SessionStart entry —
      registered in `managed-settings/codex/managed_config.toml`; no
      SessionStart fallback needed, no asymmetry; documented in the
      script header)
- [x] Band/dedup logic covered by unit tests (function extraction
      pattern); shellcheck clean (helpers return via `MEMHOOK_*` globals
      instead of stdout so the silent path stays fork-free; sourced with
      `BOXA_MEMHOOK_NO_MAIN=1`; shellcheck clean incl. info level — two
      justified SC2088 inline disables in the test, literal-text needles)

## Blocked by

None — can start immediately (reads cgroup files directly; message text
references the config file defined in issue 01 but has no code
dependency).

## Comments

- Implemented in commit `587fc61` (`scripts/hooks/boxa-memory-context.sh`,
  `managed-settings/claude-code/51-boxa-memory.json`,
  `managed-settings/codex/managed_config.toml` PostToolUse entry,
  Dockerfile bake, `tests/memory-context.sh`).
- Registration lands in the image (Dockerfile COPY), so live Containers
  pick the hook up on next image rebuild, matching the ADR 0011 cadence.
- The dmesg attribution is hedged in the message text: the WSL VM shares
  one kernel ring buffer, so the newest matching record could in rare
  simultaneous-OOM cases belong to another project; the cgroup counter
  delta is authoritative for "a kill happened in THIS project".
