# Codex (gpt-5.6) design review — per-project memory limits

Date: 2026-07-17, pre-implementation gate. Read-only pass over
HANDOFF.md, issues 01–09, CONTEXT.md `### Memory`. Outcome: feature
approved; spec updates folded into the issues (see HANDOFF, section
"Design-review pass"); some recommendations rejected on purpose.

## 1. Verdict

Ano — **hard Memory limit na vnějším Containeru je správný primární
mechanismus**. Je to jediný bod v této topologii, který současně zahrne
agentovy procesy, rootless DinD i jeho workloady a který zasáhne bez
závislosti na polling procesu. Explicitní shoda `memory_swap = memory`
správně uzavírá Docker footgun s implicitním swapem. Docker tento model
přímo podporuje a cgroup v2 `memory.max` vyvolá lokální cgroup OOM,
nikoli globální OOM, když nelze spotřebu snížit.

**Není to ale sama o sobě garance „jeden Project nikdy neshodí WSL
VM/Linux host".** Specifikace musí buď oslabit formulaci cíle, nebo
přidat host-side globální rozpočet/admission control.

Zásadní mezery threat modelu:

- **N limitů se může přečerpat.** Cgroup hard limity jsou limity, nikoli
  rezervace; kernel výslovně dovoluje, aby jejich součet přesáhl
  kapacitu rodiče. Dva Projecty po 65 % mohou společně vyvolat globální
  OOM.
- **Ani jeden 65% Project nemusí být bezpečný, pokud zbytek VM už
  spotřebovává více než zbývajících 35 %** (Docker daemon, WSL/kernel,
  další distribuce, shared služby).
- **Staré běžící Containery zůstávají neomezené, dokud se jich konkrétní
  invocation nedotkne** — issue 02 (původní znění) nebyla úplná migrační
  cesta.
- **Vnější cgroup neobsahuje všechny prostředky, které může Project
  nepřímo aktivovat** — host agent Chrome, host-side brokery, outer
  Docker daemon jsou mimo jeho cgroup.
- **Trusted host user může ochranu vypnout** (unsafe override jen
  s warningem).
- **Feature nechrání proti PID exhaustion, CPU starvation, disk/IO
  exhaustion.**

## 2. Alternatives & complements (all COMPLEMENTS, none REPLACES)

1. **Globální Boxa memory budget / admission control** — sečte hard
   limity běžících `boxa-*` Containerů, odmítne start/update nad budget.
2. **`.wslconfig memory=`/`swap=`** — strop celé VM, chrání proti
   globálnímu OOM, nechrání jednotlivé Projecty.
3. **Docker Desktop resource settings** — v WSL2 režimu fakticky opět
   `.wslconfig`, ne nezávislý mechanismus.
4. **`autoMemoryReclaim`** — vrací cache, neomezuje anonymní paměť,
   nezastaví runaway RSS.
5. **User-space cgroup watcher** — dobrý pro early warning/archival,
   race-prone, nenahrazuje `memory.max`.
6. **`memory.high`** — koncepčně skvělé, na ověřené topologii
   nedosažitelné (cgroupfs ro, žádný Docker flag); 80/90% warning je
   observability substitute, ne throttling substitute.
7. **`systemd-oomd`** — vyžaduje plnou unified hierarchy pod systemd,
   zde nedosažitelné.
8. **`earlyoom`** — globální, ne per-Project; uvnitř Containeru by
   sledoval VM data, ne `memory.max`.
9. **Docker `--memory-reservation`** — soft limit, later optimization.
10. **PIDs/CPU/IO limity** — samostatný feature, mimo scope.

## 3. Critique of key decisions

- **65% derived default — needs change.** Přijatelný UX heuristic, ne
  safety invariant: MemTotal-based, násobí se N Projecty, nekontroluje
  pre-existing Containery, unsafe override jen warns. Buď globální
  budget, nebo oslabit stated goal.
- **Swap off by default — acceptable.** Nejsilnější část návrhu.
  Doplnit: zobrazovat `memory.swap.current`, vysvětlit chování při
  hostitelském `SwapTotal=0`, precedence `--memory`/`memory_swap`.
- **OOM zabije největší proces — acceptable policy, wording needs
  change.** Kernel volba je heuristika (`oom_score`), ne garance.
  Přepsat na "OOM victim selected by kernel".
- **No daemon — acceptable pro enforcement, needs change pro
  diagnostics.** Warning/archive vrstva musí být explicitně
  "best-effort/eventual".
- **Dmesg-based OOM archive — needs change.** Kromě restart gap: chybí
  persistentní container-ID→Project mapping po `docker rm`, race mezi
  sweep a removal, slabý dedup, chybí locking proti paralelním
  invocations, chybí `/var/log/boxa/oom` provisioning.

## 4. Scope critique

- Issue 05 příliš široká — rozdělit (parser/state-machine, Claude
  registration, Codex fallback).
- Issue 06 nejrizikovější kandidát na odklad — samostatný feature.
- Issue 04 — removed-Container autopsy počkat na stabilní 06; top RSS
  jen orientační.
- Issue 08 — troubleshooting scope předčasný před stabilizací chování.
- Issue 09 — rozdělit na core isolation test a fixture-driven sweep
  test; "unlimited bystander" nahradit limitovaným.
- ADR 0020 přepsat a schválit JAKO PRVNÍ.

## 5. Recommended spec changes (priority order)

1. Rozhodnout: VM-survival garance (globální budget) vs. per-Project
   containment (oslabit wording).
2. Upgrade migration pro všechny existující běžící Containery.
3. Přesně definovat derived default: zdroj MemTotal, rounding, min
   limit (Docker ≥6 MiB), recompute policy.
4. Unsafe override jako explicitní opt-out (`--allow-unsafe-memory`).
5. Upřesnit `memory`/`memory_swap` precedenci přes config vrstvy.
6. Riziko live-lowering přes `docker update` (může spustit OOM) +
   integration test.
7. Opravit absolutní wording o OOM victim/survival na
   heuristic/observed.
8. Rozšířit `boxa mem`/hook o `memory.swap.current`.
9. Odložit/předělat issue 06 (mapping, sync sweep, boot ID, locking,
   provisioning).
10. No-daemon kontrakt explicitně best-effort diagnostics.
11. Rozdělit issue 05.
12. Rozdělit issue 09.
13. ADR 0020 na začátek batche.
14. Zúžit první AFK batch: ADR → parser/config → create + migration →
    ls/minimal mem → core test → core docs; hooky/notifikace/archive →
    navazující batch.

## Disposition (orchestrator decisions, 2026-07-17)

Accepted → folded into issues: #2 (as convergence sweep in issue 02),
#3 partial (6 MiB floor, issue 01), #6 (issue 02), #7 (issues 06/07/08),
#8 (issue 04), #13 (ADR first, issue 07), `.wslconfig` backstop (issue
08), sum > MemTotal warning (issue 01) as the lightweight answer to #1.

Rejected — do not re-litigate: full admission control (#1, #4 — config
edit is already an explicit act; warning suffices), deferring/reworking
issue 06 (#9, #14 — the lost-evidence gap WAS the motivating incident;
its dedup/timestamp-reset handling already covers the main risks),
splitting issues 05/09 (#11, #12 — AFK tracer-bullet flow handles them
as-is).
