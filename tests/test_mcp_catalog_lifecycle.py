"""ADR 0021 issue 07: transactional multi-Project catalog lifecycle."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from mcp import activation, broker, trusted  # noqa: E402
from mcp.catalog import (  # noqa: E402
    add_entry,
    load_catalog,
    remove_entry,
    set_execution_mode,
    update_entry,
)
from mcp.secrets import (  # noqa: E402
    project_secrets_path,
    read_server_secrets,
    store_server_secrets,
)


class MultiProbe(activation.DockerProbe):
    def __init__(self, running, ready=True):
        self.running = set(running)
        self.is_ready = ready
        self.seen = []

    def find_running(self, project_key):
        self.seen.append(project_key)
        return "boxa-" + os.path.basename(project_key) if project_key in self.running else None

    def ready(self, container, entry):
        return self.is_ready and entry["command"]["argv"] == ["/bin/echo", "new"]


class CatalogLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old = {
            key: os.environ.get(key)
            for key in ("HOME", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR")
        }
        self.addCleanup(self._restore)
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(self.tmp.name, ".claude")
        os.makedirs(os.environ["CLAUDE_CONFIG_DIR"])
        self.projects = [
            activation.canonical_project(os.path.join(self.tmp.name, name))
            for name in ("one", "two")
        ]
        for project in self.projects:
            os.makedirs(project)
            subprocess.run(["git", "-C", project, "init", "-q"], check=True)
        added = add_entry("echo", ["npx", "placeholder"])
        self.entry = update_entry(added["id"], argv=["/bin/echo", "old"])

    def _restore(self):
        for key, value in self.old.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def _activate(self, project, consumers):
        probe = MultiProbe([project])
        probe.ready = lambda container, entry: True
        activation.activate(self.entry["id"], project, consumers, probe)

    @staticmethod
    def _state(paths):
        result = {}
        for path in paths:
            if os.path.exists(path):
                with open(path, "rb") as fh:
                    result[path] = (
                        True,
                        fh.read(),
                        stat.S_IMODE(os.stat(path).st_mode),
                    )
            else:
                result[path] = (False, b"", 0)
        return result

    def _all_paths(self):
        paths = [
            activation.catalog_path(),
            activation.activation_path(),
            activation.runtime_path(),
            activation.render_target_path(),
            activation.render_state_path(),
        ]
        for project in self.projects:
            _relative, exclude_path, codex_path = activation._codex_git_paths(project)
            paths.extend((codex_path, exclude_path))
            paths.append(project_secrets_path(project))
        return paths

    def test_rename_preserves_identity_mode_activations_without_readiness(self):
        secret_path = project_secrets_path(self.projects[0])
        store_server_secrets(secret_path, "echo", {"TOKEN": "preserved"})
        self._activate(self.projects[0], ["claude"])
        self._activate(self.projects[1], ["codex"])
        before_activations = activation.load_activations()
        bomb = mock.Mock()

        renamed = update_entry(self.entry["id"], name="renamed", probe=bomb)

        self.assertEqual(renamed["id"], self.entry["id"])
        self.assertEqual(renamed["executionMode"], self.entry["executionMode"])
        self.assertEqual(activation.load_activations(), before_activations)
        bomb.find_running.assert_not_called()
        with open(
            activation.render_target_path(),
            encoding="utf-8",
        ) as fh:
            claude = json.load(fh)
        self.assertIn(
            "boxa-renamed",
            claude["projects"][self.projects[0]]["mcpServers"],
        )
        with open(activation.codex_config_path(self.projects[1]), encoding="utf-8") as fh:
            codex = fh.read()
        self.assertIn("[mcp_servers.boxa-renamed]", codex)
        self.assertNotIn("boxa-echo", codex)
        self.assertIsNone(read_server_secrets(secret_path, "echo"))
        self.assertEqual(
            read_server_secrets(secret_path, "renamed"),
            {"TOKEN": "preserved"},
        )
        with mock.patch.object(
            activation,
            "_codex_git_paths",
            side_effect=AssertionError("cosmetic metadata must not render"),
        ):
            cosmetic = update_entry(
                self.entry["id"], description="display-only", probe=bomb
            )
        self.assertEqual(cosmetic["description"], "display-only")

    def test_runtime_update_preflights_every_project_before_any_write(self):
        for project in self.projects:
            self._activate(project, ["claude"])
        before = self._state(self._all_paths())
        probe = MultiProbe([self.projects[0]])

        with self.assertRaisesRegex(activation.ActivationError, "not running"):
            update_entry(
                self.entry["id"], argv=["/bin/echo", "new"], probe=probe
            )

        self.assertEqual(set(probe.seen), set(self.projects))
        self.assertEqual(self._state(self._all_paths()), before)
        self.assertEqual(
            load_catalog()["entries"][self.entry["id"]]["command"]["argv"],
            ["/bin/echo", "old"],
        )

    def test_successful_runtime_update_publishes_one_state_everywhere(self):
        self._activate(self.projects[0], ["claude"])
        self._activate(self.projects[1], ["codex"])

        updated = update_entry(
            self.entry["id"],
            argv=["/bin/echo", "new"],
            probe=MultiProbe(self.projects),
        )

        self.assertEqual(updated["command"]["argv"], ["/bin/echo", "new"])
        with open(activation.runtime_path(), encoding="utf-8") as fh:
            runtime = json.load(fh)
        self.assertEqual(
            runtime["entries"][self.entry["id"]]["command"]["argv"],
            ["/bin/echo", "new"],
        )
        self.assertEqual(
            set(runtime["projects"]), set(self.projects)
        )

    def test_runtime_snapshot_failure_after_catalog_write_rolls_back_all(self):
        for project in self.projects:
            self._activate(project, ["claude"])
        before = self._state(self._all_paths())
        real_atomic = activation._atomic_json

        def fail_runtime(path, data, mode):
            if path == activation.runtime_path():
                raise OSError("forced runtime snapshot failure")
            return real_atomic(path, data, mode)

        with mock.patch.object(activation, "_atomic_json", side_effect=fail_runtime):
            with self.assertRaisesRegex(OSError, "runtime snapshot"):
                update_entry(
                    self.entry["id"],
                    argv=["/bin/echo", "new"],
                    probe=MultiProbe(self.projects),
                )

        self.assertEqual(self._state(self._all_paths()), before)

    def test_second_project_render_failure_restores_exact_preimages(self):
        store_server_secrets(
            project_secrets_path(self.projects[0]), "echo", {"TOKEN": "exact"}
        )
        for project in self.projects:
            self._activate(project, ["claude", "codex"])
        # Force the first Project render to recreate its local exclude so the
        # failure on Project two proves that side artefact rolls back as well.
        _relative, first_exclude, _codex = activation._codex_git_paths(
            self.projects[0]
        )
        os.unlink(first_exclude)
        before = self._state(self._all_paths())
        real_render = activation._render_codex_activation
        calls = 0

        def fail_second(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("forced second Project render failure")
            return real_render(*args, **kwargs)

        with mock.patch.object(
            activation, "_render_codex_activation", side_effect=fail_second
        ):
            with self.assertRaisesRegex(OSError, "second Project"):
                update_entry(
                    self.entry["id"],
                    name="renamed",
                    argv=["/bin/echo", "new"],
                    probe=MultiProbe(self.projects),
                )

        self.assertEqual(self._state(self._all_paths()), before)

    def test_remove_cascades_activations_preserves_manual_and_recreate_is_new(self):
        secret_path = project_secrets_path(self.projects[0])
        store_server_secrets(secret_path, "echo", {"TOKEN": "destroyed"})
        self._activate(self.projects[0], ["claude"])
        self._activate(self.projects[1], ["codex"])
        claude_path = activation.render_target_path()
        with open(claude_path, encoding="utf-8") as fh:
            claude = json.load(fh)
        claude["projects"][self.projects[0]]["mcpServers"]["manual"] = {
            "command": "keep"
        }
        with open(claude_path, "w", encoding="utf-8") as fh:
            json.dump(claude, fh)
        codex_path = activation.codex_config_path(self.projects[1])
        with open(codex_path, "r+", encoding="utf-8") as fh:
            existing = fh.read()
            fh.seek(0)
            fh.write('model = "keep"\n' + existing)
            fh.truncate()

        removed = activation.remove_catalog_entry(self.entry["id"])

        self.assertEqual(len(removed.affected), 2)
        self.assertNotIn(self.entry["id"], load_catalog()["entries"])
        self.assertEqual(activation.load_activations()["projects"], {})
        with open(claude_path, encoding="utf-8") as fh:
            claude = json.load(fh)
        self.assertEqual(
            claude["projects"][self.projects[0]]["mcpServers"]["manual"],
            {"command": "keep"},
        )
        with open(codex_path, encoding="utf-8") as fh:
            codex = fh.read()
        self.assertEqual(codex.strip(), 'model = "keep"')
        self.assertIsNone(read_server_secrets(secret_path, "echo"))
        recreated = add_entry("echo", ["npx", "new"])
        self.assertNotEqual(recreated["id"], self.entry["id"])
        self.assertEqual(recreated["executionMode"], "service-isolated")

    def test_remove_second_project_failure_restores_identity_and_activations(self):
        for project in self.projects:
            self._activate(project, ["claude", "codex"])
        before = self._state(self._all_paths())
        real_render = activation._render_codex_activation
        calls = 0

        def fail_second(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("forced removal render failure")
            return real_render(*args, **kwargs)

        with mock.patch.object(
            activation, "_render_codex_activation", side_effect=fail_second
        ):
            with self.assertRaisesRegex(OSError, "removal render"):
                activation.remove_catalog_entry(self.entry["id"])

        self.assertEqual(self._state(self._all_paths()), before)
        self.assertIn(self.entry["id"], load_catalog()["entries"])
        records = activation.load_activations()["projects"]
        self.assertTrue(
            all(self.entry["id"] in records[project] for project in self.projects)
        )

    def _deactivated_degraded_entry_with_ack(self):
        entry = add_entry(
            "docker-secret",
            ["docker", "run", "-e", "API_TOKEN", "example/image:1"],
        )
        probe = MultiProbe([self.projects[0]])
        probe.ready = lambda container, candidate: True
        activation.activate(
            entry["id"],
            self.projects[0],
            ["claude"],
            probe,
            accept_degraded_secret_isolation=True,
        )
        activation.deactivate(entry["id"], self.projects[0])
        self.assertTrue(
            activation.load_activations()["acknowledgements"]
            [self.projects[0]][entry["id"]]
        )
        return entry

    def test_remove_without_activation_persists_stale_ack_cleanup_without_render(self):
        entry = self._deactivated_degraded_entry_with_ack()
        claude_before = self._state([activation.render_target_path()])

        with mock.patch.object(
            activation,
            "render_claude_activations",
            side_effect=AssertionError("ack cleanup must not render consumers"),
        ), mock.patch.object(
            activation,
            "_render_codex_activation",
            side_effect=AssertionError("ack cleanup must not render consumers"),
        ):
            activation.remove_catalog_entry(entry["id"])

        stored = activation.load_activations()
        self.assertNotIn(
            entry["id"], stored.get("acknowledgements", {}).get(self.projects[0], {})
        )
        self.assertEqual(self._state([activation.render_target_path()]), claude_before)

    def test_stale_ack_cleanup_runtime_failure_restores_exact_activation_store(self):
        entry = self._deactivated_degraded_entry_with_ack()
        before = self._state(self._all_paths())
        real_atomic = activation._atomic_json

        def fail_runtime(path, data, mode):
            if path == activation.runtime_path():
                raise OSError("forced stale-ack runtime failure")
            return real_atomic(path, data, mode)

        with mock.patch.object(activation, "_atomic_json", side_effect=fail_runtime):
            with self.assertRaisesRegex(OSError, "stale-ack runtime"):
                activation.remove_catalog_entry(entry["id"])

        self.assertEqual(self._state(self._all_paths()), before)
        self.assertIn(entry["id"], load_catalog()["entries"])
        self.assertTrue(
            activation.load_activations()["acknowledgements"]
            [self.projects[0]][entry["id"]]
        )

    def test_replacement_authority_is_not_visible_before_failed_final_commit(self):
        with mock.patch("mcp.catalog._host_mode_command", return_value=True):
            self.entry = set_execution_mode(self.entry["id"], "agent-trusted")
        self._activate(self.projects[0], ["claude"])
        before = self._state(self._all_paths())
        render_entered = threading.Event()
        release_render = threading.Event()
        failures = []

        def pause_then_fail(_activations):
            render_entered.set()
            if not release_render.wait(timeout=5):
                raise AssertionError("test did not release paused late render")
            raise OSError("forced late consumer render failure")

        def mutate():
            try:
                update_entry(
                    self.entry["id"],
                    argv=["/bin/echo", "new"],
                    probe=MultiProbe(self.projects),
                )
            except Exception as exc:  # asserted below
                failures.append(exc)

        with mock.patch.object(
            activation, "render_claude_activations", side_effect=pause_then_fail
        ):
            thread = threading.Thread(target=mutate)
            thread.start()
            try:
                self.assertTrue(render_entered.wait(timeout=5))
                with mock.patch.object(
                    trusted, "RUNTIME_SNAPSHOT_PATH", activation.runtime_path()
                ), mock.patch.object(
                    broker, "project_key", return_value=self.projects[0]
                ), mock.patch.object(broker, "_is_socket", return_value=False):
                    plan = broker._build_agent_trusted_plan(
                        "echo",
                        self.projects[0],
                        self.projects[0],
                        self.entry["id"],
                        "claude",
                    )
                self.assertEqual(plan["argv"], ["/bin/echo", "old"])
                self.assertNotEqual(plan["argv"], ["/bin/echo", "new"])
            finally:
                release_render.set()
                thread.join(timeout=5)

        self.assertFalse(thread.is_alive())
        self.assertEqual(len(failures), 1)
        self.assertRegex(str(failures[0]), "late consumer render")
        self.assertEqual(self._state(self._all_paths()), before)

    def _tracked_codex_config(self, project):
        path = activation.codex_config_path(project)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write('model = "manual"\n')
        subprocess.run(
            ["git", "-C", project, "add", ".codex/config.toml"], check=True
        )
        return path

    def test_tracked_codex_lifecycle_requires_explicit_per_mutation_consent(self):
        tracked_paths = [
            self._tracked_codex_config(project) for project in self.projects
        ]
        for project in self.projects:
            probe = MultiProbe([project])
            probe.ready = lambda container, candidate: True
            activation.activate(
                self.entry["id"],
                project,
                ["codex"],
                probe,
                allow_tracked_codex_config=True,
            )

        # Runtime-only changes do not alter tracked bytes and need no consent.
        update_entry(
            self.entry["id"],
            argv=["/bin/echo", "new"],
            probe=MultiProbe(self.projects),
        )
        before_rename = self._state(self._all_paths())
        with self.assertRaises(activation.ActivationError) as refused:
            update_entry(self.entry["id"], name="renamed")
        for path in tracked_paths:
            self.assertIn(path, str(refused.exception))
        self.assertEqual(self._state(self._all_paths()), before_rename)

        update_entry(
            self.entry["id"],
            name="renamed",
            allow_tracked_codex_config=True,
        )
        before_deactivate = self._state(self._all_paths())
        with self.assertRaisesRegex(
            activation.ActivationError, "allow-tracked-codex-config"
        ):
            activation.deactivate(self.entry["id"], self.projects[0])
        self.assertEqual(self._state(self._all_paths()), before_deactivate)
        activation.deactivate(
            self.entry["id"],
            self.projects[0],
            allow_tracked_codex_config=True,
        )

        before_remove = self._state(self._all_paths())
        with self.assertRaisesRegex(
            activation.ActivationError, "allow-tracked-codex-config"
        ):
            activation.remove_catalog_entry(self.entry["id"])
        self.assertEqual(self._state(self._all_paths()), before_remove)
        activation.remove_catalog_entry(
            self.entry["id"], allow_tracked_codex_config=True
        )

    def test_concurrent_adds_do_not_lose_updates(self):
        errors = []

        def add(name):
            try:
                add_entry(name, ["npx", name])
            except Exception as exc:  # pragma: no cover - asserted below
                errors.append(exc)

        threads = [threading.Thread(target=add, args=(name,)) for name in ("a", "b")]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=5)

        self.assertFalse(errors)
        self.assertFalse(any(thread.is_alive() for thread in threads))
        names = {entry["name"] for entry in load_catalog()["entries"].values()}
        self.assertTrue({"echo", "a", "b"}.issubset(names))

    def test_concurrent_cosmetic_updates_preserve_both_changes(self):
        errors = []

        def mutate(changes):
            try:
                update_entry(self.entry["id"], **changes)
            except Exception as exc:  # pragma: no cover - asserted below
                errors.append(exc)

        threads = [
            threading.Thread(target=mutate, args=({"name": "renamed"},)),
            threading.Thread(
                target=mutate, args=({"description": "cosmetic metadata"},)
            ),
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=5)

        self.assertFalse(errors)
        final = load_catalog()["entries"][self.entry["id"]]
        self.assertEqual(final["name"], "renamed")
        self.assertEqual(final["description"], "cosmetic metadata")


if __name__ == "__main__":
    unittest.main()
