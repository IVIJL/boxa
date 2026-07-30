# ADR 0023 — Host connections via a durable scoped firewall slot

- **Status:** accepted
- **Date:** 2026-07-30

## Context

Some host-side services legitimately need to hear from the workloads
running inside boxes. The motivating case is a keep-awake daemon: agent
hooks living in the shared `~/.claude` (ADR 0002) signal busy/idle over a
tiny HTTP API on a host port, and the host must not sleep while any box's
agent is working. The same shape covers any "our listener app on the
host" — a local LLM server, a host-side database, a notification sink.

The obvious route — `boxa allow host.docker.internal` — does not work,
and cannot be made to work cleanly:

- The **Allowlist** is a domain gate. dnsmasq populates the
  `allowed-domains` ipset at lookup time inside the container, but the
  runtime ipset add never lands (the resolver runs unprivileged), so in
  practice entries flow from the host-side pre-resolve at reload — and
  `host.docker.internal` does not resolve on the host at all. The entry
  sits in the config while every packet still hits the final REJECT: a
  non-functional hole.
- Even if it resolved, a domain-gated allow of the Docker Desktop magic
  IP would open **every** port the host forwards, not the one service.

Options considered:

1. **Fix runtime ipset population for this name.** Deepens the resolver's
   privileges for a case that is not a domain-trust decision at all, and
   still opens all ports on the magic IP.
2. **A shared relay sidecar on `devproxy`** (a plain container with a
   static IP, exempt from the box firewall, forwarding to the host).
   Verified working, but it duplicates boxa's own machinery at lower
   quality: hardcoded IP, single-subnet coupling, no persistence, no
   status surface, invisible to `boxa connections`.
3. **A Host connection: `boxa connect` machinery plus a durable, scoped
   firewall slot.** Boxa already owns every needed part: per-source socat
   forwards with TSV persistence and start-time replay (ADR 0019), a
   session-scoped single-IP single-port ACCEPT inserted before the final
   OUTPUT REJECT (`start-agent-browser-host-allow.sh`, ADR 0010), and the
   agent-browser broker's platform handling (host-owned-IP bind test,
   host-side relay, scoped ufw INPUT slot on native Docker).

## Decision

`boxa connect host <port> [local-port]` creates a **Host connection**: a
persisted per-source forward whose target is the host, carried by a
firewall exception scoped to exactly one IP and one TCP port.

- **Transport.** Inside the box, socat listens on
  `127.0.0.1:<local-port>` (inner DinD containers use
  `10.0.2.2:<local-port>`, as in ADR 0019) and dials the host address.
  The container-side OUTPUT chain gets an
  `ACCEPT -p tcp -d <host-ip> --dport <port>` inserted before the final
  REJECT — the ADR 0010 slot, made durable.
- **Local port.** Defaults to the host port itself, so clients configure
  "same port as on the host". If taken at creation time, two
  deterministic fallbacks from the 15000–15999 connect pool (ADR 0019
  checksum slot and slot+1) are tried; if all three fail, the user is
  prompted (ADR 0006). The chosen port is persisted; replay never scans
  or prompts. A port stolen later inside the box surfaces as `down` in
  `boxa connections`.
- **Scope.** Per-box by default. `--all` records the connection globally
  and every Container applies it at start — for host services that any
  box may signal (the keep-awake case: hooks are shared across boxes via
  ADR 0002, so a per-box grant would leave new projects silently mute).
- **Platform handling is behavioral, not platform-guessing.** At start,
  resolve `host.docker.internal` (IPv4) inside the container — the
  `--add-host=host-gateway` mapping already covers native Docker — and
  test whether the host can bind the resolved IP. VM-owned IP (Docker
  Desktop on WSL2, macOS, or Linux): the magic forwarding does the
  host-side work; nothing to add. Host-owned IP (native Docker): start a
  host-side socat relay bound to exactly that IP:port forwarding to the
  service's loopback, and open an equally scoped ufw INPUT slot (the
  ADR 0010 issue-14 slot, made durable). The IP is re-resolved on every
  Container start; nothing is pinned across restarts.
- **Lifecycle.** The persisted entry is the single source of truth.
  Container start replays forward + container slot (+ host relay + ufw
  slot where applicable); `boxa connect rm` and uninstall tear all of it
  down; re-running `add` is idempotent repair. `boxa connections` lists
  Host connections with their scope and a live probe of the forward;
  `boxa doctor` reports (never silently repairs) a broken one, matching
  its Elective-step posture.
- **Only the host grants it.** Creation, widening, and removal happen via
  the host-side CLI and `docker exec -u root`; the agent user inside the
  Container has no path to any of them (ADR 0003).

## Rationale

- **The firewall stays honest.** The Allowlist keeps meaning "domains the
  container may reach"; reaching one host port is a different trust
  statement and gets its own, narrower primitive. The exception admits
  one IP:port — not a domain, not a magic-IP wildcard.
- **One mental model.** "Pull a remote service onto a stable local
  address" is what `boxa connect` already means; `host` is a target, not
  a second CLI. Persistence, status, port allocation, and the
  inner-container consumption path come for free.
- **The guarantee is the port, not the app.** Whatever listens on that
  host port is reachable from the box — documented, and mitigated by the
  service binding only loopback + bridge interfaces (its side of the
  contract).

## Consequences

**Positive:**

- Host services become reachable from boxes through a discoverable,
  inspectable, persistent, narrowly scoped path — no non-functional
  Allowlist entries, no hand-rolled sidecar relays.
- Global scope makes "any box may signal" services (keep-awake) work in
  every present and future project with one command.

**Negative / limitations:**

- A durable firewall exception per Host connection: single IP:port, but
  standing — on native Docker including a standing host-side ufw slot and
  relay process. Visible in `boxa connections`, cleaned by `rm` and
  uninstall.
- Anything that binds the allowed host port impersonates the service;
  authentication is the service's job, not boxa's.
- Multi-instance semantics of the target service (e.g. one box idles
  while another still works) are the service contract's problem —
  heartbeat/TTL APIs are recommended over pure busy/idle toggles.
- A broken persisted forward emits a repair warning during Container start or
  attach but does not block shell access; explicit `boxa connect` add still
  fails when the forward cannot be established.

## References

- ADR 0019 — cross-boxa connect machinery this extends (persistence,
  replay, port pool, `10.0.2.2` consumption).
- ADR 0010 / `scripts/start-agent-browser-host-allow.sh` — the scoped
  container-side ACCEPT slot; the broker's host-owned-IP bind test,
  host relay, and scoped ufw INPUT slot this makes durable.
- ADR 0002 — shared `~/.claude`, why signal clients exist in every box.
- ADR 0001 — the dnsmasq/ipset Allowlist model whose domain gate this
  deliberately does not stretch.
- `CONTEXT.md` — **Cross-boxa connection**, **Host connection**.
