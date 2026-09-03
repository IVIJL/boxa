# Forge access

Boxa gives Containers forge access through a scoped **Agent identity**, not the
user's personal forge account. The identity has two independent parts:

- the **Agent key**, used through Boxa's dedicated SSH agent for git over SSH;
- a GitHub or GitLab machine account and its token, delivered through the
  **Forge gate** for API and HTTPS access.

The two gates are independent. `boxa ssh on` forwards the Project's dedicated signing
socket; `boxa forge on` delivers stored forge credentials. An SSH remote still
needs the SSH gate, while `gh`, `glab`, and HTTPS remotes use the Forge gate.
Both paths also need the forge host admitted by the [Allowlist](firewall.md).

## Set up an Agent identity

Fresh installs and updates offer the category-B Agent identity setup once. The
wizard can generate a new ed25519 Agent key (recommended), adopt an existing key
without moving or rewriting it, or skip. A generated key has no passphrase,
uses the comment `boxa-agent@<hostname>`, and remains under
`~/.config/boxa/agent-identity/` on the host. Boxa loads it into a dedicated
Boxa-owned `ssh-agent` that contains only that key.

Re-run the wizard at any time from an interactive host terminal:

```bash
boxa doctor --fix agent-identity
```

After the key step, the wizard offers the GitHub and GitLab setup flows. The
same flows are also available directly:

```bash
boxa forge setup                  # Offer both forge flows
boxa forge setup github           # Offer only the GitHub flow
boxa forge setup gitlab           # Offer only the GitLab flow
boxa forge checklist github       # Run the GitHub new-identity checklist
boxa forge checklist gitlab       # Run the GitLab new-identity checklist
```

The checklists guide the forge-side work and verify the result with `ssh -T`
through the dedicated agent and `gh api user` or `glab api user`. Boxa does not
create accounts, memberships, branch protections, or tokens on the user's
behalf.

### GitHub identity

Use a separate machine-user account. Attach the Agent public key, invite the
account only to repositories it should access, and protect the default branch
where the repository plan supports it. Mint a classic personal access token
with the `repo` scope and a one-year expiry. A classic token is intentional:
fine-grained tokens cannot act on repositories where the machine user is only a
collaborator.

### GitLab identity

Use an instance service account on GitLab 18.11 or newer, or a separate
automation-only user on older GitLab CE. Grant it the Developer role only on
the required projects, restrict protected-branch pushes to Maintainers, and
protect release tag patterns such as `v*`. Mint a personal access token with
the `api` scope and a one-year expiry. The checklist accepts `gitlab.com` or a
self-hosted GitLab hostname.

These forge-side grants form the capability ceiling. The intended identity can
push unprotected branches, open pull or merge requests, work with issues, and
read CI, but has no repository, organization, group, or instance administration
authority.

## Store and rotate tokens

Store a token from a hidden host-terminal prompt:

```bash
boxa forge set github
boxa forge set gitlab
```

The GitLab command first asks for the GitLab host and defaults to `gitlab.com`.
Each command stores the token before probing it, then reports the authenticated
username when verification succeeds. A failed probe leaves the token stored so
offline setup remains possible. Tokens are never echoed and are not placed in
the Docker command line.

The host-owned **Forge store** is `~/.config/boxa/forge/`. Its directory is mode
`0700`; each forge has one mode-`0600` file containing the token, creation time,
verified username when available, and the GitLab host where applicable. Host
`gh` and `glab` login files are not changed.

Running `set` again replaces the stored credential and is the rotation path:

```bash
boxa forge set github             # Rotate the GitHub token
boxa forge set gitlab             # Rotate the GitLab token or host
```

Boxa warns, without blocking Container creation, during the final 30 days of
the configured one-year lifetime and after its derived expiry. Remove a stored
credential with:

```bash
boxa forge unset github
boxa forge unset gitlab
```

The consent-first import path can copy an existing host CLI token into the
Forge store without changing the source login:

```bash
boxa forge adopt github
boxa forge adopt gitlab
```

## Allow the forge host

After `boxa forge set` stores a token, Boxa checks whether the forge host is
covered by the durable Allowlist. GitHub checks `github.com`. For a self-hosted
GitLab host, Boxa offers its parent domain as an editable default so related
subdomains can be covered together.

The prompt defaults to **No**. Accepting adds only the confirmed domain and
reloads running firewalls. Declining, or running without an interactive
terminal, changes nothing and prints the exact fallback hint:

```bash
boxa allow <forge-host>
```

Adding a token therefore never silently widens network access.

## Control the Forge gate

Run these commands on the host:

```bash
boxa forge                       # Show gate, source, credentials, and token ages
boxa forge on                    # Enable for the current Project
boxa forge off                   # Disable for the current Project
boxa forge on ~/projects/my-app  # Enable for a specific Project
boxa forge on --global           # Set the global fallback to on
boxa forge off --global          # Set the global fallback to off
```

The gate is off by default. Project choices override the global fallback. Boxa
stores both in `~/.config/boxa/forge.conf`, using absolute host paths for
Project sections:

```ini
forge = off

[/home/me/projects/my-app]
forge = on
```

Storing a credential does not enable the gate. Enabling the gate grants the
Container every valid credential currently present in the Forge store; it does
not select only one forge.

## Container delivery and precedence

When the effective gate is on, Boxa reads the Forge store at Container creation
and injects the configured values by environment-variable name, keeping token
values out of Docker's argument list:

- GitHub: `GH_TOKEN`;
- GitLab: `GITLAB_TOKEN` and `GITLAB_HOST` for the stored host;
- commits: `GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL` derived from the
  verified machine identity.

The user's git configuration still supplies the author. Git therefore records
the human as author and the machine identity as committer. If both forges are
configured, the GitHub identity deterministically supplies the committer.

Each Project also has persistent named volumes mounted at `~/.config/gh` and
`~/.config/glab-cli`. This makes these in-Container alternatives survive
Container recreation while remaining Project-scoped:

```bash
gh auth login
glab auth login
```

On every Container start that receives `GITLAB_HOST`, the entrypoint prepares
the Project's `~/.config/glab-cli/config.yml`:

- If the file does not exist, it seeds a minimal config whose default `host:`
  is `GITLAB_HOST` and whose `hosts:` map contains only that host. The file has
  no token, no `gitlab.com` stub, and mode 0600.
- If the file exists, the entrypoint reconciles it idempotently. It sets the
  default `host:` to `GITLAB_HOST`, creating the `hosts:` section and Forge host
  entry when missing. It drops entries for other hosts that have no token,
  including glab's default `gitlab.com` stub. If `GITLAB_TOKEN` is also set, it
  removes the `token:` under the Forge host because the environment token wins
  and a stored token there can only be stale. Tokened entries for other hosts
  remain verbatim, and all other top-level settings remain untouched. The file
  mode is enforced to 0600.

Without `GITLAB_HOST`, the entrypoint creates no config and does not touch an
existing one. If `glab auth login` targets the same host as `GITLAB_HOST`, its
stored token is stripped on the next Container start while the Forge gate
delivers `GITLAB_TOKEN`, so that login does not stick. A login to a different
GitLab host does stick because its tokened host entry is preserved.

Injected environment credentials take precedence over those config files. To
use a persisted in-Container login instead, turn the Forge gate off and recreate
the Container. Host CLI login files are never mounted or modified by this flow.

## Container-creation limitation

Forge and SSH gate choices are frozen when the Container is created. Changing a
gate or rotating a stored token does not update an already running Container.
Boxa prints a restart hint when it can identify an affected running Project;
apply the current state with:

```bash
boxa stop && boxa
```

## Private GitHub repositories

Boxa documents but does not enforce the private-repository posture. Choose one:

- do not invite the machine user to private repositories (recommended);
- use GitHub Pro and protect the default branch before inviting it;
- attach the Agent public key as a read-only deploy key to selected repositories
  when git read access is enough. Deploy keys do not provide API, issue, or
  pull-request access.

For users who do not want a machine-user account, the DIY fallback is a
fine-grained personal access token on the user's own GitHub account, limited to
the required repositories and permissions, with HTTPS git remotes. This bypasses
the scoped machine-identity model and acts with the user's selected authority;
Boxa does not provision or enforce it.

## See also

- [ADR 0032](adr/0032-per-installation-agent-identity.md) — decision and threat
  model for Agent identity and forge access.
- [CONTEXT.md](../CONTEXT.md#forge) — canonical **Agent identity**, **Forge
  store**, and **Forge gate** terminology.
- [SSH](ssh.md) — the binary SSH gate and dedicated Project agents.
- [Firewall](firewall.md) — the separate network gate for forge hosts.
