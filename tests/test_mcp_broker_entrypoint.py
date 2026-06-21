"""Structural checks for the broker's entrypoint + Dockerfile wiring.

The runtime UID-boundary properties (the broker holding only boxa-mcp's
groups, node failing `kill -0` against the broker, /proc/<pid>/environ being
unreadable cross-UID) are CONTAINER-RUNTIME-ONLY: they require a live container
and cannot be exercised from a unit test here. This module instead verifies, by
construction, that the source wiring that PRODUCES those properties is present
and correct, so the host validation has a precise contract to confirm:

  * the entrypoint starts the broker as boxa-mcp with the FULL credential
    reset (--reuid + --regid + --init-groups), BEFORE the node drop, in the
    root phase;
  * the broker is backgrounded (always-on) and runs the boxa-mcp-broker
    launcher;
  * the Dockerfile creates an unprivileged boxa-mcp account with its own HOME
    and npm/npx cache, creates the Container-internal boxa-bridge group with
    both node and boxa-mcp as members (the broker-socket bridge, replacing the
    old node ∈ boxa-mcp cross-membership), and grants boxa-mcp NO sudo;
  * ADR 0003 invariants: no NOPASSWD sudoers entry is introduced for the broker.
"""

from __future__ import annotations

import os
import re
import stat
import subprocess
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTRYPOINT = os.path.join(REPO_ROOT, "scripts", "boxa-entrypoint.sh")
NAMESPACE = os.path.join(REPO_ROOT, "scripts", "mcp-broker-namespace.sh")
DOCKERFILE = os.path.join(REPO_ROOT, "Dockerfile")
DOCKER_RUN = os.path.join(REPO_ROOT, "docker-run.sh")


def _read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


class EntrypointBrokerTests(unittest.TestCase):
    def setUp(self):
        self.text = _read(ENTRYPOINT)
        # The broker-launch internals (credential drop + clean boxa-mcp env)
        # were hoisted into the namespace wrapper (issue 21) so they run INSIDE
        # the per-broker mount namespace; assertions about them read it.
        self.ns_text = _read(NAMESPACE)

    def test_broker_started_before_node_drop(self):
        # The broker launch (now via the namespace wrapper) must come before the
        # node drop in the entrypoint root phase.
        broker_idx = self.text.find("mcp-broker-namespace")
        node_drop_idx = self.text.find("--reuid=node")
        self.assertNotEqual(broker_idx, -1, "broker namespace launch missing")
        self.assertNotEqual(node_drop_idx, -1, "node drop missing")
        self.assertLess(
            broker_idx, node_drop_idx, "broker must start before the node drop"
        )

    def test_broker_full_credential_reset(self):
        # The broker's setpriv must reset uid AND gid AND init-groups, not just
        # uid — otherwise it retains root's groups (ADR 0014). This now lives in
        # the namespace wrapper, which execs the drop inside the namespace.
        m = re.search(
            r"setpriv\s+--reuid=boxa-mcp\s+--regid=boxa-mcp\s+--init-groups",
            self.ns_text,
        )
        self.assertIsNotNone(
            m, "broker setpriv must use --reuid + --regid + --init-groups"
        )

    def test_broker_is_backgrounded(self):
        # The broker is always-on; the namespace wrapper that launches it must be
        # backgrounded so the entrypoint proceeds to the node exec.
        self.assertRegex(
            self.text,
            r"/usr/local/bin/mcp-broker-namespace\s*&",
        )

    def test_node_drop_is_exec(self):
        # PID 1 still becomes node via exec setpriv (no residual root parent).
        self.assertIn(
            "exec setpriv --reuid=node --regid=node --init-groups", self.text
        )

    def test_socket_dir_on_neutral_bridge_path(self):
        # The broker socket dir lives on the NEUTRAL boxa-bridge path (ADR 0014
        # issue 19), owned boxa-mcp:boxa-bridge mode 2770 (setgid) — NOT
        # inside the 0700 boxa-mcp secret dir. node reaches it via the
        # boxa-bridge group; the setgid bit makes the socket inherit that group.
        self.assertRegex(
            self.text,
            r"install -d -o boxa-mcp -g boxa-bridge -m 2770 /run/boxa-bridge",
        )

    def test_boxa_mcp_runtime_root_is_owner_only(self):
        # The boxa-mcp runtime root holds secrets + the gated profile mount and
        # must stay 0700 OWNER-only — node never traverses it (the bridge socket
        # moved out to /run/boxa-bridge), so no group access here.
        self.assertRegex(
            self.text,
            r"install -d -o boxa-mcp -g boxa-mcp -m 0700 /run/boxa-mcp\b",
        )

    def test_broker_launched_with_clean_boxa_mcp_env(self):
        # The broker (and the servers it spawns) must run with boxa-mcp's own
        # HOME / npm cache, not root's inherited environment, so npx servers can
        # write their cache. `env -i` resets the environment before setting it.
        # This launch now lives in the namespace wrapper (issue 21).
        self.assertIn("env -i", self.ns_text)
        self.assertRegex(self.ns_text, r"HOME=/home/boxa-mcp")
        self.assertRegex(self.ns_text, r"npm_config_cache=/home/boxa-mcp/\.npm")

    def test_broker_reads_profile_from_gated_mount(self):
        # XDG_CONFIG_HOME must point at the GATED host MCP store mount (ADR 0014
        # issue 16) so mcp.profile.config_root() (XDG + /boxa/mcp) reads the
        # live, secret-free profile through the boxa-mcp-only 0700 parent —
        # never node's own config tree. Set in the namespace wrapper's launch.
        self.assertRegex(self.ns_text, r"XDG_CONFIG_HOME=/run/boxa-mcp/host")

    def test_host_store_parent_chain_gated_0700_boxa_mcp(self):
        # The mount-point parents docker creates root:root 0755 must be re-owned
        # boxa-mcp 0700 so node cannot traverse to the 0600 secret files.
        self.assertRegex(
            self.text, r"chown boxa-mcp:boxa-mcp /run/boxa-mcp/host\b"
        )
        self.assertRegex(self.text, r"chmod 0700 /run/boxa-mcp/host\b")
        self.assertRegex(
            self.text,
            r"chown boxa-mcp:boxa-mcp /run/boxa-mcp/host/boxa\b",
        )

    def test_secrets_staged_root_side_before_node_drop(self):
        # The reusable staging step runs in the root phase, before the node drop.
        stage_idx = self.text.find("stage-mcp-secrets")
        node_drop_idx = self.text.find("--reuid=node")
        self.assertNotEqual(stage_idx, -1, "staging step missing from entrypoint")
        self.assertLess(
            stage_idx, node_drop_idx, "secrets must be staged before the node drop"
        )

    def test_private_staged_secret_dir_is_0700_boxa_mcp(self):
        # Secret VALUES come from a boxa-mcp-private 0700 dir node cannot
        # traverse — never from the node-owned profile mount.
        self.assertRegex(
            self.text,
            r"install -d -o boxa-mcp -g boxa-mcp -m 0700 "
            r"/run/boxa-mcp/secrets",
        )
        # The broker is POINTED at that dir via BOXA_MCP_SECRETS_DIR in its
        # launch env, which lives in the namespace wrapper (issue 21).
        self.assertRegex(
            self.ns_text, r"BOXA_MCP_SECRETS_DIR=/run/boxa-mcp/secrets"
        )

    def test_identity_records_full_project_key(self):
        # The identity file must carry projectKey (the full host path) so the
        # broker can bind Project scope to exactly this Container.
        self.assertIn("projectKey", self.text)
        self.assertIn("BOXA_PROJECT_HOST_PATH", self.text)

    def test_broker_wrapped_in_private_mount_namespace(self):
        # ADR 0014 issue 21: the broker runs inside its OWN mount namespace
        # (`unshare --mount --propagation private`) so the workspace can be
        # idmap-remounted rw for boxa-mcp without touching node's view.
        self.assertRegex(
            self.text,
            r"unshare --mount --propagation private",
        )
        # The namespace wrapper (which holds the idmap remount + the credential
        # drop) is what unshare runs.
        self.assertRegex(
            self.text,
            r"unshare --mount --propagation private\s+\\\s*"
            r"-- /usr/local/bin/mcp-broker-namespace",
        )

    def test_broker_namespace_is_backgrounded(self):
        # The broker (now via the namespace wrapper) is still always-on /
        # backgrounded so the script proceeds to the node exec.
        self.assertRegex(
            self.text,
            r"/usr/local/bin/mcp-broker-namespace\s*&",
        )

    def test_socket_dir_created_before_unshare(self):
        # ORDERING IS LOAD-BEARING (issue 21): the /run/boxa-bridge socket dir
        # must be created BEFORE the unshare, so the socket the broker creates in
        # the inherited /run tmpfs stays visible/connectable from node's main
        # namespace and the setgid dir still forces the bridge group/mode.
        socket_dir_idx = self.text.find(
            "install -d -o boxa-mcp -g boxa-bridge -m 2770 /run/boxa-bridge"
        )
        unshare_idx = self.text.find("unshare --mount --propagation private")
        self.assertNotEqual(socket_dir_idx, -1, "socket dir setup missing")
        self.assertNotEqual(unshare_idx, -1, "unshare missing")
        self.assertLess(
            socket_dir_idx,
            unshare_idx,
            "the bridge socket dir must be created before the unshare",
        )

    def test_secret_dirs_created_before_unshare(self):
        # The /run/boxa-mcp secret/profile dirs (on inherited tmpfs) are also
        # created before the unshare so they survive into the broker namespace.
        secret_dir_idx = self.text.find(
            "install -d -o boxa-mcp -g boxa-mcp -m 0700 /run/boxa-mcp/secrets"
        )
        unshare_idx = self.text.find("unshare --mount --propagation private")
        self.assertNotEqual(secret_dir_idx, -1, "secret dir setup missing")
        self.assertLess(
            secret_dir_idx,
            unshare_idx,
            "the secret dirs must be created before the unshare",
        )

    def test_run_is_not_remounted(self):
        # The namespace must NEVER remount /run, or the inherited sockets/secret
        # tmpfs would be shadowed and the relay could not reach the broker. Guard
        # the namespace wrapper (where mounts happen), matching a real `mount`
        # COMMAND (line-leading, not the word "mounts" in prose) targeting /run.
        self.assertNotRegex(
            self.ns_text, r"(?m)^\s*mount\b[^\n]*\s/run(/|\b)"
        )


class DockerfileAccountTests(unittest.TestCase):
    def setUp(self):
        self.text = _read(DOCKERFILE)

    def test_boxa_mcp_account_created_unprivileged(self):
        self.assertIn("groupadd --system boxa-mcp", self.text)
        self.assertRegex(
            self.text,
            r"useradd --system --gid boxa-mcp --create-home",
        )

    def test_boxa_mcp_has_own_home_and_npm_cache(self):
        self.assertIn("/home/boxa-mcp/.npm", self.text)
        self.assertIn("--home-dir /home/boxa-mcp", self.text)

    def test_node_not_in_boxa_mcp_group(self):
        # ADR 0014 (2026-05-31, issue 19): the node ∈ boxa-mcp cross-membership
        # is REMOVED. node and boxa-mcp meet only at the bridge, never in each
        # other's primary group.
        self.assertNotRegex(self.text, r"usermod -aG boxa-mcp node")

    def test_bridge_group_created_with_both_members(self):
        # The Container-internal boxa-bridge group is created in the image with
        # BOTH node and boxa-mcp as members — the only thing they share. It is
        # never created on the host (the sockets live in /run).
        self.assertIn("groupadd --system boxa-bridge", self.text)
        self.assertIn("usermod -aG boxa-bridge node", self.text)
        self.assertIn("usermod -aG boxa-bridge boxa-mcp", self.text)

    def test_boxa_mcp_not_granted_sudo(self):
        # The only `usermod -aG sudo` in the image is for node (firewall
        # password sudo); boxa-mcp must never be added to sudo.
        self.assertNotRegex(self.text, r"usermod -aG sudo[^\n]*boxa-mcp")
        self.assertNotRegex(self.text, r"boxa-mcp[^\n]*-aG sudo")

    def test_no_nopasswd_sudoers_for_broker(self):
        # ADR 0003: no NOPASSWD sudoers entries are introduced.
        self.assertNotIn("NOPASSWD", self.text)

    def test_broker_launcher_shipped_and_executable(self):
        self.assertIn(
            "COPY scripts/mcp-broker.sh /usr/local/bin/boxa-mcp-broker", self.text
        )
        self.assertIn("/usr/local/bin/boxa-mcp-broker", self.text)

    def test_mcp_runtime_readable_by_boxa_mcp(self):
        # The shared MCP package must be readable+executable by boxa-mcp.
        self.assertRegex(
            self.text, r"chmod -R a\+rX /usr/local/share/boxa/mcp"
        )

    def test_staging_script_shipped_and_executable(self):
        # The reusable secret-staging step (issue 16) ships on PATH as root.
        self.assertIn(
            "COPY scripts/stage-mcp-secrets.sh /usr/local/bin/stage-mcp-secrets",
            self.text,
        )
        self.assertIn("/usr/local/bin/stage-mcp-secrets", self.text)

    def test_broker_namespace_wrapper_shipped_and_executable(self):
        # ADR 0014 issue 21: the mount-namespace wrapper (idmap remount +
        # credential drop) ships on PATH and is chmod +x.
        self.assertIn(
            "COPY scripts/mcp-broker-namespace.sh "
            "/usr/local/bin/mcp-broker-namespace",
            self.text,
        )
        self.assertIn("/usr/local/bin/mcp-broker-namespace", self.text)

    def test_util_linux_installed_for_unshare_mount_setpriv(self):
        # The broker namespace needs util-linux unshare/mount/setpriv. It is
        # listed explicitly so the dependency survives a slimmer base image.
        self.assertIn("util-linux", self.text)


class DockerRunMountTests(unittest.TestCase):
    def setUp(self):
        self.text = _read(DOCKER_RUN)

    def test_host_mcp_store_mounted_read_only_under_gated_path(self):
        # The host MCP store reaches the Container read-only under the root/
        # boxa-mcp-gated path the entrypoint re-owns (ADR 0014 issue 16), NOT a
        # node-readable path.
        self.assertRegex(
            self.text,
            r'\$BOXA_MCP_HOST_STORE:/run/boxa-mcp/host/boxa/mcp:ro',
        )
        self.assertRegex(
            self.text, r'BOXA_MCP_HOST_STORE="\$HOME/\.config/boxa/mcp"'
        )

    def test_host_mcp_store_created_and_mounted_unconditionally(self):
        # The host store is created up front and mounted UNCONDITIONALLY so a
        # server imported into a RUNNING Container is visible to the broker on
        # the next session without a restart (ADR 0014). A conditional mount
        # would leave a Container started before any import with no live mount.
        self.assertRegex(self.text, r'mkdir -p "\$BOXA_MCP_HOST_STORE"')
        self.assertNotRegex(self.text, r'if \[ -d "\$BOXA_MCP_HOST_STORE" \]')

    def test_existing_store_normalized_broker_readable_before_mount(self):
        # save_profile() only fixes NEWLY written profiles; an existing store
        # from an older version (0700/0600) or one created under a restrictive
        # host umask must be normalized broker-readable BEFORE the mount (issue
        # 16). The dir + projects/ subdir are made traversable (o+rx) and
        # non-secret profile files readable (o+r).
        self.assertRegex(self.text, r'chmod o\+rx "\$BOXA_MCP_HOST_STORE"')
        self.assertRegex(
            self.text, r'chmod o\+rx "\$BOXA_MCP_HOST_STORE/projects"'
        )
        self.assertRegex(self.text, r"chmod o\+r ")
        # The normalization runs before the bind-mount line.
        norm_idx = self.text.find('chmod o+rx "$BOXA_MCP_HOST_STORE"')
        mount_idx = self.text.find(
            "$BOXA_MCP_HOST_STORE:/run/boxa-mcp/host/boxa/mcp:ro"
        )
        self.assertNotEqual(norm_idx, -1)
        self.assertNotEqual(mount_idx, -1)
        self.assertLess(norm_idx, mount_idx)

    def test_secret_files_excluded_from_profile_chmod(self):
        # *.secrets.json carry credentials and MUST stay 0600 — the find that
        # selects non-secret profile files for o+r must prune them explicitly.
        self.assertRegex(self.text, r"!\s+-name '\*\.secrets\.json'")


class DockerRunStorePermLogicTests(unittest.TestCase):
    """Functional regression of the store-perm normalization algorithm.

    Re-runs the exact find/chmod logic from docker-run.sh against a temp store
    to lock in the contract: dir + projects -> 0755-traversable, profile.json +
    projects/*.json -> world-readable, while secrets.json (global) and
    *.secrets.json (project) stay 0600.
    """

    def _normalize(self, store):
        # Mirror of the docker-run.sh host-side normalization (issue 16).
        script = r"""
set -e
STORE="$1"
chmod o+rx "$STORE" 2>/dev/null || true
if [ -d "$STORE/projects" ]; then
    chmod o+rx "$STORE/projects" 2>/dev/null || true
fi
while IFS= read -r -d '' f; do
    chmod o+r "$f" 2>/dev/null || true
done < <(find "$STORE" -maxdepth 2 -type f \
    \( -name 'profile.json' -o \( -path "$STORE/projects/*.json" -a ! -name '*.secrets.json' \) \) \
    -print0 2>/dev/null)
"""
        subprocess.run(
            ["bash", "-c", script, "bash", store],
            check=True,
        )

    def _mode(self, path):
        return stat.S_IMODE(os.stat(path).st_mode)

    def test_normalizes_only_non_secret_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = os.path.join(tmp, "mcp")
            projects = os.path.join(store, "projects")
            os.makedirs(projects)
            profile = os.path.join(store, "profile.json")
            global_secrets = os.path.join(store, "secrets.json")
            proj_profile = os.path.join(projects, "api-abc.json")
            proj_secrets = os.path.join(projects, "api-abc.secrets.json")
            for p in (profile, global_secrets, proj_profile, proj_secrets):
                with open(p, "w", encoding="utf-8") as fh:
                    fh.write("{}")
            os.chmod(store, 0o700)
            os.chmod(projects, 0o700)
            for p in (profile, global_secrets, proj_profile, proj_secrets):
                os.chmod(p, 0o600)

            self._normalize(store)

            # Dirs traversable+readable by others.
            self.assertTrue(self._mode(store) & 0o005)
            self.assertTrue(self._mode(projects) & 0o005)
            # Non-secret profile files world-readable.
            self.assertTrue(self._mode(profile) & 0o004)
            self.assertTrue(self._mode(proj_profile) & 0o004)
            # Secret files UNTOUCHED at 0600.
            self.assertEqual(self._mode(global_secrets), 0o600)
            self.assertEqual(self._mode(proj_secrets), 0o600)

    def test_fresh_and_idempotent_no_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = os.path.join(tmp, "mcp")
            os.makedirs(store)  # fresh: no projects/, no files
            self._normalize(store)  # must not error
            self._normalize(store)  # idempotent


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
