# ADR 0038 — Identity subid mapping for the inner engine

- **Status:** accepted
- **Date:** 2026-09-14
- **Revises:** the fixed `node:100000:65536` subordinate-ID allocation

## Context

The host Docker engine writes service UIDs directly into Project bind mounts,
while Boxa's inner rootless engine previously mapped inner UID `N` to host UID
`100000 + N - 1`. Switching engines over the same PostgreSQL, MySQL, Redis, or
similar state therefore changed which process could access it. The failure was
delayed until the other engine started and surfaced as misleading permission
errors.

An experiment on 2026-09-14 established that an identity subordinate-ID range
split around the Container user's UID lets both engines write the same low
UIDs. It also established that putting the inner data-root on the Container's
overlay rootfs causes nested-overlayfs mounts to fail with `EINVAL`; the
data-root must remain in the `boxa-<project>-docker` volume.

## Decision

At every Container start, the root entrypoint reads the actual UID `U` of
`node` and replaces `/etc/subuid` and `/etc/subgid` with:

```text
node:1:(U-1)
node:(U+1):(65536-U)
```

The zero-length first range is omitted when `U=1`; when `U` is 65536 or
higher, nothing fits above the hole and the single range `node:1:65535`
identity-maps the whole budget below it. Rootless container root
continues to map to `U`; inner IDs below `U` map identically, and inner IDs at
or above `U` map one higher, so `U` maps to `U+1`. The two subordinate ranges
contain 65535 IDs and contain neither host UID 0 nor `U`. The ownership
check treats `U` and every host ID the generated ranges can emit as expected:
1..65536 when `U` is below 65536 (inner ID 65535 shifts to 65536), 1..65535
otherwise. Repairs walk only the Project root's own filesystem: nested mount
points are skipped, not just left undescended.

The mapping belongs to the Container, independent of Project Compose files.
The inner data-root remains `/home/node/.local/share/docker` on the existing
`boxa-<project>-docker` volume.

The entrypoint stamps that volume with `.boxa-subid-map`. A missing stamp on a
non-empty data-root identifies storage written under the old fixed mapping.
Before the daemon starts, the root phase walks the complete data-root and
remaps UID and GID independently from the old range into the new identity map,
printing counts and elapsed time. It writes the stamp only after success. An
unknown stamp, an unrepresentable old owner, or any failed walk leaves storage
unstamped; node-side daemon startup then refuses and directs the user to run
`boxa stop --clean <project>` on the host.

The security boundary is the Container's mount namespace, not UIDs. Container
root already runs identity-mapped as UID 0 and can write any UID into the
bind-mounted Project and Boxa volumes; letting the rootless engine emit low
UIDs there gives inner processes nothing new. No privileges, capabilities, or
host changes are added.

Identity mapping cannot make host UID 0 writable by the rootless inner engine.
The entrypoint therefore performs a depth-three, same-filesystem ownership
scan of the Project root before dropping privilege. It prunes well-known heavy
directories. Under the default `ownership_fix=auto`, root-owned subtrees are
changed recursively to `U:U`; large repairs continue in the background and
write completion to `/var/log/boxa-ownership.log`. A scan exceeding 500 ms becomes
warn-only for that start. Owners from the former `100000+` map and unexpected
owners are also reported, but only `boxa doctor --fix ownership` performs the
old-map per-entry remap during its unlimited-depth scan.

The policy is host-global because the entrypoint must consume it too. It lives
in the shared, read-only-mounted `~/.config/boxa/shared/ownership.conf` as
`ownership_fix=auto|warn|off`; a missing key defaults to `auto`.

## Consequences

- Postgres UID 70 and MySQL/Redis UID 999 are written as host 70 and 999 by
  both engines when `U=1000`.
- Inner root remains host `U`, preserving the rootless boundary.
- Inner IDs greater than or equal to `U` are shifted by one; callers must not
  assume identity mapping across the hole.
- Existing image layers, writable layers, and named volumes incur one bounded
  ownership walk on their first start after upgrade. A failed or impossible
  migration is explicit and requires cleaning the per-Project Docker volume.
- Nested overlayfs is not introduced; storage stays in the named volume.
- Host-engine root writes are repaired without Compose knowledge. Host root
  remains able to use state subsequently owned by `U`.
