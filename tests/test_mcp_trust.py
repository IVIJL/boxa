"""ADR 0021 issue 05: host grant and agent-trusted Codex delegation."""

from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
import threading
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import activation, broker, protocol, readiness, relay, trusted  # noqa: E402
from mcp.catalog import (  # noqa: E402
    CatalogError,
    add_entry,
    load_catalog,
    mode_preview,
    set_execution_mode,
    update_entry,
)
from mcp.secrets import project_secrets_path, store_server_secrets  # noqa: E402


class TrustTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = {
            key: os.environ.get(key)
            for key in ("HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR")
        }
        self.addCleanup(self.restore)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(self.tmp.name, "claude")
        os.makedirs(os.environ["CLAUDE_CONFIG_DIR"])
        runtime_patch = mock.patch.object(
            trusted, "RUNTIME_SNAPSHOT_PATH", activation.runtime_path()
        )
        runtime_patch.start()
        self.addCleanup(runtime_patch.stop)
        self.project = os.path.join(self.tmp.name, "project")
        os.makedirs(self.project)

    def restore(self) -> None:
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _grant(self, entry: dict) -> dict:
        with mock.patch("mcp.catalog._host_mode_command", return_value=True):
            return set_execution_mode(entry["id"], "agent-trusted")

    def _direct(self, name: str) -> dict:
        entry = add_entry(name, ["npx", "placeholder"])
        return update_entry(entry["id"], argv=["/bin/cat"])

    def test_codex_entry_defaults_isolated_and_declares_local_login_probe(self) -> None:
        entry = add_entry("codex-delegate", ["codex", "mcp-server"])
        self.assertEqual(entry["executionMode"], "service-isolated")
        self.assertEqual(
            entry["prerequisites"], {"probes": ["codex-login-status"]}
        )
        preview = mode_preview(entry["id"], "agent-trusted")
        self.assertEqual(preview["id"], entry["id"])
        self.assertEqual(preview["command"], ["codex", "mcp-server"])
        self.assertIn("node rootless Docker socket when present", preview["access"])

    def test_direct_mode_grant_refuses_inside_container(self) -> None:
        entry = add_entry("codex-delegate", ["codex", "mcp-server"])
        with mock.patch("mcp.catalog._host_mode_command", return_value=False):
            with self.assertRaisesRegex(CatalogError, "host-only"):
                set_execution_mode(entry["id"], "agent-trusted")

    def test_mode_is_immutable_while_active(self) -> None:
        entry = self._direct("delegate")
        with mock.patch("mcp.catalog._host_mode_command", return_value=True), mock.patch(
            "mcp.catalog._activation_count", return_value=1
        ):
            with self.assertRaisesRegex(CatalogError, "activation"):
                set_execution_mode(entry["id"], "agent-trusted")

    def test_secret_contract_and_retained_values_refuse_names_only(self) -> None:
        entry = self._direct("delegate")
        update_entry(entry["id"], secretEnvKeys=["DECLARED_TOKEN"])
        store_server_secrets(
            project_secrets_path(self.project),
            "delegate",
            {"RETAINED_TOKEN": "secret-value-must-not-leak"},
        )
        with mock.patch("mcp.catalog._host_mode_command", return_value=True):
            with self.assertRaises(CatalogError) as ctx:
                set_execution_mode(entry["id"], "agent-trusted")
        message = str(ctx.exception)
        self.assertIn("DECLARED_TOKEN", message)
        self.assertIn("RETAINED_TOKEN", message)
        self.assertNotIn("secret-value-must-not-leak", message)

    def test_node_readable_runtime_snapshot_contains_no_secret_values(self) -> None:
        entry = self._direct("service")
        update_entry(entry["id"], secretEnvKeys=["SERVICE_TOKEN"])
        store_server_secrets(
            project_secrets_path(self.project),
            "service",
            {"SERVICE_TOKEN": "snapshot-secret-must-not-leak"},
        )
        activation.refresh_runtime()
        with open(activation.runtime_path(), encoding="utf-8") as fh:
            raw = fh.read()
        self.assertIn("SERVICE_TOKEN", raw)
        self.assertNotIn("snapshot-secret-must-not-leak", raw)
        self.assertNotIn("secrets.json", raw)

    def test_mode_refuses_catalog_override_of_fixed_clean_baseline(self) -> None:
        entry = self._direct("delegate")
        update_entry(entry["id"], env={"PATH": "/attacker/bin"})
        with mock.patch("mcp.catalog._host_mode_command", return_value=True):
            with self.assertRaisesRegex(CatalogError, "fixed baseline"):
                set_execution_mode(entry["id"], "agent-trusted")

    def test_grant_and_rename_preserve_stable_trust_identity(self) -> None:
        entry = self._direct("old")
        trusted = self._grant(entry)
        renamed = update_entry(entry["id"], name="new")
        self.assertEqual(renamed["id"], trusted["id"])
        self.assertEqual(renamed["executionMode"], "agent-trusted")

    def _runtime(self, entry: dict, consumers: list[str] | None = None) -> None:
        path = activation.runtime_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "version": 1,
                    "catalogVersion": 2,
                    "entries": {entry["id"]: entry},
                    "projects": {
                        self.project: {
                            entry["id"]: {
                                "catalogId": entry["id"],
                                "consumers": consumers or ["claude"],
                                "enabled": True,
                            }
                        }
                    },
                },
                fh,
            )

    def test_broker_plan_is_bound_secret_free_and_uses_fixed_socket_pointers(self) -> None:
        ambient = "ambient-bearer-token-must-not-leak"
        entry = add_entry("codex-delegate", ["codex", "mcp-server"])
        update_entry(entry["id"], env={"LOG_LEVEL": "debug"}, envKeys=["LOG_LEVEL"])
        entry = self._grant(entry)
        self._runtime(entry)
        with mock.patch.object(broker, "project_key", return_value=self.project), mock.patch.object(
            broker, "_is_socket", side_effect=lambda path: path in {
                broker._DOCKER_SOCKET, broker._SSH_SOCKET
            }
        ), mock.patch.dict(os.environ, {"TEST_BEARER_TOKEN": ambient}):
            plan = broker._build_agent_trusted_plan(
                "codex-delegate", self.project, self.project, entry["id"], "claude"
            )
        self.assertEqual(plan["catalogId"], entry["id"])
        self.assertEqual(plan["consumer"], "claude")
        self.assertEqual(plan["argv"], ["codex", "mcp-server"])
        self.assertEqual(plan["env"]["HOME"], "/home/node")
        self.assertEqual(
            plan["env"]["DOCKER_HOST"], "unix:///run/user/1000/docker.sock"
        )
        self.assertEqual(plan["env"]["SSH_AUTH_SOCK"], "/tmp/ssh-agent.sock")
        self.assertEqual(plan["env"]["LOG_LEVEL"], "debug")
        self.assertNotIn("TEST_BEARER_TOKEN", plan["env"])
        self.assertNotIn(ambient, json.dumps(plan))
        with mock.patch.object(broker, "project_key", return_value=self.project):
            with self.assertRaisesRegex(broker.BrokerError, "consumer"):
                broker._build_agent_trusted_plan(
                    "codex-delegate", self.project, None, entry["id"], "codex"
                )
            with self.assertRaisesRegex(broker.BrokerError, "not this Container"):
                broker._build_agent_trusted_plan(
                    "codex-delegate", "/wrong", None, entry["id"], "claude"
                )

    def test_broker_returns_plan_without_spawning_and_relay_launches_clean_env(self) -> None:
        entry = self._grant(add_entry("codex-delegate", ["codex", "mcp-server"]))
        self._runtime(entry)
        client, server = socket.socketpair()
        self.addCleanup(client.close)
        with mock.patch.object(broker, "project_key", return_value=self.project), mock.patch(
            "subprocess.Popen"
        ) as broker_popen:
            thread = threading.Thread(target=broker._handle, args=(server,))
            thread.start()
            client.sendall(
                protocol.encode_request(
                    "codex-delegate", self.project, self.project,
                    catalog_id=entry["id"], consumer="claude",
                )
            )
            ok, error, plan = protocol.decode_reply_details(
                protocol.read_line(client.recv)
            )
            thread.join(timeout=5)
        self.assertTrue(ok, error)
        self.assertIsNotNone(plan)
        broker_popen.assert_not_called()
        with mock.patch.object(
            relay, "container_project_key", return_value=self.project
        ):
            validated = relay._validate_agent_trusted_plan(
                plan or {}, "codex-delegate", self.project, entry["id"],
                "claude", self.project,
            )
        self.assertEqual(validated, plan)
        child = mock.Mock()
        child.wait.return_value = 17
        with mock.patch("pwd.getpwuid") as getpwuid, mock.patch.object(
            relay.subprocess, "Popen", return_value=child
        ) as local_popen:
            getpwuid.return_value.pw_name = "node"
            self.assertEqual(relay._launch_agent_trusted(plan or {}), 17)
        kwargs = local_popen.call_args.kwargs
        self.assertEqual(local_popen.call_args.args[0], ["codex", "mcp-server"])
        self.assertEqual(kwargs["env"], (plan or {})["env"])
        self.assertNotIn("TEST_BEARER_TOKEN", kwargs["env"])

    def test_forged_broker_plan_cannot_expand_host_snapshot_authority(self) -> None:
        entry = self._grant(add_entry("codex-delegate", ["codex", "mcp-server"]))
        self._runtime(entry)
        valid = trusted.build_launch_plan(
            entry, entry["id"], "claude", self.project
        )
        forged_plans = []
        for mutate in (
            lambda plan: plan.update(argv=["sh", "-c", "steal-private-state"]),
            lambda plan: plan["env"].update(TEST_BEARER_TOKEN="forged"),
            lambda plan: plan.update(cwd="/home/node/.ssh"),
        ):
            forged = json.loads(json.dumps(valid))
            mutate(forged)
            forged_plans.append(forged)
        with mock.patch.object(
            relay, "container_project_key", return_value=self.project
        ):
            for forged in forged_plans:
                with self.subTest(forged=forged):
                    with self.assertRaisesRegex(relay.RelayError, "does not exactly match"):
                        relay._validate_agent_trusted_plan(
                            forged, "codex-delegate", self.project, entry["id"],
                            "claude", self.project,
                        )

    def test_forged_broker_cannot_downgrade_trusted_request_to_proxy(self) -> None:
        entry = self._grant(add_entry("codex-delegate", ["codex", "mcp-server"]))
        self._runtime(entry)
        client, server = socket.socketpair()
        self.addCleanup(client.close)

        def forged_broker() -> None:
            try:
                protocol.read_line(server.recv)
                server.sendall(protocol.encode_reply(True))
            finally:
                server.close()

        thread = threading.Thread(target=forged_broker)
        thread.start()
        with mock.patch.object(relay, "require_container"), mock.patch.object(
            relay, "container_project_key", return_value=self.project
        ), mock.patch.object(relay, "_connect", return_value=client):
            with self.assertRaisesRegex(relay.RelayError, "omitted"):
                relay.run(
                    "codex-delegate", self.project,
                    catalog_id=entry["id"], consumer="claude",
                )
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())

    def test_codex_login_readiness_is_stubbed_and_self_activation_refused(self) -> None:
        entry = self._grant(add_entry("codex-delegate", ["codex", "mcp-server"]))

        class Probe(readiness.ProjectProbe):
            def find_running(probe_self, project_key):
                return "boxa-project" if project_key == self.project else None

            def command_path(probe_self, container, command, user):
                self.assertEqual((command, user), ("codex", "node"))
                return "/usr/local/share/npm-global/bin/codex"

            def codex_logged_in(probe_self, container):
                return True

        self.assertTrue(readiness.readiness(entry["id"], self.project, Probe()).ready)
        with self.assertRaisesRegex(activation.ActivationError, "only for Claude"):
            activation.activate(entry["id"], self.project, ["codex"], Probe())


if __name__ == "__main__":
    unittest.main()
