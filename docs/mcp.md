# MCP servers

`boxa mcp` manages [MCP](https://modelcontextprotocol.io) servers for your
Containers. Boxa stores an **agent-neutral MCP profile** as its source of truth
and *renders* agent-specific config for both Claude Code and Codex from it.
Rendered entries are prefixed `boxa-` (e.g. `boxa-context7`) and call a wrapper,
`boxa-mcp-run <server>`, instead of the raw command — so boxa keeps a stable
control point for the Container-identity check, env validation, and future
runtime changes. Re-rendering only ever touches `boxa-` entries; your inherited
or hand-added agent MCP entries are never rewritten. See
[ADR 0013](adr/0013-container-mcp-profile-and-rendering.md) for the full model.

**v1 supports Container MCP servers only.** A server that runs *inside* the
Container (e.g. an `npx`/`uvx`/`docker` launcher) can be imported and launched.
**Host MCP servers** — ones that need host credential stores, desktop/OS APIs,
browser state, or absolute host paths — are *detected and explained* but **not
launched**: crossing that boundary deserves its own design and is deferred.

## Credential isolation

A Container MCP server's secrets are hidden **from the agent**. Servers don't
run as your agent user (`node`); they run under a dedicated unprivileged
account, `boxa-mcp`, behind an always-on broker. The rendered
`boxa-mcp-run <server>` command is a thin **relay**: it connects to the broker
as `node`, names the server it wants, and proxies stdio. The broker validates
the name against your in-scope profile and spawns the server as `boxa-mcp`,
injecting that server's credentials as environment. The agent only ever sees the
tool stream — never the credential, because it never becomes the server process
and cannot read another UID's `/proc/<pid>/environ`. See
[ADR 0014](adr/0014-container-mcp-broker-and-secret-isolation.md).

**Scope of the guarantee — agent, not peers.** This protects secrets from the
*agent*, not from *other MCP servers*. All servers share the one `boxa-mcp` UID,
and a secret is delivered the only way a server consumes one (an env var), so a
server can read a peer server's secret via `/proc/<pid>/environ`. Closing that
would need per-server UIDs, which require runtime privilege that
[ADR 0003](adr/0003-privileged-entrypoint-no-sudo-in-container.md) deliberately
removes — so peer-to-peer isolation is an **accepted non-goal**: treat every
Container MCP server you import as sharing one trust domain. Only import servers
you'd trust with each other's credentials.

**A Container MCP server is a peer-equal citizen.** Running under a separate
account does *not* make a server second-class: `boxa-mcp` is a full, sudo-less
user of the Container with the same practical reach as the agent. It can work
with your project (read **and** write the workspace) and use the Container's
rootless Docker, so `docker`-launched and filesystem-type servers work too — not
only API-based ones like `context7` and `taskmaster-ai`. The only asymmetry is
privacy: `node` cannot read the server's secrets, and the two accounts don't see
into each other's private files. None of this touches your host — workspace
access uses an idmapped mount and the shared sockets use a Container-internal
group, so your project files on the host keep their original ownership and
permissions.

One consequence of running behind the broker: a server's environment comes from
**its profile and the secret store**, not from your shell session. Boxa copies
non-secret values (e.g. `BASE_URL`) into the profile at import and keeps
credentials in the secret store, so servers start without you re-exporting
anything. A variable you only `export` in your session is **not** inherited by
the server (the broker runs with a clean environment by design) — put any
required config into the server's profile/secret store, not your shell.

## Onboarding

A fresh interactive install, and the first `boxa update` after MCP support
shipped, offer to scan your existing Claude Code / Codex MCP servers for import.
The offer fires **once**: it only appears when no boxa MCP profile exists yet
*and* you have not already seen or dismissed it. The seen/dismissed marker lives
at `~/.config/boxa/mcp/state.json` (outside the profile), so deleting profile
files does not re-trigger the prompt. Non-interactive installs and updates never
prompt or open a picker — they print a concise follow-up command
(`boxa mcp import`) instead. Later updates show only a short reminder.

## Two workflows

### 1. Import existing host agent MCP config

Discovery reads MCP servers already configured in Claude Code / Codex and
classifies each candidate (`container` / `host-only` / `unknown`) from evidence
— command family, arguments, absolute paths, referenced env-var names, network
needs. It is **dry-run by default and writes nothing**:

```bash
boxa mcp import                            # dry-run discovery report (current project + global)
boxa mcp import --all                      # scan every known agent project record
boxa mcp import --project <name-or-path>   # scan one explicit project

# Apply selected Container-safe candidates into the boxa profile:
boxa mcp import --apply                     # interactive wizard (TTY): fzf multi-select,
                                            # per-server scope toggle, project picker
boxa mcp import --apply --server context7
boxa mcp import --apply --import-id imp-abcdef123456
boxa mcp import --apply --all-applicable
```

In a TTY, `import --apply` opens a guided **wizard**: an `fzf` multi-select of
the Container-safe candidates (a numbered menu when `fzf` is absent), then per
selected server a **scope toggle** (default = the inherited scope; switch
project ↔ global in either direction) and — whenever the resulting scope is
*project* — a **project picker** (your initialized boxa Projects, with the
source project pre-selected). The chosen servers are applied
**continue-on-error**: a per-server failure is collected and reported in one
final summary, and a single render runs over the servers that did apply.

The non-interactive path (explicit `--server`/`--import-id`/`--all-applicable`,
or no TTY) preserves the source scope with no prompts. Switching a server's
scope copies its secrets to the chosen scope's `0600` store; the summary reports
which env **key names** were copied, never their values. Host-only, unknown, and
excluded (remote/hosted) candidates are shown but not applied. A successful
apply auto-renders unless you pass `--no-render`.

### 2. Add a brand-new boxa MCP server

`boxa mcp add <name> -- <command spec>` records an explicit new server that was
never in a host agent (distinct from `import`, which discovers inherited ones,
and `install`, which materializes runtime). The spec after `--` is the literal
launch command:

```bash
boxa mcp add context7 --global -- npx -y @upstash/context7-mcp@latest
boxa mcp add myserver --project myapp -- uvx my-mcp-tool
boxa mcp add gh --global -- docker run -i --rm -e GITHUB_TOKEN=... ghcr.io/github/github-mcp-server
```

The spec is classified and probed like an imported server, so a host-only /
unknown / remote-connector command is **refused** with a clear reason rather
than recorded. Scope is **always an explicit choice** — `--global` or
`--project <p>` set it non-interactively; in a TTY with no scope flag you pick
from the same project picker the import wizard uses; without a TTY and no scope
flag, add fails with examples. An inline secret env value (a Docker
`-e KEY=VALUE` whose name or value looks like a credential) is written to the
scope-correct `0600` secret store and never echoed. A successful add
auto-renders unless you pass `--no-render`.

## Profile management

```bash
boxa mcp list                          # effective profile for the current project (global + project)
boxa mcp list --all                    # global plus every project profile
boxa mcp list --inherited              # detected Inherited MCP servers (read-only)
boxa mcp enable  <name> [--global|--project <p>]
boxa mcp disable <name> [--global|--project <p>]   # a project disable of a global server creates a project-only override
boxa mcp remove  <name> [--global|--project <p>] [--purge]   # --purge also deletes scoped secrets
```

A Project entry **shadows** a same-named global entry for that project's
effective view. Mutating commands auto-render unless you pass `--no-render`.

## Render

```bash
boxa mcp render --dry-run                 # preview the Claude Code / Codex config boxa would write
boxa mcp render --dry-run --project <p>   # focus the preview on one project
boxa mcp render                           # write the full boxa-managed surface into both agents
```

The dry-run preview shows planned `boxa-` entries (their prefixed name and the
wrapper command they call — never the raw command, never secret values) and
separates existing entries by ownership so the re-render contract is visible.
The write path always renders the **full** managed surface (a scoped write would
drop other projects' rendered entries).

New Claude Code entries default to **disabled** for each project. They remain
visible in Claude Code's `/mcp` panel and can be connected there with `Enable`;
subsequent boxa renders preserve that native choice. Codex does not currently
offer an equivalent in-session toggle, so boxa continues to render Codex entries
enabled.

## Install (materialize)

`import` preserves the inherited command by default (e.g.
`npx -y @upstash/context7-mcp@latest`). `boxa mcp install` optionally
**materializes** an existing profile entry into persistent Container runtime and
rewrites the profile to use the installed command:

```bash
boxa mcp install <name> [--global|--project <p>] [--allow-for <min>] [--keep-window]
```

The install runs **inside a Container** (the runtime lives there, not on the
host): a project install targets that project's Container; a global install uses
one running Container, offers a picker when several run, and requires
`--project` in non-interactive ambiguous cases. npm/npx servers install into the
persistent npm-global prefix; Docker-backed servers pull into project-scoped
rootless Docker state; Python/uv reports that a dedicated MCP runtime volume is
needed first.

Install uses the existing firewall workflow. `--allow-for <min>` opens an
[Allow-for window](firewall.md#allow-for-harvest-window) for the attempt (closed
afterward by default so the harvest log is produced immediately; `--keep-window`
leaves it open). On a blocked-network failure the command points at
`boxa blocked` and shows the exact rerun command — so you can review blocked
domains, allow the trusted ones, and rerun the same install.

## Doctor

```bash
boxa mcp doctor                        # diagnose profile / render / runtime problems
boxa mcp doctor --fix                  # apply only SAFE local fixes
```

Doctor checks host-vs-Container context, the `boxa-mcp-run` wrapper on PATH,
profile JSON validity, render drift (profile vs rendered config), and required
env presence (by name only). `--fix` performs only safe local fixes — re-render,
create missing MCP dirs, repair the wrapper symlink. It never installs packages,
allows domains, purges runtime, or enables host-only servers.

Run `boxa mcp --help` for the full subcommand reference.

## See also

- [Firewall](firewall.md) — `boxa mcp install` uses the allow-for harvest window
  to reach package registries.
