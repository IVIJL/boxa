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
  * ``procs``  — process identity (pid + start time), the ``/proc`` parent-link
                 tree walk under a live worker, the ``BOXA_JOB_ID`` marker
                 scan, and TERM-then-KILL with identity verification.
  * ``recovery`` — what of a Job is still alive, the lazy re-derivation of
                 stale records (``orphaned`` / ``interrupted`` /
                 ``finished-unknown``) and ``cancel``.
  * ``runtime`` — the verified immutable per-version Codex copy a Codex job
                 runs from (snapshot, content check, real probe, atomic
                 publish, pin) — ADR 0037 "Codex runtime".
  * ``worker`` — the detached worker entry point (``python3 -m jobs.worker``),
                 in spawn mode and in ``--watch`` (adopt) mode.
  * ``cli``    — the ``boxa-job`` command surface.
"""
