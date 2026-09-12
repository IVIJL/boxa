---
name: boxa
description: Boxa dev environment guide — invoke when the user mentions the boxa CLI, boxa Containers, MCP catalog or MCP activation, trusted MCP execution, the SSH gate, Forge gate, dev URLs (*.test, *.sslip.io), Allow-for windows, the Allowlist, Agent-browser session lifecycle, ports, mkcert HTTPS, Container identity, Jobs and the boxa-job CLI (long-running commands, Codex delegation), or anything about why network/host behaviour differs from a plain shell.
user-invocable: false
---

# Boxa

Boxa runs each Project in a Linux Container behind a default-deny outbound firewall. The `boxa` CLI lives on the host and manages Containers, the **Allowlist**, **Allow-for windows**, **Host connections**, the **SSH gate**, **Forge gate**, **Agent-browser sessions**, ports, and the mkcert HTTPS layer. See `CONTEXT.md` for the canonical glossary and `docs/adr/` for design rationale.

## Identity check (run first)

```sh
test -f /etc/boxa/identity.json && jq -r .project /etc/boxa/identity.json
```

- Empty / file missing → you are on the **host**. See § On host.
- Non-empty (a project name) → you are inside a boxa **Container** for that **Project**. See § Inside container.

The file is the canonical **Container identity** (CONTEXT.md § Project / container, ADR 0011). Its mere presence is the deterministic signal.

## Inside container

You are inside a Container. Respect these boundaries:

1. **The `boxa` CLI is host-only.** It does not exist in the Container PATH. To start/stop Containers, manage the **Allowlist**, open **Allow-for windows**, create or remove **Host connections**, change the **SSH gate** or **Forge gate**, or orchestrate **Agent-browser sessions**, ask the user to run the corresponding `boxa …` command on the host.
2. **Network is default-deny against the Allowlist.** Roughly fifteen domains resolve; everything else is `REJECT`ed by the firewall. **DNS pinning** forces all name resolution through the in-Container dnsmasq, so hardcoded-IP fetches fail too. See ADR 0001, ADR 0007.
3. **Container-to-host services use a Host connection.** The Allowlist is a domain gate and does not grant traffic to a host service. Ask the user to run `boxa connect host <port> --name <label> [--all]` on the host. Omit `--all` for the current box; include it only when every present and future box should be trusted. See ADR 0023.
4. **SSH agent forwarding is opt-in.** The **SSH gate** is `off` or `on` only from the host and takes effect when the Container is created. When on, the Container receives its dedicated **Project agent**; a forwarded socket grants signing authority over every key in that agent. See ADR 0026 and ADR 0034.
5. **Forge credentials are opt-in.** The **Forge gate** is off by default, can be enabled globally or per Project only from the host, and injects credentials only when the Container is created. It does not grant network access to the forge host; the **Allowlist** remains separate. See ADR 0032.
6. **Dev URLs bypass the firewall.** `http(s)://<port>.<project>.test` and `http(s)://<port>.<project>.127.0.0.1.sslip.io` resolve locally and never hit the **Allowlist** gate. See ADR 0007.

### Recognising a default-deny denial

When `curl`, `npm`, `pip`, `git fetch`, or similar fails with `Could not resolve host`, `Connection refused`, `Connection timed out`, or a TLS handshake error against a host you've never used before, the most likely cause is that the host is not in the **Allowlist**. It is not a server outage and not a bug in the project.

Ask the user to run one of these on the host:

```sh
boxa allow <domain>             # durable: add to the Allowlist
boxa allow-for <minutes>        # time-bounded Allow-for window; harvests
                                  # every queried non-Allowlist domain into
                                  # a Harvest log for review
```

The Allow-for window is the right tool when the agent needs network for a single task and you don't yet know which domains it will touch. The Harvest log at teardown lists every non-Allowlist host that was contacted (see ADR 0009, CONTEXT.md § Allow-for window).

### Reach a service on the host

When container-side traffic is meant for a service listening on the host, an
Allowlist entry or Allow-for window is the wrong gate. Ask the user to run this
on the host:

```sh
boxa connect host <port> --name <label> [--all]
```

The **Host connection** is per-box by default. `--all` is a deliberate standing
grant to every present and future box. Code in an inner Docker container reaches
the forward at `10.0.2.2:<local-port>`; when no conflict forces a fallback, the
local port is the host port. Use `boxa connections` on the host to inspect the
persisted address and status. See ADR 0023.

### Drive the host browser from inside

Use the upstream `agent-browser` CLI (shadowed by a boxa wrapper that auto-connects to CDP — see § Agent-browser below). Session start/stop is the user's job on the host.

### Run long work as a Job (`boxa-job`)

`boxa-job` is a Container command (ADR 0037, full guide in `docs/jobs.md`). A **Job** is a command whose lifetime, state, and result belong to the Container, not to your shell call, your subagent, or your session.

**Use it for** any command that may outlive one shell call (long builds, test suites, migrations, multi-minute scripts) and for all Codex delegation. `codex mcp-server` no longer exists; there is no MCP path any more.

Start, wait in a loop, then take the result:

```sh
boxa-job start --key build-01 -- make -j4 all          # returns a jobId at once
boxa-job wait <jobId>                                  # blocks up to 540 s
# exit 10 means "still running": call wait again immediately
boxa-job result <jobId>                                # state, exit code, timings
boxa-job log <jobId> --tail 40                         # only on demand
```

A Codex job, with model and effort always explicit:

```sh
boxa-job start --key review-01 --codex --model gpt-5.6 --effort high \
    "Review the diff of HEAD and report findings."
boxa-job reply <threadId> --key review-02 --model gpt-5.6 --effort high "Now fix finding 1."
```

Rules that matter more than the flags:

- **One subagent = one Codex thread = one Job at a time.** A `reply` into a thread whose Job is unfinished is refused `thread-busy` (exit 12). Steering is `cancel` and then `reply`; a turn in flight cannot be interrupted with a message.
- **Wait frugally.** Block in `wait`, call it again on exit 10, write no commentary between waits, do not re-analyse the request between waits, and read logs only on demand or for diagnosis. Never return early while the Job runs: that answers nothing. On completion, evaluate the result and hand the main agent a summary with the evidence.
- **Distinct bad states stay visible.** `failed`, `orphaned`, `exited-with-survivors`, `interrupted`, and `finished-unknown` each need a decision; do not report them as "done".
- **The Job key stops duplicates, not parallel work.** The same key and the same request attaches to the running Job instead of starting a second one.
- **Ack only what the orchestrator asked for.** Starting beside other running Jobs is refused with `needs-ack` (exit 11) and a list. Repeat the call with `--ack-concurrent <ids>` only when the orchestrating agent deliberately asked for parallel work; otherwise wait for the other Job instead.

## On host

You can run the full `boxa` CLI. `boxa --help` is the source of truth; common surface:

### Project / Container lifecycle

```sh
boxa up [project]               # start the Container for a Project
boxa down [project]             # stop the Container
boxa shell [project]            # open a shell inside the Container
boxa status                     # list Containers and their state
boxa update                     # refresh boxa itself + self-heal hooks
```

### Allowlist and Allow-for window (ADR 0001, ADR 0009)

```sh
boxa allow <domain>             # add a domain to the Allowlist (durable)
boxa allow-for <minutes>        # start an Allow-for window in the current
                                  # Project's Container; passes non-Allowlist
                                  # traffic, logs it to the Harvest log
```

Starting a second `allow-for` inside an active window resets the clock (does not stack).

### Agent-browser session (ADR 0010)

```sh
boxa agent-browser start <project>           # open an Agent-browser session
boxa agent-browser stop <project>            # close it
boxa agent-browser allow-for <min> <project> # open an Agent-browser network
                                               # window (proxy → harvest mode)
boxa agent-browser allow-for --stop <project>
```

Exactly one **Agent-browser session** per Container at a time. The session is bound to one **Host agent Chrome** and one **Agent-browser session bridge** for its lifetime; all three die together on `stop`. See § Agent-browser.

### Host connections (ADR 0023)

```sh
boxa connect host <port> [local-port] [--name <label>] [--from source | --all]
boxa connect rm host <port> [--from source | --all]
boxa connections
```

A **Host connection** grants one host IP:port to one box by default. `--from`
selects that box explicitly; `--all` instead grants every present and future
box and cannot be combined with `--from`. Inner Docker connects through
`10.0.2.2:<local-port>`.

### SSH gate (ADR 0026, ADR 0034)

```sh
boxa ssh                        # show effective state for the current Project
boxa ssh off|on [project|path]
boxa ssh off|on --global
boxa ssh add                    # add keys to the current Project agent
```

Project configuration overrides the global choice; absent both, forwarding is
off. `on` forwards that Project's dedicated agent. Changes affect newly created Containers, so
follow the restart hint for a running Project. The separate **Boxa SSH config**
mount is not gated. Reaching an SSH server still requires the **Allowlist** or a
**Host connection**. See `docs/ssh.md` for the security model.

### Forge gate (ADR 0032)

```sh
boxa forge                       # show gate, source, credentials, token ages
boxa forge on|off [project|path] # set a durable per-Project choice
boxa forge on|off --global       # set the durable global fallback
boxa forge set github|gitlab     # securely store or rotate a token
boxa forge setup [github|gitlab] # run the guided identity flow
```

Project configuration overrides the global fallback; absent both, forge access
is off. Gate changes and rotations affect newly created Containers, so follow
the `boxa stop && boxa` restart hint. When on, Boxa injects `GH_TOKEN` and/or
`GITLAB_TOKEN`; self-hosted GitLab also gets `GITLAB_HOST`. These environment
credentials override persistent in-Container `gh`/`glab` login files. After
`set`, Boxa offers to add an uncovered forge host to the **Allowlist**, default
No; declining prints a manual `boxa allow <host>` hint. See `docs/forge.md`.

### Ports and HTTPS

```sh
boxa ports [project]            # list active listening ports + their dev URLs
boxa port <port> [project]      # print the dev URL for a single port
```

mkcert provisions HTTPS for `*.test` and `*.sslip.io` dev URLs (ADR 0008). HTTPS degrades gracefully if mkcert is unavailable — plain HTTP still works.

### MCP catalog and Project activation

Treat these as separate states:

1. `boxa mcp add NAME -- COMMAND...` records a durable user-wide **MCP catalog** definition. `NAME` is only Boxa's label; Boxa later executes `COMMAND...`. Adding neither installs the command nor activates the server.
2. `boxa mcp install NAME --project PATH` materializes a runtime when needed. Skip it for commands already provided by the Container image.
3. `boxa mcp readiness NAME --project PATH` checks a running Project without activating anything.
4. `boxa mcp activate NAME --project PATH --for claude|codex|claude,codex` exposes the entry only in that Project and only to the selected consumers.

Catalog definitions, installed runtimes, and execution modes survive Container and host restarts. Catalog membership is never global activation. For another Project, reuse the existing catalog entry and add a separate activation.

Activation writes only Boxa's host-owned store and secret-free runtime snapshot. It never writes a Project or shared agent config; Container-only Claude and Codex launch wrappers inject the selected profile into each new agent session.

Run all `boxa mcp ...` commands on the host. When operating inside a Container, inspect local prerequisites if useful, then give the user the exact host commands.

#### Codex delegation is not an MCP entry any more

Do not add `codex mcp-server` to the catalog. Current Codex releases removed
that subcommand, so such an entry can never start; ADR 0037 retired it. Codex
delegation runs as a **Job** inside the Container instead: `boxa-job start
--codex` (see § Jobs and `docs/jobs.md`).

A host that carries the old entry keeps it until the user removes it. `boxa
doctor` and `boxa mcp status` explain it and print the removal command:

```sh
boxa mcp remove codex-delegate      # use the name the entry really has
```

Use `boxa mcp catalog`, `readiness`, `status`, and `doctor` to explain each state. `boxa mcp --help` is the complete user-facing workflow; when working in the Boxa repository, consult `docs/mcp.md` for design detail.

## Agent-browser

Boxa-specific integration glue only. For the upstream CLI surface (navigation, screenshots, network inspection, the two-gate model in detail), defer to the upstream `agent-browser` skill (installed alongside this one). For architecture, see ADR 0010.

Three boxa-specific facts:

- **Lifecycle is host-only.** Inside a Container you cannot start, stop, or open a network window — those are `boxa agent-browser …` commands on the host. Ask the user.
- **The auto-connect wrapper handles CDP.** Since commit `f9e30fa`, the in-Container `agent-browser` binary is shadowed by a boxa wrapper that auto-issues `connect 9222` against the **Agent-browser session bridge** on the first Chrome-bound call. You do not need to run `agent-browser connect 9222` yourself. Power-user invocations with global flags after the verb or uncommon options like `--state` may bypass auto-connect; in those cases run `agent-browser <global-flags> connect 9222` once.
- **Dev URLs bypass the proxy.** `localhost`, `*.test`, and `*.127.0.0.1.sslip.io` are on Chrome's `--proxy-bypass-list`, so they reach the Container directly without touching the **Agent-browser proxy**. External hosts go through the proxy, which is in **default mode** (REJECT all but the **Agent-browser allowlist** and the bypass list) unless an **Agent-browser network window** is open.

## Canonical references

- `CONTEXT.md` § Firewall, § Allow-for window, § SSH, § Agent-browser, § Project / container
- ADR 0001 — dnsmasq dynamic allowlist
- ADR 0007 — local DNS with external fallback
- ADR 0008 — HTTPS via mkcert (graceful degradation)
- ADR 0009 — Allow-for window
- ADR 0010 — Agent-browser host broker and proxy
- ADR 0011 — Boxa-aware agent context (this skill's design)
- ADR 0021 — Project-selected MCP catalog and agent-trusted execution
- ADR 0023 — Host connections via a durable scoped firewall slot
- ADR 0026 — opt-in SSH gate and Key picker
- ADR 0032 — per-installation Agent identity and Forge gate
- ADR 0037 — Container-owned Jobs replace `codex mcp-server`
- `docs/ssh.md` — complete **SSH gate**, **Key picker**, and **Boxa SSH config** guide
- `docs/forge.md` — complete **Agent identity**, **Forge store**, and **Forge gate** guide
- `docs/networking.md` — complete **Cross-boxa connection** and **Host connection** guide
- `docs/mcp.md` — complete MCP catalog, readiness, activation and trust guide
- `docs/jobs.md` — complete **Job** guide: commands, states, keys, ack, runtime snapshots, retention
- `boxa --help` (on host) for the full CLI surface

## Common failures

Short decision tree for the most-frequent symptoms.

- **`boxa: command not found`** inside a Container → the CLI is host-only. Ask the user to run it on the host.
- **`Could not resolve host` / `Connection refused` / hanging fetch** to an external internet host inside a Container → almost always an **Allowlist** miss. Ask the user to run `boxa allow <domain>` (durable) or `boxa allow-for <min>` (time-bounded).
- **Container traffic cannot reach a service on the host** → the remedy is a **Host connection**, not the Allowlist. Ask the user to run `boxa connect host <port> --name <label> [--all]` on the host, then use the persisted local address shown by `boxa connections` (`10.0.2.2:<local-port>` from inner Docker).
- **`git push` / `git pull` over SSH has no agent or identities** → check `boxa ssh` on the host. The **SSH gate** is off by default; use `boxa ssh on`, add or assign the intended keys to that Project agent, then recreate the Container as instructed. Network access remains a separate Allowlist or Host connection decision.
- **`gh` / `glab` is unauthenticated or uses a stale identity** → check `boxa forge` on the host. Enable the **Forge gate** with `boxa forge on`, store or rotate the credential with `boxa forge set github|gitlab`, and recreate the Container. Injected environment credentials win over persistent in-Container CLI login files; forge network access still requires the Allowlist.
- **`ERR_CONNECTION_REFUSED` against a dev URL** (`<port>.<project>.test` / `.sslip.io`) → the Container is not running, the dev server is not bound to that port, or it is bound to `127.0.0.1` instead of `0.0.0.0`. Check `boxa status` and `boxa ports <project>` on the host.
- **`ERR_TUNNEL_CONNECTION_FAILED` in Host agent Chrome** for an external host → the **Agent-browser proxy** denied it in **default mode**. Either add the host to the **Agent-browser allowlist** (`~/.config/boxa/agent-browser-allowed-domains.conf`) or open an **Agent-browser network window** with `boxa agent-browser allow-for <min> <project>`. Since the deny-visibility slice shipped, the in-container `agent-browser` wrapper also re-navigates Chrome to an inline `data:` URL that renders the same denial reason directly in the window, so you can read the blocked host and the recovery commands without digging through the proxy log.
- **Certificate warnings on a `*.test` or `*.sslip.io` URL** → mkcert root CA is not trusted in the current Chrome profile. Check ADR 0008 for graceful-degradation behaviour; the user may need to re-run `boxa dns-install`.
- **Stale agent-browser CLI behaviour** inside a Container (e.g., `connect 9222` errors after a host Chrome restart) → the auto-connect wrapper reconnects on Chrome restart since `f9e30fa`. If symptoms persist, ask the user to `boxa agent-browser stop <project> && boxa agent-browser start <project>`.
- **MCP catalog entry exists but the agent cannot see it** → catalog membership never activates a server. Start the target Project, check `boxa mcp readiness <entry> --project <path>`, then explicitly `activate` it for the intended consumer.
- **`mcp__boxa-<entry>` tools are missing from the agent session** → the entry is not activated for this Project (activation is per-Project; catalog membership alone exposes nothing). Ask the user to run on the host: `boxa mcp readiness <entry> --project <path>`, then `boxa mcp activate <entry> --project <path> --for claude`. A newly activated server appears only in a NEW agent session.
- **A `codex-delegate` MCP entry exists but never starts (`CONNECTION_CLOSED`)** → `codex mcp-server` no longer exists in current Codex (ADR 0037). Use `boxa-job start --codex` instead (§ Jobs), and ask the user to run `boxa mcp remove codex-delegate` on the host. `boxa doctor` reports the same thing.
- **Work is lost when a Bash call, a subagent, or a session ends** → run it as a **Job**. `boxa-job` owns the command's lifetime inside the Container; see § Jobs.
