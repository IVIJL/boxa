# 01 — Claude Agent launch wrapper: strict profile injection + per-invocation version resolve

Status: done

## Parent

ADR 0028 — Launch-time MCP injection instead of shared-file renders.

## What to build

Replace the every-start `~/.local/bin/claude` symlink with a generated
Container-only wrapper script (same path, same regeneration point in the
Container setup flow). On every invocation the wrapper:

- resolves the highest available Claude CLI version under the mounted
  versions directory and execs it (a host CLI update needs no Boxa restart),
- derives the current Project's MCP profile from the read-only runtime
  snapshot (`projects` map joined with `entries`; Project key from Container
  identity, host-path parity makes paths match),
- injects the profile as the session's complete MCP configuration via
  `--strict-mcp-config --mcp-config=<inline JSON>`. Use the `=` form: the
  variadic space form swallows following arguments (verified on 2.1.234).
  Remote-entry support is issue 04; here render stdio entries through the
  Boxa MCP launcher exactly as today's `.mcp.json` definitions do.

Snapshot missing, unreadable, or invalid → exec the agent with strict mode and
an empty config plus a single stderr warning; never block the start. An empty
profile behaves the same (no MCP, no noise beyond strict flags).

The profile-derivation logic must be reusable by the Codex wrapper (issue 02).
Wrapper stays dependency-light; it runs on every agent start, including
non-session subcommands, which must keep working.

## Acceptance criteria

- [ ] New session in a Project with an active entry exposes exactly that
      entry's tools even after `<project>/.mcp.json` is deleted
      (unit-covered via `launch_profile`/CLI tests; live Container session
      not exercised here — deferred to the user's live host verification per
      KICKOFF.md)
- [x] A server present only in `.mcp.json` or user scope does not appear in a
      Container session — the wrapper's `--strict-mcp-config` never reads
      `.mcp.json`/user scope at all; covered by
      `test_active_entries_apply_consumer_enabled_and_stdio_filters`
- [ ] `claude --version` / `claude mcp list` and other subcommands still work
      through the wrapper (argv passthrough is unconditional in the
      generated wrapper; not exercised against a real `claude` binary in
      this sandbox — live verification pending)
- [ ] After copying a newer version into the versions directory, the next
      invocation runs it without Container restart (version resolution logic
      unchanged from prior `repair_claude_bin` `sort -V` behavior, re-run
      every invocation instead of once at Container start; not exercised
      live)
- [x] Corrupt or missing snapshot: session starts, has no MCP, one stderr
      warning — covered by
      `test_cli_missing_snapshot_fails_silently_for_wrapper_fallback` and
      `test_cli_invalid_snapshot_fails_silently_for_wrapper_fallback`
      (CLI fails silently with exit 1; the wrapper shell prints the single
      stderr warning and falls back to `{"mcpServers":{}}`)
- [x] shellcheck-clean wrapper generation and generated script — verified
      both `scripts/setup-claude.sh` and the extracted generated wrapper body
      with `shellcheck` (0 findings, including info-level)

## Blocked by

None — can start immediately.

## Comments

Implemented via Codex delegation (thread `01a022b2-b0f8-7fb0-98a4-8cee16fdf1ec`).
`repair_claude_bin()` in `scripts/setup-claude.sh` now generates a wrapper
script instead of a symlink; profile derivation lives in the new
`scripts/mcp/launch_profile.py` (`active_project_entries` /
`claude_launch_profile`), exposed via `python3 -m mcp.cli
claude-launch-profile`, reused verbatim from `scripts/mcp/trusted.py` and
`scripts/mcp/activation.py`'s existing `claude_server_definition`. Live
Container acceptance criteria (actual `claude` session, real version bump,
real Container restart) intentionally left unverified per AFK batch
instructions — user will verify live on host.
