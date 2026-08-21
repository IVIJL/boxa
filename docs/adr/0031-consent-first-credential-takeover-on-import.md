# ADR 0031 — Consent-first credential takeover on import and reimport

- **Status:** accepted
- **Date:** 2026-08-21
- **Extends:** ADR 0030 (secret header model), ADR 0029 (remote catalog
  entries)

## Context

Import has been strictly secret-free: it declares secret header/env key
NAMES and drops the values, leaving the user to retype them via
`boxa mcp secret set`. Live use of the ADR 0030 flow (Dozzle bearer
token) showed this is the main friction point: the value already sits
in the host agent config the user owns, yet takeover requires a manual
copy through a hidden prompt. Separately, import was one-shot — after
an entry was cataloged, later host-side edits (a new `Authorization`
header) were reported as "already in catalog" with no takeover path
short of hand-assembled `mcp update` flags.

## Decision

1. **Reimport lives inside import.** No separate resync command.
   `boxa mcp import` discovery additionally matches already-cataloged
   entries by their stable import identity (catalog renames do not
   break the match) and offers those whose host definition differs as a
   "Changed (reimport)" picker section next to "New"; in-sync entries
   are summarized in one line. Non-interactive selection mirrors the
   existing flags (`--reimport` with `--server`/`--import-id`,
   `--all-changed` next to `--all-applicable`).
2. **Changed is defined as a non-no-op apply.** Detection builds the
   full normalized update through the same mapping the apply path uses;
   "in sync" means that update is a no-op. Detection therefore covers
   by construction exactly what reimport can take over, including
   secret values (compared against the host-only store internally,
   never displayed). Fields boxa does not model are invisible to the
   diff and equally impossible to take over, so nothing detectable is
   lost; an explicit `--reimport <selection>` always remains available.
3. **Host wins on reimport.** Reimport is the explicit "take from
   host" action: fields the host definition carries (URL, headers,
   secret keys, command spec, env) overwrite the catalog entry after
   one confirmation showing the diff. Boxa-only state (name,
   description, mode, activations, trust) is untouched. No per-field
   merge UI.
4. **Credential values move only with per-value consent.** The
   invariant "import never copies credential values" becomes "never
   copies credential values *silently*". For each secret-classified
   header or env value present in the host config, import/reimport asks
   one y/N question (default no); on yes the value moves directly into
   the host-only MCP secret store — never echoed, never in argv, never
   in the catalog. A stored value that matches the host value is
   silently skipped; a differing one asks as a rotation ("stored value
   differs — update from host?"). Non-TTY/`--json` runs never take
   values and report the skipped names with the `secret set` hint.
   Import and reimport behave identically here — one behavior, not two.
5. **Host configs are never edited.** Takeover reads the host file
   only; removing the plaintext value from it stays a human decision
   (recommended in output), and automated cleanup remains
   `migrate`-only, consent-gated.

## Considered options

- **Keep never-copy (status quo):** safest on paper, but the value is
  retyped from the same file we just read — friction without a real
  security gain for a file the user already controls.
- **Silent copy:** one surprise path from an agent-writable-adjacent
  file into the secret store; rejected — the user must see and approve
  every value that enters the store.
- **Separate `resync` command:** clearer name, but splits one mental
  model ("take over from host") across two commands with duplicated
  discovery/selection; rejected in favor of import sections.

## Consequences

- ADR 0030's consequence "imports names only and prompts for values"
  is refined by this ADR: the prompt may now offer to move the value
  itself, per-value, consent-first.
- `mcp import` help text and CONTEXT.md drop the unconditional
  "never copies credential values" phrasing.
- The picker gains sections; an empty "New" section with a non-empty
  "Changed" section is the common steady-state run.
