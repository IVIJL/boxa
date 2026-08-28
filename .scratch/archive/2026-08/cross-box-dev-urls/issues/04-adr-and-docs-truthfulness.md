# 04 — ADR for box-to-box visibility + docs/hook truthfulness

Status: done

## Parent

None — this issue creates the ADR.

## What to build

Write a new ADR recording two decisions that are now deliberate:

1. **Box-to-box visibility is the default**: all boxa Containers share the
   `devproxy` network with no firewall isolation between them; a box may
   reach another box directly (`boxa-<name>:<port>`) or via dev URLs
   through Traefik. Today this is true in code but recorded nowhere as a
   decision (the Connections gates cover DinD-to-box and container-to-host,
   not box-to-box).
2. **In-box dev URLs route through Traefik** (the issue 01 + 02 mechanism:
   dnsmasq `address=` to the Traefik IP, mkcert root CA trust), including
   the accepted trade-off that explicit-port URL forms stop working inside
   containers.

Then align the existing prose with reality:

- ADR 0024 claims the in-box dnsmasq reaches `boxa_dns` over the devproxy
  network — the code forwards to Docker embedded DNS (127.0.0.11) and falls
  through to the host resolver. Correct the claim (and its echo in
  CONTEXT.md's DNS degradation section) to describe the real chain and the
  new Traefik-IP answers.
- The SessionStart identity hook says dev URLs "resolve locally" — reword:
  dev URLs work from inside the Container for the box's own **and other
  live boxes'** services via Traefik; note the explicit-port caveat and the
  direct `boxa-<name>:<port>` alternative.
- `docs/networking.md` mentions cross-box reachability in passing — link
  it to the new ADR.
- CONTEXT.md: add box-to-box visibility to the domain description where
  Connections are defined, so the glossary distinguishes the three paths
  (box↔box direct, DinD→box Connection, container→host Connection).

## Acceptance criteria

- [x] New ADR under `docs/adr/` records both decisions with the trade-offs
      above. (`docs/adr/0027-box-to-box-visibility-and-in-container-dev-urls.md`)
- [x] ADR 0024 and CONTEXT.md no longer claim the in-box dnsmasq talks to
      `boxa_dns` directly.
- [x] SessionStart hook text describes cross-box dev URL behaviour
      accurately (English strings only).
- [x] `docs/networking.md` and CONTEXT.md reference the new ADR where
      cross-box access is mentioned.

## Blocked by

- 01-inbox-dev-url-dns-to-traefik.md
- 02-mkcert-root-ca-trust-in-container.md

## Comments
