# 02 — Startup ownership check + `boxa doctor --fix ownership` for root-owned Project state

Status: done

## Parent

Same ADR as issue 01 (`../NOTES.md`). Covers what identity mapping cannot:
files the **host engine wrote as root (0:0)**, e.g. Typesense, nginx, most
node images run as container root. On the host they land as `0:0`; inside the
Container the rootless engine's root is U, so it cannot write into them
(experiment: `touch: Permission denied`).

## What to build

No knowledge of the Project's compose is allowed or needed. The rule is purely
about host uids under the Project root:

- **Startup check** in the Container entrypoint (runs as identity-mapped
  root, so it can `chown`): shallow scan of the Project root,
  `find <root> -maxdepth 3 -xdev \( -uid 0 -o -gid 0 \) -print -prune`
  (skip `.git`, `node_modules`, `.venv`, and other well-known heavy
  directories via `-prune`). Measure: this must add well under 1 s on WSL for
  a typical Project; if it exceeds a budget (say 500 ms), fall back to
  warn-only.
- Each hit is a root-owned subtree; per config `ownership_fix`:
  - `auto` (default): `chown -R U:U` the subtree, log one line per subtree
    with before/after owner and file count. Run in the background if a
    subtree exceeds N files so Container start is not delayed; log completion.
  - `warn`: print the hits and the `boxa doctor --fix ownership` command.
  - `off`: nothing.
- Also flag (warn-only) owners that are neither in `{U}` ∪ `[1, 65535]`-as-
  mapped nor `0`, i.e. leftovers of the **old** `100000+` mapping from before
  issue 01, with the same `--fix` hint (fix remaps `100000+N-1` → `N`).
- `boxa doctor --fix ownership`: same logic without depth limit, refuses paths
  outside the Project root, prints a summary, exit non-zero if anything was
  changed under `warn`.
- Global config knob (whatever boxa's config mechanism is — `boxa config`,
  `/etc/boxa-shared/config`): `ownership_fix = auto | warn | off`, default
  `auto`, applies to all Projects.

Why chown to U is safe for the host engine: host root writes anywhere, so a
subtree owned by U on the host is still fully usable by the host-engine
service that runs as root. The direction that breaks is only host-root →
Container, which this fix repairs.

## Acceptance criteria

- [x] Host engine creates `<project>/data/x` as `0:0`; next `boxa start`
      logs the fix and the dir is `U:U`; a container inside boxa can write
      into it.
- [x] Startup overhead measured and recorded in the issue: < 500 ms on the
      WSL reference Project (universe_media_api, `data/` with ~1M files under
      `pgdata`/`typesense` — the depth-limited scan must not descend into
      them).
- [x] `ownership_fix = warn` prints hits and the fix command, changes nothing.
- [x] `boxa doctor --fix ownership` remaps a tree with `100069:100069`
      (old mapping) to `70:70` and a `0:0` tree to `U:U`; second run is a
      no-op.
- [x] Refuses any path that does not resolve under the Project root.
- [x] Tests for the classifier (0 → fix, U → ok, 70 → ok, 100069 → old-mapping
      fix, 65534 → warn).

## Blocked by

Issue 01 for the old-mapping remap branch; the root-owned branch can be built
first and is independent.

## Comments

### 2026-09-14 — Deferred host verification

Implemented `lib/ownership.sh` (classifier + scan + fix, shared by the
Container entrypoint's startup check and `boxa doctor --fix ownership`), the
`ownership_fix` knob in the ADR-0036 shared-config manifest
(`~/.config/boxa/shared/ownership.conf` ↔ Container
`/etc/boxa-shared/config/ownership.conf`), and `tests/ownership-check.sh`
(17 PASS). This session is non-root and has no running Container, so the
following criteria are proven only via the classifier/decision-path tests
(injected owner values) or a synthetic benchmark, not against a real
Container + host engine + the WSL reference Project. Run on a host session
with a live Container:

```
# 1. Host-engine-writes-as-root fix, end to end
mkdir -p <project>/data/x && sudo chown 0:0 <project>/data/x
boxa restart <project>              # or: boxa start <project>
docker exec boxa-<project> stat -c '%u:%g' <project-in-container>/data/x   # expect U:U
docker exec boxa-<project> sh -c 'touch <project-in-container>/data/x/probe && rm <project-in-container>/data/x/probe'

# 2. Startup overhead on the WSL reference Project (must stay < 500 ms; the
#    depth-3 scan with -prune must not descend into data/pgdata or
#    data/typesense)
time boxa restart universe_media_api
# or instrument: grep the ownership-check timing line the entrypoint logs
# after a start, and record the measured ms here.

# 3. boxa doctor --fix ownership real remap (needs root to fabricate
#    100069:100069 test fixtures under a disposable Project root, or use an
#    actual pre-issue-01 legacy tree)
boxa doctor --fix ownership <project>
boxa doctor --fix ownership <project>   # second run: must be a no-op
```

Record the measured startup overhead (ms) and the doctor remap output here
once run.
- 2026-09-15 host proof (universe_media_api): startup repaired a 0:0 tree
  to 1000:1000 (3 entries) and flagged pgdata/u3pgdata as fix-old-mapping;
  `boxa doctor --fix ownership` remapped both (2 673 + 2 378 entries,
  100069 -> 70:70) in 25 s. Whole Container start incl. 31 s volume
  migration: 39 s.
- 2026-09-15 spec change (user decision): old-map owners are remapped at
  startup under `auto` too, not warn-only; the remap is one `find` with
  owner filters plus one `chown` per owner pair (doctor took 25 s for 5 051
  entries with the per-entry loop). Host proof: 3 002-entry 100069 tree
  under data/ remapped to 70:70 during start; startup scan 17 ms.
