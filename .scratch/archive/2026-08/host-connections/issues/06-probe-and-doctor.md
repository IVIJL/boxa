# 06 — Live probe in `boxa connections` + doctor report

Status: done

## Parent

ADR 0023 — Host connections via a durable scoped firewall slot.

## What to build

Troubleshooting surfaces for Host connections:

- `boxa connections` gains a live probe for Host connections: an actual
  TCP touch through the forward, so the status distinguishes "forward
  broken" (listener missing, firewall rule gone, relay dead) from "host
  service not answering" (forward fine, nothing listening on the host
  port). Existing `up`/`down`/`stopped` vocabulary extends rather than
  being replaced.
- `boxa doctor` gains a report-only check: for each persisted Host
  connection whose artifacts are missing or broken (rule absent, relay
  dead, ufw slot missing), print the finding and the exact repair
  command (`boxa connect host …` re-run — idempotent repair). Doctor
  never repairs these silently, matching its Elective-step posture.

## Acceptance criteria

- [x] Forward intact + host listener up → healthy status.
- [x] Host listener down, forward intact → status names the host
      service, not the forward.
- [x] Firewall rule removed or relay killed → status names the forward;
      doctor reports it with the exact repair command.
- [x] Doctor output with no Host connections is unchanged.
- [x] Shell tests cover the three probe outcomes and the doctor report;
      `shellcheck` clean.

## Blocked by

`01-connect-host-docker-desktop.md`

## Comments
