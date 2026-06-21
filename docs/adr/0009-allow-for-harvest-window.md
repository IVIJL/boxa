# ADR 0009 — Time-bounded `allow-for` window via DNS-driven harvest pool

- **Status:** accepted
- **Date:** 2026-05-15

## Context

Boxa's default-deny firewall (ADR 0001) is correct for steady-state work
but painful during exploratory tasks where the set of needed domains is
unknown — typically an LLM agent doing nonsupervised research, or an
unfamiliar `npm install` pulling exotic dependencies. The reactive
workflow today is "run task → it fails → `boxa blocked` → allow → retry",
which is fine for a developer-in-the-loop but unworkable for an autonomous
agent.

The user wants a **proactive** workflow: start a time-bounded session in
which the firewall passively allows non-allowlist destinations *and
records them*, so the session produces a harvest log that informs the
durable allowlist afterward. The trust requirement is asymmetric: the
session is a security exception, so the *control state* (timer, sentinel,
firewall rules) must be tamper-proof against code running inside the
container, but the *output state* (the harvest log itself) is informational.

## Decision

A new `boxa allow-for [minutes] [project]` command opens an
**Allow-for window** in one container. During the window:

1. **Catch-all ipset.** A second Netfilter set (`harvest-pool`) is populated
   by dnsmasq's `ipset=//harvest-pool` directive (the empty-domain form
   matches every A/AAAA query). iptables gains one `ACCEPT --match-set
   harvest-pool dst` rule *before* the final `REJECT`. The original
   `allowed-domains` ipset and the `REJECT` baseline remain unchanged.
2. **DNS pinning** (made permanent, not window-scoped). Outbound DNS is
   restricted to `127.0.0.1` on UDP/TCP 53; DoT on TCP 853 is
   `REJECT`ed. This guarantees every name resolution flows through the
   audited resolver, which is the precondition that makes the harvest pool
   complete. The rootless DinD inside the boxa container is a special
   case: inner build/run containers live in a separate network namespace
   where `127.0.0.1` resolves to their own (empty) loopback. The
   slirp4netns gateway address `10.0.2.2`, set as the daemon-wide default
   via `~/.config/docker/daemon.json` in `start-rootless-docker.sh`,
   loopback-maps back to the boxa container's `127.0.0.1:53`, so inner
   DNS still flows through dnsmasq and the audit invariant holds for
   `docker build` and `docker run` too.
3. **Sentinel state** in `/etc/boxa-shared/.allow-for.state` (root-owned
   inside the container, mode 0644). Holds `started_at`, `expires_at`,
   container name, and the teardown daemon's PID. The node user can read
   it but cannot modify it.
4. **Tamper-proof harvest log** at
   `/var/log/boxa/allow-for/<container>-<ISO>.log` on the host. The
   directory is created at install time as `root:root 0755`, mounted into
   the container without `:ro`. Files are written by the in-container
   root daemon with mode 0644. The node user (= host user UID 1000)
   can read but cannot delete or overwrite.
5. **Reset-clock semantics.** A second `boxa allow-for N` during an
   active window overwrites the `expires_at` to "now + N min". The harvest
   log accumulates within the session.
6. **Closeout on container restart.** `init-firewall.sh` checks the
   sentinel; if it finds a window state that did not complete cleanly, it
   writes the final harvest log with a "window interrupted by restart"
   marker and emits the notification.
7. **Clickable closeout notification** with a platform-native click
   action that opens the run's log:
   - **WSL2** — inline COM PowerShell toast (no module install)
     registered under AppId `Boxa.AllowFor` (one-time HKCU registry
     write at install). Protocol activation (`activationType="protocol"`,
     `launch="file://…"`) opens the harvest log via its WSL UNC path; no
     UWP activator COM server needed.
   - **Native Linux** — `notify-send` with a single `default` action
     (`-A default=…`), which mako/dunst/GNOME invoke on a body click.
     Left-click runs `xdg-open` on the log. See the **Revision** note
     below for why this is now a clickable action rather than the
     passive notification the original decision shipped.
   - **macOS** — `osascript display notification`, no click action (the
     API has none); the log path is rendered in the body.
   The log path is also kept in the notification body on every platform,
   so a daemon without action support still shows where the log is. The
   log file is always written; the notification is a convenience pointer,
   never the canonical record.

## Considered options

**Default-accept during the window.** Simply replace the final `REJECT`
with `ACCEPT` for the window's duration. Trivial to implement, no second
ipset. Rejected because it lets hardcoded-IP traffic out without ever
touching the resolver, which both expands the threat surface and breaks
the auditing invariant ("every successful outbound passed through our
DNS"). Net cost of the harvest-pool approach is ~5 lines of extra code
for a meaningful gain.

**Auto-add on DNS query.** Tail the dnsmasq query log, add new domains to
the allowlist on the fly. Rejected because dnsmasq writes the query log
*after* responding, so a tail-watcher always lags ~30 ms behind — the
client's `connect()` to a freshly-resolved IP races the ipset update and
typically loses (client gets `ICMP admin-prohibited`, fails without
retry). The first request to each new domain would fail intermittently
with no obvious cause.

**MITM proxy for full URL audit.** Run Squid or mitmproxy in the
container to capture HTTP paths, not just hostnames. Rejected as out of
scope: a separate project, materially different threat model, and not
needed for the "which domains do I need to add to the allowlist" use
case.

**Background daemon on the host instead of inside the container.**
Survives container restart but complicates the privilege story (the host
daemon would `docker exec` into the container) and provides no benefit
for the chosen "restart = end window" semantics.

## Consequences

**Positive:**

- LLM agents and other unsupervised automation can complete tasks that
  hit unknown domains without the user mediating each allow.
- Hardcoded-IP traffic remains blocked during the window. The auditing
  invariant holds: every successful outbound proves a DNS query through
  the in-container resolver.
- The harvest log is fully tamper-proof against code running as the
  `node` user inside the container — the only privilege boundary that
  matters in practice. The push notification carries the summary out of
  the container the moment the window ends, so even a log overwrite race
  (which the perms prevent anyway) would not hide information from the
  user.
- DNS pinning closes the broader hole where containers could resolve via
  `8.8.8.8`/`1.1.1.1` and bypass the in-container query log entirely.
  This is a security win independent of the `allow-for` feature.

**Negative:**

- One-time `sudo` prompt at install for the `/var/log/boxa/allow-for/`
  root-owned directory. Boxa already requires sudo for DNS install, so
  this is consistent rather than novel.
- The pending-notification hand-off (Phase 3) requires a host-user-owned
  subdirectory `/var/log/boxa/allow-for/pending/` so the host-side
  deliver script can rename-claim files atomically. The parent log dir
  stays `root:root 0755` (harvest logs unchanged). Inside the container
  the host UID maps to the `node` user, so the in-container adversary
  shares write access to that subdir and can forge or replace pending
  files. Two complementary defences close every vector this opens:
  - **Symlink-clobber resistance on the writer side.** The in-container
    teardown daemon never writes directly into the user-writable
    `pending/`. It `mktemp`s in a sibling `.tmp/` subdir (mode 0700
    root:root, under the root-owned `allow-for/` parent so the node
    user can neither enumerate it nor relocate it), writes the JSON,
    and atomic-renames into `pending/`. `rename(2)` replaces a
    symlink at the destination instead of following it, so a
    pre-planted `.pending-… → /etc/shadow` symlink is harmlessly
    overwritten. The TOCTOU race a user-writable tempdir would allow
    is eliminated by writing in the root-only dir.
  - **Filesystem-trust validation on the reader side.** The host
    deliver script treats pending JSON contents as untrusted: it
    derives the harvest log path by reconstructing it from the pending
    filename (which must match the writer's strict
    `<container>-<ts_safe>` shape) and verifies the corresponding log
    file exists in the root-owned parent dir. A forged pending
    pointing at `/etc/passwd` or `evil.bat` cannot reach the toast's
    `launch="file://..."` URI because the reconstructed path is fixed
    and the existence check fails for any log the in-container root
    daemon did not actually write. The attacker-controllable display
    fields (`reason`, `domain_count`, `top_domains`) are bounded and
    only affect the toast's text body — at worst a misleading
    message, no RCE.
- `init-firewall.sh` gains a new responsibility (sentinel closeout) and a
  small amount of state-aware code. The "fresh-deny from scratch" model
  weakens slightly.
- Per-window dnsmasq restart cost (~500 ms) on window open and close.
  Tolerable given the typical 15-min duration.
- DoH (DNS-over-HTTPS) on port 443 to **unknown** hostnames cannot be
  detected without deep packet inspection. The catch-all ipset still
  blocks the resulting connect to the target IP, so DoH does not become a
  general bypass — it only enables data exfiltration *to* the chosen DoH
  endpoint, which the harvest log records. Acceptable for the threat
  model.

## Future work

Items deliberately deferred from the MVP, to be picked up after the
feature has run in real use:

- `boxa allow-for --review [project]` — fzf picker over the most recent
  harvest log, promoting selected entries into the durable allowlist.
- `boxa allow-for --history [project]` — listing of past runs (today
  this is `ls /var/log/boxa/allow-for/`, but a curated view is more
  user-friendly).
- Heuristic grouping in the report (e.g. collapse five `*.cloudfront.net`
  edges to one line). Requires shape data from real harvest logs to
  design well.
- Built-in DoH endpoint blacklist (`dns.google`, `cloudflare-dns.com`,
  `dns.quad9.net`, `mozilla.cloudflare-dns.com`, `doh.opendns.com`) baked
  into the dnsmasq config to refuse resolution of known public DoH
  providers entirely. A small standalone security upgrade, not tied to
  `allow-for`.
- Optional Pi-hole-style malware blacklist consulted *before* a domain
  enters the harvest pool. A larger project; depends on a maintained
  upstream list.
- Status-line integration (Powerlevel10k / starship segment) showing the
  active window and time remaining.
- **Block notification with an "Unblock" action.** A proactive
  counterpart to the closeout notification: when the firewall or the
  agent-browser proxy denies a request, raise a notification carrying an
  *Unblock* action whose handler opens a terminal running the existing
  interactive `boxa blocked` / `boxa agent-browser blocked` picker —
  so the user lands directly in the chooser and selects what to allow.
  Deliberately does **not** pass a domain through the notification: the
  domain to unblock is reconstructed inside the trusted picker (from the
  container-side dnsmasq log / host-side proxy log), which sidesteps the
  spoofing vector a notification-supplied domain would open (click
  "Allow example.com", actually allow `evil.com`). Two unsolved pieces
  keep this out of the current scope: (a) there is no real-time block
  *event* today — firewall blocks are pull-only (read from the dnsmasq
  query log when `boxa blocked` runs) and the proxy log is append-only,
  so an event source / debounced watcher must be built first; (b)
  anti-spam aggregation, since one page load can produce dozens of blocked
  requests. The action plumbing from the **Revision** below (a
  parameterised `notify-send` action + detached listener) is the reusable
  foundation; launching a terminal from the detached GUI process needs
  `xdg-terminal-exec`/`$TERMINAL`. Warrants its own grill and likely its
  own ADR.

## Revision — 2026-06-09: clickable action on native Linux

The original decision (point 7) shipped the Linux backend as a *passive*
`notify-send` with the log path in the body, on the reasoning that
`notify-send` actions "require a blocking listener and depend on the
daemon's action support". In practice every desktop the user runs
(Omarchy/Hyprland + mako, plain Ubuntu + GNOME) implements the
freedesktop Notifications spec, so a `default` action works uniformly —
and the WSL2/native asymmetry (click-to-open on Windows, copy-the-path on
Linux) was a real papercut. This revision adds the clickable action on
Linux. Decisions taken, after a grilling session:

- **Detached listener, `delivered = shown`.** `notify-send -A` implies
  `--wait`, which blocks until the user clicks or the notification
  closes. `deliver_one` calls `deliver_linux` synchronously from both the
  per-`boxa`-invocation `--sweep` and the `--watch` poller, neither of
  which may block. So `deliver_linux` fires the listener in a detached
  subshell (`( … ) & disown`) and returns success the moment the
  notification is shown — mirroring WSL2, where `Show()` likewise means
  "shown", not "clicked". The "click → `xdg-open`" logic lives entirely
  in the detached process.
- **Persistent, no expiry (`-t 0`).** The user is typically away from the
  desk when a window closes; the notification must survive until they
  return and click it. It is sent with `-t 0` (freedesktop "never
  expire", honoured by mako/dunst/GNOME) and the listener has no timeout,
  so the click works as long as the notification is on screen. The cost —
  a slow accumulation of waiting subshells if many notifications are left
  unread across many projects — is accepted as rare (a window/session
  closes at most a handful of times).
- **No retry detection on Linux.** Because the detached subshell returns
  before its inner `notify-send` resolves, the rc-driven
  retry-on-next-sweep cascade no longer sees Linux delivery failures. A
  notification lost to a momentarily-dead daemon is silently dropped — an
  accepted trade against added complexity (a `gdbus`/`busctl` pre-flight
  ping), because the log file is always on disk and a desktop notification
  daemon is effectively always up while the user is logged in. The retry
  cascade is unchanged for WSL2 and macOS.
- **`xdg-open`, not `$EDITOR`.** The click opens the log in the user's
  default GUI handler by MIME type (parity with the Windows toast), not a
  terminal editor that would not surface from a detached GUI process.

## References

- `init-firewall.sh` — gains the DNS-pinning rules and the
  sentinel-closeout logic.
- `lib/allowlist.sh` — unchanged; harvest pool is a separate concern.
- `scripts/start-allow-for-window` (new) — root-privileged window setup.
- `scripts/teardown-allow-for-window` (new) — root-privileged window
  teardown + harvest log write + notification.
- `scripts/start-rootless-docker.sh` — pins inner-DinD DNS to
  `10.0.2.2` via `~/.config/docker/daemon.json` so the DNS-pinning rule
  does not break `docker build`/`docker run` inside the container.
- `docker-run.sh` — new `MODE=allow-for` subcommand.
- ADR 0001 — the underlying dnsmasq/ipset model this feature extends.
- ADR 0003 — the root/node privilege boundary this feature relies on.
