"""Boxa MCP core package (ADR 0013).

Houses the provider-neutral candidate model and the JSON contracts that the
`boxa mcp` command group builds on. The shell dispatcher
(`scripts/mcp-cli.sh`) stays thin and delegates candidate-model / JSON work
to this package so later slices (02-10) can add providers, classification,
and profile merge against one unit-testable Python core.

This slice (issue 01) is a skeleton: it defines the candidate shape and the
empty-result contracts only. No real discovery, no profile writes.
"""

from .candidate import (
    SCHEMA_VERSION,
    Candidate,
    Classification,
    Command,
    import_result,
    inherited_list_result,
)
from .classify import classify, classify_candidate

__all__ = [
    "SCHEMA_VERSION",
    "Candidate",
    "Classification",
    "Command",
    "import_result",
    "inherited_list_result",
    "classify",
    "classify_candidate",
]
