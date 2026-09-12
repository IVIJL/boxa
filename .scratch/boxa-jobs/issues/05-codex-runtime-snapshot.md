# 05 — Codex runtime: verified immutable per-version copy

Status: ready-for-agent

## Parent

ADR 0037 § "Codex runtime"; glossary "Codex runtime". Measured: the image bakes 0.149.1, the shared `boxa-npm-global` volume shadows it (0.154.0 after a host update); on Linux the host package (`~/.nvm/.../node_modules/@openai/codex`, with the `codex-linux-x64` static binary nested) is runnable in the Container; on macOS it is not.

Host proof (docker-run.sh mount changes, Container restart) is performed by the user on the host — the in-box agent prepares the change and the exact commands.

## What to build

- Host side (`docker-run.sh`): a shared named volume `boxa-codex-versions` mounted at a fixed Container path; on Linux, the host's `@openai/codex` package directory (resolved from the host `codex` executable) bind-mounted read-only at a fixed Container path. Nothing downloaded or copied at Container start.
- `boxa-job` at every Codex `start`/`reply` (and `boxa-job runtime refresh`): find the newest version among the npm volume and the host mount; if newer than the newest verified copy, snapshot it: manifest of the source (paths, sizes, mtimes, package version) before and after, copy into a temp dir under the versions volume, content-hash copied files against the source, discard on any difference (concurrent `npm` update) and keep the previous runtime; check the Linux binary answers `--version`; probe with a real run: one trivial `codex exec --json` on the cheapest model available (`gpt-5.6-luna` unless configured otherwise) followed by `resume` into its thread, verifying `thread.started`, `turn.completed`, `-o`, continuity. Publish atomically by rename to `<version>/`, mark verified, chmod read-only for `node` (convention, stated as such). A publish `flock` in the volume serializes Containers. A failed probe leaves the previous verified version in use and prints a loud warning in the `start` output.
- `runtime list` (found, verified, in-use, per version) and `runtime use <version>` (pin/rollback among verified copies). Jobs run only from a verified copy; the Job record stores the exact version and path. Interactive `codex` stays untouched (npm volume).
- macOS: the host mount is skipped; the flow works from the npm volume alone. Mac verification is deferred to `.scratch/mac/boxa-jobs/`.

## Acceptance criteria

- [ ] Unit tests: manifest diff → discard; hash mismatch → discard; probe failure → previous version stays, warning emitted; `runtime use` pins; publish lock contention.
- [ ] Test: `npm install` rewriting the source during the copy (simulated by mutating files mid-copy) → copy discarded, previous runtime in use, nothing published.
- [ ] In-Container proof: first Codex job after a version change snapshots + probes once; second job reuses the copy (no probe); `runtime list` shows both versions.
- [ ] Host proof (user): after the docker-run.sh change and a Container restart, the host package appears read-only in the Container and a Codex job runs from `boxa-codex-versions/<host version>/` while interactive `codex` still reports the npm-volume version.
- [ ] shellcheck clean.

## Blocked by

- `04-codex-job-start-reply-result.md`

## Comments
