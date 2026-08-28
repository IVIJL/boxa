# 09 — Keep-awake Windows backend

Status: done

## Parent

ADR 0023 (consumer side); issue 08 defines the daemon this extends.

## What to build

The Windows sleep-inhibitor backend for the Go daemon: hold
`SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)` while at
least one holder is live, clear it (plain `ES_CONTINUOUS`) when the last
one expires or idles. Display may sleep; only system sleep is inhibited.

This replaces the user's working PowerShell prototype — reference copy
at `../reference/AgentAwake.ps1`, with `../reference/NOTES.md` as
required reading (trench lessons from 2026-07-30, incl. why direct
container→Windows routes all failed). Behaviour to carry over, verified
against the prototype:

- The inhibition call runs on a single dedicated OS thread
  (`ES_CONTINUOUS` state is per-thread; a goroutine hopping threads
  silently drops it — use `runtime.LockOSThread`).
- Interfaces to bind on Windows include the WSL vEthernet address, so
  WSL-host clients and (via the Host connection) boxa containers reach
  it; still never 0.0.0.0.
- Tray/indicator stays a separate optional process (out of scope here);
  the daemon must run fine headless as a scheduled-task child.

## Acceptance criteria

- [ ] On Windows: busy → `powercfg /requests` (or equivalent) shows the
      system request; last release → request gone.
- [ ] Inhibition survives many busy/idle cycles (no thread-affinity
      leak).
- [ ] WSL-host curl to the vEthernet address works; LAN address does
      not.
- [x] Backend sits behind the issue-08 inhibitor interface; non-Windows
      builds are unaffected.
- [x] Manual verification steps documented in this issue's Comments
      after implementation (CI has no Windows runner).

## Blocked by

`08-keep-awake-daemon-core.md`

## Comments

2026-07-30 (agent): Implemented in commit 6458da1 —
`keep-awake/internal/inhibit/inhibit_windows.go`. Backend uses
`syscall.NewLazyDLL("kernel32.dll").NewProc("SetThreadExecutionState")`
(stdlib only, no cgo, no x/sys). A single goroutine spawned in `New()`
calls `runtime.LockOSThread()` and owns all SetThreadExecutionState
calls for the inhibitor's lifetime; Acquire/Release/Close talk to it via
a request channel. Acquire sets `ES_CONTINUOUS|ES_SYSTEM_REQUIRED`
(0x80000001), Release/Close clear with plain `ES_CONTINUOUS`
(0x80000000); return value 0 is treated as failure. Display sleep is
NOT inhibited (no ES_DISPLAY_REQUIRED), per spec.

DEFERRED verification (no Go toolchain in container, no Windows CI) —
manual steps for the user on the Windows host:

1. Build: `GOOS=windows go build ./...` from `keep-awake/` (or build on
   Windows directly); also `go build ./...` + `go test ./...` on Linux
   to confirm non-Windows builds/tests unaffected.
2. Run the daemon on Windows, mark an agent busy (e.g.
   `curl http://<vEthernet-ip>:<port>/busy/claude` from WSL).
3. `powercfg /requests` in an elevated prompt → SYSTEM section must show
   the daemon's executable holding a request. (Alternative: leave the
   machine past its sleep timeout and confirm it stays awake.)
4. Mark idle (or wait out the TTL) → `powercfg /requests` shows the
   SYSTEM request gone.
5. Cycle busy/idle ~20+ times, confirm the request appears/disappears
   each time and the process's thread count stays flat (no
   thread-affinity leak) — e.g. watch Threads in Task Manager/Process
   Explorer.
6. Network binding criterion (WSL vEthernet reachable, LAN address not)
   is daemon-listener scope, not this backend file — verify with curl
   from WSL host vs. another LAN machine once the listener config from
   issue 08 runs on Windows.
