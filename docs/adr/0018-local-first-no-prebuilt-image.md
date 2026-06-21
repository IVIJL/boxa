# ADR 0018 — Local-first: no prebuilt registry image

- **Status:** accepted
- **Date:** 2026-06-21

## Context

Most Dev Containers tooling optimises for fast onboarding by shipping a
**prebuilt image**: the `devcontainer.json` references an `image:` tag, the
editor pulls it from a registry (Docker Hub / GHCR), and the user is running in
seconds without ever building anything. Our own standalone configs lean this way
too — `.devcontainer/cursor/devcontainer.json` carries an
`"image": "ivijl/boxa:latest"` reference rather than a build directive.

For boxa that convenience pulls in the opposite direction from the whole point
of the project. Boxa exists to give an agent a sandbox whose trust boundary the
user controls: a privileged entrypoint instead of in-container sudo
(ADR 0003), a firewall allowlist the user owns (ADR 0001), a host-built mkcert
trust store (ADR 0008). A prebuilt image undercuts that — the user would be
running a binary blob they did not assemble, with whatever baked-in secrets,
trust-store state, or drift the publisher happened to ship, and we would owe a
registry account, a publishing pipeline, and a multi-arch build matrix to keep
it current.

The base layer is the one place we cannot avoid a registry: the Dockerfile
starts `FROM node:22-trixie`, which is itself pulled from a registry. That is an
upstream image we audit and pin, not one we publish.

## Decision

Boxa is **build-from-source only**. We never publish a boxa image to a registry.

- The image is **built once locally** by `./build.sh`, which runs
  `docker build -t "$IMAGE" …` where `$IMAGE` is `ivijl/boxa:latest`
  (`BRAND_IMAGE` in `lib/brand.sh`).
- That single locally-built image is **reused across every project** — the
  per-project containers boxa launches all run the same `ivijl/boxa:latest`
  tag, so the build cost is paid once, not per project.
- The standalone configs build the same way: `.devcontainer/devcontainer.json`
  and `devcontainer-standalone.json` point at `../Dockerfile` /  `Dockerfile`
  via a `build` directive, and the Cursor variant
  (`.devcontainer/cursor/devcontainer.json`) references the
  **already-locally-built** `ivijl/boxa:latest` tag — it does not pull it from
  a registry, because we never push it there.
- The **only unavoidable registry touch** is the base image `node:22-trixie`
  pulled by the Dockerfile's `FROM`. Everything layered on top is built and
  audited on the user's own host.

The tag `ivijl/boxa:latest` is namespaced (`BRAND_IMAGE_NAMESPACE="ivijl"` in
`lib/brand.sh`) so it *could* one day name a published image, but the namespace
is a naming convenience only; no publishing step exists or is planned.

## Rationale

- **Trust / supply-chain.** The user **audits and builds the Dockerfile
  themselves**. The trust boundary stays on the host — there is no published
  artefact to compromise, no baked-in secret to leak, and no opaque layer the
  user did not produce. This is the same control ethos as ADR 0003 (no
  in-container sudo) and ADR 0008 (host-built trust store).
- **Simplicity.** No registry account, no CI publishing job, no multi-arch
  build pipeline, no image-signing/provenance story to maintain. The whole
  distribution mechanism is "run `./build.sh`".
- **Architecture parity for free.** A locally built image already targets the
  host architecture, so an arm64 Apple-Silicon host produces an arm64 image with
  no extra work — the case a multi-arch matrix would otherwise exist to serve.

## Consequences

**Positive:**

- The trust boundary stays entirely on the user's host; nothing boxa ships can
  carry baked-in secrets or trust-store state.
- No registry, CI, or release-signing infrastructure to run or secure.
- Cross-architecture support (arm64) is automatic for the host that builds.

**Negative / limitations:**

- **Slower first run.** The first `./build.sh` is a full image build instead of
  a registry pull; onboarding is minutes, not seconds. Subsequent projects reuse
  the cached `ivijl/boxa:latest`, so the cost is one-time.
- The standalone / Cursor `devcontainer.json` flow depends on the image having
  **already been built locally** under the `ivijl/boxa:latest` tag — opening it
  before a local build will fail to find the image rather than silently pulling
  a published one.

**Non-goal (explicit):**

- Publishing a **prebuilt image to GHCR / Docker Hub**, and the **multi-arch
  (arm64) build matrix** that would only exist to serve such a published image,
  are explicit non-goals. They are revisited only on real demand and are tracked
  as a non-goal / conditional item in `ROADMAP.md`.

## References

- `lib/brand.sh` — `BRAND_IMAGE="ivijl/boxa:latest"` (the locally built tag) and
  the `BRAND_IMAGE_NAMESPACE` note that the image is built locally, no registry.
- `build.sh` — `docker build -t "$IMAGE"`; the single local build that produces
  `ivijl/boxa:latest`.
- `Dockerfile` — `FROM node:22-trixie`, the one unavoidable registry pull (the
  audited, pinned base image).
- `.devcontainer/devcontainer.json`, `devcontainer-standalone.json` — build from
  `Dockerfile`; `.devcontainer/cursor/devcontainer.json` — reuses the
  locally-built `ivijl/boxa:latest` tag.
- `ROADMAP.md` — the "Prebuilt image / GHCR" non-goal and the conditional
  multi-arch (arm64) item this ADR formalises.
- ADR 0003, ADR 0008 — the isolation/control ethos this decision aligns with.
