# 06 — Per-Project state volume, restart semantics, retention

Status: done

## Parent

ADR 0037 § "State and retention"; glossary "Job record".

Host proof (docker-run.sh volume, `boxa stop`/restart, `boxa remove`) is performed by the user on the host — the in-box agent prepares the change and the exact commands.

## What to build

- Host side: a per-Project named volume in the existing `BOXA_VOL_*` pattern mounted at the Job state directory from 01; removed with the Project by `boxa remove`; `boxa stop --clean` semantics consistent with the other per-Project volumes.
- After a Container restart, the lazy `interrupted` marking from 02 works against the persisted records (foreign run id).
- Retention: at every `start`, bulky artefacts (`events.jsonl`, stdout, stderr, last message copy) of terminal Jobs older than 14 days are deleted automatically; the Job record (key, fingerprint, state, model, thread, exit, final message, ack, version) stays; non-terminal Jobs and `exited-with-survivors` are never touched. `gc --purge --older-than <days>` removes records by hand. `gc --dry-run` lists.

## Acceptance criteria

- [x] Unit tests: gc keeps records and active Jobs, deletes only old bulky files; `--purge` removes records; dry-run touches nothing.
- [x] Host proof (user): stop + start the Container → a Job that was running shows `interrupted`, its record and logs are still readable, `start` with the same key without `--fresh` returns it rather than re-running.
- [x] Host proof (user): `boxa remove` deletes the volume; a fresh Container starts with an empty Job list.
- [x] shellcheck clean.

## Blocked by

- `02-ownership-cancel-recovery.md`

## Comments

### Implementation (in-Container agent)

- `lib/naming.sh`: `BOXA_PROJECT_VOLUME_SUFFIXES` gains `jobs`, plus
  `BOXA_VOL_JOBS`. That one line is what makes `boxa stop --clean` and
  `boxa remove` delete the Job state, and what the reverse-lookup regex
  derives from.
- `docker-run.sh`: `-v "${BOXA_VOL_JOBS}:/home/node/.local/state/boxa/jobs"`,
  i.e. exactly the path `jobs.store.state_root()` derives from
  `XDG_STATE_HOME`. Also derived the project-name strip in
  `list_projects_with_volumes` from the suffix array (it hard-coded the four
  old suffixes, so a fifth would have made `boxa remove`'s project discovery
  silently wrong).
- `scripts/boxa-entrypoint.sh`: the root phase chowns
  `/home/node/.local{,/state,/state/boxa,/state/boxa/jobs}` to node — Docker
  creates both the fresh volume and the parents it mounts under as root, and
  `boxa-job` runs as node (the parents matter: `~/.local/state/boxa` is also
  where the Agent-browser records live).
- Restart semantics needed no new code path: `recovery.refresh_record`
  compares the record's `worker.containerRunId` *before* it looks at any pid,
  so a record whose old worker pid now belongs to a live foreign process is
  still `interrupted` / `container-restart`. That is now covered by a test
  that deliberately points a persisted record's worker pid at a live process.
- `scripts/jobs/gc.py` (new): retention. Age of a Job = the *youngest*
  evidence it was active (the later of `finishedAt` and the newest mtime in
  the record dir, `record.json` excluded so writing `gcAt` cannot postpone a
  later `--purge`). Terminal-only, 14 days by default: `events.jsonl`,
  `stdout`, `stderr`, `last.md`, `worker.err`, `heartbeat` go, the record
  stays with `gcAt`/`gcRemoved`/`gcBytes`. `--purge` (under the Project lock)
  drops the record dir and releases the key reservation, so a purged key is
  free again. Non-terminal Jobs — `exited-with-survivors`, `orphaned`,
  `reserved`, `running`, and an unreadable record — are never touched at
  either level.
- `scripts/jobs/cli.py`: `gc [--dry-run] [--older-than DAYS] [--purge]
  [--json]`; the automatic sweep runs in `_register_job` before the Project
  lock (so it covers `start` *and* `reply`) and can never fail a start.
  `result` prints `artefacts: removed by gc <date>` instead of paths that no
  longer resolve, `log` says why it has nothing to show, and both carry
  `gcAt` in `--json`. `PENDING_COMMANDS` is now empty: no command is "not yet
  available" any more, and `--help` grew a "state and retention" section.
- `scripts/jobs/codex.py`: the final message is copied onto the record capped
  at 64 KB with `finalMessageTruncated`, and `result_extract` prefers the
  stored extract once `gcAt` is set (the files it would otherwise re-read are
  gone). This is what keeps `result` honest after a sweep.

### Tests

- New `tests/test_jobs_gc.py`: 19 tests — sweep keeps the record/key and the
  Codex final message, `result`/`log` still answer afterwards, fresh and
  non-terminal (running / survivors / orphaned / unreadable) Jobs untouched,
  a recent artefact protects an old `finishedAt`, `--older-than`, idempotence,
  dry-run (bytes and mtimes unchanged) incl. `--purge --dry-run`, purge frees
  the key (a following `start` under it runs), purge refuses non-terminal
  Jobs, automatic sweep on `start`, a broken sweep never breaks a `start`,
  the restart test (only foreign non-terminal records flip, with one pointing
  at a live pid), interrupted Job keeps logs + key and is returned rather than
  re-run, final-message cap.
- `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_*.py'`:
  **910 tests, OK** (was 891 + the two help assertions updated for the now
  empty `PENDING_COMMANDS`).
- Shell: `tests/naming.sh` (new `jobs` suffix, regex, `BOXA_VOL_JOBS`),
  `tests/remove.sh`, `tests/stop-all.sh`, `tests/forge.sh`, `tests/help.sh`,
  `tests/shared-config.sh`, `tests/resources.sh` — all pass.
- `shellcheck docker-run.sh scripts/boxa-entrypoint.sh lib/naming.sh
  scripts/job.sh` clean. `ruff check scripts/jobs/gc.py`: only the package's
  existing `Optional[...]` (UP045) style, no new rule classes.

### In-Container proof (temp `XDG_STATE_HOME=/tmp/gcproof`)

    ./scripts/job.sh start --key gc-proof -- sh -c 'echo hello...; echo ... >&2'
    # backdated record.finishedAt and every file by 15 days
    ./scripts/job.sh gc --dry-run
      gc: would remove 1 job(s), 44 B; 0 kept (terminal and older than 14 days ...)
      20260912T095906-11u0x6  done  key=gc-proof  age=15.0d  44 B  stdout,stderr,worker.err,heartbeat
    ./scripts/job.sh gc            # same list, "44 B freed"; dir left with record.json + spec.json
    ./scripts/job.sh result <id>   # state: done / exit: 0 / artefacts: removed by gc 2026-09-12
    ./scripts/job.sh log <id>      # "no logs: gc removed this Job's artefacts on ..."
    ./scripts/job.sh gc --purge --older-than 14   # "purged 1 job(s), 1.6 KB freed"
    # record dir gone, keys/ empty, and `start --key gc-proof` ran a NEW job id

The real `~/.local/state/boxa/jobs` was never touched (temp `XDG_STATE_HOME`
throughout, removed afterwards).

### Host proof (user)

The volume mount and `boxa remove` cannot be proven from inside this
Container. On the host:

    cd ~/Projekty/boxa && git checkout main && git pull
    boxa stop boxa && boxa                 # restart picks up the new -v

Inside the fresh Container:

    mount | grep state/boxa/jobs           # expect the boxa-boxa-jobs volume
    ls -ld ~/.local/state/boxa/jobs        # expect node:node
    ./scripts/job.sh start --key restart-proof -- sleep 600
    ./scripts/job.sh list                  # running

Then on the host again, and back inside:

    boxa stop boxa && boxa
    ./scripts/job.sh list                  # the same jobId is still listed
    ./scripts/job.sh result <id>            # state: interrupted, reason: container-restart
    ./scripts/job.sh log <id> --tail 3      # the previous run's output is readable
    ./scripts/job.sh start --key restart-proof -- sleep 600
                                            # returns that record (exit 4, unclear), no new run

Volume removal — do NOT run `boxa remove boxa`, that would delete this
Container's own Job state. Use a throwaway Project:

    boxa throwaway-jobs-proof              # start it once, then inside it:
    #   ./scripts/job.sh start --key t -- sleep 5   (or just let the volume exist)
    docker volume ls | grep -- -jobs       # boxa-throwaway-jobs-proof-jobs present
    boxa remove throwaway-jobs-proof       # lists "Removed volume: ...-jobs"
    docker volume ls | grep -- -jobs       # that one gone
    boxa throwaway-jobs-proof              # fresh Container: `boxa-job list` is empty

`boxa stop --clean <project>` removes the same volume through the same suffix
list.

### 2026-09-12 — host proof (Prompt B, host session)

Rebuilt image `a4dfbb5e5493`, WSL host.

**Restart interruption.** `mount | grep state/boxa/jobs` → `/dev/sdd on
/home/node/.local/state/boxa/jobs type ext4 (rw)`; the dir is `node:node`
(`docker inspect` shows the `boxa-boxa-jobs` volume). `./scripts/job.sh start
--key restart-proof -- sleep 600` → `20260912T174716-dykwm3 running`. Then
`boxa stop boxa && boxa` (run-id changed `…-47ee5767dd0b2577` →
`…-d74e59e9f79be6b0`). Afterwards:

- `list` still shows the same jobId as `interrupted`.
- `result` → `state: interrupted`, `interruptedReason: container-restart`,
  `exitCode: null`.
- `log --tail 3` → "no output recorded for this Job yet" (rc 0; `sleep`
  writes nothing, the record and log paths are readable).
- `start --key restart-proof -- sleep 600` → returns the same record with
  `reason: key-interrupted`, exit 4, no new run.
- `cancel` → `state: cancelled`, `killed: none`; the key is free again.

**Volume removal.** Throwaway Project `~/Projekty/throwaway-jobs-proof`:
after `boxa <path>` the volume `boxa-throwaway-jobs-proof-jobs` exists and a
`boxa-job start --key t -- true` shows `done`. `boxa stop` + `boxa remove
throwaway-jobs-proof` prints `Removed volume: boxa-throwaway-jobs-proof-jobs`
(among history/docker/gh/glab), `docker volume ls` no longer lists it. A fresh
`boxa <path>` → `boxa-job list` → "no jobs in this Project". Throwaway Project
removed again afterwards; only `boxa-boxa-jobs` remains.
