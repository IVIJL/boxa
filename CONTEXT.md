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
closes, or that reports the outcome of an unattended `boxa stop --all
--reason` run. For a window or session closeout, it carries a click action that opens the run's log (the
**Harvest log** or the agent-browser summary/proxy log). The notification is a
convenience pointer; that log file is the canonical record and is always
written even if no notification backend is available. The click action is
platform-native: a protocol-activated toast on WSL2, a `notify-send` default
action on Linux, none on macOS.
_Avoid_: toast (Windows-specific), popup, alert

### Keep-awake

**Keep-awake daemon**:
The host-side process that holds the operating system awake while coding
agents work and owns **Awake leases**.
_Avoid_: host daemon, awake daemon, sleep blocker

**Awake lease**:
A TTL-bounded busy claim, identified by agent and session, that an agent holds
through the keep-awake HTTP API while it is working.
_Avoid_: live lease, keep-awake claim, inhibitor lease

**Activity hook**:
The Claude hook that translates agent activity into **Awake lease** signals.
On Stop, its shell-aware behaviour keeps the lease busy while a background
shell is still running and otherwise releases it.
_Avoid_: agent-awake hook, keep-awake hook

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

### Connections

**Box-to-box visibility**:
The default direct reachability between outer **Containers** on the shared
`devproxy` network. There is no firewall isolation between boxes and no
**Connection** is needed: use `boxa-<name>:<port>` directly, or a dev URL via
Traefik. Inner DinD containers are not on `devproxy`; they use a
**Cross-boxa connection** instead. See ADR 0027.
_Avoid_: implicit connection, box trust grant, isolated box network

**Cross-boxa connection**:
A managed TCP forward owned by a source **Container**, giving its
processes and inner DinD containers a stable local address
(`127.0.0.1:<local-port>`, from inner containers `10.0.2.2:<local-port>`)
for a published service in another box. Persisted per source box and
replayed on Container start; inspectable via `boxa connections`. See
ADR 0019.
_Avoid_: box link, box tunnel, port forward (ambiguous)

**Host connection**:
A **Cross-boxa connection** whose target is a service on the host
instead of another box. Alongside the forward it carries a scoped
firewall exception — a single-IP, single-port accept inside the
**Container**, plus on native Docker an equally scoped host-side slot —
that is re-established on every Container start and removed only by
explicit removal or uninstall. The default local port mirrors the host
port; fallbacks are chosen deterministically once, at creation time.
On native Linux this means a standing, narrowly scoped host firewall
rule that exists exactly as long as the Host connection entry does.
Scope is one box by default, or every box for host services that any
Container may signal. The exception is host-managed end to end: nothing
inside the Container can create, widen, or remove it.
_Avoid_: host-service, host relay, host hole, host forward

### SSH

**SSH gate**:
The opt-in gate controlling whether the host's SSH agent socket is
forwarded into a **Container**. Off by default; enabled globally or per
**Project** (`boxa ssh on`, durable in `~/.config/boxa/ssh.conf`).
Governs only the agent socket — the signing capability — not the
**Boxa SSH config** mount. Takes effect at Container creation.
_Avoid_: ssh forwarding flag, agent mount, ssh sharing

**Boxa SSH config**:
The user-curated host aliases file `~/.config/boxa/ssh_config`
(`boxa ssh-config`), mounted read-only into every Container regardless
of the **SSH gate**. Carries addresses and usernames only — never key
material or signing capability.
_Avoid_: ssh config mount, host ssh config (that is the `--ssh-config` flag)

**Key picker**:
The consent-first interactive flow in `boxa ssh on` / `boxa ssh add`
that offers host keys for `ssh-add`: asks before listing `~/.ssh`,
discovers candidates by filename only (never reading private key
material), lets the user multi-select or type a path, and warns when a
selected key turns out to be passphrase-less. The only way boxa ever
causes a key to enter the agent.
_Avoid_: key scanner, key importer, auto-add

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

**MCP catalog**:
The user-wide set of prepared **Container MCP server** definitions available for
explicit activation in any **Project**. Catalog membership never exposes or
starts a server by itself.
_Avoid_: global MCP profile, global MCP servers

The catalog and host-owned activations survive host restart, Boxa stop, and
Container recreation. Installed npm and Docker runtimes use the Project's
persistent runtime state; the secret-free runtime snapshot is a derived
repairable artifact. Moving or cloning a Project changes its **Project key**
and therefore does not carry activations to the new path.

**MCP catalog entry**:
A durable server definition in the **MCP catalog**, with an identity independent
of its user-facing name. Updates and renames preserve that identity and its
**MCP execution mode**; removal destroys both, and a later same-named entry is
new. Cosmetic metadata may change independently. A runtime-affecting update of
an active entry is atomic: every activated Project must be running and pass
readiness for the new definition before the catalog and rendered agent configs
change. Removal also deletes every **MCP activation** that references the entry.
_Avoid_: global server, catalog name

**MCP readiness**:
Whether an **MCP catalog entry** has the runtime and prerequisites needed to
start successfully for a target **Project**. It is a deterministic local check,
not a live assertion about an external service, and it never executes the
server itself. An activation is effective only after readiness passes: for a
local entry that requires the target Boxa to be running, and a **Pending
activation** re-evaluates at Container start; a **Remote MCP catalog entry**
has no runtime readiness. Activation never starts a Boxa implicitly.
_Avoid_: installed status, enabled status

**MCP activation**:
The user's explicit choice to expose one **MCP catalog entry** to agents in one
**Project**. It is the durable source of truth and doubles as the user's
consent; no second approval step exists downstream. A plain activation never
carries over to another Project; only an **Everywhere entry** does. It becomes
effective once **MCP readiness** passes; recorded against a stopped Boxa it
stays a **Pending activation** until then. Consumer selection may differ
between agents in the same Project. Activations reach sessions only through the
**Agent launch wrapper** inside the **Container**; Boxa never writes them into
project or user agent configuration files.
Removing an activation prevents new connections but does not terminate an
already connected server process.
_Avoid_: global enable, inherited MCP

**MCP profile**:
The set of **MCP activations** currently selected for one **Project**. A fresh
Project has an empty profile until the user makes a selection. A Container
session sees exactly the profile: no inherited, project-file, or user-scope
servers ever reach it, and no profile server ever reaches a host session.
_Avoid_: MCP config, MCP preset, effective global profile

**Remote MCP catalog entry**:
An **MCP catalog entry** that points agents at an MCP server over HTTP(S)
instead of a Container-spawned process. It has no **MCP execution mode** and no
runtime readiness; its gate is the Allowlist, which must admit the server's
domain for sessions to reach it.
_Avoid_: hosted connector, remote connector entry

**Everywhere entry**:
An **MCP catalog entry** the user marked to activate in every present and
future **Project**: the only form of activation that carries between Projects.
A per-Project deactivation is sticky and always wins over the mark.
_Avoid_: user-scope server, global activation

**Pending activation**:
An **MCP activation** recorded while its **MCP readiness** cannot yet pass,
typically because the target Boxa is stopped. Sessions never see it; readiness
re-evaluates at the next Container start, and failure keeps it pending and
reported.
_Avoid_: queued activation, deferred activation

**Agent launch wrapper**:
The Container-only wrapper occupying an agent CLI's canonical binary path. On
every invocation it derives the Project's **MCP profile** from the read-only
runtime snapshot and injects it as the session's complete MCP configuration,
resolving the agent binary version at the same moment. An unreadable snapshot
degrades the session to no MCP with a warning, never a blocked start.
_Avoid_: shim, PATH alias, agent alias

**Inherited MCP server**:
An **MCP server** discovered from an existing agent configuration that was
not created by boxa. Container sessions never see it; the only path into the
**Container** is proposal into the **MCP catalog** and explicit activation.
Discovery classifies it heuristically and never by executing it. A candidate
matching an already-cataloged entry is offered for **Reimport** when its host
definition differs from the entry, and reported as in sync otherwise.
_Avoid_: existing MCP server, user MCP server

**Reimport**:
Taking host-side changes of an already-cataloged **Inherited MCP server**
back into its **MCP catalog** entry. The host definition wins for the fields
it carries; boxa-only state (name, activations, trust, mode) is untouched,
and credential values move only with per-value consent (ADR 0031).
_Avoid_: resync, re-sync, re-import command

**Boxa MCP server**:
An **MCP server** represented by an **MCP catalog entry**.
_Avoid_: managed MCP server

**MCP execution mode**:
The catalog-defined identity boundary for a **Container MCP server**. It is
either `service-isolated` or `agent-trusted`; user-facing output also names the
concrete Container account used by the selected mode. The mode cannot change
while the server has any **MCP activation**.
_Avoid_: trust boolean, trust level, run-as flag

**Service-isolated MCP server**:
The default **Container MCP server**, running as **boxa-mcp** with full Project
capabilities but without access to the agent user's private files, credentials,
process identity, or raw rootless Docker socket. Docker-packaged servers are
started through the **MCP Docker launch adapter**, which does not mount that
socket into them. This isolation is from the agent, not from other
service-isolated servers, which remain one credential trust domain. A temporary
exception applies to secrets injected into a Docker-packaged server: because
the daemon is owned by `node`, the agent user can inspect its container
environment. This degraded guarantee is reported by MCP status and doctor; its
first activation requires explicit acknowledgement, including a dedicated flag
for non-interactive use. It remains visible until Docker execution and
per-server credentials gain a stronger boundary.
_Avoid_: untrusted MCP server, restricted MCP server

**Agent-trusted MCP server**:
A **Container MCP server** whose **MCP catalog** definition the user has
explicitly authorized to share the agent user's identity and private
filesystem/socket context, but not the agent process's ambient environment. It
starts from a deterministic agent-user baseline: fixed home, XDG, executable
path, and known Docker/SSH socket locations when present, plus only explicitly
declared non-secret catalog environment. It does not inherit arbitrary session
variables or bearer tokens from the launching agent process. The identity
applies wherever that definition is activated; a Project chooses only
whether to activate it, not which identity it uses. The agent can use this
authorization but cannot grant it through the boxa-managed MCP path, and
discovery never infers it. This authorization does not constrain commands the
agent runs independently as its own user. It has the same Project access as a
**Service-isolated MCP server** plus the agent user's raw Docker capability; the
additional trust crosses the agent identity and private-state boundary, not the
Project boundary. It uses credentials already available in the agent user's
private context and never
receives values from the **MCP secret store**. An entry cannot use this mode
while it declares secret environment keys or retains values in that store.
The CLI mode is always `agent-trusted`; “node-trusted access boundary” may
describe the concrete fact that it runs as Container user `node`, but is not a
second mode name.
_Avoid_: node-trusted MCP server, trusted MCP server, full-access MCP server

**MCP broker**:
A long-running process, run as the **boxa-mcp** account, that authorizes
**Container MCP server** launches against the active **MCP profile**. It spawns
**Service-isolated MCP servers** and supplies the **Boxa MCP launcher** with an
authorization proposal for **Agent-trusted MCP servers**. Because the broker
shares its UID with Service-isolated children, the proposal is not itself a
trust root: the launcher independently validates it against the secret-free,
host-owned MCP runtime snapshot mounted read-only at a node-readable path. See
ADR 0014 and ADR 0021.

**Boxa MCP launcher**:
The `boxa-mcp-run` command the **Agent launch wrapper** injects into a
session's MCP configuration. It runs as the agent user
and asks the **MCP broker** to authorize one server against the effective **MCP
profile**. It relays stdio to a broker-spawned **Service-isolated MCP server** or
launches an authorized **Agent-trusted MCP server** as the agent user. Before an
Agent-trusted launch it independently binds stable catalog identity, exact
Project activation, consumer, mode, command, declared non-secret environment,
working directory, and fixed socket pointers against the host-owned read-only
runtime snapshot; a forged or replaced broker socket cannot expand that
authority.
_Avoid_: MCP relay, MCP wrapper

**MCP Docker launch adapter**:
The constrained node-side path used to start a Docker-packaged
**Service-isolated MCP server** through the agent user's rootless daemon. It
allows the catalog-declared image, Project mount, environment, and stdio but
does not expose the raw Docker socket to the server. Because `node` owns the
daemon, secrets injected into such a container are inspectable by the agent;
this is an explicit temporary limitation, not part of the normal secret-store
guarantee.
_Avoid_: Docker proxy, Docker sandbox

**boxa-mcp**:
The unprivileged Container service account that runs **Service-isolated MCP
servers** and is the only non-root identity allowed to read the **MCP secret store**.
Distinct from the agent user (`node`), it is a full, sudo-less Container user
with the same workspace read/write reach. It does not
receive the agent user's raw Docker socket; Docker-packaged servers use the
**MCP Docker launch adapter**. See ADR 0014 and its superseding decisions.
_Avoid_: MCP user, mcp-runner, peer-equal citizen

**boxa-bridge**:
A Container-internal group whose members are both `node` and **boxa-mcp**, used
to share Boxa control-plane runtime sockets such as the **MCP broker** socket
between the two accounts. It does not grant a **Service-isolated MCP server**
the agent user's raw Docker socket. It exists only inside the **Container**
(never on the host) and replaces the earlier `node`-in-`boxa-mcp` cross-membership,
so neither account belongs to the other's primary group. The workspace is shared
separately via an idmapped mount, not via this group. See ADR 0014.
_Avoid_: mcp group, shared group

**MCP secret store**:
The credential values for **MCP servers**, kept host-side and delivered to the
**MCP broker** only. For directly spawned **Service-isolated MCP servers** they
are not readable by the agent user inside the **Container**. Secrets injected
into a Docker-packaged server are a documented temporary exception because
`node` owns and can inspect the rootless daemon's containers. The **MCP profile**
is secret-free and references values by name.
_Avoid_: MCP credentials file, secrets config

### Project / container

**Project**:
A user codebase mounted into a boxa container. Identified by the
sanitized basename of its host path (see ADR 0005).

**Project key**:
The normalized absolute host path of a **Project**. MCP activations use it to
distinguish Projects whose sanitized basenames collide. Moving or cloning a
Project produces a different key and does not inherit activations.
_Avoid_: Project UUID, stable Project ID

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

**Hook source mount**:
A read-only bind mount of a host file that a Claude/Codex hook `source`s
from outside the shared `~/.claude` / `~/.codex` trees (typically a
machine-local credentials env file). Discovered by static resolution of
the hook's source statements and created only after a per-path approval
persisted in `~/.config/boxa/hook-mounts.conf` — host-side state no
container can write, because the shared trees themselves are
agent-writable. Notification hooks are user-brought (boxa seeds none and
hardwires no service); this mount is how their config files reach
containers. See ADR 0025.
_Avoid_: hook env mount, secret mount, hook config mount

### Dev URLs

**DNS degradation**:
The state in which the local `.test` resolution path is systemically
impossible on the host — an unmet **Environment prerequisite** such as
WSL mirrored networking reserving port 53 — and boxa automatically
serves dev URLs on the external domain instead, keeping the local
preference sticky. Entered and healed solely by probing the actual
resolution path, loudly announced on every Container start while
active. `.test` keeps resolving inside **Containers** throughout.
The in-box dnsmasq answers both dev URL suffixes with Traefik's IP, obtained
through Docker embedded DNS at `127.0.0.11`; it does not query `boxa_dns`.
See ADR 0024 and ADR 0027.
_Avoid_: external-only mode, sslip mode, broken DNS, unsupported mode

### Memory

**Memory limit**:
The hard ceiling on a **Project**'s RAM use, enforced on its outer
**Container** so that every process inside — agent subprocesses and
nested DinD containers alike — counts against it. When it is reached,
the kernel kills a victim process it selects inside the Container
(observed: the largest one); the Container itself keeps running. Unless configured, a default is
derived from the host's total RAM when the Container starts, and the
effective value is printed at startup.
_Avoid_: memory quota, RAM cap

**Memory+swap limit**:
The total RAM-plus-swap a **Container** may consume. Equal to the
**Memory limit** by default, so a runaway process is OOM-killed
immediately instead of dragging the host into swap thrashing. Raising
it above the **Memory limit** grants exactly the difference as swap.
_Avoid_: swap limit (the value is a total, not an amount of swap)

**Effective memory usage**:
A **Project**'s `memory.current` minus what the kernel reclaims before
resorting to an OOM kill — page cache (`inactive_file` +
`active_file`) and reclaimable slab, per `memory.stat`. Every boxa
usage surface (`boxa ls`, `boxa mem`, the **Memory warning** bands,
the shrink-safety check) reports this value, because raw
`memory.current` counts a warm file cache as usage and reads nearly
full on a healthy, cache-heavy Project. The **Memory limit** itself
needs no such correction: the kernel evicts the cache before killing.
_Avoid_: real memory usage (vague), working set (Kubernetes term that
subtracts only `inactive_file`)

**OOM archive**:
The durable per-event record of an OOM kill in a **Project**, captured
from the kernel log at first sighting so it outlives both the
Container and a host VM restart. Carries the project name, timestamp,
the victim process and its RSS, and the **Memory limit** in force.
The kernel log is the source; the archive is the record.
_Avoid_: oom log, kill log

**Memory warning**:
The banded notice raised when a **Project**'s **Effective memory
usage** crosses 80 % or 90 % of its **Memory limit**. Fires only on
entering a band and re-arms only
after usage falls back below it, so a Project hovering at a threshold
warns once, not continuously.
_Avoid_: memory pressure (PSI is a different kernel concept)

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
- A **Cross-boxa connection** is owned by exactly one source **Container**.
  A **Host connection** with all-boxes scope is the one exception: it is
  applied to every **Container** at start.
- A **Host connection**'s firewall exception lives exactly as long as its
  persisted entry: re-established on every Container start, removed by
  explicit removal and by uninstall. Like the **Allow-for window**, it can
  only be granted from the host — never requested from inside the
  **Container**.
- The **Allowlist** and a **Host connection** are different gates: the
  **Allowlist** admits domains via DNS resolution into the
  **Allowed-domains ipset**; a **Host connection** admits exactly one
  IP:port pair. Neither implies the other.
- The **SSH gate** stands in the same row as the **Allowlist**, a **Host
  connection**, and the **Agent-browser allowlist**: default-deny, host-owned,
  never grantable from inside the **Container**. It admits a signing
  capability, not traffic — reaching an SSH host still requires the
  **Allowlist** (or a **Host connection**).
- The **SSH gate** resolves per **Project**: a project section in
  `ssh.conf` overrides the global choice; absent both, the gate is off.
  Boxa never loads keys into the agent on its own — only the **Key
  picker** (user-confirmed `ssh-add`) does.
- A **Project** has one effective **MCP profile** at a time, formed only from
  its explicit **MCP activations**. The user-wide **MCP catalog** contributes
  available definitions, never implicit selections.
- An **Inherited MCP server** is not automatically a **Boxa MCP server**.
  Boxa first classifies it and proposes how it should enter the **MCP catalog**;
  import never activates or grants trust by itself.
- The **MCP broker** runs **Service-isolated MCP servers** as **boxa-mcp** and
  authorizes the **Boxa MCP launcher** to run **Agent-trusted MCP servers** as
  the agent user. Credentials in the **MCP secret store** stay behind the
  service boundary except for the documented node-inspectable Docker-container
  environment limitation (ADR 0021).
- The **MCP profile** is delivered into the **Container** live (read-only mount);
  the **MCP secret store** is staged privately for **boxa-mcp** and refreshed
  into a running **Container** by `boxa mcp reload`, not by a restart.
- **boxa-mcp** and `node` share the broker control plane (via the
  **boxa-bridge** group) and the workspace (via an idmapped mount), but a
  **Service-isolated MCP server** does not receive the node-owned raw Docker
  socket. Docker-packaged servers use the **MCP Docker launch adapter**. None of
  this sharing touches host ownership or permissions (ADR 0021).
- A **Memory limit** binds the **Container** as one aggregate: nested
  DinD workloads count against it but cannot be attributed
  individually, so per-process and per-nested-container numbers are
  always reported as project totals.
- A **Memory limit** change applies to a running **Container** in
  place; it never requires recreating the Container and never touches
  volumes.
- An OOM kill inside one **Project**'s Container never affects another
  Project's Container or the host's Docker daemon.
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
