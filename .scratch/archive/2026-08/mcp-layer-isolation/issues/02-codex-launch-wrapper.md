# 02 — Codex Agent launch wrapper: `-c` overrides at the canonical binary path

Status: done

## Parent

ADR 0028 — Launch-time MCP injection instead of shared-file renders.

## What to build

Replace the node-owned npm-global `codex` symlink with a wrapper script at the
same canonical path, regenerated at every Container start so an npm update
that restores the symlink cannot outlive the next start. The wrapper execs the
real npm entry point directly (no recursion through itself) and prepends `-c`
overrides derived from the runtime snapshot (reuse issue 01's derivation):

- for every `mcp_servers.*` present in the shared `~/.codex/config.toml` that
  is not an activation of this Project, emit `-c
  mcp_servers.<name>.enabled=false` (computed per invocation, so servers the
  user adds on host later are disabled automatically),
- for every activated entry with consumer codex, emit `-c` definitions
  (command/args through the Boxa MCP launcher; verified working on 0.145.0).

Because the wrapper sits at the canonical path, absolute-path callers, user
skills, and the codex-delegate's fixed `AGENT_PATH` resolution all pass
through it; the delegate's inner Codex sessions therefore also see only the
Container layer. No `AGENT_PATH` change is needed — verify, don't reorder.

Subcommands (`resume`, `exec`, `mcp`, `mcp-server`) must keep working; `-c` is
a global root flag.

## Acceptance criteria

- [ ] A server present only in shared `config.toml` shows `disabled` via
      `codex mcp list` in the Container and is absent from a session —
      derivation logic implemented and unit-tested
      (`_shared_codex_server_names` diffed against activated names emits
      `enabled=false`); not exercised live against a real host
      `~/.codex/config.toml` with a foreign server in this session.
- [ ] An activated catalog entry with consumer codex is live in a Container
      Codex session — derivation logic implemented and unit-tested; not
      exercised live against a real activation in this session.
- [x] Adding a new server to host `config.toml` while the Container runs:
      next Codex invocation disables it without any regeneration step —
      `codex_launch_profile()` reads the shared config fresh on every call,
      no caching/regeneration step exists.
- [x] `codex resume`, `codex exec`, `codex mcp list` work through the
      wrapper; delegate launch path resolves to the wrapper — verified live:
      `codex --version`, `codex mcp list`, `codex exec --help` all pass
      through the generated wrapper at
      `/usr/local/share/npm-global/bin/codex` (root `-c` flags parsed,
      subcommands unaffected); `AGENT_PATH` in `scripts/mcp/trusted.py`
      already resolves `codex` to this path, unchanged.
- [ ] Wrapper survives `npm install -g @openai/codex` followed by Container
      restart — `repair_codex_bin()` is wired into `main()`'s every-start
      section in `scripts/setup-claude.sh` next to `repair_claude_bin`, same
      atomic-mktemp-then-mv pattern; not exercised end-to-end with an actual
      `npm install` + Container restart in this session.
- [x] shellcheck-clean — `shellcheck -S style scripts/setup-claude.sh`
      clean, including info-level.

## Implementation notes

- `scripts/mcp/launch_profile.py`: `codex_launch_profile()` reuses
  `active_project_entries("codex", ...)` from issue 01, reads
  `~/.codex/config.toml` (or an injected `config_path`) via `tomllib`
  (stdlib, no new dependency) to collect existing top-level
  `mcp_servers.*` table names, and emits a flat list of `-c key=value`
  strings: `enabled=false` for every shared name not in this Project's
  activation, and `enabled=true` + `command=` + `args=` (JSON-encoded) for
  every activated codex entry via `boxa-mcp-run` (`WRAPPER_COMMAND`).
- `scripts/mcp/cli.py`: new `codex-launch-profile` subcommand
  (`_cmd_codex_launch_profile`), prints one override per line, exit 1 with
  no stdout on `LaunchProfileError`/`TrustedAuthorizationError`, mirroring
  `claude-launch-profile`.
- `scripts/setup-claude.sh`: `repair_codex_bin()` regenerates
  `/usr/local/share/npm-global/bin/codex` every Container start (mktemp +
  heredoc + atomic `mv -f` + chmod 0755, same pattern as
  `repair_claude_bin`); the generated wrapper execs the real npm entry
  point (`.../@openai/codex/bin/codex.js`) via `node` directly (no
  recursion), loops derived overrides into `-c` flags, and falls back to
  `-c mcp_servers={}` + a stderr warning on any derivation failure —
  verified this fallback path does not block a live `codex` invocation.
- Test coverage added in `tests/test_mcp_launch_profile.py` for the
  derivation function, dynamic shared-config re-read, the CLI subcommand,
  and the error fallback. No shell/bats harness exists for
  `repair_claude_bin`/`setup-claude.sh`, so none was added for
  `repair_codex_bin` either (deviation, matches existing project
  convention — see CONTRIBUTING.md, shell coverage there is
  self-contained smoke scripts like `tests/test_provisioning.sh`, not a
  per-function harness).
- Full suite verified independently of Codex's own report:
  `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_*.py'`
  → 792 passed, 0 failed. `shellcheck -S style scripts/setup-claude.sh` →
  clean.

## Blocked by

01-claude-launch-wrapper.md (shared profile derivation).

## Comments
