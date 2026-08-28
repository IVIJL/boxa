# 01 — Catalog model: headers + secretHeaderKeys on remote entries

Status: done
Priority: P1
Type: AFK

## Parent

.scratch/mcp-remote-auth/KICKOFF-NOTES.md + docs/adr/0030 (decisions are
final — do not relitigate).

## What to build

Remote (http) catalog entries learn the env-style split: `headers`
(non-secret name→value map stored in the catalog) and `secretHeaderKeys`
(list of header names; values live elsewhere). `boxa mcp add` and
`boxa mcp update` accept both for remote entries and round-trip them;
`import` may carry non-secret headers and secret header NAMES from a
discovered definition (values never — see issue 04 for the interactive
part). Validation keeps the catalog secret-free: overlap between the two
fields is an error; a non-secret header whose name or value trips the
existing secret heuristics (the URL guard's vocabulary) is an error.
`boxa mcp status`/`catalog`/`readiness` surface the declaration: an entry
with `secretHeaderKeys` and no stored value reports not-ready with a
"secret value missing" reason and a `Next:` hint; ISOLATION for such
entries reads `proxied` instead of `not-applicable`.

## Acceptance criteria

- [x] add/update/import round-trip `headers` + `secretHeaderKeys` on
      remote entries; non-remote entries reject them.
- [x] Validation: overlap error; secret-looking non-secret header
      (name or value) rejected with a clear message.
- [x] status/readiness show declared-but-missing secret value with a
      copy-pasteable `Next:` hint; ISOLATION column shows `proxied`.
- [x] Catalog file remains secret-free (test asserts no header values for
      secretHeaderKeys anywhere in catalog JSON).
- [x] English UI strings; unittest suite green.

## Blocked by

None - can start immediately.
