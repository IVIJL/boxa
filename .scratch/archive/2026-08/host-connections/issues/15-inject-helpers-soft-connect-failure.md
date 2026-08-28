# 15 — Inject connection helpers into old-image boxes; keep-awake enable survives partial connect failure

Status: done

## Parent

ADR 0023 (Host connections). Follow-up found during live WSL verification
of `boxa keep-awake enable` (2026-08-07).

## What to build

Two related hardenings around `boxa connect host --all` against boxes
still running a pre-Host-connection image:

1. **Helper injection.** `start_host_connection` / `stop_host_connection`
   exec `/usr/local/bin/start-host-connection-allow` (and `stop-…`) inside
   the source container. Containers started from an image built before the
   feature lack both helpers, so every per-box application fails with
   `stat …: no such file or directory`. Before exec'ing, check the helpers
   exist and are executable; if not, inject both from
   `$BOXA_DIR/scripts/*.sh` via `docker cp`, then `chown root:root` +
   `chmod 755`. The helpers are self-contained (plain iptables against the
   final OUTPUT REJECT rule, present in old firewalls too), so injection is
   safe without a container restart.

2. **Soft connect failure in keep-awake enable.** `keep_awake::enable`
   currently rolls back the daemon, autostart, and tray when
   `boxa connect host … --all` fails in ANY box — a working daemon gets
   uninstalled because one stale box could not take the firewall slot.
   Instead: keep daemon + autostart + tray installed, record enabled
   state, warn which step failed, tell the user to re-run
   `boxa keep-awake enable` (idempotent; retries the connection) once the
   boxes are fixed, and exit non-zero. Full rollback remains for real
   daemon failures (build, install, start, unreachable, state write).
   Update the install.sh summary line that claims "no partial state left
   behind".

## Acceptance criteria

- [ ] `boxa connect host <p> --all` succeeds against a running box whose
      image predates the helpers (helpers appear root-owned, 0755, and the
      OUTPUT ACCEPT rule lands above the final REJECT).
- [ ] `boxa connect rm host <p> --all` likewise works against such a box.
- [ ] Injection failure produces a per-box error naming the container and
      does not abort the other boxes.
- [ ] `boxa keep-awake enable` with a failing box leaves the daemon
      running, autostart + tray installed, state recorded, exits non-zero
      with retry guidance; `boxa keep-awake status` stays truthful.
- [ ] Daemon-level failures still roll back completely.
- [ ] shellcheck clean on both edited scripts.

## Blocked by

None — can start immediately.

## Comments

2026-08-07 (agent): Implemented, uncommitted. `ensure_host_connection_helpers`
in docker-run.sh (probe via `docker exec sh -c 'test -x …'`, inject via
`docker cp` from `$BOXA_DIR/scripts`, `chown root:root` + `chmod 755`),
called from both `start_host_connection` and `stop_host_connection`.
`keep_awake::enable` no longer rolls back on connect failure: state is
recorded, summary says "Host connection INCOMPLETE", retry guidance printed,
exit 1; daemon-level failures still roll back. install.sh summary line
updated ("setup incomplete; re-run"). Tests: connect-host.sh +4 injection
assertions (mock switch `BOXA_CONNECT_TEST_HELPERS_MISSING`), uninstall
counters qualified with the IP so helper probes are not counted;
keep-awake.sh rollback block rewritten to the keep-install contract.
149 + 160 tests pass, shellcheck clean on all edited files.

2026-08-07 (agent, later): Committed as 7e75e46 after 4 review rounds
(state gained `connection=ok|incomplete`, probe/status honour it; global
rm continues past per-box failures). Live retest: injection worked for
both old boxes, but boxa-boxa failed with only the generic
"Failed to start global Host connection in boxa-boxa." — the failing
step was silent. Follow-up (uncommitted): loud error messages on the
previously silent paths (ownership check indeterminate, stale DD-state
cleanup, container-side forward start/stop). Root cause of the boxa-boxa
failure still unknown; a leftover forward from the 08:47 rolled-back
attempt was found alive in the box (old `connect rm --all` aborted at
the first helper-less box and never cleaned boxa-boxa).
