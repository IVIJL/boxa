# 03 — Emergency PID 1 shutdown fallback

Status: done

## Parent

ADR 0035 — Compose-aware inner shutdown.

## What to build

Complete the emergency path used when an outer Container receives SIGTERM
without a successful explicit Boxa pre-stop cleanup. Outer stop operations no
longer override the Container's configured stop timeout with a shorter
fifteen-second deadline. PID 1 remains deliberately simpler than the explicit
Compose-aware path: it discovers only running Inner containers, starts one
graceful stop per container concurrently, waits for them, and exits without
Compose discovery or container removal.

This fallback must remain best-effort so a failed inner stop cannot trap the
outer Container forever. Document the distinction between explicit Boxa stop,
which removes inner container records, and direct Docker/SIGTERM shutdown, which
only attempts to stop running workloads before the outer deadline.

## Acceptance criteria

- [ ] Normal outer stop operations use the Container's configured 45-second
      stop timeout rather than explicitly overriding it with 15 seconds.
- [ ] On SIGTERM, PID 1 launches graceful stops for all currently running Inner
      containers concurrently and waits for every launched job.
- [ ] The fallback does not perform Compose discovery, remove containers, remove
      volumes, or prevent outer exit when an individual inner stop fails.
- [ ] Regression tests prove that multiple inner stops begin concurrently and
      that direct SIGTERM remains bounded by the outer Container deadline.
- [ ] Documentation clearly distinguishes explicit Compose-aware Boxa shutdown
      from the emergency PID 1 fallback and no longer describes the old
      sequential timeout chain.
- [ ] Every changed shell script passes `shellcheck` including informational
      findings, apart from documented false positives.

## Blocked by

- `02-degraded-cleanup-and-error-aggregation.md`

## Comments
