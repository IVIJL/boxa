# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities **privately** through GitHub's private
vulnerability reporting, not via a public issue or pull request.

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Fill in the advisory form with as much detail as you can: affected version
   or commit, steps to reproduce, impact, and any suggested fix.

This opens a private security advisory that only the maintainers can see, so the
issue stays confidential until a fix is available.

## Scope

Boxa is a local-first development environment that runs each project inside a
container behind a default-deny outbound firewall. Security-relevant areas
include, but are not limited to:

- the default-deny firewall and the allowlist / allow-for mechanisms;
- DNS pinning and the in-container resolver;
- the HTTPS / mkcert trust-store handling;
- the MCP credential isolation and broker;
- the agent-browser proxy and its host-grant lifecycle;
- `install.sh` / `build.sh` and anything they execute with elevated privileges
  on the host.

Reports that depend on the host or Docker being already compromised, or on a
user deliberately disabling the firewall (e.g. a wide allow-for window), are
generally out of scope but still welcome as hardening suggestions.

## Response expectations

This is a small, volunteer-maintained project. We aim to acknowledge a report
within a few days and to keep you updated as we investigate. There is no formal
SLA or bug-bounty program. Once a fix is ready we will publish the advisory and
credit the reporter unless you prefer to stay anonymous.

Please give us reasonable time to ship a fix before disclosing publicly.
