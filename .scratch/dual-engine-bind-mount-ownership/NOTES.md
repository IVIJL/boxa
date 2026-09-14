# Dual-engine bind-mount ownership drift

Incident evidence (universe_media_api, 2026-09-12), collected 2026-09-14.

## Symptom

Inside the boxa Container, `docker compose up` leaves `media-api-db-dev` /
`media-api-u3db-dev` (postgres:16-alpine) and `typesense-dev` in a restart
loop:

```
chown: /var/lib/postgresql/data: Operation not permitted
chmod: /var/lib/postgresql/data: Operation not permitted
find: /var/lib/postgresql/data: Permission denied
```

The in-Container agent then asks the human to run a host-side `chown` to
`100069:100069` (pgdata) and `1000:1000` (typesense). This has now happened
several times for the same project.

## Root cause

The project directory is bind-mounted into the Container and the project's
compose files bind-mount `./data/pgdata`, `./data/u3pgdata`, `./data/typesense`
into service containers. Two Docker engines can run those services against the
**same host directories** with **different UID mappings**:

| Engine | Where | postgres uid 70 lands on host as | typesense root lands as |
| ------ | ----- | -------------------------------- | ----------------------- |
| Rootless dockerd inside the Container (Container user, `subuid …:100000:65536`) | `boxa` shell / boxa agents | `100069` | `1000` (= Container user) |
| Rootful host engine (Docker Desktop / WSL) | host terminal, host-side Claude session | `70` | `0` |

Timeline reconstructed from file ownership + host Claude transcript
`514a0621-087c-466b-933a-899cfd051389.jsonl` (cwd = project dir on the host):

1. 2026-09-10 07:10 — `pull_prod_dbs.sh` + rootless `docker compose up` in the
   Container: initdb creates pgdata as `100069:100069`.
2. 2026-09-12 06:54 — a **host-side** Claude session runs
   `docker compose up -d web` in the project dir on the host engine. The
   postgres entrypoint runs as real root and executes
   `find "$PGDATA" ! -user postgres -exec chown postgres '{}' +` — this changes
   **uid only**, so 1 784 entries become `70:100069`; 7 files written by that
   run are `70:70`. `postmaster.pid` ctime = 06:54 confirms it.
3. 2026-09-12 21:14 — the same host session restarts `typesense` on the host
   engine; `data/typesense/db` becomes `0:0`.
4. Next Container start: rootless postgres (host uid 100069) cannot enter a
   `drwx------ 70:100069` directory → restart loop. Rootless typesense (host
   uid 1000) cannot write into `0:0` `db/`.

Nothing in boxa prevents, detects, or repairs this. The only mitigation so far
was a manual `docker exec -u root boxa-<project> chown …` each time.

Contributing factor outside boxa (personal host config, not a boxa bug): the
user's host hook `~/.claude/hooks/block-host-exec.py` tells a host-side agent to
run `docker compose up -d` on the host when the stack is down, i.e. it actively
steers the agent onto the wrong engine.

## Why it matters

- Any project with bind-mounted service state (Postgres, MySQL, Redis AOF,
  Typesense, Elasticsearch …) is affected the moment anyone runs its compose
  on the host engine — human or agent.
- The failure is delayed and non-obvious (entrypoint `Operation not permitted`,
  no mention of uid mapping), and the fix needs host root, so the in-Container
  agent is blocked and burns a human round-trip.

## Experiment 2026-09-14 (proves the design in issue 01)

In the running Container `boxa-universe-media-api` (U = 1000), with the
production rootless engine left untouched: wrote `/etc/subuid` + `/etc/subgid`
as `1:999` + `1001:64535`, started a **second** rootless dockerd
(`--data-root` inside the `boxa-<project>-docker` volume, own state-dir and
socket). Observed:

- `uid_map`: `0 1000 1`, `1 1 999`, `1000 1001 64535` (gid_map identical).
- `chown 70:70 / 999:999 / 1000:1000` from an inner alpine → host `70:70`,
  `999:999`, `1001:1001`; inner root → host `1000:1000`.
- `postgres:16-alpine` initdb on a bind-mounted `data/exp-test/pg` → 997
  files `70:70` (dir `70:1000`, entrypoint chowns uid only). Same pgdata then
  started under the **host** engine (insert ok, 2 rows), then again inside the
  Container (insert ok, 3 rows). Round trip clean, no chown in between.
- Host engine creating a dir as root (`0:0`) → inner container `touch` fails
  with `Permission denied` → this is what issue 02 repairs.
- Pitfall found: a data-root on the Container's own overlay rootfs fails with
  `mount … overlay … invalid argument` (nested overlayfs); the data-root must
  live in the docker volume.

Everything was reverted afterwards (subuid restored, experimental daemon,
data-root and `data/exp-test` removed; production engine still on the old map
with 6 containers).

## AFK batch 2026-09-14 (implementation + review)

Commits on `main`: 287fdb2 (issue 01), 70763a8 (issue 02), b8792e3, dad149f,
b8e4b21 (Codex review rounds 1-3 fixes). Whole-feature Codex review
(thread `01a0a04c-28d1-71a1-817e-67ec9b49e51f`, jobs `…-mgd4va`, `…-pz6iso`,
`…-1s5b15`, `…-rl1u5k`) converged clean in round 4 after the round-4 prompt
limited findings to discrete bugs breaking an acceptance criterion for a
realistic U. Review findings fixed along the way: repair walk bounded to the
Project root's filesystem (device filter, no `chown -R`), U ≥ 65536 handled
as a single range, expected owners derived from U plus the generated ranges,
U never remapped when it lies inside the old 100000+ range, candidate scan
never prunes an expected-owner directory, no pipefail dependence.

Declined as out of spec: same-device bind mounts under the Project root are
indistinguishable from plain subdirectories (the spec's rule is `-xdev`,
i.e. device based).

Not proven in the Container session (needs host rebuild + fresh Container,
see each issue's Comments): fresh uid_map, chown 70:70/999:999 through the
inner engine, the postgres cross-engine round trip, the real legacy
data-root remap, the < 500 ms startup scan on universe_media_api, and the
end-to-end `0:0 → U:U` startup repair.
