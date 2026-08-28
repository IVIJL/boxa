# 33 — Forge key scan rejects private keys without a .pub (legacy ssh add accepted them)

Status: done
Type: AFK

## Parent

Live verification round 3, 2026-08-26; regression against the legacy
SSH gate key picker, related to issues 16/19/27.

## What happened (live repro)

The user's ~/.ssh holds private keys only (copied between machines,
no .pub companions). The legacy `boxa ssh add` picker
(`_boxa::ssh_discover_keys`, lib/ssh.sh ~825) offered them — the .pub
is read only for the optional comment label
(`_boxa::ssh_public_comment` ~843) — and forwarding worked, since
ssh-add needs only the private file. The new persona flows require a
complete pair, so "Attach all host SSH keys" found nothing and the
persona was silently created keyless (gate off). Pair requirements
live at e.g. lib/forge.sh ~2559 (add flow validation), ~3013/~3034
(picker scan), ~3066, and lib/ssh.sh ~657, ~1102.

## What to build

Restore parity: persona key scan, picker, manual-path entry, and
attach must accept a private key whose .pub is missing. Constraint
that must NOT change: Boxa never reads private key contents
(docs/adr/0034, lib/ssh.sh comment ~822 — discovery by name only, the
.pub comment is the only key-file content read).

- Scanning (`_boxa::forge_all_host_persona_keys`, the choose-which
  picker, manual path validation): a candidate with a private file
  but no .pub is valid; label it with a note like "(no .pub —
  fingerprint unavailable)" instead of skipping it.
- Fingerprint consumers degrade gracefully: where
  `ssh-keygen -lf key.pub` feeds labels/summaries/verification
  (lib/forge.sh ~2794, ~2957, verify path), print
  "fingerprint unavailable" (an existing pattern in the verify path).
  Do NOT derive the public key via `ssh-keygen -y` anywhere — that
  opens the private key and can block on a passphrase prompt in
  non-interactive paths.
- Key registry and reconcile (`_boxa::ssh_key_fingerprint` ~791 and
  its callers, pair checks ~657/~1102, registry replace/reconcile in
  the per-project agent path): keys without a .pub must still be
  registered, forwarded (ssh-add uses the private file), and
  reconciled. Where the registry needs a stable identity for such a
  key, use the key path (document the choice in the registry grammar
  comment).
- Where a .pub genuinely is needed and absent (e.g. "paste this .pub
  to GitHub" guidance, per-key verification probe), say so and print
  the one-liner remedy: `ssh-keygen -y -f <key> > <key>.pub` (note it
  prompts for the passphrase if the key has one). Do not run it for
  the user.
- The empty-scan fallback message from issue 25-batch review
  ("No valid SSH key pairs found under ~/.ssh") should now be rare;
  when the scan skips unreadable/invalid entries it should name them.

UI strings EN.

## Acceptance criteria

- [x] A private-only key appears in the scan and picker, attaches,
      lands in the persona file and key registry, and reaches the
      per-project agent reconcile path.
- [x] Fingerprint displays degrade to "unavailable" without errors;
      verification/upload guidance names the missing .pub and the
      ssh-keygen -y remedy.
- [x] Boxa still never reads private key contents (no ssh-keygen -y
      execution, no parsing of the private file).
- [x] Keys with a .pub behave exactly as before.
- [x] shellcheck clean (incl. info); real pty coverage for
      private-only attach (scan default and manual path) and the
      degraded fingerprint label; shell suite coverage for
      registry/reconcile with a pub-less key.

## Blocked by

(none)

## Comments
