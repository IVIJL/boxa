# 05 — Codex runtime: verified immutable per-version copy

Status: done

## Parent

ADR 0037 § "Codex runtime"; glossary "Codex runtime". Measured: the image bakes 0.149.1, the shared `boxa-npm-global` volume shadows it (0.154.0 after a host update); on Linux the host package (`~/.nvm/.../node_modules/@openai/codex`, with the `codex-linux-x64` static binary nested) is runnable in the Container; on macOS it is not.

Host proof (docker-run.sh mount changes, Container restart) is performed by the user on the host — the in-box agent prepares the change and the exact commands.

## What to build

- Host side (`docker-run.sh`): a shared named volume `boxa-codex-versions` mounted at a fixed Container path; on Linux, the host's `@openai/codex` package directory (resolved from the host `codex` executable) bind-mounted read-only at a fixed Container path. Nothing downloaded or copied at Container start.
- `boxa-job` at every Codex `start`/`reply` (and `boxa-job runtime refresh`): find the newest version among the npm volume and the host mount; if newer than the newest verified copy, snapshot it: manifest of the source (paths, sizes, mtimes, package version) before and after, copy into a temp dir under the versions volume, content-hash copied files against the source, discard on any difference (concurrent `npm` update) and keep the previous runtime; check the Linux binary answers `--version`; probe with a real run: one trivial `codex exec --json` on the cheapest model available (`gpt-5.6-luna` unless configured otherwise) followed by `resume` into its thread, verifying `thread.started`, `turn.completed`, `-o`, continuity. Publish atomically by rename to `<version>/`, mark verified, chmod read-only for `node` (convention, stated as such). A publish `flock` in the volume serializes Containers. A failed probe leaves the previous verified version in use and prints a loud warning in the `start` output.
- `runtime list` (found, verified, in-use, per version) and `runtime use <version>` (pin/rollback among verified copies). Jobs run only from a verified copy; the Job record stores the exact version and path. Interactive `codex` stays untouched (npm volume).
- macOS: the host mount is skipped; the flow works from the npm volume alone. Mac verification is deferred to `.scratch/mac/boxa-jobs/`.

## Acceptance criteria

- [x] Unit tests: manifest diff → discard; hash mismatch → discard; probe failure → previous version stays, warning emitted; `runtime use` pins; publish lock contention.
- [x] Test: `npm install` rewriting the source during the copy (simulated by mutating files mid-copy) → copy discarded, previous runtime in use, nothing published.
- [x] In-Container proof: first Codex job after a version change snapshots + probes once; second job reuses the copy (no probe); `runtime list` shows both versions.
- [x] Host proof (user): after the docker-run.sh change and a Container restart, the host package appears read-only in the Container and a Codex job runs from `boxa-codex-versions/<host version>/` while interactive `codex` still reports the npm-volume version.
- [x] shellcheck clean.

## Blocked by

- `04-codex-job-start-reply-result.md`

## Comments

### 2026-09-12 — implemented natively (Claude), in-Container proof done, host proof pending

**Code.** New `scripts/jobs/runtime.py` is the whole Codex runtime: source
discovery (npm-volume package dir + the Linux-only host package mount),
`package.json` version with a numeric-component compare, the snapshot
(manifest before/after, `shutil.copytree`, sha256 of every copied file against
its source, `--version` on the copy's own vendor binary, the real probe,
atomic publish by rename under a `flock` in the versions root, `verified.json`
marker, chmod read-only), the pin, and `ensure()` — the selection with its
fast path. `jobs/codex.py`'s single seam is now `resolve_runtime()` (the old
`resolve_binary()` delegates to it): **no PATH fallback any more**, a Codex job
runs only from a verified copy, and `BOXA_JOB_CODEX_BIN` is the test override.
`cli.py` refreshes the runtime in `_codex_request_spec()`, i.e. BEFORE the
Project lock (a probe takes ~9 s, the registration lock must stay short),
prints every runtime warning to stderr as `WARNING:` and carries it in
`warnings` in `--json`, and gained the real `runtime list|refresh|use
<version>|use --auto`. A Codex job with no verified copy is refused
`no-verified-runtime` (exit 5, structured) rather than silently running from
the mutable npm volume.

**Decisions worth knowing.**
- Jobs execute the copy's **vendor static binary** directly
  (`…/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex`),
  not the copy's `bin/codex.js`: that is exactly the process `codex.js`
  spawns (it only adds `CODEX_MANAGED_*` env), so the node wrapper is one
  process less in the Job's tree, and the copy is self-contained
  (`codex-path`, `codex-resources` are its siblings in the vendor dir).
- Layout: `<root>/<version>/package/…` + `<root>/<version>/verified.json`;
  the marker is what makes a copy usable. The pin lives in `<root>/pin` —
  versions root, not Project state: the copies are shared by every Container
  on the volume, and so is a rollback about them.
- A pin short-circuits the refresh entirely (a rollback means "run this
  version", so a newer one is not chased and not probed).
- Paths are env-overridable (`BOXA_JOB_CODEX_VERSIONS_DIR`,
  `BOXA_JOB_CODEX_NPM_PKG_DIR`, `BOXA_JOB_CODEX_HOST_PKG_DIR`,
  `BOXA_JOB_PROBE_MODEL`, `BOXA_JOB_PROBE_TIMEOUT`); the defaults are the
  fixed Container paths `docker-run.sh` mounts. That is what made the proof
  below possible without a Container restart.
- An unusable versions root (this Container, before the volume exists) is a
  clean `no-verified-runtime` refusal, not a traceback.

**Host side.** `docker-run.sh`: shared `boxa-codex-versions` volume at
`/usr/local/share/boxa-codex-versions`; on non-Darwin hosts the host
`@openai/codex` package (resolved `command -v codex` → `readlink -f` →
package dir two levels up from `bin/codex.js`) bind-mounted **read-only** at
`/run/boxa-codex-host-pkg`, skipped on macOS exactly like the Claude binary.
`scripts/boxa-entrypoint.sh` root phase `mkdir -p` + `chown node:node` the
versions mount (a fresh named volume is root-owned, same treatment as the
other shared volumes). Nothing is downloaded or copied at Container start.

**Tests.** `tests/test_jobs_runtime.py`, 28 tests, all green: source ordering
and the absent host mount (the macOS branch), manifest change mid-copy →
discarded, content mismatch with an unchanged manifest → discarded, a binary
that cannot answer `--version` → discarded, a stream without `turn.completed`
→ discarded, publish + read-only + marker contents, the real `probe()` over a
fake binary replaying the recorded matched thread pair (continuity asserted),
probe failure → previous version stays + warning, no verified copy → refusal,
unusable root → refusal, pin wins over newest and never probes, a stale pin
warns and falls back, a copy without its marker is unusable, the fast path
probes exactly once for two calls, the publish lock (a second publisher waits
≥0.8 s; two concurrent publishers → exactly one published copy, no temp dir
left), and the CLI: `runtime list/refresh/use/--auto`, the refusal exit codes,
a Codex job's record carrying `codexVersion`/`codexBinary` from the copy, and
the loud stderr warning on `start`. Two pre-existing tests were adjusted, not
weakened: `test_jobs_codex.py`'s binary-resolution test now asserts the
refusal without a verified runtime (there is no PATH fallback to test), and
`test_jobs_ownership.py`'s help test splits on the epilog heading itself.
Whole suite: `PYTHONPATH=scripts python3 -m unittest discover -s tests` = 891
tests OK. `shellcheck docker-run.sh scripts/boxa-entrypoint.sh
scripts/job.sh` clean (no pre-existing findings either).

**In-Container proof** (real Codex, `gpt-5.6-luna`, effort low, tiny prompts,
`BOXA_JOB_CODEX_VERSIONS_DIR=/tmp/p05/versions`; 7 live turns total, temp dirs
deleted afterwards):

1. Empty versions dir, first Codex job: `started … runtimeProbed:true
   runtimeSource:npm-volume codexVersion:0.149.1 codexBinary:/tmp/p05/versions/0.149.1/package/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex`,
   `start` took **13.4 s** (309 MB copy + hash + 2 live probe turns).
   `verified.json`: `probed:true`, `probeModel:gpt-5.6-luna`,
   `probeThreadId:01a094fe-6e07-78c1-98b0-de98a3fbb1f2`,
   `reportedVersion:"codex-cli 0.149.1"`, `source:npm-volume`. Job: `done`,
   3.8 s, final `ONE`. `runtime list` → `* 0.149.1 verified sources=npm-volume`.
2. Second job, same version: `runtimeProbed:false`, `start` took **0.13 s**
   (vs 13.4 s) — the fast path does no manifest, no copy and no probe. Job
   `done`, final `TWO`.
3. Simulated second version: the real package copied to `/tmp/p05/host-pkg`
   with `package.json` bumped to 0.149.2, `BOXA_JOB_CODEX_HOST_PKG_DIR`
   pointing there. Third job: `runtimeProbed:true runtimeSource:host-mount
   codexVersion:0.149.2`, ran from `/tmp/p05/versions/0.149.2/package/…`,
   `done`, final `THREE`. `runtime list` → `* 0.149.2 verified
   sources=host-mount` / `0.149.1 verified sources=npm-volume`. (The marker
   honestly records `reportedVersion: codex-cli 0.149.1` — the bumped package
   carries the real 0.149.1 binary.)
4. `runtime use 0.149.1` → `* 0.149.1 … pinned`; `runtime refresh` →
   `runtime: 0.149.1 source: pin  probed: no` (a pin is not overtaken);
   `runtime use --auto` → 0.149.2 in use again.
5. Read-only convention: `dr-xr-xr-x` version dir, `-r--r--r--`
   `package.json`; appending to it and creating a file in the copy both fail
   `permission denied`.
6. Without the env override, a Codex job in this (not yet restarted)
   Container refuses cleanly: `result:refused reason:no-verified-runtime`,
   exit 5, with the warning that
   `/usr/local/share/boxa-codex-versions` is not usable — which is precisely
   what the host proof below fixes.

**Host proof (user)** — the `docker-run.sh` / entrypoint change needs a real
Container restart, which cannot happen from inside the box. No image rebuild
is needed (the `boxa-job` CLI runs from the repo checkout fallback), but the
mounts only appear on a fresh `docker run`:

```sh
# on the HOST
cd ~/Projekty/boxa && git checkout main && git pull
boxa stop boxa && boxa                 # fresh docker run with the new mounts

# inside the Container (the shell `boxa` drops you into)
ls -ld /run/boxa-codex-host-pkg                    # host package, RO bind
cat /run/boxa-codex-host-pkg/package.json | head -3  # the HOST codex version
touch /run/boxa-codex-host-pkg/x                   # must fail: read-only fs
ls -ld /usr/local/share/boxa-codex-versions        # node-owned, writable
boxa-job runtime list                              # sources: npm-volume + host-mount
cd ~/Projekty/boxa
./scripts/job.sh start --key host-proof --codex --model gpt-5.6-luna \
    --effort low --json "Reply with the single word HOST and nothing else."
./scripts/job.sh wait <jobId> --json | tr ',' '\n' | grep -E 'codexBinary|codexVersion|finalMessage'
codex --version                                    # still the npm-volume version
```

Expected: `runtime list` shows the host version with `sources=host-mount`
(newest wins), the job's `codexBinary` is under
`/usr/local/share/boxa-codex-versions/<host version>/package/…`, and
interactive `codex --version` keeps reporting the npm-volume version — the two
runtimes are separate, which is the point of the whole slice.

**Deviations / notes.**
- `runtime use <version>` refuses an unverified version (`reason:not-verified`,
  exit 5): pinning something unproven is the one thing this design exists to
  prevent.
- The probe reuses `codex.start_argv`/`resume_argv`, so it exercises the exact
  argv a Job gets, and runs under the same `env.baseline_env()` a Job gets.
- macOS verification is deferred: `.scratch/mac/boxa-jobs/README.md`.

### 2026-09-12 — host proof (Prompt B, host session)

Image rebuilt by the user (`a4dfbb5e5493`), `boxa stop boxa && boxa` on the WSL
host. Host `codex` = 0.154.0 (`~/.nvm/versions/node/v24.15.0/lib/node_modules/@openai/codex`).

- `docker inspect`: `boxa-codex-versions` volume at `/usr/local/share/boxa-codex-versions`
  (rw), host package bind at `/run/boxa-codex-host-pkg` with `rw=false`.
- Inside: `touch /run/boxa-codex-host-pkg/x` → "Read-only file system";
  `package.json` there says 0.154.0; the versions dir is `node:node` after the
  new entrypoint (before the rebuild it was root-owned and `boxa-job` failed
  with PermissionError, as the handoff predicted).
- `boxa-job runtime list` before the first job: `0.154.0 unverified sources=host-mount`,
  `0.149.1 unverified sources=npm-volume`.
- `./scripts/job.sh start --key host-proof --codex --model gpt-5.6-luna --effort low --json`:
  `runtimeProbed: true`, `runtimeSource: host-mount`, `codexVersion: 0.154.0`,
  `codexBinary: /usr/local/share/boxa-codex-versions/0.154.0/package/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex`.
  `wait` → `state: done`, `finalMessage: "HOST"`.
- Afterwards `runtime list` marks `* 0.154.0 verified`, the `0.154.0/` dir is
  `dr-xr-xr-x node`, `publish.lock` present. Interactive `codex --version`
  still prints `codex-cli 0.149.1` (npm volume).
