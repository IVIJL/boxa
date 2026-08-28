# 01 — boxa mem set: durable Memory limit from the CLI

Status: done

## Parent

ADR 0020 — per-project memory limits. This issue adds a CLI writer for
the host-owned config that ADR 0020 defines; it changes no enforcement
semantics.

## What to build

`boxa mem set` makes the **Memory limit** and **Memory+swap limit**
durably configurable without hand-editing `~/.config/boxa/resources.conf`:

- `boxa mem set <size> [project|path]` — writes `memory` into the
  project's section, keyed by **absolute host path** (ADR 0005 rule).
  Target resolution mirrors `boxa mem`: default is the CWD's project;
  an explicit name or path is accepted.
- `boxa mem set --global <size>` — writes the global `memory` key.
- `--swap <size>` — additionally writes `memory_swap` in the same scope.

The write is a read-modify-write that preserves everything else in the
file: comments, unrelated sections, unknown lines. Only the targeted
key(s) in the targeted scope change; a missing section or file is
created. Sizes are validated with the shared size parser **before**
touching the file — an invalid size, or `memory_swap < memory` for the
resulting effective pair, rejects the command and leaves the config
untouched.

Warning parity with ADR 0020 at set time: a limit above host RAM prints
the protection-void warning; when the new limit plus running Containers'
limits exceed host MemTotal, the joint-exhaustion warning prints. Neither
refuses the write (caps are the trusted host user's call).

After a successful write the existing live-convergence path applies the
new limits to the project's running Container (`docker update` sweep) and
prints the standard convergence notice — the setting takes effect without
a restart. Precedence is unchanged: one-shot CLI flag > project section >
global key > derived default.

Docs and completions ship with the command: `docs/memory.md` documents
`mem set` alongside the config file, and shell completions learn the new
subcommand and flags.

## Acceptance criteria

- [x] `mem set <size> [project|path]` writes the project section keyed by
      absolute host path; `--global` writes the global key; `--swap`
      writes `memory_swap` in the same scope
- [x] Comments, unrelated sections, and unknown lines in
      `resources.conf` survive the rewrite byte-identically
- [x] Invalid size or `memory_swap < memory` rejects with the shared
      parser's message and leaves the file untouched
- [x] Over-host-RAM and joint-exhaustion warnings print at set time,
      wording consistent with the startup checks
- [ ] A running Container for the target project converges to the new
      limits immediately, with the standard convergence notice
      — code + unit tests green (convergence sweep reused after write),
      but live verification against a running Container is deferred to
      the host (no host docker inside this container)
- [x] `docs/memory.md` and shell completions updated
- [x] Unit tests cover writer round-trips (preservation, section
      creation, both scopes, `--swap`) and validation rejects;
      `shellcheck` clean (including info-level)

## Blocked by

None — can start immediately.

## Comments

- Review fix (947489e): global writer now tracks/appends missing global keys independently — `mem set --global` with existing `memory` but missing `memory_swap` no longer silently drops `--swap`.
- Review fix (947489e): global set/unset now validates every affected project's resulting effective memory/memory_swap pair before replacing the file; invalid results are rejected with the offending section named and the config left untouched.
- Review fix (0e271a4): joint-exhaustion warning after `mem set` now projects post-change limits — resolves each running Container's effective limit from the just-written resources.conf (effective sum mode) instead of adding the new value to a sum still containing the old one; fixes double-count on project update and under-count on --global inheritance.
- Review fix (4f4cf14): durable writer rejects project paths containing '#' (unrepresentable in resources.conf per strict parser, ADR 0020) for both mem set and mem unset; error names the path and points at one-shot --memory workaround; config left byte-identical.
- Review fix (9a0cdc0): writer path validation now rejects CR/LF alongside '#' in project paths for set and unset (multi-line section header would corrupt resources.conf); same error style with one-shot --memory workaround.
- Review fix (dee51f4): project-scope mem set capacity warning now counts a stopped/not-yet-created target's new limit as the proposed amount (running target keeps proposed=0 replacement semantics via effective sum mode); seam-aware helper + regressions for both scenarios.
- Review fix (f11506a): writer (set and unset paths) classifies a line as a resource key only when it contains '=' (mirrors loader); bare unknown lines like 'memory' or 'memory # note' pass through byte-identically and keep their section alive.
- Review fix (d3aed9c): invocation-time convergence sweep is skipped for mem set/mem unset (round 8 P1) — the target Container is no longer converged to the OLD config before the write (could OOM-kill under a higher live one-shot limit); mutations sweep once after the config write, plain mem and other commands sweep unchanged; regressions cover set, unset, plain mem, other commands.
