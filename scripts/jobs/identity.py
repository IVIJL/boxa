"""Project and Container identity for Jobs (ADR 0037).

A Job key is scoped to one Project, so every Job lives under a directory
derived from the Container identity's Project key (ADR 0011 / 0014).  The
Container run id is the nonce that distinguishes this Container run from the
previous one; issue 02 makes the entrypoint write it to ``/run/boxa/run-id``,
until then a missing file degrades to ``unknown`` (which later slices treat as
an unclear state, never as a match).
"""

from __future__ import annotations

import hashlib
import os
from typing import Optional

from mcp import identity as mcp_identity

# Test/seam override for the Project key.  Never set in production: the real
# key comes from the Container identity file the entrypoint writes.
PROJECT_KEY_ENV = "BOXA_JOB_PROJECT_KEY"

# Container run id written by the entrypoint (issue 02).  The path is
# overridable for tests only.
DEFAULT_RUN_ID_PATH = "/run/boxa/run-id"
RUN_ID_PATH_ENV = "BOXA_JOB_RUN_ID_PATH"

# Placeholder recorded while the entrypoint does not yet write a run id.
UNKNOWN_RUN_ID = "unknown"


class IdentityError(RuntimeError):
    """No Project identity — boxa-job was invoked outside a Container."""


def run_id_path() -> str:
    return os.environ.get(RUN_ID_PATH_ENV) or DEFAULT_RUN_ID_PATH


def container_run_id() -> str:
    """This Container run's nonce, or ``unknown`` when it is not written yet."""
    try:
        with open(run_id_path(), "r", encoding="utf-8") as fh:
            value = fh.read().strip()
    except OSError:
        return UNKNOWN_RUN_ID
    return value or UNKNOWN_RUN_ID


def project_key(explicit: Optional[str] = None) -> str:
    """The Project key every Job of this Container is scoped to.

    Order: explicit argument (tests), ``BOXA_JOB_PROJECT_KEY`` (tests), the
    Container identity's full ``projectKey``, then its sanitized Project name.
    Outside a Container none of these exist and the CLI refuses to run.
    """
    if explicit:
        return explicit
    override = os.environ.get(PROJECT_KEY_ENV)
    if override:
        return override
    key = mcp_identity.project_key() or mcp_identity.project_name()
    if not key:
        raise IdentityError(
            "boxa-job must run inside a boxa Container: no Project identity "
            f"found at {mcp_identity.identity_path()}."
        )
    return key


def project_key_hash(key: str) -> str:
    """Short stable directory name for a Project key (keys can be host paths)."""
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]
