# 07 — Retire the `codex-delegate` seed, document Jobs

Status: ready-for-agent

## Parent

ADR 0037 (revises ADR 0021's seed); `docs/mcp.md`; boxa skill (`skills/boxa/SKILL.md`).

## What to build

- Remove the one-time `codex-delegate` seed (`ensure-codex-delegate-seed.sh`, `mcp.seed`, its call in `boxa update`/install, tests) and the matching docs. Existing catalog entries are not deleted automatically: `boxa doctor` and `boxa mcp status` explain that `codex mcp-server` no longer exists in current Codex and point to `boxa-job`; `boxa mcp remove codex-delegate` remains the user's action.
- Documentation: a `docs/jobs.md` (commands, states, key + ack flow, frugal waiting rules for skill authors, stated ownership limits, runtime snapshot behaviour), a Jobs section in the boxa skill so an agent inside a Container discovers `boxa-job`, a note in ADR 0021 pointing to ADR 0037, and `docs/mcp.md` updated.
- UI strings and comments in English only.

## Acceptance criteria

- [ ] Seed script, module, tests, and install/update hook call are gone; `boxa update` no longer offers the seed; shellcheck clean.
- [ ] `boxa doctor` on a host with the old catalog entry prints the explanation and the removal command.
- [ ] `docs/jobs.md` exists and matches the CLI `--help`; the boxa skill mentions `boxa-job` with the one-subagent-one-Job rule and frugal waiting.
- [ ] ADR 0021 carries a "revised by ADR 0037" note.

## Blocked by

- `04-codex-job-start-reply-result.md`

## Comments
