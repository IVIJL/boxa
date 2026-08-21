"""ADR 0028 issue 01: per-invocation Claude MCP launch profiles."""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import cli, launch_profile, trusted  # noqa: E402
from mcp.catalog import CATALOG_VERSION  # noqa: E402
from mcp.launch_profile import claude_server_definition, rendered_name  # noqa: E402


class LaunchProfileTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.project = "/host/projects/example"
        self.identity = os.path.join(self.tmp.name, "identity.json")
        self.snapshot = os.path.join(self.tmp.name, "runtime.json")
        with open(self.identity, "w", encoding="utf-8") as fh:
            json.dump({"project": "example", "projectKey": self.project}, fh)

        identity_patch = mock.patch.dict(
            os.environ,
            {"BOXA_MCP_IDENTITY_PATH": self.identity},
        )
        identity_patch.start()
        self.addCleanup(identity_patch.stop)
        snapshot_patch = mock.patch.object(
            trusted, "RUNTIME_SNAPSHOT_PATH", self.snapshot
        )
        snapshot_patch.start()
        self.addCleanup(snapshot_patch.stop)

    def _entry(self, name, *, mode="service-isolated", entry_type="stdio"):
        entry_id = str(uuid.uuid4())
        if entry_type == "http":
            return entry_id, {
                "id": entry_id,
                "name": name,
                "type": "http",
                "url": f"https://{name}.example.test/mcp",
                "readiness": {"summary": "no-runtime-readiness"},
            }
        return entry_id, {
            "id": entry_id,
            "name": name,
            "type": entry_type,
            "executionMode": mode,
            "runtimeKind": "direct",
            "readiness": {"summary": "requires-project"},
            "command": {"argv": ["/bin/echo", name]},
            "envKeys": [],
            "secretEnvKeys": [],
        }

    def _record(self, entry_id, consumers=None, *, enabled=None):
        record = {
            "catalogId": entry_id,
            "consumers": consumers or ["claude"],
        }
        if enabled is not None:
            record["enabled"] = enabled
        return record

    def _write_snapshot(self, entries=None, records=None):
        data = {
            "version": 1,
            "catalogVersion": CATALOG_VERSION,
            "entries": entries or {},
            "projects": {self.project: records or {}},
        }
        with open(self.snapshot, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        return data

    def _run_cli(self, command="claude-launch-profile"):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            rc = cli.main([command])
        return rc, stdout.getvalue(), stderr.getvalue()

    def test_empty_project_profile_has_no_servers(self):
        runtime = self._write_snapshot()

        self.assertEqual(
            launch_profile.claude_launch_profile(
                runtime=runtime, project=self.project
            ),
            {"mcpServers": {}},
        )

    def test_active_entries_apply_consumer_enabled_and_supported_type_filters(self):
        active_id, active = self._entry("active", mode="agent-trusted")
        codex_id, codex = self._entry("codex-only")
        disabled_id, disabled = self._entry("disabled")
        remote_id, remote = self._entry("remote", entry_type="http")
        missing_id = str(uuid.uuid4())
        runtime = {
            "entries": {
                active_id: active,
                codex_id: codex,
                disabled_id: disabled,
                remote_id: remote,
            },
            "projects": {
                self.project: {
                    active_id: self._record(active_id),
                    codex_id: self._record(codex_id, ["codex"]),
                    disabled_id: self._record(disabled_id, enabled=False),
                    remote_id: self._record(remote_id),
                    missing_id: self._record(missing_id),
                }
            },
        }

        project, entries = launch_profile.active_project_entries(
            "claude", runtime=runtime, project=self.project
        )

        self.assertEqual(project, self.project)
        self.assertEqual(entries, [(active_id, active), (remote_id, remote)])

    def test_pending_activation_is_excluded_from_both_launch_profiles(self):
        entry_id, entry = self._entry("pending")
        runtime = {
            "entries": {entry_id: entry},
            "projects": {
                self.project: {
                    entry_id: {
                        **self._record(entry_id, ["claude", "codex"], enabled=False),
                        "pendingReason": "target Boxa is not running",
                    }
                }
            },
        }

        self.assertEqual(
            launch_profile.claude_launch_profile(
                runtime=runtime, project=self.project
            ),
            {"mcpServers": {}},
        )
        self.assertEqual(
            launch_profile.codex_launch_profile(
                runtime=runtime,
                project=self.project,
                config_path=os.path.join(self.tmp.name, "missing.toml"),
            ),
            [],
        )

    def test_http_entries_use_native_claude_and_codex_transports(self):
        entry_id, entry = self._entry("dozzle", entry_type="http")
        entry["headers"] = {"X-Region": "eu"}
        runtime = {
            "entries": {entry_id: entry},
            "projects": {
                self.project: {
                    entry_id: self._record(entry_id, ["claude", "codex"])
                }
            },
        }
        self.assertEqual(
            launch_profile.claude_launch_profile(
                runtime=runtime, project=self.project
            )["mcpServers"]["boxa-dozzle"],
            {
                "type": "http",
                "url": entry["url"],
                "headers": {"X-Region": "eu"},
            },
        )
        self.assertEqual(
            launch_profile.codex_launch_profile(
                runtime=runtime,
                project=self.project,
                config_path=os.path.join(self.tmp.name, "missing.toml"),
            ),
            [
                "mcp_servers.boxa-dozzle.enabled=true",
                f'mcp_servers.boxa-dozzle.url={json.dumps(entry["url"])}',
                'mcp_servers.boxa-dozzle.http_headers={ "X-Region" = "eu" }',
            ],
        )

    def test_secret_header_http_entries_use_header_free_loopback_profiles(self):
        entry_id, entry = self._entry("secure", entry_type="http")
        entry["headers"] = {"X-Region": "eu"}
        entry["secretHeaderKeys"] = ["Authorization"]
        runtime = {
            "entries": {entry_id: entry},
            "projects": {
                self.project: {
                    entry_id: self._record(entry_id, ["claude", "codex"])
                }
            },
        }
        port_path = os.path.join(self.tmp.name, "http-proxy.port")
        with open(port_path, "w", encoding="utf-8") as fh:
            fh.write("43123\n")
        with mock.patch.dict(
            os.environ, {"BOXA_MCP_HTTP_PROXY_PORT_FILE": port_path}
        ), mock.patch(
            "mcp.http_proxy.request_route_token",
            side_effect=lambda _entry_id, consumer: {
                "claude": "A" * 43,
                "codex": "B" * 43,
            }[consumer],
        ):
            claude = launch_profile.claude_launch_profile(
                runtime=runtime, project=self.project
            )["mcpServers"]["boxa-secure"]
            codex = launch_profile.codex_launch_profile(
                runtime=runtime,
                project=self.project,
                config_path=os.path.join(self.tmp.name, "missing.toml"),
            )
        expected_claude_url = f"http://127.0.0.1:43123/mcp/{'A' * 43}/{entry_id}"
        expected_codex_url = f"http://127.0.0.1:43123/mcp/{'B' * 43}/{entry_id}"

        self.assertEqual(claude, {"type": "http", "url": expected_claude_url})
        self.assertEqual(
            codex,
            [
                "mcp_servers.boxa-secure.enabled=true",
                f"mcp_servers.boxa-secure.url={json.dumps(expected_codex_url)}",
            ],
        )
        rendered = json.dumps({"claude": claude, "codex": codex})
        self.assertNotIn("Authorization", rendered)
        self.assertNotIn("X-Region", rendered)

    def test_unavailable_proxy_skips_only_affected_entries_with_warning(self):
        secure_id, secure = self._entry("secure", entry_type="http")
        secure["secretHeaderKeys"] = ["Authorization"]
        direct_id, direct = self._entry("direct", entry_type="http")
        stdio_id, stdio = self._entry("stdio")
        runtime = {
            "entries": {
                secure_id: secure,
                direct_id: direct,
                stdio_id: stdio,
            },
            "projects": {
                self.project: {
                    secure_id: self._record(secure_id, ["claude", "codex"]),
                    direct_id: self._record(direct_id, ["claude", "codex"]),
                    stdio_id: self._record(stdio_id, ["claude", "codex"]),
                }
            },
        }
        missing_port = os.path.join(self.tmp.name, "missing-http-proxy.port")
        stderr = io.StringIO()
        with mock.patch.dict(
            os.environ, {"BOXA_MCP_HTTP_PROXY_PORT_FILE": missing_port}
        ), contextlib.redirect_stderr(stderr):
            claude = launch_profile.claude_launch_profile(
                runtime=runtime, project=self.project
            )
            codex = launch_profile.codex_launch_profile(
                runtime=runtime,
                project=self.project,
                config_path=os.path.join(self.tmp.name, "missing.toml"),
            )

        self.assertNotIn("boxa-secure", claude["mcpServers"])
        self.assertEqual(
            claude["mcpServers"]["boxa-direct"],
            {"type": "http", "url": direct["url"]},
        )
        self.assertIn("boxa-stdio", claude["mcpServers"])
        rendered_codex = "\n".join(codex)
        self.assertNotIn("boxa-secure", rendered_codex)
        self.assertIn("boxa-direct", rendered_codex)
        self.assertIn("boxa-stdio", rendered_codex)
        self.assertEqual(stderr.getvalue().count("skipping proxied MCP entry"), 2)
        self.assertIn("secure", stderr.getvalue())

    def test_claude_profile_matches_existing_server_definition(self):
        entry_id, entry = self._entry("echo")
        runtime = {
            "entries": {entry_id: entry},
            "projects": {
                self.project: {entry_id: self._record(entry_id)}
            },
        }

        profile = launch_profile.claude_launch_profile(
            runtime=runtime, project=self.project
        )

        self.assertEqual(
            profile,
            {
                "mcpServers": {
                    rendered_name(entry["name"]):
                        claude_server_definition(
                            entry_id, self.project, entry
                        )
                }
            },
        )

    def test_cli_emits_raw_profile_json_only(self):
        entry_id, entry = self._entry("echo")
        self._write_snapshot(
            {entry_id: entry}, {entry_id: self._record(entry_id)}
        )

        rc, stdout, stderr = self._run_cli()

        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(stdout)["mcpServers"].keys(), {"boxa-echo"})
        self.assertEqual(stderr, "")

    def test_cli_missing_snapshot_fails_silently_for_wrapper_fallback(self):
        rc, stdout, stderr = self._run_cli()

        self.assertEqual((rc, stdout, stderr), (1, "", ""))

    def test_cli_invalid_snapshot_fails_silently_for_wrapper_fallback(self):
        with open(self.snapshot, "w", encoding="utf-8") as fh:
            fh.write("not json")

        rc, stdout, stderr = self._run_cli()

        self.assertEqual((rc, stdout, stderr), (1, "", ""))

    def test_cli_unreadable_identity_fails_silently_for_wrapper_fallback(self):
        with open(self.identity, "w", encoding="utf-8") as fh:
            fh.write("not json")
        self._write_snapshot()

        rc, stdout, stderr = self._run_cli()

        self.assertEqual((rc, stdout, stderr), (1, "", ""))

    def test_codex_profile_disables_shared_servers_and_defines_activations(self):
        entry_id, entry = self._entry("echo service")
        runtime = {
            "entries": {entry_id: entry},
            "projects": {
                self.project: {
                    entry_id: self._record(entry_id, ["codex"])
                }
            },
        }
        config = os.path.join(self.tmp.name, "config.toml")
        with open(config, "w", encoding="utf-8") as fh:
            fh.write(
                '[mcp_servers.host-only]\ncommand = "host-command"\n\n'
                '[mcp_servers."boxa-echo service"]\nenabled = false\n\n'
                '[unrelated]\nvalue = true\n'
            )

        profile = launch_profile.codex_launch_profile(
            runtime=runtime,
            project=self.project,
            config_path=config,
        )

        key = 'mcp_servers."boxa-echo service"'
        self.assertEqual(
            profile,
            [
                "mcp_servers.host-only.enabled=false",
                f"{key}.enabled=true",
                f'{key}.command="boxa-mcp-run"',
                f"{key}.args=" + json.dumps(
                    [
                        "--catalog-id",
                        entry_id,
                        "--consumer",
                        "codex",
                        "--project",
                        self.project,
                        "echo service",
                    ],
                    separators=(",", ":"),
                ),
            ],
        )

    def test_codex_profile_reads_shared_config_on_every_call(self):
        runtime = self._write_snapshot()
        config = os.path.join(self.tmp.name, "config.toml")
        with open(config, "w", encoding="utf-8") as fh:
            fh.write("[mcp_servers.first]\ncommand = \"first\"\n")

        first = launch_profile.codex_launch_profile(
            runtime=runtime, project=self.project, config_path=config
        )
        with open(config, "a", encoding="utf-8") as fh:
            fh.write("[mcp_servers.second]\ncommand = \"second\"\n")
        second = launch_profile.codex_launch_profile(
            runtime=runtime, project=self.project, config_path=config
        )

        self.assertEqual(first, ["mcp_servers.first.enabled=false"])
        self.assertEqual(
            second,
            [
                "mcp_servers.first.enabled=false",
                "mcp_servers.second.enabled=false",
            ],
        )

    def test_codex_profile_does_not_block_on_non_regular_shared_config(self):
        config = os.path.join(self.tmp.name, "config.toml")
        os.mkfifo(config)
        code = (
            "from mcp.launch_profile import _shared_codex_server_names; "
            "import sys; print(_shared_codex_server_names(sys.argv[1]))"
        )
        env = dict(os.environ)
        env["PYTHONPATH"] = os.path.join(ROOT, "scripts")

        proc = subprocess.run(
            [sys.executable, "-c", code, config],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=2,
            check=False,
            env=env,
        )

        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "set()\n")

    def test_codex_cli_emits_one_override_per_line(self):
        self._write_snapshot()
        config_dir = os.path.join(self.tmp.name, ".codex")
        os.makedirs(config_dir)
        with open(os.path.join(config_dir, "config.toml"), "w", encoding="utf-8") as fh:
            fh.write("[mcp_servers.host-only]\ncommand = \"host-command\"\n")

        with mock.patch.dict(os.environ, {"HOME": self.tmp.name}):
            rc, stdout, stderr = self._run_cli("codex-launch-profile")

        self.assertEqual(rc, 0)
        self.assertEqual(stdout, "mcp_servers.host-only.enabled=false\n")
        self.assertEqual(stderr, "")

    def test_codex_cli_invalid_config_fails_silently_for_wrapper_fallback(self):
        self._write_snapshot()
        config_dir = os.path.join(self.tmp.name, ".codex")
        os.makedirs(config_dir)
        with open(os.path.join(config_dir, "config.toml"), "w", encoding="utf-8") as fh:
            fh.write("not toml =")

        with mock.patch.dict(os.environ, {"HOME": self.tmp.name}):
            rc, stdout, stderr = self._run_cli("codex-launch-profile")

        self.assertEqual((rc, stdout, stderr), (1, "", ""))


if __name__ == "__main__":
    unittest.main()
