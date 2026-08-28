# 02 — Trust the mkcert root CA inside boxa Containers

Status: done

## Parent

None — covered by the new ADR written in issue 04. Related: the mkcert
HTTPS setup on the host (`boxa https`).

## What to build

With issue 01, dev URLs resolve to Traefik from inside a box. On an HTTPS
host setup, Traefik 301-redirects :80 to https permanently, so in-box
clients need to trust the mkcert root CA or every dev URL dies on a
certificate error. An https→http downgrade is not possible (the TLS
handshake precedes any HTTP response), so shipping the CA is the only
clean path.

At Container create/start, install the host's mkcert root CA — the
**public certificate only** (`rootCA.pem`); the CA private key never
leaves the host:

- Copy it into the container trust store
  (`/usr/local/share/ca-certificates/…`) and run
  `update-ca-certificates`.
- Export env vars for ecosystems that ignore the system store:
  `NODE_EXTRA_CA_CERTS` (node/fetch) and
  `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE` (python requests/httpx), pointing
  at the installed CA path, in the shell environment agents inherit.
- On an HTTP-only host setup (no mkcert / `boxa https` never run), the
  step is a silent no-op.

## Acceptance criteria

- [ ] `curl https://<port>.<other>.test` from inside a box succeeds
      without `-k` against a live box on an HTTPS host setup.
      (deferred host verification — needs a live recreated Container on
      an HTTPS host setup)
- [ ] Same for the box's own https dev URL.
      (deferred host verification)
- [ ] `node -e 'fetch(...)'` and python `requests.get(...)` succeed
      against an https dev URL without extra flags.
      (deferred host verification)
- [x] Container create/start works unchanged on a host without mkcert
      (no error, no cert installed). Covered by
      `tests/mkcert-container-trust.sh` ("missing mkcert is a no-op",
      "missing rootCA.pem is a no-op").
- [x] The mkcert CA private key is not mounted or copied anywhere into
      the container. Covered by `tests/mkcert-container-trust.sh`
      ("private CA key is never mounted") — `docker-run.sh` mounts only
      `$CAROOT/rootCA.pem`, never `rootCA-key.pem`.

## Implementation notes

- `docker-run.sh`: `_boxa::mkcert_root_ca` resolves the host's public
  root CA via `lib/mkcert.sh`'s `_mkcert::caroot`; `_boxa::append_mkcert_ca_args`
  bind-mounts it read-only at `/run/boxa/mkcert-rootCA.pem` and exports
  `NODE_EXTRA_CA_CERTS` / `REQUESTS_CA_BUNDLE` / `SSL_CERT_FILE` pointing at
  the in-container trust path. Silent no-op when mkcert/CAROOT/rootCA.pem
  is absent. `restart_exited_container` recreates a Container that predates
  HTTPS being enabled so it picks up the CA mount.
- `scripts/boxa-entrypoint.sh`: root phase installs the mounted CA into
  `/usr/local/share/ca-certificates/` and runs `update-ca-certificates` on
  every start (create + restart), so CA rotation on the host is picked up.
- `tests/mkcert-container-trust.sh`: new unit-style test extracting and
  exercising the docker-run.sh helpers plus asserting the entrypoint wiring.

## Blocked by

- 01-inbox-dev-url-dns-to-traefik.md (end-to-end verification needs dev
  URLs routed to Traefik).

## Comments
