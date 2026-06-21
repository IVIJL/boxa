"""Import providers for `boxa mcp import` (ADR 0013).

A provider reads one agent's existing MCP configuration and normalizes its
records into the provider-neutral candidate shape from `mcp.candidate`. The
first provider is Claude Code (`mcp.providers.claude`); the Codex provider
(`mcp.providers.codex`) lands in issue 03 as a conservative detector. Their
candidates flow into the shared merge pipeline in `mcp.merge`.

Providers are read-only: they parse existing config and never write to agent
config or boxa state. They report environment-variable *names* only — secret
*values* never enter a Candidate (ADR 0013, decisions 25-26).
"""

from .claude import ClaudeProvider
from .codex import CodexProvider

__all__ = ["ClaudeProvider", "CodexProvider"]
