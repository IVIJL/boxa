"""One-time MCP onboarding state and eligibility (ADR 0013, issue 10).

Fresh installs and the first ``boxa update`` after MCP support ships should
make MCP discovery easy WITHOUT nagging the user on every later update. This
module owns the small amount of state and the eligibility rule that make that
"offer once" behaviour deterministic and unit-testable; the shell front-ends
(``install.sh`` and the ``boxa update`` self-heal chain, via
``scripts/ensure-mcp-onboarding.sh``) drive the actual interactive prompt.

State lives OUTSIDE the profile, at::

    $XDG_CONFIG_HOME/boxa/mcp/state.json   (~/.config when XDG unset)

so that DELETING the profile files (profile.json / projects/*.json) does NOT
re-trigger onboarding once the marker says the wizard was already seen. The
state file is agent-neutral, non-secret JSON with its own schema ``version``.

Eligibility rule (acceptance criteria, issue 10):

  * offer onboarding ONLY when no boxa MCP profile exists yet (neither a
    global nor any project profile has a server), AND
  * the wizard has NOT already been seen/dismissed (no ``seen`` marker).

The "decision" recorded in the marker (``imported`` / ``dismissed`` /
``noop``) is informational only — any non-empty marker suppresses future
prompts. SECRET-FREE: nothing here reads or stores a credential value.
"""

from __future__ import annotations

import json
import os
from typing import Any, Optional

from .profile import (
    config_root,
    global_profile_path,
    load_profile,
)

# Schema version for the onboarding state file. Independent of the profile
# PROFILE_VERSION: this versions the marker shape so a future change (e.g.
# re-prompting after a major MCP redesign) can branch on it.
STATE_VERSION = 1

# Recognised, non-secret onboarding decisions. Any non-empty decision counts as
# "seen" and suppresses future prompts; these labels just make the marker
# self-describing for a human reading state.json.
DECISION_IMPORTED = "imported"
DECISION_DISMISSED = "dismissed"
DECISION_NOOP = "noop"
_VALID_DECISIONS = (DECISION_IMPORTED, DECISION_DISMISSED, DECISION_NOOP)


def state_path() -> str:
    """Path to the onboarding state file (honors ``XDG_CONFIG_HOME``).

    Lives alongside the profile under the same MCP config root, but is NOT the
    profile: removing the profile must not remove this marker (that is the whole
    point of keeping the "seen" state separate).
    """
    return os.path.join(config_root(), "state.json")


def load_state() -> dict[str, Any]:
    """Load the onboarding state, or a fresh empty state when absent.

    A malformed/unreadable state file degrades to an empty state rather than
    raising: onboarding is a convenience prompt, and a corrupt marker should not
    break ``boxa update``. The worst case is the user being offered the wizard
    one extra time, which is harmless.
    """
    path = state_path()
    if not os.path.isfile(path):
        return {"version": STATE_VERSION}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {"version": STATE_VERSION}
    if not isinstance(data, dict):
        return {"version": STATE_VERSION}
    data.setdefault("version", STATE_VERSION)
    return data


def save_state(state: dict[str, Any]) -> None:
    """Write the onboarding state atomically (parent dirs created as needed)."""
    path = state_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2, sort_keys=False)
        fh.write("\n")
    os.replace(tmp, path)


def onboarding_seen() -> bool:
    """True when the onboarding wizard has already been seen/dismissed.

    Any recorded ``seen`` marker (regardless of the decision) suppresses future
    prompts. This is read from the dedicated state file, never the profile, so a
    deleted profile cannot re-arm the prompt.
    """
    state = load_state()
    return bool(state.get("seen"))


def _profile_has_servers(path: str) -> bool:
    """True when a profile file exists and records at least one server.

    A malformed profile is treated as "has state" (returns True) so onboarding
    does not offer to seed a profile on top of one boxa cannot currently read
    — the user should fix it via ``boxa mcp doctor`` first, not be nagged.
    """
    if not os.path.isfile(path):
        return False
    try:
        profile = load_profile(path)
    except (OSError, ValueError):
        # Unreadable but present: a profile DOES exist here; do not offer to
        # create a new one over it. (doctor surfaces the malformed file.)
        return True
    servers = profile.get("servers")
    return isinstance(servers, dict) and len(servers) > 0


def profile_exists() -> bool:
    """True when ANY boxa MCP profile already has a server (global or project).

    "Profile exists" for onboarding means the user has already imported or added
    at least one server somewhere — so there is nothing to onboard. An empty
    profile.json with no servers does not count (a stray empty file should not
    suppress the first-run offer).
    """
    if _profile_has_servers(global_profile_path()):
        return True
    projects_dir = os.path.join(config_root(), "projects")
    if not os.path.isdir(projects_dir):
        return False
    try:
        filenames = sorted(os.listdir(projects_dir))
    except OSError:
        return False
    for filename in filenames:
        # Project PROFILE files only — never the parallel ``*.secrets.json``
        # owner-only credential store.
        if not filename.endswith(".json") or filename.endswith(".secrets.json"):
            continue
        if _profile_has_servers(os.path.join(projects_dir, filename)):
            return True
    return False


def should_offer() -> bool:
    """Whether onboarding should be OFFERED (eligibility only; not interactivity).

    True iff no boxa MCP profile exists yet AND the wizard has not already been
    seen/dismissed. The caller still decides whether to actually prompt (only on
    an interactive TTY) or to print a non-interactive follow-up reminder instead.
    """
    if onboarding_seen():
        return False
    if profile_exists():
        return False
    return True


def mark_seen(decision: str = DECISION_NOOP) -> dict[str, Any]:
    """Record that onboarding was seen, with a non-secret decision label.

    Any non-empty marker suppresses future prompts. An unrecognised decision is
    normalised to ``noop`` so the stored state stays self-describing. Returns the
    written state for the caller / tests.
    """
    if decision not in _VALID_DECISIONS:
        decision = DECISION_NOOP
    state = load_state()
    state["seen"] = True
    state["decision"] = decision
    state["version"] = STATE_VERSION
    save_state(state)
    return state


def rearm() -> dict[str, Any]:
    """Clear the seen/dismissed marker so onboarding can be offered again.

    Used by ``boxa doctor --fix mcp-onboarding`` to genuinely re-trigger a
    previously dismissed one-time offer when the user explicitly asks for it.
    A no-op when no marker is set. ``profile_exists()`` still governs
    eligibility, so this never forces an offer on top of a real profile.
    Returns the written state for the caller / tests.
    """
    state = load_state()
    state.pop("seen", None)
    state.pop("decision", None)
    state["version"] = STATE_VERSION
    save_state(state)
    return state


# -- text helpers for the shell front-ends ------------------------------------

# The interactive offer body, shown on a fresh install or the first eligible
# update when stdin/stdout are a TTY. Kept here (not in shell) so the wording is
# unit-testable and consistent with the docs.
OFFER_LINES = (
    "Boxa can manage MCP servers for your Containers (ADR 0013).",
    "It can scan your existing Claude Code / Codex MCP servers and import the",
    "Container-safe ones into a boxa-managed profile (dry-run first; nothing",
    "is applied without your confirmation).",
    "",
    "  - Import existing host agent MCP config:  boxa mcp import",
    "  - Add a brand-new boxa MCP server:      boxa mcp add ...",
    "",
    "v1 supports Container MCP servers only; Host MCP servers are detected and",
    "explained but not launched.",
)

# The non-interactive follow-up (install/update from CI/cron, or a piped shell):
# never prompt, never open a picker — just point at the command to run later.
FOLLOWUP_LINES = (
    "Boxa MCP support is available. To discover and import your existing",
    "Claude Code / Codex MCP servers (Container-safe ones), run:",
    "    boxa mcp import",
    "To add a brand-new boxa MCP server later:",
    "    boxa mcp add ...",
)

# The short reminder printed on LATER updates (onboarding already seen, or a
# profile already exists). Never prompts; just a one-liner pair of pointers.
REMINDER_LINES = (
    "Manage MCP servers with 'boxa mcp import' (existing host config) or",
    "'boxa mcp add ...' (a new boxa MCP server). See 'boxa mcp --help'.",
)


def offer_text() -> str:
    """The interactive offer body (no trailing prompt; the shell asks Y/n)."""
    return "\n".join(OFFER_LINES) + "\n"


def followup_text() -> str:
    """The non-interactive follow-up command guidance."""
    return "\n".join(FOLLOWUP_LINES) + "\n"


def reminder_text() -> str:
    """The short later-update reminder."""
    return "\n".join(REMINDER_LINES) + "\n"


def status_dict() -> dict[str, Any]:
    """Machine-readable onboarding status for the shell front-end / tests.

    SECRET-FREE: reports only the eligibility booleans and the recorded decision
    (a non-secret label). The shell reads ``shouldOffer`` to branch between the
    interactive offer and the non-interactive follow-up, and ``profileExists`` /
    ``seen`` to choose the later-update reminder.
    """
    state = load_state()
    return {
        "version": STATE_VERSION,
        "seen": bool(state.get("seen")),
        "decision": state.get("decision", "") if state.get("seen") else "",
        "profileExists": profile_exists(),
        "shouldOffer": should_offer(),
    }


def emit_status(out) -> int:
    """Write the onboarding status JSON to ``out`` (used by the CLI)."""
    json.dump(status_dict(), out, indent=2, sort_keys=False)
    out.write("\n")
    return 0


def emit_text(out, which: str) -> Optional[int]:
    """Write one of the onboarding text blocks to ``out`` (used by the CLI).

    ``which`` selects ``offer`` / ``followup`` / ``reminder``. Returns 0 on a
    known block, or None for an unknown selector so the CLI can error clearly.
    """
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
