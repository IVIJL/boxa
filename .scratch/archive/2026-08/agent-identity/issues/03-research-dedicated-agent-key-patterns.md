# 03 — Research: dedicated ssh-agent + single-key identity patterns

Status: closed
Label: wayfinder:research
Assignee: research-agent

## Parent

[MAP](../MAP.md) — wayfinder map "Boxa agent identity".

## Question

Facts needed to design a host-side, boxa-owned ssh-agent holding exactly
one generated "agent key", forwarded into containers instead of the user's
personal agent:

- **Running a second agent**: patterns for a long-lived dedicated
  ssh-agent on Linux/WSL2 (systemd user service vs lazily spawned +
  persisted env, socket path stability across reboots); anything
  WSL2-specific (boxa's primary host is WSL2). macOS launchd equivalent
  (secondary).
- **Key selection semantics**: when a container sees only the forwarded
  agent socket, how git/ssh pick the identity; `IdentitiesOnly`,
  `IdentityAgent`, multiple-keys-in-agent behaviour; pitfalls when the
  user's own agent is also present on host.
- **Forge SSH-key semantics**: GitHub — an auth SSH key binds to exactly
  one account, deploy keys bind to one repo, the same key cannot be
  reused across accounts/repos (verify current rules); GitLab equivalent
  rules. Consequence: whose account does the agent key attach to on a
  personal GitHub (feeds ticket 04)?
- **Key hygiene**: current best practice for type (ed25519), passphrase
  question for an unattended agent key, comment conventions for
  identifying the key on forges, rotation/revocation story.
- **Auth key vs signing key**: forges distinguish authentication and
  signing SSH keys — rules for registering the same key as both (feeds
  the commit-signing fog patch).

## Acceptance criteria

- [x] Findings written to `.scratch/agent-identity/research/dedicated-agent-key-patterns.md` with source links.
- [x] Resolution comment below + map "Decisions so far" line (design decision itself is ticket 06).

## Blocked by

None — can start immediately.

## Comments

**2026-08-22 — research-agent — resolved.**
Findings written to
[research/dedicated-agent-key-patterns.md](../research/dedicated-agent-key-patterns.md).
Key facts: GitHub auth SSH key binds to exactly one account, deploy key
to exactly one repo, no per-key scoping/expiry — capability ceiling must
come from branch protection or a machine-user/App, not the key. GitLab
enforces instance-wide fingerprint uniqueness; key has expiry + usage
type (Auth/Signing/both — GitHub needs the same key uploaded twice for
both roles). Container-side selection is trivial with a one-key agent;
belt = ship only `.pub` + `IdentitiesOnly yes`. WSL2: systemd services
don't keep the VM alive → dedicated agent must be lazily resurrectable
(boxa's existing lib/ssh.sh env-file pattern fits) with a fixed `-a`
socket path, directory-mounted to survive socket inode swaps. SSH keys
never authenticate `gh`/`glab` — API tokens are a separate credential.
