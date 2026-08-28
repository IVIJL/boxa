# 02 — Per-command help

Status: done

## Parent

None — the help output is not covered by an ADR.

## What to build

Second level of the two-level help: `boxa <command> --help` (and the
equivalent `boxa help <command>`) prints detailed help for one command,
carrying the prose relocated out of the overview by issue 01 — full
subcommand lists, behavioural notes, ADR pointers, and the command's
examples.

Commands that must have per-command help: `agent-browser`, `mcp`,
`allow-for`, `mem`, `doctor`, `build`, `ports`, `connect`. Commands
without a dedicated text fall back to printing their overview line plus
the standard footer.

The `agent-browser` and `mcp` dispatchers already have their own `-h`
branches; those unify with this mechanism so each command family has
exactly one source of detailed help text (no drift between `boxa
agent-browser --help` and `boxa help agent-browser`).

An unknown command name errors with a short message and points at `boxa
help`. The overview from issue 01 gains a one-line footer: "Run 'boxa
<command> --help' for details."

## Acceptance criteria

- [x] `boxa <cmd> --help` and `boxa help <cmd>` print the same detailed
      text for the listed commands
- [x] Relocated overview prose (ADR pointers, subcommand details,
      examples) lives in per-command help — nothing from the pre-issue-01
      help content is lost
- [x] Existing `-h` branches of `agent-browser` and `mcp` produce the
      unified text (single source per command family)
- [x] Unknown command errors and refers to `boxa help`; overview footer
      advertises per-command help
- [x] Tests cover at least one per-command help text, the fallback, and
      the unknown-command error; `shellcheck` clean (including info-level)

## Blocked by

`01-sectioned-overview-help.md` — edits the same help function and
dispatcher.

## Comments
- Review fix (0e271a4): global help interception narrowed to -h/--help only; a literal second token `help` falls through to normal parsing so a Project named "help" stays addressable (word form remains `boxa help <command>`).
- Review fix (fe25030): DNS-family help (dns-install/dns-status/dns-uninstall) delegates to scripts/dns-install.sh usage instead of the one-line fallback, so detailed options (--auto, --enable-https, --disable-https) stay visible with no duplicated option list.
