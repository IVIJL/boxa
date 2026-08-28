# 01 — SSH gate core: podmíněný mount, konec auto-ssh-add, startovní stav

Status: done

## Parent

ADR 0026 — SSH gate: agent forwarding becomes opt-in; boxa never loads keys.
Glosář: CONTEXT.md → SSH gate, Boxa SSH config.

## What to build

Forwarding hostového SSH agent socketu do kontejneru se stane opt-in
**SSH gate**. Nový conf `~/.config/boxa/ssh.conf` používá stejnou
never-sourced INI gramatiku jako resources.conf (ADR 0020): globální klíč
`agent=on|off` + sekce `[/absolutní/cesta/projektu]`, projektová sekce
vyhrává nad globální; když není nic, brána je **off**. Napiš malý vlastní
loader (jeden klíč; negeneralizuj loader resources — viz ADR 0026).

Při vytváření kontejneru se agent socket mountuje **jen** když brána pro
daný projekt vychází on. Celý blok „SSH agent setup" (oživování agenta
přes keychain soubory, startování ssh-agenta a hlavně automatický
`ssh-add` defaultních klíčů) se odstraňuje bez náhrady — boxa nikdy sama
nenahrává klíče ani nečte privátní materiál. Keychain zůstává jen jako
dokumentovaný hostový postup (docs), ne jako kód v runu.

Každý start boxy vytiskne efektivní stav jedním řádkem:

- brána on + agent s klíči → `SSH: forwarded (keys: <jména/komenty z ssh-add -l>)`
- brána on + agent prázdný/mrtvý → forwarding se nemountuje resp. mountuje
  jen existující živý socket; hint `SSH: forwarding on, but agent has no
  keys — run 'boxa ssh add'` (příkaz vznikne v issue 03; hint už teď
  odkazuje na něj)
- brána off → `SSH: not forwarded (enable: boxa ssh on)`

Mount `~/.config/boxa/ssh_config` (Boxa SSH config) a flag `--ssh-config`
zůstávají beze změny — brána řídí jen socket. Stávající varování „SSH
agent not available" dává smysl jen při bráně on.

## Acceptance criteria

- [x] Bez `ssh.conf` (čerstvý stav) se agent socket do nového kontejneru
      nemountuje a `SSH_AUTH_SOCK` uvnitř není nastaven
- [x] `agent=on` globálně mountuje socket; `agent=off` v sekci projektu ho
      pro ten projekt vypne (a naopak: globál off + projekt on → mount)
- [x] Auto-`ssh-add` a auto-start agenta jsou z docker-run.sh odstraněny;
      žádná cesta v kódu nevolá `ssh-add` bez explicitní akce uživatele
- [x] Startovní výstup vždy obsahuje právě jednu SSH stavovou řádku
      odpovídající třem stavům výše (on+klíče se jmény, on+prázdno s hintem,
      off s enable hintem)
- [x] Mount Boxa SSH configu a chování `--ssh-config` se nemění
- [x] Testy pokrývají rezoluci brány (default/global/projekt, invalid
      sekce) a přítomnost/nepřítomnost mount argumentů
- [x] shellcheck čistý na změněných souborech

## Blocked by

None — can start immediately.

## Comments
