# Kickoff — mcp-render-durability (AFK dávka, coding přes MCP)

Prompt do nové session (cwd = `/home/vlcak/Projekty/boxa`):

---

Jedeme `/afk-feature-workflow` na feature `mcp-render-durability`.

**Rozsah:** `.scratch/mcp-render-durability/issues/01..04`, řetěz v tomhle pořadí
(každá je blokovaná tou předchozí). Parent ADR: `docs/adr/0022-durable-claude-mcp-render-and-approval.md`
(status accepted). Issue soubor JE zmražený spec — nedomýšlej scope.

**Twist proti skillu — coding backend není plugin, ale MCP.**
Místo `node .../codex-companion.mjs task --write --fresh` deleguj implementaci
tooolem `mcp__boxa-codex-delegate__codex` (agent-trusted MCP `codex-delegate`,
aktivovaný pro tenhle projekt). Parametry:

- `prompt` — celý spec (Codex nemá kontext session, musí být všechno v promptu)
- `cwd` — `/home/vlcak/Projekty/boxa`
- `sandbox` — `workspace-write`
- `approval-policy` — `never`
- `model` nepinuj, ať jede Codex na svém defaultu

Navazování na rozdělaný thread jde přes `mcp__boxa-codex-delegate__codex-reply`
(`threadId` + `prompt`), ale defaultně jeď fresh — issues jsou nezávislé.

**Proč ten twist stojí za to:** MCP tool call je synchronní z podstaty, blokuje
do návratu. Tím strukturálně mizí ta past, před kterou skill varuje — Codex proces
spuštěný Bashem uvnitř subagenta umřel, když se subagent vrátil, a companion state
zůstal navěky `running`, takže pád byl tichý. Přes MCP se to stát nemůže.

**Ověř hned na startu, než rozjedeš první issue:**

1. `mcp__boxa-codex-delegate__codex` je viditelný v hlavní session. Kdyby ne:
   `boxa mcp status` na hostu, `RENDERS` musí být `claude:rendered` — když je
   `claude:drift`, spusť `boxa mcp doctor --fix` a restartuj session.
2. Ten tool vidí i **subagent**, kterého na issue pouštíš. Kdyby ne, spadni zpátky
   na plugin runtime dle skillu (`codex-companion.mjs task --write --fresh`,
   FOREGROUND) a řekni mi to — je to zjištění, ne chyba.
3. `CLAUDE.md` v rootu existuje (je untracked + gitignored, po `boxa update` mizí).
   Kdyby chybělo: `printf '@AGENTS.md\n' > CLAUDE.md`, jinak se nenačtou pravidla
   lokálního trackeru a agent začne sahat po `gh issue`.

**Zbytek drž přesně dle skillu:** čerstvý subagent na každou issue, subagent sám
ověří zelené testy (`PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_mcp*.py'`
+ `shellcheck -S info -x build.sh install.sh docker-run.sh scripts/*.sh lib/*.sh tests/*.sh`),
commit HNED bez per-issue review (`mcp: <summary> (#mcp-render-durability/NN)`),
hned po commitu update issue souboru (Status → `done`, odškrtat splněná kritéria),
řetěz bez ptaní se mě, a až po VŠECH čtyřech jeden Codex review přes celou feature
(`--base <commit před 01>`), loop dokud čistý nebo odargumentované.

Coding backend echni na startu, ať to můžu přebít.

---

## Kontext, který se do promptu nevešel

Diagnóza, ze které ADR 0022 vznikla (session 2026-07-28):

- Aktivovaný `codex-delegate` zmizel z `~/.claude/.claude.json`; `boxa mcp status`
  hlásil `claude:drift`, `boxa mcp doctor --fix` to opravil.
- Vyvráceno pokusem: běžící Claude session config **nepřepisuje** natvrdo — externě
  vložený marker přežil, session sáhla jen na svoje `lastCost`/`lastSessionId` pole.
- Kdo entries smazal, se nedokázalo — Claude rotuje jen 5 záloh a všechny byly
  z host configu. Kandidáti: recovery z `.claude.json.backup.*`, nebo race
  (i boxa render je full-file read-modify-write bez sdíleného zámku).
- Past při debugování: `docker exec` bez `-u node` běží jako **root** a wrapper pak
  správně odmítne (`agent-trusted MCP launch requires the Container account node`).
  Není to bug.
- Runtime snapshot `/run/boxa-mcp-runtime/catalog-runtime.json` je `0644`, node ho
  čte a obsahuje katalog **i** aktivace včetně `consumers`/`enabled` — na tom stojí
  issue 04.
- Klíče `enabledMcpjsonServers` / `disabledMcpjsonServers` /
  `enableAllProjectMcpServers` jsou v nainstalovaném Claude Code 2.1.220 přítomné
  (ověřeno grepem binárky).
