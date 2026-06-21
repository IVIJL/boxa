# ADR 0010 — Agent-browser via host broker and forward proxy

- **Status:** proposed
- **Date:** 2026-05-19

## Context

LLM agents working inside a boxa container increasingly need a real
browser — for taking screenshots of the project's dev URLs, reading
JS console errors and network failures, navigating documentation, and
testing UI changes against the running stack. We picked
[vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser)
as the CLI surface because it speaks CDP, has built-in policy hooks
(`--allowed-domains`, `--action-policy`, `--confirm-actions`,
`--allow-file-access` opt-in), and supports `--cdp <url>` to drive a
remote Chrome.

The hard question is **where Chrome runs** and **how the container
reaches it without breaking the boxa security model**:

- Chrome must be visible on the user's desktop (visual audit; the user
  watches what the agent does).
- Chrome must not be the user's personal Chrome (CDP has no auth and
  exposes cookies, history, extensions, downloads, native messaging —
  trivial compromise of all logged-in sessions).
- The container's default-deny firewall (ADR 0001) must not be silently
  bypassed: the agent must not gain unconstrained internet just because
  a browser was added.
- The design must work on Linux native, WSL2, and macOS without two
  parallel implementations.

CDP is "remote control over the browser process", not "a debug port".
Chrome 136+ enforces a non-default `--user-data-dir` for remote
debugging precisely because earlier versions were routinely exploited
to dump cookies. The threat model has to start from "anyone who reaches
CDP owns the Chrome process and the OS identity it runs as".

## Decision

Three new host-side actors, controlled by `boxa agent-browser ...`
commands, behind a two-layer time gate.

### Actor 1: Host agent Chrome

Launched by the host-side broker (`boxa agent-browser start`) under
a dedicated OS user `boxa-agent` (created idempotently at install).
The OS-identity separation is the primary defence against `file://`
reads of the developer's home directory, downloads to autostart paths,
and any other process-privilege-level attack — `--user-data-dir`
alone does not isolate process write perms.

Launch flags:

```
--remote-debugging-port=<random-port>
--remote-debugging-address=127.0.0.1
--user-data-dir=<ephemeral, session-scoped>
--proxy-server=http://127.0.0.1:<proxy-port>
--proxy-bypass-list="127.0.0.1;localhost;*.test;*.127.0.0.1.sslip.io"
--log-net-log=<session-scoped path>
--no-first-run --no-default-browser-check
--disable-sync --disable-extensions --disable-background-networking
--disable-component-update --disable-features=NativeMessaging,OptimizationHints,AutofillServerCommunication
--download-default-directory=<ephemeral, session-scoped>
```

CDP binds on host loopback only — never on a routable interface or
container bridge gateway. The browser window renders through the
native display stack on each platform (X11/Wayland on Linux native,
Quartz on macOS, WSLg on WSL2 — all transparent to Chrome).

#### Display access for the boxa-agent uid (amended 2026-06-08)

Because Host agent Chrome runs as `boxa-agent` — a different uid than
the logged-in developer — it cannot, on a native-Linux graphical
session, connect to the developer's X server by default. Wayland's
Xwayland (and any X server using `SI:localuser` per-uid authorization)
rejects the agent uid with *"Authorization required, but no
authorization protocol specified"* because it has no readable X cookie.

The original draft of this ADR implied provisioning a per-uid **X cookie**
(`xauth`) for `boxa-agent` (see the `host_platform` notes / Actor 1
launch env-forwarding `XAUTHORITY`). **That cookie-provisioning was never
built and is superseded here.** Instead, the broker — running as the
session user, who owns the X server — grants the agent uid display access
immediately before launching Chrome:

```
xhost +SI:localuser:boxa-agent
```

This is the minimal, per-uid, **display-only** grant (never blanket
`xhost +`, which would open the display to every local user). It runs on
**every** `start` (idempotent; re-applied each launch so it survives a
logout/login with no autostart entry) and **only** when a graphical
session is present (`$DISPLAY` set) — skipped without error otherwise.
The grant is logged visibly so this privileged step is auditable, never
silent. If the `xhost` tool is missing the broker fails with an
actionable install hint rather than launching into a guaranteed
authorization failure (tool provisioning is a separate install concern).

**Lifecycle invariant (amended 2026-06-08, round-7 review).** The grant
exists **iff at least one agent-browser session has a LIVE Chrome** (a
display consumer) running as `boxa-agent`. It is **revoked** (`xhost
-SI:localuser:boxa-agent`) the moment the **last display-consuming
session goes away** — whether that session ends via a clean `stop`, a
Chrome-death watchdog stop, a failed-launch **rollback**, or a `set -e`
abort during `start` setup. A stopped or failed session leaves no
lingering authorization for `boxa-agent` on the developer's display.

Because the grant is keyed on the boxa-agent **uid** (not per session)
and the user routinely runs several containers (and thus several sessions)
at once — all sharing that single per-uid grant — the revoke is
**reference-counted**: it fires only when no OTHER session is still a
**display consumer**, so tearing one session down never pulls display
access out from under another live session's Chrome.

**Reference counting is PER-DISPLAY (amended 2026-06-08, review finding).**
`xhost +SI:localuser:boxa-agent` authorizes the uid on a *specific* X
display, AND the grant is keyed on `(uid, display)`. The reference count is
therefore **scoped to the display being revoked**: when deciding whether to
revoke the grant on display **D**, the broker counts only OTHER sessions whose
persisted `granted_display == D`, and revokes D iff no other live
display-consumer session is using D. Each display is **independently**
reference-counted — the grant on D is revoked exactly when D's own last
consumer goes away. Concretely: `_state_file_is_display_consumer` and
`_count_other_live_sessions` take an optional `target_display` filter, and
`_revoke_x_display_if_last_session` first resolves WHICH display it is revoking
(the torn-down session's persisted `granted_display`) and then counts peers ON
THAT DISPLAY only. A session on a **different** display neither **blocks** the
revoke of D (the earlier unscoped count made a `:1` session keep `:0`
authorized) nor is **affected** by it (so revoking `:1` no longer leaves
`boxa-agent` permanently authorized on `:0`). Sessions with a null/absent
`granted_display` (non-graphical, never granted) are consumers on no display.

**Revoke targets a PERSISTED display, not the ambient `$DISPLAY` (amended
2026-06-08, #12 review finding 1).** `stop` frequently runs *without*
`$DISPLAY` in its environment — the detached Chrome-death watchdog, the
container-stop closeout, or an SSH / other-terminal invocation. The earlier
revoke gated on the *teardown process's own* `$DISPLAY`, so those common
paths returned early and **leaked** the grant indefinitely. The fix: `start`
**persists the display it granted on** into the session-state JSON as
`granted_display`, and every teardown revokes against **that** value —
`DISPLAY=<granted_display> xhost -SI:localuser:boxa-agent` — regardless of
the ambient env. The revoke gate is now "a persisted `granted_display` exists
for this session" (+ native Linux + `xhost` present), **not** "current
`$DISPLAY` is set". A session that never granted (a non-graphical start with
no `$DISPLAY`) records `granted_display: null`, so its revoke is a clean
no-op. The GRANT path still legitimately requires a live `$DISPLAY` (you
cannot grant without one); only the REVOKE became env-independent. `cmd_stop`
captures `granted_display` from the file *before* any teardown step rewrites
or removes it; the consolidated failed-start cleanup carries it in
`_CFS_GRANTED_DISPLAY` (captured at grant time) so the EXIT-trap path revokes
correctly even when fired from a context that has already lost `$DISPLAY`.

**An in-progress display claim is written BEFORE the grant (amended
2026-06-08, #12 review finding 2).** The user routinely runs several
containers concurrently. Between one start's grant and its first full
state-file write, a concurrently-starting sibling was previously **invisible**
to the reference count (`_count_other_live_sessions` saw only completed
session JSON). So if container A granted, and container B then started and
**failed** before A wrote its state, B's rollback counted zero peers and
**revoked the shared grant while A still needed it** — A's Chrome launch then
failed intermittently. The fix unifies with finding 1: `cmd_start` writes the
session state file **early — at the very start, before the grant** — as a
`status: "starting"` claim carrying the `granted_display` and null PIDs.
`_state_file_is_display_consumer` counts a `starting` claim (or any state with
a non-null `granted_display` and not-yet-populated `chrome_pid`) as a
consumer, so a concurrent sibling sees the in-progress start immediately and
its revoke-if-last refuses. The same early write **persists** `granted_display`
for finding 1. `cmd_start` then progressively overwrites this one file (the
ufw crash-window marker, then the full session state) as resources come up —
each writer carries `granted_display` forward — preserving the round-3/4
recovery-marker semantics (live PIDs, ufw `pending`→`owned` promotion) and the
round-7 `ufw_retry_only`/null-chrome teardown marker (which, when present,
overrides any stale `starting`/`granted_display` so a torn-down session is
**not** counted).

The in-progress `starting` claim **records the broker PID** (`starting_pid`,
the `cmd_start` process that owns the start through to the full-state write)
**together with that PID's start time** (`starting_pid_starttime`, field 22 of
`/proc/<pid>/stat`, amended 2026-06-09, #12 review P2) and is counted as a
display consumer **only while that PID is alive *and* still that same process**:
the `_starting_pid_is_live` guard (shared by the consumer predicate and
`_sweep_if_stale`) requires both a live PID and a matching recorded start time,
so a PID **reused** by an unrelated process after a crash/reboot — alive but
with a different start time — is correctly treated as **abandoned**, not as a
live start (a bare liveness check was PID-reuse-unsafe and would pin the grant
forever). A recorded start time that is absent (an older claim) falls back to
bare liveness. A live broker is a genuine in-progress start whose grant must be
protected, while a broker killed mid-start leaves an
**abandoned** claim whose dead `starting_pid` makes it **not** a consumer — and
`_sweep_if_stale` reclaims it (removing the file and revoking the grant
if-last) exactly like a crashed full session. So an interrupted start cannot
permanently pin the shared grant: the last real session's stop on that display
still revokes it. Once the file is overwritten with full state (status no
longer `starting`) the `starting_pid` gate no longer applies — an established
session is validated by its live `chrome_pid`, never mis-expired.

Two further refinements make the reference count correct in the awkward cases
the round-6 fix left open:

  1. **Display-consumer ≠ bare state-file presence.** A session whose
     Chrome has been torn down but whose **state file is RETAINED only so
     the next `start`'s sweep can retry a deferred `sudo ufw delete`** is
     **not** a display consumer and must not keep the grant alive. `stop`
     (and the start-rollback path) mark such a retained file
     Chrome-torn-down — nulled `chrome_pid`/`proxy_pid` plus an explicit
     `ufw_retry_only: true` marker — and the reference count
     (`_count_other_live_sessions` → `_state_file_is_display_consumer`)
     **excludes** files so marked. The ufw-retry reclamation logic is
     unchanged (the sweep still deletes the rule on the next start); only
     the X-grant counting changed.

  2. **X-revoke is DECOUPLED from the ufw-retain decision.** In `stop`,
     Chrome is always torn down before the ufw release is attempted, so
     the revoke-if-last runs **regardless** of whether the ufw rule cleanup
     succeeded or was deferred. The ufw-retain decision governs only
     whether the STATE FILE is kept for retry; it no longer blocks X
     revocation (the round-6 hole: revoke was skipped whenever any file was
     retained, leaving `boxa-agent` authorized indefinitely — common when
     the detached watchdog runs `stop` after the developer's sudo timestamp
     has expired and the `ufw delete` cannot authenticate).

**Three further hardenings complete the grant lifecycle (amended 2026-06-08,
#12 review round-9).** The persisted-display + early-claim machinery above
removed the env-dependence and the concurrent-start visibility gap, but three
correctness holes remained — closed together as one pass that brings the X slot
to the same maturity the host ufw slot already has (serialized, liveness-aware,
ownership-tracked):

  (a) **Grant/revoke critical sections are SERIALIZED with a host flock.**
      Writing the early claim before granting does **not** by itself close the
      check-to-revoke race: a teardown could compute `others == 0`, **then** a
      concurrent start writes its claim and runs `xhost +SI`, **then** the
      teardown runs `xhost -SI` — revoking a grant the new session needs. Both
      critical sections now run under one shared exclusive lock
      (`$SESSIONS_DIR/.xhost-grant.lock`, `flock -x` on a subshell-scoped fd 9
      via `_with_xhost_grant_lock`): the START side `{ claim-write + ownership
      check + xhost +SI }` and the TEARDOWN side `{ count + decide + xhost -SI +
      clear ownership marker }`. With both mutually exclusive, a teardown either
      **sees** the new claim (`others >= 1` → no revoke) or **completes its
      revoke before** the new start grants (the new start then re-grants under
      the lock — correct). The locked region is deliberately small — no Chrome
      launch / `docker exec` inside it — and the lock releases on **every** exit
      path (the subshell closing fd 9, including on `_die`/signal). `flock`
      lives in util-linux and is virtually always present; if it is **missing**
      the broker warns once and falls back to the (pre-finding) lock-free
      behaviour rather than hard-crashing a teardown.

  (b) **Consumer counting validates Chrome LIVENESS** (not just a non-null
      `chrome_pid`). A crashed Chrome+watchdog, or a stale state file surviving
      a reboot, would otherwise keep counting as a consumer and pin the shared
      grant forever. `_state_file_is_display_consumer` now additionally requires
      a file claiming a *running* chrome to pass the broker's own liveness check
      — `_pid_matches_marker` against the unique `--user-data-dir=<profile_dir>`
      marker, exactly the predicate `_sweep_if_stale` uses — so a dead/recycled
      PID is **not** counted. A `status: "starting"` claim (chrome not launched
      yet) still counts without a live PID; `ufw_retry_only`/torn-down files
      still do not.

  (c) **A per-DISPLAY broker-OWNERSHIP marker prevents revoking a pre-existing
      authorization.** If `boxa-agent` was *already* authorized on the display
      before the broker's first grant (idempotent `xhost +SI` cannot tell), the
      final stop must not remove an authorization the broker did not add — the
      X analog of the ufw `pending`→`owned` ownership fix. At grant time, under
      the lock, the broker queries the X access list (`DISPLAY=<d> xhost`, no
      args) and creates a per-display marker
      (`$SESSIONS_DIR/xhost-owned-<sanitized-display>`) **only** when
      boxa-agent is **not** yet authorized — i.e. when the broker is the one
      adding the grant. The last-consumer revoke runs `xhost -SI` **only** when
      that marker exists, then deletes it; if the marker is absent (pre-existing
      authorization), the broker **never** revokes. The display string is
      sanitized for the filename (`:0`→`0`, `:1.0`→`1.0`, `host:0`→`host_0`; no
      path-traversal / shell-special chars). If the access-list query itself
      fails, the broker takes the **safe default** — treat as pre-existing, no
      marker, no revoke, with a visible warning — so it never removes
      authorization it cannot prove it added. The ownership marker is a disk file
      whose lifetime is *longer* than the X-server-session-scoped grant it
      records, so on the **already-authorized** path the marker is *revalidated*
      against an **X-server-session token** — **not** by a live-consumer count.
      Each marker is **stamped at create time** with a best-effort token
      (`_x_session_token`: the kernel boot id plus the display's X-socket
      inode/mtime, `/tmp/.X11-unix/X<n>`), an identifier that changes when the X
      server — including Xwayland — restarts or the host reboots. On the
      already-authorized path the broker compares the marker's stored token to the
      *current* X-session token: a **mismatch** means the marker is from a **prior
      X server** (its grant was cleared by the reset/reboot) → **stale** →
      **cleared** (logged visibly), so teardown treats the authorization as
      pre-existing and never revokes the user's grant; a **match** means the marker
      belongs to **this** X session and is a **live broker-owned grant** — kept
      *regardless of consumer count*, because a grant **retained after a failed
      `xhost -SI` revoke** (round 11) has **zero** current consumers yet is still
      active. (An earlier consumer-count heuristic *deleted* exactly that retained
      marker, so the next teardown could never revoke it → the grant leaked
      indefinitely; the token comparison fixes that regression.) If the marker
      carries **no token** (created before this change) or the current token is
      **underivable** (an exotic remote / SSH-forwarded / socket-less display),
      ownership **cannot be verified** → the broker **DROPS** the marker (amended
      2026-06-09, #12 review — see the *keep-vs-drop-on-uncertainty resolution*
      below, which supersedes the earlier keep-on-uncertainty default).

**Two lifecycle-consistency gaps closed (amended 2026-06-09, #12 review).**

  - **A claim-write failure ABORTS the start before granting.** The early
    starting-claim is the round-8 concurrent-start protection and the only record
    that carries `granted_display`/`starting_pid` forward to teardown. The locked
    claim→grant region runs under the caller's `|| exit 1`, which **suppresses
    `set -e`**, so a failed `_write_starting_claim` (disk full, unwritable state
    dir) would silently proceed to grant the X display and launch with no claim to
    protect a sibling start and no state to revoke against. `_write_starting_claim`
    now returns non-zero when its `cat > file` redirect fails, and
    `_start_x_claim_and_grant_locked` checks that rc **explicitly**
    (`|| return 1`), emits a clear error naming the unwritable state dir, and runs
    the X grant **only after** a successful claim write. The call site's
    `|| exit 1` then fires the EXIT trap → `_cleanup_failed_start`, which no-ops
    because nothing was granted.

  - **A failed X-grant REVOKE retains the session STATE FILE, not just the
    marker (symmetric with the ufw retain).** Round 11 retains the ownership
    *marker* when `xhost -SI` fails (e.g. a `stop` over SSH with no usable X
    authorization), but `stop` had already deleted the *state file* that holds the
    original `granted_display` — so a repeated `stop` was a no-op (no state to
    read) and could never retry, leaving `boxa-agent` authorized indefinitely.
    `_revoke_agent_x_display_access` now SIGNALS the distinct outcome: rc **2** iff
    the actual `xhost -SI` it attempted FAILED, vs rc 0 for every no-op path
    (nothing to revoke / no marker / not last consumer / xhost absent / not Linux),
    none of which need retention. `_revoke_x_display_if_last_session` propagates
    that rc verbatim. `cmd_stop`, `_cleanup_failed_start`, and `_sweep_if_stale`
    each read it and, on rc 2, **retain the state file** (marked Chrome-torn-down /
    `ufw_retry_only` so it is **not** counted as a live display consumer and does
    not pin the grant for other sessions' revoke decisions) with a visible
    "retaining session state; will retry X revoke on next stop/sweep" warning —
    combined with the ufw-retain condition so the file is kept when **either** the
    ufw release **or** the X revoke failed (both retries need it). The next
    `stop`/`sweep` re-reads `granted_display` and retries; round-16's X-session
    token on the marker keeps the retry safe — if the X session changed meanwhile,
    the stale marker is cleared on the next grant rather than wrongly revoked.

**DISPLAY canonicalization keys on X-SERVER IDENTITY via the local-socket
existence (amended 2026-06-09, #12 review — supersedes the earlier
"host-form decides" wording).** An xhost grant authorizes a uid on an X
*server*, not on a particular *screen* or *transport* — the `.screennumber`
suffix of a DISPLAY (`[host]:displaynumber[.screennumber]`) is irrelevant to
authorization, and the ACL is **server-wide**: `:0` (Unix socket) and
`localhost:0` (TCP) that reach the **same** X server share **one**
authorization. So for the reference count, ownership marker, and every
comparison, **all aliases that reach one server must collapse to one key** —
otherwise stopping `:0` would revoke while a still-running `localhost:0` needs
the grant. The server-identity discriminator is the **existence of the local X
socket `/tmp/.X11-unix/X<n>`**: when a local server is listening on display N,
`:N`, `unix:N`, `localhost:N`, and `<own-hostname>:N` **all** reach it. The
per-display reference count, the ownership-marker filename, and every display
comparison previously keyed off the EXACT STRING, so two sessions using
different aliases for one X server were treated as different displays — stopping
either saw no peer on "its" display string and ran `xhost -SI`, revoking access
the surviving Chrome still needed. `_canonical_display` now reduces a DISPLAY to
**one key per X server**:

- **Resolves to the local server on N** — `:N` / `unix:N` (always local-unix by
  X convention), **and** `localhost:N` / `<own-hostname>:N` **when**
  `/tmp/.X11-unix/X<n>` **exists** — drops both the host part and the
  `.screennumber`, yielding the bare `:displaynumber` (`:0` / `unix:0` /
  `localhost:0`-with-`X0` → all `:0`). These share **one** marker + refcount.
- **Does not resolve to a local server** keeps `host:displaynumber` (dropping
  only the screen suffix). This preserves **SSH X11-forwarding correctness**:
  SSH hands out `localhost:10.0` over an sshd TCP proxy with **no**
  `/tmp/.X11-unix/X10` socket, so it does **not** reach a local server on 10 and
  stays `localhost:10` (a DIFFERENT key from `:10`) — collapsing it would make
  teardown target the wrong transport, fail to revoke, and retain state. A
  **genuinely foreign** remote `host:N` is a different machine's server and
  **never** collapses, regardless of any local `X<n>` socket (the local socket,
  even if present, is a different server).

A value that does not match the `…:N[.M]` shape is returned unchanged. The
local-socket server-identity decision is made by a single shared probe,
`_display_resolves_to_local_server`, used by **both** `_canonical_display` and
`_x_session_token`, so the canonical key and the X-socket identity never
diverge: a display that canonicalizes to a bare `:N` (socket exists + host is
local-ish) yields the real socket-backed token, while one that keeps a
transport-specific form (socket-less SSH `localhost:10`, a remote host) yields
the UNKNOWN sentinel. So a socket-backed `localhost:0` and `:0` share marker /
refcount / token end-to-end, while SSH-forwarded `localhost:10` keeps its own.
Canonicalization is applied at every point of use: the persisted
`granted_display` is **stored canonical**, the ownership-marker path
(`_xhost_ownership_marker_path`) **derives from the canonical display** so all
same-server aliases of `:0` map to the SAME marker file + refcount, and the
per-display refcount comparison (`_state_file_is_display_consumer`)
canonicalizes **both sides** — so an older non-canonical persisted value
normalizes and matches too. The revoke still runs `DISPLAY=<persisted> xhost
-SI` against the now-canonical value.

**The already-authorized ACL check matches the EXACT `SI:localuser:boxa-agent`
token (amended 2026-06-09, #12 review).** `_xhost_agent_already_authorized`
previously substring-grepped the no-arg `xhost` access-list for `boxa-agent`,
so an unrelated entry like `SI:localuser:boxa-agent2` would substring-match →
the broker wrongly concluded the real `boxa-agent` was already authorized and
**skipped** both the ownership marker and the required `xhost +SI` grant, failing
Chrome startup. It now trims each access-list line and compares the WHOLE token
for equality against `SI:localuser:boxa-agent` (case-insensitive), so only the
exact entry counts as authorized and a longer-username entry no longer
false-matches.

**The grant FAILS CLOSED when ownership cannot be queried (amended 2026-06-09,
#12 review P2).** The earlier "access-list query failed → safe default: treat as
pre-existing, no marker, no revoke" path still **proceeded to `xhost +SI`**. If
that grant then SUCCEEDED, teardown later found a grant with **no ownership
marker**, treated it as pre-existing, and **never** revoked it — `boxa-agent`
stayed authorized until the X server reset (a leak). The broker now **refuses to
grant** when it cannot determine/track ownership: on the query-failed (`rc 2`)
path `_grant_agent_x_display_access` emits a clear error ("could not query X
access control list … refusing to grant to avoid an untracked authorization that
teardown could not revoke") and returns non-zero **before** running `xhost +SI`.
Inside the locked claim→grant region this propagates via the caller's
`|| exit 1` → EXIT trap → `_cleanup_failed_start`; since the grant never ran,
cleanup no-ops the un-allocated X resource and the starting claim is reclaimed as
usual. The same fail-closed discipline now also covers the **rc 1**
(not-authorized → broker adds the grant) path: the ownership marker is written
**before** `xhost +SI`, **atomically** (temp + `mv`) so a failed write leaves no
half-written marker, and if the marker write fails the broker emits a clear error
("could not write X-grant ownership marker for `<display>` … refusing to grant to
avoid an untracked authorization that teardown could not revoke") and returns
non-zero **before** granting — a successful grant with no ownership record would
otherwise be treated as pre-existing by every teardown and **never** revoked
(leak). Conversely, if the marker write succeeds but the subsequent `xhost +SI`
**fails**, the just-written marker is **removed** before the failure propagates,
so no stale marker is left for a grant that never took. The `rc 0`
(already-authorized, token-revalidated) path is unchanged.

**The X-session token is LOCAL-SERVER only; non-local displays get an UNKNOWN
sentinel (amended 2026-06-09, #12 review).** `_x_session_token` previously
emitted a **boot-id-only** token whenever the display's X socket was unreadable
(including for remote displays). The boot id is **stable across X-server
restarts**, so a stale ownership marker stamped with a boot-id-only token would
**false-match** the current boot-id-only token after an X restart → kept as
"current" → teardown would then revoke a now-pre-existing **USER** grant. A
remote display like `host:0` also wrongly read the **unrelated local**
`/tmp/.X11-unix/X0` socket — a different X server entirely. The token is now
derived via the **same shared `_display_resolves_to_local_server` probe** as
canonicalization: for a display that resolves to the local server on N (the
existing `/tmp/.X11-unix/X<n>` socket — `:N` / `unix:N` always, and
`localhost:N` / `<own-hostname>:N` when that socket exists) it combines the
**canonical** display number's X-socket inode:mtime with the boot id. A display
that does **not** resolve to a local server (SSH-forwarded socket-less
`localhost:N`, a remote `host:N`), OR a bare `:N`/`unix:N` whose socket is
**missing/unreadable**, returns a distinct **UNKNOWN sentinel** (empty token):
it does **not** fall back to a boot-id-only token (no false cross-restart
equality) and does **not** read the wrong local socket. Because canonicalization
and the token share one probe, a socket-backed `localhost:0` derives the **same**
real token as `:0`, so the common multi-alias local case is fully verifiable.

**Keep-vs-drop-on-uncertainty resolution — unverifiable ownership markers are
DROPPED on the already-authorized path (amended 2026-06-09, #12 review; this is
the FINAL decision and supersedes the earlier keep-on-uncertainty wording).** On
the already-authorized (rc 0) branch the broker reconciles a surviving marker
against the current X-session token in exactly three arms:

- **Both tokens present and they MATCH** → verified broker ownership (incl. the
  round-11 retained-after-failed-revoke grant) → **KEEP**.
- **Both tokens present and they DIFFER** → stale (prior X server / reboot) →
  **CLEAR** (logged).
- **Either token UNAVAILABLE/empty** (a legacy tokenless marker, OR a
  TCP/remote/SSH-forwarded display where `_x_session_token` intentionally
  returns the UNKNOWN sentinel) → ownership **cannot be verified** → **DROP** the
  marker (logged: *"clearing unverifiable X-grant ownership marker … cannot
  prove broker ownership"*).

The rationale: **the broker must never revoke an authorization it cannot prove
it created.** A marker can outlive an X-server reset while the *current*
authorization was added independently by the user; if the broker retained that
unverifiable marker, teardown would treat it as broker ownership and revoke the
**user's** pre-existing grant. An unverifiable marker is therefore *more*
dangerous than the benign residual that dropping it accepts. **Accepted, FINAL
residual:** on exotic TCP / remote / SSH-forwarded displays the broker may then
**fail to revoke its OWN grant** — a benign leak for the dedicated,
low-privilege `boxa-agent` service account, which exists *only* for
agent-browser. With the socket-existence probe above, local displays now almost
always derive a non-empty token, so the unverifiable case shrinks to genuinely
exotic displays. This **reverses** the earlier rounds' keep-on-uncertainty
default (the keep choice would, in the worst case, revoke a user's grant — the
worse failure); it is recorded here so the keep-vs-drop question is not
re-litigated. agent-browser's host Chrome is fundamentally a **LOCAL-display**
feature; remote / forwarded X is exotic here.

**`cmd_stop` refuses to tear down a LIVE in-progress starting claim (amended
2026-06-09, #12 review P2), mirroring the sweep guard.** `_sweep_if_stale`
already refuses to reclaim a `status:"starting"` claim whose `starting_pid` is
live and identity-matched (round 14/16) — a broker mid-start is not swept. But
`cmd_stop` did not apply that guard: a `stop` invoked while a `status:"starting"`
claim belonged to a LIVE broker (the original `start` still launching Chrome,
about to rewrite full state) would tear the claim down and could revoke the X
grant **under** the running start, leaving the launch failing or holding
resources the stop caller believed removed. `cmd_stop` now applies the SAME
guard via the shared `_starting_pid_is_live <pid> <starttime>` helper: a
`status:"starting"` target with a LIVE, identity-matched `starting_pid` is
**refused** (clear "a start is in progress … retry once it has started, or it
will be cleaned up automatically if the start fails" message) and returns
without revoking or deleting — the in-progress start owns its own EXIT-trap
cleanup (round 7), so refusing orphans nothing. A DEAD/abandoned `starting_pid`
(or any non-`starting` established session) falls through to normal teardown,
unchanged; the guard runs after the missing-session picker so an explicit stop
of a real running session is unaffected.

**The grant→session-established window is trap-covered.** `cmd_start`
grants the display before a long run of `set -e` steps (privileged dir
setup, proxy staging, port allocation, Chrome/relay/bridge launch). Any of
those can exit without reaching an explicit rollback branch. To make every
abort path converge to the same correct end state, `cmd_start` arms an
**EXIT trap** on a single idempotent `_cleanup_failed_start` right **at**
the grant, and disarms it (`trap - EXIT`) only on a fully-established
session. That one function closes the container-side slot, releases-or-
retains the host ufw slot (marking the retained file Chrome-torn-down),
kills the launched proxy/relay/Chrome, **terminates the in-container bridge
socat**, removes the session dirs, and revokes the X grant if this was the
last display consumer. The explicit
rollback branches funnel through the **same** function; a run-once guard
plus per-step idempotency (`xhost -SI`, `ufw delete` of a missing rule,
`rm -f`, `kill` of a dead pid) means an explicit branch followed by the
trap-on-`exit` never double-revokes or double-closes. The CDP-smoke-test
rollback delegates to `cmd_stop` and disarms the trap first so `cmd_stop`
remains the single owner of that path.

**Failed-start cleanup terminates the in-container bridge (amended
2026-06-08, review finding).** The bridge socat runs *inside* the target
container (`docker exec -d`, listening on `127.0.0.1:9222`). Earlier,
`_cleanup_failed_start` killed only HOST-side processes, so a `set -e` abort
after the bridge launch but before the full state file was written left socat
**orphaned** bound to `127.0.0.1:9222` inside the container — and because the
marker was then removed, no later sweep could reclaim it, so subsequent starts
failed (port already bound). `cmd_start` now **tracks the bridge PID** in the
`_CFS_*` vars (`_CFS_BRIDGE_PID_IN_CONTAINER`) the instant it is read back from
the `docker exec -d` launch, and the cleanup **kills it via the SAME
in-container kill path** (`_kill_bridge_in_container` → `docker exec
<container> kill <pid>`) that `cmd_stop`/the sweep use — no second mechanism.
The kill no-ops when the bridge was never started (PID unset) and **warns
(never aborts)** when the container has already vanished. The full state write
on the success path still persists `bridge_pid_in_container` so the sweep can
reclaim it normally; the trap-side kill is what guarantees nothing is orphaned
even when the marker file is removed.

The revoke mirrors the grant's gates (Linux-native via
`host_platform::detect` + `$DISPLAY` set); a missing `xhost` at teardown
**warns and no-ops** rather than aborting cleanup or `_die`-ing, and
`xhost -SI` is idempotent so a redundant revoke is harmless.

Gating is Linux-native only via `host_platform::detect`: macOS uses
Quartz (no `xhost`), and WSL2's WSLg exposes world-readable
Wayland/Xwayland sockets that `boxa-agent` can already use without a
grant. Chrome still launches as `boxa-agent`; filesystem isolation
from the developer's home and personal Chrome profile is **unchanged** —
only an X display connection is granted.

**Honest caveat — X11 is a weak boundary.** Once the agent uid is
authorized on the developer's X server, X11 offers little isolation
*between clients on that same server*: the agent uid could enumerate
other windows, read their contents, synthesize input, or grab the
keyboard on that display. This is an accepted trade-off for the MVP
(the same display the developer is already watching for the visual
audit). Hard isolation between the agent's Chrome and the developer's
other X clients would require giving the agent its own **dedicated
headless Xwayland** — see Future work.

### Actor 2: Agent-browser session bridge

A socat process started by the broker via `docker exec -d` into the
target outer container, listening on `127.0.0.1:9222` inside the
container and forwarding to `host.docker.internal:<random-port>`.

The container's network namespace is the security boundary: socat sits
inside it, so other containers and other host processes cannot reach
that socket. socat itself enforces nothing — it is transport. This is
deliberate; using a host-side iptables/pf ACL as the boundary would
have required two firewall implementations (iptables for Linux/WSL2,
pf for macOS), neither of which can be expressed identically and both
of which add maintenance surface. The netns boundary is free and
already trusted as part of Docker's isolation.

Inside the container, the agent-browser CLI always sees a single
endpoint: `AGENT_BROWSER_CDP_URL=ws://127.0.0.1:9222/...`. Platform
differences are entirely on the host side.

#### Container-side firewall slot (Docker Desktop)

The default-deny OUTPUT chain (ADR 0001) only accepts traffic to
`172.18.0.0/24` (the Docker bridge subnet) and the DNS-driven
allowed-domains ipset. On Docker Desktop (WSL2, macOS),
`host.docker.internal` resolves to a magic IP (typically
`192.168.65.254`) outside both — the in-container socat above would
hit "No route to host" (ICMP admin-prohibited rendered as
`EHOSTUNREACH`) and the CDP smoke test would roll the session back.

The broker opens a session-scoped exception that mirrors the
`allow-for` window pattern (ADR 0009, `start-allow-for-window.sh`):
`start-agent-browser-host-allow <IP> <PORT>` runs in the container via
`docker exec -u root` — no NOPASSWD sudoers added (ADR 0003) — and
inserts `ACCEPT -p tcp -d <IP> --dport <PORT>` immediately before the
final OUTPUT REJECT. Scoping to a single TCP port (the per-session
random CDP port) keeps the firewall hole as narrow as the bridge
actually needs — arbitrary host services on the same magic IP remain
firewalled for the duration of the session. `cmd_stop` and every
rollback path in `cmd_start` close the slot via the matching
`stop-agent-browser-host-allow` helper.

The IP is resolved with `getent ahostsv4 host.docker.internal` (not
`getent hosts`): Docker Desktop on WSL2 returns a dual-stack record,
glibc per RFC 6724 picks IPv6 first, but Docker Desktop only forwards
the IPv4 magic IP and the helper validates dotted IPv4. Forcing v4
here keeps the three consumers — host relay bind, firewall ACCEPT,
in-container `TCP4:` socat upstream — pinned to the same address.

On native Linux + Docker CE the resolved IP is the Docker bridge
gateway, already inside the pre-existing `ACCEPT -d 172.18.0.0/24`
rule — the session-scoped insert is then a harmless idempotent
redundancy. The same code path therefore covers both platforms.

The IP is persisted as `host_allow_ip` in the session state JSON so
`cmd_stop` knows exactly which slot to release even across host
broker restarts; the port is read from the already-persisted
`cdp_port_host` field.

The host-side ufw INPUT slot (native Linux + ufw active) reuses the
same persisted triple — `host_allow_ip` (`to`), `cdp_port_host`
(`port`), `ufw_slot_subnet` (`from`) — to open/close a scoped rule via
`sudo ufw allow|delete`. Because those values are read back from the
developer-writable session JSON, the open and close helpers STRICTLY
VALIDATE each selector (dotted IPv4, port 1-65535, IPv4 CIDR) before
the privileged `ufw` call, exactly as the container-side host-allow
helper validates dotted IPv4 before touching iptables. An invalid
selector on the delete path is treated as "cannot safely release": the
broker refuses the `ufw delete` and RETAINS the state file for a human
to inspect rather than letting a tampered selector match an arbitrary
administrator rule. This is defence-in-depth + injection/typo safety,
not a trust boundary against the container: the session JSON is a
host-side artefact with no bind mount into the container, and a host
user who can write it already holds sudo.

### Actor 3: Agent-browser proxy

A small daemon (Python or Go, ~150 LoC) run as `boxa-agent`,
listening on host loopback `127.0.0.1:<proxy-port>`. Host agent
Chrome's `--proxy-server` forces every outbound HTTP/HTTPS through it.
Two modes:

- **default** — REJECT any CONNECT/GET whose host is not in the
  **Agent-browser allowlist** (`~/.config/boxa/agent-browser-allowed-domains.conf`).
  Bypass list (`localhost`, `*.test`, `*.127.0.0.1.sslip.io`) is set
  on the Chrome side via `--proxy-bypass-list` so dev URLs go direct
  and the proxy never sees them.
- **harvest** — ALLOW + LOG every CONNECT/GET, time-bounded by the
  active **Agent-browser network window**. Mirrors the firewall
  `allow-for` semantics on a different layer.

Mode is read from `~/.local/state/boxa/agent-browser/proxy/active-mode`
and reloaded on SIGHUP. `boxa agent-browser allow-for N` writes the
mode file and signals the proxy.

HTTPS is handled at host granularity (`CONNECT host:443` allow/deny).
No MITM, no cert injection, no CA dance. URL-path granularity is
deliberately out of scope (same rationale as ADR 0009's rejection of
the MITM-proxy option).

**Proxy log format**: JSONL (one JSON object per line) at
`/var/log/boxa/agent-browser/<container>-<ISO>.proxy.log`. Each
line records `{ts, method, host, port, mode, decision, reason?}`.
JSONL is chosen over plain text because the summary generator merges
this stream with the Chrome netlog into a single human-readable
`summary.md` at session teardown; structured records make that merge
straightforward, while remaining one-line-per-event for ad-hoc
`jq` / `grep` inspection.

**Tamper-proof property**: relies on structural isolation, not
ADR 0009's symlink-clobber + filename-reconstruction dance. The proxy
log is written by `boxa-agent` (a host OS user) into a directory
owned by `boxa-agent`; the in-container `node` user has no
filesystem path to that directory (no bind mount, no shared parent).
ADR 0009 needed the elaborate atomic-rename + reconstruction
protocol because the toast IPC required a `pending/` subdirectory
that the in-container UID could write into — an IPC channel that
does not exist here. The agent-browser proxy log is a purely
host-side artefact; a rogue container process cannot reach it. The
host user (UID 1000) reads via group membership on
`boxa-agent`'s log dir.

#### Launch in the broker's main shell, not a command substitution (amended 2026-06-09)

The proxy is started with a backgrounded `sudo -u boxa-agent setsid sh
-c 'exec proxy' & disown`, and its real PID is then reconciled by a
separate `pgrep -f -- "--listen 127.0.0.1:<port>"` loop — the same
launch-then-reconcile pattern as the Chrome and relay actors. Crucially
that launch runs in the broker's **main shell**, not inside a `$(...)`
command substitution.

The original implementation wrapped it as `proxy_pid="$(_start_proxy
...)"`, returning the PID on stdout. That tied the backgrounded job's
lifetime to the command-substitution **subshell**: when `_start_proxy`
returned, the subshell exited, and the just-spawned `setsid`+`exec`
proxy raced that subshell teardown. On native Linux under an
**interactive zsh** parent reached via `docker-run.sh`, the proxy lost
the race and was torn down before it came up — surfacing as the silent
"proxy failed to start" with an **empty stderr**. It worked from a bash
parent and on WSL2 (different scheduling won the race), and inserting
real forks before the launch papered over it — all classic signatures of
a scheduling-dependent teardown race, not a logic bug. (~2h diagnosis on
the Omarchy host, 2026-06-09.)

Fix: `_start_proxy` hands its reconciled PID back via the
`_START_PROXY_PID` global and is invoked as a plain statement, so the
background job lives in the persistent main shell. There is no subshell
to exit, so there is no teardown to race. This makes the proxy launch
structurally identical to Chrome/relay rather than an exception.

### Time gates — two independent layers

| Gate | Started by | Closed by | Default state |
|---|---|---|---|
| Agent-browser session (Chrome+bridge exists) | `start` | `stop`, idle timeout, container stop | absent |
| Agent-browser network window (proxy in harvest) | `allow-for N` | `--stop`, timer expiry, session stop | closed |

Agent-browser session can run for hours (Chrome is the audit surface —
the user sees the window on the desktop and can intervene). Network
window is short (default 15 min, matching firewall `allow-for`).

### Cross-platform abstraction

Per-OS differences are confined to `lib/host-platform.sh`:

- `host_platform::detect` → `linux | wsl2 | macos`
- `host_platform::chrome_binary` → path to Chrome
- `host_platform::ensure_agent_user` → idempotent user creation
  (`useradd` on Linux/WSL2, `sysadminctl` on macOS — regular user, not
  underscore-prefixed system user, to avoid LaunchServices/permissions
  edge cases)
- `host_platform::notify <title> <body> <click-target>` → `notify-send`
  on Linux, PowerShell BurntToast on WSL2 (existing pipeline), `osascript`
  on macOS

The outer container's `docker run` always includes
`--add-host=host.docker.internal:host-gateway`. On Docker Desktop this
is redundant; on native Linux it is required. Uniform always.

### Session state

`~/.local/state/boxa/agent-browser/sessions/<container>.json`,
written by the broker:

```json
{
  "container": "easyjukebox-api",
  "chrome_pid": 12345,
  "bridge_pid_in_container": 23456,
  "proxy_pid": 34567,
  "cdp_port_host": 49152,
  "proxy_port_host": 49153,
  "profile_dir": "/var/lib/boxa-agent/profiles/easyjukebox-api-20260519-123456",
  "download_dir": "/var/lib/boxa-agent/downloads/easyjukebox-api-20260519-123456",
  "netlog_path": ".../netlog.json",
  "created_at": "2026-05-19T12:34:56Z",
  "active_network_window": null
}
```

Network window state (when active) is recorded under `active_network_window`
with `started_at`, `expires_at`, and the per-window harvest log path.

At any `boxa agent-browser start`, the broker first sweeps for
orphan processes from a stale session file (Chrome PID dead, bridge
container gone, etc.) and cleans up before launching the new one.

### Missing-session UX — interactive picker

When `boxa agent-browser {allow-for,stop,status,open}` is given a token
that does not resolve to an existing state file, the broker offers an
interactive picker over the OTHER live sessions before falling through to
its original error / idempotent-no-op path. Driven by `lib/picker.sh`
(see ADR 0006 — interactive picker conventions), so fzf is used when
present and a numbered fallback handles the no-fzf case.

Constraints:

- **Explicit-token semantics are preserved.** The picker never silently
  rewrites the caller's argument. A choice from the picker is an
  affirmative user action; cancel (Esc/`q`/empty) falls through to the
  command's existing missing-session behaviour.
- **TTY-gated.** The picker only fires when both stdin and stderr are
  TTYs. Non-interactive callers (hooks, cron, scripted pipelines) see
  the original error or idempotent no-op, unchanged.
- **`start` is exempt.** Start has no "wrong session" case — when no
  state file exists, the right answer is to launch a new one, not pick
  an unrelated session. Start retains its existing container-running
  picker (over `docker ps`) for the unrelated case of an unspecified
  target.

Rationale: shell history-completion routinely substitutes
`<project>-<suffix>` tokens between sibling projects (e.g. autocompleted
`easyjukebox-eu` against a session for `easyjukebox`); silently failing
the command sends the user on a state-file-and-process scavenger hunt.
Offering them the live alternatives turns the typo into a one-keystroke
correction without compromising the explicit-token principle.

## Considered options

**Chrome inside the boxa container (DinD).** Tempting because the
container's firewall would naturally cover the browser. Rejected
because the visual-audit value (user sees what the agent clicks)
collapses to "user opens a Traefik-routed viewport-stream URL in their
own Chrome", which is less direct, requires WSL/macOS GUI plumbing
through containers, and loses host-native display behaviour. Plus the
container already has heavy footprint (Node, Python, rust, dind) and
adding Chrome's deps doubles image size for a feature most projects
won't use daily.

**The user's personal Chrome via the existing profile.** Rejected
explicitly — CDP has no auth and would give an LLM agent full read of
banking sessions, password manager state, GitHub tokens in localStorage,
and arbitrary host filesystem access via `file://`. Not negotiable.

**Bind CDP on the devproxy bridge gateway (`172.18.0.1`) with iptables
ACL.** Was the initial design. Rejected after the cross-platform
constraint surfaced: macOS Docker Desktop has no `docker0`/`devproxy`
bridge on the host (Docker runs inside a LinuxKit VM), so the same IP
does not exist. Adding pf-on-macOS as a second firewall implementation
to mirror iptables would more than double the maintenance surface of
the security-critical layer.

**Custom CDP proxy with allowlist enforcement** (between container and
Chrome). Considered as the prevention layer before discovering
agent-browser's native `--allowed-domains`. Made redundant by that flag
plus this ADR's network-level proxy.

**DNS-level filtering** (Chrome resolves through a host dnsmasq with
ipsets like the container firewall). Rejected because Chrome caches DNS
aggressively and respects `--host-resolver-rules` only at startup, so
dynamic mode toggling (default ↔ harvest) would require Chrome restarts
on every `allow-for`.

**Host-side broker without OS-user separation** (Chrome as the host
user with a separate `$HOME`). Rejected because `$HOME` is an env var
hint; process-level filesystem permissions are unchanged. CDP
`Browser.setDownloadBehavior` with `downloadPath:
"/home/user/.config/autostart/payload.desktop"` would still write
there. OS identity is the only durable boundary.

**Hard session max-lifetime cap (30–60 min).** Suggested as a defence
against runaway sessions. Deferred from MVP: idle timeout +
explicit-stop + container-stop already cover the common cases, and the
Chrome window on the desktop is a visual reminder. If real use shows
session leaks, revisit.

## Consequences

**Positive:**

- Browser-mediated agent work is possible without giving up the
  default-deny posture: the proxy + agent-browser allowlist + harvest
  window mirror the firewall model on a layer the firewall cannot
  reach.
- The container security model is preserved: no Docker socket exposed,
  no host-loopback access, no shared filesystem with the user's home.
  The new attack surface is one socat socket inside the container's
  netns and one HTTP proxy on host loopback.
- Cross-platform parity is real, not aspirational. The same broker
  logic runs on three platforms; only `lib/host-platform.sh` knows
  about the differences.
- Visual audit is free — the Chrome window appears on the desktop
  through the platform's native display, identical UX everywhere.
- Two independent time gates let session ergonomics (hours-long) and
  network safety (minutes-long) be tuned separately.

**Negative:**

- New host-side process inventory: `boxa-agent` OS user, Chrome,
  proxy daemon, plus one socat per active session. Documented in
  `boxa agent-browser status`.
- Local non-Docker processes on the host can reach the Chrome CDP
  port and the proxy port if they discover them — `127.0.0.1`
  binding is not authorisation. Mitigated by random ports, ephemeral
  profile, separate OS user, and the threat-model observation that a
  malicious local process already has paths to most of the user's
  data. Accepted trade-off vs. shipping a per-platform firewall.
- Even with the proxy and harvest mode, the host browser is the
  agent's exit node: in harvest mode the agent can exfiltrate
  arbitrary data to any URL, and the harvest log captures only the
  hostname, not the URL or body. This is the same property the
  firewall has during `allow-for`. The user must understand that
  opening a network window is a deliberate trust event.
- One-time installer step adds a system user and may prompt for sudo
  (Linux/WSL2) or administrator authentication (macOS). Consistent
  with existing installer behaviour for DNS install / mkcert.
- agent-browser binary must be installed inside the boxa image
  (Dockerfile, per the no-runtime-installs rule). One more thing to
  keep in sync with upstream releases.

## Future work

- `--max-lifetime` cap on sessions, configurable per user. Skip until
  real-use data shows leaks.
- Per-project `agent-browser-allowed-domains.conf` override layered on
  top of the global user-level list. Wait until two projects with
  divergent needs surface.
- `boxa agent-browser review` — fzf picker over the most recent
  harvest log to promote entries into the durable allowlist (mirrors
  the equivalent for firewall `allow-for`).
- Optional URL-path granularity via a built-in MITM proxy with a
  per-session CA trusted only inside the agent profile. Separate
  project, materially heavier; defer until the host-granularity gate
  proves insufficient.
- Deny visibility for HTTPS denials in **manual Chrome navigation**.
  When an agent calls `agent-browser open https://blocked`, the
  in-container wrapper (`scripts/agent-browser-cdp-bridge.sh`,
  shipped 2026-05-21) detects `net::ERR_TUNNEL_CONNECTION_FAILED`
  on the upstream CLI's stderr and re-invokes the CLI with a
  `data:text/html,…` URL that renders a styled denial page inline —
  blocked host, recovery commands, original URL. This wrapper-redirect
  is out-of-band of the proxy/CONNECT protocol entirely, so it sidesteps
  Chromium's hard rule that any non-2xx response to a `CONNECT` request
  (and any `Location:` header on such a response) is discarded — there
  is no proxy-side fix for that path.
  The wrapper does NOT cover manual user navigation (address bar,
  link clicks): those requests never traverse the wrapper, so Chrome
  shows the bare `ERR_TUNNEL_CONNECTION_FAILED` error page. Two
  paths to close that gap, both deferred:
  1. **MITM with per-host certificate** signed by the mkcert CA — the
     proxy would `200 Connection Established` on a denied CONNECT,
     handshake as the requested host, and serve the denial HTML over
     HTTPS. Same machinery the URL-path granularity entry above would
     need. Materially heavier; only revisit if denial visibility for
     manual nav becomes a real complaint.
  2. **Chrome extension via `webRequest.onErrorOccurred`** baked into
     the agent-browser spawn (the upstream CLI already accepts
     `--extension <path>`). Listens for `ERR_TUNNEL_CONNECTION_FAILED`
     on main-frame navigation and calls `chrome.tabs.update()` to
     redirect the tab to a local denial page. Lighter than MITM (no
     cert ops, no proxy changes) but adds a manifest v3 service worker
     to the surface area.
- **Dedicated headless Xwayland for the agent.** The current
  `xhost +SI:localuser:boxa-agent` grant (amended 2026-06-08, see
  Actor 1) authorizes the agent uid on the *developer's own* X server,
  where X11 provides no isolation between clients (the agent uid could
  snoop/inject into the developer's other X clients). Hard isolation
  would run Host agent Chrome against a dedicated headless Xwayland
  instance owned by `boxa-agent`, with the window surfaced back to the
  developer's compositor for the visual audit (e.g. a nested/embedded
  view). Materially heavier (per-session display server, compositor
  plumbing); defer until the weak-boundary trade-off proves
  unacceptable in practice.
- Status-line integration showing active session + remaining network
  window time.
- Replay tool that reconstructs an agent's browsing path from the
  netlog + harvest log into a human-readable timeline.

## References

- `lib/host-platform.sh` (new) — per-OS dispatch.
- `scripts/agent-browser-broker.sh` (new) — host-side start/stop/status.
- `scripts/agent-browser-proxy.{py,go}` (new) — forward proxy daemon.
- `scripts/deliver-allow-for-notification.sh` — extended to also
  deliver agent-browser session-close and network-window-close toasts
  (single pipeline, paralleling the firewall `allow-for` path).
- `install.sh` — gains `boxa-agent` user creation and Chrome binary
  detection.
- `docker-run.sh` — adds `--add-host=host.docker.internal:host-gateway`
  uniformly.
- `Dockerfile` — bakes in `agent-browser` CLI and the in-container
  socat dependency.
- `CONTEXT.md` — terminology added under "Agent-browser".
- ADR 0001 — the firewall model whose property this ADR mirrors at the
  browser layer.
- ADR 0003 — the privilege-boundary discipline (no sudo in container,
  setup runs from host) this ADR continues.
- ADR 0006 — interactive picker conventions used by the missing-session
  fallback in `agent-browser-broker.sh`.
- ADR 0009 — `allow-for` window pattern this ADR parallels at the
  browser network layer.
