"""ADR 0021 issue 03: deterministic readiness and durable installation."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import activation, cli, readiness  # noqa: E402
from mcp.catalog import (  # noqa: E402
    add_entry,
    add_remote_entry,
    catalog_path,
    load_catalog,
    update_entry,
)
from mcp.secrets import (  # noqa: E402
    file_mode,
    global_secrets_path,
    read_header_secrets,
)


class LocalState:
    def __init__(self) -> None:
        self.commands = {"/bin/cat", "npm", "docker"}
        self.images: set[str] = set()
        self.files: set[str] = set()
        self.sockets: set[str] = set()
        self.credentials: set[str] = set()
        self.codex_login = False
        self.installs: list[str] = []
        self.pulls: list[str] = []


class Probe(readiness.ProjectProbe):
    def __init__(self, project: str, state: LocalState, running: bool = True) -> None:
        self.project = project
        self.state = state
        self.running = running

    def find_running(self, project_key):
        return "boxa-project" if self.running and project_key == self.project else None

    def command_path(self, container, command, user):
        return command if command in self.state.commands else None

    def path_is(self, container, path, kind, user):
        return path in (self.state.files if kind == "file" else self.state.sockets)

    def credential_present(self, container, project_key, server_name, key, user):
        return key in self.state.credentials

    def header_secret_present(self, entry_id, header_name):
        return header_name in self.state.credentials

    def image_exists(self, container, engine, image):
        return image in self.state.images

    def codex_logged_in(self, container):
        return self.state.codex_login

    def install_npm(self, container, package):
        self.state.installs.append(package)
        binary = readiness._npm_binary_name(package)
        self.state.commands.add(binary)

    def pull_image(self, container, engine, image):
        self.state.pulls.append(image)
        self.state.images.add(image)


class ReadinessTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = {key: os.environ.get(key) for key in ("HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR")}
        self.addCleanup(self.restore)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(self.tmp.name, "claude")
        os.makedirs(os.environ["CLAUDE_CONFIG_DIR"])
        self.project = activation.canonical_project(os.path.join(self.tmp.name, "project"))
        os.makedirs(self.project)
        self.state = LocalState()

    def restore(self) -> None:
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def direct_entry(self, name: str):
        entry = add_entry(name, ["npx", "placeholder"])
        return update_entry(entry["id"], argv=["/bin/cat"])

    def test_reports_every_missing_prerequisite_without_credential_value(self) -> None:
        entry = self.direct_entry("codex")
        update_entry(
            entry["id"],
            secretEnvKeys=["API_TOKEN"],
            prerequisites={
                "files": ["/home/node/.codex/auth.json"],
                "sockets": ["/run/user/1000/docker.sock"],
                "credentials": ["SECOND_TOKEN"],
                "probes": ["codex-login-status"],
            },
        )
        report = readiness.readiness(entry["id"], self.project, Probe(self.project, self.state))
        self.assertFalse(report.ready)
        self.assertEqual(
            [(check.kind, check.label) for check in report.missing],
            [
                ("file", "/home/node/.codex/auth.json"),
                ("socket", "/run/user/1000/docker.sock"),
                ("credential", "API_TOKEN"),
                ("credential", "SECOND_TOKEN"),
                ("credential", "Codex login"),
            ],
        )
        payload = json.dumps(report.to_dict())
        self.assertNotIn("super-secret-value", payload)
        self.assertNotIn("envValue", payload)

    def test_direct_readiness_is_local_and_requires_running_project(self) -> None:
        entry = self.direct_entry("direct")
        self.assertTrue(readiness.readiness(entry["id"], self.project, Probe(self.project, self.state)).ready)
        with self.assertRaisesRegex(readiness.ReadinessError, "not running"):
            readiness.readiness(entry["id"], self.project, Probe(self.project, self.state, running=False))

    def test_http_has_no_runtime_readiness_and_only_reports_allowlist_hint(self) -> None:
        entry = add_remote_entry(
            "dozzle", "https://mcp.dozzle.example.test/api"
        )
        report = readiness.readiness(
            entry["id"], self.project, Probe(self.project, self.state, running=False)
        )
        self.assertTrue(report.ready)
        self.assertFalse(report.has_runtime_readiness)
        self.assertEqual(report.container, "")
        self.assertEqual(report.hints, ["boxa allow mcp.dozzle.example.test"])

        allowlist = os.path.join(
            self.tmp.name, ".config", "boxa", "allowed-domains.conf"
        )
        os.makedirs(os.path.dirname(allowlist), exist_ok=True)
        with open(allowlist, "w", encoding="utf-8") as fh:
            fh.write("*.example.test\n")
        self.assertEqual(
            readiness.readiness(entry["id"], self.project).hints, []
        )

    def test_http_secret_header_is_not_ready_until_value_exists(self) -> None:
        entry = add_remote_entry(
            "secure-remote",
            "https://remote.example/mcp",
            secret_header_keys=["Authorization"],
        )
        probe = Probe(self.project, self.state, running=False)
        report = readiness.readiness(entry["id"], self.project, probe)
        self.assertFalse(report.ready)
        self.assertEqual(
            [(check.kind, check.label, check.detail) for check in report.missing],
            [("secret-header", "Authorization", "secret value missing")],
        )
        self.assertIn(
            "Next: boxa mcp secret set secure-remote Authorization",
            report.hints,
        )
        self.assertIn(
            "The broker uses the same Boxa Allowlist as direct remote entries.",
            report.hints,
        )
        stdout = io.StringIO()
        with mock.patch.object(cli, "catalog_readiness", return_value=report), \
                contextlib.redirect_stdout(stdout):
            rc = cli._cmd_readiness(
                [entry["id"], "--project", self.project], as_json=False
            )
        self.assertEqual(rc, 1)
        self.assertIn("secret value missing", stdout.getvalue())
        self.assertIn("Next: boxa mcp secret set secure-remote", stdout.getvalue())
        self.state.credentials.add("Authorization")
        self.assertTrue(
            readiness.readiness(entry["id"], self.project, probe).ready
        )

    def test_secret_header_set_updates_store_and_real_readiness(self) -> None:
        entry = add_remote_entry(
            "secure-remote",
            "https://remote.example/mcp",
            secret_header_keys=["Authorization"],
        )
        secret = "Bearer value-that-must-not-leak"
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch("sys.stdin", io.StringIO(secret + "\n")), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            rc = cli._cmd_secret_set(
                [entry["id"], "authorization"], as_json=True
            )
        self.assertEqual(rc, 0, stderr.getvalue())
        self.assertNotIn(secret, stdout.getvalue() + stderr.getvalue())
        self.assertEqual(file_mode(global_secrets_path()), 0o600)
        self.assertEqual(
            read_header_secrets(global_secrets_path(), entry["id"]),
            {"authorization": secret},
        )
        self.assertTrue(readiness.readiness(entry["id"], self.project).ready)
        self.assertNotIn(
            "secret value missing",
            json.dumps(readiness.readiness(entry["id"], self.project).to_dict()),
        )

        updated = "Bearer rotated-value-that-must-not-leak"
        with mock.patch("sys.stdin", io.StringIO(updated + "\n")), \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(
                cli._cmd_secret_set(
                    [entry["name"], "Authorization"], as_json=False
                ),
                0,
            )
        self.assertEqual(
            read_header_secrets(global_secrets_path(), entry["id"]),
            {"authorization": updated},
        )
        with open(catalog_path(), encoding="utf-8") as fh:
            self.assertNotIn(updated, fh.read())

    def test_http_activation_succeeds_with_stopped_project(self) -> None:
        entry = add_remote_entry("remote", "https://remote.example/mcp")
        result = activation.activate(
            entry["id"],
            self.project,
            ["claude", "codex"],
            Probe(self.project, self.state, running=False),
        )
        self.assertTrue(result.changed)
        with open(activation.runtime_path(), encoding="utf-8") as fh:
            snapshot = json.load(fh)
        self.assertEqual(snapshot["entries"][entry["id"]]["url"], entry["url"])

    def test_npx_install_materializes_persistent_runtime_without_activation(self) -> None:
        entry = add_entry("context7", ["npx", "-y", "@upstash/context7-mcp@latest", "--stdio"])
        claude_path = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], ".claude.json")
        before = {path: os.path.exists(path) for path in (activation.activation_path(), claude_path)}
        first = Probe(self.project, self.state)
        self.assertFalse(readiness.readiness(entry["id"], self.project, first).ready)
        result = readiness.install(entry["id"], self.project, first)
        self.assertTrue(result.readiness.ready)
        self.assertEqual(self.state.installs, ["@upstash/context7-mcp@latest"])
        stored = load_catalog()["entries"][entry["id"]]
        self.assertEqual(stored["command"]["argv"], ["context7-mcp", "--stdio"])
        self.assertEqual(stored["runtimeKind"], "direct")
        self.assertEqual(before, {path: os.path.exists(path) for path in before})
        self.assertEqual(activation.load_activations()["projects"], {})
        # A new probe simulates ordinary Container recreation over shared npm state.
        self.assertTrue(readiness.readiness(entry["id"], self.project, Probe(self.project, self.state)).ready)

    def test_catalog_install_ready_prints_activation_next_step(self) -> None:
        entry = self.direct_entry("direct")
        report = readiness.install(
            entry["id"], self.project, Probe(self.project, self.state)
        )
        stdout = io.StringIO()
        with mock.patch.object(cli, "install_catalog_entry", return_value=report), \
                contextlib.redirect_stdout(stdout):
            rc = cli._cmd_catalog_install(
                [entry["id"], "--project", self.project], as_json=False
            )
        self.assertEqual(rc, 0)
        self.assertIn(
            f"Next: boxa mcp activate direct --project {self.project} "
            "--for claude|codex",
            stdout.getvalue(),
        )

    def test_catalog_install_not_ready_points_to_readiness(self) -> None:
        entry = add_entry("secure", ["npx", "secure-mcp"])
        update_entry(entry["id"], secretEnvKeys=["TOKEN"])
        report = readiness.install(
            entry["id"], self.project, Probe(self.project, self.state)
        )
        stdout = io.StringIO()
        with mock.patch.object(cli, "install_catalog_entry", return_value=report), \
                contextlib.redirect_stdout(stdout):
            rc = cli._cmd_catalog_install(
                [entry["id"], "--project", self.project], as_json=False
            )
        self.assertEqual(rc, 1)
        self.assertIn("missing credential: TOKEN", stdout.getvalue())
        self.assertIn(
            f"Next: boxa mcp readiness secure --project {self.project}",
            stdout.getvalue(),
        )

    def test_docker_install_is_project_local_and_survives_restart(self) -> None:
        entry = add_entry("github", ["docker", "run", "--rm", "ghcr.io/acme/mcp:1"])
        probe = Probe(self.project, self.state)
        self.assertFalse(readiness.readiness(entry["id"], self.project, probe).ready)
        result = readiness.install(entry["id"], self.project, probe)
        self.assertTrue(result.readiness.ready)
        self.assertEqual(self.state.pulls, ["ghcr.io/acme/mcp:1"])
        self.assertTrue(readiness.readiness(entry["id"], self.project, Probe(self.project, self.state)).ready)

    def test_docker_readiness_uses_constrained_adapter_policy(self) -> None:
        dangerous = [
            ["--privileged"],
            ["--mount", "type=bind,src=/home/node,dst=/loot"],
            ["--network", "host"],
            ["--pid", "host"],
            ["--cap-add", "SYS_ADMIN"],
            ["--device", "/dev/kvm"],
        ]
        for index, flags in enumerate(dangerous):
            entry = add_entry(f"unsafe-{index}", ["docker", "run", "image:1"])
            # Simulate a legacy/migrated catalog written before this policy.
            # Loading remains compatible; readiness must still refuse launch.
            path = os.path.join(os.environ["XDG_CONFIG_HOME"], "boxa", "mcp", "catalog.json")
            with open(path, encoding="utf-8") as fh:
                catalog = json.load(fh)
            catalog["entries"][entry["id"]]["command"]["argv"] = [
                "docker", "run", *flags, "image:1"
            ]
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(catalog, fh)
            self.state.images.add("image:1")
            report = readiness.readiness(
                entry["id"], self.project, Probe(self.project, self.state)
            )
            with self.subTest(flags=flags):
                self.assertFalse(report.ready)
                self.assertEqual(report.missing[0].kind, "runtime")
                self.assertIn("constrained Docker launch policy", report.missing[0].detail)
                before = activation.load_activations()
                with self.assertRaisesRegex(
                    activation.ActivationError,
                    "constrained Docker launch policy",
                ):
                    activation.activate(
                        entry["id"], self.project, ["claude"],
                        Probe(self.project, self.state),
                    )
                self.assertEqual(activation.load_activations(), before)

    def test_catalog_mutation_rejects_new_unsafe_docker_definition(self) -> None:
        entry = add_entry("safe", ["docker", "run", "image:1"])
        before = load_catalog()
        with self.assertRaisesRegex(
            Exception, "constrained Docker launch policy"
        ):
            update_entry(
                entry["id"],
                argv=["docker", "run", "--privileged", "image:1"],
            )
        self.assertEqual(load_catalog(), before)

    def test_docker_readiness_accepts_declared_env_and_image_command(self) -> None:
        entry = add_entry(
            "valid-docker",
            [
                "docker", "run", "--rm", "-i", "-e", "LOG_LEVEL=info",
                "-e", "API_TOKEN", "image:1", "serve", "--stdio",
            ],
        )
        self.state.images.add("image:1")
        self.state.credentials.add("API_TOKEN")
        report = readiness.readiness(
            entry["id"], self.project, Probe(self.project, self.state)
        )
        self.assertTrue(report.ready, report.to_dict())
        self.assertEqual(report.checks[0].label, "Docker image image:1")

    def test_install_does_not_satisfy_missing_credentials(self) -> None:
        entry = add_entry("secure", ["npx", "secure-mcp"])
        update_entry(entry["id"], secretEnvKeys=["TOKEN"])
        report = readiness.install(entry["id"], self.project, Probe(self.project, self.state))
        self.assertFalse(report.readiness.ready)
        self.assertEqual([(c.kind, c.label) for c in report.readiness.missing], [("credential", "TOKEN")])

    def test_activation_failure_is_non_mutating_then_ready_activation_succeeds(self) -> None:
        entry = add_entry("ctx", ["npx", "ctx-mcp"])
        probe = Probe(self.project, self.state)
        with self.assertRaisesRegex(activation.ActivationError, "not ready"):
            activation.activate(entry["id"], self.project, ["claude"], probe)
        self.assertEqual(activation.load_activations()["projects"], {})
        self.assertFalse(os.path.exists(os.path.join(os.environ["CLAUDE_CONFIG_DIR"], ".claude.json")))
        readiness.install(entry["id"], self.project, probe)
        result = activation.activate(entry["id"], self.project, ["claude"], probe)
        self.assertTrue(result.changed)

    def test_catalog_rejects_unknown_or_malformed_prerequisite_contract(self) -> None:
        entry = self.direct_entry("direct")
        with self.assertRaisesRegex(Exception, "unknown prerequisites"):
            update_entry(entry["id"], prerequisites={"urls": ["https://example.com"]})
        with self.assertRaisesRegex(Exception, "unsupported readiness probes"):
            update_entry(entry["id"], prerequisites={"probes": ["curl-service"]})

    def _interactive_activation(
        self, answer: str, *, stopped: bool = False
    ) -> subprocess.CompletedProcess[str]:
        cli = os.path.join(ROOT, "scripts", "mcp-cli.sh")
        argv0 = os.path.join(ROOT, "scripts", "_readiness_harness.sh")
        log_path = os.path.join(self.tmp.name, "interactive.log")
        harness = f'''
            source {shlex.quote(cli)}
            _resolve_project_key() {{ printf '%s\n' "$1"; }}
            readiness_calls=0
            _run_py() {{
                printf 'PY:%s\n' "$*" >> {shlex.quote(log_path)}
                if [ "$1" = readiness-json ]; then
                    readiness_calls=$((readiness_calls + 1))
                    if [ {str(stopped).lower()} = true ]; then
                        printf '%s\n' 'mcp.cli: target Boxa for /work/project is not running; readiness never starts it implicitly' >&2
                        return 1
                    fi
                    grep -q '^INSTALL:' {shlex.quote(log_path)}
                    return
                fi
                return 0
            }}
            cmd_install() {{ printf 'INSTALL:%s\n' "$*" >> {shlex.quote(log_path)}; return 0; }}
            cmd_activation activate context7 --project /work/project --for claude
        '''
        command = f"bash -c {shlex.quote(harness)} {shlex.quote(argv0)}"
        result = subprocess.run(
            ["script", "-qefc", command, "/dev/null"],
            input=answer + "\n",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            cwd=ROOT,
            check=False,
        )
        try:
            with open(log_path, encoding="utf-8") as fh:
                result.stdout += "\n" + fh.read()
        except FileNotFoundError:
            pass
        return result

    def test_interactive_activation_cancellation_leaves_no_activation_call(self) -> None:
        result = self._interactive_activation("n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cancelled; no MCP activation or agent config changed", result.stdout)
        self.assertNotIn("INSTALL:", result.stdout)
        self.assertNotIn("PY:activate-text", result.stdout)

    def test_interactive_activation_explicitly_installs_rechecks_then_activates(self) -> None:
        result = self._interactive_activation("y")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("INSTALL:context7 --project /work/project", result.stdout)
        self.assertGreaterEqual(result.stdout.count("PY:readiness-json"), 2)
        self.assertIn(
            "PY:activate-text context7 --project /work/project --for claude",
            result.stdout,
        )

    def test_interactive_stopped_activation_skips_install_and_records_pending(self) -> None:
        result = self._interactive_activation("", stopped=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("INSTALL:", result.stdout)
        self.assertNotIn("Entry is not ready", result.stdout)
        self.assertIn(
            "PY:activate-text context7 --project /work/project --for claude",
            result.stdout,
        )


if __name__ == "__main__":
    unittest.main()
