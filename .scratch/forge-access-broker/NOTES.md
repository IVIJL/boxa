# Handoff: Boxa omezení přístupu k GitLab/GitHub a Git transportu

Datum: 2026-08-28

## Cíl příští session

Pořádně „progrillovat“ návrh, jak dát agentům pohodlný přístup přes `glab`, `gh` a Git, ale omezit je na repozitáře přiřazené aktuálnímu Boxa projektu. Výsledkem má být rozhodnutí o bezpečnostní hranici a případně návrh ADR/prototypu. Zatím nic neimplementovat bez dalšího souhlasu.

## Co už je hotové

- Na self-hosted GitLabu byla pro všech 20 projektů ve skupině `internal` sjednocena ochrana relevantních větví.
- Ověřeno 26 pravidel:
  - `main` je chráněný ve všech 20 projektech, i jako pravidlo pro budoucí větev v projektu, který dnes používá `master`;
  - skutečná výchozí větev `master` je v tomto projektu chráněná také;
  - všech 5 existujících větví `stage` je chráněných.
- Pro `main`, `master` a `stage` platí:
  - direct push: Maintainer (40) a výše;
  - merge: Maintainer (40) a výše;
  - force push: zakázán.
- Stejná politika je nastavena jako instance default pro výchozí větev nových projektů.
- Developer tedy může vytvářet pracovní větve a MR, ale nemůže pushovat ani mergovat do těchto chráněných větví.
- Opakovaný idempotentní audit skončil `20 projects / 26 rules / 26 verified / 0 changed`.
- GitLab operace sama nevyžadovala změnu ani commit v repozitáři Boxa.

## Aktuální kontext identit

- Existuje push-capable agent persona s GitLab/GitHub tokenem a SSH klíčem.
- Existuje planner persona určená primárně pro čtení, issues a MR; její lokální SSH klíč není nahrán do GitLabu.
- Push-capable agent má Developer (30) členství ve skupině `internal`; jeho
  vlastní token vidí všech 20 projektů. Chráněné větve stále vyžadují
  Maintainera pro direct push i merge.
- Tokeny, SSH privátní klíče a jejich hodnoty nejsou v tomto handoffu uvedeny.

## Problém, který je potřeba grilovat

Pouhý shell wrapper kolem `glab` a `gh` není bezpečnostní hranice, pokud kontejner současně dostane raw token nebo obecný forwardovaný SSH agent. Kód v kontejneru může wrapper obejít přes `curl`, `git`, vlastní binárku nebo přímé SSH spojení.

Je nutné explicitně rozhodnout threat model:

1. Chráníme jen proti omylu agenta?
2. Nebo i proti nedůvěryhodnému kódu/repozitáři běžícímu v kontejneru?
3. Má agent vidět všechny `internal` projekty, ale měnit jen aktuální projekt, nebo nemá ostatní ani číst?
4. Je požadavek „aktuální projekt“ odvozený z Boxa Project identity, pracovního adresáře, remote URL, nebo explicitní allowlist konfigurace?

## Návrh k oponentuře

### Varianta A — pragmatická, aktuální stav

- Agent účet má Developer členství na skupině `internal`.
- Použije se co nejjemnější GitLab token pro potřebné API operace.
- Ochrana `main`/`master`/`stage` vynucuje MR workflow a Maintainer-only merge.
- GitHub použije fine-grained token omezený na vybrané repozitáře.
- Boxa přidá ergonomické wrappery a varování podle aktuálního projektu.

Výhoda: málo správy, plná kompatibilita CLI. Nevýhoda: raw GitLab credential stále dovolí agentovi pracovat s pracovními větvemi ve všech projektech dostupných účtu; wrapper lze obejít.

### Varianta B — per-project credentials

- Každý Boxa projekt dostane vlastní GitLab project access token / deploy credential a odpovídající GitHub credential.
- Kontejner obdrží jen credential projektu, ke kterému je přiřazen.
- Git transport používá HTTPS credential nebo projektově omezený deploy key.

Výhoda: skutečné omezení rozsahem credentialu, menší nový trusted kód. Nevýhoda: provisioning, rotace, revokace a práce s více remotes/forky mohou být administrativně náročné.

### Varianta C — host-side Forge broker (preferovaný kandidát k hlubšímu návrhu)

- Kontejner nedostane raw PAT ani obecný SSH-agent socket.
- Host-side broker drží credentials a vystaví malý protokol přes Unix socket.
- Autoritativní Boxa Project identity se mapuje na explicitně povolené GitLab/GitHub repozitáře.
- Broker validuje provider, repo, operaci, cílovou větev/ref a případně roli persony.
- `glab`/`gh` compatibility layer je jen klient brokeru; ne bezpečnostní seam.
- Git transport vede přes brokerovaný smart HTTP endpoint nebo přes projektově omezené credentials. Obecné SSH forwardování pro forge se nepoužije.
- Přímý egress na forge hosty musí být z agent kontejneru blokovaný; jinak lze broker obejít odcizeným nebo jinak dostupným credentialem.
- Broker vede audit bez ukládání tokenů či citlivého obsahu.

Výhoda: centrální politika a nejlepší izolace. Nevýhoda: nový hluboký modul, kompatibilita s rozsáhlými CLI API a Git protokolem, dostupnost a recovery.

## Otázky pro grill

- Jaký přesný útočník je ve scope: chybující LLM, malicious prompt, nebo libovolný proces v kontejneru?
- Je plná kompatibilita `glab`/`gh` skutečný požadavek, nebo stačí úzké operace: repo metadata, issues, MR/PR, status/checks?
- Má politika povolit push libovolné feature větve v aktuálním projektu, nebo jen nově vytvořené větve s prefixem/session identity?
- Jak broker bezpečně určí aktuální projekt při více worktrees, submodulech a více remotes?
- Jak se obslouží fork-based MR/PR workflow?
- Jak se rozdělí read a write credential a jak se budou rotovat/revokovat?
- Je Git smart HTTP proxy přijatelná, nebo jsou jednodušší per-project deploy credentials dostatečné?
- Jak přesně vynutit zákaz přímého forge egressu bez rozbití běžného HTTPS přístupu?
- Jak funguje nouzový Maintainer override, audit a recovery při nedostupném brokeru?
- Které existující Forge gate a SSH gate mechanismy lze znovu použít a co musí zůstat oddělené?
- Má Planner smět vytvářet MR/PR bez možnosti pushnout zdrojovou větev? Pokud ano, odkud se změna bere?
- Jaká má být UX a administrační cena přidání nového projektu/provideru?

## Doporučený postup příští session

1. Přečíst stávající doménu a ADR uvedené níže.
2. Grillem zmrazit threat model, povolené operace a přijatelné administrační náklady.
3. Porovnat A/B/C v tabulce podle isolation, UX, compatibility, operations a failure modes.
4. Vybrat nejmenší skutečnou security boundary; wrapper ponechat jen jako UX vrstvu.
5. Pokud zůstane nejasnost kolem Git transportu, udělat throwaway prototype brokerovaného `git ls-remote` + push do jediného testovacího repa.
6. Až potom navrhnout ADR a implementační issues.

## Existující artefakty — neduplikovat

- `/home/vlcak/Projekty/boxa/CONTEXT.md`
- `/home/vlcak/Projekty/boxa/docs/adr/0032-per-installation-agent-identity.md`
- `/home/vlcak/Projekty/boxa/docs/adr/0033-forge-identity-catalog.md`
- `/home/vlcak/Projekty/boxa/docs/adr/0034-dashboard-first-forge-ssh-ux.md`
- `/home/vlcak/Projekty/boxa/docs/forge.md`
- `/home/vlcak/Projekty/boxa/docs/ssh.md`
- `/home/vlcak/Projekty/boxa/lib/forge.sh`
- `/home/vlcak/Projekty/boxa/lib/ssh.sh`

## Doporučené skills

- `grilling` — hlavní režim pro oponenturu threat modelu a trade-offů.
- `boxa` — autoritativní pravidla Boxa identity, Forge/SSH gate a container boundary.
- `codebase-design` — navržení hlubokého Forge broker modulu a malé veřejné plochy.
- `domain-modeling` — pokud se budou měnit pojmy v `CONTEXT.md` nebo vznikne ADR.
- `prototype` — jen pro cílený experiment Git smart HTTP/broker transportu.
- `research` — pokud bude potřeba ověřit aktuální GitLab/GitHub token permissions proti primárním dokumentacím.

## Bezpečnostní poznámka

Nerozšiřovat push-capable agenta na Maintainera ani mu nepředávat další raw
credentials jen na základě tohoto návrhu. Nejprve rozhodnout, zda je současná
ochrana proti chybě (Varianta A) dostatečná, nebo je nutná skutečná izolace
nedůvěryhodného kontejneru (B/C).
