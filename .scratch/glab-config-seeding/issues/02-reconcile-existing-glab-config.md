# 02 — Reconcile an existing glab config with Forge gate env on every start

Status: done

## Parent

ADR 0032 decision 4 (in-box `glab auth login` supported; injected env wins
over config files).

## What to build

Existing per-project glab volumes already carry the `gitlab.com` stub, and
some carry a stale token under the Forge host from an earlier in-box login
that was later rotated on the host. `glab auth status` then reports "Invalid
token provided in configuration file" even though the env token is the one
actually used. Extend the script from issue 01 so that on every Container
start with `GITLAB_HOST` set it reconciles an existing config, idempotently:

- set the default `host:` to `GITLAB_HOST`, adding the `hosts:` entry when
  missing;
- remove any host entry that has no token and is not `GITLAB_HOST`
  (this drops the `gitlab.com` stub);
- when `GITLAB_TOKEN` is also set, remove the `token:` line under
  `GITLAB_HOST` because env wins and a config token there can only be stale;
- leave every other host that carries a token untouched (an in-box login to
  a different GitLab stays);
- keep all other top-level settings the user may have changed;
- enforce mode 0600.

Running the script twice on the same input produces the same file. Without
`GITLAB_HOST` nothing is touched.

## Acceptance criteria

- [x] Stub-only config (default `host: gitlab.com`, empty gitlab.com entry):
      result has `host: GITLAB_HOST`, only the Forge host entry, no stub.
- [x] Config with a stale `token:` under `GITLAB_HOST` and `GITLAB_TOKEN`
      set: token line removed, host entry kept.
- [x] Config with a token under `GITLAB_HOST` and no `GITLAB_TOKEN` in env:
      token kept.
- [x] Config with a foreign host that has a token: that entry is preserved
      verbatim.
- [x] Config without a `hosts:` section: section created with the Forge host.
- [x] Non-default top-level keys (e.g. `git_protocol`, `check_update`)
      survive unchanged.
- [x] Idempotent: second run yields an identical file; mode 0600 after run.
- [x] No `GITLAB_HOST`: file unchanged, including mode.
- [x] Unit tests on the host cover every case above; shellcheck clean.

## Blocked by

- [01 — Seed a minimal glab config](01-seed-minimal-glab-config.md)

## Comments
