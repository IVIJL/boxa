# 02 — forge.conf v2: defaults, per-project assignment, injection

Status: done

## Parent

ADR 0033, Decision 3, 4, 8.

## What to build

The assignment layer end-to-end, driven by a hand-edited conf (no UX
yet). The strict forge.conf parser grows: global-scope default-identity
keys (one per forge) and per-project section keys `github = <id>|none`,
`gitlab = <id>|none`, alongside the existing `forge = on|off`.
Resolution per project per forge: explicit assignment > global default >
none. At container creation, the resolved identity (not the legacy
global credential) supplies `GH_TOKEN` / `GITLAB_TOKEN` / `GITLAB_HOST`
and the synthesized committer identity; `none` injects nothing for that
forge even when a default exists. Malformed conf keeps failing closed.

## Acceptance criteria

- [x] Parser accepts the new keys, still rejects malformed lines by
      invalidating the file (gate off)
- [x] Resolution precedence (assignment > default > none) covered by
      tests, incl. `none` overriding a default
- [x] A box created for a project with an assigned identity receives
      that identity's token env + committer; a project falling back to
      the default receives the default's
- [x] shellcheck clean incl. info-level

## Blocked by

01-identity-store-and-list.md

## Comments
