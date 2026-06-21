# ADR 0008 — HTTPS for `.test` URLs via mkcert with graceful degradation

- **Status:** accepted (design done; implementation tracked in `local-plan-https-mkcert.md`)
- **Date:** 2026-05-13
- **Builds on:** ADR 0007 (route format, dual-host rule, `dns-install` UAC pattern), ADR 0005 (sanitized project naming → predictable cert filenames)
- **Resolves:** ADR 0007 § "Out of scope" → HTTPS for `.test` URLs

## Context

Modern browsers increasingly enforce secure-context requirements that
`http://<port>.<project>.test` cannot satisfy:

- Service Workers throw `DOMException: The operation is insecure` outside
  secure contexts. Browsers' built-in `localhost`/`127.0.0.1` exemption
  does **not** apply to `*.test` hostnames.
- `crypto.subtle` is gated on secure context.
- Firefox and Chrome **auto-upgrade certain subresource requests to HTTPS
  even on HTTP origin** (mixed-content upgrades). The user repeatedly hits
  `GET https://3000.<project>.test/favicon.svg NS_ERROR_CONNECTION_REFUSED`
  on an HTTP page because `:443` is unbound — browser disables for the
  origin happen anyway.

ADR 0007 deferred HTTPS "until a service forces it". That moment is here.

### Why Let's Encrypt is not a path

ADR 0007 § "Out of scope" suggested Let's Encrypt could cover the
`*.<port>.<project>.127.0.0.1.sslip.io` form. **This is incorrect** and is
corrected in this ADR:

- **HTTP-01 challenge:** the validator resolves `127.0.0.1` to its own
  loopback in AWS, not ours. Cannot reach our service. Fails.
- **DNS-01 challenge:** requires control over `sslip.io` zone, which we
  do not have.
- **`.test`:** RFC 2606 reserved, no public DNS authority exists. LE
  refuses on principle.

No public CA can issue a cert that browsers trust for any of our hostnames.
The only viable path is a **local Certificate Authority** installed into
the user's trust stores.

### Trust audience

Per `feedback_adr_0007_outsider_fabrication`, all reachable users of boxa
URLs are **local-machine boxa installs**. Traefik binds `127.0.0.1:80`
(and now `:443`), so no remote outsider can reach the URLs anyway. ADR
0007's "video-call colleague pastes URL" persona was fabricated and has
been removed.

Practical consequence: every browser that ever loads a boxa URL belongs
to a user who has run `boxa dns-install`. That is a UAC moment we
already own. Adding "install our root CA" to that same moment is
incremental, not new.

### Client surface that must trust the CA

| Client                                       | Trust store                                       |
|----------------------------------------------|---------------------------------------------------|
| Browser on Windows (Chrome / Edge / Brave)   | Windows `Cert:\LocalMachine\Root`                 |
| Browser on Windows (Firefox)                 | Firefox NSS DB (own store, separate from OS)      |
| Browser on macOS                             | macOS Keychain (System)                           |
| Browser on Linux native                      | Per-user NSS DB + system trust store              |
| `curl` / Node / Python on WSL2 host          | Linux NSS DB                                      |
| `curl` inside containers                     | **Out of scope** — container→host TLS not used   |

## Decision

Use **mkcert** to manage a local CA. Generate per-project leaf certs
covering all four URL SAN patterns. Configure Traefik with an HTTPS
entrypoint, static HTTP→HTTPS redirect, and per-project TLS dynamic
configs. Hook CA install into `boxa dns-install` (single extra UAC).
Migrate existing routes on `boxa update`. Support two-state graceful
degradation (`https_active=true|false`) so boxa always functions.

### One CA, per-project leaf certs (variant A)

A single mkcert root CA in `~/.local/share/mkcert/` (mkcert default).
Per-project leaf certs in `~/.config/boxa/traefik/certs/<project>.{pem,key,meta}`.

Rejected alternatives:

- **One big cert with all SANs across all projects** — regeneration on
  every project add/remove. Race conditions with running Traefik. Single
  point of corruption.
- **Per-port cert** — port is just a subdomain under `*.<project>.test`;
  one project-wildcard cert trivially covers all ports.
- **Reshape URLs to one-label-deep so `*.test` suffices** — would force a
  second migration of ADR 0007's stabilised URL format. Cost > benefit.

Per-project = 1:1 with concern (see `feedback_concern_based_naming`).
Adding a project: one new cert. Removing a project: delete three files.
No global state.

### Cert SAN list

Each project's cert covers **four SANs**, addressing RFC 6125's
single-label wildcard rule:

```
*.<project>.test
<project>.test
*.<project>.127.0.0.1.<external_provider>
<project>.127.0.0.1.<external_provider>
```

Both wildcard **and** bare entries because `*.foo.test` does **not** match
`foo.test` — wildcards require at least one label to consume.

Both `.test` and `sslip.io` (or whatever `external_provider` is) entries
in the same cert because ADR 0007's dual-host rule serves both
simultaneously regardless of active DNS mode. Mode switch never requires
cert regeneration.

`external_provider` change (rare; user edits `dns.conf`) triggers
auto-regeneration via `ensure_project_cert` meta-fingerprint check.

### Trust-store install — single UAC on Windows, native flows elsewhere

The CA install happens **exactly once per machine** during the first
`boxa dns-install` invocation that includes HTTPS. Leaf cert generation
**never requires UAC** — it is local file ops in user space, signed by
the already-installed CA.

**WSL2 (two-sided)**:

1. **Linux side:** `mkcert -install` writes the CA to the user-local NSS
   DB. No sudo.
2. **Windows side:** copy `rootCA.pem` to a `/mnt/c/...` staging path,
   then `powershell.exe Start-Process -Verb RunAs` runs a single
   PowerShell script:
   - `certutil.exe -addstore -f Root <path>` → Windows trust store
     (covers Chrome / Edge / Brave / native Windows clients)
   - Write `C:\Program Files\Mozilla Firefox\distribution\policies.json`
     with `{"policies":{"Certificates":{"ImportEnterpriseRoots":true}}}`
     → Firefox reads from Windows trust store instead of its own NSS

   One UAC prompt covers both. Skipped if Firefox not installed
   (`%ProgramFiles%\Mozilla Firefox` missing).

**macOS native:** `mkcert -install`. Handles System Keychain (TouchID or
sudo) and Firefox NSS via `nss` package. Single OS-native prompt.

**Linux native:** `mkcert -install`. Handles user NSS and system trust
store (sudo for `/usr/local/share/ca-certificates/`). Single sudo prompt.

WSL2 is the only platform requiring custom code because Windows is
upstream of the Linux distro and mkcert in Linux cannot reach Windows
trust stores. The other two platforms delegate fully to mkcert.

### Per-project leaf cert lifecycle

A new function `ensure_project_cert <project>` runs as **step 3** of the
per-project startup flow (after shared infra `bootstrap_traefik` /
`bootstrap_dns`, before launching the project container). Idempotent.

Trigger matrix:

| Situation                                            | Action                |
|------------------------------------------------------|-----------------------|
| Cert + meta missing                                  | Generate              |
| Both present, expiry > 10 days, meta matches state   | Noop                  |
| Cert expires in < 10 days                            | Regenerate + WARN     |
| Meta missing while cert exists (drift)               | Regenerate + WARN     |
| Meta `external_provider` ≠ current `dns.conf` value  | Regenerate + WARN     |
| Meta `ca_fingerprint` ≠ current mkcert CA            | Regenerate + WARN     |

The 10-day threshold (vs. mkcert's 825-day default cert validity) means
rotation runs roughly once every ~2.2 years per project — minimal IO,
minimal noise.

Meta file is shell-style sourceable, consistent with `dns.conf`:

```sh
# ~/.config/boxa/traefik/certs/<project>.meta
generated_at=2026-05-13T13:42:00Z
expires_at=2028-08-15T13:42:00Z
external_provider=sslip.io
ca_fingerprint=sha256:abc123...
san_list="*.<project>.test <project>.test *.<project>.127.0.0.1.sslip.io <project>.127.0.0.1.sslip.io"
mkcert_version=1.4.4
```

### Two-state graceful degradation

`~/.config/boxa/https.conf`:

```sh
active=true                                  # true | false
optout=false                                 # true → skip HTTPS prompts in future boxa update
ca_fingerprint=sha256:abc123...
mkcert_version=1.4.4
ca_installed_at=2026-05-13T14:22:00Z
ca_installed_platforms="linux windows-trust firefox-policy"
```

Separate from `dns.conf` per `feedback_concern_based_naming`. DNS and
HTTPS are different concerns: one routes hostnames → loopback, the other
issues trust + cert material.

| `active` | Traefik command                                                      | Route entryPoints      | `ensure_project_cert` |
|----------|----------------------------------------------------------------------|------------------------|-----------------------|
| `true`   | `web :80 + websecure :443 + redirect web→websecure permanent`        | `[websecure] + tls:{}` | runs                  |
| `false`  | `web :80` only, no redirect                                          | `[web]`                | skipped               |

Transitions via `boxa dns-install --enable-https | --disable-https`.
Both idempotent. Re-runs trust-install logic on `--enable-https`;
removes cert files and rewrites route YAMLs on `--disable-https`. Traefik
restarts at the end of either.

Boxa **always functions**. HTTPS is a bonus achievable layer.

### HTTP → HTTPS redirect at entrypoint level

Traefik static config when `active=true`:

```
--entrypoints.web.address=:80
--entrypoints.web.http.redirections.entryPoint.to=websecure
--entrypoints.web.http.redirections.entryPoint.scheme=https
--entrypoints.web.http.redirections.entryPoint.permanent=true
--entrypoints.websecure.address=:443
```

Single source of truth in `bootstrap_traefik`. No per-route middleware
labels needed; cannot accidentally leave one route un-redirected. Cannot
opt out per project — user explicitly requested redirect everywhere.

Accepted cost: `curl http://...` without `-L` sees `301`, not `200`.
Documented in README.

### Active migration on `boxa update`

Static redirect means existing routes with `entryPoints: [web]` will be
hit by 301 → `:443` → `websecure` lookup → **404** because the router
lists only `web`. Migration is therefore mandatory same-PR, qualifying as
break-fix per `feedback_active_migration_for_breakfix`.

Three migration components ship together:

1. **`apply_port_routes` template update** (`docker-run.sh`) — every
   subsequent `boxa` start writes the new HTTPS-aware route YAML when
   `https_active=true`, the old HTTP-only form otherwise.

2. **`scripts/migrate-routes-to-https.sh`** — active rewriter for
   running projects that have not been restarted since the update.
   Detects `entryPoints:.*web` in `dynamic/*.yml`, runs
   `ensure_project_cert <project>` for each, rewrites to
   `entryPoints: [websecure] + tls: {}`. Idempotent. Backups with
   `.pre-https-backup` suffix, kept indefinitely.

3. **Hook into `boxa update`**:
   - After image pull and existing migrations (sanitization, traefik.me)
   - If `https.conf` missing or `active=unset`: pre-prompt
     `Run HTTPS upgrade now? [Y/n]` — explains one Windows UAC. "n"
     writes `optout=true`; next `boxa update` skips silently.
   - On "y": run `dns-install --enable-https` (Linux mkcert install +
     Windows UAC) and `migrate-routes-to-https.sh --auto`.
   - Stop + remove + re-create `boxa_traefik` so static config
     changes (new entrypoint, new bind, new mount) take effect.
   - Print WARN banner with new URL format.

### Failure modes — fallback to HTTP-only, never block

Per ADR 0007's "no silent failures" stance and
`feedback_no_silent_failures`:

| Failure                                              | Effect                                                    |
|------------------------------------------------------|-----------------------------------------------------------|
| `mkcert` binary missing                              | `install.sh` fetches from GitHub releases, SHA-256 verify |
| UAC declined during `dns-install --enable-https`     | `optout=true`, WARN, HTTP-only continues                  |
| `certutil` errors out (corporate policy block)       | `active=false`, WARN, HTTP-only                           |
| Firefox not installed                                | Skip `policies.json` step; Win store still covers others  |
| Port 443 occupied (pre-flight)                       | `active=false`, WARN with offending PID, HTTP-only        |
| mkcert version too old                               | `install.sh` re-fetches                                   |
| CA expired (10-year horizon)                         | WARN; user runs `mkcert -uninstall && -install` manually  |

### Pre-flight 443 collision

Symmetric to existing `_boxa::port_80_held_by_other` in
`bootstrap_traefik`, but with **soft fallback**:

- Port 80 occupied → fatal exit (boxa cannot function without `:80`).
- Port 443 occupied → set `active=false`, WARN with PID+command from
  `ss -lntp`, continue HTTP-only. User can free `:443` and re-run
  `boxa dns-install --enable-https` to flip back on.

### `boxa port` / `boxa ports` output

Reflects `https_active` state, no flags:

- `active=true`: `https://3000.<project>.test`
- `active=false`: `http://3000.<project>.test`

No `--http`/`--https` flags — would confuse users (output `http://`
redirects to `https://` anyway under static flag).

### `boxa dns-status` extension

Display HTTPS state alongside DNS state:

- `https_active` true/false
- CA fingerprint (short form, first 12 chars)
- Trust stores covered (from `ca_installed_platforms`)
- Count of project certs in `certs/`
- Nearest expiry across all project certs

### CLI surface (minimal)

| Command                                  | Purpose                                                   |
|------------------------------------------|-----------------------------------------------------------|
| `boxa dns-install`                     | Existing; HTTPS phase added (interactive prompt for UAC)  |
| `boxa dns-install --enable-https`      | Force-enable HTTPS, idempotent                            |
| `boxa dns-install --disable-https`     | Force-disable HTTPS, idempotent                           |
| `boxa dns-status`                      | Existing; extended with HTTPS state                       |
| `boxa uninstall --purge-ca`            | Full cleanup; removes CA from trust stores (extra UAC)    |
| `boxa uninstall <project>`             | Existing; also deletes per-project cert files (no UAC)    |

**Deliberately NOT in MVP** per "don't design for hypothetical future
requirements":

- `boxa cert-rotate <project>` — `ensure_project_cert` rotates
  automatically; manual force-rotate is a niche need
- `boxa cert-status <project>` — `boxa dns-status` aggregates;
  per-project diagnostics surface only if real user need emerges

### Uninstall behavior

`boxa uninstall <project>` (single project): delete
`certs/<project>.{pem,key,meta}` + `dynamic/<project>-tls.yml` +
`dynamic/<container>-<port>.yml` (existing behavior, extended). **No
UAC.** CA stays trusted for remaining projects.

`boxa uninstall` (full boxa cleanup): interactive
`Remove local CA from system trust stores? [y/N]`, default `n`.
Non-interactive shells (CI / automation) take default `n`. `--purge-ca`
flag forces yes without prompt. Yes path triggers an extra UAC.

Rationale for default `n`: the mkcert CA may be shared with non-boxa
projects on the same machine. Default-preserve avoids accidentally
breaking unrelated mkcert setups. Power-user opt-in via `--purge-ca` or
manual `mkcert -uninstall`.

### Disk layout

```
~/.config/boxa/
├── dns.conf                             # existing
├── https.conf                           # NEW
├── dns/boxa.conf                      # existing
└── traefik/
    ├── dynamic/                         # existing (file provider root)
    │   ├── <container>-<port>.yml       # existing, updated to websecure+tls when active
    │   ├── <project>-tls.yml            # NEW, registers cert pair
    │   └── (no other files)
    └── certs/                           # NEW; sibling of dynamic/, NOT inside
        ├── <project>.pem
        ├── <project>-key.pem
        └── <project>.meta
```

Cert files **must not** live inside `dynamic/` because Traefik's file
provider recursively parses every file in its directory — `.pem` files
would emit parser errors on every Traefik start.

Traefik container gains a second bind-mount when HTTPS is active:
`-v ~/.config/boxa/traefik/certs:/etc/traefik/certs:ro`. Per-project
`<project>-tls.yml` references cert paths as
`/etc/traefik/certs/<project>.pem` (container-internal absolute path).

### mkcert install path

`install.sh` fetches mkcert from
`https://github.com/FiloSottile/mkcert/releases` (latest pinned version),
verifies SHA-256 against a known-good hash, drops the binary into
`~/.local/bin/mkcert`. User-local, no sudo.

mkcert is **host-side only**. The container image does **not** include
mkcert — apps inside containers receive plain HTTP from Traefik backend
and never terminate TLS.

### Bind interface

`127.0.0.1:443`, matching existing `127.0.0.1:80`. Loopback-only.
Consistent with ADR 0007's stance. Future LAN HTTPS mode would re-bind
to `0.0.0.0:443` opt-in.

### HSTS: deliberately not set

Traefik defaults emit no HSTS header. We do not add one.

HSTS in dev would create "stuck on HTTPS that no longer works" scenarios
when a user disables HTTPS (`--disable-https`) — the browser would refuse
HTTP redirects and force HTTPS even when our `:443` is unbound. Dev needs
the flexibility to flip modes freely.

## Out of scope (deliberately deferred)

- **Container-side cert trust** — apps inside containers receive plain
  HTTP from Traefik backend, never terminate TLS. Cert trust in container
  not needed today. Revisit only if a workflow demands intra-container
  HTTPS (e.g., testing HSTS, mTLS in dev).
- **LAN HTTPS access** — bind `0.0.0.0:443`, serve same certs to LAN
  devices, ship CA root install per device. Same architectural shape as
  ADR 0007's deferred LAN DNS mode.
- **Per-project HTTPS opt-out** — the static redirect is global. A future
  per-project escape would require switching to per-route redirect
  middleware. Defer until concrete need.
- **HSTS, OCSP stapling, key rotation** — production hardening concerns,
  not local dev.
- **Multiple CAs / cert pinning per project** — single mkcert CA covers
  all projects.

## Consequences

**Positive:**

- Service workers, `crypto.subtle`, mixed-content auto-upgrade, secure
  contexts all work natively. No browser flags, no
  `unsafely-treat-insecure-origin-as-secure`.
- One UAC prompt per machine in entire boxa lifetime (CA validity is
  10 years; per-project cert install requires zero UAC).
- Per-project cert lifecycle aligns 1:1 with project lifecycle. Adding
  or removing a project is local; no shared state to coordinate.
- Graceful degradation: any HTTPS failure (UAC declined, port 443 busy,
  mkcert error) downgrades to HTTP-only with a visible WARN.
  Boxa never breaks because of HTTPS.
- ADR 0007's URL format unchanged. Existing routing logic preserved.
  No URL migration burden on the user.
- Both `.test` and sslip.io URLs work over HTTPS for local users —
  the only audience that exists per
  `feedback_adr_0007_outsider_fabrication`.
- Pattern reusable: Linux→Windows UAC bridge established by ADR 0007's
  NRPT install is extended here for cert install. Future cross-platform
  features can reuse it.

**Negative:**

- One UAC prompt on first HTTPS-enabled install per machine.
  Acceptable; user has accepted the precedent for DNS install.
- Per-project cert occupies ~10 KiB on disk (3 files: pem, key, meta).
  Negligible per-project, manageable in aggregate.
- Active migration of existing route YAMLs on `boxa update` rewrites
  files. `.pre-https-backup` preserves originals.
- Traefik command-line grows by ~6 args when HTTPS active; bind-mount
  adds one `-v` flag and a `-p 127.0.0.1:443:443`. Readable, idempotent.
- mkcert becomes a new host-side dependency. `install.sh` fetches it;
  no manual user action required.
- Two-state `active` branching in `bootstrap_traefik`,
  `apply_port_routes`, `ensure_project_cert`. Acceptable — explicit
  branches readable; integration tests cover both states.

**Corrections to prior ADRs:**

- ADR 0007 § "Out of scope" claimed Let's Encrypt could mint certs for
  sslip.io URLs. Incorrect — see Context. This ADR is the authoritative
  source on HTTPS for boxa URLs.
- ADR 0007's "colleague on video call pastes URL" use case was
  fabricated during drafting and has been removed
  (`feedback_adr_0007_outsider_fabrication`). All sslip.io URL users
  are local-machine boxa installs with the CA trusted.

## References

- `lib/naming.sh:125` — `boxa::route_hosts`, source of cert SAN list
- `docker-run.sh:227` — `bootstrap_traefik`, target of HTTPS extension
- `docker-run.sh:418` — `apply_port_routes`, target of route YAML template update
- ADR 0007 — DNS layer, dual-host rule, URL format, `dns-install` UAC pattern
- ADR 0005 — sanitized project naming → predictable cert filenames
- `feedback_active_migration_for_breakfix` — why migration is mandatory same-PR
- `feedback_concern_based_naming` — why separate `https.conf` + per-project TLS yml
- `feedback_no_silent_failures` — WARN collector for rotation and fallback events
- `feedback_adr_0007_outsider_fabrication` — sslip.io fallback audience is local-only
- `feedback_bindmount_inode` — `https.conf` rewrites must be in-place (`cat > file`)
- RFC 6125 — DNS wildcard semantics in X.509 certs (single-label wildcards)
- RFC 2606 — `.test` reserved-for-testing TLD; no public CA can issue
- mkcert (`FiloSottile/mkcert`) — local CA tool, drives Linux + macOS install paths
- `local-plan-https-mkcert.md` — implementation plan with phase breakdown
