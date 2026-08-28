# Triage Labels

The skills speak in terms of five canonical triage roles. In this repo's
**local-markdown tracker**, the "label" is the `Status:` or `**Status:**` field
near the top of each issue file. Preserve its existing markdown form.

| Role in mattpocock/skills | `Status:` value in our tracker | Meaning                                  |
| ------------------------- | ------------------------------ | ---------------------------------------- |
| `needs-triage`            | `needs-triage`                 | Maintainer needs to evaluate this issue  |
| `needs-info`              | `needs-info`                   | Waiting on reporter for more information |
| `ready-for-agent`         | `ready-for-agent`              | Fully specified, ready for an AFK agent  |
| `ready-for-human`         | `ready-for-human`              | Requires human implementation            |
| `wontfix`                 | `wontfix`                      | Will not be actioned                     |

The tracker also uses repository lifecycle states that are not skill triage
roles:

| `Status:` value | Meaning |
| --------------- | ------- |
| `in-progress` | The issue is actively being implemented. |
| `done` | Acceptance criteria and required verification are complete. |
| `superseded` | A newer issue or decision replaced this issue. |
| `cancelled` | The work was explicitly abandoned; preserve the reason. |
| `closed` | Legacy terminal state; use `done` or `superseded` for new work. |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), set
the issue file's `Status:` line to the corresponding value from this table.

Defaults are unchanged (string = role name) — existing issue files already
use `Status: ready-for-agent`.
