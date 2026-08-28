# Cancelled: pre-sleep Container stop

Status: cancelled

Date: 2026-08-28

## Decision

Do not resume the automatic pre-sleep/power-event Container shutdown work,
including the deferred macOS IOKit implementation and live verification.

The power-event approach did not behave reliably in real use. The previously
implemented power-watch and warm-hook path was removed in commit `cb3af7d`.
The remaining macOS issues depended on that same abandoned behavior, so they
are cancelled rather than waiting for a Mac session.

The preserved `issues/` and `mac-deferred/` directories are historical context,
not open work. A future shutdown design must start from fresh evidence and an
explicit new decision instead of reopening these issues.
