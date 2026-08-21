"""The shell MCP mutation paths no longer invoke a render command."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "scripts", "mcp-cli.sh")


def _run(call: str) -> subprocess.CompletedProcess:
    script = f'''
        set -uo pipefail
        source "{CLI}"
        _run_py_secret_write() {{ printf '%s\n' "$1" >> "$CALLS"; printf '%s\n' "$*" >> "$ARG_CALLS"; _LAST_SECRET_SCOPES_FILE=""; return 0; }}
        _finish_secret_write() {{ return 0; }}
        _run_py() {{ printf '%s\n' "$1" >> "$CALLS"; printf '%s\n' "$*" >> "$ARG_CALLS"; return 0; }}
        {call}
    '''
    descriptor, calls = tempfile.mkstemp()
    os.close(descriptor)
    args_descriptor, arg_calls = tempfile.mkstemp()
    os.close(args_descriptor)
    env = dict(os.environ, CALLS=calls, ARG_CALLS=arg_calls)
    proc = subprocess.run(
        ["bash", "-c", script, os.path.join(ROOT, "scripts", "_harness.sh")],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
    )
    try:
        with open(calls, encoding="utf-8") as fh:
            proc.calls = fh.read().splitlines()
        with open(arg_calls, encoding="utf-8") as fh:
            proc.arg_calls = fh.read().splitlines()
    finally:
        os.unlink(calls)
        os.unlink(arg_calls)
    return proc


class NoRenderDispatchTest(unittest.TestCase):
    def test_definition_import_has_no_render_followup(self):
        proc = _run("scope=(--global); servers=(ctx7); imps=(); cmd_import_apply true false scope servers imps")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(any("render" in call for call in proc.calls))

    def test_yes_one_shot_routes_to_machine_import_activation(self):
        proc = _run(
            "scope=(--project /work/app); servers=(); imps=(); "
            "cmd_import_apply true true true true false claude '' /work/app "
            "scope servers imps"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.calls, ["import-activate-json"])

    def test_reimport_all_changed_reaches_python_selection(self):
        proc = _run(
            "scope=(--project /work/app); servers=(); imps=(); "
            "cmd_import_apply true false true true false false false '' '' '' "
            "scope servers imps"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.calls, ["apply-json"])
        self.assertIn("--all-changed --reimport", proc.arg_calls[0])

    def test_legacy_add_has_no_render_followup(self):
        proc = _run("cmd_add --json --global ctx7 -- npx -y @upstash/context7-mcp@latest")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(any("render" in call for call in proc.calls))

    def test_secret_set_value_never_enters_python_argv(self):
        secret = "Bearer argv-leak-regression"
        proc = _run(
            "export BOXA_MCP_TEST_INTERACTIVE=1; "
            f"cmd_secret set remote Authorization <<< {secret!r}"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.calls, ["secret-set-text"])
        self.assertEqual(
            proc.arg_calls,
            ["secret-set-text remote Authorization"],
        )
        self.assertNotIn(secret, "\n".join(proc.arg_calls))

    def test_no_arg_secret_set_picks_missing_entry_and_uses_hidden_prompt(self):
        secret = "Bearer picker-secret-must-not-leak"
        script = f'''
            set -uo pipefail
            source "{CLI}"
            export BOXA_MCP_TEST_INTERACTIVE=1
            export BOXA_PICKER_FZF=0
            export BOXA_PICKER_TEST_CHOICE=1
            _run_py() {{
                case "$1" in
                    secret-missing-entry-picker) printf 'entry-id\tremote\n' ;;
                    secret-missing-key-picker) printf 'Authorization\n' ;;
                    *) return 1 ;;
                esac
            }}
            _run_py_secret_write() {{
                printf '%s\n' "$*" >"$CALLS"
                IFS= read -r supplied
                [ "$supplied" = "$EXPECTED_SECRET" ]
            }}
            _finish_secret_write() {{ :; }}
            cmd_secret set
        '''
        descriptor, calls = tempfile.mkstemp()
        os.close(descriptor)
        try:
            proc = subprocess.run(
                ["bash", "-c", script, os.path.join(ROOT, "scripts", "_harness.sh")],
                cwd=ROOT,
                env=dict(os.environ, CALLS=calls, EXPECTED_SECRET=secret),
                input=secret + "\n",
                capture_output=True,
                text=True,
            )
            with open(calls, encoding="utf-8") as fh:
                invoked = fh.read().strip()
        finally:
            os.unlink(calls)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(invoked, "secret-set-text entry-id Authorization")
        self.assertNotIn(secret, proc.stdout + proc.stderr + invoked)
        self.assertIn("full header value", proc.stderr)

    def test_no_arg_update_uses_authorization_default_then_stores_via_secret_set(self):
        secret = "Bearer guided-secret-must-not-leak"
        script = f'''
            set -uo pipefail
            source "{CLI}"
            export BOXA_MCP_TEST_INTERACTIVE=1
            export BOXA_PICKER_FZF=0
            export BOXA_PICKER_TEST_CHOICE=1
            _run_py() {{
                case "$1" in
                    catalog-update-picker) printf 'entry-id\tremote\thttp\n' ;;
                    *) return 1 ;;
                esac
            }}
            _run_py_secret_write() {{
                printf '%s\n' "$*" >"$SECRET_CALL"
                IFS= read -r supplied
                [ "$supplied" = "$EXPECTED_SECRET" ]
            }}
            _finish_secret_write() {{ :; }}
            cmd_update
        '''
        secret_fd, secret_call = tempfile.mkstemp()
        os.close(secret_fd)
        try:
            proc = subprocess.run(
                ["bash", "-c", script, os.path.join(ROOT, "scripts", "_harness.sh")],
                cwd=ROOT,
                env=dict(
                    os.environ,
                    SECRET_CALL=secret_call,
                    EXPECTED_SECRET=secret,
                ),
                input="\n" + secret + "\n",
                capture_output=True,
                text=True,
            )
            with open(secret_call, encoding="utf-8") as fh:
                secret_invoked = fh.read().strip()
        finally:
            os.unlink(secret_call)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            secret_invoked,
            "guided-secret-header-text entry-id Authorization",
        )
        self.assertNotIn(
            secret, proc.stdout + proc.stderr + secret_invoked
        )

    def test_no_arg_picker_layer_does_not_trigger_without_tty_or_with_json(self):
        proc = _run("cmd_secret set")
        self.assertEqual(proc.returncode, 2)
        self.assertIn(
            "Usage: boxa mcp secret set <entry> <header> [--json]",
            proc.stderr,
        )
        self.assertEqual(proc.calls, [])

        proc = _run("cmd_update")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.calls, ["catalog-update-text"])
        proc = _run("cmd_update --json")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.calls, ["catalog-update-json"])

    def test_everywhere_activation_reaches_python_without_project_resolution(self):
        proc = _run("cmd_activation activate ctx7 --everywhere --for claude")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("activation-agent-trusted-text", proc.calls)
        self.assertIn("activate-text", proc.calls)

    def test_no_everywhere_reaches_python_without_activation_flags(self):
        proc = _run("cmd_activation activate ctx7 --no-everywhere")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.calls, ["activate-text"])

    def test_everywhere_and_project_are_mutually_exclusive(self):
        proc = _run(
            "cmd_activation activate ctx7 --everywhere --project /work/app --for claude"
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("cannot be combined", proc.stderr)

    def test_positional_import_filters_dry_run_and_apply(self):
        proc = _run("cmd_import dozzle")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(any(
            call.startswith("import-text ") and "--server dozzle" in call
            for call in proc.arg_calls
        ))

        proc = _run("cmd_import dozzle --apply")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(any(
            call.startswith("apply-text ") and "--server dozzle" in call
            for call in proc.arg_calls
        ))

    def test_interactive_activate_passes_every_selected_project(self):
        script = f'''
            set -uo pipefail
            source "{CLI}"
            export BOXA_MCP_TEST_INTERACTIVE=1
            export BOXA_PICKER_FZF=0
            export BOXA_PICKER_TEST_CHOICE=1,2
            _resolve_project_key() {{ printf '%s\n' "$1"; }}
            _run_py() {{
                case "$1" in
                    activation-project-targets-text)
                        printf 'current\t%s\none\t/work/one\ntwo\t/work/two\n' "$PWD"
                        ;;
                    activation-degradation-text) printf '%s\n' isolated ;;
                    readiness-json) return 0 ;;
                    activate-text) printf '%s\n' "$*" >"$CALLS" ;;
                    *) return 0 ;;
                esac
            }}
            cmd_activation activate context7 --for claude
        '''
        descriptor, calls = tempfile.mkstemp()
        os.close(descriptor)
        try:
            proc = subprocess.run(
                ["bash", "-c", script, os.path.join(ROOT, "scripts", "_harness.sh")],
                cwd=ROOT,
                env=dict(os.environ, CALLS=calls),
                capture_output=True,
                text=True,
            )
            with open(calls, encoding="utf-8") as fh:
                invoked = fh.read()
        finally:
            os.unlink(calls)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--project /work/one", invoked)
        self.assertIn("--project /work/two", invoked)
        self.assertIn("--for claude", invoked)

    def test_codex_only_current_project_appears_in_activation_picker_rows(self):
        script = f'''
            set -uo pipefail
            source "{CLI}"
            export BOXA_PICKER_FZF=0
            export BOXA_PICKER_TEST_CHOICE=a
            _run_py() {{
                case "$1" in
                    activation-project-targets-text)
                        printf 'codex-only\t%s\n' "$PWD"
                        ;;
                    *) return 0 ;;
                esac
            }}
            _activation_project_picker "$PWD"
        '''
        proc = subprocess.run(
            ["bash", "-c", script, os.path.join(ROOT, "scripts", "_harness.sh")],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), ROOT)
        self.assertIn("codex-only", proc.stderr)


if __name__ == "__main__":
    unittest.main()
