# 06 — Per-Project state volume, restart semantics, retention

Status: ready-for-agent

## Parent

ADR 0037 § "State and retention"; glossary "Job record".

Host proof (docker-run.sh volume, `boxa stop`/restart, `boxa remove`) is performed by the user on the host — the in-box agent prepares the change and the exact commands.

## What to build

- Host side: a per-Project named volume in the existing `BOXA_VOL_*` pattern mounted at the Job state directory from 01; removed with the Project by `boxa remove`; `boxa stop --clean` semantics consistent with the other per-Project volumes.
- After a Container restart, the lazy `interrupted` marking from 02 works against the persisted records (foreign run id).
- Retention: at every `start`, bulky artefacts (`events.jsonl`, stdout, stderr, last message copy) of terminal Jobs older than 14 days are deleted automatically; the Job record (key, fingerprint, state, model, thread, exit, final message, ack, version) stays; non-terminal Jobs and `exited-with-survivors` are never touched. `gc --purge --older-than <days>` removes records by hand. `gc --dry-run` lists.

## Acceptance criteria

- [ ] Unit tests: gc keeps records and active Jobs, deletes only old bulky files; `--purge` removes records; dry-run touches nothing.
- [ ] Host proof (user): stop + start the Container → a Job that was running shows `interrupted`, its record and logs are still readable, `start` with the same key without `--fresh` returns it rather than re-running.
- [ ] Host proof (user): `boxa remove` deletes the volume; a fresh Container starts with an empty Job list.
- [ ] shellcheck clean.

## Blocked by

- `02-ownership-cancel-recovery.md`

## Comments
