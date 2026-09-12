#!/usr/bin/env python3
"""Release gate for Container-owned Jobs (ADR 0037, boxa-jobs issue 08).

Runs INSIDE a Container, against the real ``boxa-job`` on PATH and the real
per-Project state volume, and writes a Markdown results file. It is an
acceptance run, not a unit test: every scenario drives real processes, real
Codex runs (cheapest model), and the real Codex runtime snapshot path, then
compares the observed Job state with ADR 0037's state table.

    python3 tests/jobs_gate.py short  [--out FILE]
    python3 tests/jobs_gate.py long start   [--hours 2] [--model M]
    python3 tests/jobs_gate.py long attach
    python3 tests/jobs_gate.py long report <jobId> [--out FILE] [--measure K=V]

``short`` runs scenarios 3–6 of issue 08 in well under 15 minutes:

  3. worker crash → orphaned → adopt → finished-unknown; cancel with a
     ``setsid`` escapee; an ``env -i`` child; an inner Docker container
     (the documented limit, observed and recorded, not claimed as owned).
  4. a Codex update between two jobs (the old one keeps running on its copy,
     the new one is probed and published) and an ``npm`` update running
     concurrently with the runtime copy (the copy is discarded, the previous
     verified version stays in use). Scenario 4 runs under the documented
     ``BOXA_JOB_CODEX_*`` seams on a temporary versions root so the shared
     ``boxa-codex-versions`` volume is never polluted with fake versions.
  5. Container restart: cannot be driven from inside; the run reports the
     newest ``interrupted`` record with reason ``container-restart`` if the
     Project has one (issue 06's host proof), otherwise says so.
  6. non-zero exit, tens of MB of stdout, cancel mid-run, duplicate start
     (attach, no second run).

``long`` is scenarios 1–2: ``long start`` starts the two-hour Codex job (a
shell command inside Codex: ``sleep`` then ``sha256sum`` of a fixture) and
prints the key and jobId. Waiting is the waiting agent's job, on purpose:
the gate measures how a frugal wait loop behaves, so the loop is not in this
script. ``long attach`` is what a reconnecting agent runs: it re-issues the
same ``start`` (same key, same prompt) and proves the answer is ``attached``
or ``finished`` with the same jobId, never a second run, then reports the
final result once the Job is finished.

Results go to ``.scratch/boxa-jobs/GATE-<date>.md`` by default (``--out``).
Keys are prefixed ``gate/<stamp>/`` so repeated runs never collide. The
gate's own records stay in the Project (``gc --purge`` cannot target them
alone, so the gate never purges); they are the evidence behind the file.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any, Optional

BOXA_JOB = os.environ.get("BOXA_JOB_BIN", "boxa-job")
PROBE_MODEL = "gpt-5.6-luna"
HOST_PKG = "/run/boxa-codex-host-pkg"
DEFAULT_OUT_DIR = ".scratch/boxa-jobs"

EXIT_OK = 0
EXIT_UNCLEAR = 4
EXIT_REFUSED = 5
EXIT_CONFLICT = 6
EXIT_STILL_RUNNING = 10
EXIT_NEEDS_ACK = 11
TERMINAL_STATES = {"done", "failed", "cancelled", "interrupted", "finished-unknown"}


# ------------------------------------------------------------------ plumbing


class Gate:
    """One gate run: a key prefix, a log, and the verdict table."""

    def __init__(self, out: Optional[str]) -> None:
        self.stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.prefix = f"gate/{self.stamp}/"
        self.rows: list[tuple[str, str, str, str]] = []  # scenario, expected, observed, verdict
        self.notes: list[str] = []
        self.started = time.monotonic()
        self.jobs: list[str] = []
        self.out = out or os.path.join(
            DEFAULT_OUT_DIR, f"GATE-{dt.date.today().isoformat()}.md"
        )

    # ---- running boxa-job

    def run(
        self,
        *args: str,
        env: Optional[dict[str, str]] = None,
        timeout: Optional[float] = None,
        check: bool = False,
    ) -> tuple[int, Any, str]:
        """Run ``boxa-job <args> --json``; returns (rc, parsed stdout or raw, stderr)."""
        argv = [BOXA_JOB, *args]
        if "--json" not in args and args[0] != "log":
            # `log` has no --json; everything else does. Insert it before the
            # `--` separator so it is an option, not part of the Job's argv.
            at = argv.index("--") if "--" in argv else len(argv)
            argv.insert(at, "--json")
        full_env = dict(os.environ)
        if env:
            full_env.update(env)
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            env=full_env,
            timeout=timeout,
            check=False,
        )
        out: Any = proc.stdout
        try:
            out = json.loads(proc.stdout)
        except ValueError:
            pass
        if check and proc.returncode != 0:
            raise RuntimeError(
                f"boxa-job {' '.join(args)} exited {proc.returncode}: "
                f"{proc.stdout.strip()} {proc.stderr.strip()}"
            )
        return proc.returncode, out, proc.stderr

    def start(self, key: str, *argv: str, env: Optional[dict[str, str]] = None,
              extra: tuple[str, ...] = ()) -> dict[str, Any]:
        rc, out, err = self.run(
            "start", "--key", self.prefix + key, *extra, "--", *argv, env=env
        )
        if rc == EXIT_NEEDS_ACK and isinstance(out, dict):
            ids = ",".join(j["jobId"] for j in out.get("concurrent", []))
            self.note(f"`{key}`: needs-ack for {ids}; acked (gate-driven parallelism)")
            rc, out, err = self.run(
                "start", "--key", self.prefix + key, "--ack-concurrent", ids,
                *extra, "--", *argv, env=env,
            )
        if rc != EXIT_OK or not isinstance(out, dict):
            raise RuntimeError(f"start {key} failed rc={rc}: {out} {err}")
        self.jobs.append(out["jobId"])
        return out

    def start_codex(self, key: str, prompt: str, *, model: str = PROBE_MODEL,
                    effort: str = "low", env: Optional[dict[str, str]] = None,
                    ack: Optional[list[str]] = None) -> tuple[int, Any, str]:
        args = ["start", "--key", self.prefix + key, "--codex", "--model", model,
                "--effort", effort]
        if ack:
            args += ["--ack-concurrent", ",".join(ack)]
        args.append(prompt)
        rc, out, err = self.run(*args, env=env)
        if rc == EXIT_NEEDS_ACK and isinstance(out, dict) and not ack:
            ids = [j["jobId"] for j in out.get("concurrent", [])]
            self.note(f"`{key}`: needs-ack for {','.join(ids)}; acked (gate-driven parallelism)")
            return self.start_codex(key, prompt, model=model, effort=effort, env=env, ack=ids)
        if rc == EXIT_OK and isinstance(out, dict) and out.get("jobId"):
            self.jobs.append(out["jobId"])
        return rc, out, err

    def wait(self, job_id: str, timeout: float = 120, env: Optional[dict[str, str]] = None,
             ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while True:
            left = max(1, min(60, int(deadline - time.monotonic())))
            rc, out, err = self.run("wait", job_id, "--timeout", str(left), env=env,
                                    timeout=left + 30)
            if rc != EXIT_STILL_RUNNING:
                if not isinstance(out, dict):
                    raise RuntimeError(f"wait {job_id} rc={rc}: {out} {err}")
                return out
            if time.monotonic() >= deadline:
                raise TimeoutError(f"wait {job_id}: still {out.get('state')} after {timeout}s")

    def result(self, job_id: str, env: Optional[dict[str, str]] = None) -> dict[str, Any]:
        rc, out, err = self.run("result", job_id, env=env)
        if not isinstance(out, dict):
            raise RuntimeError(f"result {job_id} rc={rc}: {out} {err}")
        return out

    def record(self, job_id: str) -> dict[str, Any]:
        res = self.result(job_id)
        with open(res["paths"]["record"], "r", encoding="utf-8") as fh:
            return json.load(fh)

    # ---- reporting

    def verdict(self, scenario: str, expected: str, observed: str, ok: bool) -> None:
        self.rows.append((scenario, expected, observed, "PASS" if ok else "FAIL"))
        flag = "PASS" if ok else "FAIL"
        print(f"[{flag}] {scenario}: {observed}", flush=True)

    def note(self, text: str) -> None:
        self.notes.append(text)
        print(f"       note: {text}", flush=True)

    def write(self, title: str, extra_sections: Optional[list[str]] = None) -> None:
        os.makedirs(os.path.dirname(self.out) or ".", exist_ok=True)
        rc, versions, _ = self.run("runtime", "list")
        codex_version = None
        if isinstance(versions, dict):
            for v in versions.get("versions", []):
                if v.get("inUse") or v.get("current"):
                    codex_version = v.get("version")
        lines = [
            f"# {title}",
            "",
            f"Run `{self.stamp}` inside Container run `{_run_id()}`, "
            f"Project `{os.getcwd()}`, wall clock {time.monotonic() - self.started:.0f} s.",
            f"Codex runtime in use: `{codex_version or 'n/a'}`. "
            f"Script: `tests/jobs_gate.py` (issue 08).",
            "",
            "| Scenario | Expected (ADR 0037) | Observed | Verdict |",
            "| --- | --- | --- | --- |",
        ]
        for scenario, expected, observed, verdict in self.rows:
            lines.append(f"| {scenario} | {expected} | {observed} | {verdict} |")
        if self.notes:
            lines += ["", "## Notes", ""]
            lines += [f"- {n}" for n in self.notes]
        for section in extra_sections or []:
            lines += ["", section]
        failed = [r for r in self.rows if r[3] == "FAIL"]
        lines += ["", f"**{len(self.rows) - len(failed)} PASS, {len(failed)} FAIL.**", ""]
        mode = "a" if os.path.exists(self.out) else "w"
        with open(self.out, mode, encoding="utf-8") as fh:
            if mode == "a":
                fh.write("\n---\n\n")
            fh.write("\n".join(lines))
        print(f"\nresults: {self.out}  ({len(self.rows) - len(failed)} PASS, {len(failed)} FAIL)")

    def cleanup(self) -> None:
        """Cancel this run's stragglers. Records are left in place on purpose.

        `gc --purge` has no per-Job selector, and a "dry-run, then purge"
        pair is not atomic: an unrelated Job finishing in between would be
        purged too. So the gate never purges; its records are evidence and
        the user purges by hand when wanted.
        """
        for job_id in self.jobs:
            res = self.result(job_id)
            if res.get("state") in {"reserved", "running", "orphaned", "exited-with-survivors"}:
                self.run("cancel", job_id)
        self.note(f"{len(self.jobs)} gate records left under `{self.prefix}` "
                  "(the gate never purges; `boxa-job gc --purge` is the user's call).")


def _run_id() -> str:
    try:
        with open("/run/boxa/run-id", "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return "unknown"


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as fh:
            return fh.read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def _pids_with_cmd(fragment: str) -> list[int]:
    found = []
    for name in os.listdir("/proc"):
        if not name.isdigit() or int(name) == os.getpid():
            continue
        try:
            with open(f"/proc/{name}/cmdline", "rb") as fh:
                cmd = fh.read().replace(b"\0", b" ").decode("utf-8", "replace")
        except OSError:
            continue
        if fragment in cmd and _alive(int(name)):
            found.append(int(name))
    return found


def _kill(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass


# ------------------------------------------------------------- scenario 3


def scenario_3(g: Gate) -> None:
    # 3a worker crash → orphaned → adopt → finished-unknown
    started = g.start("crash", "sh", "-c", "sleep 8; echo survived-the-worker")
    job = started["jobId"]
    time.sleep(1)
    rec = g.record(job)
    worker_pid = int(rec["worker"]["pid"])
    cmd_pid = int(rec["command"]["pid"])
    _kill(worker_pid)
    time.sleep(1)
    res = g.result(job)
    orphaned = res["state"] == "orphaned" and _alive(cmd_pid)
    g.verdict("3a worker crash mid-run", "`orphaned`, command tree alive",
              f"state `{res['state']}`, command pid {cmd_pid} alive={_alive(cmd_pid)}", orphaned)
    rc, adopted, err = g.run("adopt", job)
    final = g.wait(job, timeout=60) if rc == EXIT_OK else g.result(job)
    ok = rc == EXIT_OK and final["state"] == "finished-unknown" and final["exitCode"] is None
    stdout_text = ""
    try:
        with open(final["paths"]["stdout"], "r", encoding="utf-8") as fh:
            stdout_text = fh.read().strip()
    except OSError:
        pass
    g.verdict("3a adopt → outcome", "`finished-unknown`, exit code unknown, output kept",
              f"adopt rc={rc}, state `{final['state']}`, exitCode {final['exitCode']}, "
              f"stdout `{stdout_text}`", ok and stdout_text == "survived-the-worker")

    # 3b cancel with a setsid escapee
    marker = f"gate-escapee-{g.stamp}"
    started = g.start("setsid", "bash", "-c",
                      f"setsid bash -c 'exec -a {marker}-escapee sleep 300' & "
                      f"exec -a {marker}-main sleep 300")
    job = started["jobId"]
    time.sleep(1.5)
    before = _pids_with_cmd(marker)
    rc, cancelled, err = g.run("cancel", job)
    time.sleep(1)
    after = _pids_with_cmd(marker)
    res = g.result(job)
    ok = rc == EXIT_OK and res["state"] == "cancelled" and len(before) >= 2 and not after
    g.verdict("3b cancel with `setsid` escapee",
              "`cancelled`; the escapee is killed too (tracked via the subreaper)",
              f"state `{res['state']}`, sleeps before={len(before)} after={len(after)}, "
              f"killed={len((cancelled or {}).get('killed', []))}", ok)
    for pid in after:
        _kill(pid)

    # 3c env -i child (marker wiped) under a live worker
    marker = f"gate-envi-{g.stamp}"
    started = g.start("env-i", "bash", "-c",
                      f"/usr/bin/env -i /bin/bash -c 'exec -a {marker}-child /usr/bin/sleep 300' & "
                      f"exec -a {marker}-main sleep 300")
    job = started["jobId"]
    time.sleep(1.5)
    before = _pids_with_cmd(marker)
    rc, cancelled, err = g.run("cancel", job)
    time.sleep(1)
    after = _pids_with_cmd(marker)
    res = g.result(job)
    ok = rc == EXIT_OK and res["state"] == "cancelled" and len(before) >= 2 and not after
    g.verdict("3c cancel with an `env -i` child",
              "`cancelled`; the marker-less child is killed while the worker lives",
              f"state `{res['state']}`, sleeps before={len(before)} after={len(after)}", ok)
    for pid in after:
        _kill(pid)

    # 3d env -i child whose worker died: the documented limit
    marker = f"gate-envi-orphan-{g.stamp}"
    started = g.start("env-i-orphan", "bash", "-c",
                      f"/usr/bin/env -i /bin/bash -c 'exec -a {marker}-child /usr/bin/sleep 300' & "
                      f"exec -a {marker}-main sleep 300")
    job = started["jobId"]
    time.sleep(1.5)
    rec = g.record(job)
    _kill(int(rec["worker"]["pid"]))
    time.sleep(1)
    rc, cancelled, err = g.run("cancel", job)
    time.sleep(1)
    after = _pids_with_cmd(marker)
    res = g.result(job)
    untrackable = (cancelled or {}).get("untrackable", []) if isinstance(cancelled, dict) else []
    limits = (cancelled or {}).get("limits", []) if isinstance(cancelled, dict) else []
    # The marker-less child may survive: that is the stated limit, and the CLI must say so.
    ok = rc == EXIT_OK and res["state"] == "cancelled" and any("BOXA_JOB_ID" in l for l in limits)
    g.verdict("3d cancel of an orphaned Job with an `env -i` child",
              "`cancelled`; the marker-less child may survive and the CLI states the limit",
              f"state `{res['state']}`, marker-less sleep survivors={len(after)}, "
              f"untrackable={len(untrackable)}, limit stated={any('BOXA_JOB_ID' in l for l in limits)}",
              ok)
    if after:
        g.note(f"3d: the `env -i` child of the crashed worker survived the cancel "
               f"({len(after)} process), exactly the stated limit; killed by the gate.")
    for pid in after:
        _kill(pid)

    # 3e inner Docker container started by a Job (limit documented, not claimed)
    image = _any_local_image()
    if not image:
        g.note("3e: no local image in the rootless Docker daemon, inner-container scenario skipped")
        return
    name = f"gate-inner-{g.stamp.lower()}"
    started = g.start("docker-inner", "sh", "-c",
                      f"docker run --rm --name {name} {image} sleep 300")
    job = started["jobId"]
    deadline = time.monotonic() + 60
    inner_up = False
    while time.monotonic() < deadline:
        if _docker_running(name):
            inner_up = True
            break
        time.sleep(1)
    rc, cancelled, err = g.run("cancel", job)
    time.sleep(2)
    still = _docker_running(name)
    res = g.result(job)
    limits = (cancelled or {}).get("limits", []) if isinstance(cancelled, dict) else []
    ok = inner_up and rc == EXIT_OK and res["state"] == "cancelled" and any("Docker" in l for l in limits)
    g.verdict("3e Job that starts an inner Docker container",
              "`cancelled`; the container is outside the contract and the CLI says so",
              f"inner container seen={inner_up}, state `{res['state']}`, "
              f"container still running after cancel={still}, limit stated="
              f"{any('Docker' in l for l in limits)}", ok)
    g.note(f"3e: inner container `{name}` {'survived' if still else 'did not survive'} the "
           f"cancel (the `docker run` client was killed; the daemon-side container is the "
           f"documented limit). Removed by the gate.")
    subprocess.run(["docker", "rm", "-f", name], capture_output=True, check=False)


def _any_local_image() -> Optional[str]:
    proc = subprocess.run(["docker", "images", "--format", "{{.Repository}}:{{.Tag}}"],
                          capture_output=True, text=True, check=False)
    for line in proc.stdout.splitlines():
        if line and "<none>" not in line:
            return line.strip()
    return None


def _docker_running(name: str) -> bool:
    proc = subprocess.run(["docker", "ps", "--filter", f"name=^{name}$", "--format", "{{.ID}}"],
                          capture_output=True, text=True, check=False)
    return bool(proc.stdout.strip())


# ------------------------------------------------------------- scenario 4


def scenario_4(g: Gate) -> None:
    """Codex update between two jobs; npm update concurrent with the copy."""
    if not os.path.isfile(os.path.join(HOST_PKG, "package.json")):
        g.verdict("4 host Codex package mount present",
                  f"`{HOST_PKG}/package.json` readable (Linux host mount, issue 05)",
                  "absent: runtime-update scenarios could not run (macOS branch is "
                  "deferred work, so the gate fails there by design)", False)
        return
    tmp = tempfile.mkdtemp(prefix="jobs-gate-rt-")
    versions = os.path.join(tmp, "versions")
    npm_pkg = os.path.join(tmp, "npm-pkg")
    os.makedirs(versions)
    shutil.copytree(HOST_PKG, npm_pkg, symlinks=True)
    with open(os.path.join(npm_pkg, "package.json"), "r", encoding="utf-8") as fh:
        base_version = json.load(fh)["version"]
    env = {
        "BOXA_JOB_CODEX_VERSIONS_DIR": versions,
        "BOXA_JOB_CODEX_NPM_PKG_DIR": npm_pkg,
        "BOXA_JOB_CODEX_HOST_PKG_DIR": os.path.join(tmp, "absent"),
    }
    # Numeric bumps: version_key ranks numbers above strings, so a "-gate"
    # suffix would sort below the base version and never be "newer".
    major, minor, patch = base_version.split(".")[:3]
    v1 = base_version
    v2 = f"{major}.{minor}.{int(patch) + 1}"
    v3 = f"{major}.{minor}.{int(patch) + 2}"

    prompt_a = "Run exactly `sleep 40` in the shell and wait for it to finish, then reply with the single word SLEPT and nothing else."
    rc, a, err = g.start_codex("codex-a", prompt_a, env=env)
    if rc != EXIT_OK:
        g.verdict("4a first Codex job probes the current version", "started on a verified copy",
                  f"rc={rc} {a} {err.strip()}", False)
        shutil.rmtree(tmp, ignore_errors=True)
        return
    rc_l, listed, _ = g.run("runtime", "list", env=env)
    rows = {v["version"]: v for v in listed.get("versions", [])} if isinstance(listed, dict) else {}
    v1_row = rows.get(v1, {})
    # `runtimeProbed` on the start output is true only for the call that ran
    # the probe; a `needs-ack` refusal already refreshes, so judge by the
    # published marker instead (verified + probedAt), which is what matters.
    ok = a.get("codexVersion") == v1 \
        and a.get("codexBinary", "").startswith(os.path.join(versions, v1) + os.sep) \
        and bool(v1_row.get("verified")) and v1_row.get("probedAt") is not None
    g.verdict("4a first Codex job probes and publishes the current version",
              f"`{v1}` verified with a probe, job runs from `<versions>/{v1}/`",
              f"version `{a.get('codexVersion')}`, source `{a.get('runtimeSource')}`, "
              f"verified={bool(v1_row.get('verified'))} probed={v1_row.get('probedAt') is not None}",
              ok)

    # "npm update" between jobs: bump the package version, same binary.
    _set_version(npm_pkg, v2)
    prompt_b = "Reply with the single word UPDATED and nothing else."
    rc, b, err = g.start_codex("codex-b", prompt_b, env=env)
    rc_l, listed, _ = g.run("runtime", "list", env=env)
    rows = {v["version"]: v for v in listed.get("versions", [])} if isinstance(listed, dict) else {}
    v2_row = rows.get(v2, {})
    ok_b = rc == EXIT_OK and isinstance(b, dict) and b.get("codexVersion") == v2 \
        and bool(v2_row.get("verified")) and v2_row.get("probedAt") is not None
    g.verdict("4b Codex update between two jobs: the new job probes the new version",
              f"second job runs from `<versions>/{v2}/` (probed, verified), first keeps `{v1}`",
              f"rc={rc}, version `{b.get('codexVersion') if isinstance(b, dict) else b}`, "
              f"`{v2}` verified={bool(v2_row.get('verified'))} probed={v2_row.get('probedAt') is not None}",
              ok_b)
    if isinstance(b, dict) and b.get("runtimeProbed") is False:
        g.note("4b: the runtime refresh runs before the concurrency check, so the `needs-ack` "
               "refusal of the first start had already copied and probed the new version; "
               "the acked retry took the fast path (`runtimeProbed: false`). One probe per "
               "version either way, but a refused start pays it.")
    fb = g.wait(b["jobId"], timeout=240, env=env) if ok_b else None
    fa = g.wait(a["jobId"], timeout=240, env=env)
    a_bin = fa.get("codex", {}).get("codexBinary", "")
    ok_a = fa["state"] == "done" and a_bin.startswith(os.path.join(versions, v1) + os.sep) \
        and fa.get("codex", {}).get("finalMessage", "").strip() == "SLEPT"
    g.verdict("4b the old job finished on its own copy",
              f"`done`, binary still under `{v1}/`, final message SLEPT",
              f"state `{fa['state']}`, binary under `{os.path.relpath(a_bin, versions).split(os.sep)[0] if a_bin else '?'}/`, "
              f"message `{fa.get('codex', {}).get('finalMessage')}`", ok_a)
    if fb is not None:
        g.verdict("4b the new job finished on the new copy",
                  f"`done`, binary under `{v2}/`",
                  f"state `{fb['state']}`, message `{fb.get('codex', {}).get('finalMessage')}`",
                  fb["state"] == "done")

    # npm update concurrent with the copy: keep rewriting a file in the source
    # package while the snapshot of v3 runs, so the before/after manifest differs.
    _set_version(npm_pkg, v3)
    churn_path = os.path.join(npm_pkg, "bin", "codex.js")
    churn = subprocess.Popen(
        ["sh", "-c", f'end=$(( $(date +%s) + 25 )); while [ $(date +%s) -lt $end ]; do '
                     f'echo "// churn $(date +%s%N)" >> "{churn_path}"; sleep 0.05; done'],
    )
    try:
        rc, refreshed, err = g.run("runtime", "refresh", env=env, timeout=300)
    finally:
        churn.terminate()
        churn.wait()
    rc_l, listed, _ = g.run("runtime", "list", env=env)
    published = {v["version"]: v for v in listed.get("versions", [])} if isinstance(listed, dict) else {}
    v3_verified = bool(published.get(v3, {}).get("verified"))
    warnings = refreshed.get("warnings", []) if isinstance(refreshed, dict) else []
    in_use = next((v["version"] for v in published.values() if v.get("inUse")), None)
    ok = not v3_verified and in_use == v2 and bool(warnings)
    g.verdict("4c `npm` update concurrent with the runtime copy",
              f"copy of `{v3}` discarded, `{v2}` stays in use, loud warning",
              f"`{v3}` verified={v3_verified}, in use `{in_use}`, warnings={len(warnings)}", ok)
    if warnings:
        g.note(f"4c warning text: {warnings[0]}")
    leftovers = [n for n in os.listdir(versions) if n.startswith(".snapshot")]
    g.verdict("4c no snapshot temp dir leaked", "no `.snapshot-*` under the versions root",
              f"leftovers={leftovers}", not leftovers)
    shutil.rmtree(tmp, ignore_errors=True)


def _set_version(pkg_dir: str, version: str) -> None:
    path = os.path.join(pkg_dir, "package.json")
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    data["version"] = version
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)


# ------------------------------------------------------------- scenario 5


def scenario_5(g: Gate) -> None:
    rc, listed, _ = g.run("list")
    interrupted = [j for j in (listed.get("jobs", []) if isinstance(listed, dict) else [])
                   if j.get("state") == "interrupted"]
    if not interrupted:
        g.note("5: Container restart cannot be driven from inside; no `interrupted` record in this "
               "Project. Host proof: issue 06 comments (stop + start → `interrupted`, "
               "reason `container-restart`).")
        return
    newest = sorted(interrupted, key=lambda j: j["jobId"])[-1]
    res = g.result(newest["jobId"])
    ok = res.get("interruptedReason") == "container-restart"
    g.verdict("5 Container restart mid-run (record found in this Project)",
              "`interrupted`, reason `container-restart`, never resumed",
              f"job {newest['jobId']} state `{res['state']}`, reason `{res.get('interruptedReason')}`", ok)


# ------------------------------------------------------------- scenario 6


def scenario_6(g: Gate) -> None:
    started = g.start("exit3", "sh", "-c", "echo bad >&2; exit 3")
    res = g.wait(started["jobId"], timeout=30)
    g.verdict("6a non-zero exit", "`failed`, exit code 3",
              f"state `{res['state']}`, exitCode {res['exitCode']}",
              res["state"] == "failed" and res["exitCode"] == 3)

    mb = 30
    started = g.start("big-stdout", "sh", "-c",
                      f"head -c {mb * 1024 * 1024} /dev/zero | tr '\\0' x; echo; echo LAST-LINE")
    res = g.wait(started["jobId"], timeout=120)
    size = os.path.getsize(res["paths"]["stdout"]) if os.path.exists(res["paths"]["stdout"]) else 0
    rc, tail, _ = g.run("log", started["jobId"], "--tail", "1")
    ok = res["state"] == "done" and size >= mb * 1024 * 1024 and "LAST-LINE" in str(tail)
    g.verdict(f"6b large stdout ({mb} MB)", "`done`, full stdout on disk, `log --tail` answers",
              f"state `{res['state']}`, stdout {size / 1024 / 1024:.1f} MB, tail ok={'LAST-LINE' in str(tail)}", ok)

    started = g.start("cancel-mid", "sh", "-c", "sleep 300")
    time.sleep(1)
    rc, cancelled, _ = g.run("cancel", started["jobId"])
    res = g.result(started["jobId"])
    g.verdict("6c cancel mid-run", "`cancelled` (never `failed`); signal exit recorded",
              f"state `{res['state']}`, exitCode {res['exitCode']}",
              rc == EXIT_OK and res["state"] == "cancelled")

    # duplicate start (scenario 2 in the short form)
    started = g.start("dup", "sh", "-c", "sleep 6")
    again = g.start("dup", "sh", "-c", "sleep 6")
    ok = again["jobId"] == started["jobId"] and again.get("result") == "attached"
    g.verdict("6d/2 duplicate start with the same key and request",
              "`attached` to the same jobId, no second run",
              f"result `{again.get('result')}`, same id={again['jobId'] == started['jobId']}", ok)
    rc, conflict, err = g.run("start", "--key", g.prefix + "dup", "--", "sh", "-c", "sleep 7")
    g.verdict("6d same key, different request", "`conflict`, exit 6",
              f"rc={rc}, result `{conflict.get('result') if isinstance(conflict, dict) else conflict}`",
              rc == EXIT_CONFLICT)
    g.wait(started["jobId"], timeout=30)


# ---------------------------------------------------------------- long run


LONG_KEY = "gate/long/two-hour"
LONG_PARAMS = os.path.join(".scratch", "tmp", "jobs-gate-long.json")
FIXTURE = os.path.join(".scratch", "tmp", "jobs-gate-fixture.bin")


def long_prompt(seconds: int, fixture: str) -> str:
    return (
        "This is an acceptance run of long-command handling. Run exactly this one shell "
        f"command in the foreground and wait for it to finish, however long it takes: "
        f"`sleep {seconds} && sha256sum {fixture}`. Do not background it, do not shorten "
        "the sleep, do not poll. When it has finished, reply with the sha256 hex digest only."
    )


def _long_argv(hours: float, model: str, fresh: bool) -> list[str]:
    fixture = os.path.abspath(FIXTURE)
    argv = [BOXA_JOB, "start", "--key", LONG_KEY, "--codex", "--model", model,
            "--effort", "low", "--json"]
    if fresh:
        argv.append("--fresh")
    argv.append(long_prompt(int(hours * 3600), fixture))
    return argv


def _load_long_params() -> Optional[dict[str, Any]]:
    try:
        with open(LONG_PARAMS, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def long_start(args: argparse.Namespace) -> int:
    """Start a NEW two-hour Job. A finished Job under the key is never reused."""
    fixture = os.path.abspath(FIXTURE)
    # Refuse before touching the fixture: a still-running long Job hashes it
    # at its end, and rewriting it under that Job would corrupt that run.
    listed = json.loads(subprocess.run([BOXA_JOB, "list", "--json"], capture_output=True,
                                       text=True, check=False).stdout or "{}")
    unfinished = [j for j in listed.get("jobs", []) if j.get("key") == LONG_KEY
                  and j.get("state") not in TERMINAL_STATES]
    if unfinished:
        print(f"long start: {unfinished[0]['jobId']} under {LONG_KEY} is still "
              f"`{unfinished[0]['state']}`; wait for it or `boxa-job cancel` it first",
              file=sys.stderr)
        return 1
    os.makedirs(os.path.dirname(fixture), exist_ok=True)
    with open(fixture, "wb") as fh:  # fresh bytes: a stale digest cannot pass
        fh.write(os.urandom(1024 * 1024))
    proc = subprocess.run(_long_argv(args.hours, args.model, fresh=True),
                          capture_output=True, text=True, check=False)
    print(proc.stdout.strip())
    if proc.stderr.strip():
        print(proc.stderr.strip(), file=sys.stderr)
    if proc.returncode != 0:
        print("long start: not started (an unfinished Job under the key? `boxa-job list`, "
              "then `cancel` it or wait)", file=sys.stderr)
        return 1
    out = json.loads(proc.stdout)
    if out.get("result") != "started":
        print(f"long start: expected a new run, got `{out.get('result')}` for "
              f"{out.get('jobId')}; refusing to report on an old Job", file=sys.stderr)
        return 1
    expect = subprocess.run(["sha256sum", fixture], capture_output=True, text=True,
                            check=False).stdout.split()[0]
    params = {"jobId": out["jobId"], "hours": args.hours, "model": args.model,
              "expectedDigest": expect, "startedAt": time.time()}
    with open(LONG_PARAMS, "w", encoding="utf-8") as fh:
        json.dump(params, fh, indent=2)
    print(f"key: {LONG_KEY}\njobId: {out['jobId']}\nexpected digest: {expect}\n"
          f"parameters: {LONG_PARAMS}\nreconnect with: python3 tests/jobs_gate.py long attach")
    return 0


def long_attach(args: argparse.Namespace) -> int:
    """What a reconnecting agent runs: same start, must attach, never a second Job."""
    params = _load_long_params()
    if not params:
        print(f"long attach: no {LONG_PARAMS}; run `long start` first", file=sys.stderr)
        return 1
    proc = subprocess.run(_long_argv(params["hours"], params["model"], fresh=False),
                          capture_output=True, text=True, check=False)
    try:
        out = json.loads(proc.stdout)
    except ValueError:
        print(proc.stdout, proc.stderr)
        return 1
    print(json.dumps({k: out.get(k) for k in ("jobId", "result", "state")}))
    if out.get("result") not in {"attached", "finished"} or out.get("jobId") != params["jobId"]:
        print(f"UNEXPECTED: reconnect did not attach to {params['jobId']}: "
              f"{out.get('result')} {out.get('jobId')}", file=sys.stderr)
        return 1
    return 0


def long_report(args: argparse.Namespace) -> int:
    """Judge the finished long Job against ADR 0037 and write its section.

    Exit 1 on any failed check: a report is a verdict, not a transcript.
    """
    proc = subprocess.run([BOXA_JOB, "result", args.job_id, "--json"], capture_output=True,
                          text=True, check=False)
    try:
        res = json.loads(proc.stdout)
    except ValueError:
        print(f"result {args.job_id}: {proc.stdout} {proc.stderr}", file=sys.stderr)
        return 1
    params = _load_long_params() or {}
    hours = args.hours if args.hours is not None else float(params.get("hours", 2.0))
    listed = json.loads(subprocess.run([BOXA_JOB, "list", "--json"], capture_output=True,
                                       text=True, check=False).stdout)
    # `--fresh` keeps earlier finished records under the key, so only Jobs
    # from this run onwards count (ids are UTC-stamped and sort with time).
    same_key = [j for j in listed.get("jobs", []) if j.get("key") == LONG_KEY
                and str(j.get("jobId")) >= str(params.get("jobId", ""))]
    expect = params.get("expectedDigest") or "?"
    codex = res.get("codex", {}) or {}
    final = (codex.get("finalMessage") or "").strip()
    duration = float(res.get("durationSeconds") or 0)
    checks = [
        ("the reported Job is the one `long start` recorded",
         f"reported `{res.get('jobId')}`, recorded `{params.get('jobId')}`",
         bool(params) and res.get("jobId") == params.get("jobId")),
        ("state `done`, exit 0, terminal event `turn.completed`",
         f"`{res.get('state')}`, exit {res.get('exitCode')}, `{codex.get('terminalEvent')}`",
         res.get("state") == "done" and res.get("exitCode") == 0
         and codex.get("terminalEvent") == "turn.completed"),
        ("exactly one Job under the key since `long start` (no second run from wait expiry or reconnect)",
         f"{len(same_key)} Job(s): {', '.join(j['jobId'] for j in same_key)}",
         len(same_key) == 1 and same_key[0]["jobId"] == res.get("jobId")),
        (f"ran at least {hours:.2f} h (the sleep was not shortened)",
         f"{duration / 60:.1f} min", duration >= hours * 3600),
        ("final message is the fixture's sha256",
         f"expected `{expect}`, got `{final[:80]}`", expect != "?" and expect in final),
    ]
    lines = [
        "## Long run (scenarios 1–2)",
        "",
        f"Job `{res.get('jobId')}`, key `{LONG_KEY}`, model `{codex.get('requestedModel')}` "
        f"effort `{codex.get('requestedEffort')}`, Codex `{codex.get('codexVersion')}`.",
        "",
        "| Check | Observed | Verdict |",
        "| --- | --- | --- |",
    ]
    for expected, observed, ok in checks:
        lines.append(f"| {expected} | {observed} | {'PASS' if ok else 'FAIL'} |")
    lines += [
        "",
        "| Baseline | Value |",
        "| --- | --- |",
        f"| Codex usage | {json.dumps(codex.get('usage'))} |",
        f"| item counts | {json.dumps(codex.get('itemCounts'))} |",
    ]
    for extra in args.measure or []:
        k, _, v = extra.partition("=")
        lines.append(f"| {k} | {v} |")
    failed = [c for c in checks if not c[2]]
    lines += ["", f"**{len(checks) - len(failed)} PASS, {len(failed)} FAIL.**", ""]
    out = args.out or os.path.join(DEFAULT_OUT_DIR, f"GATE-{dt.date.today().isoformat()}.md")
    with open(out, "a", encoding="utf-8") as fh:
        fh.write("\n---\n\n" + "\n".join(lines))
    print("\n".join(lines))
    return 0 if not failed else 1


# --------------------------------------------------------------------- main


def run_short(args: argparse.Namespace) -> int:
    g = Gate(args.out)
    print(f"gate {g.stamp}: keys under `{g.prefix}`, results → {g.out}", flush=True)
    for scenario in (scenario_3, scenario_4, scenario_5, scenario_6):
        try:
            scenario(g)
        except Exception as exc:  # a crashed scenario is a FAIL row, not a lost run
            g.verdict(f"{scenario.__name__} crashed", "scenario completes", f"{type(exc).__name__}: {exc}", False)
    g.write("Jobs release gate: short scenarios (3–6)")
    g.cleanup()
    return 0 if all(r[3] == "PASS" for r in g.rows) else 1


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="mode", required=True)
    short = sub.add_parser("short", help="scenarios 3–6, under 15 minutes")
    short.add_argument("--out")
    short.set_defaults(func=run_short)
    long_ = sub.add_parser("long", help="scenarios 1–2, the two-hour Codex job")
    long_sub = long_.add_subparsers(dest="action", required=True)
    for name, func in (("start", long_start), ("attach", long_attach)):
        p = long_sub.add_parser(name)
        p.add_argument("--hours", type=float, default=2.0)
        p.add_argument("--model", default=PROBE_MODEL)
        p.set_defaults(func=func)
    rep = long_sub.add_parser("report")
    rep.add_argument("job_id")
    rep.add_argument("--hours", type=float, default=None,
                     help="override the --hours recorded by `long start` (duration check)")
    rep.add_argument("--out")
    rep.add_argument("--measure", action="append", metavar="KEY=VALUE",
                     help="waiting-agent measurements to record (wait calls, output bytes, ...)")
    rep.set_defaults(func=long_report)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
