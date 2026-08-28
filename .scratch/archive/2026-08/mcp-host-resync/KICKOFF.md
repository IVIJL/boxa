# KICKOFF — mcp-host-resync AFK batch

## Fix batch 4 (2026-08-21, after live test 3 of 7e8a74f)

Issues 09 → 10 (independent, but both touch cli.py — land 09 first).
Branch `fix/mcp-host-resync-live3` off main (tip 7e8a74f). NEVER push.
Same rules as below. Issue 09 REQUIRES a real-pty end-to-end regression
test (pty.fork, no stubbed seams) — the three prior batches missed the
bug precisely because every test stubbed the consent seam. Repro driver
to adapt: /tmp/repro/drive.py.

## Fix batch 2 (2026-08-21, after live host test of beca814)

Issues 03 → 04 → 05 → 06 (06 blocked by 03; 04/05 independent).
Branch `fix/mcp-host-resync-live` off main (tip beca814). NEVER push.
Same rules as below (Codex via MCP, foreground-only, one commit per
issue, single adversarial review loop at the end). Live host
verification again deferred to the user.

Design is FINAL (grill session 2026-08-21, all decisions user-approved):
see `docs/adr/0031-consent-first-credential-takeover-on-import.md`
(committed as 017a6d4, together with the ADR 0030 back-reference and the
CONTEXT.md **Reimport** glossary term). Do not relitigate ADR decisions.

## Order

1. Docs are already committed on main (017a6d4) — nothing to commit
   first this time.
2. Issues in `issues/`: 01 → 02 (independent, but 01 is the payoff
   slice; 02 is small UX).
3. One commit per issue, immediately after its tests are green.

## Rules

- Branch `feat/mcp-host-resync` off main (main tip: 017a6d4). NEVER
  push.
- Coding is delegated to Codex via MCP `boxa-codex-delegate`, always
  from inside a fresh subagent per issue, FOREGROUND calls only (no
  run_in_background anywhere; on an MCP timeout, check the working tree
  first — the work is often complete server-side).
- English UI strings and comments. Shellcheck (incl. info-level) on
  every touched shell script. `python3 -m unittest discover -s tests
  -q` (no pytest in the container) + `tests/picker.sh` where relevant.
- Known pre-existing failures to ignore: 4 WSLg tests, tests/ssh.sh,
  tests/stop-all.sh.
- One final adversarial review loop at the end (Codex), fix or defend
  until clean; distinguish genuine holes from hardening after ~3
  rounds. Consent-first secret takeover is the security-sensitive
  surface — expect reviewer attention on value leaks (stdout/argv/
  json/catalog) and on the no-op-detection/apply shared code path.
- Live host verification is deferred to the user — do not attempt it.
  (User's manual scenario: edit dozzle entry in host ~/.claude.json,
  run `boxa mcp import`, expect the Changed section + consent prompt.)
