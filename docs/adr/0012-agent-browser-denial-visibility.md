# ADR 0012 — Agent-browser denial visibility and per-layer allow commands

- **Status:** accepted
- **Date:** 2026-05-22

## Context

Boxa has two independent network gates: the in-container firewall
(ADR 0001) and the host-side **Agent-browser proxy** (ADR 0010). Each
has its own `Allowlist` file and its own enforcement layer.

The firewall side has full CLI coverage: `boxa blocked` shows what
the in-container dnsmasq queried but failed to match against the
**Allowed-domains ipset**, with an interactive picker that adds the
selection to `~/.config/boxa/allowed-domains.conf`. `boxa allow
<domain>` and `boxa deny <domain>` round-trip the file.

The agent-browser side has none of that. The proxy daemon (slice 04 of
ADR 0010) already writes a JSONL log with one record per
CONNECT/HTTP-method decision —
`{ts, method, host, port, mode, decision, reason?}` — including
`decision: "deny"` for every default-mode rejection. Nothing reads it
from the CLI side. The only temporary unlock is `boxa agent-browser
allow-for N`, which puts the proxy into harvest mode (allow + log
**everything**) for a time window. There is no granular `agent-browser
allow <domain>`, so a user who sees the browser deny `api.openai.com`
in a tab has two options: edit `~/.config/boxa/agent-browser-allowed-domains.conf`
by hand and SIGHUP the proxy, or open the harvest-everything window.
Both are bad defaults — manual editing for one domain is friction;
opening everything for one domain is over-broad.

The recurring user flow:

> "Agent ran in a tab, hit several pages, came back empty. I don't know
> which hosts it tried that got denied. I want to see the list and pick
> the ones to permit."

The data to answer this exists in the proxy log; the surface to consume
it does not.

## Decision

### Surface — parallel namespaces with a unified entry point

- `boxa blocked` — **unified view** across both layers. Each row is
  prefixed with a tag: `[fw]` (firewall denial from dnsmasq query log)
  or `[browser]` (agent-browser proxy denial from `decision: "deny"`).
  A single multi-select picker; rows are routed back to **the layer
  that denied them** based on the tag. The first-option `* Allow all`
  splits into `* Allow all firewall` and `* Allow all browser`, each
  rendered only if its layer has rows. No "allow on both" option — when
  a domain genuinely needs both, the user invokes the explicit per-layer
  commands.
- `boxa agent-browser blocked` — narrow variant, agent-browser only,
  per-container resolution (CWD basename → `-p <name>` token →
  picker). Mirrors `boxa agent-browser allow-for` argument shape.
- `boxa agent-browser allow <domain>` / `... deny <domain>` /
  `... allow` (no arg, lists current entries) — mirrors the firewall
  `boxa allow` / `deny` shape. Writes to
  `~/.config/boxa/agent-browser-allowed-domains.conf` and SIGHUPs
  **every** running agent-browser proxy (the allowlist is shared across
  containers, so all live sessions must reload).

### Data source — "last session, live or archived"

The agent-browser proxy log is per-session, at
`/var/lib/boxa-agent/profiles/<session>/proxy.log` while the session
is live, archived to
`/var/log/boxa/agent-browser/<container>-<ISO>.proxy.log` at session
teardown.

The two surfaces consume different scopes (revised — see below):

- **`boxa agent-browser blocked`** (narrow, per-container) consumes the
  **last session, live or archived**: if a session is live, its live log;
  otherwise the most recent archived log (by ISO timestamp in filename).
  This is the retrospective "the agent ran, the session closed, let me
  review what it hit" entry point.
- **`boxa blocked`** (unified) consumes **live sessions only** for the
  browser portion — see the revision below.

There is **no time window** ("last 24h", etc.) on either path. Staleness
is filtered out instead by removing rows whose host is already in the
Allowlist (the user may have added them since the session ended).

### Revision — unified view is live-only (current-state semantics)

Originally the unified `boxa blocked` browser portion also read archived
logs (live ∪ archived, last session per container). In practice that made
the unified view accumulate denials from browser sessions that had closed
days earlier, which is jarring next to the firewall portion: the firewall
reads the in-container dnsmasq query log, and `boxa stop` `docker rm`s the
container, so firewall denials reset every run. The two halves of one view
behaved inconsistently — one reset on stop, the other lingered.

So the unified `boxa blocked` browser feed (`denied-hosts-global`) is now
scoped to **live agent-browser sessions only**, matching the firewall
side's current-state, resets-on-stop behaviour. Archived (closed-session)
denials remain fully reachable through the narrow `boxa agent-browser
blocked`, which keeps the live ∪ archived resolution above. The unified
view stays a "what's being blocked right now" surface; the narrow command
is the retrospective one.

### Multi-select header

The picker (`lib/picker.sh`) already accepts `--header`. Call sites for
both the firewall-only `blocked` (today) and the new unified
`blocked` pass a one-line legend describing tag meaning and multi-select
keybindings: `Tab/Shift-Tab to mark · Enter to confirm   (or "1,3,5"
without fzf)`. Closes a small standing usability gap on the existing
command.

## Considered options

- **Auto-route to "both layers" when picking from unified view.** Most
  picks are reactions to a specific layer's denial; auto-allowing on
  the other layer adds attack surface (a CDN denied at the browser
  proxy gets opened to in-container `curl` too) for no asked-for win.
  Rejected — explicit per-layer commands cover the genuine
  both-layers case without coupling.
- **Single `--browser` flag on `boxa allow` / `boxa blocked`** instead
  of a sub-tree. Considered. Rejected — breaks symmetry with the
  existing `boxa agent-browser allow-for` namespace; a future reader
  scanning `boxa agent-browser` sub-commands would not find `allow` /
  `deny` / `blocked` and would not know to look under the top-level
  `boxa allow --browser`.
- **Scan all archived proxy logs (not just last session).** Rejected
  — produces "blocked" entries from weeks-old sessions in unrelated
  contexts. Forensic browsing is what the per-session `summary.md`
  (slice 06 of ADR 0010) is for.
- **Time-windowed scan ("last 24h").** Rejected as an arbitrary cliff.
  "Last session" is a natural unit the user already thinks in.
- **Auto-glob on write** (`api.openai.com` picked → store as
  `*.openai.com`). Rejected — the proxy uses fnmatch and does **not**
  do implicit subdomain matching the way the firewall side does
  (asymmetry documented below). Auto-globbing would silently widen
  the allowlist beyond what the user picked. The user can write a
  glob explicitly via `boxa agent-browser allow '*.openai.com'`
  (quoted to suppress shell expansion). See the narrow apex↔www
  amendment under "Update 2026-05-22" below.

## Consequences

**Positive:**

- The agent-browser denial stream becomes visible through the same
  command the user already reaches for when something gets blocked.
- The agent-browser allowlist gets granular round-trip CLI matching
  the firewall side (`allow` / `deny` / `allow` no-arg list).
- SIGHUP-on-write means edits land in live proxies without restarting
  Chrome or any session.
- The shared allowlist file means one `agent-browser allow` propagates
  across all running containers' proxies automatically.
- Existing call sites of `lib/picker.sh` get a small UX win (legend
  header) for free.

**Negative:**

- **Subdomain semantics differ between layers.** Firewall `boxa allow
  example.com` matches `example.com` and all subdomains (dnsmasq
  `ipset=/.../` is inherently a subdomain match). Agent-browser `boxa
  agent-browser allow example.com` matches **only** `example.com`; for
  subdomains, write `'*.example.com'`. This is intrinsic to the two
  enforcement mechanisms and cannot be unified without sacrificing
  agent-browser's per-host explicitness. Documented in `--help`.
- One more JSON-shape coupling between proxy.py (slice 04) and the new
  blocked-reader code. If the proxy log schema changes, the reader
  breaks; mitigated by both living in the same repo and the schema
  being one-line-per-event JSONL (additive changes don't break
  consumers).
- The unified `boxa blocked` becomes a fan-out: it reads dnsmasq logs
  via `docker exec` AND scans host-side proxy log files. Latency grows
  with the number of running containers; acceptable for an interactive
  command but not for a tight loop.

## Future work

- "Allow on both layers" as an explicit picker action behind a modifier
  key (e.g. fzf `--bind` for Ctrl-B) if the manual two-command workflow
  proves annoying in practice.
- `boxa blocked --since <ISO>` for power users who want a wider
  archived-log scan; not in MVP, would re-open the time-window
  discussion deliberately rejected above.

## Update 2026-05-22 — apex↔www auto-pair on `allow`

Shipped after the ADR was accepted. `boxa agent-browser allow <domain>`
now writes the apex↔www counterpart alongside the user's input:

- `qr.cz` → also adds `www.qr.cz`
- `www.qr.cz` → also adds `qr.cz`
- `*.qr.cz` → unchanged (globs already span the pair)
- `localhost` (no dot) → unchanged (not a real domain)

This is a narrow, deterministic exception to the "Auto-glob on write"
rejection above. The rejected proposal added one wildcard pattern that
silently covered the entire `*.example.com` subtree; this amendment adds
exactly one literal entry — the other half of the apex↔www pair — and
nothing else. The motivation is the HSTS / 301-to-`www` redirect that
sends the user back through `blocked` for the same site (e.g. picking
`qr.cz` opens it once, Chrome retries `www.qr.cz`, picker fires again).

`deny` is **symmetric** — `deny X` also removes the apex↔www counterpart
when present, mirroring `allow X`'s pair-add. The earlier "literal +
hint" shape was changed once it shipped: the asymmetry between add
(pair) and remove (literal) was confusing and the principal failure
mode (user accidentally removes an unrelated counterpart) is rare
enough not to outweigh the symmetric mental model. Removal is
idempotent — silent when the counterpart is already absent.

The `blocked` picker collapses apex↔www pairs in its output: when both
hosts appear as denied for the same window, only the apex is shown.
Selecting it auto-pairs both, so the `www.` row would be a redundant
prompt. Implemented by `_collapse_www_pairs` applied after the existing
allowlist filter.
