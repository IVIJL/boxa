#!/usr/bin/env python3
"""Unit tests for the evidence-based MCP candidate classifier (issue 04).

Run with:

    python3 -m unittest tests.test_mcp_classify   # from repo root
    python3 tests/test_mcp_classify.py            # standalone

Covers the issue-04 acceptance criteria:
  * context7-style npx server with no host indicators -> container/high;
  * task-master-ai-style npx server with env -> container, surfacing required
    and secret env key NAMES (never values);
  * host path / Windows path / WSL2 path -> host-only (not container);
  * desktop / browser / clipboard indicators -> host-only;
  * Claude hosted/remote connector -> excluded (preserved from provider);
  * placement and confidence are separate, drawn from the allowed vocabularies;
  * the JSON envelope carries the structured classification fields.
"""

from __future__ import annotations

import json
import os
import sys
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "scripts"))

from mcp import (  # noqa: E402
    Candidate,
    Classification,
    Command,
    classify,
    import_result,
)
from mcp.candidate import CONFIDENCES, PLACEMENTS  # noqa: E402


def _candidate(
    argv=None,
    env_keys=None,
    secret_env_keys=None,
    classification=None,
    name="srv",
    type=None,
):
    return Candidate(
        provider="claude-code",
        source_path="/home/u/.claude/.claude.json",
        source_scope="global",
        name=name,
        type=type,
        command=Command(
            argv=list(argv or []),
            env_keys=list(env_keys or []),
            secret_env_keys=list(secret_env_keys or []),
        ),
        classification=classification or Classification(placement="unknown"),
    )


class ContainerCandidateTest(unittest.TestCase):
    def test_context7_npx_no_env_is_container_high(self) -> None:
        cand = _candidate(
            argv=["npx", "-y", "@upstash/context7-mcp@latest"],
            name="context7",
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "container")
        self.assertEqual(cls.confidence, "high")
        self.assertTrue(cls.reasons)

    def test_uvx_no_env_is_container_high(self) -> None:
        cand = _candidate(argv=["uvx", "some-python-mcp"], name="py")
        cls = classify(cand)
        self.assertEqual(cls.placement, "container")
        self.assertEqual(cls.confidence, "high")

    def test_docker_launcher_is_container(self) -> None:
        cand = _candidate(
            argv=["docker", "run", "-i", "--rm", "ghcr.io/example/mcp"],
            name="dock",
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "container")

    def test_url_option_is_not_host_path(self) -> None:
        # A URL passed as `--url=https://...` must NOT be mistaken for a host
        # path just because its `//authority` tail starts with a slash.
        for argv in (
            ["npx", "some-mcp", "--url=https://api.example.com"],
            ["npx", "some-mcp", "https://api.example.com/v1"],
        ):
            cls = classify(_candidate(argv=argv))
            self.assertEqual(cls.placement, "container", argv)

    def test_relative_path_is_not_host_only(self) -> None:
        cls = classify(_candidate(argv=["npx", "some-mcp", "./data"]))
        self.assertEqual(cls.placement, "container")

    def test_versioned_python_launcher_is_container(self) -> None:
        # Common versioned interpreters (python3.11, /usr/bin/python3.12) are
        # recognized container-friendly launchers (codex P2).
        for argv in (
            ["python3.11", "-m", "some_mcp"],
            ["/usr/bin/python3.12", "-m", "some_mcp"],
            ["python3.13", "server.py"],
        ):
            cls = classify(_candidate(argv=argv))
            self.assertEqual(cls.placement, "container", argv)

    def test_absolute_interpreter_path_is_not_host_only(self) -> None:
        # An absolute path to the LAUNCHER (argv[0]) is normal and resolves in
        # the Container; it must not be treated as a host-only argument.
        cand = _candidate(argv=["/usr/bin/python3", "-m", "some_mcp"], name="p")
        cls = classify(cand)
        self.assertEqual(cls.placement, "container")


class TaskMasterEnvTest(unittest.TestCase):
    def test_task_master_ai_surfaces_env_key_names(self) -> None:
        cand = _candidate(
            argv=["npx", "-y", "--package=task-master-ai", "task-master-ai"],
            env_keys=["ANTHROPIC_API_KEY", "LOG_LEVEL"],
            secret_env_keys=["ANTHROPIC_API_KEY"],
            name="task-master-ai",
        )
        cls = classify(cand)
        # Still a container candidate (npx), but env-gated -> medium confidence.
        self.assertEqual(cls.placement, "container")
        self.assertEqual(cls.confidence, "medium")
        reasons_blob = " ".join(cls.reasons)
        # Required env key NAMES surfaced.
        self.assertIn("ANTHROPIC_API_KEY", reasons_blob)
        self.assertIn("LOG_LEVEL", reasons_blob)
        # Secret key called out separately.
        self.assertTrue(any("secret" in r.lower() for r in cls.reasons))

    def test_env_values_never_appear_in_reasons(self) -> None:
        # The model has no values, but assert the reasons carry only NAMES.
        cand = _candidate(
            argv=["npx", "task-master-ai"],
            env_keys=["ANTHROPIC_API_KEY"],
            secret_env_keys=["ANTHROPIC_API_KEY"],
        )
        cls = classify(cand)
        blob = json.dumps(cls.to_dict())
        self.assertIn("ANTHROPIC_API_KEY", blob)
        self.assertNotIn("sk-", blob)


class HostOnlyTest(unittest.TestCase):
    def test_absolute_host_path_arg_is_host_only(self) -> None:
        cand = _candidate(
            argv=["npx", "fs-mcp", "/home/alice/private/data"],
            name="fs",
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "host-only")
        self.assertNotEqual(cls.placement, "container")
        self.assertEqual(cls.confidence, "medium")

    def test_windows_drive_path_is_host_only(self) -> None:
        cand = _candidate(
            argv=["npx", "fs-mcp", "C:\\Users\\alice\\data"], name="win"
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "host-only")
        self.assertEqual(cls.confidence, "high")

    def test_wsl_mount_path_is_host_only(self) -> None:
        cand = _candidate(
            argv=["npx", "fs-mcp", "/mnt/c/Users/alice"], name="wsl"
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "host-only")
        self.assertEqual(cls.confidence, "high")

    def test_windows_exe_launcher_is_host_only(self) -> None:
        cand = _candidate(argv=["powershell.exe", "-c", "Get-Item"], name="ps")
        cls = classify(cand)
        self.assertEqual(cls.placement, "host-only")

    def test_clipboard_indicator_is_host_only(self) -> None:
        cand = _candidate(argv=["npx", "clipboard-mcp"], name="clip")
        cls = classify(cand)
        self.assertEqual(cls.placement, "host-only")
        self.assertNotEqual(cls.placement, "container")

    def test_browser_tools_is_host_only(self) -> None:
        cand = _candidate(
            argv=["npx", "@agentdeskai/browser-tools-mcp@latest"],
            name="browser-tools",
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "host-only")
        self.assertNotEqual(cls.placement, "container")

    def test_playwright_is_host_only(self) -> None:
        cand = _candidate(argv=["npx", "playwright-mcp"], name="pw")
        cls = classify(cand)
        self.assertEqual(cls.placement, "host-only")

    def test_inline_option_host_path_is_host_only(self) -> None:
        # `--root=/home/alice/data` embeds a host path in the option value;
        # the whole-token check would miss it and fall through to container.
        cand = _candidate(
            argv=["npx", "fs-mcp", "--root=/home/alice/data"], name="inl"
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "host-only")
        self.assertNotEqual(cls.placement, "container")

    def test_docker_bind_mount_host_path_is_host_only(self) -> None:
        cand = _candidate(
            argv=[
                "docker",
                "run",
                "--mount=type=bind,src=/home/alice:/data",
                "img",
            ],
            name="bind",
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "host-only")

    def test_inline_option_windows_path_is_host_only(self) -> None:
        cand = _candidate(
            argv=["npx", "fs-mcp", "--path=C:\\Users\\alice"], name="winopt"
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "host-only")
        self.assertEqual(cls.confidence, "high")

    def test_container_internal_abs_path_is_not_host_only(self) -> None:
        # Absolute paths under the boxa-mapped roots (/workspace WORKDIR,
        # /home/node agent home) resolve to the same content inside the
        # Container and must not be host-only (codex P2).
        for argv in (
            ["docker", "run", "-w", "/workspace", "img"],
            ["npx", "fs", "/workspace/sub"],
            ["npx", "fs", "/home/node/.cache"],
        ):
            cls = classify(_candidate(argv=argv))
            self.assertEqual(cls.placement, "container", argv)

    def test_unmapped_generic_root_is_host_only(self) -> None:
        # /app, /src, /code are not a boxa mount convention — a host path
        # under them may be absent or different in the Container, so it must be
        # host-only/manual-confirm rather than silently importable (codex P2).
        for argv in (
            ["npx", "fs-mcp", "/app/secrets"],
            ["npx", "fs-mcp", "/src/data"],
            ["npx", "fs-mcp", "/code/config"],
        ):
            cls = classify(_candidate(argv=argv))
            self.assertEqual(cls.placement, "host-only", argv)

    def test_system_root_data_path_is_host_only(self) -> None:
        # /tmp, /etc, /opt exist in the Container too but with DIFFERENT content
        # than the host, so a server reading host data under them must be
        # host-only/manual-confirm, not silently container (codex P2).
        for argv in (
            ["npx", "fs-mcp", "/tmp/data"],
            ["docker", "run", "-v", "/opt/tool:/tool", "img"],
            ["npx", "fs-mcp", "/etc/myapp/conf"],
        ):
            cls = classify(_candidate(argv=argv))
            self.assertEqual(cls.placement, "host-only", argv)

    def test_absolute_host_launcher_is_host_only(self) -> None:
        # A container-friendly basename behind an absolute HOST launcher path
        # (homebrew, ~/.local/bin) likely does not exist in the Container
        # (codex P2).
        for argv in (
            ["/opt/homebrew/bin/npx", "-y", "context7"],
            ["/home/alice/.local/bin/uvx", "some-mcp"],
        ):
            cls = classify(_candidate(argv=argv))
            self.assertEqual(cls.placement, "host-only", argv)

    def test_project_local_launcher_is_container(self) -> None:
        # An absolute launcher UNDER the mounted Project (a project venv or
        # node_modules binary) is visible in the Container and stays importable
        # (codex P2) — same project-root exemption the argument check uses.
        for cmd in (
            "/home/alice/app/.venv/bin/python",
            "/home/alice/app/node_modules/.bin/server",
        ):
            cand = Candidate(
                provider="claude-code",
                source_path="/home/alice/.claude/.claude.json",
                source_scope="project",
                source_project="/home/alice/app",
                name="srv",
                command=Command(argv=[cmd, "-m", "x"]),
            )
            cls = classify(cand)
            self.assertEqual(cls.placement, "container", cmd)

    def test_workspace_launcher_is_container(self) -> None:
        cand = _candidate(argv=["/workspace/.venv/bin/python", "-m", "x"])
        cls = classify(cand)
        self.assertEqual(cls.placement, "container")

    def test_standard_bin_launcher_is_container(self) -> None:
        # A standard system bin path resolves to the same interpreter inside
        # the Container.
        for argv in (
            ["/usr/bin/python3", "-m", "some_mcp"],
            ["/usr/local/bin/npx", "context7"],
        ):
            cls = classify(_candidate(argv=argv))
            self.assertEqual(cls.placement, "container", argv)

    def test_path_under_mounted_project_is_not_host_only(self) -> None:
        # A path inside the candidate's own mounted Project is container-visible
        # and must stay importable (codex P2), even though it is an absolute
        # host path syntactically.
        cand = Candidate(
            provider="claude-code",
            source_path="/home/alice/.claude/.claude.json",
            source_scope="project",
            source_project="/home/alice/app",
            name="fs",
            command=Command(argv=["npx", "fs-mcp", "/home/alice/app/docs"]),
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "container")

    def test_path_outside_mounted_project_is_host_only(self) -> None:
        # A path OUTSIDE the project root is still host-only.
        cand = Candidate(
            provider="claude-code",
            source_path="/home/alice/.claude/.claude.json",
            source_scope="project",
            source_project="/home/alice/app",
            name="fs",
            command=Command(argv=["npx", "fs-mcp", "/home/alice/other-secrets"]),
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "host-only")

    def test_named_volume_destination_is_not_host_only(self) -> None:
        # A docker named-volume mount `cache:/data` has a container-side
        # destination; the source is a volume name, not a host path.
        cls = classify(_candidate(argv=["docker", "run", "-v", "cache:/data", "img"]))
        self.assertEqual(cls.placement, "container")

    def test_bind_mount_source_host_path_is_host_only(self) -> None:
        # The SOURCE side of a bind mount is a real host path -> host-only.
        cls = classify(
            _candidate(argv=["docker", "run", "-v", "/home/alice:/data", "img"])
        )
        self.assertEqual(cls.placement, "host-only")

    def test_attached_short_option_host_path_is_host_only(self) -> None:
        # Attached short-option forms (`-v/host/path`, `-C/host/path`) glue the
        # path onto the flag with no separator; it must still be detected
        # (codex P2).
        for argv in (
            ["docker", "run", "-v/home/alice:/data", "img"],
            ["npx", "tool", "-C/home/alice"],
        ):
            cls = classify(_candidate(argv=argv))
            self.assertEqual(cls.placement, "host-only", argv)

    def test_host_credential_socket_env_is_host_only(self) -> None:
        # A server depending on a host SSH agent / credential socket / docker
        # host is host-only — that resource is not shared into the Container
        # (codex P2).
        for env in (["SSH_AUTH_SOCK"], ["DOCKER_HOST"], ["GPG_AGENT_INFO"]):
            cls = classify(_candidate(argv=["npx", "git-mcp"], env_keys=env))
            self.assertEqual(cls.placement, "host-only", env)

    def test_display_env_is_host_only(self) -> None:
        cand = _candidate(
            argv=["npx", "gui-mcp"], env_keys=["DISPLAY"], name="gui"
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "host-only")
        self.assertEqual(cls.confidence, "medium")


class ExcludedTest(unittest.TestCase):
    def test_remote_connector_excluded_is_preserved(self) -> None:
        cand = _candidate(
            classification=Classification(
                placement="excluded",
                confidence="high",
                reasons=["Claude hosted/remote connector (type=http)"],
            ),
            name="gmail-connector",
            type="http",
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "excluded")
        self.assertEqual(cls.confidence, "high")
        self.assertTrue(cls.reasons)


class UnknownTest(unittest.TestCase):
    def test_unknown_command_family_is_unknown_low(self) -> None:
        cand = _candidate(argv=["some-random-binary", "--serve"], name="rng")
        cls = classify(cand)
        self.assertEqual(cls.placement, "unknown")
        self.assertEqual(cls.confidence, "low")

    def test_unknown_basename_in_standard_bin_is_unknown(self) -> None:
        # An absolute launcher under /usr/bin whose basename is NOT a known
        # runtime (e.g. /usr/bin/custom-mcp) is not assumed to exist in the
        # Container — it falls through to unknown/manual-confirm (codex P2),
        # unlike /usr/bin/python3 which is a known family.
        cls = classify(_candidate(argv=["/usr/bin/custom-mcp", "--serve"]))
        self.assertEqual(cls.placement, "unknown")

    def test_no_command_is_unknown(self) -> None:
        cand = _candidate(argv=[], name="empty")
        cls = classify(cand)
        self.assertEqual(cls.placement, "unknown")


class VocabularyTest(unittest.TestCase):
    def test_placement_and_confidence_drawn_from_allowed_sets(self) -> None:
        samples = [
            _candidate(argv=["npx", "context7"]),
            _candidate(argv=["npx", "x", "/home/a/b"]),
            _candidate(argv=["clipboard-mcp"]),
            _candidate(argv=["weird-bin"]),
        ]
        for cand in samples:
            cls = classify(cand)
            self.assertIn(cls.placement, PLACEMENTS)
            self.assertIn(cls.confidence, CONFIDENCES)

    def test_placement_and_confidence_are_independent_fields(self) -> None:
        # An npx server with env is container PLACEMENT but only MEDIUM
        # confidence — proving the two axes are decoupled.
        cand = _candidate(
            argv=["npx", "task-master-ai"], env_keys=["ANTHROPIC_API_KEY"]
        )
        cls = classify(cand)
        self.assertEqual(cls.placement, "container")
        self.assertEqual(cls.confidence, "medium")

    def test_classify_does_not_mutate_candidate(self) -> None:
        cand = _candidate(argv=["npx", "context7"])
        before = cand.classification
        classify(cand)
        self.assertIs(cand.classification, before)


class JsonEnvelopeTest(unittest.TestCase):
    def test_import_json_carries_classification_fields(self) -> None:
        from mcp import classify_candidate

        cand = classify_candidate(
            _candidate(
                argv=["npx", "task-master-ai"],
                env_keys=["ANTHROPIC_API_KEY"],
                secret_env_keys=["ANTHROPIC_API_KEY"],
            )
        )
        env = import_result([cand])
        entry = env["candidates"][0]
        self.assertIn("classification", entry)
        cls = entry["classification"]
        self.assertEqual(set(cls.keys()), {"placement", "confidence", "reasons"})
        self.assertEqual(cls["placement"], "container")
        self.assertEqual(cls["confidence"], "medium")
        self.assertTrue(cls["reasons"])


class InheritedTableTest(unittest.TestCase):
    """The list --inherited table must preserve merge provenance (codex P2)."""

    def _render(self, candidates):
        import io
        import contextlib

        from mcp import classify_candidate
        from mcp.cli import _render_inherited_table
        from mcp.merge import merge_candidates

        for c in candidates:
            classify_candidate(c)
        merged = merge_candidates(candidates)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            _render_inherited_table(merged)
        return buf.getvalue()

    def test_conflict_is_marked_in_status(self) -> None:
        # Same name+scope, different specs -> a merge conflict that the table
        # must surface, not hide behind two identical-looking rows.
        a = _candidate(argv=["npx", "ctx", "--mode=a"], name="dup")
        b = _candidate(argv=["npx", "ctx", "--mode=b"], name="dup")
        out = self._render([a, b])
        self.assertIn("(conflict)", out)

    def _render_import(self, candidates):
        import io
        import contextlib

        from mcp import classify_candidate
        from mcp.cli import _render_text
        from mcp.merge import merge_candidates

        for c in candidates:
            classify_candidate(c)
        merged = merge_candidates(candidates)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            _render_text(merged)
        return buf.getvalue()

    def test_import_summary_counts_only_container_as_importable(self) -> None:
        # v1 supports Container MCP only — host-only/unknown must not be
        # reported as importable (codex P2).
        out = self._render_import(
            [
                _candidate(argv=["npx", "context7"], name="ctr"),
                _candidate(argv=["npx", "fs", "/home/a/x"], name="hostp"),
                _candidate(argv=["weird-bin"], name="unk"),
            ]
        )
        self.assertIn("1 importable (container)", out)
        self.assertIn("1 host-only", out)
        self.assertIn("1 unknown", out)

    def test_all_merged_sources_shown(self) -> None:
        # The same logical server discovered by two providers must show both
        # provider config paths, not just the first.
        a = Candidate(
            provider="claude-code",
            source_path="/home/u/.claude/.claude.json",
            source_scope="global",
            name="context7",
            command=Command(argv=["npx", "-y", "@upstash/context7-mcp@latest"]),
        )
        b = Candidate(
            provider="codex",
            source_path="/home/u/.codex/config.toml",
            source_scope="global",
            name="context7",
            command=Command(argv=["npx", "-y", "@upstash/context7-mcp@latest"]),
        )
        out = self._render([a, b])
        self.assertIn("/home/u/.claude/.claude.json", out)
        self.assertIn("/home/u/.codex/config.toml", out)
        self.assertIn("claude-code", out)
        self.assertIn("codex", out)


if __name__ == "__main__":
    unittest.main()
