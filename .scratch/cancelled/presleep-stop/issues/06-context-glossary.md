# 06 — Keep-awake and power-watch terms in CONTEXT.md

Status: done

## Parent

None — documentation debt found during the presleep-stop grill:
CONTEXT.md has no keep-awake vocabulary at all.

## What to build

Add a keep-awake section to the CONTEXT.md glossary (glossary entries
only — no implementation detail), covering at minimum:

- **Keep-awake daemon** — the host-side process holding the OS awake
  while agents work; **Awake lease** — the TTL-bounded busy claim
  (agent + session) an agent holds via the HTTP API; **Activity
  hook** — the Claude hook translating agent activity into lease
  signals, including the shell-aware Stop behaviour (issue 02);
  **Power-watch** — the daemon component that stops boxes before the
  system sleeps or shuts down; **Pre-sleep stop** — the
  `boxa stop --all --reason presleep` run power-watch triggers, whose
  outcome the user learns via the existing **Closeout notification**.

Follow the established entry format (bold term, one-paragraph
definition, `_Avoid_:` line where synonyms float around). Cross-check
wording against docs/keep-awake.md and the presleep-stop issues so the
glossary and docs use identical terms.

## Acceptance criteria

- [x] CONTEXT.md gains the keep-awake terms above in the house format.
- [x] No implementation details (ports, file paths, API routes) leak
      into the glossary.
- [x] docs/keep-awake.md uses the same canonical terms (adjust it
      where it drifts).

## Blocked by

None — can start immediately (final wording for power-watch terms may
be polished after issues 03–05 land).

## Comments
