#!/usr/bin/env python3
"""Tests for `mcp-cli.sh` --json render-status propagation (issue 18).

Run with:

    python3 -m unittest tests.test_mcp_cli_render_status   # from repo root
    python3 tests/test_mcp_cli_render_status.py            # standalone

`boxa mcp import --apply --json` and `boxa mcp add ... --json` run a secret
write, then auto-render, then a `_finish_secret_write` cleanup. The bug fixed in
issue 18: the JSON branch returned the cleanup's exit status, which masked a
failed auto-render and made the command falsely report success. These tests
drive the bash cmd_* functions directly (sourcing mcp-cli.sh, which only runs
`main` when executed, not when sourced) with the Python-calling helpers stubbed
so the auto-render call fails. The command must then exit non-zero, matching the
text path.
"""

from __future__ import annotations

import os
import subprocess
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_CLI = os.path.join(_REPO_ROOT, "scripts", "mcp-cli.sh")


def _run_harness(call: str, *, render_fails: bool) -> subprocess.CompletedProcess:
    """Source mcp-cli.sh and run `call` with the Python helpers stubbed.

    The secret write and cleanup are stubbed to succeed (return 0); _run_py is
    stubbed so that `render-write-json` fails when render_fails is true and
    succeeds otherwise. _maybe_auto_render and _finish_secret_write themselves
    are NOT stubbed: they are the real functions under test.
    """
    render_rc = "1" if render_fails else "0"
    # Override the boundary helpers AFTER sourcing so the real cmd_* /
    # _maybe_auto_render / _finish_secret_write are exercised end to end.
    script = f"""
        set -uo pipefail
        source "{_CLI}"

        # Secret write always succeeds (we are testing the render branch only).
        _run_py_secret_write() {{ _LAST_SECRET_SCOPES_FILE=""; return 0; }}
        # Cleanup always succeeds -> if its status leaked it would mask render.
        _finish_secret_write() {{ return 0; }}
        # The Python core: only the render call's status matters here.
        _run_py() {{
            case "$1" in
                render-write-json) return {render_rc} ;;
                *) return 0 ;;
            esac
        }}

        {call}
    """
    # Pass a $0 that lives in scripts/ (a sibling of mcp-cli.sh) so the script's
    # `readlink -f "$0"` resolves BOXA_DIR and its lib/ sourcing correctly even
    # though we run it via `bash -c`. It must NOT equal BASH_SOURCE[0] (the
    # sourced file) so the source-vs-execute guard keeps `main` from running.
    argv0 = os.path.join(_REPO_ROOT, "scripts", "_harness_argv0.sh")
    return subprocess.run(
        ["bash", "-c", script, argv0],
        capture_output=True,
        text=True,
        cwd=_REPO_ROOT,
    )


# A non-interactive cmd_import_apply call with an explicit selection so it skips
# the wizard and goes straight to the JSON write/render/cleanup branch.
_APPLY_JSON_CALL = (
    "scope=(--global); servers=(ctx7); imps=(); "
    'cmd_import_apply true false false scope servers imps'
)
# Non-interactive add to global with an explicit command spec.
_ADD_JSON_CALL = "cmd_add --json --global ctx7 -- npx -y @upstash/context7-mcp@latest"


class JsonRenderStatusTest(unittest.TestCase):
    def test_apply_json_propagates_render_failure(self) -> None:
        proc = _run_harness(_APPLY_JSON_CALL, render_fails=True)
        self.assertNotEqual(
            proc.returncode,
            0,
            msg=f"apply --json should exit non-zero on render failure; "
            f"got 0\nstdout={proc.stdout}\nstderr={proc.stderr}",
        )

    def test_apply_json_succeeds_when_render_ok(self) -> None:
        proc = _run_harness(_APPLY_JSON_CALL, render_fails=False)
        self.assertEqual(
            proc.returncode,
            0,
            msg=f"apply --json should exit 0 on render success\n"
            f"stdout={proc.stdout}\nstderr={proc.stderr}",
        )

    def test_add_json_propagates_render_failure(self) -> None:
        proc = _run_harness(_ADD_JSON_CALL, render_fails=True)
        self.assertNotEqual(
            proc.returncode,
            0,
            msg=f"add --json should exit non-zero on render failure; "
            f"got 0\nstdout={proc.stdout}\nstderr={proc.stderr}",
        )

    def test_add_json_succeeds_when_render_ok(self) -> None:
        proc = _run_harness(_ADD_JSON_CALL, render_fails=False)
        self.assertEqual(
            proc.returncode,
            0,
            msg=f"add --json should exit 0 on render success\n"
            f"stdout={proc.stdout}\nstderr={proc.stderr}",
        )


if __name__ == "__main__":
    unittest.main()
