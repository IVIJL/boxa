# boxa-jobs — handoff to the host session (Prompt B)

Written 2026-09-12 by the in-Container AFK session (Prompt A). Issues 01–07
are implemented, committed on `main` (not pushed) and reviewed. Issues 08 and
09 remain `ready-for-human`. Nothing below was executed on the host yet.

## What landed

| Commit | Content |
| ------ | ------- |
| `fb7dbb9` | 01 job core: `boxa-job start/wait/result/list/log`, detached subreaper worker, link()-published reservation, ADR 0037 accepted |
| `7538971` | 02 process-tree ownership, `cancel`, `orphaned`/`adopt`, `exited-with-survivors`, `interrupted` by run id, entrypoint writes `/run/boxa/run-id` |
| `114f1de` | 03 concurrency ack (`needs-ack`, `--ack-concurrent`) |
| `ffcda25` | 04 Codex job `start --codex`, `reply`, event-derived outcome, result extraction |
| `aab3044` | 05 verified immutable Codex runtime snapshots, `runtime list/use/refresh`, docker-run.sh mounts (`boxa-codex-versions`, host package RO) |
| `832fcb7` | 06 per-Project `boxa-<project>-jobs` state volume, retention `gc` |
| `633a5d0` | 07 codex-delegate seed retired, `docs/jobs.md`, boxa skill Jobs section, doctor/status notice |
| `5d5bf81`, `b3d6a28`, `bfa94bd`, `575b9d0` | four rounds of final-review fixes |

Final Codex review (thread `01a09524-23d8-7900-85d1-508137b9cc9d`, model
gpt-5.6-sol) converged after five rounds: 12 → 10 → 6 → 5 → 0 findings; the
last verdict was "No discrete correctness issues were identified".

Test state: `PYTHONPATH=scripts python3 -m unittest discover -s tests` = 951
tests. In a full run one pre-existing pty test
(`test_ssh_gate_pty.test_failed_startup_reapply_stops_agent_and_retries_whole_bundle`)
fails under load; it passes 3/3 when its module runs alone and the feature
does not touch it. The jobs modules spawn real processes, which raises the
load of the full run. Worth a look on the host, not a Jobs bug.

## Host steps, in order

### 0. Rebuild the image once (bakes `boxa-job`; Dockerfile changed in 01)

```sh
cd ~/Projekty/boxa && git checkout main && git status   # 11 commits ahead, unpushed
boxa build
```

Until the rebuild, `boxa-job` in a Container runs only from the repo
checkout fallback (`./scripts/job.sh` in this repo); the baked
`/usr/local/bin/boxa-job` appears after the rebuild.

### 1. Issue 05 — host proof (docker-run.sh mounts, Codex runtime from the host package)

```sh
# on the HOST
boxa stop boxa && boxa                 # fresh docker run with the new mounts

# inside the Container
ls -ld /run/boxa-codex-host-pkg                    # host package, RO bind
head -3 /run/boxa-codex-host-pkg/package.json      # the HOST codex version
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
(newest wins), the first Codex job probes once (`runtimeProbed: true`), its
`codexBinary` is under `/usr/local/share/boxa-codex-versions/<host version>/package/…`,
interactive `codex --version` still prints the npm-volume version. Record the
output in issue 05 Comments and tick its "Host proof (user)" criterion.

### 2. Issue 06 — host proof (state volume, restart interruption, removal)

```sh
# inside the fresh Container from step 1
mount | grep state/boxa/jobs           # expect the boxa-boxa-jobs volume
ls -ld ~/.local/state/boxa/jobs        # expect node:node
cd ~/Projekty/boxa
./scripts/job.sh start --key restart-proof -- sleep 600
./scripts/job.sh list                  # running

# on the host, then back inside
boxa stop boxa && boxa
./scripts/job.sh list                  # the same jobId is still listed
./scripts/job.sh result <id>            # state: interrupted, reason: container-restart
./scripts/job.sh log <id> --tail 3      # the previous run's output is readable
./scripts/job.sh start --key restart-proof -- sleep 600   # returns that record (exit 4), no new run
./scripts/job.sh cancel <id>            # resolves the key afterwards
```

Volume removal: do NOT run `boxa remove boxa` (deletes this Container's Job
state). Use a throwaway Project:

```sh
boxa throwaway-jobs-proof              # start it once
docker volume ls | grep -- -jobs       # boxa-throwaway-jobs-proof-jobs present
boxa remove throwaway-jobs-proof       # lists "Removed volume: ...-jobs"
docker volume ls | grep -- -jobs       # that one gone
boxa throwaway-jobs-proof              # fresh Container: `boxa-job list` is empty
```

Record in issue 06 Comments, tick both "Host proof (user)" criteria.

### 3. Issue 07 — host verification (doctor/status on the old catalog entry)

```sh
boxa doctor                 # expect the WARNING block + 'boxa mcp remove <entry>'
boxa mcp status             # same explanation in the profile view
boxa mcp status --project ~/Projekty/boxa
boxa update                 # expect NO codex-delegate seed offer any more
boxa mcp remove codex-delegate     # only AFTER issue 09 (see interim state below)
```

The rendered text is test-proven; only the live entry point is unproven.
Tick the doctor criterion in issue 07 after seeing it.

### 4. Issue 08 — release gate (two-hour run), then 09 — switch skills

Both stay `ready-for-human`; see their issue files. 08 needs the host proofs
above first (the runtime and state volume must be real). 09 rewrites the
skills in `~/.claude` and updates the memory notes.

## Interim state, do not break it

- Codex delegation in Containers still runs through `codex mcp-server` from
  Codex 0.149.1 pinned in the shared `boxa-npm-global` volume. The final
  review of this feature used exactly that path. Do not update Codex inside
  a Container and do not remove the `codex-delegate` catalog entry before
  issue 09 is done.
- Codex jobs need a verified runtime copy. Before the Container restart in
  step 1 there is no `boxa-codex-versions` volume, so `boxa-job start --codex`
  refuses with `no-verified-runtime` (exit 5). That is expected, not a bug.
- macOS branch is deferred: `.scratch/mac/boxa-jobs/README.md`.

## Tracker state

- Issues 01–07: `done`; criteria left unticked are exactly the host proofs
  listed above (05: one, 06: two, 07: one).
- Issues 08, 09: `ready-for-human`.
- Feature row moved from Active to "Waiting for human" in `.scratch/README.md`.
  Archive only after 09 closes.
