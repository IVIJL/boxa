#!/usr/bin/env python3
"""Agent-browser session summary generator (ADR 0010, slice 06).

Merges the Chrome netlog and the proxy harvest log produced during an
Agent-browser session into a single Markdown digest written next to the
raw archives under `/var/log/boxa/agent-browser/`. Invoked by the
broker's `cmd_stop` after both archives are already in place; the
broker treats a non-zero exit as a warning and continues teardown.

Inputs:

  * `--proxy-log` — JSONL written by `scripts/agent-browser-proxy.py`;
    one object per CONNECT/HTTP decision shaped
    `{ts, method, host, port, mode, decision, reason?}`. May be missing
    if no allow-for window ever opened during the session.
  * `--netlog` — Chrome's `--log-net-log` JSON dump. Large JSON object
    with `constants.logEventTypes` (event-name -> numeric type id) and
    `events` (array of `{time, type, source:{id,type}, phase, params?}`).
    May be missing if `--log-net-log` was disabled or the session
    crashed before Chrome flushed it.

If both inputs are missing the summary still writes — the session may
have crashed at start and the user should still get a paper trail.

Trade-off: `json.load` reads the whole netlog into memory. Chrome can
emit tens of MB on a long session; for the agent-browser feature's
expected window (minutes, occasionally an hour) this is acceptable and
keeps the parser short. If real-world sessions push past memory we
revisit with an event-stream parser.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import fnmatch
import json
import subprocess
import sys
import urllib.parse
from collections import Counter, defaultdict
from pathlib import Path

# 1 MB threshold to flag an out-of-allowlist upload as suspicious. Chosen
# because routine API calls (JSON bodies, small form posts) sit well under
# this, while a credential dump, source-tree paste, or screenshot batch
# clears it comfortably. Tunable once we have real harvest data.
LARGE_UPLOAD_BYTES = 1024 * 1024

# Chrome netlog event-type names we care about. Resolved to numeric ids
# via `constants.logEventTypes` at runtime; the netlog uses numeric ids
# in each event record.
#
# Upload/download accounting notes:
#
#   * `URL_REQUEST_JOB_BYTES_READ` / `URL_REQUEST_JOB_FILTERED_BYTES_READ`
#     fire on the URL-request source and give per-host download bytes.
#   * `URL_REQUEST_JOB_BYTES_SENT` exists but Chrome doesn't always emit
#     it for HTTP/2/HTTP/3 — request-body bytes are increasingly visible
#     only at the socket layer (`SOCKET_BYTES_SENT`), and the socket
#     source can't be mapped back to the originating URL request from a
#     single event. We fall back to a session-level upload total from
#     socket-bytes-sent so the headline figure isn't structurally zero
#     on modern Chrome; per-host upload attribution stays best-effort
#     and the user-facing copy admits the gap.
NETLOG_URL_REQUEST_START = "URL_REQUEST_START_JOB"
NETLOG_BYTES_READ = "URL_REQUEST_JOB_BYTES_READ"
NETLOG_FILTERED_BYTES_READ = "URL_REQUEST_JOB_FILTERED_BYTES_READ"
NETLOG_BYTES_SENT_JOB = "URL_REQUEST_JOB_BYTES_SENT"
NETLOG_SOCKET_BYTES_SENT = "SOCKET_BYTES_SENT"
NETLOG_SOCKET_BYTES_RECEIVED = "SOCKET_BYTES_RECEIVED"
NETLOG_NATIVE_MESSAGING_PREFIX = "NATIVE_MESSAGING"
NETLOG_DOWNLOAD_PREFIX = "DOWNLOAD"


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Agent-browser session summary generator",
    )
    parser.add_argument("--netlog", default=None,
                        help="path to Chrome --log-net-log JSON; may be missing")
    parser.add_argument("--proxy-log", default=None,
                        help="path to proxy JSONL; may be missing")
    parser.add_argument("--allowlist", default=None,
                        help="path to agent-browser-allowed-domains.conf so "
                             "harvest-mode requests that already match the "
                             "allowlist are not double-counted as 'out of "
                             "allowlist'; missing/unreadable -> empty list")
    parser.add_argument("--output", required=True,
                        help="path of the .summary.md file to write")
    parser.add_argument("--session-start", required=True,
                        help="ISO-8601 session start (from session JSON)")
    parser.add_argument("--session-end", required=True,
                        help="ISO-8601 session end (from session JSON or 'now')")
    parser.add_argument("--container", required=True,
                        help="container name for the summary header")
    return parser.parse_args(argv)


def _parse_iso(value: str) -> _dt.datetime | None:
    raw = (value or "").strip()
    if not raw:
        return None
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = _dt.datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_dt.timezone.utc)
    return parsed.astimezone(_dt.timezone.utc)


def _format_duration(start: _dt.datetime | None, end: _dt.datetime | None) -> str:
    if start is None or end is None:
        return "unknown"
    delta = end - start
    total = int(delta.total_seconds())
    if total < 0:
        return "unknown"
    hours, rem = divmod(total, 3600)
    minutes, seconds = divmod(rem, 60)
    parts: list[str] = []
    if hours:
        parts.append(f"{hours}h")
    if minutes or hours:
        parts.append(f"{minutes}m")
    parts.append(f"{seconds}s")
    return " ".join(parts)


def _format_bytes(n: int | None) -> str:
    if n is None:
        return "unavailable"
    if n < 1024:
        return f"{n} B"
    units = ("KiB", "MiB", "GiB", "TiB")
    val = float(n) / 1024.0
    for unit in units:
        if val < 1024.0 or unit == units[-1]:
            return f"{val:.1f} {unit}"
        val /= 1024.0
    # Unreachable but keeps the type checker happy.
    return f"{n} B"


def _load_allowlist_patterns(path: Path | None) -> list[str]:
    """Mirror of `agent-browser-proxy.py::_read_allowlist`: best-effort
    parse of the same conf format the proxy reads. We don't need full
    schema validation here — the proxy's already done it at session
    start — just enough to classify hosts the same way."""
    if path is None or not path.exists():
        return []
    patterns: list[str] = []
    try:
        with path.open("r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if any(c.isspace() for c in line) or "/" in line:
                    continue
                patterns.append(line.lower())
    except OSError:
        return []
    return patterns


def _host_in_allowlist(host: str, patterns: list[str]) -> bool:
    """Same matching rules as the proxy daemon (fnmatch, with the
    leading-`*.` convenience to cover the bare apex)."""
    host_lc = host.lower()
    for pat in patterns:
        if fnmatch.fnmatchcase(host_lc, pat):
            return True
        if pat.startswith("*.") and host_lc == pat[2:]:
            return True
    return False


class ProxyLog:
    """Parsed view over the harvest JSONL produced by the proxy daemon."""

    def __init__(self) -> None:
        self.lines_read = 0
        self.parse_errors = 0
        self.records: list[dict] = []
        self.allowed_default: Counter[str] = Counter()
        self.allowed_harvest_in_list: Counter[str] = Counter()
        self.allowed_harvest_out_of_list: Counter[str] = Counter()
        self.denied: Counter[str] = Counter()
        self.harvest_timestamps: list[tuple[_dt.datetime, str]] = []

    @property
    def total_requests(self) -> int:
        return len(self.records)

    @property
    def distinct_hosts(self) -> set[str]:
        return {r["host"] for r in self.records if r.get("host")}

    @classmethod
    def from_path(cls, path: Path | None,
                  allowlist_patterns: list[str]) -> ProxyLog | None:
        if path is None:
            return None
        if not path.exists():
            return None
        instance = cls()
        try:
            with path.open("r", encoding="utf-8") as fh:
                for raw in fh:
                    line = raw.strip()
                    if not line:
                        continue
                    instance.lines_read += 1
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        instance.parse_errors += 1
                        continue
                    if not isinstance(record, dict):
                        instance.parse_errors += 1
                        continue
                    instance.records.append(record)
                    # Lowercase here so cross-reference against the
                    # netlog (which `_hostname()` already lowercases on
                    # the way in) matches case-insensitively. DNS hosts
                    # are case-insensitive but proxy clients are free
                    # to vary the case in their CONNECT/Host headers.
                    host = (record.get("host") or "").lower()
                    mode = record.get("mode") or ""
                    decision = record.get("decision") or ""
                    if decision == "allow" and mode == "default":
                        instance.allowed_default[host] += 1
                    elif decision == "allow" and mode == "harvest":
                        # The proxy's `_decision()` short-circuits when
                        # mode is harvest, so the JSONL `mode` field
                        # alone can't tell us whether the host was
                        # actually out-of-allowlist or just happened to
                        # be visited during a window. Re-check against
                        # the allowlist here so the summary's harvest
                        # section reports only the rows that justify
                        # opening the window in the first place.
                        if _host_in_allowlist(host, allowlist_patterns):
                            instance.allowed_harvest_in_list[host] += 1
                        else:
                            instance.allowed_harvest_out_of_list[host] += 1
                            ts_parsed = _parse_iso(record.get("ts") or "")
                            if ts_parsed is not None and host:
                                instance.harvest_timestamps.append((ts_parsed, host))
                    elif decision == "deny":
                        instance.denied[host] += 1
        except OSError as exc:
            print(f"agent-browser-summarize: proxy-log read failed: {exc}",
                  file=sys.stderr)
            return None
        return instance


class Netlog:
    """Parsed view over the Chrome netlog. May fail to parse on a
    truncated dump — callers see `available = False` in that case."""

    def __init__(self) -> None:
        self.available = False
        self.parse_error: str | None = None
        self.urls_by_request_source: dict[int, str] = {}
        self.distinct_hosts: set[str] = set()
        self.bytes_sent_by_host: defaultdict[str, int] = defaultdict(int)
        self.bytes_read_by_host: defaultdict[str, int] = defaultdict(int)
        self.upload_total: int = 0
        self.download_total: int = 0
        self.hard_fails: list[dict] = []

    @classmethod
    def from_path(cls, path: Path | None) -> Netlog | None:
        if path is None:
            return None
        if not path.exists():
            return None
        instance = cls()
        try:
            with path.open("r", encoding="utf-8") as fh:
                payload = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            instance.parse_error = str(exc)
            return instance
        if not isinstance(payload, dict):
            instance.parse_error = "netlog root is not a JSON object"
            return instance

        constants = payload.get("constants") or {}
        events = payload.get("events") or []
        if not isinstance(events, list):
            instance.parse_error = "netlog 'events' is not a list"
            return instance

        # `logEventTypes` maps name -> numeric id. We invert it so we can
        # name the events that appear in the stream. A truncated netlog
        # may lack the constants table entirely; in that case we surface
        # what we can but skip the type-keyed extraction.
        event_types_by_name = constants.get("logEventTypes") or {}
        if not isinstance(event_types_by_name, dict):
            event_types_by_name = {}
        id_to_name: dict[int, str] = {}
        for name, type_id in event_types_by_name.items():
            if isinstance(name, str) and isinstance(type_id, int):
                id_to_name[type_id] = name

        instance._scan_events(events, id_to_name)
        instance.available = True
        return instance

    def _scan_events(self, events: list, id_to_name: dict[int, str]) -> None:
        for event in events:
            if not isinstance(event, dict):
                continue
            type_id = event.get("type")
            if not isinstance(type_id, int):
                continue
            event_name = id_to_name.get(type_id, "")
            params = event.get("params") or {}
            if not isinstance(params, dict):
                params = {}
            source = event.get("source") or {}
            if not isinstance(source, dict):
                source = {}
            source_id = source.get("id") if isinstance(source.get("id"), int) else None

            self._maybe_record_url(event_name, params, source_id)
            self._maybe_record_bytes(event_name, params, source_id)
            self._maybe_record_hard_fail(event_name, params, event.get("time"))

    def _maybe_record_url(self, event_name: str, params: dict,
                          source_id: int | None) -> None:
        if event_name != NETLOG_URL_REQUEST_START:
            return
        url = params.get("url")
        if not isinstance(url, str) or not url:
            return
        if source_id is not None:
            self.urls_by_request_source[source_id] = url
        host = _hostname(url)
        if host:
            self.distinct_hosts.add(host)

    def _maybe_record_bytes(self, event_name: str, params: dict,
                            source_id: int | None) -> None:
        relevant = (NETLOG_BYTES_READ, NETLOG_FILTERED_BYTES_READ,
                    NETLOG_BYTES_SENT_JOB, NETLOG_SOCKET_BYTES_SENT,
                    NETLOG_SOCKET_BYTES_RECEIVED)
        if event_name not in relevant:
            return
        byte_count = params.get("byte_count")
        if not isinstance(byte_count, int) or byte_count <= 0:
            return
        # URL-request-attributed events have a `source_id` that maps to a
        # URL we captured at URL_REQUEST_START_JOB. Socket-level events
        # belong to a SOCKET source, which we don't track — those bytes
        # contribute to the session-wide total but not the per-host
        # attribution. This is the documented limitation in the module-
        # level comment.
        host = ""
        if source_id is not None:
            url = self.urls_by_request_source.get(source_id, "")
            host = _hostname(url)
        if event_name in (NETLOG_BYTES_SENT_JOB, NETLOG_SOCKET_BYTES_SENT):
            self.upload_total += byte_count
            if host:
                self.bytes_sent_by_host[host] += byte_count
        else:
            self.download_total += byte_count
            if host:
                self.bytes_read_by_host[host] += byte_count

    def _maybe_record_hard_fail(self, event_name: str, params: dict,
                                time_value: object) -> None:
        url = params.get("url")
        if isinstance(url, str):
            lowered = url.lower()
            if lowered.startswith("file://"):
                self.hard_fails.append({
                    "ts": str(time_value) if time_value is not None else "",
                    "what": "file:// navigation attempt",
                    "target": url,
                })
            elif lowered.startswith("chrome://"):
                self.hard_fails.append({
                    "ts": str(time_value) if time_value is not None else "",
                    "what": "chrome:// navigation attempt",
                    "target": url,
                })
        if event_name.startswith(NETLOG_NATIVE_MESSAGING_PREFIX):
            self.hard_fails.append({
                "ts": str(time_value) if time_value is not None else "",
                "what": f"native messaging event: {event_name}",
                "target": json.dumps(params, ensure_ascii=False)[:200],
            })
        # Denied downloads: Chrome surfaces these as a DOWNLOAD_*
        # event whose params carry a `danger_type` or `interrupt_reason`
        # set to a non-zero / non-"NONE" value. Either signal alone is
        # enough — `danger_type` flags a download Chrome's safe-browsing
        # classifier blocked (no interrupt yet), `interrupt_reason`
        # flags a download Chrome stopped mid-stream (policy or
        # filesystem). Both belong in the hard-fails table.
        if event_name.startswith(NETLOG_DOWNLOAD_PREFIX):
            interrupt = params.get("interrupt_reason")
            danger = params.get("danger_type")
            interrupt_flagged = interrupt not in (None, 0, "NONE")
            danger_flagged = danger not in (None, 0, "NOT_DANGEROUS",
                                            "DOWNLOAD_DANGER_TYPE_NOT_DANGEROUS")
            if interrupt_flagged or danger_flagged:
                target_bits: list[str] = []
                if interrupt_flagged:
                    target_bits.append(f"interrupt_reason={interrupt}")
                if danger_flagged:
                    target_bits.append(f"danger_type={danger}")
                self.hard_fails.append({
                    "ts": str(time_value) if time_value is not None else "",
                    "what": f"denied/interrupted download ({event_name})",
                    "target": ", ".join(target_bits),
                })


def _hostname(url: str) -> str:
    if not url:
        return ""
    try:
        parsed = urllib.parse.urlsplit(url)
    except ValueError:
        return ""
    return (parsed.hostname or "").lower()


def _render(args: argparse.Namespace, proxy: ProxyLog | None,
            netlog: Netlog | None) -> str:
    start_dt = _parse_iso(args.session_start)
    end_dt = _parse_iso(args.session_end)
    duration = _format_duration(start_dt, end_dt)

    netlog_path = Path(args.netlog) if args.netlog else None
    proxy_path = Path(args.proxy_log) if args.proxy_log else None

    lines: list[str] = []
    lines.append(f"# Agent-browser session summary — {args.container}")
    lines.append("")
    lines.append(f"- Container: `{args.container}`")
    lines.append(f"- Session start: `{args.session_start}`")
    lines.append(f"- Session end:   `{args.session_end}`")
    lines.append(f"- Duration:      {duration}")
    if netlog_path is not None:
        present = "present" if (netlog and netlog.available) else (
            "unparseable" if netlog else "missing")
        lines.append(f"- Netlog:        `{netlog_path.name}` ({present})")
    else:
        lines.append("- Netlog:        not provided")
    if proxy_path is not None:
        present = "present" if proxy else "missing"
        lines.append(f"- Proxy log:     `{proxy_path.name}` ({present})")
    else:
        lines.append("- Proxy log:     not provided")
    lines.append("")

    # --- Stats ---------------------------------------------------------------
    lines.append("## Stats")
    lines.append("")
    if proxy is None and (netlog is None or not netlog.available):
        lines.append("No logs available — session may have crashed before "
                     "either log could be written.")
        lines.append("")
    else:
        total_requests = proxy.total_requests if proxy else 0
        distinct = set()
        if proxy:
            distinct.update(proxy.distinct_hosts)
        if netlog and netlog.available:
            distinct.update(netlog.distinct_hosts)
        upload = _format_bytes(netlog.upload_total) if (
            netlog and netlog.available) else "unavailable"
        download = _format_bytes(netlog.download_total) if (
            netlog and netlog.available) else "unavailable"
        lines.append(f"- Total proxy requests: {total_requests}")
        lines.append(f"- Distinct hosts:       {len(distinct)}")
        lines.append(f"- Upload bytes:         {upload}")
        lines.append(f"- Download bytes:       {download}")
        if proxy and proxy.parse_errors:
            lines.append(f"- Proxy-log parse errors: {proxy.parse_errors}")
        lines.append("")

    # --- Allowed (in-allowlist) ---------------------------------------------
    # Sum in-allowlist hits from both default-mode (proxy enforced the
    # match) and harvest-mode (the proxy let everything through but the
    # host still matched a rule). Merged counts give the user the full
    # picture of normal allowed traffic regardless of mode.
    lines.append("## Allowed (in-allowlist)")
    lines.append("")
    if proxy is None:
        lines.append("Proxy log unavailable — no allowed-host data.")
    else:
        merged: Counter[str] = Counter()
        merged.update(proxy.allowed_default)
        merged.update(proxy.allowed_harvest_in_list)
        if not merged:
            lines.append("No in-allowlist requests recorded.")
        else:
            lines.append("| Host | Requests |")
            lines.append("| --- | ---: |")
            for host, count in merged.most_common():
                lines.append(f"| `{host}` | {count} |")
    lines.append("")

    # --- Out of allowlist ----------------------------------------------------
    lines.append("## Out of allowlist (harvest window)")
    lines.append("")
    if proxy is None:
        # AC #5: missing harvest log -> exact phrasing the issue specifies.
        lines.append("No harvest window opened during this session.")
    elif not proxy.allowed_harvest_out_of_list:
        # Harvest log present but no out-of-allowlist hits — either no
        # window was ever active, or the agent stayed inside the
        # allowlist while it was active.
        lines.append("No out-of-allowlist requests recorded during this "
                     "session.")
    else:
        lines.append(f"Threshold for upload flagging: {_format_bytes(LARGE_UPLOAD_BYTES)} "
                     "(per-host upload, cross-referenced from netlog). "
                     "Per-host attribution depends on netlog "
                     "`URL_REQUEST_JOB_BYTES_SENT` events; HTTP/2/HTTP/3 "
                     "uploads may show 0 B even when the session total "
                     "in Stats is non-zero.")
        lines.append("")
        lines.append("| Host | Requests | Upload bytes | Flag |")
        lines.append("| --- | ---: | ---: | :---: |")
        for host, count in proxy.allowed_harvest_out_of_list.most_common():
            upload_bytes = None
            if netlog and netlog.available:
                upload_bytes = netlog.bytes_sent_by_host.get(host, 0)
            upload_cell = _format_bytes(upload_bytes) if upload_bytes is not None \
                else "unavailable"
            flag_cell = ""
            if upload_bytes is not None and upload_bytes > LARGE_UPLOAD_BYTES:
                flag_cell = "[LARGE UPLOAD]"
            lines.append(f"| `{host}` | {count} | {upload_cell} | {flag_cell} |")
    lines.append("")

    # --- Denied (default-mode blocks) ---------------------------------------
    # Default-mode hits the agent made against hosts NOT in the allowlist
    # — the proxy refused them with HTTP 403. Surfacing these alongside
    # the harvest section gives the user a single place to see candidate
    # hosts to promote into the allowlist, and lets a default-only
    # session still produce an actionable digest when the agent reached
    # past its allowed set.
    lines.append("## Denied (out of allowlist, blocked in default mode)")
    lines.append("")
    if proxy is None:
        lines.append("Proxy log unavailable — no denied-host data.")
    elif not proxy.denied:
        lines.append("None — agent stayed within the allowlist while in "
                     "default mode.")
    else:
        lines.append("| Host | Blocked attempts |")
        lines.append("| --- | ---: |")
        for host, count in proxy.denied.most_common():
            lines.append(f"| `{host}` | {count} |")
    lines.append("")

    # --- Hard fails ----------------------------------------------------------
    lines.append("## Hard fails")
    lines.append("")
    if netlog is None or not netlog.available:
        reason = "missing" if netlog is None else "unparseable"
        lines.append(f"Netlog {reason} — `file://`/`chrome://`/native-messaging "
                     "/download detection skipped.")
    elif not netlog.hard_fails:
        lines.append("None detected.")
    else:
        lines.append("| Time | What | Target |")
        lines.append("| --- | --- | --- |")
        for entry in netlog.hard_fails:
            target = entry["target"].replace("|", "\\|")
            what = entry["what"].replace("|", "\\|")
            lines.append(f"| `{entry['ts']}` | {what} | `{target}` |")
    lines.append("")

    # --- Pointers ------------------------------------------------------------
    lines.append("## Pointers")
    lines.append("")
    if netlog_path is not None:
        lines.extend(_pointer_lines("Netlog", netlog_path))
    if proxy_path is not None:
        lines.extend(_pointer_lines("Proxy log", proxy_path))
    if netlog_path is None and proxy_path is None:
        lines.append("- (no raw log files associated with this session)")
    lines.append("")

    return "\n".join(lines)


def _is_wsl2() -> bool:
    """True on WSL2 hosts.

    Same probe as scripts/deliver-allow-for-notification.sh::is_wsl2 —
    /proc/version contains "Microsoft" on every WSL kernel build.
    """
    try:
        return "microsoft" in Path("/proc/version").read_text().lower()
    except OSError:
        return False


def _wsl_file_uri(path: Path) -> str | None:
    """Render a Linux path as a `file://wsl.localhost/<distro>/...` URI.

    Uses `wslpath -w` to get the UNC form (which embeds the active distro
    name), flips backslashes to forward slashes, then percent-encodes per
    RFC 8089. Mirrors the bash `to_file_uri` in
    scripts/deliver-allow-for-notification.sh. Returns None if wslpath
    is unavailable or fails so the caller can fall back silently — the
    relative-basename link is still emitted unconditionally.
    """
    try:
        result = subprocess.run(
            ["wslpath", "-w", str(path)],
            capture_output=True,
            text=True,
            check=True,
            timeout=2.0,
        )
    except (FileNotFoundError, subprocess.SubprocessError):
        return None
    unc = result.stdout.strip()
    if not unc:
        return None
    forward = unc.replace("\\", "/")
    # `/` and `:` stay literal so the path stays a path; everything else
    # outside the URI-safe set gets percent-encoded. Real triggers in
    # archive filenames: none today, but `+` in ISO offsets and spaces in
    # a renamed distro would otherwise break the URL.
    quoted = urllib.parse.quote(forward, safe="/:")
    return f"file:{quoted}"


def _pointer_lines(label: str, path: Path) -> list[str]:
    """Render one archive pointer as one (or two) clickable Markdown lines.

    Always emits a relative-basename link — the summary lives in the same
    archive dir as the file it points at, so the basename is enough for
    VS Code, GitHub, and any Markdown previewer that resolves relative
    links against the document's location.

    On WSL2 the system-absolute form changes meaning depending on whether
    the renderer treats it as Linux or Windows, so we additionally emit a
    `file://wsl.localhost/<distro>/...` URL — Windows Terminal Ctrl+Click
    opens it in the default `.json`/`.log` handler and the VS Code
    Markdown preview routes it through the OS shell.
    """
    basename = path.name
    out = [f"- {label}: [`{basename}`]({basename})"]
    if _is_wsl2():
        wsl_uri = _wsl_file_uri(path)
        if wsl_uri is not None:
            out.append(f"  - Windows: [`{path}`]({wsl_uri})")
    return out


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    proxy_path = Path(args.proxy_log) if args.proxy_log else None
    netlog_path = Path(args.netlog) if args.netlog else None
    allowlist_path = Path(args.allowlist) if args.allowlist else None

    allowlist_patterns = _load_allowlist_patterns(allowlist_path)
    proxy = ProxyLog.from_path(proxy_path, allowlist_patterns)
    netlog = Netlog.from_path(netlog_path)

    markdown = _render(args, proxy, netlog)

    output_path = Path(args.output)
    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(markdown, encoding="utf-8")
    except OSError as exc:
        print(f"agent-browser-summarize: failed to write {output_path}: {exc}",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
