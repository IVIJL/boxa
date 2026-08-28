# 16 — Onboarding: `agent-identity` provisioning step (key part)

Status: done

## Parent

[PRD](../PRD.md) F5 (key half); ADR 0032 decision 6.

## What to build

A category-B provisioning step `agent-identity`
(`scripts/ensure-agent-identity.sh`, registered in the provisioning
registry) following the `ensure-ssh-gate.sh` reference shape: verbs
`offer|probe|enable`, `--interactive`/`--non-interactive` seams, an
`agent-identity-seen` dismissal marker, default-N prompt stating the
benefit/risk in one sentence. Probe: `ok` = Agent key exists (generated
or adopted) and at least one usage is configured; `declined` = seen
marker; `missing` = neither — probe and repair read the same source of
truth so doctor and --fix cannot disagree. The interactive wizard offers
the three-way key entry: generate new (recommended) / pick an existing
key via the key picker / skip, then prints how to continue per forge
(`boxa forge`, forge checklists land in issue 17).

## Acceptance criteria

- [x] `boxa doctor` reports ok/declined/missing correctly in all three
      states; repair re-runs the wizard. — `tests/test_provisioning.sh` (agent-identity probe/fix cases) + `tests/test_ensure_agent_identity.sh` green
- [x] Non-interactive runs never prompt, never mark seen, print the
      follow-up command (mcp-onboarding pattern). — covered by `tests/test_ensure_agent_identity.sh` ("non-interactive offer/repair..." cases)
- [x] Adopting an existing key registers it as the Agent key without
      copying or reading private material. — `_boxa::ssh_adopt_agent_key` pointer-file approach; covered by `tests/ssh.sh` adoption cases and pty test `test_adopt_existing_registers_path_without_touching_private_key`
- [x] Interactive flow tested via real pty; no stubbed consent seams. — `tests/test_agent_identity_pty.py`, 4/4 pass (run via `python3 -m unittest`, pytest unavailable on this box — no root/pip to install it; same test file, live host should also confirm under pytest)
- [x] shellcheck clean. — shellcheck 0.10.0, no findings on install.sh, lib/provisioning.sh, docker-run.sh, lib/ssh.sh, lib/forge.sh, scripts/ensure-agent-identity.sh, and touched test files

## Blocked by

- [11 — Agent key, dedicated agent, gate state `agent`](11-agent-key-dedicated-agent-gate-state.md)

## Comments
