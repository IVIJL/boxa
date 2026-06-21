# Roadmap

This is a loose, non-binding list of directions we'd like to explore. Items are
not ordered or scheduled, and anything here may change. See
[CONTRIBUTING.md](CONTRIBUTING.md) if you'd like to help with one of them.

## Planned / wanted

- **Zed remote support.** Let [Zed](https://zed.dev/) connect into a running
  container over SSH (Zed's remote-development mode), the same way Cursor /
  VS Code attach today via Dev Containers.
- **`stow` dotfiles support.** Allow dotfiles to be applied with
  [GNU Stow](https://www.gnu.org/software/stow/) as an alternative to the
  current chezmoi-based flow, for users who already keep their dotfiles as stow
  packages.
- **Demo asset.** A short recorded demo (asciinema cast or GIF) showing the
  install → build → run → firewall flow, to make the README approachable.

## Non-goals

- **Prebuilt image / GHCR.** Boxa is deliberately **local-first**: you build
  the image from source on your own machine (`./build.sh`). We do **not** plan
  to publish a prebuilt image to GHCR or any other registry. Building locally
  keeps the trust boundary on the host and avoids shipping baked-in secrets or
  trust-store state.

## Conditional

- **Multi-arch (arm64 for Apple Silicon).** Only relevant *if* a prebuilt image
  is ever shipped (see non-goal above). Since the image is built locally, it
  already targets the host architecture — arm64 macOS hosts build an arm64
  image with no extra work. A multi-arch build matrix would only be needed for a
  published registry image, so this is parked behind that decision.
