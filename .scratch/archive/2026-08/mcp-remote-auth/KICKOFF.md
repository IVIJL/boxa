# KICKOFF — mcp-remote-auth AFK batch

Design is FINAL (grill session 2026-08-21, all decisions user-approved):
see `docs/adr/0030-broker-proxied-auth-headers-for-remote-mcp.md` and
`KICKOFF-NOTES.md`. Do not relitigate ADR decisions.

## Order

1. First commit the docs: ADR 0030 (already written, uncommitted).
2. Issues in `issues/`: 01 → 02 → {03, 04 in either order; 03 is the
   payoff slice}.
3. One commit per issue, immediately after its tests are green.

## Rules

- Branch `feat/mcp-remote-auth` off main (main tip: 374dd25). NEVER push.
- Coding is delegated to Codex via MCP `boxa-codex-delegate`, always from
  inside a fresh subagent per issue, FOREGROUND calls only (no
  run_in_background anywhere; on an MCP timeout, check the working tree
  first — the work is often complete server-side).
- English UI strings and comments. Shellcheck (incl. info-level) on every
  touched shell script. `python3 -m unittest discover -s tests -q` (no
  pytest in the container) + `tests/picker.sh` where relevant.
- Known pre-existing failures to ignore: 4 WSLg tests, tests/ssh.sh,
  tests/stop-all.sh.
- One final adversarial review loop at the end (Codex), fix or defend
  until clean; distinguish genuine holes from hardening after ~3 rounds.
- Live host verification is deferred to the user — do not attempt it.
