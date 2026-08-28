# Handoff — forge-identity-catalog kickoff + dojezd agent-identity (2026-08-25)

Nová session jede VŠE AFK bez čekání na Miloše (je 2h pryč). Spec:
`docs/adr/0033-forge-identity-catalog.md` (grill hotový, shoda potvrzena).
Issues: `.scratch/forge-identity-catalog/issues/01–08` (ready-for-agent).
Předchozí feature: `.scratch/agent-identity/HANDOFF.md` + ADR 0032.

## Výchozí stav

- Větev `feat/agent-identity`, 16 commitů nepushnutých + **necommitnutý
  WIP** (vše review-nezkontrolované, testy zelené, shellcheck clean):
  1. SSH probe fix — `IdentitiesOnly=yes -i <agent-key>.pub` (falešná
     verifikace přes osobní klíč; incident „Hi IVIJL!").
  2. 3-posture picker ve `forge setup` checklistech (own account /
     machine user / PAT-only, GitHub+GitLab) + dovětek v ADR 0032.
  3. Identity ve `forge status` + doctor summary („SSH key
     authenticates as: …", `ensure-agent-identity.sh summary`).
  Dále necommitnuto: ADR 0033, pointer v ADR 0032, tato issues dávka.
- Miloš má machine usera **vlciagent** (klíč připojen, ověřeno
  `Hi vlciagent!`); PAT + pozvánky do repos zatím nemá.

## Pipeline nové session (v tomto pořadí, vše AFK)

1. **`/cr` přes celý working tree** → review loop do čista, pak commit
   na `feat/agent-identity` (Miloš commit v rámci této pipeline předem
   schválil, 2026-08-25). Doporučené rozdělení: probe fix + picker +
   status/doctor + docs (ADR 0033 atd.) — klidně víc commitů.
2. **`/afk-feature-workflow`** nad `.scratch/forge-identity-catalog/
   issues/` — **na větvi `feat/agent-identity`** (NE main: squash-merge
   čeká na živé ověření + „slij", a katalog sahá do stejných míst
   `lib/forge.sh`; stavět na main = konflikty). Pořadí dle Blocked by:
   01 → 02 → {03, 04, 07} → {05, 06} → 08. Po všech issues JEDEN
   závěrečný review loop přes celou dávku.
3. Nic nepushovat, nemergovat, main nesahat.

## Provozní pravidla (kriticky, viz memory)

- ŽÁDNÝ `docker build` uvnitř boxy (2× OOM shodil dockerd i session).
- Subagenti foreground; Codex VŽDY přes MCP `boxa-codex-delegate`
  uvnitř tenké slupky, ne companion CLI.
- Interaktivní flow testovat přes reálné pty, žádné stuby na
  consent/prompt seamech; pytest v boxe není → `python3 -m unittest`.
- shellcheck vč. info-level; UI stringy anglicky.
- Závěrečný review na velkém diffu nekonverguje donekonečna — po pár
  kolech rozlišovat díru vs. hardening (memory
  `afk-review-loop-does-not-converge`).

## Po návratu Miloše (nedělá session, dělá on)

1. Živé hostové ověření: checklist v `.scratch/agent-identity/
   HANDOFF.md` + nově `forge add/list/use/default/remove/status`,
   migrace legacy credentialů, SSH write-through, multi-machine větev
   („attach key to existing machine user" — vlciagent).
2. Pak na slovo „slij" squash-merge `feat/agent-identity` → main.
3. Otevřené drobnosti z minula: image size investigace (`docker
   history` + `docker buildx du`), přesun `glab` z první apt vrstvy.

## VÝSLEDEK (session 2026-08-25, AFK dojeto)

- Krok 1: /cr loop 4 kola → čistý; commity b14bae6 (kód) + 7d55699 (ADR 0033 + dovětek 0032).
- Krok 2: issues 01–08 hotové (2ad69e4..1b800ad), závěrečný review loop 4 kola
  → 4 fix commity (97e5907, ba78e8e, e7d9538, 6ae0555), uzavřeno „No discrete
  correctness issues". Všechny issue soubory Status: done.
- Testy: forge ~380, ssh 158, ensure_agent_identity 16, PTY 12 — zelené; shellcheck -S info čistý.
- Obhájené trade-offy: GitHub-first committer (zapsáno v ADR 0033 D8), migrace
  auth=token (least authority), gate jen explicitní akcí (consent-first),
  no-rollback multi-write s reportem.
- Nic nepushnuto, main nedotčen. Zbývá sekce „Po návratu Miloše" beze změny.
- Pozn.: stroj během dávky jednou usnul (~41 min) — zabilo to jen běžící
  issue 07, restart proběhl čistě; keep-awake na hostu stojí za kontrolu.
