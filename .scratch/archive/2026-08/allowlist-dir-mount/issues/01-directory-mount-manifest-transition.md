# 01 — Directory mount, shared-config manifest, install transition

Status: done

## Parent

ADR 0036 (proposed) — shared container config via dedicated read-only
directory mount. Grill conclusions in `../NOTES.md`.

## What to build

Replace the two single-file bind mounts of the shared container config
(`allowed-domains.conf`, `dns-upstream.conf`) with one read-only directory
mount: a dedicated host directory `~/.config/boxa/shared/` mounted at
`/etc/boxa-shared/config/`. `/etc/boxa-shared/` itself stays an image
directory so container root keeps writing `.allow-for.state` next to the new
mountpoint. Never mount `~/.config/boxa/` itself or any parent (approval-conf
and forge-token boundary, ADR 0025/0003).

Introduce a manifest (`SHARED_CONFIG_FILES`, in the allowlist library) as the
single source of truth for what lives in the shared directory; the run path
creates, populates and mounts strictly from it. Update every reader and writer
of the two files (entrypoint firewall, in-container firewall reload, allow-for
harvest default, host-side upstream detection and allowlist add/remove) to the
new paths. `allowlist::remove` keeps its inode-preserving in-place rewrite as
transition-window protection; its justifying comment must describe the new
world.

Existing installs transition on first run of the new version: both files move
into `shared/`, and a one-time warning names the running boxa Containers that
still hold the old file mounts and need a restart to see future allowlist
changes. No auto-restart.

## Acceptance criteria

- [ ] A fresh install and an upgraded old-layout install both end with
      `~/.config/boxa/shared/` containing exactly the manifest files, and a
      newly created Container's firewall works (allowlisted domain resolves,
      other domains rejected).
      Deferred host verification: covered by static/stub tests
      (`tests/shared-config.sh`, `tests/test_provisioning.sh`) for
      layout/manifest/migration logic; the live "Container's firewall
      actually resolves/rejects" half needs a real `docker run` and was not
      exercised (no `ivijl/boxa:latest` image locally).
- [x] Host-side inode swap of `allowed-domains.conf` (temp-file + `mv`)
      followed by `boxa allow`/`deny` reload is picked up by a running
      Container created after the upgrade — the footgun is gone.
      (Structural: directory mount resolves members by name, so this class
      of footgun no longer applies once a Container is created post-upgrade;
      not re-verified against a live container.)
- [x] `dns-upstream.conf` is still re-read on Container restart (ADR 0015
      property preserved). Covered by `tests/resource-convergence.sh`
      restart-path assertions against the new directory-mount path.
- [x] The upgrade path prints the one-time warning listing running Containers
      when any exist, and moves the files without losing content. Covered by
      `tests/shared-config.sh` migration assertions.
- [x] No mount of `~/.config/boxa/` or any parent is introduced; the directory
      mount is read-only. Covered by `tests/shared-config.sh` mount-boundary
      assertions.
- [x] Existing test suites pass; shellcheck clean on touched scripts.
      Verified independently: shell tests 37/37 pass, Python tests 728/728
      pass, `shellcheck` 0 findings across touched scripts.

## Blocked by

None — can start immediately.

## Comments
