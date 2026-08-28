# 36 — Auto mode silently drops trailing arguments (`boxa easymusic ssh off` attaches)

Status: done
Type: AFK

## Parent

Live verification round 3, 2026-08-26.

## What happened (live repro)

`boxa easymusic ssh off` fell into MODE=auto (first arg is not a
subcommand), attached to the project, and silently threw away
`ssh off`. Similarly `boxa forge off easymusic` on an older install
turned into "attach container boxa-forge → picker". The user believed
the command ran; nothing told him the arguments were ignored.

Root cause: the auto-mode tail of docker-run.sh (flag loop ~6489, then
`${1:-.}` directory branch ~6511 and token branch ~6553) consumes at
most one positional and never checks `$#` afterwards.

## What to build

- After the auto-mode flag loop, when more than one positional remains,
  exit 1 with a usage error naming the extra arguments, e.g.:
  `Unexpected arguments after '<target>': ssh off`.
- When the **second** positional matches a known subcommand word (the
  literals of the main `case` in the subcommand parser: ls, mem, ssh,
  forge, stop, remove, port, ports, connect, connections, allow, deny,
  blocked, allow-for, agent-browser, mcp, cursor, code, ssh-config,
  clip, claude-token, build, update, doctor, keep-awake, dns-install,
  dns-status, dns-uninstall, uninstall, prune, sync-skills, help),
  add a reorder hint on the next line:
  `Did you mean: boxa <subcommand> <remaining args> <target>` —
  best-effort word order (subcommand first, target last) is enough;
  do not try to fully re-parse the intended command.
- Zero or one positional keeps today's behavior exactly (bare `boxa`,
  `boxa <project>`, `boxa <path>`, with `--memory`/`--ssh-config`
  overrides).
- Keep `_boxa::cli_override_container` / the resource sweep untouched —
  they pre-read raw argv and must not start rejecting anything.
- UI strings EN.

## Acceptance criteria

- [x] `boxa <project> ssh off` exits 1 with the unexpected-arguments
      error and the reorder hint; nothing starts or attaches.
- [x] `boxa <project> blah` (second word not a subcommand) exits 1 with
      the error, no hint required.
- [x] Bare `boxa`, `boxa <project>`, `boxa <path>`, and flag overrides
      behave exactly as before.
- [x] shellcheck clean (incl. info); test coverage in the existing
      shell-suite style for the reject and the unchanged single-target
      path (a pure-parsing test without Docker is fine).

## Blocked by

(none)

## Comments
