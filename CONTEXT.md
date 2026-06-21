# Boxa

Boxa is a Linux-container development environment that runs each project
behind a default-deny outbound firewall. The container's outbound traffic is
restricted by domain, and host-side commands manage the firewall, the
shared resolver, and the optional HTTPS layer.

## Language

### Firewall

**Allowlist**:
The user-curated set of domains in `~/.config/boxa/allowed-domains.conf`
whose resolved IPs the firewall permits permanently.
_Avoid_: whitelist, ACL, rules

**Allowed-domains ipset**:
The Netfilter set named `allowed-domains` that dnsmasq populates at lookup
time from the **Allowlist**. Persistent across the container's lifetime.

**Default-deny**:
The baseline iptables policy: outbound traffic is `REJECT`ed unless its
destination IP is in an accepting ipset. The system's safety floor.

**DNS pinning**:
The iptables policy that restricts outbound DNS (port 53 UDP/TCP, port 853
DoT) to the in-container dnsmasq on `127.0.0.1`. Forces all name resolution
through the audited resolver.
_Avoid_: DNS lockdown, resolver enforcement

### Allow-for window

**Allow-for window**:
A time-bounded session, started by `boxa allow-for`, during which
**non-allowlist** domains are passively allowed and recorded. Ends
automatically after the configured duration (default 15 min).
_Avoid_: temporary allow, firewall open mode, harvest mode

**Harvest pool**:
The ephemeral Netfilter set named `harvest-pool`, populated by dnsmasq's
catch-all `ipset=//harvest-pool` directive during an active **Allow-for
window**. Destroyed at window teardown.
_Avoid_: catch-all ipset, ephemeral allowlist

**Harvest log**:
A per-run, tamper-proof plain-text file written at window teardown to
`/var/log/boxa/allow-for/<container>-<timestamp>.log`. Contains the
unique set of domains queried during the window that were not covered by
the **Allowlist**.
_Avoid_: audit log, harvest report, capture file

**Sentinel state**:
The root-owned file inside the container (`/etc/boxa-shared/.allow-for.state`)
recording the active window's `started_at`, `expires_at`, and daemon PID.
Source of truth for status queries.

**Closeout notification**:
The desktop notification the host-side deliver script raises when an
**Allow-for window** or an **Agent-browser session**/**network window**
closes. Carries a click action that opens the run's log (the **Harvest
log** or the agent-browser summary/proxy log). The notification is a
convenience pointer; the log file on disk is the canonical record and is
always written even if no notification backend is available. The click
action is platform-native: a protocol-activated toast on WSL2, a
`notify-send` default action on Linux, none on macOS.
_Avoid_: toast (Windows-specific), popup, alert

### Agent-browser

**Agent-browser session**:
A long-lived host-side state, started by `boxa agent-browser start
<project>` and ended by `... stop`. While active, exactly one **Host
agent Chrome** runs on the host and exactly one **Container** can reach
its CDP endpoint through an in-container bridge socket. Closes on
explicit `stop`, idle timeout (`AGENT_BROWSER_IDLE_TIMEOUT_MS`), or
container teardown.
_Avoid_: chrome session, browser bridge

**Host agent Chrome**:
The dedicated Chrome instance launched on the host by the **Agent-browser
session** broker. Runs as a distinct OS user (`boxa-agent` on all
three platforms), with an ephemeral `--user-data-dir`, hardened launch
flags (no extensions, no native messaging, no sync, no `file://`
access), and `--log-net-log=<path>`. Binds CDP on the host's loopback
(`127.0.0.1:<random-port>`) — never on a routable interface. All
outbound HTTP/HTTPS is forced through the **Agent-browser proxy** via
`--proxy-server`.
_Avoid_: personal Chrome, shared Chrome

**Agent-browser session bridge**:
The per-session socat process running inside the outer **Container**'s
network namespace, forwarding `127.0.0.1:9222` (inside the container)
to `host.docker.internal:<random-port>` (the **Host agent Chrome**'s
CDP). The container's network namespace is the security boundary: no
other container or process can see this socket. socat is the
transport, not the gate.
_Avoid_: cdp tunnel, browser forwarder

**Agent-browser network window**:
A time-bounded sub-state of an **Agent-browser session**, started by
`boxa agent-browser allow-for <minutes>`. While open, the
**Agent-browser proxy** is in **harvest mode**: any host the browser
contacts is allowed and logged, paralleling the firewall **Allow-for
window**. Outside this sub-window, the proxy denies everything not in
the **Agent-browser allowlist** or the local-dev bypass list.
_Avoid_: browser allow-for, agent allow-for

**Agent-browser proxy**:
The host-side HTTP forward proxy daemon, run by `boxa-agent`, that
gates all of **Host agent Chrome**'s outbound traffic. Reloadable via
SIGHUP. Has two modes:
- **default mode** — REJECT everything except the **Agent-browser
  allowlist** and the bypass list (`localhost`, `*.test`,
  `*.127.0.0.1.sslip.io`)
- **harvest mode** — ALLOW + LOG every CONNECT/GET, time-bounded by
  the active **Agent-browser network window**
_Avoid_: agent proxy, browser proxy

**Agent-browser allowlist**:
The set of domain patterns in
`~/.config/boxa/agent-browser-allowed-domains.conf`, distinct from
the firewall **Allowlist**. Enforced at two points:
1. **Agent-browser proxy** (network gate — CONNECT/GET host check)
2. agent-browser's native `--allowed-domains` flag (page-level
   navigation gate — a structured error reaches the agent on denial,
   useful for LLM feedback)
Read at session start, propagated into the **Container** via
`AGENT_BROWSER_ALLOWED_DOMAINS`.
_Avoid_: browser allowlist, navigation allowlist

**Netlog**:
The Chrome-native `--log-net-log=` JSON file written by **Host agent
Chrome** for the lifetime of a session. Archived at session teardown
to `/var/log/boxa/agent-browser/<container>-<timestamp>.netlog.json`
and summarized into a human-readable `summary.md` (visited hosts,
out-of-allowlist requests, downloads, suspicious flags).
_Avoid_: chrome log, browser audit

### MCP

**MCP server**:
A tool provider that exposes capabilities to an agent over the Model
Context Protocol.

**Container MCP server**:
An **MCP server** that runs inside the **Container**. The default choice
for project-file, repository, build, and test capabilities because it
inherits the **Container**'s filesystem boundary and **default-deny**
network posture.
_Avoid_: local MCP server

**Host MCP server**:
An **MCP server** that runs on the host. Reserved for capabilities that
must see host OS state, desktop state, host credentials, dotfiles, WSL2
boundaries, Windows APIs, or other resources the **Container** should not
see directly.
_Avoid_: external MCP server, outside MCP server

**MCP profile**:
The selected set of **MCP servers** exposed to agents for a **Project**.
The effective profile combines user-wide MCP choices with Project-specific
choices.
_Avoid_: MCP config, MCP preset

**Inherited MCP server**:
An **MCP server** discovered from an existing agent configuration that was
not created by boxa. It can be proposed for a **MCP profile**, but is not
trusted as boxa-managed merely because its configuration is visible inside
the **Container**.
_Avoid_: existing MCP server, user MCP server

**Boxa MCP server**:
An **MCP server** that boxa has explicitly added to a **MCP profile**.
_Avoid_: managed MCP server

**MCP broker**:
A long-running process, run as the **boxa-mcp** account, that spawns
**Container MCP servers** on demand and injects their credentials. Started by
the entrypoint root phase before the privilege drop, so the agent cannot launch
or read it. See ADR 0014.

**MCP relay**:
The `boxa-mcp-run` command rendered into agent config. Runs as the agent user,
connects to the **MCP broker**'s socket, and proxies stdio for one server; it
never sees credential values.
_Avoid_: MCP wrapper (the rendered command relays to the broker; it no longer
launches the server directly)

**boxa-mcp**:
The unprivileged Container service account that runs **Container MCP servers**
and is the only non-root identity allowed to read the **MCP secret store**.
Distinct from the agent user (`node`), but a **peer-equal citizen** of it: a full,
sudo-less Container user with the same practical reach (workspace read/write,
rootless Docker) as the agent. The only asymmetry is privacy — `node` cannot read
its secrets, and neither account sees the other's private files. See ADR 0014.
_Avoid_: MCP user, mcp-runner

**boxa-bridge**:
A Container-internal group whose members are both `node` and **boxa-mcp**, used
to share only the runtime sockets (the **MCP broker** socket and the rootless
Docker socket) between the two accounts. It exists only inside the **Container**
(never on the host) and replaces the earlier `node`-in-`boxa-mcp` cross-membership,
so neither account belongs to the other's primary group. The workspace is shared
separately via an idmapped mount, not via this group. See ADR 0014.
_Avoid_: mcp group, shared group

**MCP secret store**:
The credential values for **MCP servers**, kept host-side and delivered to the
**MCP broker** only — never readable by the agent user inside the **Container**.
The **MCP profile** is secret-free and references these by name.
_Avoid_: MCP credentials file, secrets config

### Project / container

**Project**:
A user codebase mounted into a boxa container. Identified by the
sanitized basename of its host path (see ADR 0005).

**Container**:
The Docker container `boxa-<project>` that runs the project's dev
environment. Each project gets exactly one container at a time.

**Container identity**:
A root-owned JSON file at `/etc/boxa/identity.json` inside the
**Container**, written by the entrypoint, recording the active
**Project** name. Its mere presence is the deterministic signal "we
are inside a boxa container"; absence means "we are on the host".
Consumed by agent-side hooks and the `boxa` skill for host/container
branching. See ADR 0011.
_Avoid_: identity sentinel, container marker, boxa marker file

### Host provisioning

**Provisioning step**:
A single idempotent unit of host-side setup, represented by an
`ensure-<concern>.sh` script. The same step is shared across all three
entry points — `install.sh`, `boxa update`, and `boxa doctor` — so
the host's provisioned state can never diverge between a fresh install
and an upgrade. The registry of steps is the single source of truth.
_Avoid_: self-heal (describes only update's behaviour), setup task

**Unconditional step**:
A **Provisioning step** that is always performed because it is cheap,
idempotent, and has no downside (e.g. the `boxa` symlink, shell
completions, the boxa agent skill, the mkcert binary). `boxa doctor`
and `boxa update` both bring it forward silently.
_Avoid_: mandatory step, core step

**Elective step**:
A **Provisioning step** gated on a past user choice — a prompt with an
opt-out or seen/dismissed marker (e.g. the HTTPS upgrade, MCP onboarding,
the Claude token). Because the user may have deliberately declined it,
`boxa doctor` only *reports* it; it is repaired only under an explicit
`boxa doctor --fix`.
_Avoid_: optional step, prompt step

**Environment prerequisite**:
An external precondition boxa cannot reliably repair on its own — it
needs a re-login, a package manager, or a running daemon (e.g. the Docker
daemon being up, the user's Docker group membership taking effect, a
missing `git`). `boxa doctor` diagnoses it and prints the exact command
to run, but never mutates it silently.
_Avoid_: system check, prereq

**Doctor**:
`boxa doctor` — the entry point that runs the whole **Provisioning
step** registry independently of any repo change. By default it repairs
every **Unconditional step**, reports every missing **Elective step** and
**Environment prerequisite**, and asks for sudo only at the moment a step
needs it. `--fix` additionally repairs **Elective steps** (all of them,
or named ones via `--fix <step>`).
_Avoid_: boxa check, boxa repair, boxa heal

## Relationships

- A **Project** has exactly one **Container** at a time.
- An **Allowlist** is shared across all of a user's **Containers**
  (bind-mounted `:ro` from `~/.config/boxa/allowed-domains.conf`).
- An **Allow-for window** runs in exactly one **Container** at a time;
  starting a second window in the same container *resets the clock* (does
  not stack).
- An **Allow-for window** has exactly one **Harvest pool** for its lifetime
  and produces exactly one **Harvest log** at teardown.
- A domain added via `boxa allow` during an active window joins the
  **Allowlist** permanently; the **Harvest pool** keeps it (harmlessly
  redundant) until window teardown.
- An **Agent-browser session** runs in exactly one **Container** at a
  time and is bound to exactly one **Host agent Chrome** and exactly
  one **Agent-browser session bridge** for its lifetime; all three die
  together at session teardown.
- An **Agent-browser session** can contain at most one active
  **Agent-browser network window**. Starting a second `allow-for`
  during an active window *resets the clock* (parallel to the firewall
  **Allow-for window**).
- The **Agent-browser allowlist** is shared across all of a user's
  **Containers**, like the firewall **Allowlist**, but its enforcement
  points are the **Agent-browser proxy** (network) and agent-browser
  CLI (page navigation), not the firewall.
- The **Agent-browser proxy** is the single network exit point for
  **Host agent Chrome**. Chrome cannot reach the internet by any other
  path; the `--proxy-server` flag is non-negotiable.
- A **Project** has one effective **MCP profile** at a time. It is formed
  from the user's global MCP choices plus the Project's MCP choices; the
  Project can explicitly disable a global choice when that capability is
  unsafe or too noisy for the Project.
- An **Inherited MCP server** is not automatically a **Boxa MCP server**.
  Boxa first classifies it and proposes how it should enter the **MCP
  profile**.
- The **MCP broker** runs **Container MCP servers** as **boxa-mcp**; the
  agent reaches them only through an **MCP relay**, so credentials in the **MCP
  secret store** never enter the agent user's reach (ADR 0014).
- The **MCP profile** is delivered into the **Container** live (read-only mount);
  the **MCP secret store** is staged privately for **boxa-mcp** and refreshed
  into a running **Container** by `boxa mcp reload`, not by a restart.
- **boxa-mcp** and `node` are peer-equal: they share only the runtime sockets
  (via the **boxa-bridge** group) and the workspace (via an idmapped mount);
  everything else stays private to each account. None of this sharing touches the
  host — the bridge group lives only in the **Container** and the idmapped mount
  leaves host file ownership/permissions unchanged (ADR 0014).
- Every **Provisioning step** is reachable from all three entry points
  (`install.sh`, `boxa update`, `boxa doctor`); none of the three owns
  steps the others cannot run. This is what keeps a fresh install and an
  upgraded one in the same provisioned state.
- `boxa update` runs the full set of **Unconditional steps** on every
  invocation (even when the repo is already up to date); only migrations
  and the image rebuild stay gated behind an actual `git pull` change.

## Example dialogue

> **Dev:** "I'm about to let an LLM agent run a research task in `myapp`.
> Can I just open the firewall for 30 minutes?"
>
> **Maintainer:** "Don't open the firewall — start an **Allow-for window**.
> Run `boxa allow-for 30` in the project. The window stays in
> **default-deny** mode for everything the **Allowlist** doesn't cover, but
> any domain the agent queries through the resolver lands in the **Harvest
> pool** and gets through for the rest of the window. When the window
> closes, you get a clickable **Closeout notification** plus a **Harvest
> log** listing every non-allowlist domain. Click the notification and it
> opens the log straight away — on WSL2, on Omarchy, on plain Ubuntu, same
> gesture. Hardcoded-IP traffic stays blocked the whole time, thanks to
> **DNS pinning**."

## Flagged ambiguities

- "Harvest mode" and "temporary allow" were both used informally for the
  **Allow-for window**. Resolved: canonical term is **Allow-for window**.
- "Catch-all ipset" was used interchangeably with **Harvest pool**.
  Resolved: prefer **Harvest pool** for the named concept; "catch-all"
  describes only the dnsmasq directive that populates it.
- "Toast" was used as the generic name for the closeout popup, but it is
  a Windows-specific term and the click behaviour now exists on Linux too.
  Resolved: canonical term is **Closeout notification**; "toast" refers
  only to the WSL2 backend's concrete rendering.
