# 02 — host-side jq is a hard dependency but is never installed or checked

Status: done

## Parent

Spawned from issue 01 review discussion: the config purge leans on
`projects.json` (jq), which surfaced that host-side jq is unguarded.

## What to build

The host CLI uses `jq` unguarded in core paths — `docker-run.sh`
(10 call sites, incl. `_boxa::record_project` over `projects.json`,
which `boxa remove`'s new config purge also depends on) and
`lib/forge.sh`. The Dockerfile installs jq only inside the container;
`install.sh` neither installs nor checks it on the host (it covers git,
keychain, xhost, docker, mkcert). On a host without jq these paths fail
with raw "command not found" noise.

Close the gap:

- `install.sh`: install jq alongside the other host packages, in every
  supported branch (apt-based Linux, Homebrew on macOS), following the
  existing install/summary conventions (`INSTALLED+=` / `SKIPPED+=`,
  `has()` guard, idempotent when already present).
- `boxa doctor`: add a host-binaries check reporting missing required
  tools; at minimum jq (docker is already covered elsewhere). Follow
  doctor's existing check/report style in lib/provisioning.sh.
- Do NOT add `command -v jq` guards to every call site — one clear
  install-time + doctor-time signal is the fix; scattering runtime
  guards is out of scope.

## Acceptance criteria

- [x] `install.sh` installs jq when absent on apt and brew branches and
      lists it in the install summary; already-present jq is reported,
      not reinstalled. (Note: apt/brew execution paths not unit-tested —
      installer harness would mutate the host; both branches reuse the
      existing `pkg_install jq` dispatch shared by other packages.)
- [x] `boxa doctor` reports a missing host jq clearly; with jq present
      the check passes silently or as OK per doctor's existing style.
- [x] shellcheck clean on changed files (incl. info-level).
- [x] Tests in the style of existing suites where the harness allows
      (doctor check at minimum; install.sh branches may be
      unit-untestable — note if so).

## Blocked by

None.

## Comments
