# boxa-jobs — kickoff and handoff

Design: `docs/adr/0037-container-owned-jobs-replace-codex-mcp-server.md`
(proposed → accepted with issue 01), glossary `CONTEXT.md` § Jobs, facts in
`MEASUREMENTS.md`. Issues `issues/01`–`09`, dependency order as their
`Blocked by` fields. Reviewed with Codex; the ADR is the contract, do not
redesign it. Prototype worker used for the measurements lived in
`/tmp/jobmeas/` of the `boxa-boxa` Container and is disposable.

## Split of work: inside the Container vs on the host

Inside a Container the agent CAN: edit the repo, run pytest and shellcheck,
run `boxa-job` from the repo fallback path (no image rebuild needed, same as
`boxa-mcp-run`), run in-Container proofs (detached workers, Codex jobs on
`gpt-5.6-luna`), commit.

Inside a Container the agent CANNOT: rebuild the image (`docker build` is
forbidden in-box, OOM), restart or recreate its own Container, change what
`docker-run.sh` mounts (needs a host-side restart), run `boxa remove`/`boxa
stop`, or run the two-hour gate unattended across a Container restart.

Host-side steps are listed as "Host proof (user)" in issues 05, 06 and 08.
The in-box agent prepares the change and writes the exact commands into the
issue's Comments, then reports; the host agent (or the user) executes them
and pastes the result back.

## Prompt A — implementation session inside the Container (`boxa` from the boxa repo)

```
Read .scratch/README.md, then .scratch/boxa-jobs/KICKOFF.md, the ADR 0037 and
CONTEXT.md § Jobs. Run /afk-feature-workflow on feature boxa-jobs: issues
01 → 02 → 03 → 04 → 05 → 06 → 07 in dependency order (08 and 09 are
ready-for-human; stop before them). Codex delegation for coding is
UNAVAILABLE for this feature (this feature replaces it); implement natively.
Keep host-only proofs (issues 05, 06) as explicit Comments with exact
commands for the host, mark only proven criteria. Never docker build in the
Container. Commit per issue as the workflow authorizes; never push. When 07
is done and the final review is clean, write a HANDOFF.md for the host session
listing every host proof still pending.
```

## Prompt B — host session (outside the Container, this repo)

```
Read .scratch/README.md and .scratch/boxa-jobs/KICKOFF.md. You are the host
side of feature boxa-jobs. Wait for the user to relay requests from the
in-Container session. When asked: rebuild the image (boxa build), apply and
restart Containers for docker-run.sh changes, run the "Host proof (user)"
commands from issues 05/06, and later drive issue 08 (two-hour gate) and 09
(skills in ~/.claude). Record every result verbatim in the issue's Comments,
set statuses only for criteria you actually proved, keep the dashboard
current, never push.
```

## Interim state

Until issue 09 lands, Codex delegation in Containers runs through the old
`codex mcp-server` from Codex 0.149.1 pinned in the shared `boxa-npm-global`
volume (downgraded 2026-09-12). Do not update Codex inside a Container before
09 is done; a host `codex` update does not affect Containers.

## Status 2026-09-12 (end of Prompt A)

Issues 01–07 done, final review clean after five rounds; see `HANDOFF.md`
for the host steps and the pending host proofs. Next: Prompt B.
