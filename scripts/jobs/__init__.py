"""Container-owned Jobs for boxa (ADR 0037).

A Job is a command run by a detached Job worker inside a Container; its
lifetime, state and result belong to the Container, not to the shell call,
subagent or session that started it.  This package is the unit-tested core
behind the ``boxa-job`` front-end (``scripts/job.sh``).

Modules:
  * ``env``    — the fixed worker environment baseline (shared with the MCP
                 agent-trusted launcher) plus caller-named passthrough.
  * ``store``  — state directory layout, Project lock, job records, the
                 link-published key reservation and the per-key index.
  * ``worker`` — the detached worker entry point (``python3 -m jobs.worker``).
  * ``cli``    — the ``boxa-job`` command surface.
"""
