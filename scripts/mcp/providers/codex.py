"""Codex CLI import provider (ADR 0013, issue 03) — conservative detector.

Codex keeps its config in a single TOML file at ``~/.codex/config.toml``. MCP
servers, when present, live under ``[mcp_servers.<name>]`` tables following the
documented Codex stdio shape::

    [mcp_servers.context7]
    command = "npx"
    args = ["-y", "@upstash/context7-mcp@latest"]
    env = { CONTEXT7_API_KEY = "<value>" }

This provider is intentionally conservative (issue 03 acceptance criteria):

  * If ``~/.codex/config.toml`` is absent, unreadable, or carries NO
    ``[mcp_servers]`` table, the provider returns no candidates and a clear
    "no supported Codex MCP config found" note. It does NOT error and does NOT
    fabricate candidates.
  * It only parses the ONE verified table shape above (``command``/``args``/
    ``env`` under ``[mcp_servers.<name>]``). It does not invent support for any
    other / remote / unverified Codex MCP config shape — such entries are
    skipped with a note rather than guessed at.

On the machine this slice was built on, ``~/.codex/config.toml`` exists but has
no ``[mcp_servers]`` tables, so the provider correctly reports "none found".

Read-only and secret-safe: the file is opened for reading only; env values are
dropped (NAMES only are recorded), and argv credentials are scrubbed by the
shared redactor reused from the Claude provider. Secret file contents are never
printed or stored.
"""

from __future__ import annotations

import os
from typing import Any, Optional

# TOML parsing is OPTIONAL. ``tomllib`` is stdlib on Python 3.11+; older
# runtimes may have the third-party ``tomli`` backport. boxa invokes the
# system ``python3`` without declaring a ``tomli`` dependency, so we MUST NOT
# make importing this provider fail when neither is available — otherwise
# ``mcp.providers.__init__`` (which imports CodexProvider) would break the
# entire ``boxa mcp`` command before it could even fall back to Claude-only
# discovery. Instead, ``_toml`` stays None and discovery degrades to a clean
# "no parser available" note (no candidates, no exception).
_toml: Any = None
try:  # Python 3.11+ stdlib.
    import tomllib as _toml  # type: ignore[no-redef]
except ModuleNotFoundError:  # pragma: no cover - environment dependent
    try:
        import tomli as _toml  # type: ignore[no-redef]
    except ModuleNotFoundError:
        _toml = None

from ..candidate import Candidate, Classification, Command
from .claude import (
    _is_secret_env_name,
    _redact_argv,
)

PROVIDER = "codex"

# The only Codex MCP table we recognize. Bare string keeps the recognized shape
# explicit and greppable; widening support is a deliberate future change, not an
# accidental guess.
_MCP_TABLE = "mcp_servers"


def default_config_path() -> str:
    """Absolute path to Codex's config file (``~/.codex/config.toml``)."""
    return os.path.join(os.path.expanduser("~"), ".codex", "config.toml")


def _command_from_table(table: dict[str, Any]) -> Command:
    """Build a Command from a ``[mcp_servers.<name>]`` table (names-only env).

    argv = [command, *args]. Env values are dropped; only key NAMES are kept,
    and secret-looking names are flagged. argv is run through the shared
    redactor so any credential passed as a CLI argument is scrubbed.
    """
    argv: list[str] = []
    command = table.get("command")
    if isinstance(command, str) and command:
        argv.append(command)
    args = table.get("args")
    if isinstance(args, list):
        argv.extend(str(a) for a in args)
    argv = _redact_argv(argv)

    env_keys: list[str] = []
    secret_env_keys: list[str] = []
    env = table.get("env")
    if isinstance(env, dict):
        for key in env:  # KEYS only; values never touched
            name = str(key)
            env_keys.append(name)
            if _is_secret_env_name(name):
                secret_env_keys.append(name)

    return Command(argv=argv, env_keys=env_keys, secret_env_keys=secret_env_keys)


def _is_supported_stdio_table(table: dict[str, Any]) -> bool:
    """True only for the verified stdio shape (a local ``command`` string).

    Two ways a table fails the check and is skipped (not guessed at):
      * no ``command`` string (e.g. a remote/URL-based or otherwise unverified
        entry) — there is no local launch we can confidently import in v1;
      * an explicit non-stdio ``type`` (``http``/``sse``/``remote``/...), which
        marks a transport this conservative detector does not support, even when
        a ``command`` happens to be present.
    """
    command = table.get("command")
    if not (isinstance(command, str) and command):
        return False
    declared = table.get("type")
    if isinstance(declared, str) and declared.strip().lower() not in (
        "",
        "stdio",
    ):
        return False
    return True


class CodexProvider:
    """Read-only, conservative Codex MCP discovery provider.

    Parameters
    ----------
    config_path:
        Path to ``config.toml``. Defaults to ``~/.codex/config.toml``.
        Injectable so fixture-based tests do not depend on the real file.
    """

    def __init__(self, config_path: Optional[str] = None) -> None:
        self.config_path = config_path or default_config_path()
        # Human-readable note about why discovery produced what it did. Never
        # contains secret material — only counts and the config path.
        self.note: Optional[str] = None

    def _load(self) -> Optional[dict[str, Any]]:
        """Read and parse the Codex TOML config, or None if absent/unreadable.

        Read-only: opened for reading only, never written. A missing parser,
        absent file, or any parse/IO error degrades to None (treated as "no
        config"), never an exception. ``tomllib.TOMLDecodeError`` is a subclass
        of ``ValueError``, so catching ``ValueError`` covers decode failures for
        both ``tomllib`` and ``tomli`` without referencing a parser-specific
        attribute that may not exist when no parser is installed.
        """
        if _toml is None or not os.path.isfile(self.config_path):
            return None
        try:
            with open(self.config_path, "rb") as fh:
                data = _toml.load(fh)
        except (OSError, ValueError):
            return None
        return data if isinstance(data, dict) else None

    def discover(
        self,
        project_keys: Optional[list[str]] = None,
        include_global: bool = True,
        all_projects: bool = False,
    ) -> list[Candidate]:
        """Discover Codex MCP candidates.

        The scope flags mirror the Claude provider's signature so both plug into
        the same merge pipeline. Codex MCP servers live in the single top-level
        ``[mcp_servers]`` table (Codex has no per-project MCP block in the
        verified schema), so ``include_global`` gates discovery and the
        project-scope flags currently add nothing — they are accepted for a
        uniform provider interface.

        Sets ``self.note`` to explain the outcome (e.g. "no supported Codex MCP
        config found"). Returns no candidates and never raises when there is no
        recognized config.
        """
        _ = (project_keys, all_projects)  # uniform interface; unused for Codex

        if not include_global:
            self.note = "Codex global MCP scan skipped (--no-global)."
            return []

        if _toml is None:
            self.note = (
                "No supported Codex MCP config found "
                "(no TOML parser available; install Python 3.11+ or 'tomli')."
            )
            return []

        data = self._load()
        if data is None:
            self.note = (
                "No supported Codex MCP config found "
                f"(no readable {self.config_path})."
            )
            return []

        servers = data.get(_MCP_TABLE)
        if not isinstance(servers, dict) or not servers:
            self.note = (
                "No supported Codex MCP config found "
                f"(no [{_MCP_TABLE}] table in {self.config_path})."
            )
            return []

        candidates: list[Candidate] = []
        skipped = 0
        for name, table in servers.items():
            if not isinstance(table, dict):
                skipped += 1
                continue
            if not _is_supported_stdio_table(table):
                # Unverified / non-stdio shape: do not guess. Skip with a count.
                skipped += 1
                continue
            candidates.append(
                Candidate(
                    provider=PROVIDER,
                    source_path=self.config_path,
                    source_scope="global",
                    source_project=None,
                    name=str(name),
                    type=(
                        str(table["type"]) if isinstance(table.get("type"), str)
                        else None
                    ),
                    command=_command_from_table(table),
                    classification=Classification(placement="unknown"),
                )
            )

        candidates.sort(key=lambda c: c.name)

        if not candidates:
            self.note = (
                "No supported Codex MCP config found "
                f"(no verified stdio [{_MCP_TABLE}.*] entries in "
                f"{self.config_path})."
            )
        elif skipped:
            self.note = (
                f"Discovered {len(candidates)} Codex MCP server(s); "
                f"skipped {skipped} unverified/non-stdio entr(y/ies)."
            )
        else:
            self.note = f"Discovered {len(candidates)} Codex MCP server(s)."
        return candidates
