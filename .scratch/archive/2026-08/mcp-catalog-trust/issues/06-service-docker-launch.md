# 06 — Service-isolated Docker MCP launch boundary

Status: done

## Parent

ADR 0021 — Project-selected MCP catalog and agent-trusted execution.

## What to build

Keep Docker-packaged MCP servers functional without giving a rogue
service-isolated server the node-owned raw Docker socket. A constrained
node-side launch adapter starts only the catalog-authorized image with its
Project mount, declared environment, and stdio attachment. The nested MCP can
read/write Project source but cannot request arbitrary mounts or control the
daemon. An MCP needing Docker control during execution must be agent-trusted.

For compatibility, allow MCP secret injection into a Docker-packaged
service-isolated server while exposing the accepted temporary limitation:
`node`, as daemon owner, can inspect the container environment. First activation
requires acknowledgement; non-interactive use requires
`--accept-degraded-secret-isolation`; list/status/doctor keep the degradation
visible.

## Acceptance criteria

- [x] Direct-process service-isolated servers no longer inherit or reach a raw
      node Docker socket by known path, environment, or inherited descriptor.
- [x] Docker-packaged MCP starts through an allowlisted structured launch plan,
      relays stdio, and receives only the Project mount and declared resources.
- [x] Image/command tricks cannot add `/home/node`, the Docker socket, arbitrary
      host paths, privileged mode, host namespaces, or extra capabilities.
- [x] The server can read/write Project source but cannot launch or inspect other
      containers.
- [x] Agent-trusted servers retain full node Docker behavior.
- [x] Secret-bearing Docker activation is atomic on refusal/cancel and requires
      the interactive acknowledgement or exact non-interactive acceptance flag.
- [x] `list`, status output, and doctor report `degraded-secret-isolation` without
      displaying secret names unnecessarily or any values.
- [x] Tests use a fake/stub Docker API or command seam and require neither
      network nor pulling an image.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes after shell changes.

## Blocked by

- `02-claude-service-activation.md`
- `03-readiness-and-install.md`

## Comments

- Implemented a snapshot-validated node-side Docker adapter. Its accepted
  grammar permits only `docker run`, stdio/removal flags, the catalog image and
  image command; the rendered invocation adds exactly one active-Project bind,
  a Project-contained workdir, and the exact declared environment key set.
- Removed raw rootless-Docker reach from `boxa-mcp`: the socket remains
  `node:node` mode `0600`, broker/service environments omit Docker pointers,
  explicit raw-Docker env declarations are refused, and all child launches use
  `close_fds=True`. Agent-trusted execution retains its deterministic node
  Docker baseline.
- Docker secret acknowledgement is durable per stable catalog identity and
  Project. Refusal/cancel writes nothing; non-interactive activation requires
  `--accept-degraded-secret-isolation`. Catalog/list/status/doctor expose the
  degradation without secret values or unnecessary secret names.
- Whole-feature review hardening: readiness/install now share the adapter's
  public Docker grammar. New mutations reject unsafe Docker definitions, while
  legacy-loaded definitions remain readable but deterministically not-ready.
  Catalog validation rejects NUL/empty OS command tokens, invalid environment
  names, NUL environment values, and invalid prerequisite strings; broker
  `Popen` `ValueError` becomes a structured secret-free refusal.
- Proof (2026-07-27): MCP unittest suite 597/597 passed; full requested
  `shellcheck -S info -x ...`, Python byte-compilation, and `git diff --check`
  passed; `bash tests/help.sh` also passed. Docker adapter tests use a stubbed
  subprocess seam and pull no image.
- Independent review: 105 focused adapter/activation/broker/relay/trust tests
  passed; targeted shellcheck, Python byte-compilation, and diff check were
  clean. No unvalidated Docker option, mount, raw-socket, or environment path
  was found.
