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
are limited to the append-only `keep-awake.log`, configurable with `-log-file`.

Linux uses a managed `systemd-inhibit --what=idle:sleep` process, macOS uses a
managed `caffeinate -i` process, and Windows uses `SetThreadExecutionState` on
a dedicated OS thread.

Power-watch stops boxes only before shutdown. Linux uses a systemd-logind
shutdown delay inhibitor; Windows uses a hidden-window message pump and a
45-second maximum for the shutdown stop. Sleep and resume do not trigger box
stops, state recording, or notifications. macOS Power-watch is a no-op.
