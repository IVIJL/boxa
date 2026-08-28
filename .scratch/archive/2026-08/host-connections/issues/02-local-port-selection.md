# 02 — Host connection local-port selection: mirror, fallbacks, prompt

Status: done

## Parent

ADR 0023 — Host connections via a durable scoped firewall slot.

## What to build

Deterministic local-port selection for `boxa connect host`, decided once
at creation time and persisted:

- Default local port = the host port itself, so clients configure "same
  port as on the host".
- If that port is already bound inside the box at add time, try two
  deterministic fallbacks drawn from the 15000–15999 connect pool (the
  ADR 0019 checksum slot for this connection, then slot+1).
- If all three are taken, prompt the user interactively for a free port
  (picker conventions per ADR 0006). An explicit `[local-port]` argument
  always wins and skips the scan.
- The chosen port is persisted with the entry. Replay at Container start
  never scans and never prompts — it uses the persisted port; if
  something inside the box has stolen it since, the connection shows as
  `down` in `boxa connections` (existing semantics), it does not
  silently move.

## Acceptance criteria

- [x] Free host port → local port equals host port.
- [x] Host port taken → first checksum fallback; both taken → second;
      the choice is stable across re-runs (deterministic).
- [x] All three taken → interactive prompt; the entered port is
      validated as free and persisted.
- [x] Replay uses only the persisted port; a stolen port yields `down`,
      never a rescan or prompt.
- [x] Help text documents the selection order so an agent can predict
      the resulting address.
- [x] Shell tests cover all four selection outcomes; `shellcheck` clean.

## Blocked by

`01-connect-host-docker-desktop.md`

## Comments

- Done in commit ec9233f. `slot+1` wraps 15999 -> 15000, consistent with
  the ADR 0019 pool semantics. "Taken" = actually bound inside the box
  (listener probe) OR already used by a persisted connection row.
