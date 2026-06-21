"""Record a brand-new Boxa MCP server from a command spec (ADR 0013, issue 13).

``boxa mcp add <name> -- <command spec>`` is distinct from the two other
write paths:

  * ``import``  discovers an INHERITED server already configured in a host agent
    and copies its env values out of that source config;
  * ``install`` MATERIALIZES an existing profile entry into persistent runtime;
  * ``add``     records an EXPLICIT new server straight from a generic command
    spec the user typed (``npx``, ``uvx``, ``docker run``, or an absolute
    binary). It has no source agent config to re-read — the env values, if any,
    are supplied inline on the spec (``-e KEY=VALUE`` / ``--env KEY=VALUE`` for a
    Docker spec) and travel in memory only.

Reuse, not reinvention: the spec is run through the SAME classifier
(:func:`mcp.classify.classify_candidate`) as import, so placement
(``container`` / ``host-only`` / ``unknown``) and the secret-name heuristics are
identical. A host-only / unknown / excluded spec is refused with the same
``not_applicable_reason`` text the apply path uses. The chosen scope is written
through the same profile + scoped secret store the apply path uses — this module
performs the write directly (it cannot call ``apply_candidate``, which re-reads a
source config that ``add`` does not have) but lands the exact same on-disk shape.

Secret-safety: the model carries env NAMES only. Inline secret VALUES are held
in memory, written 0600 to the scoped secret store, and never logged, printed,
or placed in the (secret-free) profile or the stored argv. A secret value passed
inline on a Docker ``-e SECRET=value`` token is redacted out of the argv before
the argv is persisted, so the profile never carries the literal credential.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Any, Optional

from .apply import (
    ScopeOverride,
    is_applicable,
    not_applicable_reason,
)
from .candidate import Candidate, Command
from .classify import classify_candidate
from .merge import MergedCandidate, compute_import_id
from .profile import build_server_entry, load_profile, profile_path, save_profile
from .providers.claude import (
    _REDACTED,
    _contains_embedded_secret,
    _is_secret_env_name,
    _looks_like_secret_value,
    _redact_argv,
)
from .secrets import (
    read_server_secrets,
    restore_server_secrets,
    secrets_path,
    store_server_secrets,
)
from .source_values import _value_looks_secret

# Provider label recorded on an added server's profile entry. Distinguishes a
# server the user added explicitly from one imported out of a host agent
# ("claude-code" / "codex"), so `list` / `doctor` can show its provenance.
ADD_PROVIDER = "boxa-add"

# Docker subcommands whose ``-e``/``--env`` flags declare CONTAINER env vars.
# ``add`` only mines env declarations out of these so a ``docker run -e K=V``
# spec lands the env in the secret/profile store like an imported one would.
_DOCKER_ENV_SUBCOMMANDS = ("run", "create", "exec")

# Docker GLOBAL options that take a SEPARATE value argument (``docker --context
# desktop-linux run ...``). When scanning for the subcommand, the value token
# after one of these must be skipped — otherwise it would be mistaken for the
# subcommand and env mining would never engage, leaking an inline credential.
# Inline forms (``--context=x``, ``-H=x``) carry their own value and need no
# skip. This list covers docker's documented value-taking global flags; an
# unknown value-taking flag at worst leaves env mining off (fail-safe: the value
# is then NOT redacted, but that is the pre-existing conservative behavior, not a
# regression introduced here).
_DOCKER_GLOBAL_VALUE_FLAGS = frozenset(
    {
        "--config",
        "--context",
        "-c",
        "--host",
        "-H",
        "--log-level",
        "-l",
        "--tlscacert",
        "--tlscert",
        "--tlskey",
    }
)

# Docker ``run``/``create`` options that take a SEPARATE value argument. Used to
# find where the option section ends (the IMAGE is the first bare token not
# consumed as one of these options' value) and to skip a value token when
# scanning. Any OTHER ``-x``/``--x`` token is treated as a boolean flag that
# consumes no value — so its following positional (often the IMAGE) is NOT
# mistaken for a value and is left structural. Docker env (``-e``/``--env``) is
# handled separately by the mining loop, so it is intentionally omitted here.
# Erring toward "boolean" for an unknown flag is the safe choice: at worst env
# mining stops one token early (a missed inline secret stays inline, the
# pre-existing conservative behavior), never the reverse (consuming a positional
# as a phantom value, which would corrupt the command).
_DOCKER_RUN_VALUE_FLAGS = frozenset(
    {
        "-v", "--volume", "--mount", "-p", "--publish", "--name", "-w",
        "--workdir", "--network", "--net", "-u", "--user", "--entrypoint",
        "-l", "--label", "--env-file", "--add-host", "--device", "--dns",
        "--expose", "--health-cmd", "--hostname", "-h", "--ip", "--label-file",
        "--link", "--log-driver", "--log-opt", "-m", "--memory", "--platform",
        "--restart", "--pull", "--cpus", "--gpus", "--ulimit", "--tmpfs",
        "--cap-add", "--cap-drop", "--security-opt", "--shm-size", "--cidfile",
        "--pid", "--ipc", "--volumes-from", "--cgroupns",
    }
)


class AddError(ValueError):
    """A spec cannot be added (bad spec, host-only placement, name clash)."""


@dataclass
class AddResult:
    """Outcome of adding one server (SECRET-FREE).

    Mirrors ``apply.AppliedServer`` for a consistent text/JSON surface: copied
    secret KEY NAMES only, never their values.
    """

    name: str
    scope: str
    project_key: str  # "" for global
    profile_path: str
    placement: str
    argv: list[str] = field(default_factory=list)
    env_keys: list[str] = field(default_factory=list)
    copied_secret_keys: list[str] = field(default_factory=list)
    secrets_path: str = ""  # set only when secret keys were copied

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "name": self.name,
            "scope": self.scope,
            "profilePath": self.profile_path,
            "placement": self.placement,
            "argv": list(self.argv),
            "envKeys": list(self.env_keys),
            # NAMES only — values live 0600 in the secret store, never here.
            "copiedSecretKeys": list(self.copied_secret_keys),
        }
        if self.project_key:
            out["project"] = self.project_key
        if self.copied_secret_keys:
            out["secretsPath"] = self.secrets_path
        return out


@dataclass
class ParsedSpec:
    """A command spec parsed into the candidate model plus inline env VALUES.

    ``argv`` already has any inline secret value redacted. ``env_values`` is the
    in-memory map of every inline ``KEY=VALUE`` the user supplied (secret and
    non-secret); the caller splits it by ``secret_env_keys`` when writing.
    """

    argv: list[str]
    env_keys: list[str]
    secret_env_keys: list[str]
    env_values: dict[str, str]


def _split_env_assignment(token: str) -> tuple[str, Optional[str]]:
    """Split a ``KEY=VALUE`` (or bare ``KEY``) env token.

    Returns ``(key, value)`` with ``value`` None for a bare ``KEY`` (a pass-through
    env reference the user expects to be present in the environment at launch).
    """
    if "=" in token:
        key, value = token.split("=", 1)
        return key, value
    return token, None


def parse_spec(argv: list[str]) -> ParsedSpec:
    """Parse a generic command spec into a secret-safe candidate command.

    The spec is the user's literal launch command (``npx -y pkg``,
    ``uvx tool``, ``docker run -e K=V image``, ``/abs/bin/server``). Env
    declarations are mined only from a Docker spec's ``-e``/``--env`` flags that
    appear BEFORE the image token — that is the documented way to pass env to a
    containerized MCP server, and the one place ``add`` can recover an inline
    value. A ``-e`` after the image belongs to the containerized program and is
    left verbatim. For every mined ``KEY=VALUE``:

      * the NAME is recorded in ``env_keys`` (and ``secret_env_keys`` when the
        name OR the value looks like a credential);
      * the VALUE is kept in ``env_values`` (in memory only);
      * a SECRET value is redacted out of the stored argv so the profile never
        carries the literal credential; a non-secret value is left on the argv.

    A bare ``-e KEY`` (no value) records the name as a declared env reference but
    contributes no value. argv tokens are otherwise preserved verbatim.

    Raises :class:`AddError` for an empty spec.
    """
    if not argv:
        raise AddError("empty command spec; pass the launch command after '--'")

    command = argv[0]
    is_docker = os.path.basename(command).lower() in ("docker", "podman")
    # Only mine env after a docker env-bearing subcommand (run/create/exec); a
    # bare ``docker --version`` style spec has no container env. Scan for the
    # subcommand while SKIPPING the value of any value-taking global option
    # (``docker --context desktop-linux run ...``), so a global-option value is
    # never mistaken for the subcommand (which would disable env mining and leak
    # an inline credential).
    docker_env_mode = False
    subcommand_index = -1
    if is_docker:
        skip_next = False
        for j in range(1, len(argv)):
            tok = argv[j]
            if skip_next:
                skip_next = False
                continue
            if tok.startswith("-"):
                # A separate-value global flag consumes the next token; an
                # inline ``--flag=value`` form does not.
                if tok in _DOCKER_GLOBAL_VALUE_FLAGS and "=" not in tok:
                    skip_next = True
                continue
            docker_env_mode = tok in _DOCKER_ENV_SUBCOMMANDS
            subcommand_index = j
            break

    out_argv: list[str] = [command]
    env_keys: list[str] = []
    secret_env_keys: list[str] = []
    env_values: dict[str, str] = {}
    # Indices of out_argv tokens produced by Docker env mining. They are already
    # in a secret-safe shape, so the later generic ``_redact_argv`` pass must NOT
    # rewrite them — in particular it must not mistake a long forwarding-form env
    # NAME after ``-e`` (e.g. ``-e ANTHROPIC_API_KEY``) for an opaque credential
    # and redact it, which would wrongly reject a valid Docker spec.
    protected: set[int] = set()

    def protect_last() -> None:
        protected.add(len(out_argv) - 1)

    def append_option(token: str) -> None:
        """Append a structural Docker OPTION token (a flag NAME, a separate
        value, or an inline ``--flag=value``) and protect it from the WEAK
        opaque-after-flag redaction heuristic — so an innocent opaque value
        (``--name myserver123``, ``--context prod1``) is not wrongly redacted
        and the spec refused.

        But a token that IS or EMBEDS a credential is redacted instead of
        protected, so a secret smuggled through a non-env Docker option
        (``docker run --label API_KEY=sk-...``) is refused like any other
        argv-borne secret, never exempted into the secret-free profile.
        """
        if _looks_like_secret_value(token) or _contains_embedded_secret(token):
            out_argv.append(_REDACTED)
        else:
            out_argv.append(token)
        protect_last()

    def record_env(token: str, *, inline_flag: Optional[str] = None) -> None:
        key, value = _split_env_assignment(token)
        if not key:
            # No parseable env NAME (e.g. a stray ``-e=`` or a bare ``=value``).
            # Preserve the token verbatim instead of silently dropping it — a
            # dropped token would corrupt the stored launch command. Leave it
            # redaction-eligible (NOT protected) so any secret-shaped leftover is
            # still scrubbed by the later pass and refused.
            if inline_flag is not None:
                out_argv.append(f"{inline_flag}{token}")
            else:
                out_argv.append(token)
            return
        if key not in env_keys:
            env_keys.append(key)
        is_secret = _is_secret_env_name(key) or (
            value is not None and (_looks_like_secret_value(value) or _value_looks_secret(value))
        )
        if is_secret and key not in secret_env_keys:
            secret_env_keys.append(key)
        if value is not None:
            env_values[key] = value
        # Rebuild the argv token. A SECRET inline value is stored as the Docker
        # ENV-FORWARDING form ``KEY`` (no ``=value``): Docker then forwards the
        # variable from the process environment, which the wrapper populates from
        # the 0600 secret store at launch. Storing ``KEY=<redacted>`` would make
        # Docker pass the literal placeholder into the container (a broken
        # credential), and storing ``KEY=<value>`` would leak the secret into the
        # profile. A NON-secret value is kept inline as the user wrote it.
        if value is None or is_secret:
            stored = key
        else:
            stored = f"{key}={value}"
        if inline_flag is not None:
            out_argv.append(f"{inline_flag}{stored}")
        else:
            out_argv.append(stored)
        protect_last()

    i = 1
    n = len(argv)
    # ``in_option_section`` is True while we are between the docker subcommand and
    # the IMAGE token — the ONLY place ``-e``/``--env`` declare container env and
    # the only place env mining is valid. Everything from the image onward is the
    # containerized program + its args (where a ``-e`` is the program's own flag,
    # not docker env) and is copied + protected verbatim so the generic
    # credential-redaction pass never rewrites a structural docker token.
    in_option_section = False
    while i < n:
        tok = argv[i]
        if docker_env_mode and i == subcommand_index:
            # Enter the option section right after the subcommand token.
            out_argv.append(tok)
            protect_last()
            in_option_section = True
            i += 1
            continue

        if in_option_section:
            if tok == "-e" or tok == "--env":
                out_argv.append(tok)
                protect_last()  # the flag itself is structural
                if i + 1 < n:
                    record_env(argv[i + 1])
                    i += 2
                    continue
                i += 1
                continue
            if tok.startswith("-e") and len(tok) > 2 and not tok.startswith("--"):
                # Docker accepts both ``-eKEY=VAL`` and ``-e=KEY=VAL``; in the
                # latter the first ``=`` is the flag/value separator. Strip a
                # single leading ``=`` before parsing the assignment — otherwise
                # the KEY parses as empty and the env declaration would be lost.
                inline = tok[2:]
                if inline.startswith("="):
                    inline = inline[1:]
                record_env(inline, inline_flag="-e")
                i += 1
                continue
            if tok.startswith("--env="):
                record_env(tok[len("--env="):], inline_flag="--env=")
                i += 1
                continue
            if tok.startswith("-"):
                # Any other option. Route through append_option: a flag NAME or
                # an innocent opaque value is kept + protected, but an inline
                # ``--flag=KEY=sk-...`` (or the separate value consumed below)
                # that carries a credential is redacted so the spec is refused —
                # never exempted into the profile. A known separate-value option
                # also consumes its value token; an inline ``--flag=value`` form
                # does not.
                append_option(tok)
                if (
                    tok in _DOCKER_RUN_VALUE_FLAGS
                    and "=" not in tok
                    and i + 1 < n
                ):
                    append_option(argv[i + 1])
                    i += 2
                    continue
                i += 1
                continue
            # First bare token in the option section = the IMAGE. The option
            # section ends here and no further env is mined. The IMAGE itself is
            # structural, so it is protected from the credential-redaction pass
            # (it can sit right after a boolean flag like ``--rm`` and would
            # otherwise be mistaken for an opaque value). Everything AFTER the
            # image is the containerized program's own argv — it is NOT protected
            # so a credential passed there (``docker run img server --api-key
            # sk-...``) goes through the same redaction/refusal path as a
            # non-docker spec, never leaking into the profile.
            in_option_section = False
            out_argv.append(tok)
            protect_last()
            i += 1
            continue

        # Docker tokens BEFORE the subcommand are global options (and their
        # values) — structural docker syntax. Route through append_option so an
        # opaque-looking value like ``--context prod123`` is preserved (not
        # mistaken for an argv credential and the spec wrongly refused), while a
        # value that actually carries a credential is still redacted/refused
        # rather than exempted into the profile.
        if docker_env_mode and i < subcommand_index:
            append_option(tok)
            if (
                tok in _DOCKER_GLOBAL_VALUE_FLAGS
                and "=" not in tok
                and i + 1 < n
            ):
                append_option(argv[i + 1])
                i += 2
                continue
            i += 1
            continue

        # Outside any docker option section (a non-docker spec): copy verbatim
        # and let the redaction pass decide.
        out_argv.append(tok)
        i += 1

    # Scrub credentials passed as plain argv ARGUMENTS (not Docker -e env), the
    # same way the import providers do (e.g. ``npx server --api-key sk-...`` or a
    # bare ``sk-ant-...`` positional). Docker env tokens were already handled
    # above into a secret-safe shape (forwarding form for secrets, screened
    # non-secret inline values), so this pass only catches argv-borne secrets
    # that env mining does not cover. Any token it redacts becomes a
    # ``<redacted>`` placeholder, which ``add_server`` then REFUSES — boxa does
    # not support credential-in-argv import (the secret store copies env values,
    # not argv tokens), so persisting a broken redacted command is wrong.
    #
    # The Docker env-mined tokens are RESTORED verbatim afterward: ``_redact_argv``
    # would otherwise mistake a long forwarding-form env NAME (``-e
    # ANTHROPIC_API_KEY``) for an opaque credential value and redact it, wrongly
    # rejecting a valid Docker spec. Those tokens already carry no secret value.
    redacted_argv = _redact_argv(out_argv)
    for idx in protected:
        redacted_argv[idx] = out_argv[idx]

    return ParsedSpec(
        argv=redacted_argv,
        env_keys=env_keys,
        secret_env_keys=secret_env_keys,
        env_values=env_values,
    )


def build_candidate(
    name: str, spec: ParsedSpec, scope: str, project_key: str
) -> Candidate:
    """Build a classified Candidate for an added server.

    Records the chosen scope as the candidate's source scope/project so the
    classifier's project-root path exemptions match, and so the import id is
    derived from the real target. The classifier runs over the parsed argv +
    env NAMES exactly as it does for an imported candidate.
    """
    cand = Candidate(
        provider=ADD_PROVIDER,
        source_path="",  # no source config — added explicitly
        source_scope=scope,
        source_project=project_key or None,
        name=name,
        type=None,
        command=Command(
            argv=list(spec.argv),
            env_keys=list(spec.env_keys),
            secret_env_keys=list(spec.secret_env_keys),
        ),
    )
    return classify_candidate(cand)


def add_server(
    name: str,
    spec_argv: list[str],
    override: ScopeOverride,
) -> AddResult:
    """Add one new Boxa MCP server to the scope-correct profile + secrets.

    ``override`` carries the explicit scope decision (``global`` or ``project``
    with an absolute key) — ``add`` never defaults a scope, so a resolved
    override is always required (the shell front-end produces it from a flag or
    the project picker). The spec is parsed, classified, and:

      * refused (:class:`AddError`) when its placement is not ``container``
        (host-only / unknown / excluded), reusing the apply path's reason text;
      * refused when a server of the same name already exists in the target
        scope (``add`` records a NEW server; updating an existing one is an
        explicit remove + re-add, never a silent overwrite);
      * otherwise written to the scope's profile, with any inline secret VALUES
        copied into the scope's 0600 secret store and non-secret inline values
        recorded in the profile (mirrors import's split).

    Returns a SECRET-FREE :class:`AddResult` (copied KEY NAMES only).
    """
    spec = parse_spec(spec_argv)
    scope = override.scope
    project_key = override.project_key if scope == "project" else ""

    cand = build_candidate(name, spec, scope, project_key)
    placement = cand.classification.placement
    import_id = compute_import_id(cand)
    # Reuse the apply path's gate AND its exact reason text by wrapping the
    # candidate in a MergedCandidate (the helpers read only the candidate). This
    # refuses non-``container`` placements (host-only / unknown / excluded) AND a
    # spec whose argv carries a redacted credential — identical to import.
    merged = MergedCandidate(candidate=cand, import_id=import_id)
    if not is_applicable(merged):
        raise AddError(f"cannot add {name!r}: {not_applicable_reason(merged)}")
    p_path = profile_path(scope, project_key or None)

    # Split inline env values by the secret classification.
    secret_values = {
        k: v for k, v in spec.env_values.items() if k in spec.secret_env_keys
    }
    nonsecret_values = {
        k: v
        for k, v in spec.env_values.items()
        if k not in spec.secret_env_keys and not _value_looks_secret(v)
    }
    copied_keys = sorted(secret_values)

    result = AddResult(
        name=name,
        scope=scope,
        project_key=project_key,
        profile_path=p_path,
        placement=placement,
        argv=list(spec.argv),
        env_keys=list(spec.env_keys),
        copied_secret_keys=copied_keys,
    )

    # Load + validate the profile BEFORE touching the secret store; refuse a
    # name clash so add never overwrites an existing server.
    profile = load_profile(p_path)
    if name in profile.get("servers", {}):
        where = f"{scope} ({project_key})" if project_key else scope
        raise AddError(
            f"a server named {name!r} already exists in scope {where}; "
            "remove it first or choose another name (add never overwrites)"
        )
    if scope == "project" and project_key:
        profile["projectKey"] = project_key
    profile["servers"][name] = build_server_entry(
        name=name,
        argv=spec.argv,
        env_keys=spec.env_keys,
        secret_env_keys=spec.secret_env_keys,
        type_=cand.type,
        source_provider=ADD_PROVIDER,
        import_id=import_id,
        env=nonsecret_values,
    )

    # Persist secrets, then commit the profile; roll the secret block back to its
    # prior state if the profile save fails.
    #
    # When add HAS inline secret values, write them (replacing any prior block).
    # When it has NONE (e.g. a bare ``-e GITHUB_TOKEN`` forwarding reference that
    # declares the name but supplies no value), do NOT touch the store: a block
    # may have been intentionally retained from an earlier non-``--purge`` remove,
    # and the bare reference exists precisely to REUSE that stored credential.
    # Purging it here (as the import path does for a re-import) would orphan a
    # required env the runner can no longer resolve. So an empty-value add leaves
    # any existing block untouched rather than deleting it.
    s_path = secrets_path(scope, project_key or None)
    if secret_values:
        prior_block = read_server_secrets(s_path, name)
        store_server_secrets(s_path, name, secret_values)
        result.secrets_path = s_path
        try:
            save_profile(p_path, profile)
        except Exception:
            restore_server_secrets(s_path, name, prior_block)
            raise
    else:
        # No store mutation; if the existing block can back the declared secret
        # keys, surface its path so the summary shows the credential is wired up.
        if spec.secret_env_keys and read_server_secrets(s_path, name):
            result.secrets_path = s_path
        save_profile(p_path, profile)

    return result
