# 02 — CLI `boxa ssh` (status/on/off) + DRY generalizace conf zápisu

Status: done

## Parent

ADR 0026 — SSH gate. Konvence per-project confu: ADR 0020.

## What to build

Nový subpříkaz `boxa ssh` pro ovládání **SSH gate**:

- `boxa ssh` — vypíše efektivní stav pro aktuální projekt a odkud pochází
  (default off / globální conf / projektová sekce), plus cestu ke confu.
- `boxa ssh on|off [project|path]` — durable per-projektový zápis do
  `~/.config/boxa/ssh.conf`; cíl defaultuje na aktuální projekt stejně
  jako `boxa mem set` (přepoužít existující rezoluci cíle).
- `boxa ssh on|off --global` — durable globální volba.
- Když pro dotčený projekt běží kontejner, příkaz upozorní, že změna se
  projeví až po `boxa stop && boxa` (stejný vzor jako `--ssh-config`).

DRY: generalizuj mazání klíčů ze scope confu —
`_boxa::remove_resources_conf_keys` dostane parametrizovaný seznam klíčů
(např. `_boxa::remove_conf_keys <scope> <section> <conf> <temp> <key…>`),
`mem unset` přejde na generalizovanou verzi a jeho stávající testy musí
zůstat zelené. Zápis `agent=` hodnoty jde přes stejný mechanismus (smazat
klíč ve scope + připsat), aby cizí obsah souboru procházel beze změny.

CLI tvar je záměrně připraven na budoucí per-key filtr (`--keys`,
`keys=` v confu) — teď neimplementovat, jen nezablokovat.

Doplnit help text (`boxa help`, per-command help), bash i zsh completions.
Subpříkaz nekoliduje s existujícím `boxa ssh-config` (zůstává beze změny).

## Acceptance criteria

- [x] `boxa ssh` ukazuje efektivní stav + zdroj (default/global/projekt)
- [x] `boxa ssh on|off` zapisuje projektovou sekci (default cíl = aktuální
      projekt), `--global` zapisuje globální klíč; opakovaný zápis
      nevytváří duplicitní sekce/klíče a cizí obsah confu přežije netknutý
- [x] `mem unset` používá generalizovaný helper a všechny stávající testy
      resources projdou beze změny chování (125/0)
- [x] Při běžícím kontejneru dotčeného projektu příkaz vypíše upozornění
      na nutný restart
- [x] Completions (bash + zsh) a help pokrývají `ssh`, `ssh on`, `ssh off`,
      `--global`
- [x] Testy na zápis/mazání (global i projekt, zachování cizích bytů) —
      tests/ssh.sh 42/0
- [x] shellcheck čistý na změněných souborech

Poznámka: Codex navíc doplnil CONTEXT.md o glosář (SSH gate / Boxa SSH
config / Key picker) — souvisí přímo s featurou, ponecháno a
zkontrolováno.

## Blocked by

- 01-gate-core-conditional-mount.md

## Comments
