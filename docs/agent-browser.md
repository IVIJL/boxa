# Agent-browser

`boxa agent-browser` gives an LLM agent inside the container a real Chrome on
the host to drive — screenshots of the project's dev URL, JS console output,
network-tab inspection, click-through flows. Crucially, that Chrome **cannot
steal your keys**: the **Host agent Chrome** runs under a dedicated
`boxa-agent` OS user with hardened launch flags and no access to your home, and
the container reaches its CDP endpoint through an **Agent-browser session
bridge** (a per-session `socat` process inside the container's network
namespace). All of Chrome's outbound HTTP/HTTPS is forced through the
**Agent-browser proxy**, which mirrors the firewall's default-deny posture at
the browser layer.

See [ADR 0010](adr/0010-agent-browser-host-broker-and-proxy.md) for the full
security model, [ADR 0012](adr/0012-agent-browser-denial-visibility.md) for how
denials are surfaced, and the **Agent-browser** section of
[CONTEXT.md](../CONTEXT.md) for the terminology.

## Quick start

A full session from launch to teardown, including a short network window for one
external request:

```bash
# Host: launch Host agent Chrome + per-session bridge into the 'my-app' container
boxa agent-browser start my-app

# Container: drive Chrome via the agent-browser CLI (dev URLs go through the
# Chrome bypass list — no network window needed)
agent-browser navigate http://3000.my-app.test
agent-browser screenshot --output /tmp/dash.png

# Host: open a 5-minute Agent-browser network window (proxy flips to harvest
# mode) so Chrome can reach a host that isn't a dev URL and isn't in the
# Agent-browser allowlist
boxa agent-browser allow-for 5 my-app

# Container: that external navigation can now succeed
agent-browser navigate https://developers.facebook.com/tools/debug/

# Host: close the window early (or let the timer expire) and tear down the session
boxa agent-browser allow-for --stop my-app
boxa agent-browser stop my-app

# Host: any time during the session, inspect status
boxa agent-browser status my-app       # active session + remaining network-window time
```

## Two time gates

`agent-browser` has two independent time gates. The **Agent-browser session** is
the Chrome+bridge lifecycle and can run for hours (the Chrome window on your
desktop is the visual audit surface). The **Agent-browser network window** is a
short sub-state that flips the proxy from default-deny into harvest mode,
paralleling the firewall `allow-for` on the browser layer.

| Layer | Window | Started by | Closed by | Default |
|---|---|---|---|---|
| Firewall (DNS + iptables) | Allow-for window | `boxa allow-for N` | `--stop`, timer, container stop | closed |
| Agent-browser (HTTP proxy) | Agent-browser session | `boxa agent-browser start` | `... stop`, idle timeout, container stop | absent |
| Agent-browser (HTTP proxy) | Agent-browser network window | `boxa agent-browser allow-for N` | `... allow-for --stop`, timer, session stop | closed |

Dev URLs (`localhost`, `*.test`, `*.127.0.0.1.sslip.io`) are set as Chrome's
`--proxy-bypass-list` and go direct without touching the proxy — opening a
network window is only needed for genuinely external hosts.

```bash
boxa agent-browser allow-for 15 my-app       # 15-minute window in 'my-app'
boxa agent-browser allow-for --stop my-app   # close the window early
```

## Default-deny and growing the allowlist

The Agent-browser proxy reads its allowlist from
`~/.config/boxa/agent-browser-allowed-domains.conf` (distinct from the
[firewall allowlist](firewall.md)). Format: one domain pattern per line, `#` for
comments, `*` glob for subdomains.

```bash
# boxa agent-browser default-mode allowlist
*.github.com
api.openai.com
registry.npmjs.org
```

The installer drops a documented
`agent-browser-allowed-domains.conf.example` next to it on first run. Edits take
effect on the next `boxa agent-browser start`; mid-session reloads happen
automatically when you run `boxa agent-browser allow-for ...` (the broker
re-stages the snapshot and SIGHUPs the proxy). Hosts that show up in a window's
harvest log are good candidates for promotion to the durable list.

## Artefacts

Each session leaves three files on the host, owned by
`boxa-agent:boxa-agent` mode `0640` — your user reads them via group
membership; nothing inside the container can write to them.

```
/var/log/boxa/agent-browser/<container>-<ISO>.netlog.json    # Chrome's native netlog
/var/log/boxa/agent-browser/<container>-<ISO>.proxy.log      # JSONL of every proxy decision
/var/log/boxa/agent-browser/<container>-<ISO>.summary.md     # human-readable digest
```

`summary.md` lists visited hosts, out-of-allowlist hits during harvest, denied
requests, and any hard fails (`file://`, `chrome://`, native messaging, denied
downloads). A clickable desktop notification at session and network-window close
opens the relevant file.

## Per-OS prerequisites

Chrome must be installed on the host. The **Agent-browser proxy** + **Host agent
Chrome** + notification dispatcher each have an OS-specific path, all gated
through `lib/host-platform.sh`.

### WSL2 (validated)

The reference platform. Chrome runs as a Linux binary inside the WSL2 distro —
*not* the Windows Chrome on the host. WSLg renders the window onto the Windows
desktop, so the visual-audit story is identical to native Linux.

Setup checklist:

1. Install Chrome (or Chromium) inside the WSL2 distro:
   ```bash
   sudo apt-get install -y chromium                          # Debian/Ubuntu
   # or Google Chrome:
   wget -qO- https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
   echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list
   sudo apt-get update && sudo apt-get install -y google-chrome-stable
   ```
2. Run `bash install.sh` (or `boxa update` if upgrading) — this creates the
   `boxa-agent` OS user + group, adds you to that group, and stages the Python
   helpers under `/usr/local/lib/boxa/agent-browser/`.
3. **Re-login (or `newgrp boxa-agent`)** so the group membership applies in your
   current shell. Without this, you cannot read `summary.md` / netlog / proxy
   log artefacts at `/var/log/boxa/agent-browser/` (mode `0640`, group-readable
   only).
4. Notifications use the existing **allow-for** toast pipeline (BurntToast via
   `powershell.exe`). No extra setup beyond what `boxa allow-for` already needed.

Common WSL2 gotchas:

- **`chromium` from snap** doesn't work cleanly with `--user-data-dir` under
  `/var/lib/boxa-agent/`. Use the apt or `.deb`-distributed binary.
- **WSLg not rendering**: requires WSL version `0.65.1+` and a Windows 11 /
  Windows 10 22H2+ host. Run `wsl --version` on the Windows side to check.
- **`host.docker.internal` resolution**: Docker Desktop sets this
  automatically; on Docker-CE-inside-WSL2 (no Docker Desktop),
  `docker-run.sh` passes `--add-host=host.docker.internal:host-gateway` so the
  in-container socat bridge can still reach the host-side Chrome.

### Native Linux + macOS

Both platforms are designed-for but not yet end-to-end validated by the
maintainer. The platform-dispatch helper (`lib/host-platform.sh`) covers the
differences.

**Native Linux** (Ubuntu, Arch, Fedora, openSUSE, Alpine):

1. Install Chrome via your package manager:
   ```bash
   sudo apt-get install -y chromium                # Debian/Ubuntu
   sudo dnf install -y chromium                    # Fedora/RHEL
   sudo pacman -S chromium                         # Arch
   sudo zypper install chromium                    # openSUSE
   sudo apk add chromium                           # Alpine
   ```
   …or Google Chrome from `https://www.google.com/chrome/`.
2. `bash install.sh` (same as WSL2).
3. **Re-login (or `newgrp boxa-agent`)** to pick up the group.
4. Make sure `notify-send` (`libnotify-bin` / `libnotify`) is installed for
   click-to-open toasts.

**macOS:**

1. Install Chrome to `/Applications/`:
   ```bash
   brew install --cask google-chrome
   ```
   …or download from `https://www.google.com/chrome/`.
2. `bash install.sh`. `sysadminctl` will prompt for an administrator password
   (GUI dialog) the first time — used to create `boxa-agent` and the matching
   `boxa-agent` group, and to bind your user to it.
3. **Open a new terminal session** so the new group membership is picked up.
4. Toast click-to-open uses `osascript`; no extra install.

Full per-OS validation is pending — see ADR 0010 § "Cross-platform abstraction".

## See also

- [Firewall](firewall.md) — the container-level default-deny firewall, separate
  from the browser allowlist.
- [Networking](networking.md) — the dev URLs Chrome reaches directly.
