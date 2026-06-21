# Contributing

Thanks for your interest in improving boxa. This is a local-first,
build-from-source project (see [ROADMAP.md](ROADMAP.md) — there is no prebuilt
image to pull). The notes below describe how to build it, run the tests, lint,
and propose a change.

## Building

Boxa is built and run from a clone of this repository.

```bash
./build.sh          # build the container image (ivijl/boxa:latest)
./build.sh --help   # all flags (--no-cache, --clean, --uninstall, ...)
```

`install.sh` is the host bootstrapper for a fresh machine: it installs the
prerequisites (git, Docker, keychain), clones the repo into
`~/.local/share/boxa`, builds the image, and installs the `boxa` command on
your `PATH`.

```bash
bash install.sh --help
```

If you already have a clone and just want the `boxa` command, symlink the
runner:

```bash
sudo ln -s "$(realpath docker-run.sh)" /usr/local/bin/boxa
```

## Running the tests

Tests live in `tests/`. There are two kinds, run independently — there is no
single aggregate runner.

**Python tests** (the MCP and provisioning logic under `scripts/`) use the
standard library `unittest`. Set `PYTHONPATH=scripts` so the modules under test
resolve, and run a single module or discover the whole suite:

```bash
# one module
PYTHONPATH=scripts python3 -m unittest tests.test_mcp_add

# whole suite
PYTHONPATH=scripts python3 -m unittest discover -s tests -p 'test_*.py'
```

**Shell smoke tests** are self-contained Bash scripts that stub host state in a
throwaway temp dir, so they exercise dispatch logic without touching your real
machine. Run them directly:

```bash
bash tests/test_provisioning.sh
```

Add a test alongside the behaviour you change. Match the existing style of the
neighbouring tests in `tests/`.

## Linting

Shell scripts must pass `shellcheck` cleanly. Fix **all** findings, including
info-level (`SC####`) — the only acceptable exceptions are genuine false
positives, which should carry an inline `# shellcheck disable=SCxxxx` with a
short reason.

```bash
shellcheck build.sh install.sh docker-run.sh scripts/*.sh lib/*.sh tests/*.sh
```

Python helpers are kept clean with [Ruff](https://docs.astral.sh/ruff/):

```bash
ruff check scripts
```

## Coding conventions

- Project conventions and the domain glossary live in
  [`CONTEXT.md`](CONTEXT.md) — read it before touching firewall, DNS, HTTPS, or
  MCP code so you use the established terms.
- Agent / repo-wide working agreements live in [`AGENTS.md`](AGENTS.md).
- Significant design decisions are recorded as ADRs under
  [`docs/adr/`](docs/adr/). Read the relevant ADR before refactoring an area it
  covers; add a new ADR for a new significant decision.
- Code, comments, and user-facing strings are written in English.
- Packages and tools are installed in the `Dockerfile`, never at container
  runtime.

## Proposing a change

1. Fork the repository and create a branch from `main`.
2. Make your change, with a test and updated docs where they apply.
3. Run `shellcheck` (and `ruff` / the relevant tests) locally — see above.
4. Open a pull request against `main` describing the change and why it is
   needed. Reference any ADR you added or followed.

For a security issue, do **not** open a public PR or issue — see
[SECURITY.md](SECURITY.md).
