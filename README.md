# boxa

**A throwaway dev box for you and your AI agent — sealed off from your machine, and gone without a trace.**

Run Claude Code (or any agent) with `--dangerously-skip-permissions` and mean
it. boxa is a Dev Container with a default-deny firewall, a hardened browser
that can't touch your keys, and full Docker-in-Docker — so you and your agent
get a real machine to work on while your host stays clean.

It's also a blast radius. A malicious `npm install` — or a poisoned pip, cargo,
or any link in the dependency supply chain — lands in a box that holds none of
your secrets and can't phone home: **nothing worth stealing, and nowhere to send
it anyway.** Whatever the agent runs stays sealed behind the firewall and dies
with the box.

<!-- DEMO PLACEHOLDER — issue 12 fills this with an asciinema cast / GIF of
     install → start → firewall in action. -->

## Why boxa?

- 🔒 **Isolated & controlled.** The agent works in a container off your host,
  behind a **default-deny firewall**. Nothing reaches the internet unless you
  allowed it — you own the egress list, and grow it from what was actually
  blocked. → [Firewall](docs/firewall.md)

- 🔑 **The agent-browser can't steal your keys.** Give the agent a real Chrome
  to drive — screenshots, console, click-throughs — without handing it your
  secrets. Chrome runs as a **separate OS user with no access to your home**,
  and all its traffic goes through a default-deny forward proxy.
  → [Agent-browser](docs/agent-browser.md)

- 🐳 **Install nothing, anywhere.** Full rootless **Docker-in-Docker** lives
  inside the box, so venvs, Vite, npm, and Postgres all run in nested throwaway
  containers — **neither your host nor the box gets polluted**.
  → [Docker-in-Docker](docs/docker-in-docker.md)

- ⚡ **Portable in minutes.** Foreign machine → `install` → add an SSH key →
  `clone` → work. Built on the **Dev Containers** standard, so VS Code and
  Cursor attach remotely like any devcontainer. → [Editors](docs/editors.md)

- 🧹 **Clean uninstall, zero traces.** `boxa uninstall` removes every container,
  volume, and image; `--purge-ca` even strips the local HTTPS root CA from your
  trust stores. Nothing lingers.

- 🔍 **No opaque prebuilt image.** You **build the box from a Dockerfile you can
  read** — no registry pull, no binary blob, no supply-chain surface beyond the
  upstream base we pin and audit. → [ADR 0018](docs/adr/0018-local-first-no-prebuilt-image.md)

## Quick start

```bash
# 1. Install (downloads git/Docker/keychain, configures SSH agent, clones,
#    installs the `boxa` command). Review it first:
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/IVIJL/boxa/main/install.sh -o install.sh
less install.sh
bash install.sh

# …or the non-interactive one-liner:
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/IVIJL/boxa/main/install.sh | bash -s -- --yes

# 2. Build the image once (from the Dockerfile you just reviewed — local-first,
#    no registry pull). Reused across every project afterwards:
boxa build

# 3. Start a box for the current project (creates/attaches the container):
cd ~/projects/my-app
boxa

# 4. You're in. Run your agent, build, test — the firewall has your back:
claude --dangerously-skip-permissions
```

That's it. `boxa ls` lists your boxes, `boxa stop` parks one, `boxa <name>`
re-attaches. Run `boxa --help` for the full command list.

**Dotfiles.** During `install.sh` you pick a dotfiles strategy:
**1)** boxa's [bundled chezmoi starter](dotfiles/README.md) (recommended —
applied locally from the image, no network), **2)** your own chezmoi repo URL,
or **3)** none (pure bash). The choice is saved to
`~/.config/boxa/dotfiles.conf` and applied on every container start. A
non-interactive install (`--yes` / piped) takes the default without prompting.

## How it works

Each project gets its own container (`boxa-<project>`), Docker volume, and shell
history, wired to a shared Traefik proxy and a local DNS resolver. On start the
container brings up the default-deny firewall, the rootless Docker daemon, and
your dotfiles — all from a privileged entrypoint, with no in-container `sudo`.
Your project files are bind-mounted; your SSH **agent** is forwarded (never the
keys). The full per-feature reference lives in [docs/](docs/).

## Editor support

| Editor | Status |
|--------|--------|
| VS Code | Supported |
| Cursor | Supported |
| Zed | Planned (SSH remote — see [ROADMAP](ROADMAP.md)) |

Open a project and run **Dev Containers: Reopen in Container**, or drive it from
the CLI with `boxa code` / `boxa cursor`. See [docs/editors.md](docs/editors.md).

## Documentation

Per-feature guides:

- [Firewall](docs/firewall.md) — default-deny allowlist, `allow`/`deny`/`blocked`, allow-for harvest window.
- [Agent-browser](docs/agent-browser.md) — sessions, network windows, allowlist, artefacts, per-OS prerequisites.
- [MCP servers](docs/mcp.md) — profile model, import/add/render/install/doctor, credential isolation.
- [Networking & port routing](docs/networking.md) — local `.test` DNS, sslip.io fallback, HTTPS via mkcert.
- [SSH](docs/ssh.md) — agent forwarding, boxa SSH config, WSL2 keychain.
- [Docker-in-Docker](docs/docker-in-docker.md) — rootless DinD, persistence, graceful shutdown.
- [Editors](docs/editors.md) — VS Code / Cursor attach; Zed (planned).

Design rationale lives in the [Architecture Decision Records](docs/adr/).
Project conventions and the domain glossary are in [CONTEXT.md](CONTEXT.md).

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to
build, test, and lint, and [ROADMAP.md](ROADMAP.md) for where the project is
headed. Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

To report a security vulnerability, do **not** open a public issue — see
[SECURITY.md](SECURITY.md).

## Acknowledgments

boxa was built as a human + AI collaboration:

- **[Claude Code](https://claude.com/claude-code)** (Opus 4.8) — pair-programmed
  the implementation, end to end.
- **[Codex](https://github.com/openai/codex)** — the independent reviewer that
  kept every diff honest.
- **[Matt Pocock](https://github.com/mattpocock)** — for the superb agent skills
  that shaped how this was built.

## License

Released under the [MIT License](LICENSE).
