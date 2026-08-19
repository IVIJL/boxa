# ADR 0027 — Box-to-box visibility and in-container dev URLs via Traefik

- **Status:** accepted
- **Date:** 2026-08-19
- **Builds on:** ADR 0007 (local DNS and Traefik routing), ADR 0008
  (mkcert HTTPS), ADR 0019 (Cross-boxa connections for DinD workloads)

## Context

Every boxa Container joins the shared `devproxy` network. Processes in the
outer Containers can therefore resolve and reach one another as
`boxa-<name>:<port>`, while inner DinD containers need the managed forward from
ADR 0019. This direct outer-Container visibility existed in code, but was not
recorded as a deliberate trust decision; the **Cross-boxa connection** and
**Host connection** terminology could imply that all cross-boundary traffic
requires a Connection.

Dev URLs had a separate inconsistency. On the host, both
`<port>.<name>.test` and `<port>.<name>.127.0.0.1.sslip.io` resolve to host
loopback and enter Traefik on ports 80/443. That loopback answer is wrong from
inside a Container, where it identifies the Container itself. A Container
could use `localhost:<port>` for its own service or the Docker name for another
box, but could not consistently use the same HTTP(S) dev URLs as the host.

## Decision

Box-to-box visibility is the default. Outer boxa Containers share `devproxy`
with no firewall isolation from one another. A process in one box may reach a
published service in another directly at `boxa-<name>:<port>`, or reach any
live box's HTTP(S) service through its dev URL and Traefik. No Connection is
needed for either outer-Container path. The firewall accepts the actual
`devproxy` subnet discovered from the primary interface's connected route,
including its real prefix (currently `/16`), rather than deriving a `/24` from
the gateway address.

The in-Container dnsmasq answers the `test` and
`127.0.0.1.sslip.io` suffixes with Traefik's `devproxy` IP. The entrypoint
resolves `boxa_traefik` through Docker embedded DNS at `127.0.0.11` before the
firewall lockdown, then writes dnsmasq `address=` rules. A firewall reload
refreshes those answers through the permanent dnsmasq-owner DNS exception. If
Traefik is absent, no rules are written and startup/reload remains a graceful
no-op for these suffixes.

For HTTPS, only mkcert's public `rootCA.pem` is bind-mounted read-only. The
entrypoint installs it into the Container trust store on every start so CA
rotation is picked up, and the Container exports `NODE_EXTRA_CA_CERTS`,
`REQUESTS_CA_BUNDLE`, and `SSL_CERT_FILE` for common runtimes. The private CA
key is never mounted. Hosts without mkcert keep the existing HTTP-only,
no-op path.

## Considered options

- **Keep direct Docker names as the only cross-box path** — functional for raw
  TCP, but forces tools and application configuration to use different HTTP
  origins inside and outside Containers. Rejected.
- **Resolve dev URLs through the host-side `boxa_dns` container** — its host
  answer is loopback, which has the wrong meaning inside a Container. The
  in-box resolver instead answers the two suffixes directly with Traefik's IP.
- **Isolate each box on `devproxy` and require explicit Connections** — a
  stronger boundary, but incompatible with the established direct
  outer-Container workflow and insufficient for dev URLs without additional
  proxy exceptions. Rejected; `devproxy` is explicitly a shared trust zone.
- **Preserve explicit-port dev URLs inside Containers** — forms such as
  `3000.name.test:3000` target Traefik's IP, but Traefik listens only on 80/443.
  Publishing or forwarding every application port would add a second routing
  model. Rejected in favour of one HTTP(S) ingress path.

## Consequences

- The normal dev URL forms work from a Container for its own and other live
  boxes, over HTTP or trusted mkcert HTTPS, without crossing the Allowlist or
  using a Connection.
- `devproxy` is not a security boundary between outer Containers. Any box can
  connect directly to another box's published ports; users must not treat a
  Connection as an access-control grant for that path.
- Inner DinD containers remain outside `devproxy` and still use a Cross-boxa
  connection (ADR 0019) to reach another box.
- Explicit-port forms such as `3000.name.test:3000` no longer work inside
  Containers. Use `localhost:<port>` for the current box, or
  `boxa-<name>:<port>` for direct access to another box.
