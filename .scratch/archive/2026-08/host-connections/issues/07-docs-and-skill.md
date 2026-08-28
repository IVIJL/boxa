# 07 — Docs + boxa agent skill for Host connections

Status: done

## Parent

ADR 0023 — Host connections via a durable scoped firewall slot.

## What to build

User- and agent-facing documentation so a Host connection is
discoverable exactly where people hit the wall:

- Networking docs gain a "Host connections" section next to the
  cross-boxa one: what it is, the trust statement (one IP:port, standing
  exception, port-not-app guarantee), per-box vs `--all`, the native
  Docker consequences, and worked examples including `--name`.
- The boxa agent skill and the in-container SessionStart guidance teach
  the agent the third gate: today they explain the Allowlist and the
  Agent-browser gate; container→host traffic failures should now lead
  the agent to recommend the exact host-side command
  (`boxa connect host <port> --name <label> [--all]`) instead of a
  futile `boxa allow host.docker.internal`.
- Cross-references: ADR 0023 from the docs, glossary terms
  (**Host connection**, **Cross-boxa connection**) used consistently.

## Acceptance criteria

- [x] Networking docs section exists and matches shipped CLI behaviour
      (flags, selection order, scopes).
- [x] The boxa skill and SessionStart context mention Host connections
      as the remedy for container→host service traffic, with the exact
      command shape.
- [x] `boxa allow host.docker.internal` guidance is nowhere recommended.
- [x] Help-text tests (existing help suite) extended where output
      changed; `shellcheck` clean.

## Blocked by

`01-connect-host-docker-desktop.md` … `06-probe-and-doctor.md` (final
wording needs all behaviour landed).

## Comments

2026-07-30 — Done in c8be0e5 (docs/networking.md "Host connections"
section, skills/boxa/SKILL.md third gate + troubleshooting entry,
scripts/hooks/boxa-identity-context.sh SessionStart guidance). No
help-text test changes needed: CLI/help output was untouched; existing
help.sh already covers the connect host help lines. Facts verified
against docker-run.sh (selection order incl. `all:host:port` seed,
statuses up/host down/forward down/stopped, doctor report-only).
