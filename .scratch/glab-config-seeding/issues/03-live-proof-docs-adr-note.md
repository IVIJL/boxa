# 03 — Live proof, docs and ADR 0032 amendment

Status: ready-for-human

## Parent

ADR 0032 decision 4.

## What to build

Prove the seeded/reconciled config in a real Container and document the
behaviour. The proof project is `playground` only; do not run
`boxa stop --clean` against any other project, because `--clean` deletes the
project's history, docker, gh and glab volumes. Confirm the target project
name before running the command.

Document in the forge docs what the entrypoint does to the glab config on
each start, that a config token under the Forge host is dropped while the
gate delivers `GITLAB_TOKEN`, and that in-box logins to other hosts are kept.
Add a short amendment note to ADR 0032 decision 4 recording the
reconciliation rule so "in-box `glab auth login` is supported" reads
correctly alongside "env wins".

## Acceptance criteria

- [ ] On the host: `boxa stop --clean playground && boxa` (playground only),
      then inside the Container `glab auth status` prints exactly one host
      section for the Forge host with no `x` line, and `glab api user`
      returns the agent persona. Record the redacted output in this issue.
- [ ] Inside an existing Container whose volume still has the `gitlab.com`
      stub, a plain `boxa stop <project> && boxa` (no `--clean`) leaves
      `glab auth status` clean after restart.
- [x] `docs/forge.md` describes seeding and reconciliation and the token
      precedence consequence.
- [x] ADR 0032 carries an amendment note referencing this feature.
- [x] No image rebuild inside a Container (build runs on the host only).

## Blocked by

- [02 — Reconcile an existing glab config](02-reconcile-existing-glab-config.md)

## Comments

- 2026-09-03: Part A (docs) landed in this commit: `docs/forge.md` now
  describes seeding/reconciliation and the token precedence consequence,
  and ADR 0032 got a dated amendment note under decision 4. Part B (live
  proof) is deferred to the user on the host, since it cannot be done from
  inside this container: run `boxa stop --clean playground && boxa`
  (playground only, never `--clean` on another project), then inside the
  Container check `glab auth status` and `glab api user`; separately, on an
  existing Container whose volume still carries the `gitlab.com` stub, run
  a plain `boxa stop <project> && boxa` (no `--clean`) and confirm
  `glab auth status` is clean after restart. Record the redacted output
  under these two acceptance criteria in this file, tick them, and flip
  Status to done once both are proven.
