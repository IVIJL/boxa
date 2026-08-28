# 01 — MCP catalog with stable entry identity

Status: done

## Parent

ADR 0021 — Project-selected MCP catalog and agent-trusted execution.

## What to build

Introduce the host-owned **MCP catalog** as a user-wide collection of prepared
Container MCP server definitions. Each entry has an opaque stable identity that
survives rename and definition edits; deleting and recreating the same display
name creates a new identity. Catalog membership never renders or starts an MCP
server.

`boxa mcp catalog` lists definitions and their stable identity, execution mode,
runtime kind, and readiness summary without implying activation. `boxa mcp add`
adds a service-isolated entry to the catalog. Removing an entry with no
activations deletes its identity. Preserve inherited/manual agent configuration.

This slice establishes the new storage version alongside legacy profile data;
legacy migration is deferred to issue 08 and must not happen partially here.

## Acceptance criteria

- [x] A fresh user has an empty catalog and existing Projects gain no MCP tools.
- [x] Adding and listing a definition round-trips all secret-free launch data.
- [x] Stable identity survives rename and definition update and is not derived
      from the display name.
- [x] Delete plus same-name recreate produces a different identity.
- [x] Catalog files are host-owned, permission-safe, deterministic to read, and
      tolerate/report malformed data without overwriting it.
- [x] Existing global/Project profiles and inherited Claude/Codex entries are
      untouched by this slice.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes after any shell changes.

## Blocked by

None — can start immediately.

## Comments

2026-07-27: implemented without commit. Added the v2 host-owned catalog,
scope-free catalog add/list/remove CLI, stable UUID identity, atomic permission-
safe storage, and regression coverage. Proof: 522 MCP tests, full requested
shellcheck, help suite, CLI smoke, and `git diff --check` all passed. Independent
integration review reran 132 targeted tests plus shellcheck/help/diff proof.
