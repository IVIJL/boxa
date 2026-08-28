# 05 — Docs: přepsat docs/ssh.md a smést zastaralá tvrzení o forwardingu

Status: done

## Parent

ADR 0026 — SSH gate.

## What to build

Dokumentace přestane prodávat agent forwarding jako bezpečný default a
popíše bránu:

- Přepsat `docs/ssh.md`: SSH gate (default off, `boxa ssh on|off|status`,
  globál vs. projekt, efekt až od vytvoření kontejneru), Key picker
  (`boxa ssh add`, consent, filename-only discovery, varování u
  bezheslových klíčů), migrace/jednorázový prompt, a explicitní
  bezpečnostní odstavec: forwardovaný socket = plná podpisová pravomoc
  nad všemi klíči v agentu; boxa nikdy nečte privátní klíče ani sama
  nevolá `ssh-add`. Keychain sekce zůstává jako hostový návod.
- Projít a opravit všechna místa tvrdící, že forwarding je vždy zapnutý
  nebo že boxa auto-přidává klíče: README, SECURITY.md, skill
  `skills/boxa/SKILL.md`, session-context texty, `docs/editors.md`,
  `docs/networking.md` odkazy a help/usage texty, které issue 01–04
  nepokryly.
- Křížové odkazy: ssh.md ↔ ADR 0026, CONTEXT.md termíny (SSH gate,
  Key picker, Boxa SSH config) používat konzistentně.

## Acceptance criteria

- [x] `docs/ssh.md` popisuje bránu, picker, migraci a bezpečnostní model
      shodně s ADR 0026 (žádné „keys never enter the container ⇒ safe"
      bez zmínky o podpisové pravomoci socketu)
- [x] `grep -ri` přes repo nenajde zastaralé tvrzení o always-on
      forwardingu nebo auto-`ssh-add` (mimo ADR/historické dokumenty)
- [x] Skill `boxa` a SECURITY.md zmiňují SSH gate tam, kde vyjmenovávají
      brány (Allowlist, Host connection, Agent-browser, MCP)
- [x] Odkazy mezi ssh.md, ADR 0026 a CONTEXT.md sedí

## Výjimky

- Reálný status příkaz je `boxa ssh` (ne `boxa ssh status`) — dokumentace
  odpovídá implementaci issue 02, spec text byl nepřesný.
- `ROADMAP.md`, `devcontainer-standalone.json` a help/usage stringy beze
  změny — neobsahovaly zastaralá tvrzení.
- `install.sh` `AddKeysToAgent` hostový keychain návod ponechán beze
  změny — jde o OpenSSH/host mechanismus, ne o boxí auto-ssh-add.

## Blocked by

- 04-provisioning-prompt-migration.md

## Comments
