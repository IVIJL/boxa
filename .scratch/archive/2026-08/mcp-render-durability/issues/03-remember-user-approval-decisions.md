# 03 — Remember the user's approval decision for foreign servers

Status: done

## Parent

ADR 0022 — Durable Claude MCP render and approval.

## What to build

A `.mcp.json` can also carry servers Boxa did not render — typically because
they arrived with a cloned repository. Those are exactly the case Claude Code's
approval prompt exists for, so Boxa must never seed them. The user approves them
through Claude Code itself.

What Boxa does is make that decision stick. Claude Code stores the answer in
`~/.claude/.claude.json`, the same file whose loss motivated this whole ADR.
Boxa observes the recorded decision for the current Project — approval and
rejection alike — and mirrors it into the Project's
`.claude/settings.local.json`, so losing `.claude.json` does not lose the
decision and the user is not asked a second time.

Boxa observes and persists; it never originates a decision. A server the user
has not yet answered for stays unanswered, and the prompt still appears. A
rejection is mirrored just as faithfully as an approval, so mirroring can never
quietly turn a "no" into a "yes".

This applies to Boxa-rendered servers too, past their one-time seed: once the
user has expressed a decision through Claude Code, that decision is what gets
remembered.

## Acceptance criteria

- [x] A foreign `.mcp.json` server is never seeded and still triggers Claude
      Code's own approval prompt.
- [x] After the user approves it, the decision is mirrored into the Project's
      `.claude/settings.local.json`.
- [x] Wiping `~/.claude/.claude.json` and starting a fresh session does not
      re-prompt for a server the user has already answered for.
- [x] A rejection is mirrored as a rejection; no mirroring path can convert an
      unanswered or rejected server into an approved one.
- [x] A user decision recorded after Boxa's one-time seed wins over the seed on
      every later render.
- [x] Mirroring preserves unrelated content in both files.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes after any shell changes.

## Blocked by

- `.scratch/mcp-render-durability/issues/02-seed-approval-for-boxa-rendered-servers.md`

## Comments

- Criterion 1 and 3 are covered by unit tests (foreign server never seeded and
  left unanswered; decisions survive deleting `~/.claude/.claude.json`). That
  Claude Code actually re-prompts / stops prompting in a live in-Container
  session is deferred verification — it needs a real Claude session.
- Deviation: `_retire_old_claude_render` no longer raises on a malformed or
  unreadable `~/.claude/.claude.json`; it now returns without purging, matching
  the "observe nothing rather than fail the render" rule of this slice.
