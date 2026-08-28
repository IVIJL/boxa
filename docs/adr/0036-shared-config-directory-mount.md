# ADR 0036 — Shared container config via dedicated read-only directory mount

- **Status:** accepted
- **Date:** 2026-08-28

## Context

The host shares two files with every running Container — `allowed-domains.conf`
(input of the in-container firewall) and `dns-upstream.conf` (ADR 0015) — as
two single-file bind mounts into `/etc/boxa-shared/`. Docker pins a file bind
mount to the source inode at container start, so any host-side write that
replaces the inode (`mv`, editor save-via-temp) silently detaches every running
Container from future allowlist changes until restart. A point fix made
`allowlist::remove` rewrite in place, but every future writer re-arms the same
footgun. ADR 0002 already abandoned file-level bind mounts for `~/.claude` for
exactly this reason.

Mounting a directory raises a boundary question: `~/.config/boxa/` must never
be mounted wholesale — it holds `hook-mounts.conf`, the ADR 0025 approval
boundary, and `forge/tokens/` secrets. And `/etc/boxa-shared/` itself cannot
become a read-only mount, because container root writes `.allow-for.state`
into it.

## Decision

A dedicated host directory `~/.config/boxa/shared/` is bind-mounted read-only
at `/etc/boxa-shared/config/` and replaces both single-file mounts. Directory
mounts resolve members by name, so host-side inode swaps no longer detach
running Containers; the ADR 0015 property (file re-read on every restart) is
preserved. `/etc/boxa-shared/` stays an image directory for container-local
state.

The directory's contents are governed by a manifest
(`SHARED_CONFIG_FILES` in `lib/allowlist.sh`): only listed files may live
there, `docker-run.sh` mounts and populates from the manifest, a static test
fails on any codebase reference to an unlisted filename in the shared
directory, and `boxa doctor` warns about unexpected files on the host side.
The manifest is the security control for the one risk a directory mount adds:
a future file dropped into `shared/` would appear in every Container
automatically, so adding one must be an explicit, reviewable manifest change.
Mounting `~/.config/boxa/` itself, or any parent of it, stays forbidden.

Existing installs are migrated by moving both files into `shared/` on first
run, with a one-time warning naming running Containers that still hold the old
file mounts and need a restart. No auto-restart: it would kill live agent
sessions. `allowlist::remove` keeps its inode-preserving in-place rewrite as
protection during the transition window.

## Consequences

- Host-side writers may use ordinary `mv`/temp-file replacement again once the
  transition window closes; the in-place-write discipline stops being
  load-bearing.
- The "truncated in place (Docker snapshots bind mounts by inode)" note in
  ADR 0015 is obsolete under the directory mount; ADR 0011's description of
  `/etc/boxa-shared/` as "bind-mounted shared state" becomes accurate only for
  its `config/` subtree.
- Containers created before the upgrade keep stale file mounts until recreated
  and stop seeing allowlist changes after the host files move.
