# Allowlist shared-config directory mount — grill conclusions (2026-08-28)

Origin: the allowlist inode footgun. `~/.config/boxa/allowed-domains.conf` and
`~/.config/boxa/dns-upstream.conf` are bind-mounted into every Container as
single files (`docker-run.sh:7647`, `:7070`); Docker pins a file bind-mount to
the source inode, so any host-side inode swap (`mv`, editor save-via-temp)
silently detaches every running Container until restart. A partial fix shipped
earlier (`allowlist::remove` rewrites in place, `lib/allowlist.sh:69-79`);
this feature removes the whole failure class.

## Decisions (grilled with user, all confirmed)

1. **Directory mount replaces both file mounts.** New dedicated host dir
   `~/.config/boxa/shared/` holding ONLY `allowed-domains.conf` and
   `dns-upstream.conf`, mounted read-only at `/etc/boxa-shared/config/`.
   Directory mounts resolve members by name, so inode swaps stop mattering
   (precedent: ADR 0002 chose a directory mount for `~/.claude` for exactly
   this reason). ADR 0015's file-vs-env rationale is preserved: the file is
   still re-read on every restart; its "truncate in place" note becomes
   obsolete → amend.
2. **Security boundary unchanged and explicit.** Never mount `~/.config/boxa/`
   itself — it holds `hook-mounts.conf` (the ADR 0025 approval boundary) and
   `forge/tokens/` (0600 secrets, `lib/forge.sh:45`). The `shared/` subdir is
   the only mountable part. RO mount gives no write/unmount path in-container
   (no root path for agents, ADR 0003). `/etc/boxa-shared/` stays an image dir
   so container-root keeps writing `.allow-for.state` next to the new
   `config/` mountpoint.
3. **Manifest + guard rails** (invariant: nothing else ever lands in `shared/`):
   - `SHARED_CONFIG_FILES=(allowed-domains.conf dns-upstream.conf)` in
     `lib/allowlist.sh` as single source of truth; `docker-run.sh` mounts and
     populates from it.
   - Static test in `tests/` greps the codebase for references/writes into the
     shared dir and FAILS on any filename not in the manifest. No CI exists;
     tests run in the pre-commit review loop (/cr, AFK), so adding a third
     file forces a conscious, reviewable manifest bump.
   - `boxa doctor` warns when the host `shared/` dir contains files outside
     the manifest (covers human/editor droppings).
4. **Transition for existing installs.** First run of the new version creates
   `shared/` and moves both files in; print a one-time warning naming running
   `boxa-*` containers (they hold old file mounts and stop seeing allowlist
   changes until recreated). No auto-restart (would kill agent sessions).
   Keep `allowlist::remove`'s in-place rewrite (free protection during the
   transition window); update its comment.
5. **Deferred item #2 (migrate-from-devbox restart) CANCELLED.** The migration
   script is no longer offered anywhere (no README/install.sh references);
   users have migrated. #3 (stale-mount detection) is obsolete under the
   directory mount.
6. **`boxa blocked` dev-URL filter — separate issue in this batch.** Blocked =
   query in the dnsmasq log with no `ipset=` line; dev URLs route via
   `address=` lines so they show as blocked (`docker-run.sh:6379-6395`). Fix:
   also exclude queries covered by `address=` lines read from the same dnsmasq
   config the handler already opens. No hardcoded suffix list.
7. **Doc fixes in the same batch.** Misleading comments claiming
   `.allow-for.state` is bind-mounted (`scripts/start-allow-for-window.sh:44`,
   `scripts/closeout-allow-for-on-restart.sh:12`); ADR 0011's
   "bind-mounted shared state" wording for `/etc/boxa-shared/`; ADR 0015
   truncate-in-place note.
8. **Form:** no PRD (scope too small). ADR 0036 records the decision; issues
   split via /to-issues.

## Affected code (facts gathered 2026-08-28)

- Mounts: `docker-run.sh:7645-7647` (allowlist), `:7070` (dns-upstream).
- Readers in-container: `init-firewall.sh:168-173,281`,
  `scripts/boxa-firewall-reload.sh:40`, `lib/allow-for.sh:98`.
- Paths/constants: `lib/allowlist.sh:22,26`, dns-upstream equivalents near
  `docker-run.sh:7070`.
- Reload fan-out: `reload_firewall_in_containers`, `docker-run.sh:3654-3668`.
- `boxa blocked`: `docker-run.sh:6341-6493` (allowed set `:6371-6376`,
  filter `:6379-6395`).
