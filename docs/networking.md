# Networking & port routing

Boxa uses a shared [Traefik](https://traefik.io) reverse proxy to route HTTP(S)
traffic to containers by hostname. You expose a port once and reach it from any
browser on the host.

```bash
boxa port 3000                 # Expose port 3000 on all running containers
boxa ports                     # List active routes
```

Each route is published under **two hostnames simultaneously**, so both work
from any browser at the same time:

| Mode | URL for `boxa port 3000` in project `my-app` |
|------|----------------------------------------------|
| `local` (default) — `.test` resolved by a local dnsmasq container | `http://3000.my-app.test` |
| `external` (fallback) — `.sslip.io` wildcard DNS | `http://3000.my-app.127.0.0.1.sslip.io` |

URLs flip to `https://` after `boxa dns-install --enable-https` (see
[HTTPS](#https-mkcert-signed-leaf-certs) below). Both hostnames serve the same
cert; HTTP requests on `:80` are 301-redirected to HTTPS.

Default ports (3000, 5173, 8080, etc.) are applied automatically on container
start. The list is stored in `~/.config/boxa/default-ports.conf` and can be
edited.

> **Dev-server tip.** Because every route resolves under both `*.test` and
> `*.sslip.io` (and `localhost` inside the container), whitelist all three in
> your dev server's allowed-hosts config and bind to `0.0.0.0`, not
> `127.0.0.1`.

See [ADR 0007](adr/0007-local-dns-with-external-fallback.md) for the local-DNS
+ external-fallback design.

## Cross-boxa connections

`boxa port` publishes a port to your **browser** over HTTP(S). `boxa connect`
solves the other direction: letting code in **one box reach a TCP service in
another box** — typically an app in project `web` talking to a Postgres or API
that lives in project `api`.

Boxa containers already share the `devproxy` network, so a process running
*directly* in box `web` can reach box `api` as `boxa-api:<port>` with no setup.
The catch is **Docker-in-Docker**: the inner compose containers you actually run
(see [Docker-in-Docker](docker-in-docker.md)) sit on their own nested network and
are *not* on `devproxy`, so they cannot resolve `boxa-api`. `boxa connect`
bridges that gap.

```bash
boxa connect                   # Interactive: pick source box, target box(es), services
boxa connect api 5432          # Forward this box -> boxa-api:5432 (auto local port)
boxa connect api 5432 15432    # Pin an explicit local forward port
boxa connect api 5432 --from web   # Run from outside web's directory
boxa connections               # List all cross-boxa forwards + live status
```

### How it works

`boxa connect <target> <port>` runs a `socat` listener **inside the source box**
that forwards `127.0.0.1:<local-port>` → `boxa-<target>:<port>` over `devproxy`.
The local port is auto-allocated from the **15000–15999** range (deterministic
per `source:target:port`, so re-running is idempotent), or you can pin one.

Consume the forward by address depending on *where* the client runs:

| Client location | Address to use |
|-----------------|----------------|
| **Inner DinD container** (your compose service) | `10.0.2.2:<local-port>` |
| A process in the source box's main shell | `localhost:<local-port>` |

`10.0.2.2` is the rootless-dockerd gateway: from an inner container it routes to
the box's own loopback, where `socat` is listening.

### Requirements & lifecycle

- **The target service must publish a TCP port** (a compose `ports:` mapping).
  The interactive picker discovers exactly those; services reachable only on the
  target's internal compose network are not connectable.
- Forwards are **persisted** per source box in
  `~/.config/boxa/connect/<source>.tsv` and **auto-restart** when the box
  starts, so connections survive `boxa stop` / restart.
- `boxa connections` shows each forward's `STATUS`: `up` (listener live),
  `down` (source running but no listener — dead forward), or `stopped` (source
  box not running).

See [ADR 0019](adr/0019-cross-boxa-connect-via-socat-forward.md) for the design
rationale (why a per-source socat forward rather than direct `devproxy`
addressing, and why `10.0.2.2`).

## One-time host resolver setup for `.test`

`.test` is an [RFC 2606](https://www.rfc-editor.org/rfc/rfc2606) reserved TLD;
the host OS needs to be told to route `*.test` to `127.0.0.1`.
**`install.sh` runs `boxa dns-install` for you on first install** (it shares
the same sudo / Touch ID moment as the mkcert CA install), so `.test` works
out of the box. You only need the commands below to change mode, recover from a
declined prompt, or inspect state:

```bash
boxa dns-install               # auto: try local, fall back to external on conflict
boxa dns-install --local       # force local; fail loud if setup fails
boxa dns-install --external    # skip resolver setup, use sslip.io URLs only
boxa dns-status                # show current mode + resolver state + verify
boxa dns-uninstall             # remove resolver config + dns.conf
```

If the resolver setup fails for a *fixable* reason (you dismissed the sudo /
Touch ID prompt, or the write errored), `--auto` does **not** silently pretend
success: it prints a loud banner, advertises the working `sslip.io` URLs in the
meantime (so `boxa ports` never offers dead `.test` links), and persists a
degraded state (`preferred=local` + an external `active_domain`). The next
`boxa update` retries the resolver automatically, or re-run
`boxa dns-install --local` yourself. A *durable* fallback instead — port 53
already owned by another resolver, or an unsupported platform — settles calmly
into `external` mode with no retry, since `.test` could never work there.

What `--auto` does per platform (all are idempotent; sudo / UAC prompts as
needed):

| Platform | Resolver setup |
|----------|----------------|
| macOS | writes `/etc/resolver/test` (per-TLD nameserver = `127.0.0.1`) |
| Linux + systemd-resolved | drop-in `/etc/systemd/resolved.conf.d/boxa.conf` (`DNS=127.0.0.1`, `Domains=~test`) |
| Linux + NetworkManager-dnsmasq | drop-in `/etc/NetworkManager/dnsmasq.d/boxa.conf` (`server=/test/127.0.0.1`) |
| WSL2 | both of the above for the WSL2-side CLI, **plus** a Windows NRPT rule (`Add-DnsClientNrptRule -Namespace .test -NameServers 127.0.0.1`) via UAC-elevated PowerShell so the Windows browser resolves too |

Mode preference is persisted in `~/.config/boxa/dns.conf`. Switching mode
(`boxa dns-install --external`) only flips which URL `boxa port` and
`boxa ports` print — Traefik keeps accepting both forms.

## HTTPS (mkcert-signed leaf certs)

Opt-in HTTPS for every project, signed by a per-host
[mkcert](https://github.com/FiloSottile/mkcert) root CA installed once into the
OS + browser trust stores. One UAC / sudo / Touch ID prompt per machine for the
entire lifetime; zero prompts per project (leaf certs are signed locally). See
[ADR 0008](adr/0008-https-via-mkcert-graceful-degradation.md).

```bash
boxa dns-install --enable-https    # install CA, flip https.conf active=true, migrate live routes
boxa dns-install --disable-https   # revert to HTTP-only (CA stays installed)
boxa dns-install --purge-ca        # remove CA from all trust stores + delete https.conf
boxa dns-status                    # includes HTTPS section: active, CA fingerprint, cert inventory
```

What `--enable-https` does:

1. Runs `mkcert -install` on the native trust store (Linux NSS / macOS Keychain
   / WSL2-distro NSS).
2. **WSL2 only:** installs the CA into the Windows `LocalMachine\Root` store via
   UAC-elevated `certutil.exe`, and merges `ImportEnterpriseRoots=true` into
   Firefox's `policies.json` if Firefox is installed (org-managed policies are
   preserved).
3. Flips `~/.config/boxa/https.conf` `active=true`.
4. Rewrites every running project's Traefik route YAML from `web` →
   `websecure` (each original is backed up as `<name>.yml.pre-https-backup`).
5. Recreates `boxa_traefik` with `--entrypoints.websecure.address=:443` +
   permanent 301 from `:80` → `:443`.

Per-project leaf certs land under
`~/.config/boxa/certs/<project>.{pem,key,meta}` on the first `boxa <project>`
call after enabling. Certs auto-regenerate when: meta is missing, expiry is
within 10 days, the root CA fingerprint changed (e.g. the user ran
`mkcert -uninstall` manually), or the SAN set drifted (DNS mode / external
provider change).

If `boxa update` finds no `https.conf` it offers a one-shot upgrade prompt.
Decline with `n` and boxa persists `optout=true`; subsequent updates will not
ask again until you explicitly run `boxa dns-install --enable-https`.

### Troubleshooting HTTPS

- **Port 443 already in use at `--enable-https` time** — boxa refuses to flip
  `active=true` and prints the offending PID/comm. Free the port (or remap the
  conflicting process) and rerun. `https.conf` is left untouched so `boxa
  update` keeps offering the prompt.
- **Port 443 grabbed between sessions** — the next Traefik start downgrades to
  HTTP-only and warns. URLs continue to advertise `http://`. Stop the
  conflicting process and `boxa stop && boxa` to recover.
- **UAC declined on WSL2** — `--enable-https` persists `optout=true` and stays
  HTTP-only. Rerun the command to retry (UAC fires again).
- **Manual `mkcert -uninstall`** — the CA fingerprint stored in each cert's
  `.meta` no longer matches the freshly-seeded CA; the next `boxa <project>`
  detects the drift and regenerates every leaf. Run `--enable-https` again to
  re-install the new CA.
- **`boxa dns-status` HTTPS section** — shows `active`, `optout`, CA fingerprint
  (`sha256:...`), trust-store platforms (`linux,windows,macos`), and the
  project-cert inventory with the nearest expiry date.

## Troubleshooting

- **Port 80 already in use** — `boxa` aborts with `pid <N> (<comm>)` of the
  offender before starting Traefik. Stop that process (or remap its port) and
  re-run.
- **Port 53 already in use** — `dns-install --auto` falls back to `external`
  mode and tells you why. Stick with sslip.io URLs, or stop the conflicting
  resolver and re-run `dns-install --local`.
- **Tailscale Magic DNS** — `accept-dns=true` takes over `/etc/resolv.conf` and
  bypasses `.test` routing. Either disable Magic DNS, add `.test` as a split-DNS
  exception, or fall back to `external` mode.
- **Corporate VPN with DoH/strict DNS** — same shape as Tailscale; `external`
  mode skips the host resolver entirely and works through the VPN.
- **`.test` doesn't resolve after install** — run `boxa dns-status` to see
  whether dnsmasq is up, whether the per-OS resolver drop-in is in place, and
  whether a probe `getent hosts boxa-probe.test` returns `127.0.0.1`.

## See also

- [Firewall](firewall.md) — outbound egress control; remember to `boxa allow`
  any external host your app needs to reach.
- [Agent-browser](agent-browser.md) — dev URLs bypass the browser proxy.
