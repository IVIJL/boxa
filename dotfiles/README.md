# Boxa bundled dotfiles

The default dotfiles starter that ships with [boxa](../README.md). It is a
[chezmoi](https://www.chezmoi.io/) source tree, baked into the boxa image and
applied **locally on container start** — no network, no clone, no second repo
to trust (the same local-first stance as [ADR 0018](../docs/adr/0018-local-first-no-prebuilt-image.md)).

## What it sets up

- **`dot_zshrc`** — a portable zsh config (macOS/Linux aware, lazy-loaded
  tooling, starship prompt, atuin history, fzf, syntax highlighting). Every
  integration is `command -v`-guarded, so missing tools degrade gracefully.
- **`dot_bashrc`** — bash fallback prompt and aliases.
- **`dot_extra_aliases`** — handy aliases plus the `dx`/`dcx` helpers for
  dropping a rich shell into any running container / compose service.
- **`dot_container-bashrc`** — the minimal rc that `dx`/`dcx` copy into target
  containers.
- **`dot_nanorc`**, **`private_dot_config/`** — nano, starship, tmux, atuin, and
  a global git ignore.

## How boxa uses it

The 3-way dotfiles prompt in `install.sh` writes your choice to
`~/.config/boxa/dotfiles.conf`:

1. **Bundled starter** (default) — `CHEZMOI_REPO=bundled`; boxa applies this
   tree from the image with `chezmoi apply --source`.
2. **Your own chezmoi repo** — `CHEZMOI_REPO=<url>`; boxa runs
   `chezmoi init <url>` then applies.
3. **None** — empty `CHEZMOI_REPO`; boxa skips dotfiles entirely (pure bash).

## Make it yours

Copy this directory into your own chezmoi (or other) repo, edit to taste, and
pick option 2 at install time with your repo URL. Nothing here is mandatory —
it is a starting point, not a lock-in.
