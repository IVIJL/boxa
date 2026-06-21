# Debian trixie base: needed for util-linux >= 2.39, whose `mount -o X-mount.idmap`
# the per-broker workspace remount relies on (ADR 0014 issue 21). Bookworm ships
# util-linux 2.38.1 (no idmap option) -> workspace write would degrade to
# read-only. trixie ships 2.41. (trixie also has GLIBC 2.41, well past the 2.39 the
# tree-sitter binaries want.)
FROM node:22-trixie

ARG TZ=Europe/Prague
ENV TZ="$TZ"

# =============================================================================
# Layer 1: APT packages (Claude Code base + user tools)
# =============================================================================
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update && apt-get install -y --no-install-recommends \
    # Claude Code packages
    less git procps sudo zsh man-db unzip gnupg2 gh \
    iptables ipset iproute2 dnsutils aggregate jq nano vim dnsmasq iputils-ping socat \
    # util-linux: setpriv (broker credential drop) + unshare/mount (ADR 0014
    # issue 21 per-broker mount namespace + X-mount.idmap workspace remount).
    # X-mount.idmap needs util-linux >= 2.39; the trixie base ships 2.41. Listed
    # explicitly to make the broker's hard dependency survive a future base change.
    util-linux \
    # Rootless Docker prerequisites
    uidmap fuse-overlayfs slirp4netns \
    # User packages (tmux is current in trixie, so no backports needed)
    ncdu mc nala libfuse2 xauth xclip ripgrep fd-find tmux \
    build-essential libclang-dev \
    grc curl wget ca-certificates shellcheck rsync \
    && ln -s "$(which fdfind)" /usr/local/bin/fd

# =============================================================================
# Layer 2: Binary installs (root)
# =============================================================================

# git-delta
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
    wget -q "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Neovim (tar.gz - works on both x86_64 and arm64)
ARG NVIM_VERSION=v0.11.6
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then NVIM_ARCH="x86_64"; else NVIM_ARCH="arm64"; fi && \
    wget -q "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-${NVIM_ARCH}.tar.gz" && \
    tar xzf "nvim-linux-${NVIM_ARCH}.tar.gz" && \
    mv "nvim-linux-${NVIM_ARCH}" /opt/nvim && \
    ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim && \
    rm "nvim-linux-${NVIM_ARCH}.tar.gz"

# Eza
ARG EZA_VERSION=0.20.14
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then EZA_ARCH="x86_64"; else EZA_ARCH="aarch64"; fi && \
    wget -q "https://github.com/eza-community/eza/releases/download/v${EZA_VERSION}/eza_${EZA_ARCH}-unknown-linux-gnu.tar.gz" && \
    tar xzf "eza_${EZA_ARCH}-unknown-linux-gnu.tar.gz" -C /usr/local/bin/ && \
    rm "eza_${EZA_ARCH}-unknown-linux-gnu.tar.gz"

# =============================================================================
# Layer 3: Docker CE (rootless)
# =============================================================================
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    docker-ce-rootless-extras

# Rootless Docker: subordinate UID/GID mapping
RUN echo "node:100000:65536" >> /etc/subuid && \
    echo "node:100000:65536" >> /etc/subgid

# Rootless Docker: runtime directories and config
RUN mkdir -p /run/user/1000 && chown node:node /run/user/1000 && \
    mkdir -p /home/node/.local/share/docker && chown -R node:node /home/node/.local && \
    mkdir -p /home/node/.config/docker && \
    echo '{"storage-driver": "fuse-overlayfs"}' > /home/node/.config/docker/daemon.json && \
    chown -R node:node /home/node/.config

# =============================================================================
# Layer 4: NPM/directories/env setup (root)
# =============================================================================
RUN mkdir -p /usr/local/share/npm-global && \
    chown -R node:node /usr/local/share/npm-global

ARG USERNAME=node

# boxa-mcp service account (ADR 0014, issue 15). A dedicated UNPRIVILEGED
# account, distinct from the agent user `node` (UID 1000), under which the MCP
# broker runs and spawns MCP servers. The whole point is credential isolation:
# because servers run as boxa-mcp, the agent (node) cannot read their
# /proc/<pid>/environ (mode 0400, owned by the process UID) nor signal/ptrace
# them. boxa-mcp gets:
#   * its own writable HOME so per-account state has somewhere to live;
#   * a writable npm/npx cache so on-demand `npx` MCP servers run under it
#     without polluting node's cache or needing write access to node's HOME;
#   * NO sudo and NO membership in any privileged group (ADR 0003: no path back
#     to root from inside the Container).
# node and boxa-mcp DELIBERATELY do NOT share each other's primary group
# (ADR 0014 "peer-equal citizen", 2026-05-31): neither account is a member of
# the other's group, so the service-account HOME stays 0700 OWNER-only (node
# never sees group-readable files an MCP server might drop there — npm/npx
# state, tokens, caches) and node's home stays owner-only to node. The two
# identities meet ONLY at an explicit bridge: the `boxa-bridge` group below,
# which owns the broker socket. `.config` is pre-created (writable) so a spawned
# MCP server's XDG_CONFIG_HOME (which the broker points at this HOME, not node's
# profile mount) has a home.
RUN groupadd --system boxa-mcp && \
    useradd --system --gid boxa-mcp --create-home \
        --home-dir /home/boxa-mcp --shell /usr/sbin/nologin boxa-mcp && \
    mkdir -p /home/boxa-mcp/.npm /home/boxa-mcp/.cache /home/boxa-mcp/.config && \
    chown -R boxa-mcp:boxa-mcp /home/boxa-mcp && \
    chmod 0700 /home/boxa-mcp

# boxa-bridge group (ADR 0014, issue 19) — the SHARED-RUNTIME-SOCKET bridge.
# Created ONLY inside the image, never on the host: the sockets that use it live
# in /run (broker socket; future Docker socket), so the group never reaches host
# files and the system-assigned GID is irrelevant (it never leaves the
# Container). BOTH node and boxa-mcp are members. This is how the relay (node)
# reaches the broker socket WITHOUT being in boxa-mcp's primary group: the
# socket is group-owned `boxa-bridge` 0660 in a 0770 dir, so the broker
# (boxa-mcp) owns/serves it and node connects via the bridge — credentials and
# private homes stay owner-only and out of reach. The bridge is ONLY for sockets,
# never for the secret store (which stays 0700/0400 owner-only to boxa-mcp).
RUN groupadd --system boxa-bridge && \
    usermod -aG boxa-bridge node && \
    usermod -aG boxa-bridge boxa-mcp


# Create workspace and config directories
RUN mkdir -p /workspace /home/node/.claude \
    /home/node/.cursor-server /home/node/.vscode-server && \
    chown -R node:node /workspace /home/node/.claude \
    /home/node/.cursor-server /home/node/.vscode-server

# Pre-populate GitHub SSH host keys (so git works without host known_hosts)
RUN mkdir -p /home/node/.ssh && chmod 700 /home/node/.ssh && \
    ssh-keyscan -t ed25519,rsa github.com >> /home/node/.ssh/known_hosts 2>/dev/null && \
    chmod 600 /home/node/.ssh/known_hosts && \
    chown -R node:node /home/node/.ssh

ENV DEVCONTAINER=true
ENV SHELL=/bin/zsh
ENV TERM=xterm-256color
ENV LANG=C.UTF-8

WORKDIR /workspace

# ZSH plugins (installed to /usr/share/ for chezmoi .zshrc sourcing)
RUN git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions /usr/share/zsh-autosuggestions && \
    git clone --depth 1 https://github.com/agkozak/zsh-z.git /usr/share/zsh-z && \
    git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting.git /usr/share/zsh-syntax-highlighting && \
    git clone --depth 1 https://github.com/Aloxaf/fzf-tab /usr/share/fzf-tab

# =============================================================================
# Layer 5: User-level tools (as node)
# =============================================================================
USER node

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# fzf keybindings + completion (CTRL-R, CTRL-T, **(TAB))
RUN git clone --depth 1 https://github.com/junegunn/fzf.git /home/node/.fzf && \
    /home/node/.fzf/install --all

# Rust + Cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# tree-sitter-cli from source (pre-built binary AND Mason's binary both need GLIBC 2.39, Bookworm has 2.36)
RUN --mount=type=cache,target=/home/node/.cargo/registry,uid=1000 \
    --mount=type=cache,target=/home/node/.cargo/git,uid=1000 \
    --mount=type=cache,target=/tmp/cargo-target,uid=1000 \
    . "$HOME/.cargo/env" && CARGO_TARGET_DIR=/tmp/cargo-target cargo install tree-sitter-cli

# Starship prompt
RUN mkdir -p /home/node/.local/bin && \
    curl -sS https://starship.rs/install.sh | sh -s -- --yes --bin-dir /home/node/.local/bin

# Atuin shell history
RUN curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh && \
    mkdir -p /home/node/.local/share/atuin

# UV Python package manager
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# LazyVim starter + cleanup
RUN git clone --depth 1 https://github.com/LazyVim/starter /home/node/.config/nvim && \
    rm -rf /home/node/.config/nvim/.git && \
    rm -f /home/node/.config/nvim/lua/plugins/example.lua

# Custom nvim configs (baked into image)
COPY --chown=node:node config/nvim/lua/config/options.lua /home/node/.config/nvim/lua/config/options.lua
COPY --chown=node:node config/nvim/lua/config/lazy.lua /home/node/.config/nvim/lua/config/lazy.lua
COPY --chown=node:node config/nvim/lua/plugins/pylsp.lua /home/node/.config/nvim/lua/plugins/pylsp.lua
COPY --chown=node:node config/nvim/lua/plugins/treesitter-parsers.lua /home/node/.config/nvim/lua/plugins/treesitter-parsers.lua
COPY --chown=node:node config/nvim/lua/plugins/ruff.lua /home/node/.config/nvim/lua/plugins/ruff.lua
COPY --chown=node:node config/nvim/lua/plugins/markdown-preview.lua /home/node/.config/nvim/lua/plugins/markdown-preview.lua
COPY --chown=node:node config/nvim/lua/plugins/markdown-lint.lua /home/node/.config/nvim/lua/plugins/markdown-lint.lua
COPY --chown=node:node config/nvim/.markdownlint-cli2.yaml /home/node/.config/nvim/.markdownlint-cli2.yaml

# Set PATH early so tree-sitter-cli + claude are available for headless steps
ENV PATH="/home/node/.claude/local/bin:/home/node/.local/bin:/home/node/.cargo/bin:/home/node/.atuin/bin:$PATH"

# Pre-install LazyVim plugins (headless, with retry)
RUN for i in 1 2 3; do \
      nvim --headless "+Lazy! sync" +qa 2>/dev/null && break || sleep 2; \
    done

# Pre-install Mason LSP servers + tools with filesystem-based polling
# Mason API is_installed() has stale-cache issues, so check package dirs on disk instead
RUN nvim --headless \
    -c 'lua (function() \
      local pkgs = {"lua-language-server","bash-language-server","pyright","marksman","dockerfile-language-server","docker-compose-language-service","stylua","shfmt","shellcheck"} \
      local mason_dir = vim.fn.stdpath("data") .. "/mason/packages/" \
      local function is_pkg_installed(name) return vim.fn.isdirectory(mason_dir .. name) == 1 end \
      local max_passes = 3 \
      local pass = 0 \
      local function run_pass() \
        pass = pass + 1 \
        local missing = {} \
        for _, name in ipairs(pkgs) do \
          if not is_pkg_installed(name) then missing[#missing+1] = name end \
        end \
        if #missing == 0 then \
          print("All " .. #pkgs .. " Mason packages installed") \
          vim.cmd("qall"); return \
        end \
        if pass > max_passes then \
          print("Max passes reached, " .. #missing .. " still missing: " .. table.concat(missing, ", ")) \
          vim.cmd("qall"); return \
        end \
        print("Pass " .. pass .. ": installing " .. #missing .. " packages: " .. table.concat(missing, ", ")) \
        vim.cmd("MasonInstall " .. table.concat(missing, " ")) \
        local timer = vim.uv.new_timer() \
        local elapsed = 0 \
        timer:start(15000, 5000, vim.schedule_wrap(function() \
          elapsed = elapsed + 5000 \
          local all_done = true \
          for _, name in ipairs(missing) do \
            if not is_pkg_installed(name) then all_done = false; break end \
          end \
          if all_done or elapsed >= 90000 then \
            timer:stop(); timer:close() \
            if not all_done then print("Pass " .. pass .. " timed out, retrying remaining...") end \
            run_pass() \
          end \
        end)) \
      end \
      vim.defer_fn(function() \
        require("lazy").load({plugins={"mason.nvim","mason-lspconfig.nvim"}}) \
        vim.schedule(run_pass) \
      end, 5000) \
    end)()' \
    2>&1

# Pre-compile Treesitter parsers
# TSInstall completes quickly (~15s), use a simple defer to quit after it finishes
RUN nvim --headless \
    -c 'lua vim.defer_fn(function() \
      require("lazy").load({plugins={"nvim-treesitter"}}) \
      vim.schedule(function() \
        local langs = {"bash","python","lua","dockerfile","markdown","markdown_inline","json","yaml","toml","vim","vimdoc","regex","query"} \
        vim.cmd("TSInstall " .. table.concat(langs, " ")) \
        local timer = vim.uv.new_timer() \
        timer:start(15000, 5000, vim.schedule_wrap(function() \
          local all_done = true \
          for _, lang in ipairs(langs) do \
            local ok = pcall(vim.treesitter.language.inspect, lang) \
            if not ok then all_done = false; break end \
          end \
          if all_done then \
            timer:stop(); timer:close() \
            print("All treesitter parsers installed") \
            vim.cmd("qall") \
          end \
        end)) \
        vim.defer_fn(function() \
          timer:stop(); timer:close() \
          print("TSInstall safety timeout reached") \
          vim.cmd("qall") \
        end, 120000) \
      end) \
    end, 3000)' \
    2>&1

# Tmux Plugin Manager + config
RUN git clone --depth 1 https://github.com/tmux-plugins/tpm /home/node/.config/tmux/plugins/tpm
COPY --chown=node:node config/tmux/tmux.conf /home/node/.config/tmux/tmux.conf
RUN TMUX_PLUGIN_MANAGER_PATH="/home/node/.config/tmux/plugins" \
    /home/node/.config/tmux/plugins/tpm/bin/install_plugins

# Symlink for chezmoi dotfiles compatibility (tmux.conf references ~/.tmux/plugins/tpm/tpm)
RUN mkdir -p /home/node/.tmux && \
    ln -s /home/node/.config/tmux/plugins /home/node/.tmux/plugins

# Python LSP
RUN /home/node/.local/bin/uv tool install python-lsp-server \
    --with python-lsp-black \
    --with python-lsp-isort \
    --with pylsp-mypy

# Ruff linter/formatter
RUN /home/node/.local/bin/uv tool install ruff

# Chezmoi (retry on transient upstream 5xx from get.chezmoi.io)
# Placed AFTER heavy nvim/Mason/treesitter/uv builds so chezmoi tweaks (e.g. retry
# logic) don't bust their cache. chezmoi is only used at runtime by setup-chezmoi.sh.
RUN for i in 1 2 3; do \
        sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /home/node/.local/bin && break; \
        echo "chezmoi install attempt $i failed, retrying in 5s..."; \
        sleep 5; \
    done && test -x /home/node/.local/bin/chezmoi

# --- Below this line: frequently changed, fast rebuilds ---

# Extra APT packages (add new packages here to avoid invalidating heavy builds above)
USER root
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends bubblewrap
USER node

# Claude Code (native binary installer)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Codex CLI (OpenAI) — installs into boxa-npm-global volume (NPM_CONFIG_PREFIX).
# Existing volumes from before this change won't auto-populate; setup-claude.sh
# bootstraps Codex at runtime when missing.
RUN npm install -g @openai/codex

# agent-browser CLI (vercel-labs/agent-browser) — Rust-native browser
# automation CLI for AI agents. ADR 0010 wires this binary up against a
# host-side Chrome via CDP through an in-container socat bridge; only the
# CLI lives inside the container. Pinned via ARG so version bumps are
# explicit and reviewable; do NOT use `latest` per the no-runtime-installs
# rule (would silently drift across rebuilds).
ARG AGENT_BROWSER_VERSION=0.27.0
ENV AGENT_BROWSER_VERSION=${AGENT_BROWSER_VERSION}
RUN npm install -g "agent-browser@${AGENT_BROWSER_VERSION}"

# =============================================================================
# Layer 6: Firewall + scripts (root)
# =============================================================================
USER root

# Build stamp for volume freshness detection (must be after all nvim build steps)
# Written to both /opt/ (survives volume mount) and nvim data dir (Docker copies to fresh volumes)
RUN STAMP=$(date +%s) && \
    echo "$STAMP" > /opt/nvim-build-stamp && \
    echo "$STAMP" > /home/node/.local/share/nvim/.nvim-build-stamp && \
    chown node:node /home/node/.local/share/nvim/.nvim-build-stamp

# Ensure npm-global bin is in PATH for all zsh sessions (survives chezmoi dotfiles)
RUN echo 'export PATH="$PATH:/usr/local/share/npm-global/bin"' >> /etc/zsh/zshenv

# Ensure login shells that source /etc/profile also see global npm binaries.
# /etc/profile resets PATH, so the earlier Docker ENV alone is not enough.
RUN printf '%s\n' \
    'case ":$PATH:" in' \
    '  *:/usr/local/share/npm-global/bin:*) ;;' \
    '  *) export PATH="$PATH:/usr/local/share/npm-global/bin" ;;' \
    'esac' \
    > /etc/profile.d/npm-global-path.sh

# Shared firewall allowlist mount point (bind-mounted :ro from host)
RUN mkdir -p /etc/boxa-shared

# Claude Code config defaults (template — seeded into volume at startup)
COPY --chown=node:node config/claude/ /etc/claude-defaults/
RUN chmod +x /etc/claude-defaults/hooks/*.sh /etc/claude-defaults/statusline-info.sh

COPY lib/allowlist.sh /usr/local/share/boxa/lib/allowlist.sh
COPY lib/allow-for.sh /usr/local/share/boxa/lib/allow-for.sh
# Container MCP runtime (ADR 0013, issue 07). The boxa-mcp-run wrapper lives
# on PATH; it resolves `import mcp` from the package shipped at a fixed share
# dir so it runs from any CWD the agent launches it in. The wrapper checks
# Container identity, resolves the server from boxa's canonical profile,
# validates required env without logging values, and execs the MCP command.
COPY scripts/mcp/ /usr/local/share/boxa/mcp/
COPY scripts/mcp-run.sh /usr/local/bin/boxa-mcp-run
# Container MCP broker launcher (ADR 0014, issue 15). Runs the Python broker as
# boxa-mcp (started from the entrypoint root phase before the node drop).
COPY scripts/mcp-broker.sh /usr/local/bin/boxa-mcp-broker
# Container MCP broker mount-namespace wrapper (ADR 0014 "Update 2026-05-31",
# issue 21). Run as root inside `unshare --mount` from the entrypoint root phase:
# idmap-remounts the workspace rw for boxa-mcp in a private namespace, then
# execs the credential drop + broker. Needs util-linux `unshare`/`mount`/`setpriv`
# (installed in Layer 1).
COPY scripts/mcp-broker-namespace.sh /usr/local/bin/mcp-broker-namespace
# Container MCP secret staging (ADR 0014, issue 16). Run as root from the
# entrypoint root phase (and issue 17's `boxa mcp reload`) to copy the
# in-scope secret stores out of the gated read-only host mount into the
# boxa-mcp-private 0400 store the broker reads.
COPY scripts/stage-mcp-secrets.sh /usr/local/bin/stage-mcp-secrets
COPY init-firewall.sh /usr/local/bin/
COPY scripts/setup-chezmoi.sh /usr/local/bin/
# Bundled default dotfiles starter (chezmoi source), applied locally on start
# by setup-chezmoi.sh when CHEZMOI_REPO=bundled — no network, no clone.
COPY --chown=node:node dotfiles/ /usr/local/share/boxa/dotfiles/
COPY scripts/n scripts/nx /usr/local/bin/
COPY scripts/start-rootless-docker.sh /usr/local/bin/
COPY scripts/boxa-entrypoint.sh /usr/local/bin/
COPY scripts/boxa-firewall-reload.sh /usr/local/bin/boxa-firewall-reload
COPY scripts/setup-claude.sh /usr/local/bin/
COPY scripts/setup-nvim-data.sh /usr/local/bin/
COPY scripts/start-allow-for-window.sh /usr/local/bin/start-allow-for-window
COPY scripts/teardown-allow-for-window.sh /usr/local/bin/teardown-allow-for-window
COPY scripts/show-allow-for-status.sh /usr/local/bin/show-allow-for-status
COPY scripts/closeout-allow-for-on-restart.sh /usr/local/bin/closeout-allow-for-on-restart
COPY scripts/start-agent-browser-host-allow.sh /usr/local/bin/start-agent-browser-host-allow
COPY scripts/stop-agent-browser-host-allow.sh /usr/local/bin/stop-agent-browser-host-allow
# Shadow the npm-installed `agent-browser` CLI with a thin wrapper that
# auto-connects to the in-container CDP bridge on :9222. /usr/local/bin
# sits ahead of /usr/local/share/npm-global/bin in PATH, so this layer
# alone is enough to take precedence; the real binary stays reachable
# at its absolute path for the wrapper's exec.
COPY scripts/agent-browser-cdp-bridge.sh /usr/local/bin/agent-browser

# Container-only agent identity context (ADR 0011 Layer 3). Hook fires
# from Claude Code and Codex SessionStart; the script
# guards on /etc/boxa/identity.json so the same managed-settings
# fragments are inert if ever read on host.
COPY scripts/hooks/boxa-identity-context.sh /usr/local/bin/
COPY managed-settings/claude-code/50-boxa-identity.json \
     /etc/claude-code/managed-settings.d/50-boxa-identity.json
COPY managed-settings/codex/managed_config.toml \
     /etc/codex/managed_config.toml

RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/setup-chezmoi.sh \
    /usr/local/bin/n /usr/local/bin/nx /usr/local/bin/start-rootless-docker.sh \
    /usr/local/bin/boxa-entrypoint.sh /usr/local/bin/boxa-firewall-reload \
    /usr/local/bin/setup-claude.sh /usr/local/bin/setup-nvim-data.sh \
    /usr/local/bin/start-allow-for-window \
    /usr/local/bin/teardown-allow-for-window \
    /usr/local/bin/show-allow-for-status \
    /usr/local/bin/closeout-allow-for-on-restart \
    /usr/local/bin/start-agent-browser-host-allow \
    /usr/local/bin/stop-agent-browser-host-allow \
    /usr/local/bin/agent-browser \
    /usr/local/bin/boxa-mcp-run \
    /usr/local/bin/boxa-mcp-broker \
    /usr/local/bin/mcp-broker-namespace \
    /usr/local/bin/stage-mcp-secrets \
    /usr/local/bin/boxa-identity-context.sh

# The MCP runtime (Python package + launchers) must be readable+executable by
# BOTH node (relay) and boxa-mcp (broker). It is copied root-owned with
# default 0644/0755 (world-readable), so boxa-mcp can `import mcp` and exec
# the broker. ADR 0013's `install`-materialised runtime (issue 09) likewise
# lands world-readable, so it stays executable by boxa-mcp; nothing here is
# secret (the profile is references-only, secrets live in a separate store).
RUN chmod -R a+rX /usr/local/share/boxa/mcp

# Sudo with password — prevents AI agents from modifying firewall rules
# Password is injected via --mount=type=secret (never stored in image layers/metadata)
# Build with: docker build --secret id=sudo_password,src=<file> ...
# Falls back to "boxa" if no secret is provided
# NOTE: SUDO_CACHE_BUST forces cache invalidation — secret content alone doesn't bust cache
ARG SUDO_CACHE_BUST
RUN --mount=type=secret,id=sudo_password \
    PASS=$(cat /run/secrets/sudo_password 2>/dev/null || echo "boxa") && \
    echo "node:${PASS}" | chpasswd && \
    usermod -aG sudo node

# X11 forwarding support
RUN printf '%s\n' 'Defaults env_keep += "DISPLAY XAUTHORITY"' > /etc/sudoers.d/x11-forward && \
    chmod 440 /etc/sudoers.d/x11-forward && \
    touch /home/node/.Xauthority && chmod 600 /home/node/.Xauthority && \
    chown node:node /home/node/.Xauthority

# =============================================================================
# Layer 7: Final ENV
# =============================================================================
USER node

ENV EDITOR=nvim
ENV VISUAL=nvim
ENV XDG_RUNTIME_DIR=/run/user/1000
ENV DOCKER_HOST=unix:///run/user/1000/docker.sock
