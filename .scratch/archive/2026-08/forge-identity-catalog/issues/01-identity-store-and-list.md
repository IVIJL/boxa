# 01 — Identity store + `forge list`

Status: done

## Parent

ADR 0033 (docs/adr/0033-forge-identity-catalog.md), Decision 1, 2, 4.

## What to build

The catalog layer: a Forge identity is one file under the forge store's
`identities/` directory, named by its derived ID (`github:<username>`,
`gitlab:<host>:<username>`), 0600, in the same strict `key=value` format
as today's credential files plus a `kind` field (`mine` | `agent` |
`other`). Provide load/write/validate/list helpers with the same
strictness as the existing credential reader (unknown keys, duplicates,
bad version → reject). `boxa forge list` prints the catalog: ID, kind
label, token age, host.

## Acceptance criteria

- [x] Identity file format documented in the helper header and enforced
      by a strict reader (round-trips through writer)
- [x] Derived-ID helper covers github and self-hosted gitlab (host in ID)
- [x] `boxa forge list` shows all identities with kind labels; empty
      catalog prints a helpful line, not an error
- [x] shellcheck clean incl. info-level; tests in the forge suite cover
      reader strictness, ID derivation, and list output

## Blocked by

None — can start immediately.

## Comments
