# Handoff — forge/SSH UX redesign po grillu (2026-08-25)

> **SUPERSEDED** týž den: pipeline splněna (ADR 0034 commitnuté, issues
> 09+11–18 published) a model prohlouben na PERSONY (bod 1 níže už
> neplatí — entita není per-forge účet). Aktuální je
> `HANDOFF-afk-personas.md`.

Nová session implementuje redesign vygrilovaný s Milošem (grill-with-docs,
frontier prázdný, shoda potvrzena). Kontext feature: ADR 0032/0033,
`.scratch/forge-identity-catalog/` (issues 01–08 done, batch review-clean,
viz HANDOFF.md tamtéž). Větev `feat/agent-identity`, ~30 commitů nepushnutých,
main nesahat, nepushovat.

## Vygrilovaná rozhodnutí (závazná)

1. **Entita katalogu zůstává Forge identita** (účet na forge, ADR 0033 D1).
   Klíč-centrický pohled je PREZENTACE, ne datový model. Přestavba storage: žádná.
2. **Dashboard-first**: `boxa forge` i `forge setup` otevřou stav — klíče
   (Agent + osobní, fingerprinty, kde jsou enablované), identity, assignmenty,
   co chybí — a akce se nabízejí z kontextu. Lineární checklist zůstává jen
   jako akce „přidat účet".
3. **Posture picker (own/machine/PAT-only) se RUŠÍ.** Registrace účtu = token
   (+ volitelně připojit klíč); kind (`mine`/`agent`/`other`) zůstává jen jako
   štítek, jedna otázka „čí je to účet?". PAT-only = přirozený důsledek
   nepřipojeného klíče (`auth=token` už v datech je).
4. **Transport politika**: SSH klíč primární git transport, token povinný
   vedle něj kvůli API (gh/glab, PR/MR). Žádný HTTPS rewrite, žádné
   destination-constraints (ssh-add -h jen jako budoucí hardening poznámka).
   Jiné git hosty (Forgejo…) = obyčejný SSH server, katalog se jich netýká.
5. **SSH gate kolabuje na off/on**: obsah určuje přiřazení klíčů v katalogu.
   Mapování starých módů: `agent` = on s Agent klíčem, `user` = on s klíči
   uživatele. Per-projekt běží DEDIKOVANÝ ssh-agent (jeden per projekt
   s přiřazenými klíči; ~1–2 MB RAM, vlastní socket, mount do boxy).
6. **Jeden vlastník klíčů per projekt**: v projektovém agentu jsou VŽDY jen
   klíče agenta, NEBO jen klíče uživatele — nikdy mix identit (vědomé
   rozhodnutí Miloše; chce-li z agent-projektu na svůj server, vymění klíče
   přes setup nebo přidá agentův klíč na server). Díky tomu není potřeba
   generovaný ssh config ani per-host mapování — ssh zkouší klíče po řadě,
   všechny patří témuž vlastníkovi.
7. **Více klíčů per vlastník**: agent může mít víc klíčů (nový `ssh-keygen`
   do agent-identity/ i převzetí existujícího); GitHub caveat: 1 auth klíč =
   1 účet (per klíč).
8. **Key registry + persistence**: přidané klíče (cesty, ne privátní obsah)
   se pamatují NAVŽDY; po restartu hosta se do projektových agentů tiše
   re-addují (klíč s passphrase = jeden prompt po restartu; keyring NE).
   `ssh user`/enable bez klíčů automaticky nabídne add flow (dnes nutné ruční
   `boxa ssh add`, po restartu klíče mizí — hlavní Milošův pain point).
9. **Multiselect UX**: vyberu klíč → multiselect projektů, kde má být
   (zapisuje přiřazení + přepíná gate). Jedno spuštění, ne 10×.
10. **Jedny komponenty všude**: dashboard + flow sdílí `forge setup`, doctor
    wizard i migrace. Žádné třetí UI.
11. **Issue 09 (fzf --header)** platí beze změny a je NEZÁVISLÁ — každý picker
    v forge/ssh flow MUSÍ mít otázku a kontext v `--header` (fzf schová text
    vytištěný před spuštěním; `lib/picker.sh` to podporuje, ADR 0006).
    Miloš na tohle explicitně upozornil znovu: „ať se nestane, že mám tři
    odpovědi a nevidím žádnou otázku."

## Fakta zjištěná při grillu (nehádat znovu)

- Picker agent je dnes JEDEN globální, prázdný by default, klíče jen v paměti
  (mizí s restartem) — není to bug, ale ADR 0026 consent design; redesign ho
  nahrazuje per-projekt agenty + registrem (bod 5/8).
- ssh-agent neumí per-klient filtrování — selektivita = víc agentů, nikdy
  load/unload tanec na sdíleném agentu.
- Migrace legacy → katalog běží automaticky při prvním forge příkazu, jen
  když v rootu forge store leží legacy credential soubory; jinak tichý no-op
  (Milošův „nespustil se migrate" = neměl legacy soubory / mix CLI).
- Mix instalovaného boxa + dev checkoutu rozbíjí testy (starý parser
  fail-closed na `user` gate; hláška „boxa ssh on" = staré CLI). Živé ověření
  jet VÝHRADNĚ `./docker-run.sh` + recreate kontejneru (gate se aplikuje při
  vytvoření).

## Dokumentace k napsání (první krok nové session)

- **ADR 0034** (nové): UX redesign — dashboard-first, gate off/on
  s per-projekt agenty, key registry s tichým re-addem, zrušení posture
  pickeru, jeden-vlastník-per-projekt pravidlo. Supersede příslušné části
  ADR 0026 (třístav gate) a 0032 (posture checklisty); odkázat rozhodnutí
  výše. ADR 0033 (katalog/identita) platí beze změny.
- **CONTEXT.md glossary**: upravit „SSH gate" (off/on + přiřazené klíče),
  přidat „Key registry", „Project agent"; „Identity kind" zeslabit na štítek.

## Pipeline nové session

1. Napsat ADR 0034 + CONTEXT.md úpravy (viz výše), dát Milošovi k review.
2. Po odsouhlasení `/to-issues` (tracer-bullet slices; issue 09 zařadit jako
   první — nezávislá, jde hned).
3. AFK dávka přes `/afk-feature-workflow` na `feat/agent-identity`.
   Miloš commity v rámci pipeline schvaluje per dávka — OVĚŘIT slovem.
4. Provozní pravidla: Codex VŽDY přes MCP `boxa-codex-delegate` v subagentovi
   (v této session se MCP odpojilo — aktivovat/nová session); žádný docker
   build v boxe; pty testy reálné (`python3 -m unittest`, pytest v boxe není);
   shellcheck vč. info; UI stringy EN; per-issue commit hned, jeden závěrečný
   review loop (pozor na nekonvergenci — po pár kolech díra vs. hardening).

## Stav repa / okolí

- `feat/agent-identity`: issues 01–08 + review fixy commitnuté (HEAD 6ae0555),
  review-clean; živé ověření katalogu PŘERUŠENO nálezy UX → tento redesign.
  Squash-merge do main až po ověření, na slovo „slij".
- Issues 09 (ready po ADR — mechanická), 10 (nahrazena tímto handoffem).
- Bug report na Claude Code odeslán (skill discoverability regression,
  /bug 2026-08-25) — netýká se repa.

## Suggested skills (nová session)

- `domain-modeling` — při psaní ADR 0034 + glossary.
- `to-issues` — rozpad na issues po review ADR.
- `afk-feature-workflow` — implementační dávka.
- `boxa` — kontejnerové mantinely.
