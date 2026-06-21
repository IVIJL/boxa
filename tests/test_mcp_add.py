#!/usr/bin/env python3
"""Tests for `boxa mcp add` (issue 13).

Run with:

    PYTHONPATH=scripts python3 -m unittest tests.test_mcp_add

Covers the ``mcp.add`` core and its ``mcp.cli`` entry point:

  * spec parsing — Docker ``-e KEY=VALUE`` env mining, secret vs non-secret
    classification, secret-value redaction out of the stored argv;
  * a successful add writes the scope-correct profile + 0600 secret store and
    keeps the credential out of the (secret-free) profile;
  * scope follows the explicit decision: global vs an absolute project key;
  * host-only / unknown specs are refused with the apply path's reason text;
  * a name clash in the target scope is refused (add never overwrites);
  * the CLI entry parses ``<scope> <name> -- <spec>`` and validates an explicit
    scope + a spec after ``--``.

HOME / XDG_CONFIG_HOME point at a fresh tempdir so the real ~/.config/boxa
state is never touched. No real ``docker`` is ever invoked.
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp import cli  # noqa: E402
from mcp.add import (  # noqa: E402
    ADD_PROVIDER,
    AddError,
    add_server,
    parse_spec,
)
from mcp.apply import ScopeOverride  # noqa: E402
from mcp.profile import (  # noqa: E402
    global_profile_path,
    load_profile,
    project_profile_path,
)
from mcp.secrets import (  # noqa: E402
    file_mode,
    global_secrets_path,
    load_secrets,
    project_secrets_path,
)

_ABS_PROJECT = "/home/dev/Projekty/myapp"


class _IsolatedConfigTest(unittest.TestCase):
    """Base class pointing HOME / XDG_CONFIG_HOME at a fresh tempdir."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self._env_backup = {
            k: os.environ.get(k) for k in ("HOME", "XDG_CONFIG_HOME")
        }
        os.environ["HOME"] = self._tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self._tmp.name, ".config")

    def tearDown(self) -> None:
        for k, v in self._env_backup.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


# -- spec parsing -------------------------------------------------------------


class TestParseSpec(unittest.TestCase):
    def test_plain_npx_spec_has_no_env(self) -> None:
        spec = parse_spec(["npx", "-y", "@upstash/context7-mcp@latest"])
        self.assertEqual(spec.argv, ["npx", "-y", "@upstash/context7-mcp@latest"])
        self.assertEqual(spec.env_keys, [])
        self.assertEqual(spec.secret_env_keys, [])
        self.assertEqual(spec.env_values, {})

    def test_empty_spec_raises(self) -> None:
        with self.assertRaises(AddError):
            parse_spec([])

    def test_docker_secret_env_is_redacted_in_argv(self) -> None:
        spec = parse_spec(
            [
                "docker", "run", "-i", "--rm",
                "-e", "GITHUB_TOKEN=ghp_supersecretvalue1234",
                "-e", "LOG_LEVEL=debug",
                "ghcr.io/github/github-mcp-server",
            ]
        )
        self.assertIn("GITHUB_TOKEN", spec.secret_env_keys)
        self.assertNotIn("LOG_LEVEL", spec.secret_env_keys)
        self.assertEqual(spec.env_keys, ["GITHUB_TOKEN", "LOG_LEVEL"])
        # Secret value stored as the Docker forwarding form ``KEY`` (no value),
        # so Docker forwards it from the env the wrapper populates; non-secret
        # value stays inline. The literal credential is nowhere in the argv.
        self.assertIn("GITHUB_TOKEN", spec.argv)
        self.assertNotIn("GITHUB_TOKEN=<redacted>", spec.argv)
        self.assertIn("LOG_LEVEL=debug", spec.argv)
        self.assertNotIn("ghp_supersecretvalue1234", " ".join(spec.argv))
        # The argv keeps a runnable docker -e forwarding pair for the secret.
        idx = spec.argv.index("GITHUB_TOKEN")
        self.assertEqual(spec.argv[idx - 1], "-e")
        # But the value survives IN MEMORY for the secret store write.
        self.assertEqual(
            spec.env_values["GITHUB_TOKEN"], "ghp_supersecretvalue1234"
        )

    def test_docker_inline_e_flag_form(self) -> None:
        spec = parse_spec(["docker", "run", "-eAPI_KEY=abc123token", "img"])
        self.assertIn("API_KEY", spec.secret_env_keys)
        # Forwarding form preserves the inline -e prefix without the value.
        self.assertIn("-eAPI_KEY", spec.argv)
        self.assertNotIn("abc123token", " ".join(spec.argv))

    def test_docker_inline_e_equals_separator_form(self) -> None:
        # ``-e=KEY=VALUE`` is valid Docker (the first ``=`` is the flag/value
        # separator). The KEY must be mined, not parsed as empty and the whole
        # token dropped (which would silently lose the env declaration).
        spec = parse_spec(["docker", "run", "-e=LOG_LEVEL=debug", "img"])
        self.assertEqual(spec.env_keys, ["LOG_LEVEL"])
        self.assertNotIn("LOG_LEVEL", spec.secret_env_keys)
        self.assertEqual(spec.env_values["LOG_LEVEL"], "debug")
        # The non-secret value stays inline; the env declaration is preserved.
        self.assertIn("-eLOG_LEVEL=debug", spec.argv)
        self.assertIn("img", spec.argv)

    def test_docker_inline_e_equals_separator_secret(self) -> None:
        # The ``-e=KEY=VALUE`` separator form also routes a secret value into the
        # forwarding form, with the literal credential nowhere in the argv.
        spec = parse_spec(["docker", "run", "-e=API_KEY=sk-realsecret123", "img"])
        self.assertIn("API_KEY", spec.secret_env_keys)
        self.assertEqual(spec.env_values["API_KEY"], "sk-realsecret123")
        self.assertIn("-eAPI_KEY", spec.argv)
        self.assertNotIn("sk-realsecret123", " ".join(spec.argv))

    def test_docker_global_value_flag_before_subcommand(self) -> None:
        # A value-taking global option before ``run`` must not be mistaken for
        # the subcommand; env mining still engages and the secret is forwarded.
        spec = parse_spec(
            [
                "docker", "--context", "desktop-linux", "run",
                "-e", "GITHUB_TOKEN=ghp_secretvalueabcdef",
                "img",
            ]
        )
        self.assertIn("GITHUB_TOKEN", spec.secret_env_keys)
        self.assertNotIn("ghp_secretvalueabcdef", " ".join(spec.argv))
        self.assertEqual(spec.env_values["GITHUB_TOKEN"], "ghp_secretvalueabcdef")
        # The global option + its value are preserved verbatim in the argv.
        self.assertIn("--context", spec.argv)
        self.assertIn("desktop-linux", spec.argv)

    def test_long_secret_env_name_survives_redaction(self) -> None:
        # A long credential env NAME after ``-e`` must NOT be mistaken for an
        # opaque argv credential by the generic redaction pass; the forwarding
        # form is preserved so the spec stays addable.
        spec = parse_spec(
            ["docker", "run", "-e", "ANTHROPIC_API_KEY=sk-ant-realvalue123", "img"]
        )
        self.assertIn("ANTHROPIC_API_KEY", spec.secret_env_keys)
        self.assertIn("ANTHROPIC_API_KEY", spec.argv)
        self.assertNotIn("<redacted>", spec.argv)
        self.assertNotIn("sk-ant-realvalue123", " ".join(spec.argv))

    def test_docker_boolean_flag_before_image_not_redacted(self) -> None:
        # A boolean flag (``--rm``, ``-i``) before the image must not cause the
        # image token to be redacted as an opaque flag value.
        for spec_argv in (
            ["docker", "run", "--rm", "context7image"],
            ["docker", "run", "-i", "mcp1234567890abc"],
        ):
            spec = parse_spec(spec_argv)
            self.assertNotIn("<redacted>", spec.argv, spec_argv)
            self.assertEqual(spec.argv, spec_argv)

    def test_docker_value_flag_consumes_its_value(self) -> None:
        # A known value-taking option's value is protected, and the image after
        # it is still recognized (env after the image is NOT mined).
        spec = parse_spec(
            ["docker", "run", "--name", "mycontainer", "-e", "TOKEN=secretabc123", "img"]
        )
        self.assertIn("TOKEN", spec.secret_env_keys)
        self.assertIn("mycontainer", spec.argv)
        self.assertNotIn("<redacted>", spec.argv)

    def test_e_flag_after_image_is_program_arg_not_mined(self) -> None:
        # ``-e`` after the image is the containerized program's own flag, NOT a
        # docker env declaration — it is never mined into the env model. A
        # non-secret program env value is left verbatim.
        spec = parse_spec(
            ["docker", "run", "img", "tool", "-e", "LOG=debug"]
        )
        self.assertEqual(spec.env_keys, [])
        self.assertEqual(spec.secret_env_keys, [])
        self.assertEqual(
            spec.argv, ["docker", "run", "img", "tool", "-e", "LOG=debug"]
        )

    def test_credential_after_image_is_redacted_not_mined(self) -> None:
        # A credential-shaped program arg after the image is NOT mined as docker
        # env; it goes through the generic redaction path (and add_server then
        # refuses it), so it never lands in the profile.
        spec = parse_spec(
            ["docker", "run", "img", "tool", "-e", "API_KEY=sk-ant-secretval"]
        )
        self.assertEqual(spec.secret_env_keys, [])  # not mined as docker env
        self.assertIn("<redacted>", spec.argv)
        self.assertNotIn("sk-ant-secretval", " ".join(spec.argv))

    def test_docker_program_arg_credential_is_redacted(self) -> None:
        # A credential passed to the CONTAINERIZED program (after the image) is
        # the server's own argv and must be redacted just like a non-docker spec
        # — it must NOT be protected as docker structure.
        spec = parse_spec(
            ["docker", "run", "img", "server", "--api-key", "sk-ant-api03-secretvalue"]
        )
        self.assertIn("<redacted>", spec.argv)
        self.assertNotIn("sk-ant-api03-secretvalue", " ".join(spec.argv))
        # The image is still protected (preserved verbatim).
        self.assertIn("img", spec.argv)

    def test_docker_inline_global_value_flag(self) -> None:
        # The inline ``--flag=value`` form carries its own value (no skip).
        spec = parse_spec(
            ["docker", "--context=devhost", "run", "-e", "TOKEN=secretvalabc", "img"]
        )
        self.assertIn("TOKEN", spec.secret_env_keys)
        self.assertNotIn("secretvalabc", " ".join(spec.argv))

    def test_docker_global_value_opaque_not_redacted(self) -> None:
        # An opaque-looking global option value (``--context prod1234567890``)
        # is structural docker syntax and must survive redaction unrewritten.
        spec = parse_spec(
            ["docker", "--context", "prod1234567890", "run", "img"]
        )
        self.assertNotIn("<redacted>", spec.argv)
        self.assertIn("prod1234567890", spec.argv)
        self.assertEqual(
            spec.argv, ["docker", "--context", "prod1234567890", "run", "img"]
        )

    def test_docker_option_value_credential_is_redacted(self) -> None:
        # A credential smuggled through a NON-env Docker option's separate value
        # (e.g. ``--label API_KEY=sk-...``) must NOT be exempted from redaction
        # just because it is a docker option value — it is redacted so the spec
        # is refused, never persisted into the secret-free profile.
        spec = parse_spec(
            [
                "docker", "run", "--label", "API_KEY=sk-ant-secretvalue123",
                "img",
            ]
        )
        self.assertIn("<redacted>", spec.argv)
        self.assertNotIn("sk-ant-secretvalue123", " ".join(spec.argv))
        self.assertEqual(spec.secret_env_keys, [])  # not a mined env

    def test_docker_inline_option_value_credential_is_redacted(self) -> None:
        # The inline ``--label=API_KEY=sk-...`` form embeds the credential in a
        # single option token; it must still be redacted, not protected verbatim.
        spec = parse_spec(
            ["docker", "run", "--label=API_KEY=sk-ant-secretvalue123", "img"]
        )
        self.assertIn("<redacted>", spec.argv)
        self.assertNotIn("sk-ant-secretvalue123", " ".join(spec.argv))

    def test_docker_innocent_option_value_not_redacted(self) -> None:
        # Regression guard for the fix above: an innocent opaque option value
        # (``--name myserver123abc``, ``--label app=web``) carries no credential
        # shape and must survive verbatim, so a valid spec is not wrongly refused.
        spec = parse_spec(
            [
                "docker", "run", "--name", "myserver123abc",
                "--label", "app=web", "img",
            ]
        )
        self.assertNotIn("<redacted>", spec.argv)
        self.assertIn("myserver123abc", spec.argv)
        self.assertIn("app=web", spec.argv)

    def test_docker_env_long_flag(self) -> None:
        spec = parse_spec(["docker", "run", "--env", "PLAIN=value", "img"])
        self.assertEqual(spec.env_keys, ["PLAIN"])
        self.assertEqual(spec.secret_env_keys, [])
        self.assertIn("PLAIN=value", spec.argv)

    def test_docker_bare_env_reference_has_no_value(self) -> None:
        spec = parse_spec(["docker", "run", "-e", "TOKEN", "img"])
        self.assertIn("TOKEN", spec.env_keys)
        self.assertIn("TOKEN", spec.secret_env_keys)
        self.assertNotIn("TOKEN", spec.env_values)
        self.assertIn("TOKEN", spec.argv)

    def test_non_docker_e_flag_is_not_env_mined(self) -> None:
        # ``-e`` on a non-docker launcher is just a regular flag, untouched.
        spec = parse_spec(["npx", "-e", "SOME=thing", "tool"])
        self.assertEqual(spec.env_keys, [])
        self.assertEqual(spec.argv, ["npx", "-e", "SOME=thing", "tool"])

    def test_secret_detected_by_value_shape_not_name(self) -> None:
        # An innocuous NAME but a credential-shaped VALUE is still secret.
        spec = parse_spec(
            ["docker", "run", "-e", "ENDPOINT=sk-ant-api03-abcdefghij", "img"]
        )
        self.assertIn("ENDPOINT", spec.secret_env_keys)
        self.assertEqual(
            spec.env_values["ENDPOINT"], "sk-ant-api03-abcdefghij"
        )
        self.assertNotIn("sk-ant-api03", " ".join(spec.argv))
        # Stored as the forwarding form (no inline value).
        self.assertIn("ENDPOINT", spec.argv)


# -- add_server ---------------------------------------------------------------


class TestAddServer(_IsolatedConfigTest):
    def test_add_global_writes_profile(self) -> None:
        result = add_server(
            "context7",
            ["npx", "-y", "@upstash/context7-mcp@latest"],
            ScopeOverride(scope="global"),
        )
        self.assertEqual(result.scope, "global")
        self.assertEqual(result.placement, "container")
        self.assertEqual(result.copied_secret_keys, [])
        profile = load_profile(global_profile_path())
        entry = profile["servers"]["context7"]
        self.assertEqual(
            entry["command"]["argv"], ["npx", "-y", "@upstash/context7-mcp@latest"]
        )
        self.assertEqual(entry["source"]["provider"], ADD_PROVIDER)

    def test_add_project_writes_project_profile(self) -> None:
        result = add_server(
            "tool",
            ["uvx", "my-mcp-tool"],
            ScopeOverride(scope="project", project_key=_ABS_PROJECT),
        )
        self.assertEqual(result.scope, "project")
        self.assertEqual(result.project_key, _ABS_PROJECT)
        profile = load_profile(project_profile_path(_ABS_PROJECT))
        self.assertIn("tool", profile["servers"])
        # The absolute key is recorded so render can match the Claude record.
        self.assertEqual(profile["projectKey"], _ABS_PROJECT)
        # No server landed in the global profile.
        self.assertFalse(os.path.exists(global_profile_path()))

    def test_secret_lands_in_store_not_profile(self) -> None:
        result = add_server(
            "gh",
            [
                "docker", "run", "-i", "--rm",
                "-e", "GITHUB_TOKEN=ghp_supersecretvalue1234",
                "ghcr.io/github/github-mcp-server",
            ],
            ScopeOverride(scope="global"),
        )
        self.assertEqual(result.copied_secret_keys, ["GITHUB_TOKEN"])
        # Profile is secret-free: the value appears nowhere in it.
        with open(global_profile_path(), encoding="utf-8") as fh:
            profile_text = fh.read()
        self.assertNotIn("ghp_supersecretvalue1234", profile_text)
        # The 0600 secret store holds the value.
        store = load_secrets(global_secrets_path())
        self.assertEqual(
            store["servers"]["gh"]["GITHUB_TOKEN"], "ghp_supersecretvalue1234"
        )
        self.assertEqual(file_mode(global_secrets_path()), 0o600)

    def test_long_secret_env_name_is_addable(self) -> None:
        # Regression: a long Docker secret env name must not be rejected as an
        # argv credential after redaction.
        result = add_server(
            "anthropic",
            [
                "docker", "run", "-i", "--rm",
                "-e", "ANTHROPIC_API_KEY=sk-ant-realvalue123",
                "img",
            ],
            ScopeOverride(scope="global"),
        )
        self.assertEqual(result.copied_secret_keys, ["ANTHROPIC_API_KEY"])
        store = load_secrets(global_secrets_path())
        self.assertEqual(
            store["servers"]["anthropic"]["ANTHROPIC_API_KEY"],
            "sk-ant-realvalue123",
        )
        profile = load_profile(global_profile_path())
        self.assertIn(
            "ANTHROPIC_API_KEY",
            profile["servers"]["anthropic"]["command"]["argv"],
        )

    def test_secret_follows_project_scope(self) -> None:
        add_server(
            "gh",
            ["docker", "run", "-e", "API_KEY=abc123secrettoken", "img"],
            ScopeOverride(scope="project", project_key=_ABS_PROJECT),
        )
        # Project secret store has it; global store was never created.
        store = load_secrets(project_secrets_path(_ABS_PROJECT))
        self.assertIn("gh", store["servers"])
        self.assertFalse(os.path.exists(global_secrets_path()))

    def test_nonsecret_env_value_kept_in_profile(self) -> None:
        add_server(
            "svc",
            ["docker", "run", "-e", "BASE_URL=https://api.example.com", "img"],
            ScopeOverride(scope="global"),
        )
        profile = load_profile(global_profile_path())
        entry = profile["servers"]["svc"]
        self.assertEqual(entry["env"], {"BASE_URL": "https://api.example.com"})

    def test_bare_env_add_preserves_retained_secret(self) -> None:
        # Add a server with an inline secret, then simulate a non-purge remove by
        # deleting only the profile entry (the secret block lingers). Re-adding
        # the same server with a BARE ``-e GITHUB_TOKEN`` forwarding reference must
        # NOT delete the retained block — it exists to be reused.
        add_server(
            "gh",
            ["docker", "run", "-e", "GITHUB_TOKEN=ghp_retainedsecret123", "img"],
            ScopeOverride(scope="global"),
        )
        # Drop the profile entry only (mimics `remove` without `--purge`).
        profile = load_profile(global_profile_path())
        del profile["servers"]["gh"]
        from mcp.profile import save_profile as _save
        _save(global_profile_path(), profile)
        # Secret block still present.
        self.assertIn("gh", load_secrets(global_secrets_path())["servers"])

        # Re-add with a BARE env reference (no value).
        result = add_server(
            "gh",
            ["docker", "run", "-e", "GITHUB_TOKEN", "img"],
            ScopeOverride(scope="global"),
        )
        # The retained credential is untouched and still resolvable.
        store = load_secrets(global_secrets_path())
        self.assertEqual(
            store["servers"]["gh"]["GITHUB_TOKEN"], "ghp_retainedsecret123"
        )
        # No NEW copy happened this time, but the path is surfaced for the wiring.
        self.assertEqual(result.copied_secret_keys, [])
        self.assertEqual(result.secrets_path, global_secrets_path())

    def test_bare_env_add_with_no_existing_secret_creates_nothing(self) -> None:
        # A bare env reference with no prior block does not create a store.
        add_server(
            "svc",
            ["docker", "run", "-e", "API_KEY", "img"],
            ScopeOverride(scope="global"),
        )
        self.assertFalse(os.path.exists(global_secrets_path()))

    def test_host_only_spec_refused(self) -> None:
        with self.assertRaises(AddError) as ctx:
            add_server(
                "clip",
                ["npx", "clipboard-mcp"],
                ScopeOverride(scope="global"),
            )
        self.assertIn("host-only", str(ctx.exception))
        # Nothing was written.
        self.assertFalse(os.path.exists(global_profile_path()))

    def test_unknown_spec_refused(self) -> None:
        with self.assertRaises(AddError) as ctx:
            add_server(
                "mystery",
                ["/usr/bin/some-unknown-binary", "--serve"],
                ScopeOverride(scope="global"),
            )
        self.assertIn("placement unknown", str(ctx.exception))

    def test_argv_credential_refused(self) -> None:
        # A credential passed as a plain argv argument (not Docker -e env) is
        # redacted and the spec is refused — add never persists a broken
        # <redacted> command, matching the import path.
        with self.assertRaises(AddError) as ctx:
            add_server(
                "leaky",
                ["npx", "server", "--api-key", "sk-ant-api03-supersecretvalue"],
                ScopeOverride(scope="global"),
            )
        self.assertIn("credential", str(ctx.exception))
        # Nothing leaked to disk.
        self.assertFalse(os.path.exists(global_profile_path()))

    def test_docker_program_arg_credential_refused(self) -> None:
        with self.assertRaises(AddError) as ctx:
            add_server(
                "leakydocker",
                [
                    "docker", "run", "img",
                    "server", "--api-key", "sk-ant-api03-supersecretvalue",
                ],
                ScopeOverride(scope="global"),
            )
        self.assertIn("credential", str(ctx.exception))
        self.assertFalse(os.path.exists(global_profile_path()))

    def test_docker_option_value_credential_refused(self) -> None:
        # A credential in a non-env Docker option (``--label API_KEY=sk-...``)
        # is redacted in argv, so add_server refuses the spec rather than
        # writing the literal secret into the non-0600 profile.
        with self.assertRaises(AddError) as ctx:
            add_server(
                "leakylabel",
                [
                    "docker", "run", "--label", "API_KEY=sk-ant-api03-supersecret",
                    "img",
                ],
                ScopeOverride(scope="global"),
            )
        self.assertIn("credential", str(ctx.exception))
        self.assertFalse(os.path.exists(global_profile_path()))

    def test_argv_credential_not_in_profile_when_refused(self) -> None:
        with self.assertRaises(AddError):
            add_server(
                "leaky2",
                ["npx", "server", "--token=ghp_supersecretvalue12345"],
                ScopeOverride(scope="global"),
            )
        # The secret store was not created with the leaked value either.
        self.assertFalse(os.path.exists(global_secrets_path()))

    def test_name_clash_refused(self) -> None:
        add_server(
            "dup", ["npx", "a"], ScopeOverride(scope="global")
        )
        with self.assertRaises(AddError) as ctx:
            add_server(
                "dup", ["npx", "b"], ScopeOverride(scope="global")
            )
        self.assertIn("already exists", str(ctx.exception))
        # The original entry survives unchanged.
        profile = load_profile(global_profile_path())
        self.assertEqual(profile["servers"]["dup"]["command"]["argv"], ["npx", "a"])

    def test_same_name_different_scope_is_allowed(self) -> None:
        add_server("ctx", ["npx", "a"], ScopeOverride(scope="global"))
        # A project add of the same name is a distinct slot; not a clash.
        add_server(
            "ctx",
            ["npx", "a"],
            ScopeOverride(scope="project", project_key=_ABS_PROJECT),
        )
        self.assertIn("ctx", load_profile(global_profile_path())["servers"])
        self.assertIn(
            "ctx", load_profile(project_profile_path(_ABS_PROJECT))["servers"]
        )


# -- cli entry point ----------------------------------------------------------


class TestAddCli(_IsolatedConfigTest):
    def _run(self, args):
        out = io.StringIO()
        err = io.StringIO()
        old_out, old_err = sys.stdout, sys.stderr
        sys.stdout, sys.stderr = out, err
        try:
            rc = cli.main(args)
        finally:
            sys.stdout, sys.stderr = old_out, old_err
        return rc, out.getvalue(), err.getvalue()

    def test_add_json_global(self) -> None:
        rc, out, _ = self._run(
            ["add-json", "--global", "context7", "--", "npx", "-y", "pkg"]
        )
        self.assertEqual(rc, 0)
        payload = json.loads(out)
        self.assertEqual(payload["name"], "context7")
        self.assertEqual(payload["scope"], "global")
        self.assertEqual(payload["argv"], ["npx", "-y", "pkg"])

    def test_add_text_project(self) -> None:
        rc, out, _ = self._run(
            ["add-text", "--project", _ABS_PROJECT, "tool", "--", "uvx", "x"]
        )
        self.assertEqual(rc, 0)
        self.assertIn("Added tool", out)
        self.assertIn(_ABS_PROJECT, out)

    def test_missing_scope_fails(self) -> None:
        rc, _, err = self._run(["add-text", "foo", "--", "npx", "x"])
        self.assertEqual(rc, 2)
        self.assertIn("resolved scope", err)

    def test_missing_spec_fails(self) -> None:
        rc, _, err = self._run(["add-text", "--global", "foo"])
        self.assertEqual(rc, 2)
        self.assertIn("command spec after '--'", err)

    def test_empty_spec_after_dashdash_fails(self) -> None:
        rc, _, err = self._run(["add-text", "--global", "foo", "--"])
        self.assertEqual(rc, 2)
        self.assertIn("command spec after '--'", err)

    def test_missing_name_fails(self) -> None:
        rc, _, err = self._run(["add-text", "--global", "--", "npx", "x"])
        self.assertEqual(rc, 2)
        self.assertIn("server name", err)

    def test_two_names_before_dashdash_fails(self) -> None:
        rc, _, err = self._run(
            ["add-text", "--global", "one", "two", "--", "npx", "x"]
        )
        self.assertEqual(rc, 2)
        self.assertIn("one server name", err)

    def test_bare_project_name_rejected(self) -> None:
        # The core requires an ABSOLUTE project key; a bare name is rejected
        # (the shell resolver turns a name into a key before this point).
        rc, _, err = self._run(
            ["add-text", "--project", "bareword", "foo", "--", "npx", "x"]
        )
        self.assertEqual(rc, 2)
        self.assertIn("ABSOLUTE project key", err)

    def test_host_only_refused_via_cli(self) -> None:
        rc, _, err = self._run(
            ["add-text", "--global", "clip", "--", "npx", "clipboard-mcp"]
        )
        self.assertEqual(rc, 2)
        self.assertIn("host-only", err)


if __name__ == "__main__":
    unittest.main()
