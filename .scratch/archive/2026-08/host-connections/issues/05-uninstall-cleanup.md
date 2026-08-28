# 05 — Uninstall sweeps Host connections

Status: done

## Parent

ADR 0023 — Host connections via a durable scoped firewall slot.

## What to build

Boxa uninstall leaves no Host-connection residue on the host: it
enumerates every persisted Host connection (per-box and `--all`) and
tears down all host-side artifacts — relay processes, ufw INPUT slots —
and the persisted entries themselves. Container-side pieces need no
sweep (containers are removed by uninstall anyway).

Teardown must be the same code path `boxa connect rm` uses, not a
parallel implementation, so the two cannot diverge (mirroring how
provisioning shares steps across install/update/doctor).

## Acceptance criteria

- [x] Uninstall with per-box + global Host connections present removes
      every relay, every ufw slot, and all persisted entries.
- [x] Uninstall with none present changes nothing and prints nothing
      extra.
- [x] The sweep reuses the `rm` teardown path (one implementation).
- [x] Shell tests cover both scenarios; `shellcheck` clean.

## Blocked by

`01-connect-host-docker-desktop.md`, `04-native-docker-path.md`

## Comments

Done in fa413c9. The `rm` command body moved into `remove_host_connection`;
the uninstall sweep (`sweep_host_connections`, run in the `uninstall` MODE
branch before exec'ing `build.sh --uninstall`) iterates every per-box TSV +
`_all.tsv` and calls the same function. Minor behavior tightening: the
`rm --all` container loop now aborts on a container-side stop failure
(`|| return 1`) where it previously continued.
