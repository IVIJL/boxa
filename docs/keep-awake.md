# Keep-awake

`boxa keep-awake` optionally runs the **Keep-awake daemon**, which blocks idle
sleep only while one or more coding agents hold **Awake leases**. Enablement
builds the daemon from `keep-awake/` in a pinned golang Docker container,
falling back to the host's local Go toolchain, then installs user autostart and
creates a port-17777 Host connection trusted by every present and future box.

On WSL2, the scheduled task resolves the Windows vEthernet adapter when it
starts. If the adapter is still absent after 60 seconds, keep-awake starts on
loopback only and continues polling every 30 seconds. Once vEthernet appears,
the wrapper stops the daemon instance it started and restarts it with both
loopback and vEthernet listeners. `status` and `doctor` also require the task's
PowerShell wrapper to exist; `boxa keep-awake enable` repairs a missing wrapper.
On WSL2, boxa functionally probes the daemon on loopback first and then on the
default gateway. The keep-awake Host connection relays to the first target that
returns an HTTP status response. Enablement also requests elevation to install
the `Boxa Keep-Awake (WSL)` Windows firewall rule, limited to TCP port 17777,
the WSL vEthernet interface, and remote addresses on its local subnet. Declining
UAC leaves mirrored/loopback operation available but the NAT gateway path
blocked; enablement continues and `status` / `doctor` identify the missing rule
as the likely cause. Disable and uninstall remove the rule best effort.

```bash
boxa keep-awake enable
boxa keep-awake status
boxa keep-awake disable
```

## Start with your terminal instead of the system

Run `boxa keep-awake enable --autostart terminal` to install and start the
daemon without a system service or tray autostart. The command prints a
ready-to-paste WezTerm `gui-startup` block containing the resolved installed
paths. On WSL2 the block starts the generated PowerShell wrapper, which resolves
the current WSL gateway; on Linux and macOS it starts the installed binary with
the same arguments as system autostart.

For another terminal, run the printed wrapper or equivalent binary command from
its startup hook. Duplicate launches are safe because the daemon's port bind is
the single-instance guard. A terminal-started daemon ends with that terminal
session, while system autostart is always available after login; an idle daemon
does not inhibit sleep. Use `--autostart none` when another startup mechanism is
entirely user-managed.

The installer offers this elective once. A decline is remembered; plain
`boxa doctor` reports it without changing the choice. Enable it later with
`boxa keep-awake enable` or `boxa doctor --fix keep-awake`.

## Activity hook

Boxa's managed Claude config includes the **Activity hook**, `agent-awake.sh`,
in every Container. It refreshes a 15-minute **Awake lease** on
`UserPromptSubmit` and `PreToolUse`. On `Stop`, it releases the same
project-scoped lease unless the owning Claude process still has a live
background shell-snapshot child, in which case it refreshes the lease instead.
The hook calls the Host connection on local port 17777 with a one-second timeout
and always exits successfully, so it is a silent fast no-op until the daemon is
made reachable with `boxa keep-awake enable`. Existing Claude configs receive
the hook and settings entries additively during Container setup.

Third-party agents can implement the same activity/stop protocol. The
**Keep-awake daemon** gives each **Awake lease** a default TTL of 15 minutes, so
a missed stop event cannot hold the machine awake forever:

```bash
#!/usr/bin/env bash
set -euo pipefail

agent="${1:-claude}"
event="${2:-activity}"
session="${BOXA_PROJECT_NAME:-default}"

keep_awake_host() {
    # Inside a box, the global Host connection listens locally.
    if [ -f /etc/boxa/identity.json ]; then
        printf '127.0.0.1'
    # From WSL, prefer mirrored-networking loopback when it answers, then use
    # the Windows host's vEthernet/default-gateway address.
    elif grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        if curl -fsS --noproxy '*' --max-time 2 \
            http://127.0.0.1:17777/v1/status >/dev/null 2>&1; then
            printf '127.0.0.1'
        else
            ip route show default | awk 'NR == 1 { print $3; exit }'
        fi
    # Native Linux and macOS reach the Keep-awake daemon directly.
    else
        printf '127.0.0.1'
    fi
}

base="http://$(keep_awake_host):17777"
case "$event" in
    start|activity)
        curl -fsS --max-time 2 \
            "$base/v1/busy/$agent?ttl=900&session=$session" >/dev/null
        ;;
    stop)
        curl -fsS --max-time 2 \
            "$base/v1/idle/$agent?session=$session" >/dev/null
        ;;
esac
```

Resolution order for any client is: native Linux/macOS → `localhost`; WSL →
probe `localhost`, then the Windows vEthernet/default-gateway IP; boxa Container
→ `localhost` on the Host connection's local port (17777 by default).
`GET /v1/status` returns the active holders, remaining TTLs, inhibitor state,
**Power-watch** state, and daemon version.

## Pre-sleep stop

On native Linux, **Power-watch** starts with the **Keep-awake daemon** and
holds a systemd-logind delay inhibitor for sleep and shutdown. When logind
announces either transition, Power-watch runs
`boxa stop --all --reason presleep` regardless of any held Awake leases, then
releases the delay inhibitor so the transition can continue. Its output is
written to the daemon log. macOS and Windows Power-watch implementations are
currently no-ops.

The command and its one-minute stop budget can be overridden with the daemon
flags `-power-watch-command` and `-power-watch-timeout`. A hanging command is
terminated when that budget or logind's shorter effective delay expires.

logind commonly defaults `InhibitDelayMaxSec` to only a few seconds. If the
configured stop budget is longer, raise `InhibitDelayMaxSec` in
`/etc/systemd/logind.conf` and restart logind (normally by rebooting) so Boxa
has enough time to stop every Container cleanly. `/v1/status` reports the
effective delay, stop budget, Power-watch activity, and a hint when the delay
is shorter than the budget.
