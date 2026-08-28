# Handoff — persona redesign: obě dávky UZAVŘENY CLEAN (2026-08-26)

Nahrazuje předchozí verzi. Původní AFK dávka i navazující live-fix
dávka (nálezy z prvního živého ověření) jsou DOJETÉ, oba review loopy
uzavřené s verdiktem CLEAN.
Větev `feat/agent-identity`, base dávky `2de61d3`, main nesahat, NIKDY
nepushovat. Squash-merge („slij") až po živém ověření na výslovné slovo.

## Co je hotové

- **Všech 9 issues (09, 11–18) implementováno + commitnuto**, issue
  soubory v `.scratch/forge-identity-catalog/issues/` mají `Status: done`:
  e6fafff (09 fzf headery), ca6b2d7 (11 binární gate + per-projekt
  agenti), 97c06b9 (12 persona storage + migrace), cc574c0 (13 key
  registry lazy re-add), 1d5e138 (14 assignment write-through), a76f9fd
  (15 bez posture pickeru), 7ad414d (16 víc klíčů), 7e07888 (17
  multiselect summary), 0c8047c (18 dashboard).
- **Závěrečný Codex review loop, 6 fix kol commitnutých**: 16534a8
  (kolo 1 — 7 nálezů), d0cb224 (kolo 2 — 5), 1b6ad7e (kolo 3 — 2),
  7f150c9 (kolo 4 — 2), 2b556a5 (kolo 5 — 1, registry rollback pod
  sdíleným PID lockem), 2e1b7f5 (kolo 6 — 1, assignment už nebere
  vlastní registry backup; rollback dělá výhradně locked gate apply,
  regression test na souběžný zápis). Vždy vše zelené.
- **Loop UZAVŘEN 2026-08-26**: potvrzovací re-review kola 6 vrátila
  **CLEAN**. Konvergence 7→5→2→2→1→1→0.
- Původní review thread expiroval; scoped thread
  `01a03be6-435d-71e2-9714-d8682f85f767` potvrdil kolo 6 CLEAN.
  (Pozn.: threadId žije jen po dobu session MCP serveru — do handoffu
  napříč dny nemá smysl.)

## Live-fix dávka (2026-08-26, po prvním živém ověření)

První živé ověření našlo 7 nálezů → issues 19–24 (nálezy 4+5 sloučené
do 23), vše implementováno + commitnuto:
- 0fb930b (#19 P1: adopt-existing attachoval boxí agent-identity klíč
  místo vybraných ~/.ssh klíčů; opraveno + oba dřív „timeoutující" pty
  testy byly hangy téhle cesty a teď procházejí)
- 3fc2037 (#20 fzf inline --height + echo volby)
- cd38eb4 (#21 dashboard jednou, akce hlásí deltu)
- 8a4097e (#22 legacy gate: markery, souhrn MISSING, konsentní migrace)
- f7ba28e (#23 ssh-agent messaging jmenuje proces + personu, důsledek
  assignmentu explicitně)
- f05be33 (#24 persona grammar v3: tokeny v 0600 souborech
  forge/tokens/, jednosměrná migrace, maskování ve výstupech)
Review loop live-fix dávky: 3 fix kola 586b9ed, d03344a, e187829;
konvergence 6→2→2→0, verdikt CLEAN (2026-08-26). Finální stav suit:
forge 200, persona 117, ssh 182, pty 40/0, shellcheck čistý.

## Dávka 25–27 (2026-08-26, po druhém živém ověření)

Druhé živé ověření odhalilo kořen opakovaně špatného klíče: krok
„SSH key:" v Add a persona nabízel jako default „Attach this machine's
Agent key" = boxí agent-identity klíč, bez ohledu na kind. Dále chyběl
Remove v dashboardu a legacy migrace byla zastrčená v menu.
Issues 25–27, vše implementováno + review CLEAN (1 kolo, 1 P2):
- ad90edf (#27 kind-aware SSH volba: mine = all host keys (default) /
  choose which (vč. manual path) / without; Agent key pro mine zmizel,
  pro ostatní kinds přejmenován)
- 061d4fe (#25 dashboard akce Remove a persona přes guarded remove)
- f2d084f (#26 legacy migrace: proaktivní one-time prompt při startu
  dashboardu, durable decline, marker se čistí po úspěšné migraci)
- f8be804 (oprava indexu v dashboard pty testu po novém menu — subagent
  26 to mylně hlásil jako pre-existující fail; byla to regrese z #25)
- c1ef7a1 (review P2: prázdné ~/.ssh u mine defaultu už neaborcuje
  registraci — degradace na keyless, token zůstává)
- b2fe0a8 (#28 z třetího živého ověření: Add a persona vypíše před
  token volbou mint návod s URL, kind=agent zmiňuje samostatný
  automation účet; helpery sdílené s guided setupem)
Re-review potvrdil CLEAN (naposledy vč. b2fe0a8). Suity: checklist
pty 21/21, dashboard pty 3/3, forge/persona/ssh zelené, shellcheck
čistý.

## Dávka 29–30 (2026-08-26, další nálezy třetího živého ověření)

- c1be81b (#29 dashboard akce „Add or rotate a token": u persony
  nabízí i chybějící forge (add label), před paste tiskne mint
  guidance (#28 helper), success rozlišuje added/rotated; klíče se
  neřeší — jsou persona-level, forge-agnostic)
- f1ecf76 (#30 kind-aware label místo „Generate a new Agent key" v
  `_boxa::forge_keys`, success hláška jmenuje personu; nový
  tests/test_forge_keys_pty.py)
- df2850b (review P3: reverzní pty test — GitLab-only persona
  s custom hostem získá GitHub token, GitLab token+host zachovány)
Review thread 01a03dbc-ae0c-79d3-9496-06b8fba26175, konvergence 1→0,
verdikt CLEAN. Suity: dashboard pty 31 zelených, forge 200,
persona 117, shellcheck čistý.

## Dávka 31–32 (2026-08-26, živý test add-GitLab-tokenu)

Miloš přidával GitLab token (rep.gaiagroup.cz) bez glab na hostu —
probe tiše spadl do generické hlášky, navíc add cesta lhala o
„existing token is unchanged".
- d2efd9c (#31 `_boxa::forge_require_probe_cli`: kontrola gh/glab
  před token promptem ve všech interaktivních tocích, hláška
  s install pokynem; probe zůstává tichý pro neinteraktivní volající;
  pty testy přes PATH manipulaci)
- f2f5094 (#32 failed add říká „no token was added to persona X",
  rotate drží původní copy)
Re-review v témže threadu: CLEAN na první pokus. Suity: pty 33/33,
forge + persona zelené, shellcheck čistý.

## Dávka 33–34 (2026-08-26, pokračování živého testu)

Nálezy: Milošovy ~/.ssh klíče nemají .pub (kopírované jen privátní) →
persona vznikla tiše keyless, gate off; `boxa ssh on` padal do legacy
key pickeru místo person.
- 59bf109 (#33 private-only klíče: sken/picker/manual path je berou,
  fingerprint degraduje na „unavailable", registry/reconcile/agent
  add fungují s path-based identitou; boxa privátní klíč dál NIKDY
  nečte — kde je .pub fakt potřeba, poradí `ssh-keygen -y` remedy)
- c90ab55 (#34 `ssh on` bez persony pouští assignment flow
  s předvybraným projektem, keyless persona = guidance, nové
  `boxa ssh on|off --pick` multiselect projektů, legacy picker jen
  v migračních cestách, ensure-ssh-gate.sh + completions)
- 5ac2e62 (review P2: persona follow-up už není short-circuitnutý
  stavem agenta/registry — legacy registry bez persony nepřeskočí
  assignment)
- 822dc4d (review P2: cancel assignmentu vyčistí registry projektu
  pod zámkem + reconcile běžícího agenta)
- 11f022d (review P2: cleanup rozhodnutí pod catalog lockem, skip
  když mezitím doběhl souběžný assignment)
Review konvergence 1→1→1→0, verdikt CLEAN (kolo 4 s instrukcí
nehlásit další concurrency hardening téže cesty). Suity: ssh 202,
ensure_ssh_gate 21, pty 33, forge/persona zelené, shellcheck čistý.

## Dávka 35–36 (2026-08-26, další nálezy živého testu)

Nálezy: `forge off` vypnul jen tokeny, klíče persony se forwardovaly
dál (syntetizovaný gate ignoroval forge stav); auto mód tiše zahazoval
argumenty za jménem projektu (`boxa easymusic ssh off` attachnul).
- e7490af (#35 `forge off` vypne i syntetizovaný SSH gate + reconcile
  běžícího agenta, `forge on` obnoví z klíčů persony; registry klíčů
  zůstává netknutá pro symetrický round-trip; platí i pro --global
  přes project-over-global resoluci)
- d735528 (#36 auto mód odmítne >1 positional s usage errorem a
  reorder hintem „Did you mean: boxa <sub> … <target>"; nová suita
  tests/auto-mode-args.sh, 50 testů)
- a6a2850 (review fixy: [P1] `ssh on`/`--pick` při forge=off odmítne
  s odkazem na `boxa forge on` — kill switch neobejitelný; [P1]
  selhání `ssh-add -D` se propaguje, global reconcile dojede zbylé
  projekty a reportuje selhané; [P2] `forge on` rollbackuje forge.conf
  při selhání apply. ensure-ssh-gate.sh netknut — jen globální
  onboarding, ověřeno.)
Review thread 01a03eaf-9612-7f10-889f-27b74197002d, konvergence 3→0,
verdikt CLEAN. Suity: forge 228, persona 144, ssh 212,
auto-mode-args 50, shellcheck čistý.
Pozn.: `forge use none` (odpřiřazení persony) funguje, ale je
neintuitivní — user chce časem hezčí command (zatím nechat).

## Dávka 37 (2026-08-26, pokračování živého testu)

Nález: `forge on` bez keyed persony nechal gate off potichu (report
jen při old != new) → user zbytečně recreatnul kontejner.
- dd7a3c4 (#37 `forge on` vždy vypíše výslednou řádku SSH forwardingu;
  bez persony pustí sdílený issue-34 assignment follow-up (TTY wizard
  s předvybraným projektem, non-TTY guidance na `boxa forge use`),
  keyless persona = pojmenované vysvětlení; `--global` tiskne
  per-project still-off důvody bez interakce; `ssh on` sdílí tytéž
  helpery)
Re-review v témže threadu: CLEAN na první pokus. Suity: forge 237,
persona 153, ssh 212, forge pty 23, shellcheck čistý.

## Známé pre-existující nálezy (NEreportovat jako nové)

- 4 WSLg test faily (read-only /tmp/.X11-unix).
- 2 timeouty v `tests.test_agent_identity_pty` (ověřeno na a76f9fd).
- 25 shellcheck nálezů v `completions/_boxa` (zsh soubor parsovaný
  jako bash).

## Provozní pravidla (beze změny)

- Codex VŽDY přes MCP `boxa-codex-delegate` UVNITŘ subagenta, call
  FOREGROUND; MCP timeout ~30 min → čekni working tree.
- Žádný docker build v boxe. Pty testy reálné (`python3 -m unittest`),
  žádné stuby na consent/prompt seamech. shellcheck vč. info. UI
  stringy EN.
- Živé ověření VÝHRADNĚ `./docker-run.sh` + recreate kontejneru.

## Zbývá

1. Třetí živé hostové ověření (Miloš, boxd): smazat starou personu
   `vlcak` (teď jde i z dashboardu — Remove a persona), projít nový
   Add flow (mine → default „Attach all host SSH keys" musí dát
   ~/.ssh/id_rsa + id_rsa_gitlab jako path reference), proaktivní
   legacy-migration prompt při startu dashboardu, `cat` persona
   souboru s `key=/home/vlcak/.ssh/…`. Nově i: „Add or rotate a
   token" na GitHub-only personě přidá GitLab token (mint guidance,
   host prompt); kind-aware generate label v menu klíčů. End-to-end
   agent persona cesta už ověřená (pull IVIJL/boxa přes forwardovaný
   per-projekt ssh-agent, žádný leak klíče do kontejneru). Nově i:
   `forge off` → recreate → gate off + žádné tokeny, `forge on`
   obnoví; `boxa easymusic ssh off` (špatné pořadí) vrátí usage error
   s hintem. POZOR: živé testy VŽDY přes `./docker-run.sh` z tohoto
   checkoutu — hostová `boxa` jede na main a forge nezná (2026-08-26
   to u usera vyrobilo matoucí attach + picker).
2. Miloš má zrevokovat GitHub token `gho_PMhq…` (leakl do transcriptu;
   k 2026-08-26 večer stále živý — dashboard hlásí „live as IVIJL").
3. Squash-merge do main až na slovo „slij". Nepushovat.
