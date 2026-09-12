#!/bin/bash
set -euo pipefail

# =============================================================================
# boxa-job — Container-owned Job CLI wrapper (ADR 0037, issue 01)
# =============================================================================
# Agents call this from their shell tool to run long work as a Job: the Job's
# lifetime, state and result belong to the Container, not to the shell call,
# the subagent, or the session that started it. `start` returns at once with a
# jobId; `wait` blocks up to a caller-bounded time and returns `running` on
# expiry, which only means "call again".
#
# This is a thin shell front-end in the same shape as `boxa-mcp-run`: all
# logic (key semantics, Project lock, reservation, the detached worker, output
# discipline) lives in the unit-tested Python core (`jobs.cli`). The wrapper
# only locates that core and forwards its args.
#
# The Python package ships into the image at a fixed share dir so this wrapper
# resolves `import jobs` regardless of CWD (the agent launches it from
# anywhere). A repo-checkout fallback keeps it runnable from a source tree
# without an image rebuild, which is how this slice is developed and proven.
#
# Container-only: the Python core needs a Project identity (ADR 0011's
# Container identity file) to scope Job keys, and refuses to run without one.
# =============================================================================

# Preferred in-image location of the Python package's parent dir.
_JOBS_SHARE_DIR="/usr/local/share/boxa"

if [ -d "$_JOBS_SHARE_DIR/jobs" ]; then
    JOBS_PY_DIR="$_JOBS_SHARE_DIR"
else
    # Dev/test fallback: run from a repo checkout (scripts/jobs/ alongside us).
    JOBS_PY_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
fi

PYTHONPATH="$JOBS_PY_DIR${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m jobs.cli "$@"
