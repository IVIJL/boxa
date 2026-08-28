# 03 — Key picker: `boxa ssh add` + navázání na `boxa ssh on`

Status: done

## Parent

ADR 0026 — SSH gate (sekce o Key pickeru). Picker konvence: ADR 0006.
Glosář: CONTEXT.md → Key picker.

## What to build

Interaktivní, consent-first cesta, jak dostat klíče do hostového agenta —
jediný mechanismus, kterým boxa kdy způsobí nahrání klíče:

- `boxa ssh add` — samostatný příkaz; a `boxa ssh on` na něj plynule
  naváže, pokud po zapnutí brány agent neběží nebo nemá žádné klíče.
- Nejdřív **explicitní souhlas**: „Podívat se do ~/.ssh a nabídnout klíče
  k přidání? [y/N]". Bez souhlasu žádný výpis adresáře.
- Discovery **jen podle jmen souborů** (readdir): kandidát = soubor, který
  není `*.pub`, `config`, `known_hosts*`, `authorized_keys*` ani jiný
  známý ne-klíč (sockety, adresáře). Obsah privátních souborů boxa nikdy
  nečte. Když k souboru existuje `.pub`, přibal jeho komentář do popisku.
- Multi-select picker dle konvencí ADR 0006 + položka pro ruční zadání
  cesty (fallback i pro „no" u souhlasu / prázdný `~/.ssh`).
- Nahrání dělá výhradně `ssh-add`: pro každý vybraný klíč nejdřív
  ne-interaktivní pokus (zavřený stdin, `SSH_ASKPASS` na neúspěch);
  úspěch bez promptu ⇒ klíč je **bez passphrase** ⇒ vytiskni varování
  (agent v kterékoli boxe ho může použít kamkoli; doporuč `ssh-keygen -p`).
  Neúspěch ⇒ spusť `ssh-add` interaktivně, o passphrase si řekne ssh sám —
  max. jeden prompt na klíč, žádné copy-paste.
- Pokud agent neběží, příkaz ho pro tento účel nastartuje/oživí (keychain
  pokud je, jinak `ssh-agent`) — tohle je jediné místo, kde se agent smí
  startovat; ve startu boxy nikoli (viz issue 01).

## Acceptance criteria

- [x] `boxa ssh add` funguje samostatně; `boxa ssh on` naváže pickerem jen
      když je agent prázdný/mrtvý
- [x] Bez kladné odpovědi na souhlas se `~/.ssh` nevylistuje; ruční cesta
      zůstává dostupná
- [x] Kandidáti se určují výhradně podle jmen souborů; žádný kód nečte
      obsah privátního klíče (grep testem: jediné čtení dělá `ssh-add`)
- [x] Bezheslový klíč se detekuje ne-interaktivním `ssh-add` pokusem a
      vyvolá varování; klíč s passphrase dostane právě jeden interaktivní
      prompt
- [x] Picker respektuje konvence ADR 0006 (multi-select, zrušitelnost)
- [x] Testy pro discovery filtr a pro ne-interaktivní/interaktivní větev
      (mock ssh-add)
- [x] shellcheck čistý na změněných souborech

## Blocked by

- 02-cli-boxa-ssh-and-conf-writer.md

## Comments
