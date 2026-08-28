# 26 — Legacy SSH gate migration: proactive one-time prompt, not a buried menu item

Status: done
Type: AFK

## Parent

Live verification round 2, 2026-08-26; follow-up to issue 22 (ADR 0034
binary gate, consent-first migration rule from review round 1).

## What happened (live repro)

"Migrate legacy SSH gates" sits as the sixth item in the dashboard
action menu. The user never picks it, so the legacy NOTE, `(legacy)`
markers and the MISSING summary persist forever. The user expected the
migration to happen automatically on update; fully silent migration is
banned (it writes durable gate values — consent-relevant config), but
a passive menu item is too hidden.

## What to build

Keep consent-first, make it proactive: when the dashboard starts and
legacy-mapped gate values exist, prompt once before the action menu —
show exactly what would be written where (per-project explicit gate
values, same summary the menu action shows today) and ask yes/no. Yes
runs the existing migration path (issue 22 implementation, under the
registry lock). No records the decline durably (e.g. a marker in the
forge config dir) so the prompt never repeats; the menu item stays
available for later. After a successful migration nothing legacy
remains, so neither the prompt nor the menu item shows. No silent
writes of gate values in any path. UI strings EN.

## Acceptance criteria

- [x] Dashboard start with legacy state prompts once with the
      write-plan summary; yes migrates, no declines durably.
- [x] Declined state never re-prompts but keeps the menu item.
- [x] No gate value is ever written without the explicit yes.
- [x] shellcheck clean (incl. info); test coverage incl. the decline
      persistence (real pty for the prompt).

## Blocked by

(none)

## Comments
