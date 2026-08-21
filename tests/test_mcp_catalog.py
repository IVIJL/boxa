"""ADR 0021 issue 01: host-owned MCP catalog with stable identity."""

from __future__ import annotations

import io
import json
import os
import stat
import sys
import tempfile
import unittest
import uuid
from contextlib import redirect_stderr, redirect_stdout

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_ROOT, "scripts"))

from mcp import cli  # noqa: E402
from mcp.catalog import (  # noqa: E402
    CATALOG_VERSION,
    CatalogError,
    add_entry,
    add_remote_entry,
    catalog_path,
    entries_sorted,
    load_catalog,
    remove_entry,
    update_entry,
)
from mcp.profile import global_profile_path, save_profile  # noqa: E402


class CatalogTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.old_env = {key: os.environ.get(key) for key in ("HOME", "XDG_CONFIG_HOME")}
        os.environ["HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "xdg")

    def tearDown(self) -> None:
        for key, value in self.old_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_fresh_catalog_is_empty_and_does_not_write(self) -> None:
        self.assertEqual(load_catalog(), {"version": CATALOG_VERSION, "entries": {}})
        self.assertFalse(os.path.exists(catalog_path()))

    def test_add_round_trips_secret_free_launch_data_and_modes(self) -> None:
        fixed = uuid.UUID("8f5832c6-6445-40cb-99ab-aa84442f57f2")
        entry = add_entry(
            "github",
            [
                "docker", "run", "--rm", "-e", "LOG_LEVEL=debug",
                "-e", "GITHUB_TOKEN", "ghcr.io/example/mcp",
            ],
            id_factory=lambda: fixed,
        )
        self.assertEqual(entry["id"], str(fixed))
        self.assertEqual(entry["executionMode"], "service-isolated")
        self.assertEqual(entry["runtimeKind"], "docker")
        self.assertEqual(entry["readiness"], {"summary": "requires-project"})
        self.assertEqual(entry["command"]["argv"][0:2], ["docker", "run"])
        self.assertEqual(entry["env"], {"LOG_LEVEL": "debug"})
        self.assertEqual(entry["secretEnvKeys"], ["GITHUB_TOKEN"])
        with open(catalog_path(), encoding="utf-8") as fh:
            raw = fh.read()
        self.assertNotIn("ghp_", raw)
        self.assertEqual(load_catalog()["entries"][str(fixed)], entry)
        self.assertEqual(stat.S_IMODE(os.stat(catalog_path()).st_mode), 0o600)
        self.assertEqual(
            stat.S_IMODE(os.stat(os.path.dirname(catalog_path())).st_mode), 0o755
        )

    def test_rename_and_definition_update_preserve_identity(self) -> None:
        original = add_entry("old", ["npx", "old-package"])
        renamed = update_entry(original["id"], name="new")
        updated = update_entry("new", argv=["uvx", "new-package"])
        self.assertEqual(renamed["id"], original["id"])
        self.assertEqual(updated["id"], original["id"])
        self.assertEqual(updated["executionMode"], "service-isolated")
        self.assertEqual(updated["runtimeKind"], "python")

    def test_delete_and_same_name_recreate_gets_new_identity(self) -> None:
        first = add_entry("server", ["npx", "one"])
        removed = remove_entry("server")
        second = add_entry("server", ["npx", "two"])
        self.assertEqual(removed["id"], first["id"])
        self.assertNotEqual(second["id"], first["id"])

    def test_malformed_catalog_is_reported_and_never_overwritten(self) -> None:
        os.makedirs(os.path.dirname(catalog_path()), exist_ok=True)
        malformed = b'{"version":2,"entries":['
        with open(catalog_path(), "wb") as fh:
            fh.write(malformed)
        with self.assertRaises(CatalogError):
            add_entry("server", ["npx", "one"])
        with open(catalog_path(), "rb") as fh:
            self.assertEqual(fh.read(), malformed)

    def test_catalog_rejects_os_invalid_command_and_environment_strings(self) -> None:
        base = add_entry("server", ["npx", "one"])
        with open(catalog_path(), encoding="utf-8") as fh:
            clean = json.load(fh)
        mutations = (
            ("empty argv token", lambda entry: entry["command"].update(argv=["npx", ""])),
            ("NUL argv token", lambda entry: entry["command"].update(argv=["npx", "bad\0value"])),
            ("invalid env key", lambda entry: entry.update(envKeys=["BAD=KEY"])),
            ("empty env key", lambda entry: entry.update(envKeys=[""])),
            ("NUL env value", lambda entry: entry.update(env={"SAFE_KEY": "secret-value\0tail"}, envKeys=["SAFE_KEY"])),
        )
        for label, mutate in mutations:
            data = json.loads(json.dumps(clean))
            mutate(data["entries"][base["id"]])
            with open(catalog_path(), "w", encoding="utf-8") as fh:
                json.dump(data, fh)
            with self.subTest(label=label):
                with self.assertRaisesRegex(CatalogError, "malformed catalog") as ctx:
                    load_catalog()
            self.assertNotIn("secret-value", str(ctx.exception))

    def test_catalog_order_is_deterministic(self) -> None:
        add_entry("Zulu", ["npx", "z"])
        add_entry("alpha", ["npx", "a"])
        self.assertEqual([e["name"] for e in entries_sorted()], ["alpha", "Zulu"])

    def test_http_entry_requires_url_and_forbids_local_runtime_fields(self) -> None:
        entry = add_remote_entry("dozzle", "https://dozzle.example.test/mcp")
        self.assertEqual(
            set(entry), {"id", "name", "type", "url", "readiness"}
        )
        self.assertEqual(entry["readiness"]["summary"], "no-runtime-readiness")
        with self.assertRaisesRegex(CatalogError, "valid HTTP"):
            add_remote_entry("bad", "ftp://example.test/mcp")
        with self.assertRaisesRegex(CatalogError, "command argv"):
            update_entry(entry["id"], argv=["echo"])

    def test_http_entry_rejects_credential_like_query_and_fragment_keys(self) -> None:
        urls = (
            "https://example.test/mcp?token=secret",
            "https://example.test/mcp?apiKey=secret",
            "https://example.test/mcp?auth=secret",
            "https://example.test/mcp?authToken=secret",
            "https://example.test/mcp?auth_token=secret",
            "https://example.test/mcp?authorization=Bearer%20secret",
            "https://example.test/mcp?value=sk-ant-api03-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
            "https://example.test/mcp?header=Bearer%20sk-ant-api03-XXXXXXXXXXXXXXXXXXXX",
            "https://example.test/mcp#access_token=secret",
            "https://example.test/mcp#Authorization=secret",
        )
        for index, url in enumerate(urls):
            with self.subTest(url=url):
                with self.assertRaisesRegex(CatalogError, "valid HTTP"):
                    add_remote_entry(f"remote-{index}", url)

        benign_url = (
            "https://example.test/mcp?timeout=10&locale=sk-SK&monkey=1"
            "&author=smith&authority=x#section"
        )
        entry = add_remote_entry("benign", benign_url)
        self.assertEqual(entry["url"], benign_url)

    def test_http_entry_url_update_preserves_remote_shape(self) -> None:
        entry = add_remote_entry("remote", "https://one.example/mcp")
        updated = update_entry(entry["id"], url="https://two.example/mcp")
        self.assertEqual(updated["url"], "https://two.example/mcp")
        self.assertNotIn("executionMode", updated)

    def test_catalog_does_not_touch_legacy_profile(self) -> None:
        profile = {"version": 1, "servers": {"legacy": {"name": "legacy"}}}
        save_profile(global_profile_path(), profile)
        with open(global_profile_path(), "rb") as fh:
            before = fh.read()
        add_entry("new", ["npx", "new"])
        with open(global_profile_path(), "rb") as fh:
            self.assertEqual(fh.read(), before)

    def test_cli_add_catalog_and_list_json(self) -> None:
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            rc = cli.main(["catalog-add-json", "context7", "--", "npx", "ctx"])
        self.assertEqual(rc, 0, stderr.getvalue())
        added = json.loads(stdout.getvalue())["entry"]
        stdout = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            rc = cli.main(["catalog-json"])
        self.assertEqual(rc, 0, stderr.getvalue())
        listed = json.loads(stdout.getvalue())["entries"]
        expected = dict(added)
        expected["isolationStatus"] = "isolated"
        self.assertEqual(listed, [expected])

    def test_cli_add_and_update_remote_url(self) -> None:
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            rc = cli.main(
                [
                    "catalog-add-json",
                    "dozzle",
                    "--url",
                    "https://one.example/mcp",
                ]
            )
        self.assertEqual(rc, 0, stderr.getvalue())
        entry = json.loads(stdout.getvalue())["entry"]
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            rc = cli.main(
                [
                    "catalog-update-json",
                    entry["id"],
                    "--url",
                    "https://two.example/mcp",
                ]
            )
        self.assertEqual(rc, 0, stderr.getvalue())
        self.assertEqual(
            json.loads(stdout.getvalue())["entry"]["url"],
            "https://two.example/mcp",
        )


if __name__ == "__main__":
    unittest.main()
