# 09 — Consent never fires: open("/dev/tty", "r+") fails on every real terminal

Status: done

## Parent

Third live failure of the consent flow (#mcp-host-resync, 7e8a74f).
User answered y/y/y, still got "Skipped credential values for dozzle:
Authorization". Issue 07 replaced the wrong gate (`sys.stdin.isatty()`)
with a /dev/tty probe — but the probe itself is broken.

## Root cause (confirmed by in-container PTY reproduction)

`open("/dev/tty", "r+", encoding="utf-8")` raises
`io.UnsupportedOperation: File or stream is not seekable` on EVERY real
terminal: mode "r+" makes Python wrap the fd in `BufferedRandom`, which
requires a seekable stream, and a tty is never seekable. So:

- `_controlling_terminal_usable` (`scripts/mcp/cli.py:854`) returns
  False on every real terminal → `secret_consent=None` → the takeover
  silently skips with the "Skipped credential values" + "Next: boxa mcp
  secret set" path. This is NOT host-specific; it reproduces in this
  container under `pty.fork()`.
- `_secret_consent` (`cli.py:952`) and `_wizard_degradation_consent`
  (`cli.py:866`) open /dev/tty the same way and would fail identically
  even if the probe passed.

Verified under a pty: `open("/dev/tty", "r+")` → UnsupportedOperation;
split handles (`open("/dev/tty", "w")` + `open("/dev/tty", "r")`) work;
`io.TextIOWrapper(io.FileIO(os.open("/dev/tty", os.O_RDWR), "r+"),
write_through=True)` works.

Why three rounds of tests missed it: every test stubbed the probe or
`_secret_consent` (patched seam); no test ran the real python prompt
against a real pty. Reproduction driver: `/tmp/repro/drive.py` (sandbox
HOME + `pty.fork()` + real `scripts/mcp-cli.sh import --apply`,
`BOXA_PICKER_FZF=0`), exact live output shape reproduced including
"changed: no (in sync)" + "Skipped credential values".

## What to build

- One shared helper that opens the controlling terminal correctly
  (unbuffered `io.FileIO(os.open("/dev/tty", os.O_RDWR), "r+")` wrapped
  in `TextIOWrapper(..., write_through=True)`, or split read/write
  handles). Use it at ALL three sites (`cli.py:854`, `:866`, `:952`).
  The probe must exercise the SAME open call the prompts use, so probe
  success implies prompt success.
- MANDATORY regression test with a REAL pty (`pty.fork()`), no stubbed
  seams: sandbox HOME with an http server carrying a secret header,
  entry pre-cataloged without the value, then interactive
  `mcp-cli.sh import --apply` (BOXA_PICKER_FZF=0) driven through the
  pty answering the numbered picker + y/n prompts. Assert: the consent
  prompt text appears in the transcript, answering y stores the value
  (present in the secrets file under the sandbox), and NO "Skipped
  credential values" line is printed. Base it on /tmp/repro/drive.py.
- A second pty case answering n → value NOT stored, skipped line
  present (consent decline still works).
- Audit result: the three cli.py sites are the only python
  `open("/dev/tty", "r+")` users in scripts/ (grep verified); fix all
  three via the shared helper.

## Acceptance criteria

- [x] Real-pty end-to-end test: consent fires, y stores the header
      value, no "Skipped credential values" (the exact live shape).
- [x] Real-pty decline test: n keeps today's skip behavior.
- [x] No-tty behavior unchanged (pipe stdin, no controlling terminal →
      key-only declaration + hint; existing tests green).
- [x] Secret values still never on stdout/argv/json/catalog.
- [x] Tests green (`python3 -m unittest discover -s tests -q`),
      shellcheck clean on touched shell scripts (likely none).

## Blocked by

None.

## Comments

- 2026-08-21: Filed from live run 3. The bash prompts work because bash
  redirection has no buffered-random requirement; only the python
  consent layer was dead — on every terminal, everywhere, since the
  feature landed.
