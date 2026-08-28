# 04 — Provisioning prompt: migrace stávajících uživatelů a první instalace

Status: done

## Parent

ADR 0026 — SSH gate (migrace). Provisioning registry: ADR 0017.

## What to build

Jednorázový **Elective step** (ADR 0017) `ensure-ssh-gate.sh` v registry
provisioning kroků, sdílený mezi `install.sh`, `boxa update` a `boxa
doctor`:

- Když `~/.config/boxa/ssh.conf` neexistuje ani nemá globální `agent=`
  a krok nemá seen-marker, položí se jednorázová interaktivní otázka:
  „Boxa nově neforwarduje SSH agenta do kontejnerů automaticky. Zapnout
  forwarding? [y/N]" s krátkým vysvětlením rizika (forwardovaný socket =
  podpisová pravomoc nad všemi klíči v agentu).
- Enter/`n` = **No** (secure by default): zapíše se seen/dismissed marker,
  conf se nechává být (brána zůstává off přes default), příště se už
  neptat. `y` = zapíše `agent=on` globálně do `ssh.conf` a naváže Key
  picker (issue 03), pokud je agent prázdný.
- `boxa doctor` krok jen **reportuje** (elective — uživatel mohl vědomě
  odmítnout); opraví ho jen `boxa doctor --fix`.
- Neinteraktivní kontext (bez TTY) se nikdy neptá — chová se jako No bez
  zápisu markeru, aby otázka padla při nejbližším interaktivním běhu.

Tím je pokryt upgrade stávajících uživatelů (kterým default off jinak
potichu rozbije ssh git remote) i úplně první instalace boxy — stejný
mechanismus, stejná formulace.

## Acceptance criteria

- [x] Krok je registrován v provisioning registry a běží z install.sh,
      `boxa update` i `boxa doctor` (elective sémantika dle ADR 0017)
- [x] Otázka se položí nejvýše jednou (marker); existující `agent=` v
      confu otázku potlačí i bez markeru
- [x] Odpověď No nezapisuje do ssh.conf nic; odpověď Yes zapíše globální
      `agent=on` a při prázdném agentu naváže picker z issue 03
- [x] Bez TTY se neprompti a marker se nezapisuje
- [x] `boxa doctor` bez `--fix` krok jen reportuje
- [x] Testy pro marker/conf potlačení a non-TTY větev
- [x] shellcheck čistý na změněných souborech

Rozhodnutím uživatele z 2026-08-19 bylo chování vráceno: holé
`boxa doctor --fix` opravuje jen chybějící elective kroky; dříve odmítnuté
vyžadují explicitní `--fix <step>`. Doctor u zapnutých elective kroků zobrazuje
také návod k vypnutí.

## Blocked by

- 03-key-picker-ssh-add.md

## Comments
