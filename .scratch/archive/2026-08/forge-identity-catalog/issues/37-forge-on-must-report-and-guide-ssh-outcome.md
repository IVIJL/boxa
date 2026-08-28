# 37 — `forge on` leaves the SSH gate off silently when no keyed persona is assigned

Status: done
Type: AFK

## Parent

Live verification round 3, 2026-08-26; follow-up to issue 35 (forge
off/on drives the synthesized gate) and issue 34 (`ssh on` persona
follow-up).

## What happened (live repro)

`boxa forge on /home/vlcak/Projekty/easymusic` printed only
"Forge access set to on for …". The user recreated the container and
only the start banner revealed "SSH: gate off (enable: boxa ssh on)" —
a wasted recreate. Cause: with no assigned persona (or a keyless one)
the synthesized gate stays off, and
`_boxa::forge_apply_project_ssh_gate` (lib/forge.sh ~3522, called from
`_boxa::forge_set_gate_locked`) reports only on old != new, so
off → off says nothing. The user expected `forge on` to either bring
SSH up or say explicitly that the next step is missing.

## What to build

`boxa forge on` (project scope) must always state the resulting SSH
forwarding for the project, and guide when it stays off. Decided by
the user 2026-08-26 ("mel by automaticky zapnout ssh pokud je vyple
anebo alespon upozornit ze dalsi krok je zapnout").

- **Gate flips on** (keyed persona assigned): keep today's change
  line; nothing else needed.
- **No persona assigned:** reuse the issue-34 `ssh on` follow-up: on a
  TTY, launch the persona assignment flow with this project
  preselected (same helper as the `ssh on` no-persona path, incl. the
  cancel note); without a TTY, print an explanation naming the next
  command (`boxa forge use`).
- **Keyless persona assigned:** print the issue-34 style explanation
  naming the persona and pointing to attaching keys in `boxa forge`
  (no picker, exit 0 — the forge access change itself succeeded).
- **Result line always:** after the follow-up resolves, print one
  summary line of the project's SSH forwarding state (on with persona
  name and key count, or still off with the reason), so the user knows
  before any container recreate whether it was worth it. Reuse
  existing wording patterns; do not invent a new format if a suitable
  helper exists.
- `forge on --global`: per affected project keep the change lines as
  today; do not launch interactive follow-ups per project — print the
  still-off reason lines instead.
- `forge off` unchanged. UI strings EN.

## Acceptance criteria

- [x] `forge on` with no assigned persona (TTY) launches the
      assignment flow preselected on the project; cancel leaves forge
      on and prints the still-off note. Non-TTY prints the guidance
      instead.
- [x] `forge on` with a keyless persona prints the persona-named
      explanation, exit 0.
- [x] `forge on` with a keyed persona behaves as today plus the result
      line; `forge off` and `--global` behavior unchanged except the
      per-project still-off reasons.
- [x] shellcheck clean (incl. info); pty coverage for the no-persona
      and keyless follow-ups; shell-suite coverage for the non-TTY
      messages.

## Blocked by

(none)

## Comments
