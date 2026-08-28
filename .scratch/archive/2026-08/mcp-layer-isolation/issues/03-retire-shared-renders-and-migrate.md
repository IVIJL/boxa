# 03 — Retire shared-file renders, remove approval seeding, migration cleanup

Status: done

## Parent

ADR 0028 — Launch-time MCP injection instead of shared-file renders
(supersedes ADR 0022).

## What to build

With both wrappers live, stop producing every shared-file artifact:

- activation/deactivation no longer writes `<project>/.mcp.json`, approval
  seeds in `<project>/.claude/settings.local.json`, the Codex managed region
  in `<project>/.codex/config.toml`, or `.git/info/exclude` lines; the
  associated CAS project-file transactions, render state, and
  `--allow-tracked-*` write paths go away,
- convergence loses its render-assertion job (keep whatever snapshot/health
  duties remain, or retire the command if nothing is left),
- `boxa mcp migrate` gains a cleanup phase driven by the recorded render
  state: surgically remove previously rendered boxa content from all four
  artifact kinds across all Projects, preserve non-boxa content, refuse
  tracked files without the existing consent flags, stay idempotent, and run
  automatically on boxa update,
- align prose: `docs/mcp.md`, MCP-related CLI/help texts, and the
  Container session-context guidance that still describe project-config
  renders or approval seeding.

## Acceptance criteria

- [x] After migrate, previously rendered boxa content (`.mcp.json` entries,
      approval seeds, Codex managed region, `.git/info/exclude` lines) is
      surgically removed and user-authored content in the same files survives
      byte-identical (unit-tested in `tests/test_mcp_migration.py`); live
      verification that host Claude/Codex actually list zero boxa servers
      afterwards is deferred to the user (no host Claude/Codex available in
      this run)
- [x] Container sessions keep their MCP profile throughout (wrappers, not
      files) — carried by issues 01/02, unaffected by this change
- [x] Activate/deactivate cycles touch no file inside the Project directory
      (render call chain removed from `activation.py`; unit-tested)
- [x] Migrate is idempotent and refuses tracked-file edits without the
      consent flag, naming the file (unit-tested)
- [x] No remaining references to `.mcp.json` rendering or approval seeding in
      user-facing docs/help output (`docs/mcp.md`, `mcp-cli.sh`, `SKILL.md`
      aligned; verified by grep — only remaining mentions describe the
      cleanup phase itself)

## Blocked by

01-claude-launch-wrapper.md, 02-codex-launch-wrapper.md.

## Comments
