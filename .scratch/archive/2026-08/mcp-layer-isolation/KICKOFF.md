# Kickoff — mcp-layer-isolation (AFK batch)

Prompt pro novou session:

> Pusť /afk-feature-workflow na featuru `mcp-layer-isolation`. Pracuj na
> branchi `feat/mcp-layer-isolation` (existuje, NEpracuj na main, nepushuj).
> Nejdřív commitni připravené dokumentační změny (CONTEXT.md, docs/adr/0028,
> docs/adr/0029, status v 0022, .scratch/mcp-layer-isolation/) jako úvodní
> commit. Pak zpracuj issues v .scratch/mcp-layer-isolation/issues/ v pořadí
> 01 → 02 → {03, 04, 05 paralelně dle závislostí} → 06; 07 kdykoliv.
> Živé hostové ověření NEdělej, to si uživatel testne sám mimo tracker.

Kontext pro agenty:

- Design: ADR 0028 (launch-time injekce, konec shared-file renderů) a
  ADR 0029 (remote entries, pending, everywhere). Glosář: CONTEXT.md sekce
  MCP (nové termíny: Remote MCP catalog entry, Everywhere entry, Pending
  activation, Agent launch wrapper).
- Ověřená fakta z přípravy (v kontejneru, netřeba znovu zkoumat):
  - Claude 2.1.234: `--strict-mcp-config --mcp-config=<inline JSON>` funguje,
    POZOR nutná `=` forma (variadický space tvar spolkne další argumenty);
    servery z `--mcp-config` nepodléhají `enabledMcpjsonServers` approval.
  - Codex 0.145.0: `-c mcp_servers.<n>.enabled=false` i plná definice serveru
    přes `-c` fungují, globální root flag, snese subcommandy.
  - `~/.local/bin/claude` = symlink přepisovaný v setup-claude.sh
    (repair_claude_bin) při každém startu → nahradí se generovaným wrapperem;
    `~/.local/share/claude` je RO host mount (mac: volume boxa-mac-claude-bin).
  - `/usr/local/share/npm-global/bin/codex` je node-owned npm symlink →
    nahradit wrapperem regenerovaným při startu kontejneru.
  - Runtime snapshot `/run/boxa-mcp-runtime/catalog-runtime.json` už obsahuje
    `projects` (project key → catalogId → {consumers, enabled}) i `entries`.
  - `AGENT_PATH` v scripts/mcp/trusted.py resolvuje `codex` na npm-global
    cestu → delegate projde wrapperem bez úprav AGENT_PATH.
- Wrapper = kritická cesta každého startu agenta: lehký, rychlý, fail mód
  „bez MCP + stderr varování", nikdy neblokovat start.
- Shell změny: shellcheck-clean včetně info-level.
