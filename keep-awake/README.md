# keep-awake

`keep-awake` is a headless host daemon that prevents system idle sleep while
one or more coding agents hold a live lease. All lease state is in memory.

## HTTP API

The versioned API uses `GET` so simple shell hooks can signal it without a
request body:

```text
GET /v1/busy/<agent>?ttl=<seconds>&session=<id>
GET /v1/idle/<agent>?session=<id>
GET /v1/status
```

Busy calls create or re-arm an agent/session lease. The default TTL is 15
minutes. Idle releases exactly the matching lease; omitting `session` affects
only the sessionless lease. Status returns active holders, rounded-up remaining
TTL seconds, current inhibitor state, and daemon version.

## Binding and files

The daemon listens on `127.0.0.1:17777` by default. Add each container or WSL
arrival interface explicitly, for example:

```text
keep-awake -listen-unsafe -listen-address 192.168.65.1 -listen-address 172.17.0.1
```

Only loopback addresses are accepted unless `-listen-unsafe` explicitly opts
into non-loopback interfaces, which may include LAN-facing ones. Only literal
IP addresses are accepted and wildcard addresses (`0.0.0.0` and `::`) are
always rejected. Binding the port is the single-instance guard. The disk writes
are the append-only `keep-awake.log`, configurable with `-log-file`, and, on
Windows, a small suspend-state file that is cleared after resume.

Linux uses a managed `systemd-inhibit --what=idle:sleep` process, macOS uses a
managed `caffeinate -i` process, and Windows uses `SetThreadExecutionState` on
a dedicated OS thread.

Power-watch stops boxes before native Linux sleep/shutdown events. On Windows
it predicts idle sleep from the active power-plan timeout and user idle time,
then stops boxes about one minute before the deadline when no lease is held. A
hidden-window message pump also runs a bounded stop during shutdown and records
actually running boxes during manual sleep so resume can raise a Closeout
notification without restarting or healing anything.
