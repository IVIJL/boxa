# Research — dedicated ssh-agent + single-key identity patterns

Ticket: [03](../issues/03-research-dedicated-agent-key-patterns.md) ·
Date: 2026-08-22 · Sources: OpenSSH manpages (local `man ssh_config` /
`man ssh-agent`, matching man.openbsd.org), docs.github.com,
docs.gitlab.com, learn.microsoft.com/wsl, plus the repo's own
`lib/ssh.sh` and ADR 0026 for grounding. Claims that could not be traced
to a primary source are explicitly marked **unverified**.

## 1. Running a second, dedicated ssh-agent

### Socket basics (ssh-agent(1))

- Default socket is `$TMPDIR/ssh-XXXXXXXXXX/agent.<ppid>` — random,
  unstable across restarts. `-a bind_address` binds the agent to a
  chosen Unix socket path → this is the mechanism for a *stable,
  well-known* socket (e.g. `~/.config/boxa/agent-identity/agent.sock`
  or `$XDG_RUNTIME_DIR/boxa/agent.sock`).
- `-D` = foreground (no fork) — the mode you want under a service
  manager. `-t life` sets a default max lifetime for added keys
  (relevant if the agent key should require periodic re-add; for an
  unattended identity you normally omit it).
- Source: `man ssh-agent` (OpenSSH 9.x; same text at
  <https://man.openbsd.org/ssh-agent.1>).

### Linux/WSL2 patterns

Two viable host-side patterns; boxa already implements a variant of (b):

a) **systemd user service** — unit with
   `ExecStart=/usr/bin/ssh-agent -D -a %t/boxa-agent.sock`
   (`%t` = `$XDG_RUNTIME_DIR`, wiped every boot but the *path string*
   is stable, so config referencing it survives reboots). WSL2 supports
   systemd since WSL 0.67.6 via `/etc/wsl.conf` `[boot] systemd=true`
   (default on current Ubuntu installed by `wsl --install`)
   (<https://learn.microsoft.com/en-us/windows/wsl/systemd>).
   **WSL2 caveat (verified, MS docs):** "systemd services will NOT keep
   your WSL instance alive" — the WSL VM still shuts down when the last
   client exits, taking the agent down with it. So on WSL2 a systemd
   unit gives auto-(re)start *within* a VM lifetime, not persistence
   across VM idle-shutdowns; any consumer must tolerate
   "agent gone, restart it" (socket-activation or a lazy-ensure step).
   To have user units start without an interactive login, lingering
   (`loginctl enable-linger`, systemd's `user@.service` machinery,
   <https://www.freedesktop.org/software/systemd/man/loginctl.html>)
   is the standard tool — **unverified on WSL2 specifically**; WSL's
   session setup is nonstandard, so this needs a live check.

b) **Lazily spawned + persisted env** — spawn `ssh-agent -s` on demand,
   persist `SSH_AUTH_SOCK`/`SSH_AGENT_PID` to a 0600 env file, re-source
   and liveness-check (`ssh-add -l`, exit ≤1 = alive) on every use.
   This is exactly what boxa does today for the *user* agent:
   `_boxa::ssh_resolve_agent` / `_boxa::ssh_persist_agent_env` in
   `lib/ssh.sh` (env file `~/.config/boxa/ssh-agent.env`, keychain(1)
   fallback). A dedicated agent can clone this machinery with its own
   env file + `-a` fixed socket; the liveness-check-then-respawn dance
   already absorbs the WSL2 VM-restart problem. Lower new-machinery
   cost than a systemd unit and works on systemd-less distros.

Recommendation-shaped observation (for ticket 06, not a decision here):
pattern (b) with a *fixed* `-a` socket path under `~/.config/boxa/`
gives a stable mount source for containers even across agent restarts
— important because boxa bind-mounts the socket path at container
creation (`/tmp/ssh-agent.sock` inside, see
`_boxa::existing_container_ssh_status`), and a `$TMPDIR`-random path
would go stale on every agent restart while the container lives on.
Note the repo's own bind-mount/inode lesson (single-file bind mounts
detach on inode swap): a *socket* re-created at the same path is a new
inode → an already-running container's mount goes stale. Mounting the
*directory* containing the socket avoids that.

### macOS (secondary)

- macOS runs a per-login system ssh-agent via launchd
  (`com.openssh.ssh-agent`, `SSH_AUTH_SOCK` pointing at
  `/private/tmp/com.apple.launchd.*/Listeners`). A second dedicated
  agent = a user LaunchAgent plist (`~/Library/LaunchAgents/`) with
  `ProgramArguments = ssh-agent -D -a <fixed path>` and
  `KeepAlive`/`RunAtLoad`. **Unverified in this session** (no macOS docs
  fetched; standard launchd.plist(5) pattern). Fits the existing
  `.scratch/mac/` deferred-work convention.

## 2. Key selection semantics inside the container

All quotes from `ssh_config(5)` (local manpage = man.openbsd.org):

- **Default behaviour with an agent:** "any identities represented by
  the authentication agent will be used for authentication unless
  IdentitiesOnly is set." With multiple keys in the agent, ssh offers
  agent identities (agent-insertion order) until the server accepts
  one; servers count each offered key against `MaxAuthTries`. → If the
  container sees a forwarded agent holding *exactly one* key, there is
  nothing to configure: git/ssh will use that key. This is the big
  simplification the dedicated-agent design buys.
- **`IdentitiesOnly yes`**: ssh uses only the configured
  identity/certificate files "even if ssh-agent(1) … offers more
  identities". Crucially, `IdentityFile` "may be used in conjunction
  with IdentitiesOnly to select which identities in an agent are
  offered" — and `IdentityFile` may point at a **public key file** "to
  use the corresponding private key that is loaded in ssh-agent(1) when
  the private key file is not present locally." → A container can pin
  the agent key by shipping only the *.pub* + `IdentitiesOnly yes`;
  private key never leaves the host. This is the standard belt against
  pitfall cases below.
- **`IdentityAgent`**: per-host choice of agent socket; overrides
  `SSH_AUTH_SOCK`; `none` disables agent use. Host-side this is how the
  user's ssh config could route `github.com-as-agent` to the dedicated
  socket; container-side it's mostly irrelevant (only one socket is
  forwarded).
- **Pitfalls when the user's own agent also exists on the host:**
  - The two agents are distinct sockets; nothing leaks between them.
    Confusion arises only *on the host* if `SSH_AUTH_SOCK` points at
    one and tooling assumes the other — solved by `IdentityAgent` in
    ssh config or explicit env when boxa itself talks to the forge.
  - If the *user's* agent (not the dedicated one) is forwarded into a
    container that also has the agent key's `.pub` configured, ssh
    would fall back to other agent keys once the pinned one is absent —
    unless `IdentitiesOnly yes` is set. Ship it.
  - GitHub/GitLab shell auth identifies the *account by the first
    accepted key*: with multiple keys for the same
    forge host in one agent, the wrong identity can win. One-key agent
    removes this class entirely.

## 3. Forge SSH-key binding rules (feeds ticket 04)

### GitHub (docs.github.com, verified 2026-08-22)

- **Authentication key ⇒ exactly one account.** "Error: Key already in
  use" fires "when you try to add a key that's already been added to
  another account or repository." Diagnose ownership with
  `ssh -T -ai <key> git@github.com` — "The username in the response is
  the account on GitHub.com that the key is currently attached to"
  (repo-format response ⇒ it's a deploy key).
  <https://docs.github.com/en/authentication/troubleshooting-ssh/error-key-already-in-use>
- **Deploy key ⇒ exactly one repository.** "You can't reuse a deploy
  key for multiple repositories." Read-only by default, optional write;
  write access ≈ admin-level collaborator; no expiry, not tied to a
  user. Alternatives GitHub itself recommends for automation: GitHub
  App installation tokens (scoped, ≤1 h), machine users (a separate
  account added as collaborator), OAuth tokens.
  <https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys>
- **Consequence for boxa on a personal GitHub:** an auth key can only
  attach to *some* account. Attached to the user's personal account, the
  agent key is indistinguishable from the user for **all git-over-SSH
  operations on every repo the user can reach** — GitHub has no per-key
  scoping of auth keys (no expiry either). The MAP's capability ceiling
  (no protected-branch push etc.) is therefore *not* expressible via the
  SSH key on a personal account; it must come from branch protection
  (already the MAP's stance) or from a machine-user/App model. Deploy
  keys give per-repo scoping but are per-repo-unique and repo-admin
  work — poor fit for "one identity per installation" across many repos.
- **SSH keys do not authenticate `gh`/the API** — they cover git wire
  operations only; `gh`/`glab` need an OAuth/PAT token separately
  (that's ticket 04/05 territory).

### GitLab (docs.gitlab.com + instance behaviour, verified 2026-08-22)

- **User SSH key**: per-key optional **expiration date** (auth/signing
  stop working after expiry; notification 7 days before) and a **usage
  type**: `Authentication`, `Signing`, or both — "Authentication &
  Signing" is the default. ED25519 explicitly "more secure and
  performant than RSA".
  <https://docs.gitlab.com/user/ssh/>
- **Fingerprint uniqueness per instance**: adding a key already present
  anywhere on the instance fails with "Fingerprint has already been
  taken" — one key ⇒ one identity per GitLab instance (long-standing
  behaviour, evidenced by gitlab-org issues #330286, #480472 and the
  deploy-key variant gitlab-foss#35702; exact wording not in the docs
  page itself — **rule verified via issue tracker, not docs prose**).
- **Deploy keys**: *project* deploy keys bind to one project; *public*
  deploy keys (instance-admin-created) are "shareable between multiple
  projects", enabled per project by a Maintainer+. Read-only or
  read-write, changeable later. GitLab recommends service accounts for
  non-human access.
  <https://docs.gitlab.com/user/project/deploy_keys/>
- Self-hosted CE (the user's case) additionally allows a real **service
  account / dedicated user** with per-project role (Developer =
  push-unprotected + open MR, no protected push) — that maps almost 1:1
  onto the MAP's capability ceiling, unlike GitHub personal.

## 4. Key hygiene

- **Type**: Ed25519 — GitHub's own generation docs default to
  `ssh-keygen -t ed25519`; GitLab lists ED25519 as preferred
  (<https://docs.gitlab.com/user/ssh/>). No reason to consider RSA.
- **Passphrase**: for an *unattended* agent key a passphrase adds
  nothing once the key sits decrypted in the agent, and blocks
  unattended restart (someone must type it after every WSL VM restart
  — frequent per the WSL keep-alive caveat above). The honest design:
  passphrase-less private key, `chmod 600`, on host only, never mounted
  (extends ADR 0026's "key material never enters containers"). The
  agent *is* the protection boundary; contrast with ADR 0026's incident
  — the risk there was a passphrase-less *user prod* key exposed to
  containers, whereas this key's blast radius is capped by forge-side
  scoping. Optionally `ssh-agent -t`/`ssh-add -c` exist but `-c`
  (confirm per signature) defeats unattended use.
- **Comment/labelling**: key comment (`-C`) travels inside the public
  key line and is what `ssh-add -l` shows (boxa's status line already
  parses these comments). Suggested convention:
  `boxa-agent@<hostname>` or similar stable, greppable marker. On
  GitHub the *title* field is set at upload (comment only prefills the
  UI); on GitLab likewise — set both to the same marker so the key is
  identifiable on the forge and in `ssh-add -l`.
  (Title-prefill detail: **unverified**, UI behaviour.)
- **Rotation/revocation**: no CRL concept for forge auth keys —
  rotation = generate new key, upload, delete old key on the forge
  (immediate effect), replace in agent. GitLab's per-key expiration
  date gives free time-boxed rotation pressure; GitHub auth keys have
  no expiry, so rotation is purely operational discipline. Deleting the
  key on the forge is the *only* kill switch — worth a
  `boxa ... rotate`-shaped affordance in the spec.

## 5. Auth key vs signing key (feeds commit-signing fog patch)

- **GitHub**: authentication and signing are separate key registrations.
  "If you want to use the same SSH key for both authentication and
  signing, you need to upload it twice"
  (<https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account>).
  "There's no limit on the number of signing keys you can add to your
  account" and re-uploading an auth key as a signing key is explicitly
  supported
  (<https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification>).
  The "key already in use" uniqueness rule is documented for
  auth/deploy keys only; whether one signing key can sit on *multiple*
  accounts is not documented — **unverified**, assume undefined.
  Vigilant-mode nuance for "author = user, signed by agent": if the
  *user* enables vigilant mode, commits authored by them but signed
  with a key on their own account still verify — but only if the
  signing key is registered on the account matching the committer
  email; mixed author/committer identities degrade to "Partially
  verified"/"Unverified".
- **GitLab**: one registration with usage type `Authentication`,
  `Signing`, or `Authentication & Signing` (default both) — no double
  upload needed (<https://docs.gitlab.com/user/ssh/>).
- Net: registering the single agent key for both purposes is possible
  on both forges (GitHub: two uploads; GitLab: one flag), so the
  commit-signing question stays a pure policy decision — no key-count
  consequence.

## Summary of surprising constraints

1. **GitHub auth key = whole-account, unscoped, no expiry.** The MAP's
   capability ceiling cannot be enforced by the key itself on a
   personal account; it's branch protection or a separate
   machine-user/App. Deploy keys don't compose (one repo each,
   non-reusable).
2. **One key ⇒ one identity** on both forges (GitHub account/repo
   uniqueness; GitLab instance-wide fingerprint uniqueness) — the agent
   key can never be shared between the user's account and any second
   account, which forces ticket 04's "whose account" question.
3. **WSL2 systemd services don't keep the VM alive** — a dedicated
   agent on WSL2 must be resurrectable, not assumed persistent; boxa's
   existing lazy ensure + env-file pattern (lib/ssh.sh) already models
   this, and a fixed `-a` socket path (directory-mounted, not
   file-mounted) keeps container mounts valid across agent restarts.
4. **SSH keys don't log `gh`/`glab` in** — API/CLI auth is a separate
   credential no matter how the key design lands.
