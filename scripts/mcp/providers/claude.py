"""Claude Code import provider (ADR 0013, issue 02).

Reads Claude Code's existing MCP state and normalizes it into the
provider-neutral `Candidate` shape from `mcp.candidate`. This is the first
real import provider; issue 03 merges multiple providers, issue 04 classifies.

Source of truth on disk
------------------------
Claude Code keeps a single JSON file at ``~/.claude/.claude.json``. Verified
shape on a real machine:

  * Top level *may* carry a global ``mcpServers`` object (user/global MCP).
    It is absent when the user has no global MCP servers, so we treat it as
    optional.
  * ``projects`` is an object keyed by the **absolute path** of each project
    directory. Each value may carry its own ``mcpServers`` object — those are
    the project-scoped MCP servers.

A single MCP server entry looks like (values redacted here)::

    "context7": {
        "type": "stdio",
        "command": "npx",
        "args": ["-y", "@upstash/context7-mcp@latest"],
        "env": {"CONTEXT7_API_KEY": "<value>"}
    }

``type`` may be omitted (defaults to stdio). Remote/connector servers use a
non-stdio ``type`` (``http`` / ``sse`` / ``remote``) and/or a ``url`` field.

Read-only and secret-safe
-------------------------
The provider only reads the file. It records env-variable *names* (the keys of
the ``env`` object) and never the values, so no secret can enter a Candidate
or the JSON envelope. Remote/connector servers are surfaced as ``excluded``
candidates (ADR 0013 / local-plan-mcp.md core question 9) rather than dropped.
"""

from __future__ import annotations

import json
import os
import re
from typing import Any, Optional

from ..candidate import Candidate, Classification, Command

# Placeholder substituted for any argv value that looks like a secret. Keeps
# the command *shape* visible without ever emitting the credential.
_REDACTED = "<redacted>"

PROVIDER = "claude-code"

# Server types that denote a Claude hosted/remote connector (Gmail, Calendar,
# Drive, and similar). These are not importable Container MCP servers in v1;
# they are surfaced as excluded for visibility (ADR 0013 / local-plan-mcp.md
# core question 9), not silently dropped.
_REMOTE_TYPES = {"http", "sse", "remote", "ws", "websocket"}

# Substrings (case-insensitive) in an env-var NAME that mark its VALUE as
# sensitive. Names only — values are never inspected or stored. Conservative
# on purpose: a false positive only adds a name to secretEnvKeys (still just a
# name), while a miss would understate which values an apply step must protect.
_SECRET_NAME_HINTS = (
    "KEY",
    "TOKEN",
    "SECRET",
    "PASSWORD",
    "PASSWD",
    "CREDENTIAL",
    "AUTH",
    "ACCESS_KEY",
    "PRIVATE",
    "SESSION",
)

# `PAT` (personal access token) is too short to match as a bare substring — it
# would flag innocuous flags like `--path`. Match it only as a delimited token
# (start/end or separated by `_`/`-`), e.g. `GITHUB_PAT`, `PAT_TOKEN`, `--pat`.
_PAT_TOKEN = re.compile(r"(?:^|[_-])PAT(?:$|[_-])")


def candidate_config_paths() -> list[str]:
    """Ordered Claude config-file locations to probe.

    Claude Code's project/MCP metadata file (`.claude.json`) lives in different
    places depending on how Claude was started (ADR 0002):

      * ``$CLAUDE_CONFIG_DIR/.claude.json`` — authoritative whenever the env
        var is set. This is the active location inside a boxa Container,
        where ``CLAUDE_CONFIG_DIR=/home/node/.claude``.
      * ``~/.claude.json`` — Claude Code's host location (one directory up) when
        no ``CLAUDE_CONFIG_DIR`` is set. On a bare host this is the real file
        holding the user's MCP servers.
      * ``~/.claude/.claude.json`` — the config-dir form. Inside boxa this is
        the container's own bind-mounted metadata; on a host it only exists if
        the user explicitly uses a config dir. It is the last fallback so a
        host import does not accidentally read container-written metadata
        instead of the host's ``~/.claude.json``.

    Order therefore is: env override (if set), then host ``~/.claude.json``,
    then the config-dir form. This means ``boxa mcp import`` finds the right
    MCP servers whether it runs inside a Container (env set) or on a bare host
    (no env -> host file preferred).
    """
    home = os.path.expanduser("~")
    paths: list[str] = []
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    if config_dir:
        paths.append(os.path.join(config_dir, ".claude.json"))
    paths.append(os.path.join(home, ".claude.json"))
    paths.append(os.path.join(home, ".claude", ".claude.json"))
    # De-duplicate while preserving order (CLAUDE_CONFIG_DIR may equal a default).
    seen: set[str] = set()
    ordered: list[str] = []
    for p in paths:
        if p not in seen:
            seen.add(p)
            ordered.append(p)
    return ordered


def default_config_path() -> str:
    """Best-guess absolute path to Claude Code's MCP state file.

    Returns the first probed location that exists; if none exist yet, returns
    the highest-priority candidate so callers still have a stable path to
    report. See ``candidate_config_paths`` for the probe order.

    This is the DISCOVERY path (reading what the user has). The RENDER target
    is computed separately by ``render_target_path`` — see that function for the
    split.
    """
    candidates = candidate_config_paths()
    for path in candidates:
        if os.path.isfile(path):
            return path
    return candidates[0]


def render_target_path() -> str:
    """Return the Container-visible Claude config that the agent actually reads.

    Discovery and render are SPLIT (ADR 0014):

      * Discovery uses ``default_config_path`` / ``candidate_config_paths``,
        which probe ``$CLAUDE_CONFIG_DIR`` first and then host-native
        ``~/.claude.json``, because that is where the user's existing servers
        live and ``import`` must find them.
      * Render uses THIS function. The Container runs Claude Code with
        ``CLAUDE_CONFIG_DIR=/home/node/.claude`` and ``docker-run.sh``
        bind-mounts the host ``~/.claude`` directory onto ``/home/node/.claude``
        (``-v "$HOME/.claude:/home/node/.claude"``), so inside the Container the
        agent reads ``~/.claude/.claude.json`` — the config-dir form. boxa's
        ``boxa-``-prefixed entries must land there, regardless of whether a
        host-native ``~/.claude.json`` exists (otherwise they are written where
        the Container never reads them).

    Deliberately does NOT honor ``$CLAUDE_CONFIG_DIR``. ``boxa`` render runs
    on the HOST, where the user may point their OWN host Claude Code at a
    ``CLAUDE_CONFIG_DIR`` that is NOT the directory bind-mounted into the
    Container; honoring it would again write where the Container never reads,
    re-introducing the exact bug this split fixes. The bind-mount source is
    always the host ``~/.claude`` directory, so the render target is always
    ``~/.claude/.claude.json``. When render happens to run INSIDE a Container,
    ``~/.claude`` already equals ``CLAUDE_CONFIG_DIR``, so the result matches.
    """
    home = os.path.expanduser("~")
    return os.path.join(home, ".claude", ".claude.json")


def _name_marks_secret(stem: str) -> bool:
    """True when a normalized UPPER_SNAKE name marks its value as a credential."""
    if any(hint in stem for hint in _SECRET_NAME_HINTS):
        return True
    return bool(_PAT_TOKEN.search(stem))


def _is_secret_env_name(name: str) -> bool:
    return _name_marks_secret(name.upper())


# A CLI flag NAME whose VALUE is a credential (matched case-insensitively after
# stripping leading dashes). Reuses the env-name heuristic so the two stay in
# sync. `PAT` is delimited, so common flags like `--path` are not flagged.
def _is_secret_flag(flag: str) -> bool:
    stem = flag.lstrip("-").upper().replace("-", "_")
    return _name_marks_secret(stem)


# High-confidence secret VALUE shapes (provider token prefixes + long opaque
# blobs). `_looks_like_secret_value` checks whether a *standalone* value is a
# secret; the patterns are anchored at the start so a value like `sk-ant-...`
# is recognized while ordinary args (package names, flags) are not.
_SECRET_VALUE_PATTERNS = (
    re.compile(r"^sk-"),  # OpenAI / Anthropic-style keys
    re.compile(r"^xox[abprs]-"),  # Slack tokens
    re.compile(r"^gh[pousr]_"),  # GitHub tokens
    re.compile(r"^github_pat_"),  # GitHub fine-grained PAT
    re.compile(r"^AKIA[0-9A-Z]{16}$"),  # AWS access key id
    re.compile(r"^[A-Za-z0-9_\-]{40,}$"),  # long opaque token blob
)

# Secret material that may be EMBEDDED inside a larger argv token, e.g.
# `Authorization: Bearer sk-ant-...`, `API_KEY=sk-...`, or
# `--header=X-Token: ghp_...`. Searched anywhere in the token (not anchored);
# any hit means the whole token is redacted, since we cannot know how much of
# it is sensitive. These are deliberately high-signal so structural args
# (package@version specs, paths) are not redacted.
_EMBEDDED_SECRET_PATTERNS = (
    re.compile(r"\bsk-[A-Za-z0-9_-]{8,}"),  # OpenAI / Anthropic keys
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{8,}"),  # Slack tokens
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),  # GitHub tokens
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),  # GitHub fine-grained PAT
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),  # AWS access key id
    re.compile(r"\bBearer\s+[A-Za-z0-9._-]{12,}"),  # HTTP bearer tokens
    # `SECRET_NAME = value` / `Secret-Header: value` style assignments where the
    # left-hand name is itself secret-looking and a non-trivial value follows.
    re.compile(
        r"(?i)\b\w*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH"
        r"|PRIVATE|SESSION)\w*\s*[:=]\s*\S+"
    ),
)


def _looks_like_secret_value(value: str) -> bool:
    """True when a standalone value looks like a credential (anchored shapes)."""
    return any(pat.search(value) for pat in _SECRET_VALUE_PATTERNS)


def _contains_embedded_secret(token: str) -> bool:
    """True when a token carries credential material anywhere inside it."""
    return any(pat.search(token) for pat in _EMBEDDED_SECRET_PATTERNS)


# Markers that make an argv value clearly *structural* rather than an opaque
# credential: path separators, package/scope/version markers, URLs, key:value
# headers, whitespace. A value carrying any of these is treated as part of the
# command shape and is NOT redacted on its own (it would already be caught by
# the embedded-secret scan if it contained a known token shape).
_STRUCTURAL_VALUE_CHARS = ("/", "@", "\\", " ", "\t")


def _is_opaque_value(value: str) -> bool:
    """True when a value looks like an opaque token rather than a path/name.

    Used only for the value *immediately following a flag*, where credentials
    are commonly passed (e.g. `-k abc123`, `--auth deadbeefcafe`). Conservative:
    a value is opaque when it has no structural separators, is not a plain
    number/boolean/common literal, is reasonably long, and looks token-ish
    (mixed alphanumerics). Structural values (paths, `@scope/pkg`, versions,
    URLs, `key:value`) are preserved so command fidelity survives.
    """
    if not value or value.startswith("-"):
        return False
    if any(ch in value for ch in _STRUCTURAL_VALUE_CHARS):
        return False
    if ":" in value or "." in value:  # urls, versions, host:port, headers
        return False
    lowered = value.lower()
    if lowered in ("true", "false", "null", "none", "yes", "no", "stdio"):
        return False
    if value.isdigit():
        return False
    if len(value) < 6:
        return False
    # Token-ish: contains a digit or is long, and is restricted to the
    # alphabet credentials actually use.
    if not re.fullmatch(r"[A-Za-z0-9_+=~%-]+", value):
        return False
    has_digit = any(c.isdigit() for c in value)
    return has_digit or len(value) >= 16


def _redact_argv(argv: list[str]) -> list[str]:
    """Redact secret-looking values inside an argv list (ADR 0013 secret-safe).

    Cases scrubbed, leaving the command *shape* intact where possible:
      * `--token <value>`        -> value after a secret-looking flag;
      * `--token=<value>`        -> inline value on a secret-looking flag;
      * a bare `<value>` that matches a high-confidence secret pattern;
      * any token with EMBEDDED secret material (e.g.
        `Authorization: Bearer sk-...`, `API_KEY=sk-...`) -> whole token;
      * an OPAQUE value following ANY flag (e.g. `-k abc123`), since a
        credential can be passed through an agent-specific short flag whose
        name does not match the secret-name heuristics.

    Env values are already dropped entirely; this closes the parallel gap for
    credentials passed as command-line arguments. The embedded check runs first
    so secrets buried inside header/assignment tokens never slip through the
    flag/value heuristics below.

    Limitation: a value is, by nature, ambiguous — boxa cannot always know
    whether `--region eu-west` is sensitive. The heuristics err toward
    redaction for opaque, credential-shaped values while preserving clearly
    structural ones (paths, package specs, versions, URLs). The authoritative
    secret handling (the boxa secret store) is applied at `import --apply`
    time; this display path only ever shows redacted placeholders for anything
    that looks like a credential.
    """
    out: list[str] = []
    redact_next = False
    prev_was_flag = False
    for token in argv:
        if redact_next:
            out.append(_REDACTED)
            redact_next = False
            prev_was_flag = False
            continue

        # A `--flag=value` token: redact only the value side when the flag is
        # secret-looking or the value is/embeds a secret, keeping the flag name
        # visible.
        if token.startswith("-") and "=" in token:
            flag, _, value = token.partition("=")
            if (
                _is_secret_flag(flag)
                or _looks_like_secret_value(value)
                or _contains_embedded_secret(value)
            ):
                out.append(f"{flag}={_REDACTED}")
            else:
                out.append(token)
            prev_was_flag = False
            continue

        # A bare `--flag`: keep it, and redact the following value token if the
        # flag is secret-looking. Otherwise the *next* token is still inspected
        # as a possible opaque credential value below.
        if token.startswith("-"):
            out.append(token)
            if _is_secret_flag(token):
                redact_next = True
            prev_was_flag = True
            continue

        # Positional / value token. Redact when it is a secret value, carries
        # embedded secret material, or is an opaque credential-shaped value
        # immediately following a flag.
        if (
            _looks_like_secret_value(token)
            or _contains_embedded_secret(token)
            or (prev_was_flag and _is_opaque_value(token))
        ):
            out.append(_REDACTED)
        else:
            out.append(token)
        prev_was_flag = False

    return out


def _is_remote_connector(spec: dict[str, Any]) -> bool:
    """True when the entry is a hosted/remote connector, not a stdio server."""
    server_type = spec.get("type")
    if isinstance(server_type, str) and server_type.lower() in _REMOTE_TYPES:
        return True
    # A url/httpUrl/sseUrl with no local command is a remote connector even if
    # the type field is missing.
    for url_key in ("url", "httpUrl", "sseUrl"):
        if spec.get(url_key):
            return True
    return False


def _command_from_spec(spec: dict[str, Any]) -> Command:
    """Build a Command (argv + env key names) from a Claude server spec.

    argv = [command, *args]. Env values are dropped on the floor; only the
    key names are kept, and secret-looking names are also flagged.
    """
    argv: list[str] = []
    command = spec.get("command")
    if isinstance(command, str) and command:
        argv.append(command)
    args = spec.get("args")
    if isinstance(args, list):
        argv.extend(str(a) for a in args)

    # Scrub credentials passed as CLI arguments before they enter the model.
    argv = _redact_argv(argv)

    env_keys: list[str] = []
    secret_env_keys: list[str] = []
    env = spec.get("env")
    if isinstance(env, dict):
        for key in env:  # iterate KEYS only; never touch values
            name = str(key)
            env_keys.append(name)
            if _is_secret_env_name(name):
                secret_env_keys.append(name)

    return Command(argv=argv, env_keys=env_keys, secret_env_keys=secret_env_keys)


def _candidate_from_spec(
    name: str,
    spec: dict[str, Any],
    source_path: str,
    source_scope: str,
    source_project: Optional[str],
) -> Candidate:
    server_type = spec.get("type")
    type_str = server_type if isinstance(server_type, str) else None

    if _is_remote_connector(spec):
        # Hosted/remote connector: surfaced as excluded, never importable in
        # v1. confidence "high" — we are certain it cannot be a Container MCP
        # server here. We still keep argv/env-key metadata (names only) for
        # transparency.
        classification = Classification(
            placement="excluded",
            confidence="high",
            reasons=[
                "Claude hosted/remote connector "
                f"(type={type_str or 'remote'}); not importable as a Container "
                "MCP server in v1",
            ],
        )
    else:
        # Container/stdio candidate. This slice does not classify placement
        # (issue 04 owns that), so leave it neutral/unknown.
        classification = Classification(placement="unknown")

    return Candidate(
        provider=PROVIDER,
        source_path=source_path,
        source_scope=source_scope,
        source_project=source_project,
        name=name,
        type=type_str,
        command=_command_from_spec(spec),
        classification=classification,
    )


def _candidates_from_mcp_block(
    mcp_servers: Any,
    source_path: str,
    source_scope: str,
    source_project: Optional[str],
) -> list[Candidate]:
    if not isinstance(mcp_servers, dict):
        return []
    out: list[Candidate] = []
    for name, spec in mcp_servers.items():
        if not isinstance(spec, dict):
            continue
        out.append(
            _candidate_from_spec(
                str(name),
                spec,
                source_path=source_path,
                source_scope=source_scope,
                source_project=source_project,
            )
        )
    return out


class ClaudeProvider:
    """Read-only Claude Code MCP discovery provider.

    Parameters
    ----------
    config_path:
        Path to ``.claude.json``. Defaults to ``~/.claude/.claude.json``.
        Injectable so fixture-based tests do not depend on the real file.
    """

    def __init__(self, config_path: Optional[str] = None) -> None:
        self.config_path = config_path or default_config_path()

    # -- loading -------------------------------------------------------------

    def _load(self) -> Optional[dict[str, Any]]:
        """Read and parse the Claude config, or None if absent/unreadable.

        Read-only: opened for reading only, never written.
        """
        if not os.path.isfile(self.config_path):
            return None
        try:
            with open(self.config_path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) else None

    @staticmethod
    def _global_candidates(data: dict[str, Any], path: str) -> list[Candidate]:
        return _candidates_from_mcp_block(
            data.get("mcpServers"),
            source_path=path,
            source_scope="global",
            source_project=None,
        )

    def _project_candidates(
        self, data: dict[str, Any], path: str, project_key: str
    ) -> list[Candidate]:
        projects = data.get("projects")
        if not isinstance(projects, dict):
            return []
        record = projects.get(project_key)
        if not isinstance(record, dict):
            return []
        return _candidates_from_mcp_block(
            record.get("mcpServers"),
            source_path=path,
            source_scope="project",
            source_project=project_key,
        )

    # -- public discovery API ------------------------------------------------

    def discover_global(self) -> list[Candidate]:
        """Global/user MCP servers (top-level ``mcpServers``)."""
        data = self._load()
        if data is None:
            return []
        return self._global_candidates(data, self.config_path)

    def discover_project(self, project_key: str) -> list[Candidate]:
        """Project-scoped MCP servers for one project record key.

        ``project_key`` is the absolute path Claude uses as the projects map
        key (e.g. ``/home/user/Projekty/app``).
        """
        data = self._load()
        if data is None:
            return []
        return self._project_candidates(data, self.config_path, project_key)

    def project_keys(self) -> list[str]:
        """All known Claude project record keys.

        Returns every project record Claude tracks, not only those that
        currently carry MCP servers. A `--project <name>` token must resolve
        against any real project (it may have no project-scoped MCP yet but
        still get applicable global config), and `--all` records without MCP
        simply yield no project candidates.
        """
        data = self._load()
        if data is None:
            return []
        projects = data.get("projects")
        if not isinstance(projects, dict):
            return []
        return [str(key) for key, record in projects.items() if isinstance(record, dict)]

    def discover(
        self,
        project_keys: Optional[list[str]] = None,
        include_global: bool = True,
        all_projects: bool = False,
    ) -> list[Candidate]:
        """Discover candidates for the requested scope.

        * ``include_global`` adds the top-level ``mcpServers`` block.
        * ``all_projects`` scans every known project record.
        * ``project_keys`` scans those explicit project record keys.

        Global candidates come first, then project candidates in a stable
        order (project key, then server name) so output is deterministic.
        """
        data = self._load()
        if data is None:
            return []

        candidates: list[Candidate] = []
        if include_global:
            candidates.extend(self._global_candidates(data, self.config_path))

        keys: list[str]
        if all_projects:
            keys = self.project_keys()
        else:
            keys = list(project_keys or [])

        for key in keys:
            project_cands = self._project_candidates(data, self.config_path, key)
            project_cands.sort(key=lambda c: c.name)
            candidates.extend(project_cands)

        return candidates
