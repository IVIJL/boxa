# 02 — Auto-flip to external domain on `boxa up` with vocal banner

Status: done

## Parent

ADR 0024 — decisions 1, 2 and 5 (functional probe on every up,
auto-flip with sticky preference, never mutate user system config).

## What to build

On every `boxa up` on WSL2, after the DNS bootstrap, run the probes
from issue 01 and transition the **DNS degradation** state
(CONTEXT.md § Dev URLs) automatically in both directions:

- **Degrade:** `windows-broken` or `wsl-broken` while
  `preferred=local` → set `active_domain` to the external provider
  (preference stays `local`) and print the full banner: cause named
  from config best-effort ("system limitation, not a boxa bug"
  wording — the mode *systemically cannot work*, not "unsupported"),
  the external URL form to use, the note that `.test` keeps working
  inside Containers and HTTPS works on both domains, exact recovery
  steps, and the promise that boxa switches back automatically.
- **Heal:** `both-ok` while degraded (`preferred=local`,
  `active_domain` external) → flip back and print a one-line
  `.test DNS restored` confirmation.
- The full banner repeats on *every* `boxa up` while degraded — no
  seen-marker, no cache, no TTL.
- A user-chosen external mode (`preferred=external`) is respected:
  probes never flip it back.
- `boxa ports` / `boxa port` while degraded append a one-line
  reminder pointing at `boxa dns-status` (URLs themselves already
  follow `active_domain`).
- `resolver-not-running` and probe tooling failures cause no state
  transition.

## Acceptance criteria

- [x] Degraded probe on `up` flips `active_domain` to external,
      leaves `preferred=local`, prints the full banner
- [x] Successful probe on `up` while degraded flips back and prints
      the restored line
- [x] Banner repeats on every degraded `up`; no cached probe state
      anywhere
- [x] `preferred=external` (user override) is never auto-flipped
- [x] `boxa ports` shows the reminder line only while degraded
- [x] No writes to `.wslconfig` or any Windows-side configuration
- [x] Tests cover both transitions, the sticky-preference guard and
      the no-transition states with mocked probes
- [x] shellcheck clean including info-level findings

## Blocked by

[01-dns-path-probes.md](01-dns-path-probes.md)

## Comments
