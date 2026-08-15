"""One-time codex-delegate catalog seed (default Codex delegation entry).

The Container image already bakes the Codex CLI, so trusted Codex delegation
(``codex mcp-server`` behind the ``boxa-mcp-run`` launcher, ADR 0021) needs no
install step — only a user-wide catalog definition plus the host-authorized
agent-trusted grant. This module turns that into a one-time, explicitly
confirmed offer during install / ``boxa update``, mirroring the onboarding
marker model (``mcp.onboarding``): the seen/dismissed marker lives in the same
``state.json`` under its own key, so deleting catalog files never re-arms the
prompt.

Seeding NEVER happens silently. ``apply()`` grants agent-trusted mode, which
is host-only (``mcp.catalog.add_entry_trusted``); the shell hook calls it
only after the user confirmed the printed access boundary — the same canonical
wording ``boxa mcp mode`` previews (``catalog.AGENT_TRUSTED_ACCESS``).
Seeding also never activates anything: each Project still opts in explicitly
with ``boxa mcp activate``.
"""

from __future__ import annotations

import json
from typing import Any, Optional

from . import catalog as _catalog
from .catalog import (
    AGENT_TRUSTED_ACCESS,
    CatalogError,
    add_entry_trusted,
    is_codex_delegate_argv,
    load_catalog,
)
from .onboarding import STATE_VERSION, load_state, save_state

# The seeded definition is byte-identical to the documented manual recipe
# (`boxa mcp add codex-delegate -- codex mcp-server`), so a user who already
# added it by hand is simply detected as present.
SEED_NAME = "codex-delegate"
SEED_ARGV = ("codex", "mcp-server")

# Marker key inside the shared onboarding state.json. Separate from the
# onboarding wizard marker: dismissing one offer must not suppress the other.
STATE_KEY = "codexDelegateSeed"

DECISION_APPLIED = "applied"
DECISION_DISMISSED = "dismissed"
DECISION_NOOP = "noop"
_VALID_DECISIONS = (DECISION_APPLIED, DECISION_DISMISSED, DECISION_NOOP)


def _marker(state: dict[str, Any]) -> dict[str, Any]:
    marker = state.get(STATE_KEY)
    return marker if isinstance(marker, dict) else {}


def seed_seen() -> bool:
    """True when the seed offer has already been applied/dismissed."""
    return bool(_marker(load_state()).get("seen"))


def mark_seen(decision: str = DECISION_NOOP) -> dict[str, Any]:
    """Record the seed decision (suppresses future prompts). Returns the state."""
    if decision not in _VALID_DECISIONS:
        decision = DECISION_NOOP
    state = load_state()
    state[STATE_KEY] = {"seen": True, "decision": decision}
    state["version"] = STATE_VERSION
    save_state(state)
    return state


def rearm() -> dict[str, Any]:
    """Clear the marker so the offer can fire again (explicit user request).

    ``entry_present()`` still governs eligibility, so this never re-offers on
    top of an existing definition. Returns the written state.
    """
    state = load_state()
    state.pop(STATE_KEY, None)
    state["version"] = STATE_VERSION
    save_state(state)
    return state


def find_entry() -> Optional[dict[str, Any]]:
    """The existing Codex delegation entry, matched by command (not name)."""
    for entry in load_catalog()["entries"].values():
        if is_codex_delegate_argv(entry["command"]["argv"]):
            return dict(entry)
    return None


def entry_present() -> bool:
    return find_entry() is not None


def should_offer() -> bool:
    """Eligibility only (not interactivity): no delegation entry AND not seen."""
    if seed_seen():
        return False
    if entry_present():
        return False
    return True


def apply() -> dict[str, Any]:
    """Add the codex-delegate entry and grant agent-trusted mode (host-only).

    Called by the shell hook strictly AFTER an interactive confirmation of the
    printed access boundary; that confirmation is the host authorization the
    ``boxa mcp mode`` flow otherwise collects. Refuses inside a Container
    before touching the catalog, so a failed grant never leaves a half-seeded
    entry. Idempotent: an already-present delegation entry is returned as-is
    (marked applied), whatever its mode.
    """
    # The indirection (not `from`-imported) keeps the host guard mockable in
    # tests the same way the mode-command tests mock it.
    if not _catalog._host_mode_command():
        raise CatalogError(
            "codex-delegate seed is host-only; run 'boxa update' on the host"
        )
    existing = find_entry()
    if existing is not None:
        mark_seen(DECISION_APPLIED)
        return existing
    entry = add_entry_trusted(SEED_NAME, list(SEED_ARGV))
    mark_seen(DECISION_APPLIED)
    return dict(entry)


# -- text helpers for the shell front-end --------------------------------------

def offer_text() -> str:
    """The interactive offer body (no trailing prompt; the shell asks Y/n)."""
    lines = [
        "The Container image bakes the Codex CLI, so trusted Codex delegation",
        "('codex mcp-server' as an MCP server for Claude) needs no install.",
        "Accepting records ONE user-wide catalog definition ('codex-delegate')",
        "and the host-confirmed agent-trusted grant. Nothing is activated:",
        "each Project still opts in explicitly with",
        "  boxa mcp activate codex-delegate --project <path> --for claude",
        "",
        "Agent-trusted access boundary (same as the 'boxa mcp mode' preview):",
    ]
    lines.extend(f"  - {item}" for item in AGENT_TRUSTED_ACCESS)
    return "\n".join(lines) + "\n"


FOLLOWUP_LINES = (
    "Trusted Codex delegation is available; it needs a one-time host",
    "confirmation, so a non-interactive run never applies it:",
    "  boxa mcp add codex-delegate -- codex mcp-server",
    "  boxa mcp mode codex-delegate agent-trusted",
    "Then per Project: boxa mcp activate codex-delegate --project <path> --for claude",
)

REMINDER_LINES = (
    "Codex delegation seed was declined earlier; set it up any time with",
    "'boxa mcp add codex-delegate -- codex mcp-server' + 'boxa mcp mode'.",
)


def followup_text() -> str:
    """The non-interactive follow-up command guidance."""
    return "\n".join(FOLLOWUP_LINES) + "\n"


def reminder_text() -> str:
    """The short later-update reminder (previously dismissed)."""
    return "\n".join(REMINDER_LINES) + "\n"


def status_dict() -> dict[str, Any]:
    """Machine-readable seed status for the shell front-end / tests.

    SECRET-FREE: eligibility booleans and the non-secret decision label only.
    """
    marker = _marker(load_state())
    return {
        "version": STATE_VERSION,
        "seen": bool(marker.get("seen")),
        "decision": marker.get("decision", "") if marker.get("seen") else "",
        "entryPresent": entry_present(),
        "shouldOffer": should_offer(),
    }


def emit_status(out) -> int:
    """Write the seed status JSON to ``out`` (used by the CLI)."""
    json.dump(status_dict(), out, indent=2, sort_keys=False)
    out.write("\n")
    return 0


def emit_text(out, which: str) -> Optional[int]:
    """Write one seed text block (offer/followup/reminder); None when unknown."""
    blocks = {
        "offer": offer_text,
        "followup": followup_text,
        "reminder": reminder_text,
    }
    fn = blocks.get(which)
    if fn is None:
        return None
    out.write(fn())
    return 0
