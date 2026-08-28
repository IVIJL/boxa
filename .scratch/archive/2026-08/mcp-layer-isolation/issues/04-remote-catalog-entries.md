# 04 — Remote MCP catalog entries (http)

Status: done

## Parent

ADR 0029 — Everywhere entries, pending activation, and remote catalog entries.

## What to build

A Remote MCP catalog entry carries a URL instead of `command.argv`: no MCP
execution mode, no runtime readiness, no broker/launcher involvement — the
agent connects out itself, gated by the Allowlist. End to end:

- catalog schema + validation for the http kind (URL required, argv/execution
  mode forbidden), CLI add/update paths, runtime snapshot carries it,
- both wrappers inject it natively: Claude as `{"type":"http","url":…}` in
  the strict config, Codex as `-c mcp_servers.<name>.url=…` (both transports
  verified working when added manually),
- import/discovery stops excluding `type=http` candidates and can propose
  them,
- readiness/status for a remote entry reports "no runtime readiness"; when
  the URL's domain is not in the Allowlist, status shows a hint naming
  `boxa allow <domain>` (hint only, no live probe),
- activation works without the target Boxa running (nothing to probe).

## Acceptance criteria

- [ ] An http entry (e.g. the Dozzle scenario) activates and its tools work in
      a Container Claude and Codex session with the domain allowlisted —
      deferred: needs a live Container Claude/Codex session, not testable
      from the unit suite; leaving for the user's own live check
- [x] The same entry is invisible to host agents (falls out structurally:
      the launch wrapper is Container-only and reads only the Container
      runtime snapshot; covered by launch_profile tests)
- [x] Import proposes a discovered http server instead of excluding it
      (classify.py/providers/catalog_import.py + tests)
- [x] Status on a non-allowlisted remote entry names the missing domain
      (`readiness.remote_allowlist_hint` + CLI wiring, tests)
- [x] Activating a remote entry with the Boxa stopped succeeds immediately
      (`readiness_for_entry`/`activation.py` skip the running-container
      check for `type == "http"`, tests)

## Blocked by

01-claude-launch-wrapper.md, 02-codex-launch-wrapper.md.

## Comments

Implemented via Codex delegation (thread 01a022e7-bba9-78b1-9d17-5bbf20dfc1dd),
commit aa7db65. Catalog schema/validation, add/update CLI paths (`--url`),
runtime snapshot pass-through, both launch wrappers (Claude
`{"type":"http","url":...}`, Codex `-c mcp_servers.<name>.url=...`),
import/discovery no longer excludes `type=http` (other remote types like
`sse` remain excluded, out of scope here), readiness/status report
"no-runtime-readiness" + `boxa allow <domain>` hint (host-side allowlist file,
text hint only, no live probe). Everywhere entries and Pending activation are
explicitly out of scope (issues 05/06). Full suite: 527 passed (baseline 518 +
9 new), 0 failed; shellcheck clean on the touched shell script.
