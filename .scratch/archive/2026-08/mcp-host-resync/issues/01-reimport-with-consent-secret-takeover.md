# 01 — Reimport inside `mcp import`, with consent-first credential takeover

Status: done

## Parent

ADR 0031 (consent-first credential takeover on import/reimport) — the
design is FINAL there; do not relitigate. Builds on ADR 0030 header
model and the import discovery from #mcp-remote-auth/04.

## What to build

No separate resync command — reimport is a mode of `boxa mcp import`:

- Discovery additionally matches already-cataloged entries by stable
  import identity (a catalog rename must not break the match) and
  computes "changed" as a **non-no-op apply**: build the full
  normalized update through the SAME mapping the apply path uses;
  in-sync = that update is a no-op. Secret values count into the no-op
  check via internal comparison against the host-only secret store
  (never displayed).
- Interactive picker gets two sections in one multi-select pass:
  "New" and "Changed (reimport)". In-sync matches collapse into a
  one-line summary ("N entries in sync with host configs"). An empty
  New section with changed entries present is a normal run — this
  covers "nothing new, want to reimport?" without a second step.
- Non-interactive: `--reimport` makes changed entries addressable by
  the existing selectors (`--server`, `--import-id`); `--all-changed`
  is the counterpart of `--all-applicable`. Explicit selection works
  even for entries the summary calls in sync (reports "in sync",
  changes nothing).
- Apply: host wins for fields the host definition carries (URL,
  headers, secret header keys, command spec, env) after ONE
  confirmation showing the diff; goes through the same
  preflight+atomic path as `mcp update`. Boxa-only state (name,
  description, mode, activations, trust) untouched. No per-field merge.
- Consent-first secrets, IDENTICAL in import and reimport, for BOTH
  http secret headers and secret-classified env values of stdio
  servers: per-value y/N prompt (default no) — "Take over the value of
  secret header 'Authorization' from <host-file> into the host-only
  secret store? [y/N]". On yes: declare the key if needed and move the
  value straight into the store (never echoed, never argv, never in
  catalog). Stored value equal to host value → silent skip. Differing →
  rotation prompt ("stored value differs — update from host?").
  Decline or non-TTY/`--json` → key-only declaration + report of
  skipped names + `Next: boxa mcp secret set` hint.
- Never edit host agent configs; human-readable output may recommend
  removing the plaintext value from the host file.
- Update `mcp import` help text and any "never copies credential
  values" phrasing to the ADR 0031 wording (never copies *silently*).
- After apply, existing `Next:` hints (activate / reload) as
  appropriate.

## Acceptance criteria

- [x] Changed-detection and apply share one mapping code path; test
      proves that applying right after "in sync" is a no-op, and that
      each takeable field (url, headers, secret keys, command, env,
      secret VALUES via store comparison) flips detection when changed
      host-side.
- [x] Catalog-renamed entry still matches its host definition and
      reimports under the catalog name.
- [x] Picker shows New + Changed sections in one multi-select run;
      in-sync entries only as a summary line; `q` cancels cleanly.
- [x] `--reimport --server <x>` / `--import-id` / `--all-changed` work
      non-interactively; explicit selection of an in-sync entry reports
      in sync and changes nothing.
- [x] Reimport apply overwrites host-carried fields after one
      diff+confirm via the preflight+atomic update path; name/mode/
      activations/trust/description are untouched (test).
- [x] Per-value consent prompt in BOTH import and reimport, for header
      and env secrets; yes lands the value in the host-only store and
      readiness flips ready without a separate `secret set`; equal
      value = silent skip; differing value = rotation prompt.
- [x] Secret values never appear in stdout/stderr, argv, `--json`, or
      the catalog file — tests assert absence.
- [x] Non-TTY/`--json` never takes values; skipped names + `secret
      set` hint reported.
- [x] Help text updated to ADR 0031 wording.
- [x] Tests green (`python3 -m unittest discover -s tests -q`),
      shellcheck clean incl. info-level on touched shell scripts,
      `tests/picker.sh` covers the sectioned picker.

## Blocked by

None — can start immediately (builds on merged #mcp-remote-auth work).

## Comments

- 2026-08-21: Filed from live-testing feedback: user edited the dozzle
  entry in host `~/.claude.json` (added Authorization header), re-ran
  `boxa mcp import` and got "No Inherited MCP servers detected" —
  no takeover path existed short of hand-assembled `mcp update` flags.
- 2026-08-21: Grill session resolved: reimport inside import (no
  resync command), dry-run-apply change detection, host-wins conflict
  rule, per-value consent incl. rotation, env+stdio symmetry, ADR 0031
  written (design final).
