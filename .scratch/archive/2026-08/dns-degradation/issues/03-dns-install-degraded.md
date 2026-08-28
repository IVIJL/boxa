# 03 — dns-install on a system-incompatible setup: skip dead artifacts, never uninstall

Status: done

## Parent

ADR 0024 — decisions 4 and 6 (leave installed artifacts in place,
certificates always).

## What to build

Make `boxa dns-install` and the related provisioning honour the probe
verdict on WSL2:

- **Fresh install on a broken path:** skip installing the NRPT rule
  and the resolved drop-in entirely — no dead configuration, no
  pointless UAC prompt. Set the external domain active (preference
  stays `local`), print the degradation banner, and finish
  successfully. mkcert CA and per-project certificates install
  exactly as today — the external HTTPS URLs terminate at the local
  Traefik and need them (SANs already cover both domains).
- **Degrade-later:** when an already-installed setup starts failing
  the probe, nothing is uninstalled — NRPT and the drop-in stay in
  place (dead but harmless; removing and re-adding would cost a UAC
  round-trip each way). Self-heal paths must not remove them either.
- **Heal-later:** once the probe passes again on a system where the
  artifacts were skipped, the normal provisioning entry points
  (`dns-install`, `boxa update` self-heal, `boxa doctor`) install the
  missing NRPT rule and drop-in — the single UAC prompt happens at
  the moment it is useful.
- `dns-uninstall` behaviour is unchanged.

## Acceptance criteria

- [x] Fresh install with a failing probe skips NRPT + drop-in, keeps
      cert provisioning, activates external, prints the banner, exits
      successfully
- [x] Fresh install with a passing probe behaves exactly as today
- [x] No code path removes NRPT or the drop-in in reaction to a
      failing probe
- [x] After the probe passes, provisioning installs the previously
      skipped artifacts; repeated runs stay idempotent
- [x] Tests cover skip, no-uninstall and late-install flows with
      mocked probes and interop shims
- [x] shellcheck clean including info-level findings

## Blocked by

[01-dns-path-probes.md](01-dns-path-probes.md)

## Comments
