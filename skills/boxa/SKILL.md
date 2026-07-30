---
name: boxa
description: Boxa dev environment guide — invoke when the user mentions the boxa CLI, boxa Containers, MCP catalog or MCP activation, trusted MCP execution, dev URLs (*.test, *.sslip.io), Allow-for windows, the Allowlist, Agent-browser session lifecycle, ports, mkcert HTTPS, Container identity, or anything about why network/host behaviour differs from a plain shell.
user-invocable: false
---

# Boxa

Boxa runs each Project in a Linux Container behind a default-deny outbound firewall. The `boxa` CLI lives on the host and manages Containers, the **Allowlist**, **Allow-for windows**, **Host connections**, **Agent-browser sessions**, ports, and the mkcert HTTPS layer. See `CONTEXT.md` for the canonical glossary and `docs/adr/` for design rationale.

## Identity check (run first)

```sh
test -f /etc/boxa/identity.json && jq -r .project /etc/boxa/identity.json
```

- Empty / file missing → you are on the **host**. See § On host.
- Non-empty (a project name) → you are inside a boxa **Container** for that **Project**. See § Inside container.

The file is the canonical **Container identity** (CONTEXT.md § Project / container, ADR 0011). Its mere presence is the deterministic signal.

## Inside container

You are inside a Container. Respect these boundaries:

1. **The `boxa` CLI is host-only.** It does not exist in the Container PATH. To start/stop Containers, manage the **Allowlist**, open **Allow-for windows**, create or remove **Host connections**, or orchestrate **Agent-browser sessions**, ask the user to run the corresponding `boxa …` command on the host.
2. **Network is default-deny against the Allowlist.** Roughly fifteen domains resolve; everything else is `REJECT`ed by the firewall. **DNS pinning** forces all name resolution through the in-Container dnsmasq, so hardcoded-IP fetches fail too. See ADR 0001, ADR 0007.
3. **Container-to-host services use a Host connection.** The Allowlist is a domain gate and does not grant traffic to a host service. Ask the user to run `boxa connect host <port> --name <label> [--all]` on the host. Omit `--all` for the current box; include it only when every present and future box should be trusted. See ADR 0023.
4. **Dev URLs bypass the firewall.** `http(s)://<port>.<project>.test` and `http(s)://<port>.<project>.127.0.0.1.sslip.io` resolve locally and never hit the **Allowlist** gate. See ADR 0007.

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

Run all `boxa mcp ...` commands on the host. When operating inside a Container, inspect local prerequisites if useful, then give the user the exact host commands.

#### Delegate from Claude to trusted Codex

Use this host flow when Claude should call Codex directly as an MCP server:

```sh
cd /path/to/my-project
boxa up
boxa mcp add codex-delegate -- codex mcp-server
boxa mcp mode codex-delegate agent-trusted
boxa mcp readiness codex-delegate --project "$PWD"
boxa mcp activate codex-delegate --project "$PWD" --for claude
boxa mcp status --project "$PWD"
```

Do not invent a path or API key for `codex-delegate`: the label does not resolve software. The Container image already provides `codex`; the argv after `--` selects its `mcp-server` mode. Readiness checks the mounted `node` user's existing `codex login`, including ChatGPT subscription login.

`agent-trusted` is a host-confirmed grant for the stable catalog identity. It gives the server the same `node`-user repository, mounted private-state, SSH, and Docker access as the agent that launches it, while excluding ambient bearer tokens and Boxa MCP-store secrets. Review the command/access preview before confirming. Boxa refuses Codex self-activation; select Claude only.

To enable the prepared server in another Project, do not add or trust it again:

```sh
cd /path/to/other-project
boxa up
boxa mcp activate codex-delegate --project "$PWD" --for claude
```

Use `boxa mcp catalog`, `readiness`, `status`, and `doctor` to explain each state. `boxa mcp --help` is the complete user-facing workflow; when working in the Boxa repository, consult `docs/mcp.md` for design detail.

## Agent-browser

Boxa-specific integration glue only. For the upstream CLI surface (navigation, screenshots, network inspection, the two-gate model in detail), defer to the upstream `agent-browser` skill (installed alongside this one). For architecture, see ADR 0010.

Three boxa-specific facts:

- **Lifecycle is host-only.** Inside a Container you cannot start, stop, or open a network window — those are `boxa agent-browser …` commands on the host. Ask the user.
- **The auto-connect wrapper handles CDP.** Since commit `f9e30fa`, the in-Container `agent-browser` binary is shadowed by a boxa wrapper that auto-issues `connect 9222` against the **Agent-browser session bridge** on the first Chrome-bound call. You do not need to run `agent-browser connect 9222` yourself. Power-user invocations with global flags after the verb or uncommon options like `--state` may bypass auto-connect; in those cases run `agent-browser <global-flags> connect 9222` once.
- **Dev URLs bypass the proxy.** `localhost`, `*.test`, and `*.127.0.0.1.sslip.io` are on Chrome's `--proxy-bypass-list`, so they reach the Container directly without touching the **Agent-browser proxy**. External hosts go through the proxy, which is in **default mode** (REJECT all but the **Agent-browser allowlist** and the bypass list) unless an **Agent-browser network window** is open.

## Canonical references

- `CONTEXT.md` § Firewall, § Allow-for window, § Agent-browser, § Project / container
- ADR 0001 — dnsmasq dynamic allowlist
- ADR 0007 — local DNS with external fallback
- ADR 0008 — HTTPS via mkcert (graceful degradation)
- ADR 0009 — Allow-for window
- ADR 0010 — Agent-browser host broker and proxy
- ADR 0011 — Boxa-aware agent context (this skill's design)
- ADR 0021 — Project-selected MCP catalog and agent-trusted execution
- ADR 0023 — Host connections via a durable scoped firewall slot
- `docs/networking.md` — complete **Cross-boxa connection** and **Host connection** guide
- `docs/mcp.md` — complete MCP catalog, readiness, activation and trust guide
- `boxa --help` (on host) for the full CLI surface

## Common failures

Short decision tree for the most-frequent symptoms.

- **`boxa: command not found`** inside a Container → the CLI is host-only. Ask the user to run it on the host.
- **`Could not resolve host` / `Connection refused` / hanging fetch** to an external internet host inside a Container → almost always an **Allowlist** miss. Ask the user to run `boxa allow <domain>` (durable) or `boxa allow-for <min>` (time-bounded).
- **Container traffic cannot reach a service on the host** → the remedy is a **Host connection**, not the Allowlist. Ask the user to run `boxa connect host <port> --name <label> [--all]` on the host, then use the persisted local address shown by `boxa connections` (`10.0.2.2:<local-port>` from inner Docker).
- **`ERR_CONNECTION_REFUSED` against a dev URL** (`<port>.<project>.test` / `.sslip.io`) → the Container is not running, the dev server is not bound to that port, or it is bound to `127.0.0.1` instead of `0.0.0.0`. Check `boxa status` and `boxa ports <project>` on the host.
- **`ERR_TUNNEL_CONNECTION_FAILED` in Host agent Chrome** for an external host → the **Agent-browser proxy** denied it in **default mode**. Either add the host to the **Agent-browser allowlist** (`~/.config/boxa/agent-browser-allowed-domains.conf`) or open an **Agent-browser network window** with `boxa agent-browser allow-for <min> <project>`. Since the deny-visibility slice shipped, the in-container `agent-browser` wrapper also re-navigates Chrome to an inline `data:` URL that renders the same denial reason directly in the window, so you can read the blocked host and the recovery commands without digging through the proxy log.
- **Certificate warnings on a `*.test` or `*.sslip.io` URL** → mkcert root CA is not trusted in the current Chrome profile. Check ADR 0008 for graceful-degradation behaviour; the user may need to re-run `boxa dns-install`.
- **Stale agent-browser CLI behaviour** inside a Container (e.g., `connect 9222` errors after a host Chrome restart) → the auto-connect wrapper reconnects on Chrome restart since `f9e30fa`. If symptoms persist, ask the user to `boxa agent-browser stop <project> && boxa agent-browser start <project>`.
- **MCP catalog entry exists but the agent cannot see it** → catalog membership never activates a server. Start the target Project, check `boxa mcp readiness <entry> --project <path>`, then explicitly `activate` it for the intended consumer.
- **`codex-delegate` cannot be found as a binary** → it is only the catalog label. The executable comes from the command after `--` (`codex mcp-server`); verify the Project is running and use `boxa mcp readiness codex-delegate --project <path>`.
