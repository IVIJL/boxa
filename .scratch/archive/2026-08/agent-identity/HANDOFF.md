# Handoff — agent-identity AFK batch (2026-08-25)

Stav pro další session. Kickoff: [KICKOFF.md](KICKOFF.md), spec
[PRD.md](PRD.md), ADR `docs/adr/0032-per-installation-agent-identity.md`.

## Hotovo

- **Všech 9 issues (11–18 + 19) implementováno a commitnuto** na větvi
  `feat/agent-identity`, rozsah `f02cee9..d666e6b` (16 commitů, NEPUSHNUTO).
  Issue 19 (forge host Allowlist offer, návrh Miloše během dávky) přidána
  nad rámec kickoffu.
- **Review loop čistý po 6 kolech** (Codex, thread
  `01a0375e-f211-7940-9443-046c1498b5d6`; fix-thread
  `01a03765-b34c-77a3-8978-09713b61f129`). Hlavní opravy: races +
  stale-recovery v novém `_boxa::with_pid_lock` (lib/resources.sh,
  finálně atomický hardlink claim + tombstone takeover, POSIX bez
  GNU-only flagů kvůli macOS), adopce klíče bez čtení privátního
  materiálu (přes dedicated ssh-agent), rollback adopce, glab config
  path `~/.config/glab-cli`, gh/glab volume chown, GitLab checklist
  drží self-hosted hostname, expiry heads-up i při attach/restart.
- Testy zelené: ssh 158, forge 128, naming 62, provisioning 54,
  ensure-agent-identity 12, pty přes `python3 -m unittest` (pytest
  v boxe není). shellcheck clean vč. info-level.
- Tracker: všechny issues 11–19 `Status: done` (`.scratch/` je
  gitignored, žije jen na disku).

## Provozní poučení (kriticky dodržovat)

- **ŽÁDNÝ `docker build` uvnitř boxy** — 2× OOM shodil dockerd i celou
  session (dockerd ~4,6 GB RSS). Testy OK, buildy jen na hostu. Uloženo
  v memory `no-docker-build-inside-box`; do promptu každého subagenta.
- Subagenti: všechny cally FOREGROUND (žádné run_in_background), Codex
  přes MCP `boxa-codex-delegate` uvnitř sonnet slupky.

## Navazuje (2026-08-25 odpoledne)

Feature pokračuje katalogem identit: ADR 0033 + AFK dávka
`.scratch/forge-identity-catalog/` — **aktuální pipeline a stav WIP viz
`.scratch/forge-identity-catalog/HANDOFF.md`** (necommitnutý probe fix,
3-posture picker, status identity; /cr + commit dělá až nová session).
Machine user: **vlciagent** (klíč připojen a ověřen).

## Otevřené body

1. **Image size investigace (rozpracováno):** hostí build dal image
   7,79 GB; opakované buildy nafouknou BuildKit cache na 10–14 GB.
   Miloš má poslat `! docker history ivijl/boxa:latest --format
   '{{.Size}}\t{{.CreatedBy}}' | head -40` (+ `docker buildx du`).
   Kandidáti dle Dockerfile: rust toolchain (ř. 178), nvim/LazyVim +
   treesitter (ř. 201–272), první velká apt vrstva (ř. 14), npm globály
   (claude/codex/agent-browser). Cache úklid: `docker builder prune -f`.
2. **Zvážit přesun `glab` z první apt vrstvy (Dockerfile ř. 19) do
   pozdější vrstvy** — teď každá změna té vrstvy zneplatní celou cache.
   Nabídnuto Milošovi, nerozhodnuto.
3. **Živé hostové ověření (Miloš, checklist níže).**
4. Po ověření: **squash-merge `feat/agent-identity` do `main` jako
   jeden commit** — jen na výslovné slovo („slij"). Nepushovat.

## Checklist živého ověření (host)

Příprava: `OLD_IMG` zálohovat (`docker image inspect -f '{{.Id}}'
ivijl/boxa:latest`), `cp -a ~/.config/boxa ~/.config/boxa.bak`.
Dev CLI = `./docker-run.sh` z checkoutu (instalované boxy se to nedotkne);
image tag `ivijl/boxa:latest` build přepíše (rollback = retag OLD_IMG).

1. `./build.sh` projde (glab v image, gitlab.com keys v known_hosts).
2. `./docker-run.sh doctor --fix agent-identity` — wizard, Agent key +
   dedicated agent v `~/.config/boxa/agent-identity/`.
3. `./docker-run.sh ssh` + přepínání `off/agent/user`, fingerprint.
4. `./docker-run.sh forge set github` (machine user PAT) a `forge set
   gitlab` (host `rep.gaiagroup.cz`, service account) — Allowlist offer
   předvyplní `gaiagroup.cz`; `forge setup/checklist/adopt`.
5. Čerstvý box (scratch projekt): `glab version`; env `GH_TOKEN`/
   `GITLAB_TOKEN`/`GITLAB_HOST`; `gh api user`; `glab api user`;
   committer identity; push + PR (GitHub) a push + MR (GitLab).
6. `gh auth login` v boxu přežije stop/start; jiný projekt ho nevidí;
   env vítězí nad in-box loginem.
7. Expiry heads-up i při attach/restart existujícího boxu.
8. `wsl --shutdown` → klíč/agent/forge store přežijí.
9. Pty testy na hostu i přes `pytest` (v boxe jen unittest).

Úklid po testech: test box + `boxa-<name>-{history,docker,gh,glab}`
volumes smazat, `forge unset github|gitlab` (nebo restore zálohy
`~/.config/boxa`), `docker image prune -f` + `docker builder prune -f`.
