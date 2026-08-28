# 04 — Converge the rendered state inside the Container

Status: done

## Parent

ADR 0022 — Durable Claude MCP render and approval.

## What to build

The durability guarantee does not come from choosing better files; it comes from
re-asserting the intended state before the user needs it. This slice adds that
convergence step and is where the guarantee is actually enforced.

Convergence reads the secret-free broker runtime snapshot, which already carries
both the catalog entries and the per-Project activations with their consumers
and enabled flag, and which the Container's agent account can read without
touching the gated host store. From that snapshot it repairs the rendered
`.mcp.json` and the approval files for the Projects mounted in that Container.

It runs at Container start and at shell initialization, so the state is correct
before the user launches an agent from that shell. When everything already
matches it does nothing and costs nothing noticeable.

The removal rule is the load-bearing part: convergence **never** removes a
rendered entry that is still present in the snapshot. It removes only what the
snapshot no longer carries, which is only what `boxa mcp deactivate` removed.
An activated MCP server is therefore not lost until the user deactivates or
disables it; anything else that removes it is repaired at the next Container or
shell start. Convergence likewise re-asserts a seed only through the one-time
rule from issue 02, so a repaired render does not resurrect a server the user
disabled.

A snapshot that is missing or unreadable makes convergence a reported no-op
rather than a destructive one — it must never interpret an absent snapshot as
"nothing is activated".

## Acceptance criteria

- [x] Deleting the Boxa entry from `.mcp.json` and starting a new shell in the
      Container restores it without any host command.
      (restore covered by unit test; the *shell-init* trigger is a Dockerfile
      `/etc/zsh/zshrc` hook — needs an image rebuild + new shell to observe.)
- [ ] The same holds after a Container restart.
      (deferred: `setup-claude.sh` runs convergence on every start, but this
      needs a real rebuilt image + `boxa restart` to verify.)
- [x] Wiping the approval state restores it under the issue-02 seeding rules,
      and does not re-enable a server the user disabled.
- [x] Convergence never removes an entry still present in the runtime snapshot,
      including when the rendered file was hand-edited.
- [x] `boxa mcp deactivate` on the host is reflected in the Container at the next
      convergence, removing the entry.
      (tested as "entry gone from the snapshot"; the host command itself is
      deferred to manual verification.)
- [x] A missing, empty, or malformed runtime snapshot produces a reported no-op
      and never removes a rendered entry.
- [x] Convergence with everything already in sync writes nothing and is fast
      enough to sit in shell initialization.
      (zero-write pinned by test; "fast enough" not measured in a real shell.)
- [x] Convergence runs as the agent account and needs no access to the gated
      host MCP store.
      (test runs with no host store present at all.)
- [x] Convergence refuses every write for a Project when `.mcp.json` is tracked,
      its rendered bytes differ, and the runtime snapshot carries no durable
      `--allow-tracked-mcp-json` consent.
- [x] Convergence proceeds for a changed tracked `.mcp.json` when the snapshot
      carries that Project's durable consent, for an untracked `.mcp.json`,
      and for non-repository approval repair when a tracked `.mcp.json` is
      already in sync.
- [x] `PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
      passes.
- [x] `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh
      lib/*.sh tests/*.sh` passes after any shell changes.

## Blocked by

- `.scratch/mcp-render-durability/issues/03-remember-user-approval-decisions.md`

## Comments
