# 03 — `--all` scope: a Host connection every box applies

Status: done

## Parent

ADR 0023 — Host connections via a durable scoped firewall slot.

## What to build

Global scope for Host connections: `boxa connect host <port> --all`
records the connection once, globally, and **every** Container applies
it at start — forward, firewall exception, and all. This is for host
services that any box may signal (the keep-awake case: agent hooks are
shared across all boxes, so a per-box grant would leave a newly created
project silently unable to signal).

- Global entries live in their own persisted state next to the per-box
  files and are replayed by every Container start, including boxes
  created after the entry.
- `boxa connections` shows global entries in every box with the scope
  clearly marked, so the standing exception is visible everywhere it
  applies.
- Removal of a global entry (`rm --all` or equivalent) tears it down in
  running boxes and stops future replay.
- Per-box remains the default; `--all` is a deliberate widening, and the
  help text says so.

## Acceptance criteria

- [x] `boxa connect host 17777 --all` makes the forward work in two
      different running boxes and in a box started afterwards.
- [x] `boxa connections` marks the scope in every box.
- [x] Global removal cleans running boxes and future starts.
- [x] A per-box and a global entry for different ports coexist without
      interference.
- [x] Help documents `--all` and its trust implication.
- [x] Shell tests cover global replay, coexistence, and removal;
      `shellcheck` clean.

## Blocked by

`01-connect-host-docker-desktop.md`

## Comments

Done in commit a1a741b. Note: the two-running-boxes + future-box criterion is proven via the mocked-docker shell test harness (tests/connect-host.sh), not against live containers.
