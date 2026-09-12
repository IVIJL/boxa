# 07 — Retire the `codex-delegate` seed, document Jobs

Status: done

## Parent

ADR 0037 (revises ADR 0021's seed); `docs/mcp.md`; boxa skill (`skills/boxa/SKILL.md`).

## What to build

- Remove the one-time `codex-delegate` seed (`ensure-codex-delegate-seed.sh`, `mcp.seed`, its call in `boxa update`/install, tests) and the matching docs. Existing catalog entries are not deleted automatically: `boxa doctor` and `boxa mcp status` explain that `codex mcp-server` no longer exists in current Codex and point to `boxa-job`; `boxa mcp remove codex-delegate` remains the user's action.
- Documentation: a `docs/jobs.md` (commands, states, key + ack flow, frugal waiting rules for skill authors, stated ownership limits, runtime snapshot behaviour), a Jobs section in the boxa skill so an agent inside a Container discovers `boxa-job`, a note in ADR 0021 pointing to ADR 0037, and `docs/mcp.md` updated.
- UI strings and comments in English only.

## Acceptance criteria

- [x] Seed script, module, tests, and install/update hook call are gone; `boxa update` no longer offers the seed; shellcheck clean.
- [x] `boxa doctor` on a host with the old catalog entry prints the explanation and the removal command.
- [x] `docs/jobs.md` exists and matches the CLI `--help`; the boxa skill mentions `boxa-job` with the one-subagent-one-Job rule and frugal waiting.
- [x] ADR 0021 carries a "revised by ADR 0037" note.

## Blocked by

- `04-codex-job-start-reply-result.md`

## Comments

### 2026-09-12 — implemented natively (Claude)

**Removed.** `scripts/ensure-codex-delegate-seed.sh`, `scripts/mcp/seed.py`,
`tests/test_mcp_seed.py` (git rm), the `setup_codex_delegate_seed` step and its
call in `install.sh`, the hook call in `boxa update` (`docker-run.sh`), and the
five `seed-codex-delegate-*` subcommands in `scripts/mcp/cli.py`. The
`is_codex_delegate_argv` predicate in `mcp/catalog.py` stayed: it is exactly
what recognizes the leftover entry now.

**Check-only report (no --fix).** `mcp.catalog.retired_codex_delegate_entries()`
/ `retired_codex_delegate_notice()` render the explanation + `boxa mcp remove
<real name>` (matched by command, so an entry added under another name is
covered). Surfaces: `boxa mcp status` in both scopes (`catalog-effective-list-text`
and `list-text`, plus a `retiredCodexDelegate` key in both JSON forms) and
`boxa doctor` through the new `mcp.cli retired-codex-delegate-text` command,
called by `report_retired_codex_delegate_entries()` in the doctor mode block
next to `report_broken_host_connections`. Deviation from the issue wording: it
is NOT a `BOXA_PROVISIONING_STEPS` entry. That registry maps a step id to an
`ensure-*.sh` repair, and this finding must never be repaired automatically;
it follows the existing check-only report pattern instead, so there is no
`boxa doctor --fix <id>` for it. Empty output on a clean catalog, so doctor
stays silent on a host that never had the entry.

**Docs.** New `docs/jobs.md` (commands with flags, state and exit-code tables,
key/attach/conflict/`--fresh`, the ack flow, frugal-waiting rules for skill
authors, ownership limits, runtime snapshot discovery/copy/hash/probe/publish +
`runtime list|refresh|use` + `no-verified-runtime`, state volume and retention,
env overrides for tests). Every `--*` flag of every subcommand in
`python3 -m jobs.cli <cmd> --help` was diffed against the file (script loop, no
misses); the command list and order match `--help`. `docs/mcp.md`: the "Trusted
Codex delegation" section became "Codex delegation moved to Jobs" and the
`boxa mcp mode` example uses `<entry>`. ADR 0021: "partly revised by ADR 0037"
in the status area + a revision note at the `codex mcp-server` consequence.
ADR 0028: one-line note that the entry is retired (historical mention kept).
`README.md`: `docs/jobs.md` in the doc index. `CONTEXT.md`: the **Job** entry
points at `docs/jobs.md`.

**Skill.** `skills/boxa/SKILL.md` gained "### Run long work as a Job
(`boxa-job`)" under § Inside container (when to use, start → wait loop →
result, the Codex form, one-subagent-one-thread-one-Job, frugal waiting, ack
only on the orchestrator's request), the host MCP recipe became "Codex
delegation is not an MCP entry any more", the two `codex-delegate` entries in
§ Common failures were replaced (leftover entry → `boxa-job` + `boxa mcp
remove`; work lost at a call boundary → Job), and `Jobs and the boxa-job CLI`
went into the front-matter description so the skill fires on Job questions.
**Sync path:** the repo file is the only source; `scripts/ensure-boxa-skill.sh`
copies it to `~/.agents/skills/boxa/SKILL.md` on the host with
`~/.claude/skills/boxa` and `~/.codex/skills/boxa` symlinks (ADR 0011), so the
user's next `boxa update` / `boxa doctor` propagates it. There is no separate
Codex-side copy to edit. `scripts/hooks/boxa-identity-context.sh`: the
`mcp__boxa-codex-delegate` example is now neutral (`mcp__boxa-<entry>`) and one
line points at `boxa-job` for long or Codex work.

**Tests.** New `tests/test_mcp_retired_codex_delegate.py` (13 tests): detection
by command not name, unrelated `codex exec` entry not matched, notice content
(removed subcommand, `boxa-job`, `docs/jobs.md`, ADR 0037, removal command with
the real name), clean catalog renders nothing, the doctor command's silence +
exit 0 + arg validation + that it never mutates the catalog, both status views
in text and JSON, and that `mcp.seed` / the hook / the seed subcommands are
really gone. New `tests/doctor-retired-codex-delegate.sh` (11 assertions):
`report_retired_codex_delegate_entries` extracted from `docker-run.sh` and run
against a fixture catalog in a temp HOME, a static guard that the doctor mode
block actually calls it, the catalog untouched afterwards, and silent
degradation without `python3`. Whole Python suite `PYTHONPATH=scripts python3
-m unittest discover -s tests -p 'test_*.py'` = **903 tests OK** (910 before
minus the 20 seed tests plus 13). Shell: `tests/help.sh`, `tests/naming.sh`,
`tests/test_provisioning.sh`, `tests/shared-config.sh`,
`tests/doctor-retired-codex-delegate.sh` all pass (there are no `tests/mcp*.sh`).
`shellcheck docker-run.sh install.sh scripts/mcp-cli.sh
scripts/hooks/boxa-identity-context.sh scripts/job.sh
tests/doctor-retired-codex-delegate.sh` clean at all levels. `ruff check
scripts/mcp/{catalog,cli}.py`: 51 findings vs 50 before, the single addition
being the package's existing `Optional[...]` (UP045) style.

**Grep residue** (`grep -rn "codex mcp-server\|codex-delegate\|ensure-codex-delegate"`,
excluding `.scratch`/`.git`): ADR 0037 and ADR 0021/0028 historical text,
`docs/mcp.md` + `docs/jobs.md` + `skills/boxa/SKILL.md` pointers, the
doctor/status strings in `scripts/mcp/{catalog,cli}.py` and
`scripts/mcp-cli.sh`, `docker-run.sh`'s step, and their two test files. Beyond
the expected list, deliberately kept: `tests/test_mcp_trust.py` (15) and
`tests/test_mcp_integration.py` (5) use the `codex mcp-server` entry as the
agent-trusted broker/relay fixture, and `scripts/mcp/activation.py` (1) still
refuses Codex self-activation for it. None of these exercise the seed; they
cover trust behaviour that is unchanged and still applies to a leftover entry,
so rewriting them would have weakened real coverage. All three now carry a
comment saying the entry is retired by ADR 0037.

**Host verification left for the user** (the `boxa` CLI runs on the host, not
in this Container). On a host whose catalog still carries the entry:

```sh
boxa doctor                 # expect the WARNING block + 'boxa mcp remove <entry>'
boxa mcp status             # same explanation in the profile view
boxa mcp status --project <path>   # and in the Project view
boxa update                 # expect NO codex-delegate seed offer any more
boxa mcp remove codex-delegate     # then `boxa doctor` is silent again
```

The rendered text itself is proven by the tests above; what remains unproven
from inside is only that the real `boxa` entry point reaches the step (asserted
statically against the doctor mode block).


### 2026-09-12 — host verification (Prompt B, host session)

Run on the WSL host with the installed copy at `451e3c4` and the old
`codex-delegate` catalog entry still present (kept on purpose until issue 09).

- `boxa doctor`: prints the WARNING block ("MCP catalog entry 'codex-delegate'
  runs 'codex mcp-server', which current Codex releases no longer provide …
  Remove it with: boxa mcp remove codex-delegate") between the keep-awake
  section and "Host provisioning is healthy."
- `boxa mcp status` and `boxa mcp status --project ~/Projekty/boxa`: the same
  block after the table; the entry itself still lists as `ready / activated`.
- `boxa update`: "Already up to date. No changes, skipping rebuild." and no
  codex-delegate seed offer.

`boxa mcp remove codex-delegate` deliberately not run yet (interim state).
