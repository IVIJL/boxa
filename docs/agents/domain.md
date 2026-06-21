# Domain Docs

How the engineering skills should consume this repo's domain documentation
when exploring the codebase. This repo is **single-context**.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — the canonical glossary.
- **`docs/adr/`** — read the ADRs that touch the area you're about to work
  in (currently `0001`–`0014`). Respect accepted decisions.

If any of these files don't exist for a given area, **proceed silently**.
Don't flag their absence or suggest creating them upfront. The producer
skill (`/grill-with-docs`) creates/extends them lazily when terms or
decisions actually get resolved.

## File structure (single-context)

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-dnsmasq-dynamic-allowlist.md
│   ├── …
│   └── 0014-container-mcp-broker-and-secret-isolation.md
└── …
```

There is no `CONTEXT-MAP.md`; do not look for per-context `CONTEXT.md`
files under `src/`.

## Use the glossary's vocabulary

When your output names a domain concept (an issue title, a refactor
proposal, a hypothesis, a test name), use the term as defined in
`CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either
you're inventing language the project doesn't use (reconsider), or there's a
real gap (note it for `/grill-with-docs`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather
than silently overriding:

> _Contradicts ADR-0007 (local DNS with external fallback) — but worth
> reopening because…_
