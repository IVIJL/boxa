# 01 — `boxa connect host`: per-box Host connection on Docker Desktop

Status: done

## Parent

ADR 0023 — Host connections via a durable scoped firewall slot.

## What to build

The tracer bullet for the **Host connection** primitive: `boxa connect
host <port> [local-port] [--name <label>]` creates a persisted forward
from a box to a service on the host, on the Docker Desktop path (WSL2,
macOS, Docker Desktop on Linux — the branch where `host.docker.internal`
is VM-routed and no host-side work is needed).

End-to-end behaviour:

- `host` is a reserved connect target alongside box names. The entry is
  persisted in the source box's connection state with target `host`, the
  host port, the chosen local port, and the optional `--name` label.
- On add and on every Container start (replay), boxa resolves
  `host.docker.internal` to IPv4 inside the container, inserts a durable
  container-side firewall exception scoped to exactly that IP and TCP
  port (before the final OUTPUT REJECT, same slot shape as the
  agent-browser session exception), and starts the in-box socat forward
  `127.0.0.1:<local-port>` → resolved IP:`<port>`. Inner DinD containers
  consume it at `10.0.2.2:<local-port>`, as with any Cross-boxa
  connection. The IP is re-resolved on every start; nothing is pinned.
- Removal (`boxa connect rm` / the existing disconnect flow) deletes the
  firewall exception, kills the forward, and drops the persisted entry.
- `boxa connections` lists Host connections with target `host` and the
  label, alongside cross-boxa forwards, with the existing STATUS column.
- Help output (`boxa help`, the connect usage text) documents the `host`
  target and `--name` precisely enough that an agent reading only the
  help can tell the user the exact command to run.

For this slice the local port may be taken verbatim from the explicit
argument or default naively to the host port; the full
fallback-and-prompt selection is issue 02.

## Acceptance criteria

- [x] `boxa connect host 17777` from a project makes
      `curl http://127.0.0.1:17777/` inside the box reach a listener on
      the host; the firewall exception admits only that IP:port
      (a second host port stays REJECTed).
      *(Rule shape and exact-scope covered by stubbed shell tests; live
      HTTP traversal + second-port REJECT verifiable only on a real
      host — deferred to host verification.)*
- [x] The connection and its firewall exception survive `boxa stop` +
      start via replay, with the host IP re-resolved.
      *(Replay + fresh-IP re-resolution covered by stubbed tests; real
      stop/start cycle deferred to host verification.)*
- [x] `boxa connect rm` removes forward, firewall rule, and persisted
      entry; a subsequent start does not resurrect any of them.
- [x] Re-running the same `add` is idempotent (no duplicate rules,
      forwards, or entries).
- [x] `boxa connections` shows the entry with target `host` and the
      `--name` label.
- [x] Nothing inside the Container can create, widen, or remove the
      exception (host-side CLI + root exec only; helper scripts are
      root-owned in /usr/local/bin, invoked via `docker exec -u root`).
- [x] Help text covers `connect host`, `[local-port]`, and `--name`.
- [x] Shell tests cover add/replay/rm/idempotency and the help text;
      `shellcheck` clean.

## Blocked by

None — can start immediately.

## Comments
