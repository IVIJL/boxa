# Measurements 2026-09-12 (copied from agent memory)


Měřeno 2026-09-12 v boxe `boxa-boxa`, artefakty `/tmp/jobmeas/` (zmizí s boxou).
Kontext: [[codex-mcp-priority-over-companion]] — `codex mcp-server` zmizel v 0.154.0,
shoda s Codexem na jednom obecném job manageru (argv+cwd+env) pro Codex i dlouhé příkazy.

- Image `ivijl/boxa` peče Codex 0.149.1 (má ještě mcp-server); volume `boxa-npm-global`
  ho překrývá (0.154.0). Pin runtime musí být mimo volume, absolutní cestou.
- V boxe není `boxa` CLI (jen `boxa-mcp-run`), cgroups read-only, `prctl(PR_SET_CHILD_SUBREAPER)` OK.
- `codex exec --json`: `thread.started{thread_id}` → `item.*` (agent_message, command_execution
  s status/exit_code, file_change) → terminální `turn.completed{usage}`. `-o file` = finální zpráva.
  Stdin nutně `</dev/null`. SIGTERM zabije celý strom, exit 0, ale BEZ terminální události.
- `codex exec resume <thread_id> --json PROMPT` funguje; NEbere `-s`/`-C`, sandbox přes
  `-c sandbox_mode="workspace-write"`.
- Detached worker (setsid+subreaper, stdout/stderr do souborů, heartbeat, atomic result.json)
  přežije konec Bash toolu i subagenta. Po SIGKILL workeru dítě běží dál (reparent na PID 1),
  exit code ztracen. `kill -pgid` NEchytí setsid uprchlíka; env marker `BOXA_JOB_ID` + sken
  `/proc/*/environ` chytí vše i po smrti workeru.
- 14min `sleep` uvnitř `codex exec` (gpt-5.6-luna, effort low): shell tool nevypršel, Codex
  počkal a vrátil správný hash. Nativní dlouhý příkaz uvnitř Codexu tedy funguje aspoň 15 min.

**How to apply:** ADR job manageru z toho čerpá; před release ještě 2h gate + duplicitní start,
pád workeru, cancel, restart boxy.
