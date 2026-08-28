# 01 — Sectioned overview help

Status: done

## Parent

None — the help output is not covered by an ADR. Interactive picker
conventions (ADR 0006) are unaffected.

## What to build

Restructure the `boxa help` overview from one flat ~115-line list into
sectioned output so every command is findable at a glance (motivating
incident: the user overlooked `boxa mem` entirely).

Sections, in this order: **Containers** (start/attach, ls, mem, stop,
remove), **Ports & connect** (port, ports, connect, connections),
**Firewall** (allow, deny, blocked, allow-for), **Agent-browser** (one
entry for the whole command family), **MCP**, **DNS** (dns-install,
dns-status, dns-uninstall), **Maintenance** (build, update, doctor, prune,
uninstall, claude-token, sync-skills), **Editors & misc** (cursor, code,
clip, ssh-config).

Per-entry budget: one line, two only when the syntax itself needs it. The
overview loses all "See ADR NNNN" references and multi-line behavioural
prose (passive allow semantics, apex↔www pairing, doctor step semantics,
…) — that detail moves to per-command help in issue 02 and must not be
deleted from the codebase, only relocated out of the overview. Until issue
02 lands it may live in an unreferenced heredoc or comment; the overview
itself must already be clean.

The Examples block shrinks to the ~5 most common invocations. The Build
flags block folds into the Maintenance section or Examples.

## Acceptance criteria

- [x] Overview groups commands under the section headings above; every
      command currently listed is still present exactly once
- [x] No entry exceeds two lines; no ADR references and no behavioural
      prose paragraphs remain in the overview
- [x] Examples reduced to ~5 most common invocations; Build flags block
      merged away
- [x] Existing tests that assert on help output updated and passing
      (no tests/*.sh assert on help output — verified by grep; smoke check
      `bash tests/resources.sh` passing)
- [x] `shellcheck` clean on touched scripts (including info-level)
      (preexisting SC1091 info findings on runtime-resolved $BOXA_DIR
      sources suppressed via file-level directive — false positives)

## Blocked by

None — can start immediately.

## Comments
