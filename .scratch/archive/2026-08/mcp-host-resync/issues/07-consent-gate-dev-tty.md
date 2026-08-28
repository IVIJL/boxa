# 07 — Consent prompts gated on stdin isatty but read /dev/tty

Status: done

## Parent

Live-test regression of issue 01/07 fixes (#mcp-host-resync, d75eb07).
Second live run: wizard answered y/y/y, then "Skipped credential
values for dozzle: Authorization" — the per-value consent prompt never
appeared.

## Root cause (confirmed)

The python consent gates test `sys.stdin.isatty()`:

- `scripts/mcp/cli.py:1011` `secret_consent=_secret_consent if sys.stdin.isatty() else None`
- `scripts/mcp/cli.py:1162` `_secret_consent if not as_json and sys.stdin.isatty() else None`
- `scripts/mcp/cli.py:852` same gate in `_wizard_degradation_consent`

but the prompts themselves never touch stdin — they open `/dev/tty`
directly (`cli.py:939-946`, `:855`). The bash wizard made the opposite
(correct) choice: every prompt reads `/dev/tty` via `_tty_read`
(`scripts/mcp-cli.sh:799-808`), so the whole bash flow works even when
fd 0 is not a terminal — and the python consent is the single
component that silently degrades to the non-TTY "skipped + secret set
hint" path. Detection had already read the host value in the same run
("host values differ" in the diff), so the value was available; only
the gate was wrong.

Tests missed it because both sides stub the seam: python tests patch
`sys.stdin.isatty` AND `_secret_consent`
(`tests/test_mcp_catalog_import.py:305`, `:441`, `:518`); the shell
wizard test stubs `_run_py*` entirely (`tests/test_mcp_apply.py:
967-994`). No test lets a real python inherit the wizard's fds.

## What to build

- Replace the `sys.stdin.isatty()` consent gates with a "controlling
  terminal usable" probe: one shared helper that attempts
  `open("/dev/tty", "r+")` (closing it) and caches nothing surprising;
  use it at all three gate sites. `--json` still unconditionally
  disables consent. When `/dev/tty` is unusable, behavior is exactly
  today's non-TTY path (key-only declaration, skipped names, hint).
- Add a test seam so the probe/prompt can be exercised without a real
  terminal (mirror the shell's `BOXA_MCP_TEST_INTERACTIVE` idea or a
  patchable module-level probe) and write a regression test where
  python's stdin is a PIPE yet consent still fires (probe patched
  usable) — the exact live failure shape.
- Audit for any other `sys.stdin.isatty()` gate guarding a
  `/dev/tty`-reading prompt in scripts/mcp/ and fix the same way
  (state the audited sites).

## Acceptance criteria

- [x] With stdin a pipe and a usable /dev/tty (test seam), the secret
      consent prompt fires during wizard apply and an accepted value
      lands in the store (readiness ready, no "Skipped credential
      values" line).
- [x] With /dev/tty unusable, exact current non-TTY behavior and
      messages, including `--json` (tests).
- [x] `_wizard_degradation_consent` gate fixed identically (test).
- [x] Secret values still never in stdout/argv/json/catalog (existing
      assertions green).
- [x] Tests green (`python3 -m unittest discover -s tests -q`),
      shellcheck clean on touched shell scripts (if any — none touched).

## Blocked by

None.

## Comments

- 2026-08-21: Live run 2: detection showed the secretValues diff, all
  bash prompts worked, python consent silently skipped — user got
  "Next: boxa mcp secret set" despite consenting to reimport.
