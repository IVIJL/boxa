# 02 — Seed Claude approval for Boxa-rendered servers, once

Status: done

## Parent

ADR 0022 — Durable Claude MCP render and approval.

## What to build

A server defined in `.mcp.json` is not usable until Claude Code's per-Project
approval names it. Running `boxa mcp activate` already **is** the user's
decision to expose that server, so Boxa delivers that consent instead of making
the user give it a second time in another tool.

Rendering for the `claude` consumer seeds the rendered name into
`enabledMcpjsonServers` in the Project's `.claude/settings.local.json`. Any
unrelated settings that file already holds — the user's own, or the permission
rules Claude Code writes there — are preserved.

The seeded set comes from Boxa's own render state, meaning the exact names Boxa
rendered in that run. It is never derived from a prefix match against the
file's contents, so a foreign server that happens to be named like a Boxa one
cannot be approved this way. `enableAllProjectMcpServers` is not written under
any circumstance.

Seeding happens once per name. A name Boxa has already seeded is never seeded
again, so a user who turns the server off through Claude Code's own controls
stays off across every later render, including a full re-render after drift
repair. Deactivating the entry retires its seed, so a later re-activation is
treated as new and seeds again.

## Acceptance criteria

- [x] Activating for `claude` seeds the rendered name into
      `enabledMcpjsonServers` in the Project's `.claude/settings.local.json`.
- [ ] A fresh in-Container Claude session finds the server usable with no
      approval prompt.
      Deferred: needs a live Container and a host `boxa` run; not verifiable
      from the implementation session. Unblocked by removing
      `enableAllProjectMcpServers` from `config/claude/settings.json` and by
      the one-shot Container-start migration that removes the previously
      seeded key from existing host settings. A Container rebuild is still
      required before this can be observed.
- [x] Unrelated content in `.claude/settings.local.json`, including
      Claude-Code-written permission rules, survives every Boxa write.
- [x] Disabling the server through Claude Code and then re-rendering leaves it
      disabled — the seed is not reapplied.
- [x] A foreign `.mcp.json` server whose name matches Boxa's naming shape is
      never seeded, because seeding reads render state and not the file.
- [x] `enableAllProjectMcpServers` is never written, in any file.
- [x] Deactivating withdraws the approval delivered by Boxa and retires the
      seed; re-activating the same entry seeds it again.
- [x] Withdrawal touches only names in Boxa's previous seeded set; unrelated
      and user-created approvals and unrelated settings survive.
- [x] A recorded Claude Code approval or rejection wins over withdrawal, and
      withdrawal alone never creates a rejection.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes after any shell changes.

## Blocked by

- `.scratch/mcp-render-durability/issues/01-claude-render-to-project-mcp-json.md`

## Comments
