# boxa-jobs — deferred macOS verification

ADR 0037 "Codex runtime" (issue 05) has one host-dependent branch that cannot
be proven on Linux/WSL: on macOS `docker-run.sh` mounts NO host
`@openai/codex` package (the host binary is Mach-O and unrunnable in a Linux
Container), so the shared `boxa-npm-global` volume is the only Codex runtime
source. Implemented and unit-tested (`tests/test_jobs_runtime.py`:
`test_absent_host_mount_leaves_the_npm_volume_alone`), never run on a Mac.

## What to verify on a Mac

1. `boxa` start prints no error about the host Codex package, and inside the
   Container `ls /run/boxa-codex-host-pkg` does NOT exist (the Darwin branch
   in `docker-run.sh` skips the bind mount).
2. `boxa-job runtime list` shows exactly one source per version, named
   `npm-volume`, and `/usr/local/share/boxa-codex-versions` is writable by
   `node` (the entrypoint chown works on a Docker Desktop volume too).
3. One Codex job: first run snapshots + probes (`runtime list` → verified),
   `boxa-job result <id> --json` shows `codexBinary` under
   `/usr/local/share/boxa-codex-versions/<version>/package/…`; a second job
   reuses it (`runtimeProbed: false`).
4. `npm install -g @openai/codex@<newer>` inside the Container, then one Codex
   job: the new version is snapshotted and probed once, interactive
   `codex --version` reports the npm-volume version.
5. The vendor static binary in the copy is the **linux** one and runs: the
   copy is made inside the Container, so a Mach-O host package can never leak
   into it.
