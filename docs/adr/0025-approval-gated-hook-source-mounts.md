# ADR 0025 — Approval-gated mounts for hook-sourced host files

- **Status:** accepted
- **Date:** 2026-08-14
- **Builds on:** ADR 0002 (shared Claude config via bind mount)

## Context

Per ADR 0002 the whole `~/.claude` (and `~/.codex`) tree is bind-mounted
into every container, so hook scripts and anything stored next to them
work identically on both sides. That breaks down for a hook that
`source`s a file *outside* those trees — the emerging convention for
notification credentials is a machine-local env file under
`~/.config/<tool>/`, deliberately kept out of any synced tree. Inside a
container that path is empty and the hook goes silently dead: no error a
user would see, notifications just stop.

The previous stopgap was worse: `docker-run.sh` grepped `~/.claude/hooks/*.sh`
for string literals shaped like one specific notification service's tokens
and forwarded the match as container env. It only worked for secrets
pasted inline into hooks, was hardwired to one provider's token format,
and would happily harvest a lookalike string from any unrelated script in
the directory.

Two constraints shape the fix:

1. **No hook execution on the host.** Learning where a hook reads its
   config must not mean running the hook.
2. **The shared trees are agent-writable.** Every container can edit
   `~/.claude/hooks/*`. Any mechanism that turns "a hook references path
   X" directly into "X is visible in all containers" hands agents a
   delayed arbitrary-file-read of the host (`~/.ssh`, `~/.config/gh`, …)
   via a one-line hook edit.

## Decision

At container start, `docker-run.sh` **statically resolves** `source` / `.`
statements in `~/.claude/hooks` and `~/.codex/hooks` scripts: parameter
expansion (`$VAR`, `${VAR}`, `${VAR:-default}` nested, leading `~`) is
evaluated in-process against assignments seen earlier in the same hook and
the host environment; command substitution and pattern operators are
refused. Resolution failures, relative results, and paths that do not
exist or already live inside the shared trees are dropped — the failure
mode is always "no mount", never a wrong one.

Each remaining path is subject to a **per-path interactive approval**,
persisted in `~/.config/boxa/hook-mounts.conf`: a plain `~/`-relative line
is approved, a `# `-prefixed line is denied and never asked about again.
Approved paths are mounted **read-only** at the container-side equivalent
location (host `$HOME`-relative → `/home/node`-relative); a hook that
hardcodes the host-literal home path still works, because the entrypoint
mirrors `/home/node` onto host `$HOME` with per-entry symlinks (ADR 0004).
Non-interactive starts never mount unapproved paths and never
persist a denial the user did not make; they print a pointer to the conf
file. Approved conf lines are mounted even when discovery cannot parse the
source expression that motivated them, which is what makes the file a
genuine manual escape hatch.

The conf lives outside every bind mount, so the approval — not the
discovery — is the security boundary: an agent can add a `source` line,
but only the user at a host terminal can turn it into a mount, and the
prompt names the exact path being requested. When the selected project
would itself expose the conf read-write (the project is `~/.config` or an
ancestor), the feature is disabled for that start — the boundary, not the
convenience, wins. Discovered paths are canonicalised before approval, so
a symlink in an agent-writable location cannot be repointed at a host
secret after its approval; the mount exposes the canonical file at the
location where the hook's own spelling resolves in the container.

The token grep is deleted, and so are the provider-specific env
passthrough (with the matching `localEnv` forwarding in the devcontainer
variants) and the seeded notify hooks themselves: they were the author's
personal setup leaked into the defaults — without his notification
config, and with no sounds shipped at all, a fresh install got hooks
that only wrote a log line on every Stop/Notification event. Anyone who
wants notifications brings their own hook; whatever config file it
sources is mounted by this mechanism. No notification service is
hardwired anywhere in the repo.

## Consequences

- Hooks that source machine-local config work identically in containers
  after one `y` answer per machine, regardless of which service or path
  convention the user picked.
- New approval prompts appear only when a hook starts sourcing a new
  outside path — a signal worth a human glance precisely because agents
  can write hooks.
- Secrets inline in hook files keep working with no prompt (they travel
  with the ADR 0002 mount), so the deleted grep loses no capability.
- Installed notify-hook copies still byte-for-byte a shipped version are
  retired on start (sha256-gated file delete + exact-entry unwire, the
  interaction-hook pattern). A customized copy keeps its file and wiring
  — its owner just migrates credentials themselves, since the env
  passthrough is gone.
- Mounts are fixed at container start; approving a path or adding a new
  `source` line takes effect on the next start.
- Static resolution knowingly skips exotic constructions (command
  substitution, associative lookups); those users add one line to the
  conf by hand.
