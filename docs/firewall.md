# Firewall

Every boxa container starts behind a **default-deny firewall** (iptables +
ipset + dnsmasq). Only domains on the allowlist can be reached; everything else
is blocked at DNS resolution and at the packet layer. This is what makes it safe
to run Claude Code with `--dangerously-skip-permissions` inside the box — an
agent simply cannot exfiltrate to an arbitrary host.

GitHub is allowed by IP range. Default allowed domains include the Anthropic
API, npm, PyPI, crates.io, the VS Code marketplace, Cursor, and Docker Hub. The
allowlist file is seeded on first run at
`~/.config/boxa/allowed-domains.conf` and can be edited by hand or via the CLI.

See [ADR 0001](adr/0001-dnsmasq-dynamic-allowlist.md) for the dynamic-allowlist
design and [ADR 0015](adr/0015-firewall-dns-upstream-on-native-docker.md) for
the DNS-upstream behaviour on native Docker.

## Managing the allowlist

```bash
boxa allow                     # List all allowed domains
boxa allow pypi.org            # Add a domain to the allowlist
boxa deny                      # Interactive removal (fzf)
boxa deny example.com          # Remove a specific domain
boxa blocked                   # Show blocked DNS queries, allow interactively
```

Changes take effect immediately across **all** running containers — dnsmasq is
reloaded and the ipset rules are updated without a restart. No container restart
is needed after editing the allowlist.

### `blocked` — promote from what was actually denied

`boxa blocked` shows the DNS queries the firewall has rejected so far and lets
you promote any of them to the allowlist interactively (via `fzf`). This is the
fastest way to grow the allowlist from reality: run your tool, see what it
tried to reach, and allow only the hosts you trust.

## Allow-for harvest window

When running unattended agents (LLM tools, scripts) it is useful to let them
reach the wider internet for a short time and then see *what* they actually
queried, so the allowlist can be informed by reality instead of guesswork.
`boxa allow-for` opens a time-bounded window where:

- Domains **outside** the allowlist are **recorded, not blocked** — DNS
  resolution succeeds and traffic to those IPs is accepted via a transient
  `harvest-pool` ipset.
- Domains **in** the allowlist behave exactly as before — no change in routing.
- When the window closes (timer expires, `--stop`, or `boxa stop` on the
  container), the firewall is reversed and a harvest log lists every
  non-allowlist domain that was queried. A clickable desktop notification
  (Windows toast / Linux `notify-send` / macOS `osascript`) opens the log.

```bash
boxa allow-for 30              # 30-minute window in the CWD's container
boxa allow-for 30 myapp        # 30-minute window in 'myapp'
boxa allow-for myapp           # Show status (remaining time, captured count)
boxa allow-for --stop          # Close the active window in the CWD's container
boxa allow-for --stop myapp    # Close the active window in 'myapp'
```

Harvest logs persist at
`/var/log/boxa/allow-for/<container>-<timestamp>.log` on the host (root-owned,
so they cannot be tampered with from inside the container). See
[ADR 0009](adr/0009-allow-for-harvest-window.md) for the security model.

## See also

- [Networking](networking.md) — local `.test` DNS, port routing, and HTTPS sit
  on top of the same firewall.
- [Agent-browser](agent-browser.md) — the browser layer has its own,
  independent default-deny allowlist and network window.
