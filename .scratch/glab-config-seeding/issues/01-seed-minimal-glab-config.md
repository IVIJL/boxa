# 01 — Seed a minimal glab config from Forge gate env on Container start

Status: done

## Parent

ADR 0032 decision 4 (forge tokens delivered as env; per-project
`~/.config/glab-cli` volume; env wins over config).

## What to build

When a Container starts with the Forge gate delivering `GITLAB_HOST`, `glab`
must be usable and self-consistent before any agent runs it. Today `glab`
writes its own default config on first invocation, which includes an empty
`gitlab.com` host stub. That host is not on the Allowlist, so `glab auth
status` reports "no route to host" and "could not authenticate", and agents
conclude glab is misconfigured even though API calls against `GITLAB_HOST`
work through the env token.

Add a dedicated, host-testable script that the entrypoint runs in its node
phase on every start. When `GITLAB_HOST` is set and no glab config exists in
the per-project volume, it writes a minimal config: default `host:` equal to
`GITLAB_HOST`, a `hosts:` map containing only that host, no token line, no
`gitlab.com` stub, file mode 0600 (glab refuses 0644). Without `GITLAB_HOST`
the script does nothing. An existing config is left untouched by this slice
(reconciliation is issue 02).

`gh` is out of scope: it reads `GH_TOKEN` without any config and its status
is already clean.

## Acceptance criteria

- [x] Fresh volume + `GITLAB_HOST` set: config exists after start, `host:`
      equals `GITLAB_HOST`, `hosts:` has exactly that entry, no `gitlab.com`
      key, no `token:` line, mode 0600 (proven by
      `tests/test_ensure_glab_config.py`). "owned by node" not independently
      host-tested — follows structurally from the script running after
      `--reuid=node` in the entrypoint, not proven by a live container run.
- [x] Fresh volume without `GITLAB_HOST`: no config file is created.
- [x] Existing config: byte-for-byte unchanged by this slice.
- [x] Entrypoint invokes the script in the node phase; a structural test
      (pattern of the existing entrypoint tests) asserts the call is present
      and after the node drop.
- [x] Unit tests run on the host against a temp HOME without Docker.
- [x] shellcheck clean including info-level findings.

## Blocked by

None — can start immediately.

## Comments
