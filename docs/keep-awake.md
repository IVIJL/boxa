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
boxa keep-awake refresh
boxa keep-awake disable
```

`refresh` is a silent no-op when keep-awake is not enabled. Otherwise it
rebuilds and replaces only the daemon binary, then restarts the existing
service without prompts, elevation, or changes to autostart, firewall, and
Host connection setup. `boxa update` runs this refresh automatically when its
pulled commit range changes `keep-awake/` or `scripts/ensure-keep-awake.sh`.

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
`UserPromptSubmit` and `PreToolUse`. Each active turn also has one detached,
Claude-process-scoped refresher. It renews the lease every 90 seconds while the
owning Claude process and turn remain active, so a single long tool or MCP call
cannot outlive the lease. The interval must stay below the daemon's two-minute
idle grace because concurrent Claude processes share the project holder. On
`Stop`, the hook moves the same project-scoped lease into the daemon's
two-minute idle grace. A live background shell-snapshot child keeps the
refresher active until that child exits; the refresher then sends idle itself.
The hook calls the Host connection on local port 17777 with a one-second
timeout and always exits successfully, so it is a silent fast no-op until the
daemon is made reachable with `boxa keep-awake enable`. Existing Claude configs
receive the hook and settings entries additively during Container setup.

Third-party agents can implement the same activity/stop protocol. The
**Keep-awake daemon** gives each **Awake lease** a default TTL of 15 minutes.
Idle requests shorten an existing lease to a two-minute grace period instead of
removing it immediately. The grace closes brief gaps between turns or
subagents, while an idle request for an absent holder remains a no-op. This
gap-coverage guarantee assumes idle grace is at least the hook heartbeat
interval (90 seconds by default); lowering `-idle-grace` below it, including to
zero, gives up that protection:

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
and daemon version.

### Bounded expiry guarantees

| Failure or completion mode | Maximum lease lifetime without new activity |
| --- | --- |
| Claude or the refresher crashes | One lease TTL (15 minutes by default) |
| A session reaches `Stop` and is abandoned | One idle grace (2 minutes by default) |
| Claude, hook, and refresher are all killed with `SIGKILL` | One lease TTL (15 minutes by default) |

The daemon logs holder add, idle-linger, removal, and expiry transitions, plus
sleep-inhibitor acquisition and release. It also logs one successful refresh
per holder at most every five minutes; the line includes the heartbeat `src`
(such as `hook` or `refresher-<claude-pid>`) when the client supplied it.
Higher-frequency busy refreshes remain suppressed between those marks.

Client-side refresher lifecycle and connectivity transitions are appended to
`$TMPDIR/boxa-agent-awake/<claude-pid>/refresher.log` (or the equivalent path
under `BOXA_AWAKE_STATE_DIR`). It records refresher start/exit, daemon failure
after a prior success, and recovery, without logging each successful send. The
hook remains silent and successful even when this best-effort log cannot be
written.

The daemon does not react to shutdown, poweroff, or sleep: those transitions
leave boxes untouched, and after a resume they remain available. Stop boxes
explicitly with `boxa stop --all` when needed.

Daemon changes need no separate deployment step. Because the code is under
`keep-awake/`, `boxa update` detects it in the pulled commit range and
automatically runs `boxa keep-awake refresh` for an enabled installation.
