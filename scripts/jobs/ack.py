"""Concurrency ack: starting beside other Jobs is never silent (ADR 0037).

A Job key protects against duplicate runs, nothing more. Two Jobs under two
different keys can happily edit the same file in the same checkout, so ADR
0037 refuses the second `start` until the caller names the Jobs it is
knowingly running beside::

    boxa-job start --key b -- cmd            -> needs-ack, lists the others
    boxa-job start --key b --ack-concurrent <ids> -- cmd   -> starts

The ack is not a lock and it is not a force flag: it records the orchestrating
agent's parallelism decision in the new Job's record (``ackConcurrent``), so
the decision is visible afterwards. It must name **exactly** the current set,
order-free; a subset, a superset or an unknown id is stale and gets the
current list back. That exactness is the point — an ack written from a list
the caller never saw would acknowledge nothing.

"Running" here is :data:`jobs.store.RUNNING_STATES` — ``reserved``,
``running``, ``exited-with-survivors``, ``orphaned`` — plus any record this
Project cannot read back (an unclear record whose fate nobody established).
``interrupted`` is deliberately NOT in that set: it is terminal, nothing of it
is alive, and it already refuses a retry under its own key; demanding an ack
for it would make every Container restart cost an ack for work that can never
resume again.

Both ``start`` and (later) ``reply`` gate on :func:`gate`, called under the
Project ``flock`` so the check and the reservation cannot interleave.
"""

from __future__ import annotations

import time
from typing import Any, NamedTuple, Optional

from .store import RUNNING_STATES, JobStoreError, ProjectStore

__all__ = [
    "REQUEST_PREVIEW_CHARS",
    "AckOutcome",
    "Concurrent",
    "concurrent_jobs",
    "gate",
    "parse_ids",
]

# The request line is a reminder of WHICH job is running, not the request. One
# terminal line, so the list stays scannable at ten Jobs.
REQUEST_PREVIEW_CHARS = 80

# Reasons, echoed as `reason` in --json so a skill can branch on them.
REASON_MISSING = "missing-ack"
REASON_STALE = "stale-ack"
REASON_NOT_NEEDED = "ack-not-needed"


class Concurrent(NamedTuple):
    """One other non-finished Job, as the caller needs to see it."""

    job_id: str
    key: Optional[str]
    state: Optional[str]
    started_at: Optional[float]
    request: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "jobId": self.job_id,
            "key": self.key,
            "state": self.state,
            "startedAt": self.started_at,
            "request": self.request,
        }

    def as_line(self) -> str:
        stamp = (
            time.strftime("%H:%M:%S", time.localtime(self.started_at))
            if self.started_at
            else "unknown"
        )
        return (
            f"  {self.job_id}  key={self.key}  {self.state}  "
            f"started={stamp}  req: {self.request}"
        )


class AckOutcome(NamedTuple):
    """Verdict of the gate: either cleared, or a needs-ack to print."""

    ok: bool
    reason: Optional[str]
    ack: list[str]
    concurrent: list[Concurrent]


def parse_ids(value: Optional[str]) -> list[str]:
    """Split ``--ack-concurrent a,b`` into ids, dropping empties."""
    if not value:
        return []
    return [part.strip() for part in value.split(",") if part.strip()]


def _preview(record: dict[str, Any]) -> str:
    argv = record.get("argv") or []
    text = " ".join(str(part) for part in argv).splitlines()
    first = text[0] if text else ""
    if len(first) > REQUEST_PREVIEW_CHARS:
        return first[: REQUEST_PREVIEW_CHARS - 1] + "…"
    return first or "(unknown request)"


def concurrent_jobs(
    store: ProjectStore, exclude_job_id: Optional[str] = None
) -> list[Concurrent]:
    """Every other non-finished Job of this Project, oldest first.

    Call it under the Project lock and after
    :func:`jobs.recovery.refresh_states`, or the answer is only as true as the
    last restart. An unreadable record is reported as an unclear Job rather
    than skipped: a record nobody can read is exactly the case where silence
    would be a lie.
    """
    out: list[Concurrent] = []
    for job_id in store.job_ids():
        if job_id == exclude_job_id:
            continue
        try:
            record = store.load_record(job_id)
        except JobStoreError as exc:
            out.append(
                Concurrent(job_id, None, "unclear", None, f"unreadable record: {exc}")
            )
            continue
        if record is None:
            # A job directory without a published record: a start that never
            # reserved. Nothing owns it, so it is not a concurrent Job.
            continue
        if record.get("state") not in RUNNING_STATES:
            continue
        out.append(
            Concurrent(
                job_id,
                record.get("key"),
                record.get("state"),
                record.get("startedAt") or record.get("reservedAt"),
                _preview(record),
            )
        )
    out.sort(key=lambda item: (item.started_at or 0.0, item.job_id))
    return out


def gate(
    store: ProjectStore,
    ack: list[str],
    exclude_job_id: Optional[str] = None,
) -> AckOutcome:
    """Decide whether this start/reply may proceed beside the running Jobs.

    Cleared when the ack names exactly the current set (including "nothing
    runs, no ack given"). Everything else is a needs-ack carrying the current
    list, so the caller's next call can be right.
    """
    current = concurrent_jobs(store, exclude_job_id)
    given = sorted(set(ack))
    expected = sorted(item.job_id for item in current)
    if given == expected:
        return AckOutcome(True, None, expected, current)
    if not current:
        # An ack for Jobs that have since finished. Honest over convenient:
        # the caller's picture of the Project is out of date either way.
        return AckOutcome(False, REASON_NOT_NEEDED, given, current)
    reason = REASON_MISSING if not given else REASON_STALE
    return AckOutcome(False, reason, given, current)
