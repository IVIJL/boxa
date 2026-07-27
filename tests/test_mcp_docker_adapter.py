"""ADR 0021 issue 06: constrained service-isolated Docker launch."""

from __future__ import annotations

import os
import sys
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp.docker_adapter import (  # noqa: E402
    DockerAdapterError,
    build_plan,
    validate_plan_shape,
)
from mcp import relay  # noqa: E402
from mcp import protocol  # noqa: E402


class DockerAdapterTest(unittest.TestCase):
    def entry(self, argv=None, *, secrets=None, env=None):
        return {
            "executionMode": "service-isolated",
            "runtimeKind": "docker",
            "command": {"argv": argv or ["docker", "run", "--rm", "image:1", "serve"]},
            "envKeys": sorted((env or {}).keys()),
            "secretEnvKeys": secrets or [],
            "env": env or {},
        }

    def test_plan_has_only_project_mount_declared_env_and_stdio(self):
        entry = self.entry(secrets=["TOKEN"], env={"LOG": "info"})
        plan = build_plan(
            entry, "id", "claude", "/work/app", "/work/app/sub",
            {"LOG": "info", "TOKEN": "secret"},
        )
        self.assertEqual(plan["image"], "image:1")
        self.assertEqual(plan["command"], ["serve"])
        joined = " ".join(plan["argv"])
        self.assertIn("type=bind,src=/work/app,dst=/work/app", joined)
        self.assertNotIn("docker.sock", joined)
        self.assertNotIn("--privileged", plan["argv"])
        self.assertEqual(plan["argv"][-2:], ["image:1", "serve"])
        encoded = protocol.encode_reply(True, launch=plan)
        ok, error, decoded = protocol.decode_reply_details(encoded.rstrip())
        self.assertTrue(ok, error)
        self.assertEqual(decoded, plan)

    def test_rejects_every_docker_control_option_before_image(self):
        dangerous = [
            ["-v", "/home/node:/loot"], ["--mount", "type=bind,src=/,dst=/host"],
            ["--privileged"], ["--network", "host"], ["--pid", "host"],
            ["--cap-add", "SYS_ADMIN"], ["--device", "/dev/kvm"],
            ["--userns", "host"], ["--name", "victim"],
        ]
        for flags in dangerous:
            with self.subTest(flags=flags), self.assertRaises(DockerAdapterError):
                build_plan(
                    self.entry(["docker", "run", *flags, "image:1"]),
                    "id", "claude", "/work/app", None, {},
                )

    def test_command_tokens_after_image_are_never_docker_options(self):
        plan = build_plan(
            self.entry(["docker", "run", "image:1", "--mount", "not-a-docker-flag"]),
            "id", "claude", "/work/app", None, {},
        )
        image_index = plan["argv"].index("image:1")
        self.assertEqual(plan["argv"][image_index + 1 :], ["--mount", "not-a-docker-flag"])

    def test_rogue_plan_cannot_change_snapshot_bound_fields(self):
        entry = self.entry(secrets=["TOKEN"], env={"LOG": "info"})
        plan = build_plan(entry, "id", "claude", "/work/app", None, {"LOG": "info", "TOKEN": "s"})
        mutations = (
            ("image", "evil:latest"), ("command", ["evil"]),
            ("project", "/home/node"), ("cwd", "/home/node"),
        )
        for field, value in mutations:
            rogue = dict(plan)
            rogue[field] = value
            with self.subTest(field=field), self.assertRaises(DockerAdapterError):
                validate_plan_shape(rogue, entry, "id", "claude", "/work/app", None)

        extra = dict(plan)
        extra["environment"] = {**plan["environment"], "DOCKER_HOST": "unix:///run/user/1000/docker.sock"}
        with self.assertRaises(DockerAdapterError):
            validate_plan_shape(extra, entry, "id", "claude", "/work/app", None)

        changed_nonsecret = dict(plan)
        changed_nonsecret["environment"] = {"LOG": "debug", "TOKEN": "s"}
        with self.assertRaises(DockerAdapterError):
            validate_plan_shape(changed_nonsecret, entry, "id", "claude", "/work/app", None)

    def test_cwd_outside_project_falls_back_to_project(self):
        plan = build_plan(self.entry(), "id", "claude", "/work/app", "/home/node", {})
        self.assertIn("/work/app", plan["argv"])
        self.assertNotIn("/home/node", plan["argv"])

    def test_mount_field_injection_in_project_path_is_refused(self):
        with self.assertRaisesRegex(DockerAdapterError, "represented safely"):
            build_plan(
                self.entry(), "id", "claude",
                "/work/app,src=/home/node", None, {},
            )

    def test_adapter_closes_inherited_descriptors_and_exposes_socket_only_to_docker_cli(self):
        plan = build_plan(self.entry(), "id", "claude", "/work/app", None, {})
        child = mock.Mock()
        child.wait.return_value = 0
        with mock.patch.object(relay.subprocess, "Popen", return_value=child) as popen:
            self.assertEqual(relay._launch_docker_adapter(plan), 0)
        kwargs = popen.call_args.kwargs
        self.assertTrue(kwargs["close_fds"])
        self.assertEqual(kwargs["env"]["DOCKER_HOST"], "unix:///run/user/1000/docker.sock")
        self.assertNotIn("DOCKER_HOST", plan["environment"])
        self.assertNotIn("docker.sock", " ".join(plan["argv"]))

    def test_rootless_socket_is_node_only_not_boxa_bridge(self):
        path = os.path.join(ROOT, "scripts", "start-rootless-docker.sh")
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn('chgrp node "$SOCKET" && chmod 0600 "$SOCKET"', text)
        self.assertNotIn('chgrp boxa-bridge "$SOCKET"', text)


if __name__ == "__main__":
    unittest.main()
