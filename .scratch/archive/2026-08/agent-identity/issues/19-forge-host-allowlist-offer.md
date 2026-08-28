# 19 — offer Allowlist entry for the forge host during `boxa forge set`

Status: done

## Parent

[PRD](../PRD.md) F2/F4 follow-up; ADR 0032 decision 4; ADR 0001
(dnsmasq allowlist semantics). User-requested during the AFK batch
(2026-08-22).

## What to build

A stored forge token is useless if the container firewall still REJECTs
the forge host, and today the user has to notice that and run
`boxa allow <domain>` manually. Close that gap at the moment the host
becomes known: after `boxa forge set github|gitlab` successfully stores
a credential, check whether the forge host is already covered by the
durable Allowlist (remember: an entry matches the domain plus all
subdomains, `lib/allowlist.sh`). If not, offer a consent prompt to add
it — never add silently.

Details:

- GitHub: host is `github.com` (usually already in the default
  allowlist — then no prompt at all).
- GitLab: use the stored `host=` value. Suggest a sensible default in
  the prompt: for a multi-label host like `rep.gaiagroup.cz`, prefill
  the registrable parent (`gaiagroup.cz`) so sibling subdomains
  (registry, pages, …) work too; the user can edit the value or decline.
  Keep the parent-derivation heuristic simple (strip the leftmost label
  when ≥3 labels; two-label hosts stay as-is) and let the edit prompt
  cover public-suffix edge cases (e.g. `foo.co.uk`) — do not vendor a
  PSL.
- Reuse the existing allowlist plumbing (`lib/allowlist.sh` add path,
  same validation and effects as `boxa allow`); no new mechanism.
- Prompt reads from `/dev/tty` like the rest of forge set; on
  non-interactive stdin, skip with a printed hint (`boxa allow <host>`)
  instead of blocking.
- Declining stores nothing and still leaves the credential saved; print
  the manual hint.

## Acceptance criteria

- [x] `boxa forge set gitlab` with host `rep.gaiagroup.cz` offers to
      allow `gaiagroup.cz` (editable), and accepting makes the entry
      land via the same code path as `boxa allow`.
- [x] Host already covered (exact entry or parent entry) → no prompt.
- [x] Declining keeps the credential and prints the `boxa allow` hint.
- [x] Non-interactive invocation skips the prompt with the hint, exit 0.
- [x] shellcheck clean; prompt flow covered by real-pty tests
      (tests/forge.sh patterns).

## Blocked by

13 (forge store + CLI) — done.

## Comments
